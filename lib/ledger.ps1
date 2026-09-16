<#
  ledger.ps1 — .sdd/state.json tek gerçek kaynak.
  tasks.md buradan RENDER edilir; asla tersine değil.
  Checkbox ile ledger çelişirse: biri 'done' diyorsa done kabul edilir.
#>

Set-StrictMode -Version Latest

$script:StageOrder = @('spec','plan','tasks','analyze','implement')

function Read-Ledger {
    param([Parameter(Mandatory)] [string] $StatePath)
    if (-not (Test-Path -LiteralPath $StatePath)) {
        throw "state.json bulunamadı: $StatePath. Önce 'sdd init' çalıştır."
    }
    Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
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
    $tmp = "$StatePath.tmp"
    $Ledger | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $tmp -Encoding utf8
    Move-Item -LiteralPath $tmp -Destination $StatePath -Force
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
      Ledger'dan tasks.md üretir. Format kullanıcının örneğine birebir:
        [ ] T001 <title>       (pending)
        [x] T001 <title>       (done)
      blocked task'lar checkbox açık kalır, altına yorum düşülür:
        [ ] T042 <title>
            <!-- blocked: N deneme, <gate özeti> -->
      Böylece "yapılmadı" ile "denendi düştü" ayırt edilir.
    #>
    param(
        [Parameter(Mandatory)] [object] $Ledger,
        [Parameter(Mandatory)] [string] $OutPath
    )
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('# Tasks')
    [void]$sb.AppendLine('')
    foreach ($t in Get-LedgerTasks $Ledger) {
        $box = if ($t.status -eq 'done') { '[x]' } else { '[ ]' }
        [void]$sb.AppendLine("- $box $($t.id) $($t.title)")
        if ($t.status -eq 'blocked') {
            $note = "blocked: $($t.attempts) deneme"
            if ($t.PSObject.Properties.Name -contains 'last_gate_output' -and $t.last_gate_output) {
                $first = ($t.last_gate_output -split "`r?`n" | Select-Object -First 1)
                $note += ", $first"
            }
            [void]$sb.AppendLine("      <!-- $note -->")
        }
        elseif ($t.status -eq 'superseded') {
            [void]$sb.AppendLine("      <!-- superseded -->")
        }
        elseif ($t.status -eq 'manual') {
            [void]$sb.AppendLine("      <!-- manual: otonom loop dışında -->")
        }
    }
    Set-Content -LiteralPath $OutPath -Value $sb.ToString() -Encoding utf8
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
