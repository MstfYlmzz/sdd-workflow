<#
  ledger.ps1 — .sdd/state.json tek gerçek kaynak.
  tasks.md buradan RENDER edilir; asla tersine değil.
  Checkbox ile ledger çelişirse: biri 'done' diyorsa done kabul edilir
  (agent'ın kaybettiği işareti kurtarır, insan override'ını da onurlandırır).
#>

function Read-Ledger {
    param([string] $StatePath)
    # TODO: state.json oku -> nesne. Yoksa boş şablon döndür.
    throw [System.NotImplementedException]::new('Read-Ledger')
}

function Write-Ledger {
    param([object] $Ledger, [string] $StatePath)
    # TODO: nesneyi state.json'a yaz (atomik: temp'e yaz, sonra taşı).
    throw [System.NotImplementedException]::new('Write-Ledger')
}

function Get-PendingBatch {
    <#
      Sıradaki batch'i seçer: status=pending VE tüm depends_on'ları done olan
      task'lardan ilk batch_size tanesi. Loop'un otonom ilerlemesini sağlayan
      seçim burada.
    #>
    param([object] $Ledger, [int] $BatchSize)
    # TODO: bağımlılığı karşılanmış pending task'ları sırayla topla.
    throw [System.NotImplementedException]::new('Get-PendingBatch')
}

function Set-TaskStatus {
    <#
      Bir task'ın durumunu, attempts'ini, commit_sha'sını, son gate çıktısını
      günceller. Checkbox'ı AGENT DEĞİL bu fonksiyon (orkestratör) yazar.
    #>
    param(
        [object] $Ledger,
        [string] $TaskId,
        [ValidateSet('pending','done','blocked','superseded','manual')] [string] $Status,
        [hashtable] $Fields
    )
    # TODO: ledger'daki ilgili task'ı güncelle.
    throw [System.NotImplementedException]::new('Set-TaskStatus')
}

function Render-TasksMd {
    <#
      Ledger'dan tasks.md üretir. Format kullanıcının verdiği örneğe birebir:
        [ ] T001 <title>
        [x] T001 <title>        (done)
      blocked task'lar checkbox açık kalır ama altına yorum düşülür:
        [ ] T042 <title>
            <!-- blocked: 3 deneme, tier1 build, TS2307 -->
      Böylece dosyaya bakan "yapılmadı" ile "denendi düştü"yü ayırt eder.
    #>
    param([object] $Ledger, [string] $OutPath)
    # TODO: her task için satır üret; done -> [x], diğerleri -> [ ] + gerek' se yorum.
    throw [System.NotImplementedException]::new('Render-TasksMd')
}

function Set-DownstreamStale {
    <#
      Bir stage yeniden çalıştığında SONRAKİ stage'leri 'stale' işaretler.
      plan yeniden çalıştı -> tasks stale (loop, tasks yeniden üretilene dek başlamaz).
      Aynı stage'i düzeltme promptuyla tekrar çalıştırmak bunu TETİKLEMEZ;
      sadece geriye gitmek tetikler.
    #>
    param([object] $Ledger, [string] $ChangedStage)
    # TODO: stage sırasına göre sonrakileri stale yap.
    throw [System.NotImplementedException]::new('Set-DownstreamStale')
}

function Show-LedgerStatus {
    <#
      `sdd status`: ledger'ı okunur özet olarak basar — stage durumları,
      task sayıları (pending/done/blocked), varsa circuit breaker durumu.
    #>
    param([string] $StatePath)
    # TODO: özet tabloyu yazdır.
    throw [System.NotImplementedException]::new('Show-LedgerStatus')
}
