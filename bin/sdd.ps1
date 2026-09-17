#requires -Version 7.0
<#
.SYNOPSIS
  SDD workflow giriş noktası. Proje klasöründe `sdd <komut>` olarak çalışır.
.DESCRIPTION
  Bu dosya sadece dağıtıcıdır: argümanı okur, ilgili lib fonksiyonunu çağırır.
  Hiçbir iş mantığı burada YAŞAMAZ. Projeye özel hiçbir varsayım burada YOK.

  Komutlar:
    sdd init                 Projeye .sdd/ iskeletini ve config'i kurar
    sdd spec      [-Prompt]  spec stage'ini çalıştırır
    sdd plan      [-Prompt]  plan stage'ini çalıştırır
    sdd tasks     [-Prompt]  tasks stage'ini çalıştırır
    sdd analyze              analyze stage'ini çalıştırır        (henüz taslak)
    sdd implement            Tier 0 + Tier 1 implement loop'unu başlatır
    sdd status               ledger özetini gösterir
    sdd config               stage seçim arayüzünü açar          (henüz taslak)
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('init','spec','plan','tasks','analyze','implement','status','config','sync-tasks')]
    [string] $Command,

    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]] $Rest
)

$ErrorActionPreference = 'Stop'

# Türkçe karakterlerin konsolda ve dosya okumada bozulmaması için UTF-8'e sabitle
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
    $PSDefaultParameterValues['*:Encoding'] = 'utf8'
} catch { }

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
    Write-Host "  sdd spec|plan|tasks      Spec Kit stage'ini çalıştırır"
    Write-Host "  sdd implement [-ObserveEvery N]   otonom implement loop"
    Write-Host "  sdd implement -RevalidateFrom SHA -CandidateCommit SHA   mevcut candidate'ı agentsız doğrula"
    Write-Host "  sdd analyze|config       (yapım aşamasında)"
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
        'sync-tasks' {
            # Mevcut tasks.md'yi (stage'i yeniden çalıştırmadan) ledger'a yükle.
            $root  = Find-ProjectRoot
            $paths = Get-SddPaths -ProjectRoot $root
            $L     = Read-Ledger -StatePath $paths.State
            $featureDir = Get-FeatureDirectory -ProjectRoot $root
            if (-not $featureDir) { throw ".specify/feature.json yok — önce spec/plan/tasks çalıştır." }
            $tasksMd = Join-Path $featureDir 'tasks.md'
            if (-not (Test-Path -LiteralPath $tasksMd)) { throw "tasks.md bulunamadı: $tasksMd" }
            $L = Import-TasksToLedger -Ledger $L -TasksMdPath $tasksMd
            Write-Ledger -Ledger $L -StatePath $paths.State
            $n = @(Get-LedgerTasks $L).Count
            Write-Host ""
            Write-Host "$n task ledger'a yüklendi." -ForegroundColor Green
            Show-LedgerStatus -StatePath $paths.State
        }
        { $_ -in 'spec','plan','tasks' } {
            $root  = Find-ProjectRoot
            $paths = Get-SddPaths -ProjectRoot $root
            $cfg   = Read-SddConfig -ConfigPath $paths.Config
            $L     = Read-Ledger -StatePath $paths.State

            # -Prompt "<metin>" ve serbest argüman ayrıştırması
            # ($Rest argümansız çağrıda null olabilir; @() ile güvene al)
            $restArr = @($Rest)
            $userArgs = ''
            $fixPrompt = ''
            $doResume = $false
            for ($i = 0; $i -lt $restArr.Count; $i++) {
                switch -Regex ($restArr[$i]) {
                    '^-Prompt$'  { $fixPrompt = $restArr[++$i]; continue }
                    '^-Resume$'  { $doResume = $true; continue }
                    default      { $userArgs = if ($userArgs) { "$userArgs $($restArr[$i])" } else { $restArr[$i] } }
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
        'implement' {
            $root  = Find-ProjectRoot
            $paths = Get-SddPaths -ProjectRoot $root
            $cfg   = Read-SddConfig -ConfigPath $paths.Config
            $L     = Read-Ledger -StatePath $paths.State

            $observeEvery = -1
            $revalidateFrom = ''
            $candidateCommit = ''
            $restArr = @($Rest)
            for ($i = 0; $i -lt $restArr.Count; $i++) {
                switch -Regex ($restArr[$i]) {
                    '^-ObserveEvery$' {
                        if ($i + 1 -ge $restArr.Count -or $restArr[$i + 1] -notmatch '^\d+$') {
                            throw '-ObserveEvery için sıfır veya pozitif bir sayı gerekli.'
                        }
                        $observeEvery = [int]$restArr[++$i]
                        continue
                    }
                    '^-Resume$' { continue } # loop zaten idempotent resume eder
                    '^-RevalidateFrom$' {
                        if ($i + 1 -ge $restArr.Count -or [string]::IsNullOrWhiteSpace($restArr[$i + 1])) {
                            throw '-RevalidateFrom için bir git commit SHA gerekli.'
                        }
                        $revalidateFrom = $restArr[++$i]
                        continue
                    }
                    '^-CandidateCommit$' {
                        if ($i + 1 -ge $restArr.Count -or [string]::IsNullOrWhiteSpace($restArr[$i + 1])) {
                            throw '-CandidateCommit için bir git commit SHA gerekli.'
                        }
                        $candidateCommit = $restArr[++$i]
                        continue
                    }
                    default { throw "Bilinmeyen implement argümanı: $($restArr[$i])" }
                }
            }

            $res = Invoke-ImplementLoop -Config $cfg -Ledger $L -ProjectRoot $root -ObserveEvery $observeEvery `
                                        -RevalidateFrom $revalidateFrom -CandidateCommit $candidateCommit
            Write-Host ""
            if ($res.ok -and $res.reason -eq 'completed') {
                Write-Host "[implement] tamamlandı — tüm otonom tasklar geçti." -ForegroundColor Green
            } elseif ($res.reason -eq 'observe_pause') {
                Write-Host "[implement] gözlem molası — devam etmek için yeniden 'sdd implement'." -ForegroundColor Yellow
            } else {
                Write-Host "[implement] durdu: $($res.reason)" -ForegroundColor Yellow
                if ($res.blocked) { Write-Host "  blocked: $(@($res.blocked) -join ', ')" -ForegroundColor Red }
                if ($res.manual)  { Write-Host "  manual:  $(@($res.manual) -join ', ')" -ForegroundColor Yellow }
                if ($res.output)  { Write-Host "  $($res.output)" -ForegroundColor DarkYellow }
            }
            Write-Host ""
        }
        default {
            Write-Host ""
            Write-Host "'$Command' henüz uygulanmadı (bu turda init + status çalışıyor)." -ForegroundColor Yellow
            Write-Host ""
        }
    }
}

Invoke-Sdd
