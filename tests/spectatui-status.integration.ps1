#requires -Version 7.0
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'lib/common.ps1')
. (Join-Path $repoRoot 'lib/ledger.ps1')
. (Join-Path $repoRoot 'lib/spectatui.ps1')
. (Join-Path $repoRoot 'lib/events.ps1')
. (Join-Path $repoRoot 'lib/stages.ps1')
. (Join-Path $repoRoot 'lib/tier0.ps1')

function Assert-True([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw "ASSERT FAILED: $Message" }
}

$fixture = Join-Path ([IO.Path]::GetTempPath()) ("sdd-specta-status-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture -Force | Out-Null
try {
    $null = Initialize-SddProject -ProjectRoot $fixture
    $statePath = Join-Path $fixture '.sdd/state.json'
    $ledger = Read-Ledger -StatePath $statePath
    $ledger.spec_id = '001-status'
    $ledger.stages.implement.status = 'running'
    $ledger.stages.implement | Add-Member -NotePropertyName agent -NotePropertyValue 'codex' -Force
    $ledger.stages.implement | Add-Member -NotePropertyName model -NotePropertyValue 'gpt-test' -Force
    $ledger.stages.implement | Add-Member -NotePropertyName effort -NotePropertyValue 'medium' -Force
    $ledger.tasks = @(
        [pscustomobject]@{id='T001';title='done';status='done';attempts=1;files=@();depends_on=@();story=$null;phase=1;parallel=$false},
        [pscustomobject]@{id='T002';title='pending';status='pending';attempts=1;files=@();depends_on=@();story=$null;phase=1;parallel=$false},
        [pscustomobject]@{id='T003';title='blocked';status='blocked';attempts=3;files=@();depends_on=@();story=$null;phase=1;parallel=$false}
    )
    Write-Ledger -Ledger $ledger -StatePath $statePath

    $ledger.stages.spec.status = 'completed'
    $ledger.stages.plan.status = 'completed'
    $ledger.stages.tasks.status = 'completed'
    $ledger.stages.analyze.status = 'completed'
    $ledger.stages.implement.status = 'not_started'
    Assert-True ((Get-SddSpectaStage -Ledger $ledger) -eq 'implement') 'Analyze tamamlandıktan sonra implement not_started ise projection implement stage göstermeli.'
    $ledger.stages.implement.status = 'interrupted'
    Assert-True ((Get-SddSpectaStage -Ledger $ledger) -eq 'implement') 'Interrupted implement task aşamasına geri düşmemeli.'
    $ledger.stages.implement.status = 'completed'
    $ledger.stages.converge.status = 'not_started'
    $ledger.stages.converge.round = 0
    Assert-True ((Get-SddSpectaStage -Ledger $ledger) -eq 'implement') 'Converge başlamadan implement completed görünümü korunmalı.'
    $ledger.stages.converge.status = 'running'
    Assert-True ((Get-SddSpectaStage -Ledger $ledger) -eq 'converge') 'Converge başladığında projection converge stage göstermeli.'
    $ledger.stages.converge.status = 'not_started'
    $ledger.stages.implement.status = 'running'

    $profile = [pscustomobject]@{agent='codex';model='gpt-test';effort='high'}
    $args1 = @{
        ProjectRoot = $fixture
        Ledger = $ledger
        Stage = 'implement'
        Status = 'running'
        Batch = @($ledger.tasks[1])
        BatchNumber = 4
        Attempt = 2
        MaxAttempts = 3
        Profile = $profile
    }
    $featureDir = Join-Path $fixture 'specs/001-status'
    New-Item -ItemType Directory -Path $featureDir -Force | Out-Null
    [ordered]@{ feature_directory = 'specs/001-status' } |
        ConvertTo-Json |
        Set-Content -LiteralPath (Join-Path $fixture '.specify/feature.json') -Encoding utf8

    $null = Write-SddSpectaStatus @args1

    $path = Join-Path $fixture '.specify/sdd-status.json'
    Assert-True (Test-Path -LiteralPath $path) 'Projection dosyası üretilmeli.'
    $doc = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    Assert-True (-not [bool]$doc.authoritative) 'Projection authoritative state olmamalı.'
    Assert-True ($doc.spec_id -eq '001-status' -and $doc.stage -eq 'implement' -and $doc.status -eq 'running') 'Projection aktif Spec Kit feature kimliğini stage/status ile birlikte kullanmalı.'
    Assert-True ($doc.tasks.total -eq 3 -and $doc.tasks.done -eq 1 -and $doc.tasks.pending -eq 1 -and $doc.tasks.blocked -eq 1) 'Task sayaçları ledgerdan türetilmeli.'
    Assert-True (@($doc.runtime.batch).Count -eq 1 -and $doc.runtime.batch[0] -eq 'T002') 'Aktif batch görünmeli.'
    Assert-True ($doc.runtime.batch_number -eq 4 -and $doc.runtime.attempt -eq 2 -and $doc.runtime.max_attempts -eq 3) 'Batch/retry metadata görünmeli.'
    Assert-True ($doc.runtime.agent -eq 'codex' -and $doc.runtime.model -eq 'gpt-test' -and $doc.runtime.effort -eq 'high') 'Routing metadata görünmeli.'

    $configProjectionPath = Join-Path $fixture '.specify/sdd-config.json'
    if (Test-Path -LiteralPath $configProjectionPath) { Remove-Item -LiteralPath $configProjectionPath -Force }
    $null = Sync-SddSpectaStatusFromDisk -ProjectRoot $fixture
    Assert-True (Test-Path -LiteralPath $configProjectionPath) 'Status sync routing projectionı da üretmeli.'

    $null = Write-SddSpectaConfig -ProjectRoot $fixture
    Assert-True (Test-Path -LiteralPath $configProjectionPath) 'Routing projection üretilmeli.'
    $configProjection = Get-Content -LiteralPath $configProjectionPath -Raw | ConvertFrom-Json
    Assert-True (-not [bool]$configProjection.authoritative) 'Routing projection authoritative olmamalı.'
    Assert-True (@($configProjection.routes).Count -eq 6) 'Altı SDD stage routing satırı projection içinde olmalı.'
    Assert-True (@($configProjection.providers).Count -eq 3) 'Üç provider model kataloğu routing projection içinde olmalı.'
    $codexCatalog = @($configProjection.providers | Where-Object agent -eq 'codex')[0]
    $claudeCatalog = @($configProjection.providers | Where-Object agent -eq 'claude')[0]
    $cursorCatalog = @($configProjection.providers | Where-Object agent -eq 'cursor')[0]
    Assert-True (@($codexCatalog.models).Count -gt 0 -and @($claudeCatalog.models).Count -gt 0 -and @($cursorCatalog.models).Count -gt 0) 'Her provider için seçilebilir model listesi bulunmalı.'
    Assert-True (@($cursorCatalog.efforts).Count -eq 1 -and $cursorCatalog.efforts[0] -eq 'medium') 'Cursor effort listesi yalnız medium olmalı.'
    $implementRoute = @($configProjection.routes | Where-Object stage -eq 'implement')[0]
    Assert-True ($implementRoute.agent -and $implementRoute.model -and $implementRoute.effort) 'Implement routing bilgisi eksiksiz görünmeli.'

    $legacyLedger = Read-Ledger -StatePath $statePath
    $legacyLedger.spec_id = 'legacy-project-name'
    $tasksPath = Join-Path $featureDir 'tasks.md'
    @(
        '# Tasks',
        '- [ ] T001 Example task'
    ) | Set-Content -LiteralPath $tasksPath -Encoding utf8
    $legacyLedger = Import-TasksToLedger -Ledger $legacyLedger -TasksMdPath $tasksPath
    Assert-True ($legacyLedger.spec_id -eq '001-status') 'Task import eski repo-adı spec_id değerini feature klasörüyle düzeltmeli.'

    $null = Set-SddStageProfile -ConfigPath (Join-Path $fixture '.sdd/config.yaml') -StageName analyze -Agent claude -Model sonnet -Effort high
    $configProjection = Get-Content -LiteralPath $configProjectionPath -Raw | ConvertFrom-Json
    $analyzeRoute = @($configProjection.routes | Where-Object stage -eq 'analyze')[0]
    Assert-True ($analyzeRoute.agent -eq 'claude' -and $analyzeRoute.model -eq 'sonnet' -and $analyzeRoute.effort -eq 'high') 'Config değişikliği routing projectiona anında yansımalı.'

    Push-Location $fixture
    try {
        $jsonText = @(& (Join-Path $repoRoot 'bin/sdd.ps1') config --json) -join [Environment]::NewLine
        $jsonDoc = $jsonText | ConvertFrom-Json
        Assert-True (@($jsonDoc.routes).Count -eq 6) 'sdd config --json altı routing satırı döndürmeli.'

        $setText = @(& (Join-Path $repoRoot 'bin/sdd.ps1') config set tasks -Agent cursor -Model auto -Effort medium) -join [Environment]::NewLine
        $setDoc = $setText | ConvertFrom-Json
        $tasksRoute = @($setDoc.routes | Where-Object stage -eq 'tasks')[0]
        Assert-True ($tasksRoute.agent -eq 'cursor' -and $tasksRoute.model -eq 'auto') 'Noninteractive config set SpectaTUI backend sözleşmesini uygulamalı.'
    } finally {
        Pop-Location
    }

    $event = [pscustomobject]@{
        timestamp='2026-09-19T21:18:05+03:00';run_id='run-1';sequence=28;stage='implement'
        category='gate';event_type='gate_completed';severity='info';status='failed'
        message='Tier 1/reference-frame-tests';provider='';exit_code=1;duration_ms=312
    }
    $null = Write-SddSpectaEvent -ProjectRoot $fixture -Event $event
    $eventPath = Join-Path $fixture '.specify/sdd-events.json'
    Assert-True (Test-Path -LiteralPath $eventPath) 'Parsed event projection dosyası üretilmeli.'
    $eventDoc = Get-Content -LiteralPath $eventPath -Raw | ConvertFrom-Json
    Assert-True (-not [bool]$eventDoc.authoritative) 'Event projection authoritative olmamalı.'
    Assert-True (@($eventDoc.events).Count -eq 1) 'Event feed ilk anlamlı olayı içermeli.'
    Assert-True ($eventDoc.events[0].message -eq 'Tier 1/reference-frame-tests' -and $eventDoc.events[0].status -eq 'failed') 'Event özeti UI için gerekli alanları korumalı.'

    $agentStart = [pscustomobject]@{
        timestamp='2026-09-19T21:18:05+03:00';run_id='run-1';sequence=28;stage='implement'
        category='agent';event_type='agent_started';severity='info';status='running'
        message='Codex agent başladı';command='';provider='codex';exit_code=$null;duration_ms=$null
    }
    $null = Write-SddSpectaEvent -ProjectRoot $fixture -Event $agentStart
    $commandEvent = [pscustomobject]@{
        timestamp='2026-09-19T21:18:05+03:00';run_id='run-1';sequence=29;stage='implement'
        category='command';event_type='command_started';severity='info';status='running'
        message='terminal';command='node --test tests/reference-frame.test.js';provider='codex';exit_code=$null;duration_ms=$null
    }
    $null = Write-SddSpectaEvent -ProjectRoot $fixture -Event $commandEvent
    $activityDoc = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    Assert-True ($activityDoc.runtime.agent_started_at_ms -gt 0 -and $activityDoc.runtime.last_activity_at_ms -gt 0) 'Agent süre/heartbeat telemetry projectiona yazılmalı.'
    Assert-True ($activityDoc.runtime.activity_kind -eq 'terminal' -and $activityDoc.runtime.activity_detail -match 'node --test') 'Aktif terminal işlemi runtime projectionda görünmeli.'
    $eventDoc = Get-Content -LiteralPath $eventPath -Raw | ConvertFrom-Json
    $projectedCommand = @($eventDoc.events | Where-Object event_type -eq 'command_started')[-1]
    Assert-True ($projectedCommand.command -eq 'node --test tests/reference-frame.test.js') 'Structured command event ham output olmadan komutu korumalı.'

    $streamEvent = [pscustomobject]@{
        timestamp='2026-09-19T21:18:06+03:00';run_id='run-1';sequence=29;stage='implement'
        category='command_output';event_type='gate_output';severity='info';status=''
        message='raw test output';provider='';exit_code=$null;duration_ms=$null
    }
    $beforeRawCount = @($eventDoc.events).Count
    $null = Write-SddSpectaEvent -ProjectRoot $fixture -Event $streamEvent
    $eventDoc = Get-Content -LiteralPath $eventPath -Raw | ConvertFrom-Json
    Assert-True (@($eventDoc.events).Count -eq $beforeRawCount) 'Ham command output parsed runtime event feedini şişirmemeli.'

    $partialEvent = [pscustomobject]@{
        timestamp='2026-09-19T21:18:07+03:00';run_id='run-1';sequence=30;stage='implement'
        category='assistant';event_type='agent_message_partial';severity='info';status=''
        message='Hello ';provider='cursor';exit_code=$null;duration_ms=$null
    }
    $null = Write-SddSpectaEvent -ProjectRoot $fixture -Event $partialEvent
    $partialEvent.sequence = 31
    $partialEvent.message = 'world'
    $null = Write-SddSpectaEvent -ProjectRoot $fixture -Event $partialEvent
    $liveDoc = Get-Content -LiteralPath $eventPath -Raw | ConvertFrom-Json
    Assert-True (@($liveDoc.events | Where-Object event_type -eq 'agent_message_live').Count -le 1) 'Partial agent deltaları tek canlı mesaja coalesce edilmeli.'

    $finalAgentEvent = [pscustomobject]@{
        timestamp='2026-09-19T21:18:08+03:00';run_id='run-1';sequence=32;stage='implement'
        category='assistant';event_type='agent_message';severity='info';status='completed'
        message='Hello world';provider='cursor';exit_code=$null;duration_ms=$null
    }
    $null = Write-SddSpectaEvent -ProjectRoot $fixture -Event $finalAgentEvent
    $finalAgentDoc = Get-Content -LiteralPath $eventPath -Raw | ConvertFrom-Json
    Assert-True (@($finalAgentDoc.events | Where-Object event_type -eq 'agent_message_live').Count -eq 0) 'Final agent mesajı canlı partial kaydını temizlemeli.'
    Assert-True (@($finalAgentDoc.events | Where-Object { $_.event_type -eq 'agent_message' -and $_.message -eq 'Hello world' }).Count -eq 1) 'Parsed Agent Output final mesajı korumalı.'

    $ledger.stages.implement.status = 'interrupted'
    Write-Ledger -Ledger $ledger -StatePath $statePath
    $null = Sync-SddSpectaStatusFromDisk -ProjectRoot $fixture
    $interruptedDoc = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    Assert-True ($interruptedDoc.stage -eq 'implement' -and $interruptedDoc.status -eq 'interrupted') 'Yarıda kesilmiş implement projectionda task aşamasına geri düşmemeli.'

    $secretEvent = [pscustomobject]@{
        timestamp='2026-09-19T21:18:09+03:00';run_id='run-1';sequence=33;stage='implement'
        category='assistant';event_type='agent_message';severity='info';status='completed'
        message='api_key=super-secret value';provider='codex';exit_code=$null;duration_ms=$null
    }
    $null = Write-SddSpectaEvent -ProjectRoot $fixture -Event $secretEvent
    $secretDoc = Get-Content -LiteralPath $eventPath -Raw | ConvertFrom-Json
    $secretLine = @($secretDoc.events | Where-Object sequence -eq 33)[0].message
    Assert-True ($secretLine -match 'api_key=<redacted>' -and $secretLine -notmatch 'super-secret') 'SpectaTUI event projection obvious credentials redakte etmeli.'

    $ledger.stages.implement.status = 'completed'
    $ledger.stages.converge.status = 'running'
    $ledger.stages.converge | Add-Member -NotePropertyName round -NotePropertyValue 2 -Force
    $args2 = @{
        ProjectRoot = $fixture
        Ledger = $ledger
        Stage = 'converge'
        Status = 'running'
        Profile = [pscustomobject]@{agent='claude';model='sonnet';effort='medium'}
        ConvergenceRound = 2
        MaxConvergenceRounds = 3
    }
    $null = Write-SddSpectaStatus @args2
    $doc = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    Assert-True ($doc.stage -eq 'converge') 'Converge explicit stage olarak görünmeli.'
    Assert-True ($doc.runtime.convergence_round -eq 2 -and $doc.runtime.max_convergence_rounds -eq 3) 'Convergence round görünmeli.'

    Push-Location $fixture
    try {
        & git check-ignore -q .specify/sdd-status.json
        Assert-True ($LASTEXITCODE -eq 0) 'Projection Git-ignore edilmiş olmalı.'
        & git check-ignore -q .specify/sdd-events.json
        Assert-True ($LASTEXITCODE -eq 0) 'Event projection Git-ignore edilmiş olmalı.'
        & git check-ignore -q .specify/sdd-config.json
        Assert-True ($LASTEXITCODE -eq 0) 'Routing projection Git-ignore edilmiş olmalı.'

        & git add .
        & git -c user.email=sdd-test@example.invalid -c user.name=SDD-Test commit -m baseline --quiet
        Set-Content -LiteralPath (Join-Path $fixture '.spectatui.toml') -Value 'theme = "dark"' -Encoding utf8
        Add-Content -LiteralPath (Join-Path $fixture '.sdd/config.yaml') -Value "# local routing edit" -Encoding utf8
        Set-Content -LiteralPath (Join-Path $fixture '.sdd/state.json') -Value '{"schema_version":1,"stages":{},"tasks":[]}' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $fixture '.specify/sdd-status.json') -Value '{"stage":"implement"}' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $fixture '.specify/sdd-events.json') -Value '{"events":[]}' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $fixture '.specify/sdd-config.json') -Value '{"routes":[]}' -Encoding utf8
        $dirty = @(Get-GitStatusForTier0 -ProjectRoot $fixture)
        Assert-True (-not ($dirty -match '\.spectatui\.toml')) '.spectatui.toml Tier 0 clean-worktree kontrolünü bozmamalı.'
        Assert-True (-not ($dirty -match '\.sdd/config\.yaml')) 'Routing config değişikliği Tier 0 clean-worktree kontrolünü bozmamalı.'
        Assert-True (-not ($dirty -match '\.sdd/state\.json')) 'Authoritative SDD state değişikliği Tier 0 clean-worktree kontrolünü bozmamalı.'
        Assert-True (-not ($dirty -match '\.specify/sdd-(status|events|config)\.json')) 'SpectaTUI projection dosyaları Tier 0 clean-worktree kontrolünü bozmamalı.'
    } finally {
        Pop-Location
    }

    Write-Host 'SPECTATUI STATUS INTEGRATION OK' -ForegroundColor Green
} finally {
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
