#requires -Version 7.0
[CmdletBinding()]
param(
    [string] $SourceDir = '',
    [string] $InstallDir = '',
    [switch] $SkipTests,
    [switch] $NoInstall
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$PinnedCommit = 'c039831190588c336abf4adba8a0d7c91c148774'
$repoRoot = Split-Path -Parent $PSScriptRoot
$overlayRoot = Join-Path $repoRoot 'spectatui-overlay'

if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'git PATH üzerinde bulunamadı.' }
if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
    throw 'Rust/Cargo gerekli. rustup ile stable toolchain kurulduktan sonra tekrar çalıştır.'
}

$ownedTemp = $false
if ([string]::IsNullOrWhiteSpace($SourceDir)) {
    $SourceDir = Join-Path ([IO.Path]::GetTempPath()) ("spectatui-sdd-" + [guid]::NewGuid().ToString('N'))
    $ownedTemp = $true
    & git clone --quiet https://github.com/tinesoft/spectatui.git $SourceDir
    if ($LASTEXITCODE -ne 0) { throw 'SpectaTUI repository clone başarısız.' }
}
$SourceDir = [IO.Path]::GetFullPath($SourceDir)

try {
    & git -C $SourceDir checkout --quiet $PinnedCommit
    if ($LASTEXITCODE -ne 0) { throw "SpectaTUI pinned commit checkout başarısız: $PinnedCommit" }

    $head = (& git -C $SourceDir rev-parse HEAD).Trim()
    if ($head -ne $PinnedCommit) { throw "SpectaTUI source commit uyuşmuyor: $head" }

    $overlayFiles = @(
        'crates/spectatui-core/src/speckit/mod.rs',
        'crates/spectatui/src/config.rs',
        'crates/spectatui/src/main.rs',
        'crates/spectatui/src/ui/mod.rs',
        'crates/spectatui/src/ui/sdd_runtime.rs',
        'crates/spectatui/src/ui/workflow.rs',
        'crates/spectatui/src/ui/workflows.rs'
    )
    foreach ($relative in $overlayFiles) {
        $src = Join-Path $overlayRoot $relative
        $dst = Join-Path $SourceDir $relative
        if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { throw "Overlay dosyası eksik: $relative" }
        Copy-Item -LiteralPath $src -Destination $dst -Force
    }

    if (-not $SkipTests) {
        Push-Location $SourceDir
        try {
            & cargo test -p spectatui-core discover_loads_sdd
            if ($LASTEXITCODE -ne 0) { throw 'SpectaTUI core SDD projection testi başarısız.' }
            & cargo check -p spectatui
            if ($LASTEXITCODE -ne 0) { throw 'Patched SpectaTUI compile kontrolü başarısız.' }
        } finally {
            Pop-Location
        }
    }

    Push-Location $SourceDir
    try {
        & cargo build --release -p spectatui
        if ($LASTEXITCODE -ne 0) { throw 'Patched SpectaTUI release build başarısız.' }
    } finally {
        Pop-Location
    }

    $exeName = if ($IsWindows) { 'spectatui.exe' } else { 'spectatui' }
    $built = Join-Path $SourceDir (Join-Path 'dist/target/release' $exeName)
    if (-not (Test-Path -LiteralPath $built -PathType Leaf)) { throw "Build çıktısı bulunamadı: $built" }

    if ($NoInstall) {
        Write-Host "Patched SpectaTUI build OK: $built" -ForegroundColor Green
        return
    }

    if ([string]::IsNullOrWhiteSpace($InstallDir)) {
        $InstallDir = if ($IsWindows) {
            Join-Path $env:LOCALAPPDATA 'sdd-workflow/bin'
        } else {
            Join-Path $HOME '.local/bin'
        }
    }
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    $targetName = if ($IsWindows) { 'spectatui-sdd.exe' } else { 'spectatui-sdd' }
    $target = Join-Path $InstallDir $targetName
    Copy-Item -LiteralPath $built -Destination $target -Force

    if (-not $IsWindows) {
        & chmod +x $target
        if ($LASTEXITCODE -ne 0) { throw 'spectatui-sdd executable yapılamadı.' }
    }

    $meta = [ordered]@{
        spectatui_commit = $PinnedCommit
        sdd_workflow_commit = $(try { (& git -C $repoRoot rev-parse HEAD).Trim() } catch { 'working-tree' })
        installed_at = (Get-Date).ToUniversalTime().ToString('o')
        binary = $target
    }
    $meta | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $InstallDir 'spectatui-sdd.json') -Encoding utf8

    Write-Host ''
    Write-Host 'Patched SpectaTUI kuruldu.' -ForegroundColor Green
    Write-Host "  binary : $target"
    Write-Host "  base   : SpectaTUI 1.1.0 @ $($PinnedCommit.Substring(0,8))"
    Write-Host ''
    Write-Host 'Çalıştırma:' -ForegroundColor Cyan
    Write-Host '  spectatui-sdd -p .'
} finally {
    if ($ownedTemp -and (Test-Path -LiteralPath $SourceDir)) {
        Remove-Item -LiteralPath $SourceDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
