#requires -Version 7.0
<#
  spectatui.ps1 — .sdd/state.json içeriğini değiştirmeden SpectaTUI için
  read-only, Git-ignore edilmiş bir projection üretir.

  Authoritative state:
    .sdd/state.json

  Projection:
    .specify/sdd-status.json
#>

Set-StrictMode -Version Latest

function Get-SddSpectaProperty {
    param([object] $Object, [Parameter(Mandatory)] [string] $Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary] -and $Object.Contains($Name)) { return $Object[$Name] }
    if ($Object.PSObject.Properties.Name -contains $Name) { return $Object.$Name }
    return $Default
}

function Get-SddSpectaStatusPath {
    param([Parameter(Mandatory)] [string] $ProjectRoot)
    return (Join-Path $ProjectRoot '.specify/sdd-status.json')
}

function Get-SddSpectaSpecId {
    param(
        [Parameter(Mandatory)] [string] $ProjectRoot,
        [Parameter(Mandatory)] [object] $Ledger
    )

    if (Get-Command Get-SddActiveSpecId -ErrorAction SilentlyContinue) {
        $active = [string](Get-SddActiveSpecId -ProjectRoot $ProjectRoot)
        if (-not [string]::IsNullOrWhiteSpace($active)) { return $active }
    }

    return [string](Get-SddSpectaProperty -Object $Ledger -Name 'spec_id' -Default '')
}

function Get-SddSpectaStage {
    param([Parameter(Mandatory)] [object] $Ledger)

    $ordered = @('spec','plan','tasks','analyze','implement')
    $converge = Get-SddSpectaProperty -Object $Ledger.stages -Name 'converge'
    $convStatus = [string](Get-SddSpectaProperty -Object $converge -Name 'status' -Default 'not_started')
    $convRound = [int](Get-SddSpectaProperty -Object $converge -Name 'round' -Default 0)

    # Gerçekten çalışan stage her şeyden önce gelir.
    foreach ($name in @($ordered + 'converge')) {
        $stage = Get-SddSpectaProperty -Object $Ledger.stages -Name $name
        if ($stage -and [string](Get-SddSpectaProperty -Object $stage -Name 'status' -Default '') -eq 'running') {
            return $name
        }
    }

    # Converge bir kez başladıysa (interrupted/completed dahil) kendi lifecycle
    # stage'idir. round>0 eski ledger biçimleri için geriye uyumluluk sağlar.
    if ($convRound -gt 0 -or $convStatus -in @('interrupted','completed','stale')) {
        return 'converge'
    }

    # İlk tamamlanmamış upstream stage, kullanıcının bulunduğu/sonraki actionable
    # stage'dir. Böylece analyze=completed + implement=not_started => implement.
    foreach ($name in $ordered) {
        $stage = Get-SddSpectaProperty -Object $Ledger.stages -Name $name
        $status = [string](Get-SddSpectaProperty -Object $stage -Name 'status' -Default 'not_started')
        if ($status -ne 'completed') {
            return $name
        }
    }

    # Implement tamamlandı, Converge henüz başlamadıysa UI implement-completed
    # üzerinde kalır; Converge başladığında yukarıdaki kurallar onu devralır.
    return 'implement'
}

function Get-SddSpectaConfigPath {
    param([Parameter(Mandatory)] [string] $ProjectRoot)
    return (Join-Path $ProjectRoot '.specify/sdd-config.json')
}

function Get-SddSpectaConfigDocument {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $ProjectRoot)

    $configPath = Join-Path $ProjectRoot '.sdd/config.yaml'
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { return $null }
    $config = Read-SddConfig -ConfigPath $configPath

    $routes = foreach ($stageName in @('spec','plan','tasks','analyze','implement','converge')) {
        $profile = Get-SddSpectaProperty -Object (Get-SddSpectaProperty -Object $config -Name 'agents') -Name $stageName
        [pscustomobject][ordered]@{
            stage = $stageName
            agent = [string](Get-SddSpectaProperty -Object $profile -Name 'agent' -Default '')
            model = [string](Get-SddSpectaProperty -Object $profile -Name 'model' -Default '')
            effort = [string](Get-SddSpectaProperty -Object $profile -Name 'effort' -Default '')
        }
    }

    $providers = foreach ($agentName in @('codex','claude','cursor')) {
        $configuredModels = @($routes | Where-Object agent -eq $agentName | ForEach-Object { [string]$_.model } | Where-Object { $_ })
        $knownModels = if (Get-Command Get-SddAgentModels -ErrorAction SilentlyContinue) {
            @(Get-SddAgentModels -Agent $agentName)
        } else {
            switch ($agentName) {
                'codex'  { @('gpt-5.6-sol','gpt-5.6-terra','gpt-5.6-luna') }
                'claude' { @('sonnet','opus','haiku') }
                default  { @('auto') }
            }
        }
        $models = @(@($configuredModels)+@($knownModels) | Where-Object { $_ } | Select-Object -Unique)
        $efforts = if ($agentName -eq 'cursor') { @('medium') } else { @('low','medium','high','xhigh','max') }
        $available = $true
        if (Get-Command Get-SddAgentCapabilities -ErrorAction SilentlyContinue) {
            try { $available = [bool](Get-SddAgentCapabilities -Agent $agentName).available } catch { $available = $false }
        }
        [pscustomobject][ordered]@{
            agent = $agentName
            available = $available
            models = @($models)
            efforts = @($efforts)
        }
    }

    [pscustomobject][ordered]@{
        schema_version = 1
        authoritative = $false
        updated_at = (Get-Date).ToUniversalTime().ToString('o')
        routes = @($routes)
        providers = @($providers)
    }
}

function Write-SddSpectaConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $ProjectRoot)

    $specifyDir = Join-Path $ProjectRoot '.specify'
    if (-not (Test-Path -LiteralPath $specifyDir -PathType Container)) { return $null }
    $doc = Get-SddSpectaConfigDocument -ProjectRoot $ProjectRoot
    if (-not $doc) { return $null }

    $path = Get-SddSpectaConfigPath -ProjectRoot $ProjectRoot
    $tmp = "$path.tmp"
    $doc | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $tmp -Encoding utf8 -NoNewline
    Move-Item -LiteralPath $tmp -Destination $path -Force
    return $doc
}

function Get-SddSpectaEventsPath {
    param([Parameter(Mandatory)] [string] $ProjectRoot)
    return (Join-Path $ProjectRoot '.specify/sdd-events.json')
}


function Get-SddSpectaUnixMs {
    return [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
}

function Get-SddSpectaActiveBaseline {
    param([Parameter(Mandatory)] [string] $ProjectRoot)
    $statePath = Join-Path $ProjectRoot '.sdd/state.json'
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { return '' }
    try {
        $ledger = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -ErrorAction Stop
        $implement = Get-SddSpectaProperty -Object (Get-SddSpectaProperty -Object $ledger -Name 'stages') -Name 'implement'
        return [string](Get-SddSpectaProperty -Object $implement -Name 'active_baseline' -Default '')
    } catch { return '' }
}

function Get-SddSpectaGitDelta {
    param(
        [Parameter(Mandatory)] [string] $ProjectRoot,
        [string] $Baseline = '',
        [int] $MaxFiles = 10
    )

    if (-not $Baseline) { $Baseline = Get-SddSpectaActiveBaseline -ProjectRoot $ProjectRoot }
    $empty = [pscustomobject][ordered]@{
        baseline = $Baseline
        changed_files = 0
        additions = 0
        deletions = 0
        files = @()
    }
    if (-not $Baseline -or -not (Test-Path -LiteralPath (Join-Path $ProjectRoot '.git'))) { return $empty }

    $rows = @()
    try { $rows = @(& git -C $ProjectRoot diff --numstat $Baseline -- 2>$null) } catch { return $empty }
    $items = [System.Collections.Generic.List[object]]::new()
    $seen = @{}
    $totalAdd = 0
    $totalDel = 0
    foreach ($line in $rows) {
        if ([string]::IsNullOrWhiteSpace([string]$line)) { continue }
        $parts = [string]$line -split [char]9, 3
        if ($parts.Count -lt 3) { continue }
        $path = [string]$parts[2]
        if ($path -match '^(?:\.sdd|\.specify)(?:/|\\)') { continue }
        $binary = ($parts[0] -eq '-' -or $parts[1] -eq '-')
        $add = if ($binary) { 0 } else { [int]$parts[0] }
        $del = if ($binary) { 0 } else { [int]$parts[1] }
        $totalAdd += $add; $totalDel += $del
        $seen[$path] = $true
        $items.Add([pscustomobject][ordered]@{
            path = $path; status = 'changed'; additions = $add; deletions = $del; binary = $binary
        })
    }

    try {
        foreach ($path in @(& git -C $ProjectRoot ls-files --others --exclude-standard 2>$null)) {
            $path = [string]$path
            if (-not $path -or $path -match '^(?:\.sdd|\.specify)(?:/|\\)' -or $seen.ContainsKey($path)) { continue }
            $items.Add([pscustomobject][ordered]@{
                path = $path; status = 'untracked'; additions = 0; deletions = 0; binary = $false
            })
        }
    } catch { }

    $ordered = @($items | Sort-Object @{Expression={ [int]$_.additions + [int]$_.deletions };Descending=$true}, path)
    return [pscustomobject][ordered]@{
        baseline = $Baseline
        changed_files = $items.Count
        additions = $totalAdd
        deletions = $totalDel
        files = @($ordered | Select-Object -First ([Math]::Max(1, $MaxFiles)))
    }
}

function Update-SddSpectaRuntimeActivity {
    param(
        [Parameter(Mandatory)] [string] $ProjectRoot,
        [Parameter(Mandatory)] [object] $Event,
        [switch] $RefreshDelta
    )

    $path = Get-SddSpectaStatusPath -ProjectRoot $ProjectRoot
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try { $doc = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -ErrorAction Stop } catch { return $null }
    if (-not $doc.runtime) { return $null }

    $nowMs = Get-SddSpectaUnixMs
    $category = [string](Get-SddSpectaProperty -Object $Event -Name 'category' -Default '')
    $eventType = [string](Get-SddSpectaProperty -Object $Event -Name 'event_type' -Default '')
    $provider = [string](Get-SddSpectaProperty -Object $Event -Name 'provider' -Default '')
    $message = [string](Get-SddSpectaProperty -Object $Event -Name 'message' -Default '')
    $command = [string](Get-SddSpectaProperty -Object $Event -Name 'command' -Default '')
    $status = [string](Get-SddSpectaProperty -Object $Event -Name 'status' -Default '')

    $kind = [string](Get-SddSpectaProperty -Object $doc.runtime -Name 'activity_kind' -Default '')
    $label = [string](Get-SddSpectaProperty -Object $doc.runtime -Name 'activity_label' -Default '')
    $detail = [string](Get-SddSpectaProperty -Object $doc.runtime -Name 'activity_detail' -Default '')
    $activityStarted = [long](Get-SddSpectaProperty -Object $doc.runtime -Name 'activity_started_at_ms' -Default 0)
    $agentStarted = [long](Get-SddSpectaProperty -Object $doc.runtime -Name 'agent_started_at_ms' -Default 0)

    $newActivity = $false
    if ($eventType -eq 'agent_started') {
        $kind = 'agent'; $label = $(if ($provider) { "$provider agent" } else { 'agent' }); $detail = $message
        $activityStarted = $nowMs; $agentStarted = $nowMs; $newActivity = $true
    } elseif ($eventType -eq 'gate_command_started') {
        $kind = 'test'; $label = 'test'; $detail = $(if ($command) { $command } else { $message })
        $activityStarted = $nowMs; $newActivity = $true
    } elseif ($category -eq 'command' -and $status -in @('running','started','')) {
        $kind = 'terminal'; $label = 'terminal'; $detail = $(if ($command) { $command } else { $message })
        $activityStarted = $nowMs; $newActivity = $true
    } elseif ($category -eq 'gate' -or $eventType -like 'gate_*') {
        $kind = 'test'; $label = 'validation'; $detail = $(if ($command) { $command } else { $message })
        $activityStarted = $nowMs; $newActivity = $true
    } elseif ($category -eq 'file_change') {
        $kind = 'file'; $label = 'editing'; $detail = $message
        $activityStarted = $nowMs; $newActivity = $true
    } elseif ($category -eq 'tool' -and $status -in @('running','started','')) {
        $kind = 'tool'; $label = 'tool'; $detail = $message
        $activityStarted = $nowMs; $newActivity = $true
    } elseif ($category -eq 'reasoning_summary') {
        $kind = 'thinking'; $label = 'thinking'; $detail = $message
        $activityStarted = $nowMs; $newActivity = $true
    } elseif ($category -eq 'assistant') {
        $kind = 'agent'; $label = $(if ($provider) { "$provider response" } else { 'agent response' }); $detail = $message
        if ($eventType -ne 'agent_message_partial') { $activityStarted = $nowMs; $newActivity = $true }
    } elseif ($eventType -eq 'agent_completed') {
        $kind = $(if ($status -in @('failed','interrupted')) { 'error' } else { 'done' })
        $label = $(if ($status) { "agent $status" } else { 'agent completed' }); $detail = $message
        $activityStarted = $nowMs; $newActivity = $true
    }

    $doc.runtime | Add-Member -NotePropertyName activity_kind -NotePropertyValue $kind -Force
    $doc.runtime | Add-Member -NotePropertyName activity_label -NotePropertyValue $label -Force
    $doc.runtime | Add-Member -NotePropertyName activity_detail -NotePropertyValue (ConvertTo-SddSafeText -Value $detail -MaxLength 2000) -Force
    $doc.runtime | Add-Member -NotePropertyName activity_started_at_ms -NotePropertyValue $activityStarted -Force
    $doc.runtime | Add-Member -NotePropertyName agent_started_at_ms -NotePropertyValue $agentStarted -Force
    $doc.runtime | Add-Member -NotePropertyName last_activity_at_ms -NotePropertyValue $nowMs -Force

    # Git delta calculation can be expensive for vendor-heavy repos. Activity itself
    # is written immediately, while diff stats are sampled at most once every 2s
    # (agent completion always forces a final sample).
    $shouldRefreshDelta = [bool]$RefreshDelta
    if ($shouldRefreshDelta) {
        if (-not (Get-Variable -Scope Script -Name SddSpectaLastDeltaAt -ErrorAction SilentlyContinue)) {
            $script:SddSpectaLastDeltaAt = @{}
        }
        $lastDelta = if ($script:SddSpectaLastDeltaAt.ContainsKey($ProjectRoot)) {
            [long]$script:SddSpectaLastDeltaAt[$ProjectRoot]
        } else { 0 }
        $forceFinal = ($eventType -eq 'agent_completed')
        if (-not $forceFinal -and ($nowMs - $lastDelta) -lt 2000) {
            $shouldRefreshDelta = $false
        }
    }
    if ($shouldRefreshDelta) {
        $delta = Get-SddSpectaGitDelta -ProjectRoot $ProjectRoot
        $doc.runtime | Add-Member -NotePropertyName active_baseline -NotePropertyValue $delta.baseline -Force
        $doc.runtime | Add-Member -NotePropertyName changed_files -NotePropertyValue $delta.changed_files -Force
        $doc.runtime | Add-Member -NotePropertyName additions -NotePropertyValue $delta.additions -Force
        $doc.runtime | Add-Member -NotePropertyName deletions -NotePropertyValue $delta.deletions -Force
        $doc.runtime | Add-Member -NotePropertyName file_changes -NotePropertyValue @($delta.files) -Force
        $script:SddSpectaLastDeltaAt[$ProjectRoot] = $nowMs
    }

    $doc.updated_at = (Get-Date).ToUniversalTime().ToString('o')
    $tmp = "$path.tmp"
    $doc | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $tmp -Encoding utf8 -NoNewline
    Move-Item -LiteralPath $tmp -Destination $path -Force
    return $doc.runtime
}

function Write-SddSpectaEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ProjectRoot,
        [Parameter(Mandatory)] [object] $Event,
        [int] $MaxEvents = 80
    )

    $specifyDir = Join-Path $ProjectRoot '.specify'
    if (-not (Test-Path -LiteralPath $specifyDir -PathType Container)) { return $null }

    $category = [string](Get-SddSpectaProperty -Object $Event -Name 'category' -Default '')
    $eventType = [string](Get-SddSpectaProperty -Object $Event -Name 'event_type' -Default '')
    if ($category -eq 'command_output') { return $null }

    $runId = [string](Get-SddSpectaProperty -Object $Event -Name 'run_id' -Default '')
    $provider = [string](Get-SddSpectaProperty -Object $Event -Name 'provider' -Default '')
    $stage = [string](Get-SddSpectaProperty -Object $Event -Name 'stage' -Default '')
    $rawMessage = [string](Get-SddSpectaProperty -Object $Event -Name 'message' -Default '')
    $message = if (Get-Command ConvertTo-SddSafeText -ErrorAction SilentlyContinue) {
        [string](ConvertTo-SddSafeText -Value $rawMessage -MaxLength 6000)
    } else {
        $rawMessage
    }
    $partialKey = "$runId|$provider|$stage"

    if ($eventType -eq 'agent_message_partial') {
        if (-not (Get-Variable -Scope Script -Name SddSpectaPartialBuffers -ErrorAction SilentlyContinue)) {
            $script:SddSpectaPartialBuffers = @{}
            $script:SddSpectaPartialLastWrite = @{}
        }
        $prior = if ($script:SddSpectaPartialBuffers.ContainsKey($partialKey)) { [string]$script:SddSpectaPartialBuffers[$partialKey] } else { '' }
        $combined = $prior + $message
        if ($combined.Length -gt 6000) { $combined = '…' + $combined.Substring($combined.Length - 5999) }
        $script:SddSpectaPartialBuffers[$partialKey] = $combined

        $now = [DateTimeOffset]::UtcNow
        if ($script:SddSpectaPartialLastWrite.ContainsKey($partialKey)) {
            $last = [DateTimeOffset]$script:SddSpectaPartialLastWrite[$partialKey]
            if (($now - $last).TotalMilliseconds -lt 250) { return $null }
        }
        $script:SddSpectaPartialLastWrite[$partialKey] = $now
        $eventType = 'agent_message_live'
        $message = $combined
    }

    $path = Get-SddSpectaEventsPath -ProjectRoot $ProjectRoot
    $existingEvents = @()
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        try {
            $existing = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -ErrorAction Stop
            $existingEvents = @((Get-SddSpectaProperty -Object $existing -Name 'events' -Default @()))
        } catch {
            $existingEvents = @()
        }
    }

    if ($eventType -eq 'agent_message_live') {
        $existingEvents = @($existingEvents | Where-Object {
            -not (
                [string](Get-SddSpectaProperty -Object $_ -Name 'event_type' -Default '') -eq 'agent_message_live' -and
                [string](Get-SddSpectaProperty -Object $_ -Name 'run_id' -Default '') -eq $runId -and
                [string](Get-SddSpectaProperty -Object $_ -Name 'provider' -Default '') -eq $provider -and
                [string](Get-SddSpectaProperty -Object $_ -Name 'stage' -Default '') -eq $stage
            )
        })
    } elseif ($eventType -eq 'agent_message') {
        $existingEvents = @($existingEvents | Where-Object {
            -not (
                [string](Get-SddSpectaProperty -Object $_ -Name 'event_type' -Default '') -eq 'agent_message_live' -and
                [string](Get-SddSpectaProperty -Object $_ -Name 'run_id' -Default '') -eq $runId -and
                [string](Get-SddSpectaProperty -Object $_ -Name 'provider' -Default '') -eq $provider -and
                [string](Get-SddSpectaProperty -Object $_ -Name 'stage' -Default '') -eq $stage
            )
        })
        if (Get-Variable -Scope Script -Name SddSpectaPartialBuffers -ErrorAction SilentlyContinue) {
            $script:SddSpectaPartialBuffers.Remove($partialKey)
            $script:SddSpectaPartialLastWrite.Remove($partialKey)
        }
    }

    $entry = [ordered]@{
        timestamp   = [string](Get-SddSpectaProperty -Object $Event -Name 'timestamp' -Default ((Get-Date).ToString('o')))
        run_id      = $runId
        sequence    = [int](Get-SddSpectaProperty -Object $Event -Name 'sequence' -Default 0)
        stage       = $stage
        category    = $category
        event_type  = $eventType
        severity    = [string](Get-SddSpectaProperty -Object $Event -Name 'severity' -Default 'info')
        status      = $(if ($eventType -eq 'agent_message_live') { 'running' } else { [string](Get-SddSpectaProperty -Object $Event -Name 'status' -Default '') })
        message     = $message
        command     = [string](Get-SddSpectaProperty -Object $Event -Name 'command' -Default '')
        provider    = $provider
        exit_code   = Get-SddSpectaProperty -Object $Event -Name 'exit_code' -Default $null
        duration_ms = Get-SddSpectaProperty -Object $Event -Name 'duration_ms' -Default $null
    }

    $limit = [Math]::Max(5, $MaxEvents)
    $events = @($existingEvents + [pscustomobject]$entry | Select-Object -Last $limit)
    $doc = [ordered]@{
        schema_version = 1
        authoritative = $false
        updated_at = (Get-Date).ToUniversalTime().ToString('o')
        events = $events
    }

    $tmp = "$path.tmp"
    $doc | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $tmp -Encoding utf8 -NoNewline
    Move-Item -LiteralPath $tmp -Destination $path -Force

    $refreshDelta = $category -eq 'file_change' -or
                    $eventType -in @('agent_started','agent_completed','agent_message','gate_completed')
    $null = Update-SddSpectaRuntimeActivity -ProjectRoot $ProjectRoot -Event $Event -RefreshDelta:$refreshDelta
    return [pscustomobject]$entry
}

function Write-SddSpectaStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ProjectRoot,
        [Parameter(Mandatory)] [object] $Ledger,
        [string] $Stage = '',
        [string] $Status = '',
        [object[]] $Batch = @(),
        [int] $BatchNumber = 0,
        [int] $Attempt = 0,
        [int] $MaxAttempts = 0,
        [object] $Profile,
        [int] $ConvergenceRound = -1,
        [int] $MaxConvergenceRounds = -1,
        [string] $StopReason = '',
        [object] $Usage
    )

    $specifyDir = Join-Path $ProjectRoot '.specify'
    if (-not (Test-Path -LiteralPath $specifyDir -PathType Container)) { return $null }

    $config = $null
    $configPath = Join-Path $ProjectRoot '.sdd/config.yaml'
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        try { $config = Read-SddConfig -ConfigPath $configPath } catch { $config = $null }
    }

    if (-not $Stage) { $Stage = Get-SddSpectaStage -Ledger $Ledger }
    $stageState = Get-SddSpectaProperty -Object $Ledger.stages -Name $Stage
    if (-not $Status) {
        $Status = [string](Get-SddSpectaProperty -Object $stageState -Name 'status' -Default 'not_started')
    }
    if (-not $StopReason) {
        $StopReason = [string](Get-SddSpectaProperty -Object $stageState -Name 'stop_reason' -Default '')
    }

    if (-not $Profile -and $stageState) {
        $agent = [string](Get-SddSpectaProperty -Object $stageState -Name 'agent' -Default '')
        $model = [string](Get-SddSpectaProperty -Object $stageState -Name 'model' -Default '')
        $effort = [string](Get-SddSpectaProperty -Object $stageState -Name 'effort' -Default '')
        if ($agent -or $model -or $effort) {
            $Profile = [pscustomobject]@{agent=$agent;model=$model;effort=$effort}
        }
    }

    if ($MaxAttempts -le 0 -and $config) {
        $MaxAttempts = [int](Get-SddSpectaProperty -Object $config.loop -Name 'max_attempts' -Default 0)
    }
    $convergeState = Get-SddSpectaProperty -Object $Ledger.stages -Name 'converge'
    if ($ConvergenceRound -lt 0) {
        $ConvergenceRound = [int](Get-SddSpectaProperty -Object $convergeState -Name 'round' -Default 0)
    }
    if ($MaxConvergenceRounds -lt 0 -and $config) {
        $MaxConvergenceRounds = [int](Get-SddSpectaProperty -Object $config.loop -Name 'max_converge_rounds' -Default 0)
    }
    if ($MaxConvergenceRounds -lt 0) { $MaxConvergenceRounds = 0 }

    $tasks = @(Get-LedgerTasks $Ledger)
    $counts = [ordered]@{
        total   = $tasks.Count
        done    = @($tasks | Where-Object status -eq 'done').Count
        pending = @($tasks | Where-Object status -eq 'pending').Count
        blocked = @($tasks | Where-Object status -eq 'blocked').Count
        manual  = @($tasks | Where-Object status -eq 'manual').Count
    }

    $batchIds = @($Batch | ForEach-Object {
        if ($_ -is [string]) { [string]$_ }
        elseif ($_.PSObject.Properties.Name -contains 'id') { [string]$_.id }
    } | Where-Object { $_ })

    $priorRuntime = $null
    $statusPath = Get-SddSpectaStatusPath -ProjectRoot $ProjectRoot
    if (Test-Path -LiteralPath $statusPath -PathType Leaf) {
        try { $priorRuntime = (Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json -ErrorAction Stop).runtime } catch { $priorRuntime = $null }
    }
    $baseline = [string](Get-SddSpectaProperty -Object $stageState -Name 'active_baseline' -Default '')
    if (-not $baseline) { $baseline = [string](Get-SddSpectaProperty -Object $priorRuntime -Name 'active_baseline' -Default '') }
    $delta = Get-SddSpectaGitDelta -ProjectRoot $ProjectRoot -Baseline $baseline

    $runtime = [ordered]@{
        batch = $batchIds
        batch_number = $BatchNumber
        attempt = $Attempt
        max_attempts = $MaxAttempts
        agent = [string](Get-SddSpectaProperty -Object $Profile -Name 'agent' -Default '')
        model = [string](Get-SddSpectaProperty -Object $Profile -Name 'model' -Default '')
        effort = [string](Get-SddSpectaProperty -Object $Profile -Name 'effort' -Default '')
        convergence_round = [Math]::Max(0, $ConvergenceRound)
        max_convergence_rounds = [Math]::Max(0, $MaxConvergenceRounds)
        stop_reason = $StopReason
        active_baseline = $delta.baseline
        changed_files = $delta.changed_files
        additions = $delta.additions
        deletions = $delta.deletions
        file_changes = @($delta.files)
        activity_kind = [string](Get-SddSpectaProperty -Object $priorRuntime -Name 'activity_kind' -Default '')
        activity_label = [string](Get-SddSpectaProperty -Object $priorRuntime -Name 'activity_label' -Default '')
        activity_detail = [string](Get-SddSpectaProperty -Object $priorRuntime -Name 'activity_detail' -Default '')
        activity_started_at_ms = [long](Get-SddSpectaProperty -Object $priorRuntime -Name 'activity_started_at_ms' -Default 0)
        agent_started_at_ms = [long](Get-SddSpectaProperty -Object $priorRuntime -Name 'agent_started_at_ms' -Default 0)
        last_activity_at_ms = [long](Get-SddSpectaProperty -Object $priorRuntime -Name 'last_activity_at_ms' -Default 0)
    }

    $doc = [ordered]@{
        schema_version = 1
        authoritative = $false
        spec_id = Get-SddSpectaSpecId -ProjectRoot $ProjectRoot -Ledger $Ledger
        stage = $Stage
        status = $Status
        updated_at = (Get-Date).ToUniversalTime().ToString('o')
        tasks = $counts
        runtime = $runtime
    }
    if ($null -ne $Usage) { $doc.usage = $Usage }

    $path = Get-SddSpectaStatusPath -ProjectRoot $ProjectRoot
    $tmp = "$path.tmp"
    $json = $doc | ConvertTo-Json -Depth 10
    Set-Content -LiteralPath $tmp -Value $json -Encoding utf8 -NoNewline
    Move-Item -LiteralPath $tmp -Destination $path -Force
    return [pscustomobject]$doc
}

function Sync-SddSpectaStatusFromDisk {
    param(
        [Parameter(Mandatory)] [string] $ProjectRoot,
        [string] $Stage = '',
        [string] $Status = ''
    )
    if (-not (Get-Command Read-Ledger -ErrorAction SilentlyContinue)) { return $null }
    $statePath = Join-Path $ProjectRoot '.sdd/state.json'
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { return $null }
    try {
        $ledger = Read-Ledger -StatePath $statePath
        $statusDoc = Write-SddSpectaStatus -ProjectRoot $ProjectRoot -Ledger $ledger -Stage $Stage -Status $Status
        if (Get-Command Write-SddSpectaConfig -ErrorAction SilentlyContinue) {
            $null = Write-SddSpectaConfig -ProjectRoot $ProjectRoot
        }
        return $statusDoc
    } catch {
        return $null
    }
}
