# dsh-pwsh-guard shim — the decision layer of the guard.
#
# The guard exe dot-sources this file ahead of every DSH PowerShell command, so
# the function below shadows Remove-Item (and therefore rm/del/erase/rd/rmdir/ri,
# which are aliases of that name) for the whole session, including scripts that
# the command calls.
#
# What it decides: the RESOLVED TARGETS of the delete, never the words of the
# command. PowerShell itself expands variables, wildcards and pipeline input, so
# `$home`, `.`, `*` and `Get-ChildItem x | Remove-Item` all arrive here as real
# paths.
#
# Policy (three data-driven checks, in order):
#   1. a target may not be a wildcard expression (it would delete what you did
#      not name)                       -> DSH_GUARD_DENY_WILDCARD=0 disables
#   2. a target may not be a protected root, nor an ancestor of one
#   3. a single call may not delete more than DSH_GUARD_MAX_TARGETS paths
# Anything else runs, and the resolved targets are appended to the log.
#
# A refusal states the target, why it is refused and what to do instead, pins
# exit code 86, and throws so that no later statement of the command can run.

function Write-GuardRefusal {
    param([string]$Headline, [string]$Advice, $Targets)

    [Console]::Error.WriteLine("[pwsh-guard] REFUSED Remove-Item: $Headline")
    [Console]::Error.WriteLine('[pwsh-guard] Nothing was deleted, and every later statement of this command was skipped (exit code 86).')
    if ($Targets -and $Targets.Count -gt 0) {
        $shown = @($Targets | Select-Object -First 10)
        [Console]::Error.WriteLine('[pwsh-guard] Targets that were resolved: ' + ($shown -join ' , ') + $(if ($Targets.Count -gt $shown.Count) { " ... and $($Targets.Count - $shown.Count) more" } else { '' }))
    }
    [Console]::Error.WriteLine("[pwsh-guard] What to do instead: $Advice")
    [Console]::Error.WriteLine('[pwsh-guard] If the user really asked for this, tell them what was refused and let them decide.')

    Write-GuardLog 'refused' $Headline $Targets

    # SetShouldExit pins the process exit code; throw aborts the rest of the
    # command, including the statements that follow it in a caller script.
    $host.SetShouldExit(86)
    throw "pwsh-guard refused this Remove-Item: $Headline"
}

function Write-GuardLog {
    param([string]$Decision, [string]$Reason, $Targets)

    $log = $env:DSH_GUARD_LOG
    if (-not $log) { return }
    try {
        $record = [pscustomobject]@{
            t        = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
            decision = $Decision
            reason   = $Reason
            pid      = $PID
            cwd      = (Get-Location).ProviderPath
            targets  = @($Targets)
        }
        Add-Content -LiteralPath $log -Value ($record | ConvertTo-Json -Compress -Depth 3) -Encoding UTF8 -ErrorAction SilentlyContinue
    }
    catch { }
}

function Remove-Item {
    $piped = @($input)

    $maxTargets = 20
    if ($env:DSH_GUARD_MAX_TARGETS) {
        $parsed = 0
        if ([int]::TryParse($env:DSH_GUARD_MAX_TARGETS, [ref]$parsed) -and $parsed -gt 0) { $maxTargets = $parsed }
    }
    $denyWildcard = ($env:DSH_GUARD_DENY_WILDCARD -ne '0')

    # Every argument value is a candidate target expression, except the values of
    # -Filter (a name filter, not a path) and the switches themselves.
    $expressions = New-Object 'System.Collections.Generic.List[string]'
    $candidates = New-Object 'System.Collections.Generic.List[object]'
    for ($i = 0; $i -lt $args.Count; $i++) {
        $a = $args[$i]
        if ($a -is [string] -and $a.StartsWith('-')) { continue }
        if ($i -gt 0 -and ($args[$i - 1] -is [string]) -and ($args[$i - 1] -ieq '-Filter')) { continue }
        if ($a -is [string]) { $expressions.Add($a) }
        $candidates.Add($a)
    }

    # Check 1: a wildcard would delete files the caller never named.
    if ($denyWildcard) {
        foreach ($e in $expressions) {
            if ($e.Contains('*') -or $e.Contains('?')) {
                Write-GuardRefusal "the target expression '$e' contains a wildcard, so it can delete files that were never named." `
                    "pass the exact paths (or a single folder) you mean to delete; if you only want to inspect matches, use Get-ChildItem first." @()
            }
        }
    }

    $targets = New-Object 'System.Collections.Generic.List[string]'
    foreach ($p in $piped) {
        if ($p -is [System.IO.FileSystemInfo]) { $targets.Add($p.FullName); continue }
        if ($p -is [string] -and $p.Length -gt 0) {
            $hit = @()
            try { $hit = @(Resolve-Path -Path $p -ErrorAction Stop) } catch { $hit = @() }
            if ($hit.Count -eq 0) {
                try { $hit = @(Resolve-Path -LiteralPath $p -ErrorAction Stop) } catch { $hit = @() }
            }
            foreach ($h in $hit) { $targets.Add($h.ProviderPath) }
        }
    }
    foreach ($c in $candidates) {
        if ($c -is [System.IO.FileSystemInfo]) { continue }
        if ($c -isnot [string] -or $c.Length -eq 0) { continue }
        $hit = @()
        try { $hit = @(Resolve-Path -Path $c -ErrorAction Stop) } catch { $hit = @() }
        if ($hit.Count -eq 0) {
            try { $hit = @(Resolve-Path -LiteralPath $c -ErrorAction Stop) } catch { $hit = @() }
        }
        foreach ($h in $hit) { if (-not $targets.Contains($h.ProviderPath)) { $targets.Add($h.ProviderPath) } }
    }

    # Check 3: a single call may not sweep more paths than a human can read.
    if ($targets.Count -gt $maxTargets) {
        Write-GuardRefusal "this one call would delete $($targets.Count) paths at once, which is more than the limit of $maxTargets." `
            "delete one folder or an explicit list of files per call, so every path is something you actually named." $targets
    }

    # Check 2: no protected root, and no ancestor of one.
    $protected = @(
        $env:USERPROFILE
        $env:LOCALAPPDATA
        $env:APPDATA
        $env:DSH_HOME
        (Get-Location).ProviderPath
    )
    if ($env:DSH_GUARD_EXTRA_ROOTS) {
        $protected += $env:DSH_GUARD_EXTRA_ROOTS -split ';'
    }
    $protected = @($protected | Where-Object { $_ -and $_.Trim() -ne '' } | ForEach-Object { $_.Trim().TrimEnd('\') })

    foreach ($t in $targets) {
        $full = $t.TrimEnd('\')
        $rootTrim = ''
        try { $rootTrim = [System.IO.Path]::GetPathRoot($full) } catch { $rootTrim = '' }
        if ($rootTrim) { $rootTrim = $rootTrim.TrimEnd('\') }

        if ($rootTrim -and ($full -ieq $rootTrim)) {
            Write-GuardRefusal "the target '$full' is a drive root." `
                "name the file or sub-folder inside it that you actually want gone." $targets
        }

        foreach ($p in $protected) {
            if ($full -ieq $p) {
                Write-GuardRefusal "the target '$full' is a protected root (user home, AppData, DSH home, or the session's working directory). Deleting it would destroy everything under it." `
                    "name the file or sub-folder inside it that you actually want gone." $targets
            }
            if ($p.StartsWith($full + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
                Write-GuardRefusal "the target '$full' is a parent folder of the protected root '$p'." `
                    "name the file or sub-folder inside it that you actually want gone." $targets
            }
        }
    }

    Write-GuardLog 'allowed' "delete of $($targets.Count) named target(s)" $targets

    if ($piped.Count -gt 0) { $piped | Microsoft.PowerShell.Management\Remove-Item @args }
    else { Microsoft.PowerShell.Management\Remove-Item @args }
}
