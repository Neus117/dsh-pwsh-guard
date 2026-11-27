#requires -Version 5.1
<#
    Removes the guard from a DSH profile. Two modes:

      -Restore            copy the newest cordis.patch.yml.bak-pwsh-guard-* back
      (default)           delete only the pwshPath line from the pwsh-sandbox
                          entry, so DSH resolves a real pwsh again

    Nothing outside the DSH profile is touched. The exe and its logs stay on
    disk; delete the dist folder yourself if you want them gone.
#>
[CmdletBinding()]
param(
    [string]$ProfileDir = $(if ($env:DSH_PROFILE_DIR) { $env:DSH_PROFILE_DIR } else { Join-Path $env:USERPROFILE '.dsh\profiles\desktop' }),
    [switch]$Restore
)

$ErrorActionPreference = 'Stop'
$patch = Join-Path $ProfileDir 'cordis.patch.yml'
if (-not (Test-Path -LiteralPath $patch)) { throw "profile patch not found: $patch" }

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backup = "$patch.bak-pwsh-guard-uninstall-$stamp"
Copy-Item -LiteralPath $patch -Destination $backup
Write-Output "backup    : $backup"

if ($Restore) {
    $candidate = Get-ChildItem -LiteralPath $ProfileDir -Filter 'cordis.patch.yml.bak-pwsh-guard-*' |
        Where-Object { $_.Name -notlike '*uninstall*' } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if (-not $candidate) { throw 'no cordis.patch.yml.bak-pwsh-guard-* backup found' }
    Copy-Item -LiteralPath $candidate.FullName -Destination $patch -Force
    Write-Output "restored  : $($candidate.FullName)"
    Write-Output 'Re-verify with: Write-Output guard-restored-ok'
    exit 0
}

$bytes = [System.IO.File]::ReadAllBytes($patch)
$hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
$lines = New-Object System.Collections.Generic.List[string]
$lines.AddRange([string[]]([System.IO.File]::ReadAllText($patch) -split "`r?`n"))

$removed = 0
$inEntry = $false
foreach ($line in @($lines)) {
    if ($line -match '^\s*-\s+id:\s*') { $inEntry = ($line -match '^\s*-\s*id:\s*pwsh-sandbox\s*$'); continue }
    if ($inEntry -and $line -match '^\s*pwshPath:\s*') {
        $lines.Remove($line)
        $removed++
    }
}
if ($removed -eq 0) { Write-Warning 'no pwshPath line found; nothing changed' }

[System.IO.File]::WriteAllText($patch, ($lines -join "`r`n"), (New-Object System.Text.UTF8Encoding($hasBom)))
Write-Output "removed   : $removed pwshPath line(s) from $patch"
Write-Output 'DSH now resolves a real pwsh: the guard is off. Re-verify with: Write-Output guard-off-ok'
