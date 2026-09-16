<#
  stages.ps1 — spec/plan/tasks/analyze stage'lerini çalıştırır ve
  agent/model/effort seçim arayüzünü yönetir.

  Stage'lerin sırası (stale mantığı buna dayanır):
    spec -> plan -> tasks -> analyze -> implement
#>

$script:StageOrder = @('spec','plan','tasks','analyze','implement')

function Show-AgentSelection {
    <#
      Akış başında kayıtlı seçimleri gösterir:

        Kayıtlı seçimler:
          spec       claude / opus   / high
          plan       claude / opus   / high
          tasks      codex  / gpt-5  / medium
          ...
        [Enter] devam   [d] değiştir   [r] sıfırla

      Enter -> mevcut config'le devam (hafıza: yeniden seçmezsin).
      d     -> stage seç, sonra agent -> model -> effort menüsü. Menü
               sağlayıcıya göre uyarlanır (Codex'te effort low/medium/high,
               Claude'da model+thinking, Cursor kendi karşılığı).
      r     -> config'i default'a döndür.
      Değişiklik config.yaml'a geri YAZILIR.
    #>
    param([object] $Config, [string] $ConfigPath)
    # TODO: interaktif menü; seçim değişirse Read/Write-SddConfig ile kaydet.
    throw [System.NotImplementedException]::new('Show-AgentSelection')
}

function Invoke-Stage {
    <#
      Tek bir stage'i çalıştırır (spec/plan/tasks/analyze).
      Akış:
        1. Bağımlılık kontrolü: bir önceki stage completed mı? (stale değilse)
        2. Config'den bu stage'in {agent,model,effort}'unu al.
        3. -Prompt verildiyse: aynı stage'i düzeltme talimatıyla yeniden çalıştır.
           Bu geriye gitmek DEĞİL, aynı yerde iterasyon -> stale tetiklemez.
        4. -Resume verildiyse: interrupted stage'i session_id ile sürdür
           (adapter destekliyorsa; yoksa baştan çalıştır).
        5. İlgili adapter'ı çağır, çıktıyı canlı akıt + logla.
        6. Bittiğinde stage'i completed işaretle; geriye gidildiyse
           Set-DownstreamStale çağır.
    #>
    param(
        [ValidateSet('spec','plan','tasks','analyze')] [string] $Name,
        [string] $Prompt,
        [switch] $Resume,
        [object] $Config,
        [object] $Ledger
    )
    # TODO: yukarıdaki akış.
    throw [System.NotImplementedException]::new("Invoke-Stage:$Name")
}

function Resolve-Adapter {
    <#
      Config'deki agent adına göre doğru adapter fonksiyonunu döndürür.
      claude -> Invoke-ClaudeAgent, codex -> Invoke-CodexAgent, cursor -> ...
      Her adapter aynı SÖZLEŞMEYİ konuşur (bkz. adapters/*.ps1):
        girdi:  {prompt, model, effort, resume_session, cwd, log_path}
        çıktı:  {ok, session_id, stream, denied[]}
    #>
    param([string] $AgentName)
    # TODO: ada göre adapter fonksiyon referansı döndür.
    throw [System.NotImplementedException]::new('Resolve-Adapter')
}

function Invoke-Analyze {
    <#
      analyze stage'i: spec/plan/tasks'ı birbirine karşı tutarlılık için tarar,
      YAPILANDIRILMIŞ bulgu üretir (severity, target_artifact, location).
      Her zaman otonom koşar. config.analyze.block_on seviyesinde ya da üstünde
      bulgu varsa loop'un durması için sinyal döndürür; yoksa sessizce geçer.
      Analyze KOD YAZMAZ, sadece rapor üretir.
    #>
    param([object] $Config, [object] $Ledger)
    # TODO: adapter'ı analyze promptuyla çağır; bulguları ayrıştır; block sinyali üret.
    throw [System.NotImplementedException]::new('Invoke-Analyze')
}
