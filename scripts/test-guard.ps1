#requires -Version 5.1
<#
    Behaviour matrix for dsh-pwsh-guard 4.x.

    Every case runs the guard exe exactly the way DSH runs it:
        <exe> -NoLogo -NoProfile -NonInteractive -Command <command>

    Expected outcomes:
      allow  -> exit 0, the delete happened
      refuse -> exit 86, nothing deleted, the refusal names the target and says
                what to do instead, and no later statement of the command ran
#>
[CmdletBinding()]
param(
    [string]$Exe = (Join-Path (Split-Path -Parent $PSScriptRoot) 'dist\pwsh-guard-4.0.0.exe')
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $Exe)) { throw "guard exe not found: $Exe (run scripts\build.ps1 first)" }

$sandbox = Join-Path $env:TEMP ('guard-matrix-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $sandbox | Out-Null

function New-Leaf([string]$name) {
    $p = Join-Path $sandbox $name
    Set-Content -LiteralPath $p -Value 'x'
    return $p
}

$cases = @()

$f1 = New-Leaf 'leaf1.txt'
$cases += [pscustomobject]@{ Name = 'allow: one named file'; Expect = 'allow'; WorkDir = $sandbox
    Command = "Remove-Item -LiteralPath '$f1' -Force; Write-Output 'done'"; ThenGone = $f1 }

$d2 = Join-Path $sandbox 'sub2'
New-Item -ItemType Directory -Force -Path $d2 | Out-Null
Set-Content -LiteralPath (Join-Path $d2 'a.txt') -Value 'a'
$cases += [pscustomobject]@{ Name = 'allow: one named sub-folder (-Recurse)'; Expect = 'allow'; WorkDir = $sandbox
    Command = "Remove-Item -LiteralPath '$d2' -Recurse -Force; Write-Output 'done'"; ThenGone = $d2 }

$cases += [pscustomobject]@{ Name = 'refuse: user profile root'; Expect = 'refuse'; WorkDir = $sandbox
    Command = 'Remove-Item $env:USERPROFILE -Recurse -Force'; MustContain = 'protected root' }

$cases += [pscustomobject]@{ Name = 'refuse: $home chain (the 2026-11-23 shape)'; Expect = 'refuse'; WorkDir = $sandbox
    Command = '$target = $env:USERPROFILE; Remove-Item -LiteralPath $target -Recurse -Force'; MustContain = 'protected root' }

$cwdCase = Join-Path $sandbox 'cwdcase'
New-Item -ItemType Directory -Force -Path $cwdCase | Out-Null
Set-Content -LiteralPath (Join-Path $cwdCase 'keep.txt') -Value 'k'
$cases += [pscustomobject]@{ Name = 'refuse: the session cwd itself'; Expect = 'refuse'; WorkDir = $cwdCase
    Command = 'Remove-Item . -Recurse -Force'; MustContain = 'protected root'; ThenThere = (Join-Path $cwdCase 'keep.txt') }

$cases += [pscustomobject]@{ Name = 'refuse: drive root'; Expect = 'refuse'; WorkDir = $sandbox
    Command = "Remove-Item 'C:\' -Recurse -Force -WhatIf"; MustContain = 'drive root' }

$d8 = Join-Path $sandbox 'wild8'
New-Item -ItemType Directory -Force -Path $d8 | Out-Null
Set-Content -LiteralPath (Join-Path $d8 'a.txt') -Value 'a'
$cases += [pscustomobject]@{ Name = 'refuse: wildcard sweep'; Expect = 'refuse'; WorkDir = $d8
    Command = 'Remove-Item * -Force'; MustContain = 'wildcard'; ThenThere = (Join-Path $d8 'a.txt') }

$d9 = Join-Path $sandbox 'bulk9'
New-Item -ItemType Directory -Force -Path $d9 | Out-Null
1..25 | ForEach-Object { Set-Content -LiteralPath (Join-Path $d9 ("f$_.txt")) -Value 'x' }
$cases += [pscustomobject]@{ Name = 'refuse: 25 targets in one call (limit 20)'; Expect = 'refuse'; WorkDir = $sandbox
    Command = "Get-ChildItem -LiteralPath '$d9' -File | Remove-Item -Force"; MustContain = 'more than the limit of 20'; ThenThere = (Join-Path $d9 'f1.txt') }

$f10 = New-Leaf 'leaf10.txt'
$cases += [pscustomobject]@{ Name = 'allow: alias rm on one file'; Expect = 'allow'; WorkDir = $sandbox
    Command = "rm -LiteralPath '$f10' -Force; Write-Output 'done'"; ThenGone = $f10 }

$d11 = Join-Path $sandbox 'sub11'
New-Item -ItemType Directory -Force -Path $d11 | Out-Null
Set-Content -LiteralPath (Join-Path $d11 'a.txt') -Value 'a'
Set-Content -LiteralPath (Join-Path $d11 'b.txt') -Value 'b'
$cases += [pscustomobject]@{ Name = 'allow: pipeline of two named files'; Expect = 'allow'; WorkDir = $sandbox
    Command = "Get-ChildItem -LiteralPath '$d11' -File | Remove-Item -Force; Write-Output ('left=' + @(Get-ChildItem -LiteralPath '$d11').Count)"; MustContain = 'left=0' }

$killer = Join-Path $sandbox 'killer.ps1'
Set-Content -LiteralPath $killer -Value "Remove-Item -LiteralPath `$env:USERPROFILE -Recurse -Force"
$cases += [pscustomobject]@{ Name = 'refuse: delete hidden in a .ps1 script'; Expect = 'refuse'; WorkDir = $sandbox
    Command = "& '$killer'"; MustContain = 'protected root' }

$f13 = New-Leaf 'leaf13.txt'
$cases += [pscustomobject]@{ Name = 'GAP (documented): cmd /c del bypasses the shim'; Expect = 'allow'; WorkDir = $sandbox
    Command = "cmd.exe /c del `"$f13`"; Write-Output 'done'"; ThenGone = $f13 }

$rows = @()
$failures = 0
foreach ($case in $cases) {
    $runCommand = $case.Command
    if ($case.Expect -eq 'refuse') { $runCommand = $case.Command + "; Write-Output 'AFTER'" }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.WorkingDirectory = $case.WorkDir
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardOutput = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    foreach ($a in @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', $runCommand)) { $psi.ArgumentList.Add($a) }

    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    if (-not $proc.WaitForExit(60000)) { $proc.Kill($true); $stdout = ''; $stderr = 'TIMEOUT' }
    $exit = $proc.ExitCode
    $text = $stdout + $stderr
    $problems = @()

    if ($case.Expect -eq 'refuse') {
        if ($exit -ne 86) { $problems += "expected exit 86, got $exit" }
        if ($text -notmatch 'REFUSED') { $problems += 'no REFUSED line' }
        if ($case.MustContain -and $text -notmatch [regex]::Escape($case.MustContain)) { $problems += "missing '$($case.MustContain)'" }
        if ($text -match 'AFTER') { $problems += 'execution continued after the refusal' }
        if ($text -notmatch 'What to do instead') { $problems += 'no advice line for the agent' }
    }
    else {
        if ($exit -ne 0) { $problems += "expected exit 0, got $exit" }
        if ($case.MustContain -and $text -notmatch [regex]::Escape($case.MustContain)) { $problems += "missing '$($case.MustContain)'" }
    }
    if ($case.PSObject.Properties.Name -contains 'ThenGone' -and (Test-Path -LiteralPath $case.ThenGone)) { $problems += 'target still exists' }
    if ($case.PSObject.Properties.Name -contains 'ThenThere' -and -not (Test-Path -LiteralPath $case.ThenThere)) { $problems += 'protected target was deleted' }

    $ok = ($problems.Count -eq 0)
    if (-not $ok) { $failures++ }
    $rows += [pscustomobject]@{ Result = if ($ok) { 'PASS' } else { 'FAIL' }; Case = $case.Name; Expect = $case.Expect; Exit = $exit; Detail = ($problems -join '; ') }

    if ($case.Name -like 'refuse: $home*') { Write-Output '--- sample refusal (what the agent sees) ---'; Write-Output $stderr }
}

$rows | Format-Table -AutoSize -Wrap | Out-String -Width 200 | Write-Output

$log = Join-Path (Split-Path -Parent $Exe) 'logs\guard.jsonl'
if (Test-Path -LiteralPath $log) {
    $lines = @(Get-Content -LiteralPath $log)
    $refused = @($lines | Where-Object { $_ -match '"decision":"refused"' }).Count
    $allowed = @($lines | Where-Object { $_ -match '"decision":"allowed"' }).Count
    Write-Output "log: $log  total=$($lines.Count) allowed=$allowed refused=$refused"
    Write-Output 'sample log line:'
    $lines | Select-Object -Last 1 | ForEach-Object { $_ }
} else {
    Write-Output "log MISSING: $log"
    $failures++
}

if ($failures -gt 0) { Write-Output "RESULT: $failures case(s) failed"; exit 1 }
Write-Output 'RESULT: all cases passed'
exit 0
