#requires -Version 7.0
<#
  workflow.ps1 — Spec Kit workflow engine ile mevcut SDD domain motoru
  arasındaki ince adapter.

  Ownership:
    - Spec Kit run state: yalnız pipeline step konumu / run-resume durumu.
    - .sdd/state.json: task, attempt, validation, agent ve convergence durumu.

  Bu dosya implement/converge semantics'lerini yeniden üretmez. Yalnız mevcut
  fonksiyonları workflow-step exit/pause semantics'ine çevirir.
#>

Set-StrictMode -Version Latest

function Get-SddWorkflowTasksPath {
    param([Parameter(Mandatory)] [string] $ProjectRoot)
    $featureDir = Get-FeatureDirectory -ProjectRoot $ProjectRoot
    if (-not $featureDir) { throw '.specify/feature.json bulunamadı.' }
    $tasksPath = Join-Path $featureDir 'tasks.md'
    if (-not (Test-Path -LiteralPath $tasksPath -PathType Leaf)) {
        throw "tasks.md bulunamadı: $tasksPath"
    }
    return $tasksPath
}

function Get-SddWorkflowTaskSignature {
    param([Parameter(Mandatory)] [object] $Ledger)

    $shape = foreach ($task in @(Get-LedgerTasks $Ledger | Sort-Object id)) {
        [ordered]@{
            id         = [string]$task.id
            title      = [string]$task.title
            files      = @($(if ($task.PSObject.Properties.Name -contains 'files') { @($task.files) } else { @() }))
            depends_on = @($(if ($task.PSObject.Properties.Name -contains 'depends_on') { @($task.depends_on) } else { @() }))
            phase      = $(if ($task.PSObject.Properties.Name -contains 'phase') { $task.phase } else { $null })
            story      = $(if ($task.PSObject.Properties.Name -contains 'story') { $task.story } else { $null })
            parallel   = [bool]$(if ($task.PSObject.Properties.Name -contains 'parallel') { $task.parallel } else { $false })
        }
    }
    return ($shape | ConvertTo-Json -Compress -Depth 8)
}

function Invoke-SddWorkflowStep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ProjectRoot,
        [Parameter(Mandatory)] [ValidateSet('prepare','analyze','closure')] [string] $Step,
        [ValidateSet('auto','plain','tui','raw')] [string] $UiMode = 'raw'
    )

    $paths = Get-SddPaths -ProjectRoot $ProjectRoot
    $config = Read-SddConfig -ConfigPath $paths.Config
    $ledger = Read-Ledger -StatePath $paths.State
    $eventStage = switch ($Step) {
        'prepare' { 'tasks' }
        'analyze' { 'analyze' }
        default   { 'implement' }
    }

    $null = Initialize-SddEventContext -ProjectRoot $ProjectRoot -UiMode $UiMode -Stage $eventStage
    $eventStatus = 'completed'
    try {
        switch ($Step) {
            'prepare' {
                $dirty = @(Get-GitStatusForTier0 -ProjectRoot $ProjectRoot)
                if ($dirty.Count -gt 0) {
                    throw "SDD workflow temiz çalışma ağacıyla başlamalı: $($dirty -join ' | ')"
                }

                $tasksPath = Get-SddWorkflowTasksPath -ProjectRoot $ProjectRoot
                $before = Get-SddWorkflowTaskSignature -Ledger $ledger
                $ledger = Import-TasksToLedger -Ledger $ledger -TasksMdPath $tasksPath
                $after = Get-SddWorkflowTaskSignature -Ledger $ledger

                $ledger.stages.tasks.status = 'completed'
                if ($before -ne $after) {
                    $ledger = Set-DownstreamStale -Ledger $ledger -ChangedStage 'tasks'
                }

                $null = Save-LoopCheckpoint -Ledger $ledger -ProjectRoot $ProjectRoot -TasksMdPath $tasksPath -Message 'sdd: prepare native workflow' -StateOnly
                Send-SddEvent -Message 'Task ledger hazır; Spec Kit pipeline domain state ownershipünü .sdd/state.json üzerinde bıraktı.' -Category 'workflow' -EventType 'workflow_prepare_completed' -Stage 'tasks' -Status 'completed'
                return [pscustomobject]@{ ok=$true; step='prepare'; pause=$false }
            }

            'analyze' {
                $tasksPath = Get-SddWorkflowTasksPath -ProjectRoot $ProjectRoot
                $analysis = Invoke-Analyze -Config $config -Ledger $ledger -ProjectRoot $ProjectRoot
                $null = Save-LoopCheckpoint -Ledger $ledger -ProjectRoot $ProjectRoot -TasksMdPath $tasksPath -Message 'sdd: workflow analyze checkpoint' -StateOnly

                if (-not $analysis.ok) {
                    $detail = if ($analysis.output) { [string]$analysis.output } else { 'Analyze tamamlanmadı.' }
                    throw $detail
                }
                if ($analysis.blocked) {
                    throw "Analyze implementasyonu blokladı: severity=$($analysis.severity); $($analysis.summary)"
                }

                Send-SddEvent -Message "Analyze geçti: severity=$($analysis.severity), findings=$($analysis.finding_count)" -Category 'workflow' -EventType 'workflow_analyze_completed' -Stage 'analyze' -Status 'completed'
                return [pscustomobject]@{ ok=$true; step='analyze'; pause=$false; analysis=$analysis }
            }

            'closure' {
                $result = Invoke-ImplementLoop -Config $config -Ledger $ledger -ProjectRoot $ProjectRoot
                if ($result.ok -and $result.reason -eq 'completed') {
                    Send-SddEvent -Message 'Autonomous closure tamamlandı: strict Tier 1 ve converge döngüsü temiz.' -Category 'workflow' -EventType 'workflow_closure_completed' -Stage 'implement' -Status 'completed'
                    return [pscustomobject]@{ ok=$true; step='closure'; pause=$false; result=$result }
                }
                if ($result.reason -eq 'observe_pause') {
                    Send-SddEvent -Message 'Observation pause: workflow resume ile aynı closure step devam edebilir.' -Category 'workflow' -EventType 'workflow_observe_pause' -Stage 'implement' -Status 'interrupted'
                    return [pscustomobject]@{ ok=$true; step='closure'; pause=$true; result=$result }
                }

                $detail = if ($result.output) { [string]$result.output } else { [string]$result.reason }
                throw "Autonomous closure durdu: $($result.reason). $detail"
            }
        }
    } catch {
        $eventStatus = 'failed'
        throw
    } finally {
        $null = Close-SddEventContext -Status $eventStatus
    }
}
