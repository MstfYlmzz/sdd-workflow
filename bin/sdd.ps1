#requires -Version 7.0
<#
.SYNOPSIS
  SDD workflow giriş noktası. Proje klasöründe `sdd <komut>` olarak çalışır.
.DESCRIPTION
  Bu dosya sadece dağıtıcıdır: argümanı okur, ilgili lib fonksiyonunu çağırır.
  Hiçbir iş mantığı burada YAŞAMAZ. Projeye özel hiçbir varsayım burada YOK.

  Komutlar:
    sdd init                 Projeye .sdd/ iskeletini ve config'i kurar
    sdd spec      [-Prompt]  spec stage'ini çalıştırır          (henüz taslak)
    sdd plan      [-Prompt]  plan stage'ini çalıştırır          (henüz taslak)
    sdd tasks     [-Prompt]  tasks stage'ini çalıştırır         (henüz taslak)
    sdd analyze              analyze stage'ini çalıştırır        (henüz taslak)
    sdd implement            implement loop'unu başlatır         (henüz taslak)
    sdd status               ledger özetini gösterir
    sdd config               stage seçim arayüzünü açar          (henüz taslak)
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('init','spec','plan','tasks','analyze','implement','status','config')]
    [string] $Command,

    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]] $Rest
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $PSCommandPath
$lib  = Join-Path (Split-Path -Parent $here) 'lib'

. (Join-Path $lib 'common.ps1')
. (Join-Path $lib 'ledger.ps1')
. (Join-Path $lib 'stages.ps1')
. (Join-Path $lib 'tier0.ps1')
. (Join-Path $lib 'tier1.ps1')
. (Join-Path $lib 'loop.ps1')

# adapter'ları yükle
Get-ChildItem -Path (Join-Path $lib 'adapters') -Filter '*.ps1' | ForEach-Object { . $_.FullName }

function Show-Help {
    Write-Host ""
    Write-Host "sdd — spec-driven development orkestratörü" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  sdd init        projeye .sdd/ kurar"
    Write-Host "  sdd status      ledger özeti"
    Write-Host "  sdd spec|plan|tasks|analyze|implement|config   (yapım aşamasında)"
    Write-Host ""
}

function Invoke-Sdd {
    if (-not $Command) { Show-Help; return }

    switch ($Command) {
        'init' {
            $res = Initialize-SddProject -ProjectRoot (Get-Location).Path
            Write-Host ""
            Write-Host "SDD kuruldu." -ForegroundColor Green
            foreach ($c in $res.Created) { Write-Host "  + $c" -ForegroundColor Green }
            foreach ($s in $res.Skipped) { Write-Host "  = $s (zaten var, dokunulmadı)" -ForegroundColor DarkGray }
            Write-Host ""
            Write-Host "Sonraki: .sdd/config.yaml'ı gözden geçir, sonra 'sdd status'." -ForegroundColor Gray
            Write-Host ""
        }
        'status' {
            $root  = Find-ProjectRoot
            $paths = Get-SddPaths -ProjectRoot $root
            Show-LedgerStatus -StatePath $paths.State
        }
        { $_ -in 'spec','plan','tasks' } {
            $root  = Find-ProjectRoot
            $paths = Get-SddPaths -ProjectRoot $root
            $cfg   = Read-SddConfig -ConfigPath $paths.Config
            $L     = Read-Ledger -StatePath $paths.State

            # -Prompt "<metin>" ve serbest argüman ayrıştırması
            $userArgs = ''
            $fixPrompt = ''
            $doResume = $false
            for ($i = 0; $i -lt $Rest.Count; $i++) {
                switch -Regex ($Rest[$i]) {
                    '^-Prompt$'  { $fixPrompt = $Rest[++$i]; continue }
                    '^-Resume$'  { $doResume = $true; continue }
                    default      { $userArgs = if ($userArgs) { "$userArgs $($Rest[$i])" } else { $Rest[$i] } }
                }
            }

            $res = Invoke-Stage -Name $Command -ProjectRoot $root -Config $cfg -Ledger $L `
                                -Arguments $userArgs -Prompt $fixPrompt -Resume:$doResume
            Write-Ledger -Ledger $L -StatePath $paths.State

            if ($res.ok) {
                Write-Host ""
                Write-Host "[$Command] tamamlandı." -ForegroundColor Green
                if ($res.feature_dir) { Write-Host "  feature: $($res.feature_dir)" -ForegroundColor Gray }
            } else {
                Write-Host ""
                Write-Host "[$Command] başarısız — .sdd/logs/$Command.log'a bak." -ForegroundColor Red
            }
        }
        default {
            Write-Host ""
            Write-Host "'$Command' henüz uygulanmadı (bu turda init + status çalışıyor)." -ForegroundColor Yellow
            Write-Host ""
        }
    }
}

Invoke-Sdd
