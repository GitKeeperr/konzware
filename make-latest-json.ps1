# Generates latest.json for the Tauri updater from the newest NSIS build.
# Copyright (c) Konzei. Licensed under the GNU General Public License v3.0.
#
# Requires a signed build (TAURI_SIGNING_PRIVATE_KEY set at build time so a
# .sig file exists next to the setup exe). All activity is logged to
# konzware-build.log with [INFO]/[WARNING]/[ERROR].

param(
    [string]$Tag,
    [string]$Out = "latest.json"
)
$ErrorActionPreference = 'Stop'
$repoRoot = $PSScriptRoot
Set-Location $repoRoot
$logPath = Join-Path $repoRoot 'konzware-build.log'

function Write-KzLog {
    param(
        [ValidateSet('INFO', 'WARNING', 'ERROR')][string]$Level = 'INFO',
        [string]$Message
    )
    $line = '[{0}] [{1,-7}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    try { Add-Content -Path $logPath -Value $line -Encoding UTF8 } catch {}
}

try {
    Write-KzLog INFO 'latest.json generation started.'

    # --- Pre-flight integrity checks -------------------------------------
    $versionFile = Join-Path $repoRoot 'VERSION'
    if (-not (Test-Path $versionFile)) {
        throw 'VERSION file not found at repo root.'
    }
    $version = (Get-Content $versionFile -Raw).Trim()
    if (-not $Tag) { $Tag = "v$version" }
    Write-KzLog INFO "Version: $version (tag: $Tag)"

    $nsisDir = Join-Path $repoRoot 'src-tauri\target\release\bundle\nsis'
    if (-not (Test-Path $nsisDir)) {
        throw "NSIS output folder not found: $nsisDir. Run build-release.ps1 first."
    }

    $setup = Get-ChildItem -Path $nsisDir -Filter "*$version*_x64-setup.exe" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $setup) {
        $setup = Get-ChildItem -Path $nsisDir -Filter '*_x64-setup.exe' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
    }
    if (-not $setup) {
        throw "No NSIS setup exe found in $nsisDir. Run build-release.ps1 first."
    }
    Write-KzLog INFO "Setup exe: $($setup.FullName)"

    $sigPath = "$($setup.FullName).sig"
    if (-not (Test-Path $sigPath)) {
        throw "Updater signature missing: $sigPath. The build must run with TAURI_SIGNING_PRIVATE_KEY set (build-release.ps1 handles this)."
    }
    $signature = (Get-Content $sigPath -Raw).Trim()

    $url = "https://github.com/GitKeeperr/konzware/releases/download/$Tag/$($setup.Name)"

    $json = [ordered]@{
        version   = $version
        notes     = "Konzware v$version`n`nSee the in-app What's New for the full changelog."
        pub_date  = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        platforms = [ordered]@{
            'windows-x86_64' = [ordered]@{
                url       = $url
                signature = $signature
            }
        }
    }
    $jsonText = $json | ConvertTo-Json -Depth 5

    $outPath = Join-Path $repoRoot $Out
    [System.IO.File]::WriteAllText($outPath, $jsonText, [System.Text.UTF8Encoding]::new($false))

    Write-KzLog INFO "Wrote $outPath (version $version)"
    Write-KzLog INFO "    url: $url"
    Write-KzLog INFO "    sig: $sigPath"
    Write-KzLog INFO "Edit 'notes' if you want custom release notes, then upload latest.json so the releases/latest/download/latest.json endpoint serves it."
    exit 0
}
catch {
    Write-KzLog ERROR $_.Exception.Message
    Write-KzLog ERROR 'latest.json generation aborted.'
    exit 1
}
