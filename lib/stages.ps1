<#
  stages.ps1 — spec/plan/tasks/analyze stage'lerini çalıştırır ve
  agent/model/effort seçim arayüzünü yönetir.

  Stage sırası (stale mantığı buna dayanır):
    spec -> plan -> tasks -> analyze -> implement -> converge

  Spec Kit entegrasyonu (Yol A): orkestratör ilgili SKILL.md'yi okur,
  $ARGUMENTS'ı kullanıcı açıklamasıyla değiştirir, non-interactive kısıtını
  başa ekler ve tüm metni codex exec'e prompt olarak verir. Codex talimatları
  uygular; feature klasörünü, spec.md'yi vb. kendisi oluşturur. Çalışma sonrası
  orkestratör .specify/feature.json'dan üretilen yolu okur.
#>

Set-StrictMode -Version Latest

$script:StageOrder = @('spec','plan','tasks','analyze','implement','converge')

# Stage adı -> Spec Kit skill klasörü eşlemesi
$script:StageSkill = @{
    spec    = 'speckit-specify'
    plan    = 'speckit-plan'
    tasks   = 'speckit-tasks'
    analyze = 'speckit-analyze'
    converge = 'speckit-converge'
}

# codex exec non-interactive olduğu için skill'in soru sormasını engelleyen
# kısıt. Her stage prompt'unun başına eklenir — "müdahalesiz" garantisinin kalbi.
# Her stage için, o stage'in ürettiği artifact ve dokunmaması gerekenler.
# "Stage sızması" (spec çağrısının plan+tasks da yapması) bununla engellenir.
$script:StageScope = @{
    spec    = @{ produces = 'spec.md';  forbid = 'plan.md, tasks.md, research.md, data-model.md ya da başka herhangi bir sonraki-aşama dosyası' }
    plan    = @{ produces = 'plan.md ve tasarım artefaktları (research.md, data-model.md, contracts/, quickstart.md)'; forbid = 'tasks.md' }
    tasks   = @{ produces = 'tasks.md';  forbid = 'kod implementasyonu ya da herhangi bir kaynak dosya' }
    analyze = @{ produces = 'analiz raporu';  forbid = 'spec.md, plan.md, tasks.md üzerinde herhangi bir değişiklik' }
    converge = @{ produces = 'yalnızca gerekliyse tasks.md sonuna append-only Convergence fazı'; forbid = 'uygulama kodu, spec.md, plan.md veya mevcut task satırlarında herhangi bir değişiklik' }
}

function Get-NonInteractivePreamble {
    <#
      Stage'e özel orkestratör kısıtı. İki şeyi zorlar:
        1. Non-interactive: soru sorma, varsayımla ilerle.
        2. STAGE İZOLASYONU: yalnızca bu stage'in artifact'ini üret, sonraki
           stage'lere GEÇME. Skill'lerin "sonraki komut: $speckit-plan" gibi
           zincirleme yönlendirmelerini görmezden gel. Bu, stage'lerin ayrı
           kalmasını ve ledger ile diskin tutarlı olmasını sağlar.
    #>
    param([Parameter(Mandatory)] [string] $StageName)
    $scope = $script:StageScope[$StageName]
    $produces = if ($scope) { $scope.produces } else { 'yalnızca bu stage için istenen dosya' }
    $forbid   = if ($scope) { $scope.forbid } else { 'sonraki aşamalara ait dosyalar' }

    return @"
[ORKESTRATÖR KISITI — ÖNCE BUNU OKU, SONRA AŞAĞIDAKİ SKILL TALİMATINI UYGULA]

1) STAGE İZOLASYONU (EN ÖNEMLİ KURAL):
   Sen YALNIZCA '$StageName' aşamasını çalıştırıyorsun. Üreteceğin tek çıktı: $produces.
   ŞUNLARI YAPMA: $forbid.
   Aşağıdaki skill talimatı seni başka bir aşamaya yönlendirebilir ("Önerilen
   sonraki komut: `$speckit-...", "Next phase", "proceed to plan/tasks" gibi).
   BU YÖNLENDİRMELERİ YOK SAY. Başka skill çağırma, başka aşamaya geçme.
   Yalnızca bu aşamayı bitir ve dur. Bir sonraki aşamayı orkestratör ayrı bir
   komutla başlatacak.

2) NON-INTERACTIVE:
   Kullanıcı YOK; soru soramaz, onay bekleyemezsin. Skill kullanıcıya soru
   sormanı isterse BUNU YAPMA. Bunun yerine:
   - Bağlam ve endüstri standartlarına dayalı makul varsayımlar yap.
   - Kararlarını çıktının "Assumptions" bölümüne yaz.
   - [NEEDS CLARIFICATION] marker'larını yalnızca gerçekten kritik kararlar için
     ve izin verilen üst sınır kadar bırak; gerisini varsayımla çöz.
   - Asla "Wait for user response" adımında durma; devam et ve işi tamamla.

Tüm dosya/dizin işlemlerini kendin yap. Bittiğinde ürettiğin dosya yollarını
raporla ve DUR.

---

"@
}

function Get-StageProfile {
    param(
        [Parameter(Mandatory)] [object] $Config,
        [Parameter(Mandatory)] [string] $StageName,
        [string] $Agent, [string] $Model, [string] $Effort
    )
    $saved = $Config.agents.$StageName
    if (-not $saved) { throw "config.agents.$StageName tanımlı değil." }
    [pscustomobject]@{
        agent = $(if ($Agent) { $Agent } else { [string]$saved.agent })
        model = $(if ($Model) { $Model } else { [string]$saved.model })
        effort = $(if ($Effort) { $Effort } else { [string]$saved.effort })
        override = [bool]($Agent -or $Model -or $Effort)
    }
}

function Set-SddStageProfile {
    <# config.yaml yorumlarını koruyarak tek stage'in inline routing satırını atomik günceller. #>
    param(
        [Parameter(Mandatory)] [string] $ConfigPath,
        [Parameter(Mandatory)] [ValidateSet('spec','plan','tasks','analyze','implement','converge')] [string] $StageName,
        [Parameter(Mandatory)] [ValidateSet('codex','claude','cursor')] [string] $Agent,
        [Parameter(Mandatory)] [string] $Model,
        [Parameter(Mandatory)] [string] $Effort
    )
    if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "config.yaml bulunamadı: $ConfigPath" }
    $text = Get-Content -LiteralPath $ConfigPath -Raw
    $line = "  ${StageName}:".PadRight(13) + "{ agent: $Agent, model: $Model, effort: $Effort }"
    $pattern = "(?m)^\s{2}" + [regex]::Escape($StageName) + ":\s*\{[^\r\n]*\}\s*$"
    if ([regex]::IsMatch($text, $pattern)) {
        $next = [regex]::Replace($text, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $line }, 1)
    } else {
        $agentsMatch = [regex]::Match($text, '(?ms)^agents:\s*\r?\n(?<body>(?:^\s{2}[^\r\n]*\r?\n)+)')
        if (-not $agentsMatch.Success) { throw 'config.yaml agents bloğu bulunamadı.' }
        $body = $agentsMatch.Groups['body'].Value
        $replacement = 'agents:' + [Environment]::NewLine + $body.TrimEnd("`r","`n") + [Environment]::NewLine + $line + [Environment]::NewLine
        $next = $text.Substring(0,$agentsMatch.Index) + $replacement + $text.Substring($agentsMatch.Index + $agentsMatch.Length)
    }
    $tmp = "$ConfigPath.tmp"
    Set-Content -LiteralPath $tmp -Value $next -Encoding utf8 -NoNewline
    try { $null = Read-SddConfig -ConfigPath $tmp }
    catch { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue; throw "Yeni config doğrulanamadı: $($_.Exception.Message)" }
    Move-Item -LiteralPath $tmp -Destination $ConfigPath -Force
    return (Read-SddConfig -ConfigPath $ConfigPath)
}

function Get-SddAgentCapabilities {
    param([Parameter(Mandatory)] [ValidateSet('codex','claude','cursor')] [string] $Agent)
    $command = switch ($Agent) { 'cursor' { 'agent' }; default { $Agent } }
    $found = Get-Command $command -ErrorAction SilentlyContinue
    [pscustomobject]@{
        agent = $Agent; command = $command; available = [bool]$found
        supports_effort = ($Agent -ne 'cursor')
        supports_resume = $true
        supports_model_list = ($Agent -eq 'cursor')
    }
}

function Select-SddMenuItem {
    <# Windows Terminal dahil gerçek bir ↑/↓ menüsü. String veya {label,value} nesnesi kabul eder. #>
    param(
        [Parameter(Mandatory)] [string] $Title,
        [Parameter(Mandatory)] [object[]] $Items,
        [string] $SelectedValue = ''
    )
    $choices=@($Items|ForEach-Object{
        if($_-is[string]){[pscustomobject]@{label=[string]$_;value=[string]$_}}
        else{[pscustomobject]@{label=[string]$_.label;value=[string]$_.value}}
    })
    if($choices.Count-eq0){throw "Menü boş: $Title"}
    $index=0
    for($i=0;$i-lt$choices.Count;$i++){if($choices[$i].value-eq$SelectedValue){$index=$i;break}}
    $interactive=$false;try{$interactive=-not[Console]::IsInputRedirected-and-not[Console]::IsOutputRedirected}catch{}
    if(-not$interactive){
        Write-Host "`n$Title";for($i=0;$i-lt$choices.Count;$i++){Write-Host "  [$($i+1)] $($choices[$i].label)"}
        $answer=Read-Host "Seçim [1-$($choices.Count)]"
        $number=0;if(-not[int]::TryParse($answer,[ref]$number)-or$number-lt1-or$number-gt$choices.Count){throw 'Geçersiz seçim.'}
        return $choices[$number-1].value
    }
    $esc=[char]27
    try{
        Write-Host -NoNewline "$esc[?1049h$esc[?25l"
        while($true){
            Write-Host -NoNewline "$esc[H$esc[2J"
            Write-Host $Title -ForegroundColor Cyan
            Write-Host '↑/↓ seç · Home/End · Enter onayla · Esc iptal' -ForegroundColor DarkGray
            $height=try{[Math]::Max(3,[Console]::WindowHeight-4)}catch{15}
            $start=[Math]::Min([Math]::Max(0,$index-$height+1),[Math]::Max(0,$choices.Count-$height))
            $end=[Math]::Min($choices.Count,$start+$height)
            for($i=$start;$i-lt$end;$i++){
                $prefix=if($i-eq$index){'❯ '}else{'  '}
                $text=$prefix+$choices[$i].label;$width=[Math]::Max(1,[Console]::WindowWidth-1)
                if($text.Length-gt$width){$text=$text.Substring(0,$width)}
                Write-Host $text -ForegroundColor $(if($i-eq$index){'Cyan'}else{'Gray'})
            }
            if($choices.Count-gt$height){Write-Host "Gösterilen $($start+1)-$end / $($choices.Count)" -ForegroundColor DarkGray}
            $key=[Console]::ReadKey($true)
            switch($key.Key){
                'UpArrow'{$index=($index-1+$choices.Count)%$choices.Count}
                'DownArrow'{$index=($index+1)%$choices.Count}
                'Home'{$index=0};'End'{$index=$choices.Count-1}
                'Enter'{return $choices[$index].value}
                'Escape'{throw 'Seçim iptal edildi.'}
            }
        }
    }finally{Write-Host -NoNewline "$esc[?25h$esc[?1049l"}
}

function Get-SddAgentModels {
    param([Parameter(Mandatory)] [ValidateSet('codex','claude','cursor')] [string] $Agent,[string]$CurrentModel='')
    $fallback=switch($Agent){'claude'{@('sonnet','opus','haiku')};'codex'{@('gpt-5.6-sol','gpt-5.6-terra','gpt-5.6-luna')};default{@('auto')}}
    $cap=Get-SddAgentCapabilities -Agent $Agent;$discovered=@()
    if($cap.available){
        try{
            if($Agent-eq'cursor'){$output=@(& $cap.command --list-models 2>$null);if($LASTEXITCODE-eq0){$discovered=$output}}
            else{
                $help=@(& $cap.command --help 2>$null)
                if(($help-join"`n")-match'(?mi)^\s+models?\s'){$output=@(& $cap.command models 2>$null);if($LASTEXITCODE-eq0){$discovered=$output}}
            }
        }catch{}
    }
    $parsed=@($discovered|ForEach-Object{([string]$_).Trim()-replace'^[>*\-\s]+',''}|ForEach-Object{($_-split'\s+')[0]}|Where-Object{$_-match'^[A-Za-z0-9][A-Za-z0-9._:/-]+$'-and$_-notmatch'(?i)^available$'})
    return @(@($CurrentModel)+@($fallback)+@($parsed)|Where-Object{$_}|Select-Object -Unique)
}

function Show-AgentSelection {
    <#
      Akış başında kayıtlı seçimleri gösterir, Enter ile devam / d ile değiştir /
      r ile sıfırla. Değişiklik config.yaml'a geri yazılır (hafıza). Menü
      sağlayıcıya göre uyarlanır.
    #>
    param(
        [Parameter(Mandatory)] [object] $Config,
        [Parameter(Mandatory)] [string] $ConfigPath,
        [AllowEmptyString()] [string] $StageName,
        [switch] $RunOnly
    )
    if ([string]::IsNullOrWhiteSpace($StageName)) { $StageName='all' }
    if($StageName-notin(@('all')+$script:StageOrder)){throw "Geçersiz stage: $StageName. Beklenen: all, $($script:StageOrder -join ', ')"}
    if($StageName-eq'all'){
        $profiles=[ordered]@{}
        foreach($name in $script:StageOrder){
            $Config=Read-SddConfig -ConfigPath $ConfigPath
            $profiles[$name]=Show-AgentSelection -Config $Config -ConfigPath $ConfigPath -StageName $name -RunOnly:$RunOnly
        }
        return [pscustomobject]$profiles
    }
    $saved = Get-StageProfile -Config $Config -StageName $StageName
    Write-Host "`n[$StageName] kayıtlı: $($saved.agent)/$($saved.model)/$($saved.effort)"
    $agentItems=@()
    foreach ($provider in @('codex','claude','cursor')) {
        $cap = Get-SddAgentCapabilities -Agent $provider
        $mark = if ($cap.available) { 'hazır' } else { 'kurulu değil' }
        $agentItems+=[pscustomobject]@{label=('{0,-7} [{1}]'-f$provider,$mark);value=$provider}
    }
    $agent=Select-SddMenuItem -Title "[$StageName] Agent" -Items $agentItems -SelectedValue $saved.agent
    $models=@(Get-SddAgentModels -Agent $agent -CurrentModel $(if($agent-eq$saved.agent){$saved.model}else{''}))
    $modelItems=@($models|ForEach-Object{[pscustomobject]@{label=$_;value=$_}})+@([pscustomobject]@{label='Özel model adı…';value='__custom__'})
    $model=Select-SddMenuItem -Title "[$StageName] Model ($agent)" -Items $modelItems -SelectedValue $(if($agent-eq$saved.agent){$saved.model}else{$models[0]})
    if($model-eq'__custom__'){$model=Read-Host 'Model adı';if([string]::IsNullOrWhiteSpace($model)){throw 'Model adı boş olamaz.'}}
    $efforts=if($agent-eq'cursor'){@([pscustomobject]@{label='medium (Cursor CLI effort bayrağı sunmuyor; metadata)';value='medium'})}else{@('low','medium','high','xhigh','max')|ForEach-Object{[pscustomobject]@{label=$_;value=$_}}}
    $effort=Select-SddMenuItem -Title "[$StageName] Effort" -Items $efforts -SelectedValue $(if($agent-eq$saved.agent){$saved.effort}else{'medium'})
    $profile = [pscustomobject]@{agent=$agent;model=$model;effort=$effort;override=[bool]$RunOnly}
    if (-not $RunOnly) {
        $Config = Set-SddStageProfile -ConfigPath $ConfigPath -StageName $StageName -Agent $agent -Model $model -Effort $effort
        Write-Host "Kaydedildi: $StageName -> $agent/$model/$effort" -ForegroundColor Green
    } else { Write-Host "Yalnız bu çalışma: $agent/$model/$effort" -ForegroundColor Yellow }
    return $profile
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

    $contract = if ($StageName -eq 'analyze') {
@"

[ZORUNLU ANALYZE ÇIKTI SÖZLEŞMESİ]
Analiz read-only olmalıdır; hiçbir repo dosyasını değiştirme veya commit üretme.
Normal analiz raporundan sonra EN SON SATIRDA tam olarak şu biçimde kompakt JSON yaz:
SDD_ANALYZE_RESULT {"highest_severity":"none|info|warning|critical","finding_count":0,"summary":"kısa özet"}
highest_severity en ağır gerçek bulguyu göstermeli; bulgu yoksa none kullan.
Bu son satır olmadan stage başarısız sayılacaktır.
"@
    } elseif ($StageName -eq 'converge') {
@"

[ZORUNLU CONVERGE ÇIKTI SÖZLEŞMESİ]
Yukarıdaki Spec Kit converge davranışını aynen uygula. Hiçbir commit üretme.
Normal raporundan sonra EN SON SATIRDA tam olarak şu biçimlerden birini yaz:
SDD_CONVERGE_RESULT {"outcome":"converged","tasks_appended":0,"summary":"kısa özet"}
SDD_CONVERGE_RESULT {"outcome":"tasks_appended","tasks_appended":3,"summary":"kısa özet"}
Bu makine-okunur satır semantik kararını değiştirmez; yalnız orkestratör handoff'udur.
"@
    } else { '' }

    return (Get-NonInteractivePreamble -StageName $StageName) + $body + $contract
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
      Adapter dosyaları bin/sdd.ps1 tarafından önceden dot-source edilir.
    #>
    param([Parameter(Mandatory)] [string] $AgentName)
    switch ($AgentName) {
        'codex'  { return 'Invoke-CodexAgent' }
        'claude' { return 'Invoke-ClaudeAgent' }
        'cursor' { return 'Invoke-CursorAgent' }
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
        [switch] $Resume,
        [object] $ProfileOverride
    )

    $paths = Get-SddPaths -ProjectRoot $ProjectRoot
    $profile = if ($ProfileOverride) { $ProfileOverride } else { $Config.agents.$Name }
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
        stream_partial = (Test-SddPartialStreaming)
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

    # tasks stage'i bittiğinde üretilen tasks.md'yi ledger'a yükle. Loop'un
    # girdisi budur; bu olmadan "0 task" kalır.
    if ($Name -eq 'tasks' -and $featureDir) {
        $tasksMd = Join-Path $featureDir 'tasks.md'
        if (Test-Path -LiteralPath $tasksMd) {
            $Ledger = Import-TasksToLedger -Ledger $Ledger -TasksMdPath $tasksMd
            $n = @(Get-LedgerTasks $Ledger).Count
            Write-SddLog -Message "[tasks] $n task ledger'a yüklendi" -LogPath $logPath -Level 'info'
        } else {
            Write-SddLog -Message "[tasks] UYARI: tasks.md bulunamadı, ledger'a task yüklenemedi" -LogPath $logPath -Level 'warn'
        }
    }

    Write-SddLog -Message "[$Name] tamamlandı. feature: $featureDir" -LogPath $logPath -Level 'info'
    return [pscustomobject]@{ ok = $true; stage = $Name; feature_dir = $featureDir; result = $res }
}

function Invoke-Analyze {
    <#
      analyze stage'i: her zaman otonom koşar, yapılandırılmış bulgu üretir.
      config.analyze.block_on seviyesinde bulgu varsa loop'un durması için
      sinyal döndürür. Agent'ın son mesajındaki zorunlu JSON sözleşmesini
      ayrıştırır ve read-only kuralını git kanıtıyla doğrular.
    #>
    param(
        [Parameter(Mandatory)] [object] $Config,
        [Parameter(Mandatory)] [object] $Ledger,
        [Parameter(Mandatory)] [string] $ProjectRoot,
        [switch] $Force,
        [object] $ProfileOverride
    )

    function Get-AnalyzeValue([object] $Object, [string] $Name, $Default = $null) {
        if ($null -eq $Object) { return $Default }
        if ($Object -is [System.Collections.IDictionary] -and $Object.Contains($Name)) { return $Object[$Name] }
        if ($Object.PSObject.Properties.Name -contains $Name) { return $Object.$Name }
        return $Default
    }
    function Test-AnalyzeThreshold([string] $Severity, [string] $BlockOn) {
        if ($BlockOn -eq 'never') { return $false }
        $rank = @{ none = 0; info = 1; warning = 2; critical = 3 }
        if (-not $rank.ContainsKey($Severity)) { return $true }
        if (-not $rank.ContainsKey($BlockOn)) { $BlockOn = 'critical' }
        return $rank[$Severity] -ge $rank[$BlockOn]
    }

    $stage = $Ledger.stages.analyze
    $blockOn = [string](Get-AnalyzeValue -Object (Get-AnalyzeValue -Object $Config -Name 'analyze') -Name 'block_on' -Default 'critical')
    $savedSeverity = [string](Get-AnalyzeValue -Object $stage -Name 'highest_severity' -Default '')
    if (-not $Force -and $stage.status -eq 'completed' -and $savedSeverity) {
        return [pscustomobject]@{
            ok = $true; blocked = (Test-AnalyzeThreshold -Severity $savedSeverity -BlockOn $blockOn)
            severity = $savedSeverity; finding_count = [int](Get-AnalyzeValue -Object $stage -Name 'finding_count' -Default 0)
            summary = [string](Get-AnalyzeValue -Object $stage -Name 'summary' -Default '')
            reused = $true; output = $null
        }
    }

    $baseline = Get-GitBaseline -ProjectRoot $ProjectRoot
    $beforeDirty = @(Get-GitStatusForTier0 -ProjectRoot $ProjectRoot)
    if ($beforeDirty.Count -gt 0) {
        return [pscustomobject]@{ ok = $false; blocked = $true; severity = 'critical'; output = "Analyze temiz çalışma ağacı gerektirir: $($beforeDirty -join ' | ')" }
    }

    $run = Invoke-Stage -Name 'analyze' -ProjectRoot $ProjectRoot -Config $Config -Ledger $Ledger -ProfileOverride $ProfileOverride
    if (-not $run.ok) {
        return [pscustomobject]@{ ok = $false; blocked = $true; severity = 'critical'; output = 'Analyze agent çalışması tamamlanmadı.' }
    }

    $afterHead = Get-GitBaseline -ProjectRoot $ProjectRoot
    $afterDirty = @(Get-GitStatusForTier0 -ProjectRoot $ProjectRoot)
    if ($afterHead -ne $baseline -or $afterDirty.Count -gt 0) {
        $stage.status = 'interrupted'
        $detail = if ($afterHead -ne $baseline) { 'Analyze commit üretti.' } else { "Analyze dosya değiştirdi: $($afterDirty -join ' | ')" }
        $stage | Add-Member -NotePropertyName stop_reason -NotePropertyValue 'analyze_not_read_only' -Force
        $stage | Add-Member -NotePropertyName last_error -NotePropertyValue $detail -Force
        return [pscustomobject]@{ ok = $false; blocked = $true; severity = 'critical'; output = $detail }
    }

    $message = [string](Get-AnalyzeValue -Object $run.result -Name 'last_message' -Default '')
    $match = [regex]::Match($message, '(?m)^SDD_ANALYZE_RESULT\s+(\{[^\r\n]+\})\s*$')
    if (-not $match.Success) {
        $stage.status = 'interrupted'
        $stage | Add-Member -NotePropertyName stop_reason -NotePropertyValue 'analyze_contract_missing' -Force
        $stage | Add-Member -NotePropertyName last_error -NotePropertyValue 'SDD_ANALYZE_RESULT satırı bulunamadı.' -Force
        return [pscustomobject]@{ ok = $false; blocked = $true; severity = 'critical'; output = 'Analyze çıktısında zorunlu SDD_ANALYZE_RESULT satırı yok.' }
    }
    try { $report = $match.Groups[1].Value | ConvertFrom-Json -ErrorAction Stop }
    catch {
        $stage.status = 'interrupted'
        $stage | Add-Member -NotePropertyName stop_reason -NotePropertyValue 'analyze_contract_invalid' -Force
        $stage | Add-Member -NotePropertyName last_error -NotePropertyValue $_.Exception.Message -Force
        return [pscustomobject]@{ ok = $false; blocked = $true; severity = 'critical'; output = "Analyze JSON geçersiz: $($_.Exception.Message)" }
    }

    $severity = ([string]$report.highest_severity).ToLowerInvariant()
    if ($severity -notin @('none','info','warning','critical')) {
        $stage.status = 'interrupted'
        return [pscustomobject]@{ ok = $false; blocked = $true; severity = 'critical'; output = "Geçersiz analyze severity: $severity" }
    }
    $count = [Math]::Max(0, [int]$report.finding_count)
    $summary = [string]$report.summary
    $stage | Add-Member -NotePropertyName highest_severity -NotePropertyValue $severity -Force
    $stage | Add-Member -NotePropertyName finding_count -NotePropertyValue $count -Force
    $stage | Add-Member -NotePropertyName summary -NotePropertyValue $summary -Force
    $stage | Add-Member -NotePropertyName stop_reason -NotePropertyValue 'completed' -Force
    $stage | Add-Member -NotePropertyName last_error -NotePropertyValue $null -Force

    return [pscustomobject]@{
        ok = $true; blocked = (Test-AnalyzeThreshold -Severity $severity -BlockOn $blockOn)
        severity = $severity; finding_count = $count; summary = $summary; reused = $false; output = $null
    }
}
