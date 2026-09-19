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
    if ($After -eq $Before) {
        return [pscustomobject]@{ok=$true;changed=$false;new_ids=@();error=$null}
    }
    if (-not $After.StartsWith($Before, [StringComparison]::Ordinal)) {
        return [pscustomobject]@{ok=$false;changed=$true;new_ids=@();error='tasks.md append-only değil; mevcut içerik değiştirildi.'}
    }
    $suffix = $After.Substring($Before.Length)
    if ($suffix -notmatch '(?m)^##\s+Phase\s+\d+:\s+Convergence\s*$') {
        return [pscustomobject]@{ok=$false;changed=$true;new_ids=@();error='Eklenen içerikte yeni bir Convergence fazı yok.'}
    }
    $beforeIds = @(Get-TaskIdsFromMarkdown -Text $Before)
    $afterIds = @(Get-TaskIdsFromMarkdown -Text $After)
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
        [switch] $Force
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
    if ($currentRound -ge $maxRounds) {
        $message = "Converge maksimum tur sınırına ulaştı ($maxRounds)."
        Set-ConvergeStageState -Ledger $Ledger -Status 'interrupted' -Reason 'converge_circuit_breaker' -Profile $profile -Round $currentRound -ErrorMessage $message
        return [pscustomobject]@{ok=$false;outcome='circuit_breaker';tasks_appended=0;output=$message;round=$currentRound}
    }

    $dirty = @(Get-GitStatusForTier0 -ProjectRoot $ProjectRoot)
    if ($dirty.Count -gt 0) { throw "Converge temiz çalışma ağacı gerektirir: $($dirty -join ' | ')" }
    $baseline = Get-GitBaseline -ProjectRoot $ProjectRoot
    $before = Get-Content -LiteralPath $tasksPath -Raw
    $beforeIds = @(Get-TaskIdsFromMarkdown -Text $before)
    $round = $currentRound + 1
    $logPath = Join-Path $paths.LogsDir 'converge.log'
    Set-ConvergeStageState -Ledger $Ledger -Status 'running' -Reason 'running' -Profile $profile -Round $round
    if (Get-Command Write-SddSpectaStatus -ErrorAction SilentlyContinue) {
        $null = Write-SddSpectaStatus -ProjectRoot $ProjectRoot -Ledger $Ledger -Stage 'converge' -Status 'running' -Profile $profile -ConvergenceRound $round -MaxConvergenceRounds $maxRounds -StopReason 'running'
    }
    Send-SddEvent -Message "Converge round $round/$maxRounds başladı" -LogPath $logPath -Category 'workflow' -EventType 'converge_started' -Stage 'converge' -Status 'running'

    $prompt = Get-StagePrompt -ProjectRoot $ProjectRoot -StageName 'converge'
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

    $after = Get-Content -LiteralPath $tasksPath -Raw
    $append = Test-ConvergeAppend -Before $before -After $after
    if (-not $append.ok) {
        Set-ConvergeStageState -Ledger $Ledger -Status 'interrupted' -Reason 'append_contract' -Profile $profile -Round $round -ErrorMessage $append.error
        return [pscustomobject]@{ok=$false;outcome='append_contract';tasks_appended=0;output=$append.error;round=$round}
    }

    $lastMessage = [string](Get-ConvergeProperty -Object $result -Name 'last_message' -Default '')
    $match = [regex]::Match($lastMessage, '(?m)^SDD_CONVERGE_RESULT\s+(\{[^\r\n]+\})\s*$')
    if (-not $match.Success) {
        $message = 'Converge çıktısında zorunlu SDD_CONVERGE_RESULT satırı yok.'
        Set-ConvergeStageState -Ledger $Ledger -Status 'interrupted' -Reason 'contract_missing' -Profile $profile -Round $round -ErrorMessage $message
        return [pscustomobject]@{ok=$false;outcome='contract_missing';tasks_appended=0;output=$message;round=$round}
    }
    try { $report = $match.Groups[1].Value | ConvertFrom-Json -ErrorAction Stop }
    catch {
        $message = "Converge sonuç JSON'u geçersiz: $($_.Exception.Message)"
        Set-ConvergeStageState -Ledger $Ledger -Status 'interrupted' -Reason 'contract_invalid' -Profile $profile -Round $round -ErrorMessage $message
        return [pscustomobject]@{ok=$false;outcome='contract_invalid';tasks_appended=0;output=$message;round=$round}
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
