[CmdletBinding()]
param(
    [string]$Version = '2.2.0',
    [string]$OutputDirectory,
    [string]$AcpBinaryPath
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
    $binDir = Join-Path $repositoryRoot 'plugin\bin'
    New-Item -ItemType Directory -Path $binDir -Force | Out-Null
    $pluginAcpBinary = Join-Path $binDir 'agy-acp.exe'

    if ($AcpBinaryPath) {
        $AcpBinaryPath = [System.IO.Path]::GetFullPath($AcpBinaryPath)
        if (-not (Test-Path -LiteralPath $AcpBinaryPath -PathType Leaf)) {
            throw "Precompiled agy-acp binary not found: $AcpBinaryPath"
        }
        Write-Host "Using precompiled agy-acp: $AcpBinaryPath"
        Copy-Item -LiteralPath $AcpBinaryPath -Destination $pluginAcpBinary -Force
    }
    else {
        # Compile agy-acp from the bundled source by default.
        $acpCargoPath = Join-Path $repositoryRoot 'plugin\agy-acp\Cargo.toml'
        if (-not (Test-Path -LiteralPath $acpCargoPath -PathType Leaf)) {
            throw 'Missing plugin/agy-acp/Cargo.toml and no -AcpBinaryPath was supplied.'
        }
        Write-Host "Compiling agy-acp..."
        & cargo build --release --manifest-path $acpCargoPath
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to compile agy-acp."
        }
        $acpBinarySource = Join-Path $repositoryRoot 'plugin\agy-acp\target\release\agy-acp.exe'
        if (-not (Test-Path -LiteralPath $acpBinarySource -PathType Leaf)) {
            $acpBinarySource = Join-Path $repositoryRoot 'plugin\agy-acp\target\release\agy-acp'
        }
        if (-not (Test-Path -LiteralPath $acpBinarySource -PathType Leaf)) {
            throw "Compiled agy-acp binary not found."
        }
        Copy-Item -LiteralPath $acpBinarySource -Destination $pluginAcpBinary -Force
    }

    New-Item -ItemType Directory -Path $OutputDirectory, $stagingDirectory -Force | Out-Null
    foreach ($item in @('plugin', 'README.md', 'LICENSE')) {
        $source = Join-Path $repositoryRoot $item
        if (-not (Test-Path -LiteralPath $source)) { throw "Missing release item: $item" }
        Copy-Item -LiteralPath $source -Destination (Join-Path $stagingDirectory $item) -Recurse -Force
    }

    # Clean up agy-acp source code and build files from the staging plugin directory to keep release lightweight
    $stagingAcpSource = Join-Path $stagingDirectory 'plugin\agy-acp'
    if (Test-Path -LiteralPath $stagingAcpSource -PathType Container) {
        Remove-Item -LiteralPath $stagingAcpSource -Recurse -Force
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
