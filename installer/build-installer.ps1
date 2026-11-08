param(
    [string]$OutFile = ''
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $OutFile) {
    $OutFile = Join-Path $root 'herdr-approve-all-setup.exe'
}

$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $csc)) {
    throw "csc.exe not found at $csc"
}

$csFile = Join-Path $PSScriptRoot 'HerdrApproveAllSetup.cs'
$cscArgs = @(
    '/nologo',
    '/optimize+',
    '/target:exe',
    "/out:$OutFile",
    ('/resource:' + (Join-Path $root 'herdr-plugin.toml') + ',herdr-plugin.toml'),
    ('/resource:' + (Join-Path $root 'README.md') + ',README.md'),
    ('/resource:' + (Join-Path $root 'scripts\dispatch') + ',scripts/dispatch'),
    ('/resource:' + (Join-Path $root 'scripts\dispatch.cmd') + ',scripts/dispatch.cmd'),
    ('/resource:' + (Join-Path $root 'scripts\approve-windows.ps1') + ',scripts/approve-windows.ps1'),
    ('/resource:' + (Join-Path $root 'scripts\lib.sh') + ',scripts/lib.sh'),
    ('/resource:' + (Join-Path $root 'scripts\approve-blocked.sh') + ',scripts/approve-blocked.sh'),
    ('/resource:' + (Join-Path $root 'scripts\auto-toggle.sh') + ',scripts/auto-toggle.sh'),
    ('/resource:' + (Join-Path $root 'scripts\on-status-changed.sh') + ',scripts/on-status-changed.sh'),
    $csFile
)

& $csc @cscArgs
if ($LASTEXITCODE -ne 0) {
    throw "csc.exe failed with exit code $LASTEXITCODE"
}
Write-Output "Built installer: $OutFile"
