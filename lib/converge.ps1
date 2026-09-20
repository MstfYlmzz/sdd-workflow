<#
  converge.ps1 — Spec Kit converge skill'ini semantik karar kaynağı olarak
  çalıştırır. Deterministik katman yalnız write boundary, append-only tasks.md,
  task ID bütünlüğü ve ledger handoff'unu doğrular.
#>

Set-StrictMode -Version Latest

function Get-ConvergeProperty {
    param([object] $Object, [Parameter(Mandatory)] [string] $Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary] -and $Object.Contains($Name)) { return $Object[$Name] }
    if ($Object.PSObject.Properties.Name -contains $Name) { return $Object.$Name }
    return $Default
}

function Set-ConvergeProperty {
    param([Parameter(Mandatory)] [object] $Object, [Parameter(Mandatory)] [string] $Name, $Value)
    if ($Object -is [System.Collections.IDictionary]) { $Object[$Name] = $Value; return }
    $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
}

function Get-ConvergeChangedPaths {
    param([Parameter(Mandatory)] [string] $ProjectRoot)
    $lines = @(Get-GitStatusForTier0 -ProjectRoot $ProjectRoot)
    $paths = foreach ($line in $lines) {
        if ($line.Length -lt 4) { continue }
        $path = $line.Substring(3).Trim()
        if ($path -match ' -> ') { $path = ($path -split ' -> ',2)[1] }
        $path.Trim('"') -replace '\\','/'
    }
    return @($paths | Select-Object -Unique)
}

function Get-TaskIdsFromMarkdown {
    param([Parameter(Mandatory)] [string] $Text)
    return @([regex]::Matches($Text, '(?m)^\s*-\s*\[[ xX]\]\s*(T\d{3,})\b') | ForEach-Object { $_.Groups[1].Value })
}

function Test-ConvergeAppend {
    param(
        [Parameter(Mandatory)] [string] $Before,
        [Parameter(Mandatory)] [string] $After
    )
    $beforeNormalized = $Before -replace "`r`n", "`n"
    $afterNormalized = $After -replace "`r`n", "`n"
    if ($afterNormalized -eq $beforeNormalized) {
        return [pscustomobject]@{ok=$true;changed=$false;new_ids=@();error=$null}
    }
    if (-not $afterNormalized.StartsWith($beforeNormalized, [StringComparison]::Ordinal)) {
        return [pscustomobject]@{ok=$false;changed=$true;new_ids=@();error='tasks.md append-only değil; mevcut içerik değiştirildi.'}
    }
    $suffix = $afterNormalized.Substring($beforeNormalized.Length)
    if ($suffix -notmatch '(?m)^##\s+Phase\s+\d+:\s+Convergence\s*$') {
        return [pscustomobject]@{ok=$false;changed=$true;new_ids=@();error='Eklenen içerikte yeni bir Convergence fazı yok.'}
    }
    $beforeIds = @(Get-TaskIdsFromMarkdown -Text $beforeNormalized)
    $afterIds = @(Get-TaskIdsFromMarkdown -Text $afterNormalized)
    $duplicates = @($afterIds | Group-Object | Where-Object Count -gt 1 | ForEach-Object Name)
    if ($duplicates.Count -gt 0) {
        return [pscustomobject]@{ok=$false;changed=$true;new_ids=@();error="Tekrarlanan task ID: $($duplicates -join ', ')"}
    }
    $newIds = @($afterIds | Where-Object { $_ -notin $beforeIds })
    if ($newIds.Count -eq 0) {
        return [pscustomobject]@{ok=$false;changed=$true;new_ids=@();error='Convergence fazı eklendi fakat yeni task bulunamadı.'}
    }
    $oldMax = if ($beforeIds.Count) { (@($beforeIds | ForEach-Object { [int]($_ -replace '\D','') }) | Measure-Object -Maximum).Maximum } else { 0 }
    if (@($newIds | Where-Object { [int]($_ -replace '\D','') -le $oldMax }).Count -gt 0) {
        return [pscustomobject]@{ok=$false;changed=$true;new_ids=$newIds;error='Yeni Convergence task ID sırası mevcut maksimumdan büyük değil.'}
    }
    return [pscustomobject]@{ok=$true;changed=$true;new_ids=$newIds;error=$null}
}

function Get-ConvergeResultPayload {
    param([string] $Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }

    # Cursor can append a final background-check sentence directly after the
    # contract JSON. Do not require the marker/JSON to occupy a whole line.
    $matches = [regex]::Matches(
        $Text,
        'SDD_CONVERGE_RESULT\s+(\{.*?\})',
        [System.Text.RegularExpressions.RegexOptions]::Singleline
    )
    if ($matches.Count -eq 0) { return $null }
    return [string]$matches[$matches.Count - 1].Groups[1].Value
}

function Try-RecoverConvergeContract {
    param(
        [Parameter(Mandatory)] [object] $Ledger,
        [Parameter(Mandatory)] [string] $ProjectRoot,
        [Parameter(Mandatory)] [string] $TasksPath,
        [Parameter(Mandatory)] [object] $Profile,
        [Parameter(Mandatory)] [string] $LogPath
    )

    $stage = $Ledger.stages.converge
    $status = [string](Get-ConvergeProperty -Object $stage -Name 'status' -Default '')
    $reason = [string](Get-ConvergeProperty -Object $stage -Name 'stop_reason' -Default '')
    $round = [int](Get-ConvergeProperty -Object $stage -Name 'round' -Default 0)
    if ($status -ne 'interrupted' -or $reason -ne 'contract_missing' -or $round -le 0) {
        return $null
    }
    if (-not (Test-Path -LiteralPath $LogPath -PathType Leaf)) { return $null }

    $payload = Get-ConvergeResultPayload -Text (Get-Content -LiteralPath $LogPath -Raw)
    if (-not $payload) { return $null }
    try { $report = $payload | ConvertFrom-Json -ErrorAction Stop }
    catch { return $null }

    $tasksRel = ConvertTo-GitRelativePath -ProjectRoot $ProjectRoot -Path $TasksPath
    $changed = @(Get-ConvergeChangedPaths -ProjectRoot $ProjectRoot)
    $forbidden = @($changed | Where-Object { $_ -ne $tasksRel })
    if ($forbidden.Count -gt 0) { return $null }

    if ([string]$report.outcome -eq 'converged') {
        if ($changed.Count -gt 0) { return $null }
        Set-ConvergeStageState -Ledger $Ledger -Status 'completed' -Reason 'converged' -Profile $Profile -Round $round
        Set-ConvergeProperty -Object $Ledger.stages.converge -Name 'summary' -Value ([string]$report.summary)
        $null = Save-LoopCheckpoint -Ledger $Ledger -ProjectRoot $ProjectRoot -TasksMdPath $TasksPath -Message 'sdd: recover converged contract' -StateOnly
        Send-SddEvent -Message ([string]$report.summary) -LogPath $LogPath -Category 'workflow' -EventType 'converge_contract_recovered' -Stage 'converge' -Status 'completed'
        return [pscustomobject]@{ok=$true;outcome='converged';tasks_appended=0;summary=[string]$report.summary;round=$round;recovered=$true}
    }

    if ([string]$report.outcome -ne 'tasks_appended' -or $changed.Count -eq 0) { return $null }

    $headFile = Invoke-GitCapture -ProjectRoot $ProjectRoot -Arguments @('show',"HEAD:$tasksRel") -AllowFailure
    if ($headFile.ExitCode -ne 0) { return $null }
    $before = [string]$headFile.Text
    $after = Get-Content -LiteralPath $TasksPath -Raw
    $append = Test-ConvergeAppend -Before $before -After $after
    if (-not $append.ok -or -not $append.changed) { return $null }

    $reportedCount = [int](Get-ConvergeProperty -Object $report -Name 'tasks_appended' -Default -1)
    if ($reportedCount -ge 0 -and $reportedCount -ne @($append.new_ids).Count) { return $null }

    $Ledger = Import-TasksToLedger -Ledger $Ledger -TasksMdPath $TasksPath
    foreach ($id in @($append.new_ids)) {
        $task = @(Get-LedgerTasks $Ledger | Where-Object id -eq $id | Select-Object -First 1)
        if ($task) { Set-ConvergeProperty -Object $task[0] -Name 'convergence_round' -Value $round }
    }
    Set-ConvergeStageState -Ledger $Ledger -Status 'stale' -Reason 'tasks_appended' -Profile $Profile -Round $round
    Set-ConvergeProperty -Object $Ledger.stages.converge -Name 'summary' -Value ([string]$report.summary)
    $null = Save-LoopCheckpoint -Ledger $Ledger -ProjectRoot $ProjectRoot -TasksMdPath $TasksPath -Message "sdd: recover convergence tasks round $round"
    Send-SddEvent -Message "Converge contract recovery: $(@($append.new_ids).Count) task eklendi: $(@($append.new_ids) -join ', ')" -LogPath $LogPath -Category 'workflow' -EventType 'converge_contract_recovered' -Stage 'converge' -Status 'completed'
    return [pscustomobject]@{ok=$true;outcome='tasks_appended';tasks_appended=@($append.new_ids).Count;task_ids=@($append.new_ids);summary=[string]$report.summary;round=$round;recovered=$true}
}

function Set-ConvergeStageState {
    param([Parameter(Mandatory)] [object] $Ledger, [Parameter(Mandatory)] [string] $Status,
          [string] $Reason, [object] $Profile, [int] $Round, [string] $ErrorMessage = '')
    $stage = $Ledger.stages.converge
    $stage.status = $Status
    Set-ConvergeProperty -Object $stage -Name 'round' -Value $Round
    Set-ConvergeProperty -Object $stage -Name 'stop_reason' -Value $Reason
    Set-ConvergeProperty -Object $stage -Name 'last_error' -Value $(if ($ErrorMessage) { $ErrorMessage } else { $null })
    if ($Profile) {
        foreach ($n in @('agent','model','effort')) { Set-ConvergeProperty -Object $stage -Name $n -Value (Get-ConvergeProperty -Object $Profile -Name $n) }
    }
    if ($Status -eq 'running') { Set-ConvergeProperty -Object $stage -Name 'started_at' -Value ((Get-Date).ToString('o')) }
    if ($Status -in @('completed','interrupted','stale')) { Set-ConvergeProperty -Object $stage -Name 'finished_at' -Value ((Get-Date).ToString('o')) }
}

function Invoke-Converge {
    param(
        [Parameter(Mandatory)] [object] $Config,
        [Parameter(Mandatory)] [object] $Ledger,
        [Parameter(Mandatory)] [string] $ProjectRoot,
        [object] $ProfileOverride,
        [switch] $Force,
        [switch] $FinalVerification
    )
    $paths = Get-SddPaths -ProjectRoot $ProjectRoot
    $featureDir = Get-FeatureDirectory -ProjectRoot $ProjectRoot
    if (-not $featureDir) { throw '.specify/feature.json bulunamadı.' }
    $tasksPath = Join-Path $featureDir 'tasks.md'
    if (-not (Test-Path -LiteralPath $tasksPath -PathType Leaf)) { throw "tasks.md bulunamadı: $tasksPath" }
    foreach ($required in @('spec.md','plan.md')) {
        if (-not (Test-Path -LiteralPath (Join-Path $featureDir $required) -PathType Leaf)) { throw "Converge prerequisite eksik: $required" }
    }

    $profile = if ($ProfileOverride) { $ProfileOverride } else { Get-ConvergeProperty -Object $Config.agents -Name 'converge' }
    if (-not $profile) { throw 'config.agents.converge tanımlı değil.' }
    $loopCfg = Get-ConvergeProperty -Object $Config -Name 'loop'
    $maxRounds = [Math]::Max(1, [int](Get-ConvergeProperty -Object $loopCfg -Name 'max_converge_rounds' -Default 3))
    $currentRound = [int](Get-ConvergeProperty -Object $Ledger.stages.converge -Name 'round' -Default 0)
    $logPath = Join-Path $paths.LogsDir 'converge.log'

    # A provider may have produced a valid append/result before its final stream
    # frame caused contract parsing to fail. Recover that exact round first; do
    # not spend another convergence round or rerun the provider.
    $recovered = Try-RecoverConvergeContract -Ledger $Ledger -ProjectRoot $ProjectRoot -TasksPath $tasksPath -Profile $profile -LogPath $logPath
    if ($null -ne $recovered) { return $recovered }

    $verificationAlreadyAttempted = [bool](Get-ConvergeProperty -Object $Ledger.stages.converge -Name 'final_verification_attempted' -Default $false)
    if ($currentRound -ge $maxRounds -and -not $FinalVerification) {
        $message = "Converge düzeltme turu sınırına ulaştı ($maxRounds); yalnız final doğrulama çalıştırılabilir."
        Set-ConvergeStageState -Ledger $Ledger -Status 'interrupted' -Reason 'converge_circuit_breaker' -Profile $profile -Round $currentRound -ErrorMessage $message
        return [pscustomobject]@{ok=$false;outcome='circuit_breaker';tasks_appended=0;output=$message;round=$currentRound}
    }
    if ($FinalVerification -and $verificationAlreadyAttempted) {
        $message = 'Final converge doğrulaması daha önce çalıştı ve workflow converge olmadı.'
        Set-ConvergeStageState -Ledger $Ledger -Status 'interrupted' -Reason 'converge_circuit_breaker' -Profile $profile -Round $currentRound -ErrorMessage $message
        return [pscustomobject]@{ok=$false;outcome='circuit_breaker';tasks_appended=0;output=$message;round=$currentRound}
    }

    $dirty = @(Get-GitStatusForTier0 -ProjectRoot $ProjectRoot)
    if ($dirty.Count -gt 0) { throw "Converge temiz çalışma ağacı gerektirir: $($dirty -join ' | ')" }
    $baseline = Get-GitBaseline -ProjectRoot $ProjectRoot
    $before = Get-Content -LiteralPath $tasksPath -Raw
    $beforeIds = @(Get-TaskIdsFromMarkdown -Text $before)
    $round = if ($FinalVerification) { $currentRound } else { $currentRound + 1 }
    if ($FinalVerification) {
        Set-ConvergeProperty -Object $Ledger.stages.converge -Name 'final_verification_attempted' -Value $true
    }
    Set-ConvergeStageState -Ledger $Ledger -Status 'running' -Reason $(if ($FinalVerification) { 'final_verification' } else { 'running' }) -Profile $profile -Round $round
    if (Get-Command Write-SddSpectaStatus -ErrorAction SilentlyContinue) {
        $null = Write-SddSpectaStatus -ProjectRoot $ProjectRoot -Ledger $Ledger -Stage 'converge' -Status 'running' -Profile $profile -ConvergenceRound $round -MaxConvergenceRounds $maxRounds -StopReason $(if ($FinalVerification) { 'final_verification' } else { 'running' })
    }
    $startMessage = if ($FinalVerification) { "Converge final doğrulama başladı (düzeltme turları $currentRound/$maxRounds)" } else { "Converge round $round/$maxRounds başladı" }
    Send-SddEvent -Message $startMessage -LogPath $logPath -Category 'workflow' -EventType $(if ($FinalVerification) { 'converge_final_verification_started' } else { 'converge_started' }) -Stage 'converge' -Status 'running'

    $prompt = Get-StagePrompt -ProjectRoot $ProjectRoot -StageName 'converge'
    if ($FinalVerification) {
        $prompt += @"

[FINAL CONVERGENCE VERIFICATION — READ ONLY]
The configured convergence repair-round budget is exhausted. This call is ONLY
the final verification after those repairs.

- Do not modify tasks.md or any repository file.
- Do not append new tasks.
- If the implementation is fully aligned, finish with:
  SDD_CONVERGE_RESULT {"outcome":"converged","tasks_appended":0,"summary":"short summary"}
- If any remaining gap would normally require another convergence task, do NOT
  write it. Finish with:
  SDD_CONVERGE_RESULT {"outcome":"not_converged","tasks_appended":0,"summary":"remaining gap summary"}

This narrower final-verification contract supersedes the normal task-append
behavior above for this call only.
"@
    }
    $adapter = Resolve-Adapter -AgentName ([string](Get-ConvergeProperty -Object $profile -Name 'agent'))
    $result = & $adapter -Request @{
        prompt=$prompt; model=$profile.model; effort=$profile.effort; cwd=$ProjectRoot; log_path=$logPath
        stream_partial=(Test-SddPartialStreaming)
    }
    if (-not $result.ok) {
        $message = "Converge agent tamamlanmadı: $(@($result.denied) -join '; ')"
        Set-ConvergeStageState -Ledger $Ledger -Status 'interrupted' -Reason 'agent_interrupted' -Profile $profile -Round $round -ErrorMessage $message
        return [pscustomobject]@{ok=$false;outcome='agent_interrupted';tasks_appended=0;output=$message;round=$round}
    }

    $head = Get-GitBaseline -ProjectRoot $ProjectRoot
    if ($head -ne $baseline) {
        $message = 'Converge agent commit üretti; yalnız commitlenmemiş append-only tasks.md değişikliğine izin verilir.'
        Set-ConvergeStageState -Ledger $Ledger -Status 'interrupted' -Reason 'write_boundary' -Profile $profile -Round $round -ErrorMessage $message
        return [pscustomobject]@{ok=$false;outcome='write_boundary';tasks_appended=0;output=$message;round=$round}
    }
    $tasksRel = ConvertTo-GitRelativePath -ProjectRoot $ProjectRoot -Path $tasksPath
    $changed = @(Get-ConvergeChangedPaths -ProjectRoot $ProjectRoot)
    $forbidden = @($changed | Where-Object { $_ -ne $tasksRel })
    if ($forbidden.Count -gt 0) {
        $message = "Converge izin verilmeyen dosyaları değiştirdi: $($forbidden -join ', ')"
        Set-ConvergeStageState -Ledger $Ledger -Status 'interrupted' -Reason 'write_boundary' -Profile $profile -Round $round -ErrorMessage $message
        return [pscustomobject]@{ok=$false;outcome='write_boundary';tasks_appended=0;output=$message;round=$round}
    }
    if ($FinalVerification -and $changed.Count -gt 0) {
        # The tree was clean on entry, so any tasks.md change belongs to this
        # verification call. Restore it before opening the circuit breaker.
        $restore = Invoke-GitCapture -ProjectRoot $ProjectRoot -Arguments @('restore','--worktree','--',$tasksRel) -AllowFailure
        $message = if ($restore.ExitCode -eq 0) {
            'Final converge doğrulaması read-only sözleşmesini ihlal ederek tasks.md değiştirdi; değişiklik geri alındı.'
        } else {
            "Final converge doğrulaması tasks.md değiştirdi ve otomatik geri alma başarısız oldu: $($restore.Text)"
        }
        Set-ConvergeStageState -Ledger $Ledger -Status 'interrupted' -Reason 'converge_circuit_breaker' -Profile $profile -Round $round -ErrorMessage $message
        return [pscustomobject]@{ok=$false;outcome='circuit_breaker';tasks_appended=0;output=$message;round=$round}
    }

    $after = Get-Content -LiteralPath $tasksPath -Raw
    $append = Test-ConvergeAppend -Before $before -After $after
    if (-not $append.ok) {
        Set-ConvergeStageState -Ledger $Ledger -Status 'interrupted' -Reason 'append_contract' -Profile $profile -Round $round -ErrorMessage $append.error
        return [pscustomobject]@{ok=$false;outcome='append_contract';tasks_appended=0;output=$append.error;round=$round}
    }

    $lastMessage = [string](Get-ConvergeProperty -Object $result -Name 'last_message' -Default '')
    $payload = Get-ConvergeResultPayload -Text $lastMessage
    if (-not $payload) {
        $message = 'Converge çıktısında zorunlu SDD_CONVERGE_RESULT satırı yok.'
        Set-ConvergeStageState -Ledger $Ledger -Status 'interrupted' -Reason 'contract_missing' -Profile $profile -Round $round -ErrorMessage $message
        return [pscustomobject]@{ok=$false;outcome='contract_missing';tasks_appended=0;output=$message;round=$round}
    }
    try { $report = $payload | ConvertFrom-Json -ErrorAction Stop }
    catch {
        $message = "Converge sonuç JSON'u geçersiz: $($_.Exception.Message)"
        Set-ConvergeStageState -Ledger $Ledger -Status 'interrupted' -Reason 'contract_invalid' -Profile $profile -Round $round -ErrorMessage $message
        return [pscustomobject]@{ok=$false;outcome='contract_invalid';tasks_appended=0;output=$message;round=$round}
    }

    if ($FinalVerification -and [string]$report.outcome -eq 'not_converged') {
        $message = "Converge düzeltme turu sınırı ($maxRounds) sonrasında hâlâ gap var: $([string]$report.summary)"
        Set-ConvergeStageState -Ledger $Ledger -Status 'interrupted' -Reason 'converge_circuit_breaker' -Profile $profile -Round $round -ErrorMessage $message
        Set-ConvergeProperty -Object $Ledger.stages.converge -Name 'summary' -Value ([string]$report.summary)
        return [pscustomobject]@{ok=$false;outcome='circuit_breaker';tasks_appended=0;output=$message;summary=[string]$report.summary;round=$round}
    }

    if (-not $append.changed) {
        if ([string]$report.outcome -ne 'converged') {
            $message = "Converge çıktı/diff çelişkisi: dosya değişmedi ama outcome=$($report.outcome)."
            Set-ConvergeStageState -Ledger $Ledger -Status 'interrupted' -Reason 'contract_mismatch' -Profile $profile -Round $round -ErrorMessage $message
            return [pscustomobject]@{ok=$false;outcome='contract_mismatch';tasks_appended=0;output=$message;round=$round}
        }
        Set-ConvergeStageState -Ledger $Ledger -Status 'completed' -Reason 'converged' -Profile $profile -Round $round
        Set-ConvergeProperty -Object $Ledger.stages.converge -Name 'summary' -Value ([string]$report.summary)
        $null = Save-LoopCheckpoint -Ledger $Ledger -ProjectRoot $ProjectRoot -TasksMdPath $tasksPath -Message 'sdd: record converged workflow' -StateOnly
        Send-SddEvent -Message ([string]$report.summary) -LogPath $logPath -Category 'workflow' -EventType 'converged' -Stage 'converge' -Status 'completed'
        return [pscustomobject]@{ok=$true;outcome='converged';tasks_appended=0;summary=[string]$report.summary;round=$round}
    }

    if ([string]$report.outcome -ne 'tasks_appended') {
        $message = "Converge çıktı/diff çelişkisi: task eklendi ama outcome=$($report.outcome)."
        Set-ConvergeStageState -Ledger $Ledger -Status 'interrupted' -Reason 'contract_mismatch' -Profile $profile -Round $round -ErrorMessage $message
        return [pscustomobject]@{ok=$false;outcome='contract_mismatch';tasks_appended=0;output=$message;round=$round}
    }
    $Ledger = Import-TasksToLedger -Ledger $Ledger -TasksMdPath $tasksPath
    foreach ($id in @($append.new_ids)) {
        $task = @(Get-LedgerTasks $Ledger | Where-Object id -eq $id | Select-Object -First 1)
        if ($task) { Set-ConvergeProperty -Object $task[0] -Name 'convergence_round' -Value $round }
    }
    Set-ConvergeStageState -Ledger $Ledger -Status 'stale' -Reason 'tasks_appended' -Profile $profile -Round $round
    Set-ConvergeProperty -Object $Ledger.stages.converge -Name 'summary' -Value ([string]$report.summary)
    $null = Save-LoopCheckpoint -Ledger $Ledger -ProjectRoot $ProjectRoot -TasksMdPath $tasksPath -Message "sdd: append convergence tasks round $round"
    Send-SddEvent -Message "$(@($append.new_ids).Count) task eklendi: $(@($append.new_ids) -join ', ')" -LogPath $logPath -Category 'workflow' -EventType 'converge_tasks_appended' -Stage 'converge' -Status 'completed'
    return [pscustomobject]@{ok=$true;outcome='tasks_appended';tasks_appended=@($append.new_ids).Count;task_ids=@($append.new_ids);summary=[string]$report.summary;round=$round}
}
