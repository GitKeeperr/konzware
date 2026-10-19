# Konzware release build script.
# Copyright (c) Konzei. Licensed under the GNU General Public License v3.0.
#
# Syncs VERSION into tauri.conf.json / Cargo.toml / package.json, then builds.
# If a private signing script exists at .signing\build-release.ps1 it is used
# (signed build); otherwise falls back to `npm run tauri build` (unsigned).
# All activity is logged to konzware-build.log with [INFO]/[WARNING]/[ERROR].

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
    Write-KzLog INFO 'Build started.'

    # --- Pre-flight integrity checks -------------------------------------
    $versionFile = Join-Path $repoRoot 'VERSION'
    if (-not (Test-Path $versionFile)) {
        throw 'VERSION file not found at repo root. It is the single source of truth for the app version.'
    }
    $version = (Get-Content $versionFile -Raw).Trim()
    if ($version -notmatch '^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$') {
        throw "VERSION file contains '$version' - expected a valid semver like 2.0.3 or 2.0.3-alpha.1."
    }
    Write-KzLog INFO "Version: $version"

    if (-not (Test-Path (Join-Path $repoRoot 'package.json'))) {
        throw 'package.json not found - run this script from the Konzware repo root.'
    }
    if (-not (Test-Path (Join-Path $repoRoot 'src-tauri\Cargo.toml'))) {
        throw 'src-tauri\Cargo.toml not found - run this script from the Konzware repo root.'
    }
    foreach ($tool in @('npm', 'cargo')) {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
            throw "Required tool '$tool' was not found on PATH."
        }
    }
    Write-KzLog INFO 'Pre-flight checks passed (VERSION, package.json, Cargo.toml, npm, cargo).'

    # --- Sync tauri.conf.json --------------------------------------------
    $confPath = Join-Path $repoRoot 'src-tauri\tauri.conf.json'
    $conf = Get-Content $confPath -Raw
    if ($conf -notmatch '([\r\n ]+"version": ")(\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?)(")') {
        throw 'Could not find version field in tauri.conf.json.'
    }
    if ($Matches[2] -ne $version) {
        $old = $Matches[2]
        $conf = $conf -replace '([\r\n ]+"version": ")(\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?)(")', ('${1}' + $version + '${4}')
        [System.IO.File]::WriteAllText($confPath, $conf, [System.Text.UTF8Encoding]::new($false))
        Write-KzLog INFO "tauri.conf.json: $old -> $version"
    }

    # --- Sync Cargo.toml --------------------------------------------------
    $cargoPath = Join-Path $repoRoot 'src-tauri\Cargo.toml'
    $cargo = Get-Content $cargoPath -Raw
    if ($cargo -notmatch '(?m)^(version = ")(\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?)(")') {
        throw 'Could not find version field in Cargo.toml.'
    }
    if ($Matches[2] -ne $version) {
        $old = $Matches[2]
        $cargo = $cargo -replace '(?m)^(version = ")(\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?)(")', ('${1}' + $version + '${4}')
        [System.IO.File]::WriteAllText($cargoPath, $cargo, [System.Text.UTF8Encoding]::new($false))
        Write-KzLog INFO "Cargo.toml: $old -> $version"
    }

    # --- Sync package.json (optional) --------------------------------------
    $pkgPath = Join-Path $repoRoot 'package.json'
    if (Test-Path $pkgPath) {
        $pkg = Get-Content $pkgPath -Raw
        if ($pkg -match '("version": ")(\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?)(")') {
            if ($Matches[2] -ne $version) {
                $old = $Matches[2]
                $pkg = $pkg -replace '("version": ")(\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?)(")', ('${1}' + $version + '${4}')
                [System.IO.File]::WriteAllText($pkgPath, $pkg, [System.Text.UTF8Encoding]::new($false))
                Write-KzLog INFO "package.json: $old -> $version"
            }
        }
    }

    # --- Build -------------------------------------------------------------
    # Build the inventory-injector DLL first (strict: release must ship it).
    & powershell -ExecutionPolicy Bypass -File (Join-Path $repoRoot 'injector\build.ps1') -Strict
    if ($LASTEXITCODE -ne 0) {
        throw "injector DLL build failed with exit code $LASTEXITCODE."
    }

    $signingScript = Join-Path $repoRoot '.signing\build-release.ps1'
    if (Test-Path $signingScript) {
        Write-KzLog INFO 'Private signing script found - delegating to .signing\build-release.ps1.'
        & $signingScript
    }
    else {
        Write-KzLog WARNING '.signing\build-release.ps1 not present - producing an UNSIGNED build via "npm run tauri build". The updater will not be able to verify this artifact until signing keys are configured.'
        & npm run tauri build
        if ($LASTEXITCODE -ne 0) {
            throw "npm run tauri build failed with exit code $LASTEXITCODE."
        }
        $nsisDir = Join-Path $repoRoot 'src-tauri\target\release\bundle\nsis'
        $artifacts = Get-ChildItem -Path $nsisDir -Filter '*.exe' -ErrorAction SilentlyContinue
        foreach ($a in $artifacts) {
            Write-KzLog INFO "Artifact: $($a.FullName) ($([math]::Round($a.Length / 1MB, 1)) MB)"
        }
    }

    Write-KzLog INFO 'Build finished.'
    exit 0
}
catch {
    Write-KzLog ERROR $_.Exception.Message
    Write-KzLog ERROR 'Build aborted. See messages above.'
    exit 1
}
