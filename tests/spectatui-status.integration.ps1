#requires -Version 7.0
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'lib/common.ps1')
. (Join-Path $repoRoot 'lib/ledger.ps1')
. (Join-Path $repoRoot 'lib/spectatui.ps1')
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
    $null = Write-SddSpectaStatus @args1

    $path = Join-Path $fixture '.specify/sdd-status.json'
    Assert-True (Test-Path -LiteralPath $path) 'Projection dosyası üretilmeli.'
    $doc = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    Assert-True (-not [bool]$doc.authoritative) 'Projection authoritative state olmamalı.'
    Assert-True ($doc.spec_id -eq '001-status' -and $doc.stage -eq 'implement' -and $doc.status -eq 'running') 'Spec/stage/status doğru olmalı.'
    Assert-True ($doc.tasks.total -eq 3 -and $doc.tasks.done -eq 1 -and $doc.tasks.pending -eq 1 -and $doc.tasks.blocked -eq 1) 'Task sayaçları ledgerdan türetilmeli.'
    Assert-True (@($doc.runtime.batch).Count -eq 1 -and $doc.runtime.batch[0] -eq 'T002') 'Aktif batch görünmeli.'
    Assert-True ($doc.runtime.batch_number -eq 4 -and $doc.runtime.attempt -eq 2 -and $doc.runtime.max_attempts -eq 3) 'Batch/retry metadata görünmeli.'
    Assert-True ($doc.runtime.agent -eq 'codex' -and $doc.runtime.model -eq 'gpt-test' -and $doc.runtime.effort -eq 'high') 'Routing metadata görünmeli.'

    $null = Write-SddSpectaConfig -ProjectRoot $fixture
    $configProjectionPath = Join-Path $fixture '.specify/sdd-config.json'
    Assert-True (Test-Path -LiteralPath $configProjectionPath) 'Routing projection üretilmeli.'
    $configProjection = Get-Content -LiteralPath $configProjectionPath -Raw | ConvertFrom-Json
    Assert-True (-not [bool]$configProjection.authoritative) 'Routing projection authoritative olmamalı.'
    Assert-True (@($configProjection.routes).Count -eq 6) 'Altı SDD stage routing satırı projection içinde olmalı.'
    $implementRoute = @($configProjection.routes | Where-Object stage -eq 'implement')[0]
    Assert-True ($implementRoute.agent -and $implementRoute.model -and $implementRoute.effort) 'Implement routing bilgisi eksiksiz görünmeli.'

    $null = Set-SddStageProfile -ConfigPath (Join-Path $fixture '.sdd/config.yaml') -StageName analyze -Agent claude -Model sonnet -Effort high
    $configProjection = Get-Content -LiteralPath $configProjectionPath -Raw | ConvertFrom-Json
    $analyzeRoute = @($configProjection.routes | Where-Object stage -eq 'analyze')[0]
    Assert-True ($analyzeRoute.agent -eq 'claude' -and $analyzeRoute.model -eq 'sonnet' -and $analyzeRoute.effort -eq 'high') 'Config değişikliği routing projectiona anında yansımalı.'

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

    $streamEvent = [pscustomobject]@{
        timestamp='2026-09-19T21:18:06+03:00';run_id='run-1';sequence=29;stage='implement'
        category='command_output';event_type='gate_output';severity='info';status=''
        message='raw test output';provider='';exit_code=$null;duration_ms=$null
    }
    $null = Write-SddSpectaEvent -ProjectRoot $fixture -Event $streamEvent
    $eventDoc = Get-Content -LiteralPath $eventPath -Raw | ConvertFrom-Json
    Assert-True (@($eventDoc.events).Count -eq 1) 'Ham command output parsed runtime event feedini şişirmemeli.'

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
        $dirty = @(Get-GitStatusForTier0 -ProjectRoot $fixture)
        Assert-True (-not ($dirty -match '\.spectatui\.toml')) '.spectatui.toml Tier 0 clean-worktree kontrolünü bozmamalı.'
    } finally {
        Pop-Location
    }

    Write-Host 'SPECTATUI STATUS INTEGRATION OK' -ForegroundColor Green
} finally {
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
