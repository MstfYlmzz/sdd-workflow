<#
  ledger.ps1 — .sdd/state.json tek gerçek kaynak.
  tasks.md buradan RENDER edilir; asla tersine değil.
  Checkbox ile ledger çelişirse: biri 'done' diyorsa done kabul edilir.
#>

Set-StrictMode -Version Latest

$script:StageOrder = @('spec','plan','tasks','analyze','implement','converge')

function Update-LedgerShape {
    <# Eski state.json dosyalarını geriye uyumlu biçimde bellekte genişletir. #>
    param([Parameter(Mandatory)] [object] $Ledger)
    if (-not ($Ledger.PSObject.Properties.Name -contains 'stages') -or $null -eq $Ledger.stages) {
        $Ledger | Add-Member -NotePropertyName stages -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    foreach ($name in $script:StageOrder) {
        if (-not ($Ledger.stages.PSObject.Properties.Name -contains $name)) {
            $value = if ($name -eq 'converge') { [pscustomobject]@{status='not_started';round=0} } else { [pscustomobject]@{status='not_started'} }
            $Ledger.stages | Add-Member -NotePropertyName $name -NotePropertyValue $value -Force
        }
    }
    if (-not ($Ledger.PSObject.Properties.Name -contains 'gate_baseline')) {
        $Ledger | Add-Member -NotePropertyName gate_baseline -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    if (-not ($Ledger.PSObject.Properties.Name -contains 'tasks')) {
        $Ledger | Add-Member -NotePropertyName tasks -NotePropertyValue @() -Force
    }
    return $Ledger
}

function Read-Ledger {
    param([Parameter(Mandatory)] [string] $StatePath)
    if (-not (Test-Path -LiteralPath $StatePath)) {
        throw "state.json bulunamadı: $StatePath. Önce 'sdd init' çalıştır."
    }
    $ledger = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
    return (Update-LedgerShape -Ledger $ledger)
}

function Write-Ledger {
    <#
      Nesneyi state.json'a yazar. Atomik: önce .tmp'ye yaz, sonra taşı ki
      yazma yarıda kesilirse dosya bozulmasın.
    #>
    param(
        [Parameter(Mandatory)] [object] $Ledger,
        [Parameter(Mandatory)] [string] $StatePath
    )
    $Ledger = Update-LedgerShape -Ledger $Ledger
    $tmp = "$StatePath.tmp"
    $Ledger | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $tmp -Encoding utf8
    Move-Item -LiteralPath $tmp -Destination $StatePath -Force
}

function Get-SddActiveSpecId {
    param([Parameter(Mandatory)] [string] $ProjectRoot)
    $path=Join-Path $ProjectRoot '.specify/feature.json'
    if(-not(Test-Path -LiteralPath $path)){return $null}
    try{$feature=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json;$dir=([string]$feature.feature_directory).TrimEnd('/','\');if($dir){return (Split-Path -Leaf $dir)}}catch{}
    return $null
}

function Get-SddSpecCatalog {
    param([Parameter(Mandatory)] [string] $ProjectRoot)
    $active=Get-SddActiveSpecId -ProjectRoot $ProjectRoot
    foreach($dir in @(Get-ChildItem -LiteralPath (Join-Path $ProjectRoot 'specs') -Directory -ErrorAction SilentlyContinue|Sort-Object Name)){
        $total=0;$done=0;$taskFile=Join-Path $dir.FullName 'tasks.md'
        if(Test-Path -LiteralPath $taskFile){$lines=@(Get-Content -LiteralPath $taskFile);$total=@($lines|Where-Object{$_-match'^\s*-\s*\[[ xX]\]\s*T\d+'}).Count;$done=@($lines|Where-Object{$_-match'^\s*-\s*\[[xX]\]\s*T\d+'}).Count}
        [pscustomobject]@{id=$dir.Name;active=($dir.Name-eq$active);tasks=$total;done=$done;path=$dir.FullName}
    }
}

function Get-LedgerTasks {
    <#
      Ledger'daki task'ları düz, enumerate edilebilir bir koleksiyon olarak
      döndürür. ConvertFrom-Json boş diziyi $null ya da tek öğeyi tekil nesne
      yapabildiği için, çağıran taraf sonucu @(...) ile sararak sayar/gezinir.
      (Buradan `,@()` ile dönmek iç içe dizi yaratıp Where-Object'i bozar.)
    #>
    param([object] $Ledger)
    if ($null -eq $Ledger) { return @() }
    if (-not ($Ledger.PSObject.Properties.Name -contains 'tasks')) { return @() }
    $t = $Ledger.tasks
    if ($null -eq $t) { return @() }
    # tekil nesneyi diziye çevir; zaten diziyse aynen enumerate edilir
    return @($t)
}

function Get-PendingBatch {
    <#
      Sıradaki batch: status=pending VE tüm depends_on'ları done olan
      task'lardan ilk BatchSize tanesi. Loop'un otonom ilerlemesi buna dayanır.
    #>
    param(
        [Parameter(Mandatory)] [object] $Ledger,
        [int] $BatchSize = 4
    )
    $tasks = Get-LedgerTasks $Ledger
    $doneIds = @($tasks | Where-Object { $_.status -eq 'done' } | ForEach-Object { $_.id })

    $eligible = foreach ($t in $tasks) {
        if ($t.status -ne 'pending') { continue }
        $deps = @()
        if ($t.PSObject.Properties.Name -contains 'depends_on' -and $t.depends_on) { $deps = @($t.depends_on) }
        $unmet = @($deps | Where-Object { $_ -notin $doneIds })
        if ($unmet.Count -eq 0) { $t }
    }
    @($eligible | Select-Object -First $BatchSize)
}

function Set-TaskStatus {
    <#
      Bir task'ın durumunu ve alanlarını günceller. Checkbox'ı AGENT DEĞİL
      bu fonksiyon (orkestratör) yazar. $Fields ile commit_sha, attempts,
      last_gate_output gibi alanlar geçilebilir.
    #>
    param(
        [Parameter(Mandatory)] [object] $Ledger,
        [Parameter(Mandatory)] [string] $TaskId,
        [ValidateSet('pending','done','blocked','superseded','manual')] [string] $Status,
        [hashtable] $Fields
    )
    $task = Get-LedgerTasks $Ledger | Where-Object { $_.id -eq $TaskId } | Select-Object -First 1
    if ($null -eq $task) { throw "Task bulunamadı: $TaskId" }

    if ($PSBoundParameters.ContainsKey('Status')) {
        $task.status = $Status
    }
    if ($Fields) {
        foreach ($k in $Fields.Keys) {
            if ($task.PSObject.Properties.Name -contains $k) { $task.$k = $Fields[$k] }
            else { $task | Add-Member -NotePropertyName $k -NotePropertyValue $Fields[$k] -Force }
        }
    }
    $task | Add-Member -NotePropertyName 'updated_at' -NotePropertyValue ((Get-Date).ToString('o')) -Force
    return $Ledger
}

function Render-TasksMd {
    <#
      Ledger durumunu mevcut Spec Kit tasks.md üzerine işler. Başlıklar,
      phase/story bölümleri ve açıklamalar korunur; yalnızca checkbox ile
      orkestratöre ait sdd-status yorumu güncellenir. Dosya baştan render
      edilse phase bilgisi kaybolur ve sonraki sync-tasks bağımlılıkları
      bozardı.
    #>
    param(
        [Parameter(Mandatory)] [object] $Ledger,
        [Parameter(Mandatory)] [string] $OutPath
    )
    $byId = @{}
    foreach ($task in Get-LedgerTasks $Ledger) { $byId[$task.id] = $task }

    $source = if (Test-Path -LiteralPath $OutPath) { @(Get-Content -LiteralPath $OutPath) } else { @('# Tasks','') }
    $result = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($line in $source) {
        # Önceki render'dan kalan orkestratör notunu yeniden üretmek üzere atla.
        if ($line -match '^\s*<!--\s*sdd-status:') { continue }

        if ($line -match '^(\s*-\s*)\[[ xX]\](\s*)(T\d{3,})(\s+.*)$') {
            $id = $Matches[3]
            if ($byId.ContainsKey($id)) {
                $task = $byId[$id]
                $box = if ($task.status -eq 'done') { '[x]' } else { '[ ]' }
                $result.Add("$($Matches[1])$box$($Matches[2])$id$($Matches[4])")
                [void]$seen.Add($id)

                $note = $null
                if ($task.status -eq 'blocked') {
                    $note = "blocked; attempts=$($task.attempts)"
                    if ($task.PSObject.Properties.Name -contains 'last_gate_output' -and $task.last_gate_output) {
                        $first = ([string]$task.last_gate_output -split "`r?`n" | Select-Object -First 1)
                        $note += "; $first"
                    }
                } elseif ($task.status -eq 'superseded') {
                    $note = 'superseded'
                } elseif ($task.status -eq 'manual') {
                    $note = 'manual; otonom loop dışında'
                }
                if ($note) { $result.Add("  <!-- sdd-status: $note -->") }
                continue
            }
        }
        $result.Add([string]$line)
    }

    $missing = @(Get-LedgerTasks $Ledger | Where-Object { -not $seen.Contains($_.id) })
    if ($missing.Count -gt 0) {
        $result.Add('')
        $result.Add('## Orchestrator Tasks')
        $result.Add('')
        foreach ($task in $missing) {
            $box = if ($task.status -eq 'done') { '[x]' } else { '[ ]' }
            $result.Add("- $box $($task.id) $($task.title)")
        }
    }

    Set-Content -LiteralPath $OutPath -Value $result -Encoding utf8
}

function Import-TasksToLedger {
    <#
      tasks.md'yi parse edip ledger'a task kayıtları olarak yükler.
      spec-kit satır formatı: tire, boş kutu, T-numarası, opsiyonel P ve US
      etiketleri, açıklama; dosya yolları açıklamada backtick içinde.

      Çıkarılanlar:
        id          T### (zorunlu)
        title       [P]/[US#] etiketleri çıkarılmış açıklama
        files       açıklamadaki backtick içindeki dosya.yolu parçaları
        parallel    [P] var mı
        story       [US#] etiketi (varsa)
        phase       task'ın altında bulunduğu "## Phase N" numarası
        depends_on  PHASE SIRASI ile: bu task, kendinden önceki bloklayıcı
                    phase'lerdeki task'lara bağlı (task-seviyesi prose parse
                    edilmez; yanlış sıra Tier 1 tarafından yakalanır).

      Idempotent: zaten ledger'da olan (aynı id) task'ın status/attempts'ine
      DOKUNMAZ; yalnızca title/files/story/phase'i günceller. Böylece tasks'ı
      yeniden import etmek biten işi sıfırlamaz. Ledger'da olup tasks.md'de
      olmayan task'lar korunur (superseded'ları kaybetme).
    #>
    param(
        [Parameter(Mandatory)] [object] $Ledger,
        [Parameter(Mandatory)] [string] $TasksMdPath
    )
    if (-not (Test-Path -LiteralPath $TasksMdPath)) {
        throw "tasks.md bulunamadı: $TasksMdPath"
    }

    $lines = Get-Content -LiteralPath $TasksMdPath
    $currentPhase = 0
    $parsed = [System.Collections.Generic.List[object]]::new()

    foreach ($line in $lines) {
        # phase başlığı: "## Phase 3: ..."
        if ($line -match '^##\s+Phase\s+(\d+)') {
            $currentPhase = [int]$Matches[1]
            continue
        }
        # task satırı: "- [ ] T### ..." (yalnızca açık kutu; [x] zaten yapılmış
        # ama biz status'ü ledger'dan yönetiyoruz, yine de id'yi alırız)
        if ($line -match '^\s*-\s*\[[ xX]\]\s*(T\d{3,})\s+(.*)$') {
            $id = $Matches[1]
            $rest = $Matches[2]

            # [P] işareti
            $parallel = $false
            if ($rest -match '^\[P\]\s*') { $parallel = $true; $rest = $rest -replace '^\[P\]\s*', '' }

            # [US#] etiketi
            $story = $null
            if ($rest -match '^\[US(\d+)\]\s*') { $story = "US$($Matches[1])"; $rest = $rest -replace '^\[US\d+\]\s*', '' }
            # [P] etiketi US'ten sonra da gelebilir (bazı satırlarda sıra karışık)
            if ($rest -match '^\[P\]\s*') { $parallel = $true; $rest = $rest -replace '^\[P\]\s*', '' }

            $title = $rest.Trim()

            # backtick'li dosya yolları: `path/to/file.ext`
            $files = @()
            foreach ($m in [regex]::Matches($title, '`([^`]+)`')) {
                $cand = $m.Groups[1].Value.Trim()
                # dosya gibi görünenler (uzantısı olan ya da / içeren); komut/script değil
                if ($cand -match '[\\/]' -or $cand -match '\.\w+$') {
                    # virgülle ayrılmış çoklu yol olabilir
                    foreach ($part in ($cand -split ',\s*')) {
                        $p = $part.Trim()
                        if ($p -and ($p -match '[\\/]' -or $p -match '\.\w+$')) { $files += $p }
                    }
                }
            }
            $files = @($files | Select-Object -Unique)

            $parsed.Add([pscustomobject]@{
                id = $id; title = $title; files = $files
                parallel = $parallel; story = $story; phase = $currentPhase
            })
        }
    }

    # Phase sırası bağımlılığı: her task, kendinden DÜŞÜK phase'lerdeki tüm
    # task'lara bağlı (kaba ama sağlam). Aynı phase içinde bağımlılık yok.
    $byPhase = $parsed | Group-Object phase
    $phaseTaskIds = @{}
    foreach ($g in $byPhase) { $phaseTaskIds[[int]$g.Name] = @($g.Group | ForEach-Object { $_.id }) }
    $phases = @($phaseTaskIds.Keys | Sort-Object)

    foreach ($t in $parsed) {
        $deps = @()
        foreach ($ph in $phases) {
            if ($ph -lt $t.phase) { $deps += $phaseTaskIds[$ph] }
        }
        $t | Add-Member -NotePropertyName depends_on -NotePropertyValue @($deps) -Force
    }

    # Ledger'a birleştir (idempotent)
    $existing = @{}
    foreach ($e in (Get-LedgerTasks $Ledger)) { $existing[$e.id] = $e }

    $merged = [System.Collections.Generic.List[object]]::new()
    foreach ($t in $parsed) {
        if ($existing.ContainsKey($t.id)) {
            # var olanı koru, sadece açıklayıcı alanları tazele
            $e = $existing[$t.id]
            $e.title = $t.title
            $e | Add-Member -NotePropertyName files      -NotePropertyValue $t.files      -Force
            $e | Add-Member -NotePropertyName depends_on -NotePropertyValue $t.depends_on  -Force
            $e | Add-Member -NotePropertyName story      -NotePropertyValue $t.story       -Force
            $e | Add-Member -NotePropertyName phase      -NotePropertyValue $t.phase       -Force
            $e | Add-Member -NotePropertyName parallel   -NotePropertyValue $t.parallel    -Force
            $merged.Add($e)
        } else {
            # yeni task
            $merged.Add([pscustomobject]@{
                id = $t.id; title = $t.title; status = 'pending'; attempts = 0
                files = $t.files; depends_on = $t.depends_on; story = $t.story
                phase = $t.phase; parallel = $t.parallel
                agent = $null; commit_sha = $null; last_gate_output = $null; updated_at = $null
            })
        }
    }
    # ledger'da olup tasks.md'de olmayanları da koru (ör. superseded)
    foreach ($e in (Get-LedgerTasks $Ledger)) {
        if (-not ($parsed | Where-Object { $_.id -eq $e.id })) { $merged.Add($e) }
    }

    $Ledger.tasks = @($merged | Sort-Object { [int]($_.id -replace '\D','') })
    return $Ledger
}

function Set-DownstreamStale {
    <#
      Bir stage yeniden çalışınca SONRAKİ stage'leri 'stale' işaretler.
      plan yeniden çalıştı -> tasks/analyze/implement stale.
      Aynı stage'i düzeltmeyle tekrar çalıştırmak bunu TETİKLEMEZ; sadece
      geriye gitmek tetikler (çağıran karar verir, bu fonksiyon sadece uygular).
    #>
    param(
        [Parameter(Mandatory)] [object] $Ledger,
        [Parameter(Mandatory)] [string] $ChangedStage
    )
    $idx = [array]::IndexOf($script:StageOrder, $ChangedStage)
    if ($idx -lt 0) { throw "Bilinmeyen stage: $ChangedStage" }
    for ($i = $idx + 1; $i -lt $script:StageOrder.Count; $i++) {
        $name = $script:StageOrder[$i]
        if ($Ledger.stages.PSObject.Properties.Name -contains $name) {
            $st = $Ledger.stages.$name
            if ($st.status -in @('completed','running')) { $st.status = 'stale' }
        }
    }
    return $Ledger
}

function Show-LedgerStatus {
    <#
      `sdd status`: ledger'ı okunur özet olarak basar — stage durumları ve
      task sayıları (pending/done/blocked/...).
    #>
    param([Parameter(Mandatory)] [string] $StatePath)

    $ledger = Read-Ledger -StatePath $StatePath
    Write-Host ""
    Write-Host "SDD durumu — spec: $($ledger.spec_id)" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Stage'ler:"
    foreach ($name in $script:StageOrder) {
        if ($ledger.stages.PSObject.Properties.Name -contains $name) {
            $st = $ledger.stages.$name
            $color = switch ($st.status) {
                'completed'   { 'Green' }
                'running'     { 'Yellow' }
                'stale'       { 'DarkYellow' }
                'interrupted' { 'Red' }
                default       { 'Gray' }
            }
            Write-Host ("  {0,-10} {1}" -f $name, $st.status) -ForegroundColor $color
        }
    }

    if ($ledger.stages.converge.PSObject.Properties.Name -contains 'round') {
        Write-Host ("  {0,-10} {1}" -f 'conv.round', $ledger.stages.converge.round) -ForegroundColor DarkGray
    }

    $tasks = @(Get-LedgerTasks $ledger)
    Write-Host ""
    Write-Host "Task'lar: $($tasks.Count) toplam"
    if ($tasks.Count -gt 0) {
        foreach ($grp in ($tasks | Group-Object status | Sort-Object Name)) {
            Write-Host ("  {0,-11} {1}" -f $grp.Name, $grp.Count)
        }
    }
    Write-Host ""
}
