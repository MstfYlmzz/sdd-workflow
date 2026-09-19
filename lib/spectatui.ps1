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

    [pscustomobject][ordered]@{
        schema_version = 1
        authoritative = $false
        updated_at = (Get-Date).ToUniversalTime().ToString('o')
        routes = @($routes)
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

function Write-SddSpectaEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ProjectRoot,
        [Parameter(Mandatory)] [object] $Event,
        [int] $MaxEvents = 40
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
        return Write-SddSpectaStatus -ProjectRoot $ProjectRoot -Ledger $ledger -Stage $Stage -Status $Status
    } catch {
        return $null
    }
}
