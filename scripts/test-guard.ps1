#requires -Version 5.1
<#
    Behaviour matrix for pwsh-guard.exe.

    Every case runs the wrapper exactly the way DSH runs it:
        <exe> -NoLogo -NoProfile -NonInteractive -Command <command>

    Expected outcomes:
      allow  -> exit 0 (command ran)
      block  -> exit 3 (refused before PowerShell started)

    Run:  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\test-guard.ps1
#>
[CmdletBinding()]
param(
    [string]$Exe = (Join-Path (Split-Path -Parent $PSScriptRoot) 'dist\pwsh-guard-v3.exe')
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $Exe)) { throw "guard exe not found: $Exe  (run scripts\build.ps1 first)" }

$marker = '# dsh-guard:allow-destructive'
$rulesFile = Join-Path (Split-Path -Parent $PSScriptRoot) 'guard.rules.json'
$unicode = [string][char]0x4E2D + [string][char]0x6587 + '-ok'
$tempFile = Join-Path $env:TEMP ('guard-test-' + [guid]::NewGuid().ToString('N') + '.txt')
Set-Content -LiteralPath $tempFile -Value 'probe'

$cases = @(
    [pscustomobject]@{
        Name = 'allow: plain command'
        Expect = 'allow'
        Command = 'Write-Output "plain-ok"'
        MustContain = 'plain-ok'
    },
    [pscustomobject]@{
        Name = 'allow: destructive verb only quoted as a search pattern'
        Expect = 'allow'
        Command = ('Select-String -LiteralPath "' + $rulesFile + '" -Pattern "Remove-Item" -SimpleMatch | Out-Null; Write-Output "quoted-ok"')
        MustContain = 'quoted-ok'
    },
    [pscustomobject]@{
        Name = 'allow: variable named after the verb'
        Expect = 'allow'
        Command = '$removeItem = 1; Write-Output "var-ok-$removeItem"'
        MustContain = 'var-ok-1'
    },
    [pscustomobject]@{
        Name = 'allow: unicode round-trip (UTF-8 through the wrapper)'
        Expect = 'allow'
        Command = ('Write-Output "' + $unicode + '"')
        MustContain = $unicode
    },
    [pscustomobject]@{
        Name = 'block: delete at statement start'
        Expect = 'block'
        Command = 'Remove-Item -LiteralPath "C:\never-exists\guard-probe" -Recurse -Force -ErrorAction SilentlyContinue; Write-Output "SHOULD-NOT-RUN"'
    },
    [pscustomobject]@{
        Name = 'block: delete after semicolon'
        Expect = 'block'
        Command = '$x = 1; Remove-Item -LiteralPath "C:\never-exists" -ErrorAction SilentlyContinue; Write-Output "SHOULD-NOT-RUN"'
    },
    [pscustomobject]@{
        Name = 'block: delete on its own line (the 2026-11-23 shape)'
        Expect = 'block'
        Command = ("`$target = Join-Path `$env:TEMP 'guard-probe'`nRemove-Item -LiteralPath `$target -Recurse -Force`nWrite-Output 'SHOULD-NOT-RUN'")
    },
    [pscustomobject]@{
        Name = 'block: delete inside a script block'
        Expect = 'block'
        Command = 'Get-ChildItem -LiteralPath $env:TEMP -Filter "guard-no-match-*" | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }'
    },
    [pscustomobject]@{
        Name = 'block: cmdlet alias rd'
        Expect = 'block'
        Command = 'rd C:\never-exists'
    },
    [pscustomobject]@{
        Name = 'block: git clean'
        Expect = 'block'
        Command = 'git clean -fdx'
    },
    [pscustomobject]@{
        Name = 'block: robocopy /MIR'
        Expect = 'block'
        Command = 'robocopy C:\never-a C:\never-b /MIR'
    },
    [pscustomobject]@{
        Name = 'block: taskkill /T'
        Expect = 'block'
        Command = 'taskkill /IM never-exists.exe /T /F'
    },
    [pscustomobject]@{
        Name = 'block: -File script bypass'
        Expect = 'block'
        Command = 'powershell.exe -NoProfile -File "C:\never-exists\guard-probe.ps1"'
    },
    [pscustomobject]@{
        Name = 'block: protected root outranks the allow marker'
        Expect = 'block'
        Command = ($marker + "`nRemove-Item -LiteralPath `$env:USERPROFILE\__guard_probe_never__ -Recurse -Force -ErrorAction SilentlyContinue; Write-Output 'SHOULD-NOT-RUN'")
    },
    [pscustomobject]@{
        Name = 'allow: explicit marker deletes a temp file'
        Expect = 'allow'
        Command = ($marker + "`nRemove-Item -LiteralPath '" + $tempFile + "' -Force; Write-Output 'marker-ok'")
        MustContain = 'marker-ok'
        ThenMissing = $tempFile
    }
)

$rows = @()
$failures = 0
foreach ($case in $cases) {
    $output = & $Exe -NoLogo -NoProfile -NonInteractive -Command $case.Command 2>&1
    $exit = $LASTEXITCODE
    $text = ($output | Out-String)
    $problems = @()

    if ($case.Expect -eq 'block') {
        if ($exit -ne 3) { $problems += "expected exit 3, got $exit" }
        if ($text -notmatch 'BLOCKED') { $problems += 'no BLOCKED line on stderr' }
        if ($text -match 'SHOULD-NOT-RUN') { $problems += 'the command body executed' }
    }
    else {
        if ($exit -ne 0) { $problems += "expected exit 0, got $exit" }
        if ($case.PSObject.Properties.Name -contains 'MustContain' -and $text -notmatch [regex]::Escape($case.MustContain)) {
            $problems += "stdout missing '$($case.MustContain)'"
        }
        if ($case.PSObject.Properties.Name -contains 'ThenMissing' -and (Test-Path -LiteralPath $case.ThenMissing)) {
            $problems += 'target file still exists'
        }
    }

    $ok = ($problems.Count -eq 0)
    if (-not $ok) { $failures++ }
    $rows += [pscustomobject]@{
        Result = if ($ok) { 'PASS' } else { 'FAIL' }
        Case   = $case.Name
        Expect = $case.Expect
        Exit   = $exit
        Detail = ($problems -join '; ')
    }
}

$rows | Format-Table -AutoSize -Wrap | Out-String -Width 200 | Write-Output

if (Test-Path -LiteralPath $tempFile) { [System.IO.File]::Delete($tempFile) }

$logDir = Join-Path (Split-Path -Parent $Exe) 'logs'
$logFile = Join-Path $logDir 'guard.jsonl'
if (Test-Path -LiteralPath $logFile) {
    $logged = @(Get-Content -LiteralPath $logFile | Select-Object -Last 60)
    $blockedLines = @($logged | Where-Object { $_ -match '"decision":"blocked"' })
    Write-Output "log file   : $logFile"
    Write-Output "last lines : $($logged.Count) (blocked: $($blockedLines.Count))"
} else {
    Write-Output "log file   : MISSING ($logFile)"
    $failures++
}

if ($failures -gt 0) {
    Write-Output "RESULT: $failures case(s) failed"
    exit 1
}
Write-Output 'RESULT: all cases passed'
exit 0
