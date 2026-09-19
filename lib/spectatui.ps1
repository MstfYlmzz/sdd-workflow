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

function Get-SddSpectaStage {
    param([Parameter(Mandatory)] [object] $Ledger)

    foreach ($name in @('converge','implement','analyze','tasks','plan','spec')) {
        $stage = Get-SddSpectaProperty -Object $Ledger.stages -Name $name
        if ($stage -and [string](Get-SddSpectaProperty -Object $stage -Name 'status' -Default '') -eq 'running') {
            return $name
        }
    }

    $implement = Get-SddSpectaProperty -Object $Ledger.stages -Name 'implement'
    $converge = Get-SddSpectaProperty -Object $Ledger.stages -Name 'converge'
    $convRound = [int](Get-SddSpectaProperty -Object $converge -Name 'round' -Default 0)
    $implStatus = [string](Get-SddSpectaProperty -Object $implement -Name 'status' -Default '')
    if ($convRound -gt 0 -and $implStatus -ne 'running') { return 'converge' }

    foreach ($name in @('implement','analyze','tasks','plan','spec')) {
        $stage = Get-SddSpectaProperty -Object $Ledger.stages -Name $name
        $status = [string](Get-SddSpectaProperty -Object $stage -Name 'status' -Default '')
        if ($status -and $status -notin @('not_started','stale')) { return $name }
    }
    return 'spec'
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
        spec_id = [string](Get-SddSpectaProperty -Object $Ledger -Name 'spec_id' -Default '')
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
