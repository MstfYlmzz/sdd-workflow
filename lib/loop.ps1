<#
  loop.ps1 — otonom implement döngüsü. Diyagramdaki "otonom bölge".
  Tek invocation'a tüm task'ları vermez; küçük batch'ler halinde ilerler,
  her batch'i git baseline'a ve Tier 0 + Tier 1'e karşı doğrular.
  Checkbox'ı agent değil BU döngü yazar.
#>

function Invoke-ImplementLoop {
    <#
      Ana döngü. Akış (diyagramla birebir):

        analyze çalıştır -> kritik bulgu varsa DUR, insana dön
        gate baseline ölç (Measure-GateBaseline)
        while (bağımlılığı karşılanmış pending task var):
            batch    = Get-PendingBatch
            baseline = Get-GitBaseline
            adapter'ı batch ile çalıştır (canlı akış + log)
            foreach task in batch:
                t0 = Invoke-Tier0 (baseline, task)
                if t0.ok:
                    Set-TaskStatus done (commit_sha, evidence)   # ORKESTRATÖR yazar
                else:
                    task.attempts++
                    if attempts == escalate_at: daha güçlü model/effort ile retry sırala
                    if attempts >= max_attempts: Set-TaskStatus blocked (t0.hard_fails)
            t1 = Invoke-Tier1 (baseline sonrası bütün batch için)
            if not t1.ok:
                repair task üret (t1.output) -> sıradaki batch'in başına
            Render-TasksMd  (ledger -> tasks.md, her batch sonrası)
            ardışık hata sayacını güncelle
            if ardışık hata >= circuit_breaker: DUR, insana dön
            if observe_every > 0 and batch % observe_every == 0: DUR, devamı bekle

      Döngü şu üç durumda insana döner (diyagramdaki "Sen devralırsın"):
        - tüm task'lar done + Tier 1 temiz + tree temiz
        - blocked task var (max_attempts doldu)
        - circuit breaker (ardışık batch hatası)
      manual task'lar döngüye HİÇ girmez; ayrı kuyrukta bekler.

      İdempotent: tekrar çalıştırmak = resume. done task'lar atlanır.
      Yani "beğenmediğim için yeni task ekledim" senaryosunda döngü sadece
      yeni pending task'ları yapar, eski işe dokunmaz.
    #>
    param([object] $Config, [object] $Ledger, [int] $ObserveEvery = -1)
    # TODO: yukarıdaki akış.
    throw [System.NotImplementedException]::new('Invoke-ImplementLoop')
}

function New-RepairTask {
    <#
      Tier 1 bir batch sonrası kırıldığında, hatayı düzeltmek için yeni bir
      task üretir ve sıradaki batch'in BAŞINA koyar. Yeni ID alır (mevcut en
      yüksek T### + 1). Böylece build hatası döngüyü durdurmaz, sıraya girer.
    #>
    param([object] $Ledger, [string] $GateOutput)
    # TODO: yeni T### task'ı oluştur, başa ekle.
    throw [System.NotImplementedException]::new('New-RepairTask')
}

function Get-EscalatedProfile {
    <#
      Bir task escalate_at denemesine ulaştığında, config'deki {agent,model,
      effort}'un daha güçlü bir varyantını döndürür (ör. medium->high, ya da
      daha güçlü model). Failover listesi de burada: session/rate limit
      pattern'i görülürse sıradaki sağlayıcıya geç, döngüyü durdurma.
    #>
    param([object] $BaseProfile, [int] $Attempt)
    # TODO: effort/model yükselt ya da sıradaki sağlayıcıya düş.
    throw [System.NotImplementedException]::new('Get-EscalatedProfile')
}
