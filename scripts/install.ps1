#requires -Version 5.1
<#
    Installs the guard into a DSH profile by pointing the existing
    `@deepseek-ai/dsh-pwsh-sandbox` plugin's `pwshPath` at pwsh-guard.exe.

    Nothing outside the DSH profile is touched: the system PowerShell install,
    PATH and the user profile script are left alone, so the user's own terminal
    never goes through the guard.

    Run:  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\install.ps1
#>
[CmdletBinding()]
param(
    [string]$Exe = (Join-Path (Split-Path -Parent $PSScriptRoot) 'dist\pwsh-guard-v3.exe'),
    [string]$ProfileDir = $(if ($env:DSH_PROFILE_DIR) { $env:DSH_PROFILE_DIR } else { Join-Path $env:USERPROFILE '.dsh\profiles\desktop' })
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Exe)) { throw "guard exe not found: $Exe (run scripts\build.ps1 first)" }
$Exe = (Resolve-Path -LiteralPath $Exe).Path

$patch = Join-Path $ProfileDir 'cordis.patch.yml'
if (-not (Test-Path -LiteralPath $patch)) { throw "profile patch not found: $patch" }

# ---------------------------------------------------------------- preflight
Write-Output '--- preflight: the exe must run, allow and block ---'
$infoLines = @(& $Exe --guard-info 2>&1)
$infoExit = $LASTEXITCODE
$infoLines | Select-Object -First 4 | ForEach-Object { Write-Output $_ }
if ($infoExit -ne 0) { throw "guard exe failed its --guard-info self check (exit $infoExit)" }

$allowOut = & $Exe -NoLogo -NoProfile -NonInteractive -Command 'Write-Output "install-allow-ok"' 2>&1
if ($LASTEXITCODE -ne 0 -or (($allowOut | Out-String) -notmatch 'install-allow-ok')) {
    throw 'guard exe did not forward an allowed command'
}

$blockCmd = 'Remove-Item -LiteralPath "C:\never-exists\guard-install-probe" -Recurse -Force -ErrorAction SilentlyContinue; Write-Output "SHOULD-NOT-RUN"'
$blockOut = & $Exe -NoLogo -NoProfile -NonInteractive -Command $blockCmd 2>&1
if ($LASTEXITCODE -ne 3) { throw "guard exe did not block a delete (exit $LASTEXITCODE)" }
if (($blockOut | Out-String) -match 'SHOULD-NOT-RUN') { throw 'blocked command was executed anyway' }
Write-Output 'preflight ok'

# ------------------------------------------------------------------- backup
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backup = "$patch.bak-pwsh-guard-$stamp"
Copy-Item -LiteralPath $patch -Destination $backup
Write-Output "backup    : $backup"

# ------------------------------------------------------- patch the pwsh entry
$bytes = [System.IO.File]::ReadAllBytes($patch)
$hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
$text = [System.IO.File]::ReadAllText($patch)
$lines = New-Object System.Collections.Generic.List[string]
$lines.AddRange([string[]]($text -split "`r?`n"))

$entryPattern = '^\s*-\s*id:\s*pwsh-sandbox\s*$'
$entryIndex = -1
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match $entryPattern) { $entryIndex = $i; break }
}

$yamlPath = $Exe.Replace("'", "''")
if ($entryIndex -ge 0) {
    $end = $lines.Count
    for ($j = $entryIndex + 1; $j -lt $lines.Count; $j++) {
        if ($lines[$j] -match '^\s*-\s+id:\s*') { $end = $j; break }
    }
    $replaced = $false
    for ($k = $entryIndex + 1; $k -lt $end; $k++) {
        if ($lines[$k] -match '^(\s*)pwshPath:\s*') {
            $lines[$k] = $Matches[1] + "pwshPath: '$yamlPath'"
            $replaced = $true
            break
        }
    }
    if (-not $replaced) {
        for ($k = $entryIndex + 1; $k -lt $end; $k++) {
            if ($lines[$k] -match '^(\s*)config:\s*$') {
                $lines.Insert($k + 1, ($Matches[1] + "  pwshPath: '$yamlPath'"))
                $replaced = $true
                break
            }
        }
    }
    if (-not $replaced) { throw "found the pwsh-sandbox entry but no config block to extend in $patch" }
} else {
    $lines.Add('')
    $lines.Add('# Added by dsh-pwsh-guard: every DSH pwsh command goes through the guard exe.')
    $lines.Add('- id: pwsh-sandbox')
    $lines.Add('  name: "@deepseek-ai/dsh-pwsh-sandbox"')
    $lines.Add('  config:')
    $lines.Add("    pwshPath: '$yamlPath'")
}

$newText = ($lines -join "`r`n")
[System.IO.File]::WriteAllText($patch, $newText, (New-Object System.Text.UTF8Encoding($hasBom)))

Write-Output "profile   : $patch"
Write-Output "pwshPath  : $Exe"
Write-Output ''
Write-Output 'Now verify in DSH (the profile is re-applied live; no restart needed):'
Write-Output '  1) ask DSH: Write-Output guard-live-ok                       -> should print guard-live-ok'
Write-Output '  2) ask DSH: Remove-Item -LiteralPath C:\nope -Recurse -Force  -> should be BLOCKED (exit code 3)'
Write-Output '  3) read   : dist\logs\guard.jsonl                             -> both decisions must be logged'
Write-Output ''
Write-Output "Rollback  : copy '$backup' over '$patch'"
