#requires -Version 5.1
<#
    Compiles the dsh-pwsh-guard wrapper and stages dist\ with the rules file.
    Uses the .NET Framework csc.exe that ships with every Windows machine, so no
    SDK, NuGet or network access is needed.
#>
[CmdletBinding()]
param(
    [string]$OutputName = 'pwsh-guard-3.0.1.exe'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$source = Join-Path $root 'src\PwshGuard.cs'
$rules = Join-Path $root 'guard.rules.json'
$dist = Join-Path $root 'dist'
$exe = Join-Path $dist $OutputName

if (-not (Test-Path -LiteralPath $source)) { throw "source not found: $source" }
if (-not (Test-Path -LiteralPath $rules)) { throw "rules not found: $rules" }

$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $csc)) {
    $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
}
if (-not (Test-Path -LiteralPath $csc)) { throw 'csc.exe (NET Framework 4.x) not found' }

New-Item -ItemType Directory -Force -Path $dist | Out-Null

# Windows locks a running exe: never overwrite the file the live DSH is using.
if (Test-Path -LiteralPath $exe) {
    try {
        [System.IO.File]::Delete($exe)
    }
    catch {
        $exe = Join-Path $dist ([System.IO.Path]::GetFileNameWithoutExtension($OutputName) + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.exe')
        Write-Warning "previous exe is locked; writing $exe instead"
    }
}

& $csc /nologo /codepage:65001 /target:exe /optimize+ /out:$exe /r:System.Web.Extensions.dll $source
if ($LASTEXITCODE -ne 0) { throw "csc failed with exit code $LASTEXITCODE" }

Copy-Item -LiteralPath $rules -Destination (Join-Path $dist 'guard.rules.json') -Force

$hash = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
Write-Output "built  $exe"
Write-Output "size   $((Get-Item -LiteralPath $exe).Length) bytes"
Write-Output "sha256 $hash"
Write-Output ''
& $exe --guard-info
