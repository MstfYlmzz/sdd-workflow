#requires -Version 7.0
<#
.SYNOPSIS
  SDD workflow giriş noktası. Proje klasöründe `sdd <komut>` olarak çalışır.

.DESCRIPTION
  Bu dosya sadece dağıtıcıdır: argümanı okur, ilgili lib fonksiyonunu çağırır.
  Hiçbir iş mantığı burada YAŞAMAZ. Projeye özel hiçbir varsayım burada YOK.

  Komutlar (nihai hedef — bu turda hepsi taslak):
    sdd init                 Projeye .sdd/ iskeletini ve config'i kurar
    sdd spec      [-Prompt]  spec stage'ini çalıştırır
    sdd plan      [-Prompt]  plan stage'ini çalıştırır
    sdd tasks     [-Prompt]  tasks stage'ini çalıştırır
    sdd analyze              analyze stage'ini çalıştırır (otonom, rapor üretir)
    sdd implement            implement loop'unu başlatır (Tier 0 + Tier 1)
    sdd status               ledger özetini gösterir
    sdd config               stage seçim arayüzünü açar (agent/model/effort)

  Ortak bayraklar:
    -Prompt "<metin>"   Aynı stage'i düzeltme talimatıyla yeniden çalıştırır
    -Resume             Yarıda kalmış stage'i kaldığı yerden sürdürür
    -ObserveEvery N     implement: her N batch'te dur ve devamı bekle
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

# lib modüllerini yükle
. (Join-Path $lib 'common.ps1')
. (Join-Path $lib 'ledger.ps1')
. (Join-Path $lib 'stages.ps1')
. (Join-Path $lib 'tier0.ps1')
. (Join-Path $lib 'tier1.ps1')
. (Join-Path $lib 'loop.ps1')

function Invoke-Sdd {
    # TODO: $Command'a göre ilgili Invoke-* fonksiyonuna yönlendir.
    #   init      -> Initialize-SddProject
    #   spec/plan/tasks/analyze -> Invoke-Stage -Name <command> -Rest $Rest
    #   implement -> Invoke-ImplementLoop -Rest $Rest
    #   status    -> Show-LedgerStatus
    #   config    -> Show-AgentSelection (kaydet)
    # Komut yoksa kısa yardım bas.
    throw [System.NotImplementedException]::new('Invoke-Sdd henüz uygulanmadı.')
}

Invoke-Sdd
