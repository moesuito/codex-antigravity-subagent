[CmdletBinding()]
param(
    [string]$Version = '1.0.0',
    [string]$OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$manifestPath = Join-Path $repositoryRoot 'plugin\.codex-plugin\plugin.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw 'Missing plugin manifest.'
}
$manifestVersion = (Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json).version
if ($manifestVersion -ne $Version) {
    throw "Plugin manifest version ($manifestVersion) does not match release version ($Version)."
}
if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $repositoryRoot 'release'
}
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
$stagingDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "codex-antigravity-subagent-release-$([guid]::NewGuid().ToString('N'))"
$archivePath = Join-Path $OutputDirectory 'codex-antigravity-subagent.zip'

try {
    New-Item -ItemType Directory -Path $OutputDirectory, $stagingDirectory -Force | Out-Null
    foreach ($item in @('plugin', 'README.md', 'LICENSE')) {
        $source = Join-Path $repositoryRoot $item
        if (-not (Test-Path -LiteralPath $source)) { throw "Missing release item: $item" }
        Copy-Item -LiteralPath $source -Destination (Join-Path $stagingDirectory $item) -Recurse -Force
    }
    Get-ChildItem -LiteralPath $stagingDirectory -Filter '__pycache__' -Directory -Recurse -ErrorAction SilentlyContinue |
        Remove-Item -Recurse -Force
    if (Test-Path -LiteralPath $archivePath) { Remove-Item -LiteralPath $archivePath -Force }
    Compress-Archive -Path (Join-Path $stagingDirectory '*') -DestinationPath $archivePath -CompressionLevel Optimal
    $archivePath
}
finally {
    Remove-Item -LiteralPath $stagingDirectory -Recurse -Force -ErrorAction SilentlyContinue
}
