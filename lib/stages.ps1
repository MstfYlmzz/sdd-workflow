<#
  stages.ps1 — spec/plan/tasks/analyze stage'lerini çalıştırır ve
  agent/model/effort seçim arayüzünü yönetir.

  Stage sırası (stale mantığı buna dayanır):
    spec -> plan -> tasks -> analyze -> implement

  Spec Kit entegrasyonu (Yol A): orkestratör ilgili SKILL.md'yi okur,
  $ARGUMENTS'ı kullanıcı açıklamasıyla değiştirir, non-interactive kısıtını
  başa ekler ve tüm metni codex exec'e prompt olarak verir. Codex talimatları
  uygular; feature klasörünü, spec.md'yi vb. kendisi oluşturur. Çalışma sonrası
  orkestratör .specify/feature.json'dan üretilen yolu okur.
#>

Set-StrictMode -Version Latest

$script:StageOrder = @('spec','plan','tasks','analyze','implement')

# Stage adı -> Spec Kit skill klasörü eşlemesi
$script:StageSkill = @{
    spec    = 'speckit-specify'
    plan    = 'speckit-plan'
    tasks   = 'speckit-tasks'
    analyze = 'speckit-analyze'
}

# codex exec non-interactive olduğu için skill'in soru sormasını engelleyen
# kısıt. Her stage prompt'unun başına eklenir — "müdahalesiz" garantisinin kalbi.
$script:NonInteractivePreamble = @'
[ORKESTRATÖR KISITI — ÖNCE BUNU OKU]
Non-interactive bir oturumda çalışıyorsun. Kullanıcı YOK; hiçbir soru soramaz,
hiçbir onay bekleyemezsin. Aşağıdaki talimatlar kullanıcıya soru sormanı ya da
yanıt beklemeni isterse, BUNU YAPMA. Bunun yerine:
- Bağlam ve endüstri standartlarına dayalı makul varsayımlar yap.
- Kararlarını çıktının "Assumptions" bölümüne yaz.
- [NEEDS CLARIFICATION] marker'larını yalnızca gerçekten kritik kararlar için
  ve izin verilen üst sınır kadar bırak; gerisini varsayımla çöz.
- Asla "Wait for user response" adımında durma; devam et ve işi tamamla.
Tüm dosya/dizin işlemlerini kendin yap (mkdir, template kopyalama, dosya yazma).
Bittiğinde ürettiğin dosya yollarını raporla.

---

'@

function Show-AgentSelection {
    <#
      Akış başında kayıtlı seçimleri gösterir, Enter ile devam / d ile değiştir /
      r ile sıfırla. Değişiklik config.yaml'a geri yazılır (hafıza). Menü
      sağlayıcıya göre uyarlanır. (Bu tur: iskelet — bir sonraki turda tam UI.)
    #>
    param([object] $Config, [string] $ConfigPath)
    throw [System.NotImplementedException]::new('Show-AgentSelection (sonraki tur)')
}

function Get-StagePrompt {
    <#
      Bir stage için Codex'e gönderilecek tam prompt'u üretir (Yol A):
        1. .agents/skills/<skill>/SKILL.md oku
        2. $ARGUMENTS'ı kullanıcı açıklaması ile değiştir
        3. başına non-interactive kısıtı ekle
      Argüman boşsa (plan/tasks çoğu zaman argümansız çalışır) $ARGUMENTS
      yerine boş dize konur; skill zaten feature.json'dan bağlamı bulur.
    #>
    param(
        [Parameter(Mandatory)] [string] $ProjectRoot,
        [Parameter(Mandatory)] [string] $StageName,
        [string] $Arguments = ''
    )
    $skill = $script:StageSkill[$StageName]
    if (-not $skill) { throw "Bu stage için skill eşlemesi yok: $StageName" }

    $skillPath = Join-Path $ProjectRoot ".agents/skills/$skill/SKILL.md"
    if (-not (Test-Path -LiteralPath $skillPath)) {
        throw "SKILL.md bulunamadı: $skillPath. 'specify init --integration codex' çalıştırıldı mı?"
    }

    $body = Get-Content -LiteralPath $skillPath -Raw
    # $ARGUMENTS düz metin olarak geçiyor (regex değil) — literal değiştir
    $body = $body.Replace('$ARGUMENTS', $Arguments)

    return $script:NonInteractivePreamble + $body
}

function Get-FeatureDirectory {
    <#
      .specify/feature.json'dan üretilen feature klasörünü okur. spec stage'i
      bunu yazar; plan/tasks/analyze bundan feature'ı bulur. Orkestratör de
      çalışma sonrası spec.md/plan.md/tasks.md yolunu buradan öğrenir.
    #>
    param([Parameter(Mandatory)] [string] $ProjectRoot)
    $fj = Join-Path $ProjectRoot '.specify/feature.json'
    if (-not (Test-Path -LiteralPath $fj)) { return $null }
    $obj = Get-Content -LiteralPath $fj -Raw | ConvertFrom-Json
    if ($obj.PSObject.Properties.Name -contains 'feature_directory') {
        return (Join-Path $ProjectRoot $obj.feature_directory)
    }
    return $null
}

function Resolve-Adapter {
    <#
      Config'deki agent adına göre doğru adapter fonksiyonunu döndürür.
      Şimdilik yalnızca codex bağlı.
    #>
    param([Parameter(Mandatory)] [string] $AgentName)
    switch ($AgentName) {
        'codex'  { return 'Invoke-CodexAgent' }
        'claude' { throw 'claude adapteri henüz bağlı değil.' }
        'cursor' { throw 'cursor adapteri henüz bağlı değil.' }
        default  { throw "Bilinmeyen agent: $AgentName" }
    }
}

function Invoke-Stage {
    <#
      Tek bir stage'i çalıştırır (spec/plan/tasks/analyze). Akış:
        1. stage stale değilse ve önceki stage tamam değilse uyar
        2. config'den {agent,model,effort} al
        3. Get-StagePrompt ile prompt üret ($ARGUMENTS + kısıt)
        4. adapter'ı çağır (canlı akış + log)
        5. ok değilse hata; ok ise stage'i completed işaretle
        6. -Prompt varsa: aynı stage'i düzeltmeyle yeniden çalıştırma (stale
           tetiklemez). Geriye gidiş çağıran tarafın kararı (Set-DownstreamStale).
    #>
    param(
        [Parameter(Mandatory)] [ValidateSet('spec','plan','tasks','analyze')] [string] $Name,
        [Parameter(Mandatory)] [string] $ProjectRoot,
        [Parameter(Mandatory)] [object] $Config,
        [Parameter(Mandatory)] [object] $Ledger,
        [string] $Arguments = '',
        [string] $Prompt = '',
        [switch] $Resume
    )

    $paths = Get-SddPaths -ProjectRoot $ProjectRoot
    $profile = $Config.agents.$Name
    if (-not $profile) { throw "config.agents.$Name tanımlı değil." }

    $agentFn = Resolve-Adapter -AgentName $profile.agent
    $logPath = Join-Path $paths.LogsDir "$Name.log"

    # prompt gövdesi: skill metni; -Prompt verildiyse düzeltme talimatı olarak ekle
    $userArgs = $Arguments
    if ($Prompt) { $userArgs = "$Arguments`n`n[DÜZELTME TALİMATI]`n$Prompt" }
    $fullPrompt = Get-StagePrompt -ProjectRoot $ProjectRoot -StageName $Name -Arguments $userArgs

    # stage'i running işaretle
    $Ledger.stages.$Name.status = 'running'

    Write-SddLog -Message "[$Name] $($profile.agent)/$($profile.model)/$($profile.effort) başlıyor" -LogPath $logPath -Level 'info'

    $req = @{
        prompt   = $fullPrompt
        model    = $profile.model
        effort   = $profile.effort
        cwd      = $ProjectRoot
        log_path = $logPath
    }
    if ($Resume -and $Ledger.stages.$Name.PSObject.Properties.Name -contains 'session_id' -and $Ledger.stages.$Name.session_id) {
        $req.resume_session = $Ledger.stages.$Name.session_id
    }

    $res = & $agentFn -Request $req

    # session_id ve durum kaydı
    if ($res.session_id) {
        $Ledger.stages.$Name | Add-Member -NotePropertyName 'session_id' -NotePropertyValue $res.session_id -Force
    }
    $Ledger.stages.$Name | Add-Member -NotePropertyName 'agent'  -NotePropertyValue $profile.agent  -Force
    $Ledger.stages.$Name | Add-Member -NotePropertyName 'model'  -NotePropertyValue $profile.model  -Force
    $Ledger.stages.$Name | Add-Member -NotePropertyName 'effort' -NotePropertyValue $profile.effort -Force
    $Ledger.stages.$Name | Add-Member -NotePropertyName 'log_path' -NotePropertyValue $logPath -Force

    if (-not $res.ok) {
        $Ledger.stages.$Name.status = 'interrupted'
        Write-SddLog -Message "[$Name] BAŞARISIZ (denied: $(@($res.denied) -join '; '))" -LogPath $logPath -Level 'error'
        return [pscustomobject]@{ ok = $false; stage = $Name; result = $res }
    }

    $Ledger.stages.$Name.status = 'completed'
    $featureDir = Get-FeatureDirectory -ProjectRoot $ProjectRoot
    Write-SddLog -Message "[$Name] tamamlandı. feature: $featureDir" -LogPath $logPath -Level 'info'
    return [pscustomobject]@{ ok = $true; stage = $Name; feature_dir = $featureDir; result = $res }
}

function Invoke-Analyze {
    <#
      analyze stage'i: her zaman otonom koşar, yapılandırılmış bulgu üretir.
      config.analyze.block_on seviyesinde bulgu varsa loop'un durması için
      sinyal döndürür. (Bu tur: iskelet — loop turunda tamamlanacak.)
    #>
    param([object] $Config, [object] $Ledger, [string] $ProjectRoot)
    throw [System.NotImplementedException]::new('Invoke-Analyze (loop turunda)')
}
