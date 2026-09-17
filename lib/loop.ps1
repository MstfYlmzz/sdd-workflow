<#
  loop.ps1 — otonom implement döngüsü.

  Batch seçer, Codex'i non-interactive çalıştırır, git kanıtını Tier 0 ile ve
  proje sağlığını Tier 1 ile doğrular. Task ancak iki tier da geçtiğinde done
  olur. Hook kullanılmaz; agent implementation commit'ini, orkestratör ise
  ledger/tasks.md checkpoint commit'ini üretir.
#>

Set-StrictMode -Version Latest

function Get-WorkflowProperty {
    param([object] $Object, [Parameter(Mandatory)] [string] $Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary] -and $Object.Contains($Name)) { return $Object[$Name] }
    if ($Object.PSObject.Properties.Name -contains $Name) { return $Object.$Name }
    return $Default
}

function Set-WorkflowProperty {
    param([Parameter(Mandatory)] [object] $Object, [Parameter(Mandatory)] [string] $Name, $Value)
    if ($Object -is [System.Collections.IDictionary]) { $Object[$Name] = $Value; return }
    $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
}

function Get-EscalatedProfile {
    <#
      Config'deki modeli değiştirmez. Kullanıcının seçtiği model sabit kalır;
      yalnızca reasoning effort düşük->orta->yüksek yükselir. Sağlayıcı/model
      failover ancak config sözleşmesine açıkça eklendiğinde yapılmalıdır.
    #>
    param([Parameter(Mandatory)] [object] $BaseProfile, [int] $Attempt)

    $effort = [string](Get-WorkflowProperty -Object $BaseProfile -Name 'effort' -Default 'medium')
    if ($Attempt -ge 2) {
        $effort = switch ($effort) {
            'low' { 'medium' }
            default { 'high' }
        }
    }
    [pscustomobject]@{
        agent  = [string](Get-WorkflowProperty -Object $BaseProfile -Name 'agent' -Default 'codex')
        model  = [string](Get-WorkflowProperty -Object $BaseProfile -Name 'model' -Default '')
        effort = $effort
    }
}

function New-RepairTask {
    <#
      Dışarıdan/manual kullanım için repair task üreticisi. Ana loop Tier 1
      hatasında aynı batch'i retry eder; böylece asıl task'lar doğrulanmadan
      done olmaz. Bu yardımcı, kullanıcının ayrı bir repair işi eklemek istediği
      durumlarda kimlik üretme sözleşmesini korur.
    #>
    param([Parameter(Mandatory)] [object] $Ledger, [Parameter(Mandatory)] [string] $GateOutput)

    $numbers = @(Get-LedgerTasks $Ledger | ForEach-Object { [int]($_.id -replace '\D','') })
    $next = if ($numbers.Count -gt 0) { ($numbers | Measure-Object -Maximum).Maximum + 1 } else { 1 }
    $id = 'T{0:D3}' -f $next
    $first = ($GateOutput -split "`r?`n" | Select-Object -First 1)
    $task = [pscustomobject]@{
        id = $id; title = "Repair Tier 1 failure: $first"; status = 'pending'; attempts = 0
        files = @(); depends_on = @(); story = $null; phase = 0; parallel = $false
        agent = $null; commit_sha = $null; last_gate_output = $GateOutput; updated_at = (Get-Date).ToString('o')
    }
    $Ledger.tasks = @($task) + @(Get-LedgerTasks $Ledger)
    return $task
}

function Get-ImplementPrompt {
    param(
        [Parameter(Mandatory)] [object[]] $Batch,
        [Parameter(Mandatory)] [string] $ProjectRoot,
        [Parameter(Mandatory)] [string] $Baseline,
        [string] $PreviousFailure
    )

    $featureDir = Get-FeatureDirectory -ProjectRoot $ProjectRoot
    $taskLines = foreach ($task in $Batch) {
        $files = if ($task.PSObject.Properties.Name -contains 'files' -and @($task.files).Count -gt 0) {
            " | expected files: $(@($task.files) -join ', ')"
        } else { '' }
        "- $($task.id): $($task.title)$files"
    }
    $retryBlock = if ($PreviousFailure) {
@"

PREVIOUS ATTEMPT FAILED VALIDATION. Repair the current repository state and
complete the same tasks. Raw validator output follows; do not merely explain it:

$PreviousFailure
"@
    } else { '' }

@"
[SDD IMPLEMENT BATCH — NON-INTERACTIVE]

Implement ONLY the tasks listed below. Read the feature's spec.md, plan.md,
research/design artifacts and tasks.md for context. Do not start later tasks.

$($taskLines -join "`n")

Rules:
1. Do not ask questions or wait for approval. Make reasonable implementation
   assumptions and proceed.
2. Do not edit any tasks.md checkbox or any file under .sdd/. The orchestrator
   owns ledger and checkbox state.
3. Do not add TODO/FIXME/not-implemented placeholders, disabled checks, skipped
   tests, secret .env files, node_modules, or unrelated cleanup.
4. Run the most relevant available checks for this batch.
5. Commit all implementation changes. Use a concise commit message containing
   these task IDs: $(@($Batch.id) -join ', '). Leave the working tree clean,
   apart from .sdd/logs which is written by the orchestrator.
6. Do not amend, reset, rebase, or rewrite commits that existed at baseline
   $Baseline. If this is a retry, add a repair commit on top.
7. Finish with a compact factual summary and stop.

Feature directory: $featureDir
$retryBlock
"@
}

function ConvertTo-GitRelativePath {
    param([Parameter(Mandatory)] [string] $ProjectRoot, [Parameter(Mandatory)] [string] $Path)
    return ([IO.Path]::GetRelativePath($ProjectRoot, $Path) -replace '\\','/')
}

function Save-LoopCheckpoint {
    param(
        [Parameter(Mandatory)] [object] $Ledger,
        [Parameter(Mandatory)] [string] $ProjectRoot,
        [Parameter(Mandatory)] [string] $TasksMdPath,
        [Parameter(Mandatory)] [string] $Message,
        [switch] $StateOnly
    )

    $paths = Get-SddPaths -ProjectRoot $ProjectRoot
    Write-Ledger -Ledger $Ledger -StatePath $paths.State
    if (-not $StateOnly) { Render-TasksMd -Ledger $Ledger -OutPath $TasksMdPath }

    $stateRel = ConvertTo-GitRelativePath -ProjectRoot $ProjectRoot -Path $paths.State
    $tasksRel = ConvertTo-GitRelativePath -ProjectRoot $ProjectRoot -Path $TasksMdPath
    $checkpointPaths = if ($StateOnly) { @($stateRel) } else { @($stateRel,$tasksRel) }
    $add = Invoke-GitCapture -ProjectRoot $ProjectRoot -Arguments (@('add','-f','--') + $checkpointPaths) -AllowFailure
    if ($add.ExitCode -ne 0) { throw "Loop checkpoint dosyaları stage edilemedi: $($add.Text)" }

    $cached = Invoke-GitCapture -ProjectRoot $ProjectRoot -Arguments (@('diff','--cached','--quiet','--') + $checkpointPaths) -AllowFailure
    if ($cached.ExitCode -eq 1) {
        $commit = Invoke-GitCapture -ProjectRoot $ProjectRoot -Arguments (@('commit','-m',$Message,'--') + $checkpointPaths) -AllowFailure
        if ($commit.ExitCode -ne 0) { throw "Loop checkpoint commit'i oluşturulamadı: $($commit.Text)" }
    } elseif ($cached.ExitCode -ne 0) {
        throw "Checkpoint diff kontrolü başarısız: $($cached.Text)"
    }

    return (Get-GitBaseline -ProjectRoot $ProjectRoot)
}

function Set-ImplementStageState {
    param(
        [Parameter(Mandatory)] [object] $Ledger,
        [Parameter(Mandatory)] [string] $Status,
        [string] $Reason,
        [object] $Profile,
        [string] $SessionId
    )
    $stage = $Ledger.stages.implement
    $stage.status = $Status
    if (-not (Get-WorkflowProperty -Object $stage -Name 'started_at')) {
        Set-WorkflowProperty -Object $stage -Name 'started_at' -Value ((Get-Date).ToString('o'))
    }
    if ($Status -in @('completed','interrupted')) {
        Set-WorkflowProperty -Object $stage -Name 'finished_at' -Value ((Get-Date).ToString('o'))
    } else {
        Set-WorkflowProperty -Object $stage -Name 'finished_at' -Value $null
    }
    if ($Reason) { Set-WorkflowProperty -Object $stage -Name 'stop_reason' -Value $Reason }
    if ($Profile) {
        foreach ($name in @('agent','model','effort')) {
            Set-WorkflowProperty -Object $stage -Name $name -Value (Get-WorkflowProperty -Object $Profile -Name $name)
        }
    }
    if ($SessionId) { Set-WorkflowProperty -Object $stage -Name 'session_id' -Value $SessionId }
}

function Update-FailedBatch {
    param(
        [Parameter(Mandatory)] [object] $Ledger,
        [Parameter(Mandatory)] [object[]] $Batch,
        [Parameter(Mandatory)] [string] $Failure,
        [Parameter(Mandatory)] [int] $MaxAttempts,
        [string] $AgentName
    )

    $blocked = [System.Collections.Generic.List[string]]::new()
    foreach ($task in $Batch) {
        $attempts = [int](Get-WorkflowProperty -Object $task -Name 'attempts' -Default 0) + 1
        $status = if ($attempts -ge $MaxAttempts) { 'blocked' } else { 'pending' }
        $fields = @{
            attempts = $attempts
            last_gate_output = $Failure
            agent = $AgentName
        }
        $null = Set-TaskStatus -Ledger $Ledger -TaskId $task.id -Status $status -Fields $fields
        if ($status -eq 'blocked') { $blocked.Add($task.id) }
    }
    return @($blocked)
}

function Invoke-ImplementLoop {
    param(
        [Parameter(Mandatory)] [object] $Config,
        [Parameter(Mandatory)] [object] $Ledger,
        [Parameter(Mandatory)] [string] $ProjectRoot,
        [int] $ObserveEvery = -1
    )

    $paths = Get-SddPaths -ProjectRoot $ProjectRoot
    $featureDir = Get-FeatureDirectory -ProjectRoot $ProjectRoot
    if (-not $featureDir) { throw '.specify/feature.json bulunamadı.' }
    $tasksMdPath = Join-Path $featureDir 'tasks.md'
    if (-not (Test-Path -LiteralPath $tasksMdPath -PathType Leaf)) { throw "tasks.md bulunamadı: $tasksMdPath" }

    $allTasks = @(Get-LedgerTasks $Ledger)
    if ($allTasks.Count -eq 0) { throw "Ledger boş. Önce 'sdd tasks' veya 'sdd sync-tasks' çalıştır." }
    $existingBlocked = @($allTasks | Where-Object { $_.status -eq 'blocked' })
    if ($existingBlocked.Count -gt 0) {
        return [pscustomobject]@{ ok = $false; reason = 'blocked'; blocked = @($existingBlocked.id); batches = 0 }
    }

    $loopCfg = $Config.loop
    $batchSize = [Math]::Max(1, [int](Get-WorkflowProperty -Object $loopCfg -Name 'batch_size' -Default 4))
    $maxAttempts = [Math]::Max(1, [int](Get-WorkflowProperty -Object $loopCfg -Name 'max_attempts' -Default 3))
    $escalateAt = [Math]::Max(1, [int](Get-WorkflowProperty -Object $loopCfg -Name 'escalate_at' -Default 2))
    $circuitLimit = [Math]::Max(1, [int](Get-WorkflowProperty -Object $loopCfg -Name 'circuit_breaker' -Default 3))
    if ($ObserveEvery -lt 0) { $ObserveEvery = [int](Get-WorkflowProperty -Object $loopCfg -Name 'observe_every' -Default 0) }

    $baseProfile = $Config.agents.implement
    if (-not $baseProfile) { throw 'config.agents.implement tanımlı değil.' }
    $agentFn = Resolve-Adapter -AgentName ([string](Get-WorkflowProperty -Object $baseProfile -Name 'agent'))
    $logPath = Join-Path $paths.LogsDir 'implement.log'

    $previousReason = [string](Get-WorkflowProperty -Object $Ledger.stages.implement -Name 'stop_reason' -Default '')
    $dirty = @(Get-GitStatusForTier0 -ProjectRoot $ProjectRoot)
    $mayResumeDirty = $previousReason -in @('tier0_failed','tier1_failed','agent_interrupted','circuit_breaker')
    if ($dirty.Count -gt 0 -and -not $mayResumeDirty) {
        throw "Implement loop temiz çalışma ağacıyla başlamalı. Önce commit/stash yap: $($dirty -join ' | ')"
    }

    if (-not (Get-WorkflowProperty -Object $Ledger -Name 'gate_baseline')) {
        Set-WorkflowProperty -Object $Ledger -Name 'gate_baseline' -Value ([pscustomobject]@{})
    }
    if (@($Ledger.gate_baseline.PSObject.Properties).Count -eq 0) {
        Write-SddLog -Message '[implement] Tier 1 baseline ölçülüyor' -LogPath $logPath -Level 'info'
        $Ledger.gate_baseline = Measure-GateBaseline -Config $Config -ProjectRoot $ProjectRoot
    }

    Set-ImplementStageState -Ledger $Ledger -Status 'running' -Reason 'running' -Profile $baseProfile
    $consecutiveFailures = [int](Get-WorkflowProperty -Object $Ledger.stages.implement -Name 'consecutive_failures' -Default 0)
    $completedThisRun = 0
    $attemptedBatches = 0
    $retryFailure = $null
    $resumeSession = if ($previousReason -in @('tier0_failed','tier1_failed','agent_interrupted','circuit_breaker')) {
        [string](Get-WorkflowProperty -Object $Ledger.stages.implement -Name 'session_id' -Default '')
    } else { '' }

    while ($true) {
        $pending = @(Get-LedgerTasks $Ledger | Where-Object { $_.status -eq 'pending' })
        if ($pending.Count -eq 0) {
            $manual = @(Get-LedgerTasks $Ledger | Where-Object { $_.status -eq 'manual' })
            if ($manual.Count -gt 0) {
                Set-ImplementStageState -Ledger $Ledger -Status 'interrupted' -Reason 'manual_tasks' -Profile $baseProfile
                $null = Save-LoopCheckpoint -Ledger $Ledger -ProjectRoot $ProjectRoot -TasksMdPath $tasksMdPath -Message 'sdd: pause for manual tasks'
                return [pscustomobject]@{ ok = $false; reason = 'manual_tasks'; manual = @($manual.id); batches = $attemptedBatches }
            }
            Set-ImplementStageState -Ledger $Ledger -Status 'completed' -Reason 'all_done' -Profile $baseProfile
            Set-WorkflowProperty -Object $Ledger.stages.implement -Name 'consecutive_failures' -Value 0
            $null = Save-LoopCheckpoint -Ledger $Ledger -ProjectRoot $ProjectRoot -TasksMdPath $tasksMdPath -Message 'sdd: complete implement loop'
            Write-SddLog -Message '[implement] bütün otonom tasklar tamamlandı' -LogPath $logPath -Level 'info'
            return [pscustomobject]@{ ok = $true; reason = 'completed'; batches = $attemptedBatches }
        }

        $batch = @(Get-PendingBatch -Ledger $Ledger -BatchSize $batchSize)
        if ($batch.Count -eq 0) {
            $detail = foreach ($task in $pending) {
                $deps = @($task.depends_on | Where-Object {
                    $depId = $_
                    -not (Get-LedgerTasks $Ledger | Where-Object { $_.id -eq $depId -and $_.status -eq 'done' })
                })
                "$($task.id) waits for [$($deps -join ', ')]"
            }
            $failure = "Çözülemeyen task bağımlılığı: $($detail -join '; ')"
            Set-ImplementStageState -Ledger $Ledger -Status 'interrupted' -Reason 'dependency_deadlock' -Profile $baseProfile
            Set-WorkflowProperty -Object $Ledger.stages.implement -Name 'last_error' -Value $failure
            $null = Save-LoopCheckpoint -Ledger $Ledger -ProjectRoot $ProjectRoot -TasksMdPath $tasksMdPath -Message 'sdd: stop on dependency deadlock'
            return [pscustomobject]@{ ok = $false; reason = 'dependency_deadlock'; output = $failure; batches = $attemptedBatches }
        }

        $attemptedBatches++
        $nextAttempt = (@($batch | ForEach-Object { [int]$_.attempts } | Measure-Object -Maximum).Maximum) + 1
        $profile = if ($nextAttempt -ge $escalateAt) { Get-EscalatedProfile -BaseProfile $baseProfile -Attempt $nextAttempt } else { Get-EscalatedProfile -BaseProfile $baseProfile -Attempt 1 }
        $baseline = Get-GitBaseline -ProjectRoot $ProjectRoot
        $ids = @($batch.id) -join ', '
        Write-SddLog -Message "[implement] batch ${attemptedBatches}: $ids | attempt=$nextAttempt | $($profile.agent)/$($profile.model)/$($profile.effort)" -LogPath $logPath -Level 'info'

        $prompt = Get-ImplementPrompt -Batch $batch -ProjectRoot $ProjectRoot -Baseline $baseline -PreviousFailure $retryFailure
        $request = @{
            prompt = $prompt; model = $profile.model; effort = $profile.effort
            cwd = $ProjectRoot; log_path = $logPath
        }
        if ($resumeSession) { $request.resume_session = $resumeSession }
        $agentResult = & $agentFn -Request $request
        if ($agentResult.session_id) {
            $resumeSession = [string]$agentResult.session_id
            Set-WorkflowProperty -Object $Ledger.stages.implement -Name 'session_id' -Value $resumeSession
        }

        if (-not $agentResult.ok) {
            $failure = "Agent çalışması tamamlanmadı: $(@($agentResult.denied) -join '; ')"
            Set-ImplementStageState -Ledger $Ledger -Status 'interrupted' -Reason 'agent_interrupted' -Profile $profile -SessionId $resumeSession
            Set-WorkflowProperty -Object $Ledger.stages.implement -Name 'last_error' -Value $failure
            $null = Save-LoopCheckpoint -Ledger $Ledger -ProjectRoot $ProjectRoot -TasksMdPath $tasksMdPath -Message 'sdd: record interrupted agent session' -StateOnly
            Write-SddLog -Message $failure -LogPath $logPath -Level 'error'
            return [pscustomobject]@{ ok = $false; reason = 'agent_interrupted'; output = $failure; batches = $attemptedBatches }
        }

        $tier0Fails = [System.Collections.Generic.List[string]]::new()
        $tier0Warnings = [System.Collections.Generic.List[string]]::new()
        foreach ($task in $batch) {
            $t0 = Invoke-Tier0 -ProjectRoot $ProjectRoot -Baseline $baseline -Task $task
            foreach ($item in @($t0.hard_fails)) { if ($item) { $tier0Fails.Add([string]$item) } }
            foreach ($item in @($t0.warnings)) { if ($item) { $tier0Warnings.Add([string]$item) } }
        }
        foreach ($warning in @($tier0Warnings | Select-Object -Unique)) {
            Write-SddLog -Message "[Tier 0 warning] $warning" -LogPath $logPath -Level 'warn'
        }

        $failureReason = $null
        $failureKind = $null
        if ($tier0Fails.Count -gt 0) {
            $failureKind = 'tier0_failed'
            $failureReason = "Tier 0 failed:`n$(@($tier0Fails | Select-Object -Unique) -join "`n")"
        } else {
            $t1 = Invoke-Tier1 -Config $Config -ProjectRoot $ProjectRoot -Ledger $Ledger
            if (-not $t1.ok) {
                $failureKind = 'tier1_failed'
                $failureReason = "Tier 1 failed:`n$($t1.output)"
            }
        }

        if ($failureReason) {
            $consecutiveFailures++
            $blocked = @(Update-FailedBatch -Ledger $Ledger -Batch $batch -Failure $failureReason -MaxAttempts $maxAttempts -AgentName $profile.agent)
            Set-WorkflowProperty -Object $Ledger.stages.implement -Name 'consecutive_failures' -Value $consecutiveFailures
            Set-WorkflowProperty -Object $Ledger.stages.implement -Name 'last_error' -Value $failureReason
            Set-ImplementStageState -Ledger $Ledger -Status 'running' -Reason $failureKind -Profile $profile -SessionId $resumeSession
            $null = Save-LoopCheckpoint -Ledger $Ledger -ProjectRoot $ProjectRoot -TasksMdPath $tasksMdPath -Message "sdd: record failed batch $ids" -StateOnly
            Write-SddLog -Message $failureReason -LogPath $logPath -Level 'error'

            if ($blocked.Count -gt 0) {
                Set-ImplementStageState -Ledger $Ledger -Status 'interrupted' -Reason 'blocked' -Profile $profile -SessionId $resumeSession
                $null = Save-LoopCheckpoint -Ledger $Ledger -ProjectRoot $ProjectRoot -TasksMdPath $tasksMdPath -Message "sdd: block tasks $($blocked -join ', ')" -StateOnly
                return [pscustomobject]@{ ok = $false; reason = 'blocked'; blocked = $blocked; output = $failureReason; batches = $attemptedBatches }
            }
            if ($consecutiveFailures -ge $circuitLimit) {
                Set-ImplementStageState -Ledger $Ledger -Status 'interrupted' -Reason 'circuit_breaker' -Profile $profile -SessionId $resumeSession
                $null = Save-LoopCheckpoint -Ledger $Ledger -ProjectRoot $ProjectRoot -TasksMdPath $tasksMdPath -Message 'sdd: open circuit breaker' -StateOnly
                return [pscustomobject]@{ ok = $false; reason = 'circuit_breaker'; output = $failureReason; batches = $attemptedBatches }
            }
            $retryFailure = $failureReason
            continue
        }

        $implementationSha = (Get-GitBaseline -ProjectRoot $ProjectRoot)
        foreach ($task in $batch) {
            $attempts = [int]$task.attempts + 1
            $fields = @{
                attempts = $attempts; agent = $profile.agent; commit_sha = $implementationSha
                last_gate_output = $null
            }
            $null = Set-TaskStatus -Ledger $Ledger -TaskId $task.id -Status 'done' -Fields $fields
        }
        $consecutiveFailures = 0
        $completedThisRun++
        Set-WorkflowProperty -Object $Ledger.stages.implement -Name 'consecutive_failures' -Value 0
        Set-WorkflowProperty -Object $Ledger.stages.implement -Name 'last_error' -Value $null
        Set-ImplementStageState -Ledger $Ledger -Status 'running' -Reason 'running' -Profile $profile
        $null = Save-LoopCheckpoint -Ledger $Ledger -ProjectRoot $ProjectRoot -TasksMdPath $tasksMdPath -Message "sdd: complete tasks $ids"
        Write-SddLog -Message "[implement] geçti: $ids @ $($implementationSha.Substring(0, 8))" -LogPath $logPath -Level 'info'

        $retryFailure = $null
        $resumeSession = '' # her başarılı batch'ten sonra temiz context
        Set-WorkflowProperty -Object $Ledger.stages.implement -Name 'session_id' -Value $null

        if ($ObserveEvery -gt 0 -and ($completedThisRun % $ObserveEvery) -eq 0) {
            Set-ImplementStageState -Ledger $Ledger -Status 'interrupted' -Reason 'observe_pause' -Profile $profile
            $null = Save-LoopCheckpoint -Ledger $Ledger -ProjectRoot $ProjectRoot -TasksMdPath $tasksMdPath -Message 'sdd: observation pause'
            return [pscustomobject]@{ ok = $true; reason = 'observe_pause'; batches = $attemptedBatches }
        }
    }
}
