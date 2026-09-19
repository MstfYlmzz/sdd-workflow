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
    $id = 'T{0:D3}' -f ([int]$next)
    $first = ($GateOutput -split "`r?`n" | Select-Object -First 1)
    $task = [pscustomobject]@{
        id = $id; title = "Repair Tier 1 failure: $first"; status = 'pending'; attempts = 0
        files = @(); depends_on = @(); story = $null; phase = 0; parallel = $false
        strict_gates = $true
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
    if (Get-Command Write-SddSpectaStatus -ErrorAction SilentlyContinue) {
        $null = Write-SddSpectaStatus -ProjectRoot $ProjectRoot -Ledger $Ledger
    }
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

function Invoke-BatchValidation {
    param(
        [Parameter(Mandatory)] [object] $Config,
        [Parameter(Mandatory)] [object] $Ledger,
        [Parameter(Mandatory)] [string] $ProjectRoot,
        [Parameter(Mandatory)] [string] $Baseline,
        [Parameter(Mandatory)] [object[]] $Batch,
        [Parameter(Mandatory)] [string] $LogPath
    )

    $tier0Fails = [System.Collections.Generic.List[string]]::new()
    $tier0Warnings = [System.Collections.Generic.List[string]]::new()
    foreach ($task in $Batch) {
        $t0 = Invoke-Tier0 -ProjectRoot $ProjectRoot -Baseline $Baseline -Task $task
        foreach ($item in @($t0.hard_fails)) { if ($item) { $tier0Fails.Add([string]$item) } }
        foreach ($item in @($t0.warnings)) { if ($item) { $tier0Warnings.Add([string]$item) } }
    }
    foreach ($warning in @($tier0Warnings | Select-Object -Unique)) {
        Write-SddLog -Message "[Tier 0 warning] $warning" -LogPath $LogPath -Level 'warn'
    }

    if ($tier0Fails.Count -gt 0) {
        return [pscustomobject]@{
            ok = $false; kind = 'tier0_failed'
            output = "Tier 0 failed:`n$(@($tier0Fails | Select-Object -Unique) -join "`n")"
        }
    }

    $strictTier1 = @($Batch | Where-Object { [bool](Get-WorkflowProperty -Object $_ -Name 'strict_gates' -Default $false) }).Count -gt 0
    $t1 = Invoke-Tier1 -Config $Config -ProjectRoot $ProjectRoot -Ledger $Ledger -Strict:$strictTier1
    if (-not $t1.ok) {
        return [pscustomobject]@{ ok = $false; kind = 'tier1_failed'; output = "Tier 1 failed:`n$($t1.output)" }
    }
    return [pscustomobject]@{ ok = $true; kind = $null; output = $null }
}

function Resolve-RevalidationCommit {
    param(
        [Parameter(Mandatory)] [string] $ProjectRoot,
        [Parameter(Mandatory)] [string] $Baseline,
        [Parameter(Mandatory)] [string] $CandidateCommit
    )

    $resolved = Invoke-GitCapture -ProjectRoot $ProjectRoot -Arguments @('rev-parse','--verify',"$CandidateCommit^{commit}") -AllowFailure
    if ($resolved.ExitCode -ne 0) { throw "Candidate commit bulunamadı: $CandidateCommit" }
    $sha = $resolved.Text.Trim()
    $links = @(
        [pscustomobject]@{ From = $Baseline; To = $sha }
        [pscustomobject]@{ From = $sha; To = 'HEAD' }
    )
    foreach ($link in $links) {
        $ancestor = Invoke-GitCapture -ProjectRoot $ProjectRoot -Arguments @('merge-base','--is-ancestor',$link.From,$link.To) -AllowFailure
        if ($ancestor.ExitCode -ne 0) {
            throw "Revalidation zinciri geçersiz: $Baseline -> $sha -> HEAD olmalı."
        }
    }
    return $sha
}

function Invoke-ImplementLoop {
    param(
        [Parameter(Mandatory)] [object] $Config,
        [Parameter(Mandatory)] [object] $Ledger,
        [Parameter(Mandatory)] [string] $ProjectRoot,
        [int] $ObserveEvery = -1,
        [string] $RevalidateFrom,
        [string] $CandidateCommit,
        [object] $ProfileOverride
    )

    if ($RevalidateFrom -and -not $CandidateCommit) {
        throw '-RevalidateFrom ile birlikte -CandidateCommit gerekli.'
    }

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

    $baseProfile = if ($ProfileOverride) { $ProfileOverride } else { $Config.agents.implement }
    if (-not $baseProfile) { throw 'config.agents.implement tanımlı değil.' }
    $agentFn = Resolve-Adapter -AgentName ([string](Get-WorkflowProperty -Object $baseProfile -Name 'agent'))
    $logPath = Join-Path $paths.LogsDir 'implement.log'

    $previousReason = [string](Get-WorkflowProperty -Object $Ledger.stages.implement -Name 'stop_reason' -Default '')
    $dirty = @(Get-GitStatusForTier0 -ProjectRoot $ProjectRoot)
    $mayResumeDirty = $previousReason -in @('tier0_failed','tier1_failed','agent_interrupted','circuit_breaker')
    if ($dirty.Count -gt 0 -and -not $mayResumeDirty) {
        throw "Implement loop temiz çalışma ağacıyla başlamalı. Önce commit/stash yap: $($dirty -join ' | ')"
    }

    # Validator recovery agentsız kalmalıdır. Normal implement girişinde ise
    # analyze otomatik ve read-only çalışır; kritik eşik loop'u durdurur.
    if (-not $RevalidateFrom) {
        $analysis = Invoke-Analyze -Config $Config -Ledger $Ledger -ProjectRoot $ProjectRoot
        if (-not $analysis.ok -or $analysis.blocked) {
            $why = if ($analysis.output) { $analysis.output } else { "Analyze $($analysis.severity) bulguyla implement'i durdurdu: $($analysis.summary)" }
            Set-ImplementStageState -Ledger $Ledger -Status 'interrupted' -Reason 'analyze_blocked' -Profile $baseProfile
            Set-WorkflowProperty -Object $Ledger.stages.implement -Name 'last_error' -Value $why
            $null = Save-LoopCheckpoint -Ledger $Ledger -ProjectRoot $ProjectRoot -TasksMdPath $tasksMdPath -Message 'sdd: stop on analyze findings' -StateOnly
            Write-SddLog -Message $why -LogPath $logPath -Level 'error'
            return [pscustomobject]@{ ok = $false; reason = 'analyze_blocked'; output = $why; batches = 0 }
        }
        Write-SddLog -Message "[analyze] geçti: severity=$($analysis.severity), findings=$($analysis.finding_count)" -LogPath $logPath -Level 'info'
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
    $revalidatePending = -not [string]::IsNullOrWhiteSpace($RevalidateFrom)
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

            Write-SddLog -Message '[implement] final strict Tier 1 doğrulaması' -LogPath $logPath -Level 'info'
            $finalGate = Invoke-Tier1 -Config $Config -ProjectRoot $ProjectRoot -Ledger $Ledger -Strict
            if (-not $finalGate.ok) {
                $failure = "Final Tier 1 failed:`n$($finalGate.output)"
                $repair = New-RepairTask -Ledger $Ledger -GateOutput $failure
                Set-WorkflowProperty -Object $Ledger.stages.implement -Name 'last_error' -Value $failure
                Set-ImplementStageState -Ledger $Ledger -Status 'running' -Reason 'final_gate_repair' -Profile $baseProfile
                $null = Save-LoopCheckpoint -Ledger $Ledger -ProjectRoot $ProjectRoot -TasksMdPath $tasksMdPath -Message "sdd: add final gate repair $($repair.id)"
                Write-SddLog -Message "[implement] final gate için repair task eklendi: $($repair.id)" -LogPath $logPath -Level 'warn'
                continue
            }

            $enableConverge = [bool](Get-WorkflowProperty -Object $loopCfg -Name 'enable_converge' -Default $false)
            if ($enableConverge) {
                Write-SddLog -Message '[implement] final gate geçti; converge başlıyor' -LogPath $logPath -Level 'info'
                $converge = Invoke-Converge -Config $Config -Ledger $Ledger -ProjectRoot $ProjectRoot
                if (-not $converge.ok) {
                    Set-ImplementStageState -Ledger $Ledger -Status 'interrupted' -Reason $converge.outcome -Profile $baseProfile
                    Set-WorkflowProperty -Object $Ledger.stages.implement -Name 'last_error' -Value $converge.output
                    $null = Save-LoopCheckpoint -Ledger $Ledger -ProjectRoot $ProjectRoot -TasksMdPath $tasksMdPath -Message 'sdd: stop on converge failure' -StateOnly
                    return [pscustomobject]@{ok=$false;reason=$converge.outcome;output=$converge.output;batches=$attemptedBatches}
                }
                if ($converge.outcome -eq 'tasks_appended') {
                    Set-ImplementStageState -Ledger $Ledger -Status 'running' -Reason 'convergence_tasks' -Profile $baseProfile
                    Write-SddLog -Message "[implement] converge $($converge.tasks_appended) yeni task ekledi; loop devam ediyor" -LogPath $logPath -Level 'warn'
                    continue
                }
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

        if ($revalidatePending) {
            $revalidatePending = $false
            $attemptedBatches++
            $ids = @($batch.id) -join ', '
            $candidateSha = Resolve-RevalidationCommit -ProjectRoot $ProjectRoot -Baseline $RevalidateFrom -CandidateCommit $CandidateCommit
            if (Get-Command Write-SddSpectaStatus -ErrorAction SilentlyContinue) {
                $revalidateAttempt = [Math]::Max(1, [int](@($batch | ForEach-Object { [int]$_.attempts } | Measure-Object -Maximum).Maximum))
                $null = Write-SddSpectaStatus -ProjectRoot $ProjectRoot -Ledger $Ledger -Stage 'implement' -Status 'running' -Batch $batch -BatchNumber $attemptedBatches -Attempt $revalidateAttempt -MaxAttempts $maxAttempts -Profile $baseProfile -StopReason 'revalidating'
            }
            Write-SddLog -Message "[implement] mevcut candidate yeniden doğrulanıyor: $ids | $($candidateSha.Substring(0, 8))" -LogPath $logPath -Level 'info'

            $validation = Invoke-BatchValidation -Config $Config -Ledger $Ledger -ProjectRoot $ProjectRoot `
                                                   -Baseline $RevalidateFrom -Batch $batch -LogPath $logPath
            if (-not $validation.ok) {
                Set-WorkflowProperty -Object $Ledger.stages.implement -Name 'last_error' -Value $validation.output
                Set-ImplementStageState -Ledger $Ledger -Status 'interrupted' -Reason 'revalidation_failed' -Profile $baseProfile
                $null = Save-LoopCheckpoint -Ledger $Ledger -ProjectRoot $ProjectRoot -TasksMdPath $tasksMdPath -Message "sdd: record failed revalidation $ids" -StateOnly
                Write-SddLog -Message $validation.output -LogPath $logPath -Level 'error'
                return [pscustomobject]@{ ok = $false; reason = 'revalidation_failed'; output = $validation.output; batches = $attemptedBatches }
            }

            foreach ($task in $batch) {
                $fields = @{
                    attempts = [Math]::Max(1, [int]$task.attempts)
                    agent = [string](Get-WorkflowProperty -Object $baseProfile -Name 'agent')
                    commit_sha = $candidateSha
                    last_gate_output = $null
                }
                $null = Set-TaskStatus -Ledger $Ledger -TaskId $task.id -Status 'done' -Fields $fields
            }
            $consecutiveFailures = 0
            $completedThisRun++
            Set-WorkflowProperty -Object $Ledger.stages.implement -Name 'consecutive_failures' -Value 0
            Set-WorkflowProperty -Object $Ledger.stages.implement -Name 'last_error' -Value $null
            Set-WorkflowProperty -Object $Ledger.stages.implement -Name 'session_id' -Value $null
            Set-ImplementStageState -Ledger $Ledger -Status 'running' -Reason 'running' -Profile $baseProfile
            $null = Save-LoopCheckpoint -Ledger $Ledger -ProjectRoot $ProjectRoot -TasksMdPath $tasksMdPath -Message "sdd: revalidate tasks $ids"
            Write-SddLog -Message "[implement] yeniden doğrulama geçti: $ids @ $($candidateSha.Substring(0, 8))" -LogPath $logPath -Level 'info'

            if ($ObserveEvery -gt 0 -and ($completedThisRun % $ObserveEvery) -eq 0) {
                Set-ImplementStageState -Ledger $Ledger -Status 'interrupted' -Reason 'observe_pause' -Profile $baseProfile
                $null = Save-LoopCheckpoint -Ledger $Ledger -ProjectRoot $ProjectRoot -TasksMdPath $tasksMdPath -Message 'sdd: observation pause'
                return [pscustomobject]@{ ok = $true; reason = 'observe_pause'; batches = $attemptedBatches }
            }
            continue
        }

        $attemptedBatches++
        $nextAttempt = (@($batch | ForEach-Object { [int]$_.attempts } | Measure-Object -Maximum).Maximum) + 1
        $profile = if ($nextAttempt -ge $escalateAt) { Get-EscalatedProfile -BaseProfile $baseProfile -Attempt $nextAttempt } else { Get-EscalatedProfile -BaseProfile $baseProfile -Attempt 1 }
        $baseline = Get-GitBaseline -ProjectRoot $ProjectRoot
        $ids = @($batch.id) -join ', '
        if (Get-Command Write-SddSpectaStatus -ErrorAction SilentlyContinue) {
            $null = Write-SddSpectaStatus -ProjectRoot $ProjectRoot -Ledger $Ledger -Stage 'implement' -Status 'running' -Batch $batch -BatchNumber $attemptedBatches -Attempt $nextAttempt -MaxAttempts $maxAttempts -Profile $profile -StopReason 'running'
        }
        Write-SddLog -Message "[implement] batch ${attemptedBatches}: $ids | attempt=$nextAttempt | $($profile.agent)/$($profile.model)/$($profile.effort)" -LogPath $logPath -Level 'info'

        $prompt = Get-ImplementPrompt -Batch $batch -ProjectRoot $ProjectRoot -Baseline $baseline -PreviousFailure $retryFailure
        $request = @{
            prompt = $prompt; model = $profile.model; effort = $profile.effort
            cwd = $ProjectRoot; log_path = $logPath
            stream_partial = (Test-SddPartialStreaming)
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

        $validation = Invoke-BatchValidation -Config $Config -Ledger $Ledger -ProjectRoot $ProjectRoot `
                                               -Baseline $baseline -Batch $batch -LogPath $logPath
        $failureReason = $validation.output
        $failureKind = $validation.kind

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
