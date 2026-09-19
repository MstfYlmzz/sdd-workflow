#requires -Version 7.0
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'lib/common.ps1')
. (Join-Path $repoRoot 'lib/ledger.ps1')
. (Join-Path $repoRoot 'lib/events.ps1')
. (Join-Path $repoRoot 'lib/stages.ps1')
. (Join-Path $repoRoot 'lib/tier0.ps1')
. (Join-Path $repoRoot 'lib/tier1.ps1')
. (Join-Path $repoRoot 'lib/converge.ps1')
. (Join-Path $repoRoot 'lib/loop.ps1')
. (Join-Path $repoRoot 'lib/workflow.ps1')

function Assert-True([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw "ASSERT FAILED: $Message" }
}

$workflowPath = Join-Path $repoRoot '.specify/workflows/sdd-native/workflow.yml'
$workflowText = Get-Content -LiteralPath $workflowPath -Raw
Assert-True ($workflowText -match 'id:\s*"sdd-native"') 'sdd-native workflow tanımlı olmalı.'
Assert-True ($workflowText -match 'id:\s*tasks-ready' -and $workflowText -match 'id:\s*analyze' -and $workflowText -match 'id:\s*autonomous-closure') 'PoC üç top-level resumable step içermeli.'
Assert-True (@([regex]::Matches($workflowText, 'type:\s*sdd-process')).Count -eq 3) 'PoC her domain çağrısını streaming custom step üzerinden çalıştırmalı.'
Assert-True ($workflowText -notmatch '(?i)\b(codex|claude|cursor)\b') 'Workflow provider/model hardcode etmemeli.'
Assert-True ($workflowText -notmatch 'speckit\.implement') 'Workflow mevcut SDD implement semanticsini bypass etmemeli.'

$stepSource = Get-Content -LiteralPath (Join-Path $repoRoot '.specify/workflows/steps/sdd-process/__init__.py') -Raw
Assert-True ($stepSource -match 'StepStatus\.PAUSED' -and $stepSource -match 'sys\.stdout' -and $stepSource -match 'sys\.stderr') 'Custom step pause ve iki yönlü canlı stream desteklemeli.'

$registry = Get-Content -LiteralPath (Join-Path $repoRoot '.specify/workflows/workflow-registry.json') -Raw | ConvertFrom-Json
Assert-True ($registry.workflows.PSObject.Properties.Name -contains 'sdd-native') 'sdd-native registry içinde görünür olmalı.'

$fixture = Join-Path ([IO.Path]::GetTempPath()) ("sdd-spectatui-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture -Force | Out-Null
try {
    $null = Initialize-SddProject -ProjectRoot $fixture
    Assert-True (Test-Path -LiteralPath (Join-Path $fixture '.specify/workflows/sdd-native/workflow.yml')) 'sdd init custom workflow assetini kurmalı.'
    Assert-True (Test-Path -LiteralPath (Join-Path $fixture '.specify/workflows/steps/sdd-process/__init__.py')) 'sdd init custom streaming step assetini kurmalı.'

    foreach ($dir in @('specs/001-native','src')) {
        New-Item -ItemType Directory -Path (Join-Path $fixture $dir) -Force | Out-Null
    }
    Set-Content -LiteralPath (Join-Path $fixture '.specify/feature.json') -Value '{"feature_directory":"specs/001-native"}' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $fixture 'specs/001-native/spec.md') -Value '# Spec' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $fixture 'specs/001-native/plan.md') -Value '# Plan' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $fixture 'specs/001-native/tasks.md') -Value @(
        '# Tasks',
        '',
        '## Phase 1: Existing',
        '',
        '- [x] T001 Existing fixture task'
    ) -Encoding utf8

    $config = @'
agents:
  analyze:   { agent: codex, model: fixture, effort: medium }
  implement: { agent: codex, model: fixture, effort: medium }
  converge:  { agent: codex, model: fixture, effort: medium }
gates:
  - name: diff-check
    cmd: git diff --check
loop:
  batch_size: 1
  max_attempts: 2
  escalate_at: 2
  circuit_breaker: 2
  observe_every: 0
  enable_converge: false
  max_converge_rounds: 2
analyze:
  block_on: critical
ui:
  mode: auto
  prompt_on_stage_start: false
'@
    Set-Content -LiteralPath (Join-Path $fixture '.sdd/config.yaml') -Value $config -Encoding utf8

    $ledger = Read-Ledger -StatePath (Join-Path $fixture '.sdd/state.json')
    $ledger.spec_id = '001-native'
    $ledger.stages.spec.status = 'completed'
    $ledger.stages.plan.status = 'completed'
    $ledger.stages.tasks.status = 'completed'
    $ledger.stages.analyze.status = 'completed'
    $ledger.stages.analyze | Add-Member -NotePropertyName highest_severity -NotePropertyValue 'none' -Force
    $ledger.stages.analyze | Add-Member -NotePropertyName finding_count -NotePropertyValue 0 -Force
    $ledger.stages.analyze | Add-Member -NotePropertyName summary -NotePropertyValue 'fixture clean' -Force
    $ledger.tasks = @(
        [pscustomobject]@{
            id='T001'; title='Existing fixture task'; status='done'; attempts=1
            files=@(); depends_on=@(); story=$null; phase=1; parallel=$false
            agent='fixture'; commit_sha=$null; last_gate_output=$null; updated_at=$null
        }
    )
    Write-Ledger -Ledger $ledger -StatePath (Join-Path $fixture '.sdd/state.json')

    & git -C $fixture config user.email 'sdd-test@example.invalid'
    & git -C $fixture config user.name 'SDD Test'
    & git -C $fixture add .
    & git -C $fixture commit --quiet -m 'native workflow fixture'

    $prepare = Invoke-SddWorkflowStep -ProjectRoot $fixture -Step prepare -UiMode plain
    Assert-True $prepare.ok 'Prepare step fixture task ledgerını kabul etmeli.'

    $analysis = Invoke-SddWorkflowStep -ProjectRoot $fixture -Step analyze -UiMode plain
    Assert-True ($analysis.ok -and -not $analysis.pause) 'Güncel completed analyze tekrar agent çağırmadan kullanılabilmeli.'

    $closure = Invoke-SddWorkflowStep -ProjectRoot $fixture -Step closure -UiMode plain
    Assert-True ($closure.ok -and -not $closure.pause) 'Pending task yokken strict Tier 1 sonrası closure tamamlanmalı.'

    $after = Read-Ledger -StatePath (Join-Path $fixture '.sdd/state.json')
    Assert-True ($after.stages.implement.status -eq 'completed') 'Closure implement stageini completed bırakmalı.'
    Assert-True (@(Get-GitStatusForTier0 -ProjectRoot $fixture).Count -eq 0) 'Bridge checkpointlerinden sonra çalışma ağacı temiz olmalı.'

    $after.tasks[0].status = 'blocked'
    $after.stages.implement.status = 'not_started'
    Write-Ledger -Ledger $after -StatePath (Join-Path $fixture '.sdd/state.json')
    & git -C $fixture add -f .sdd/state.json
    & git -C $fixture commit --quiet -m 'fixture blocked state'

    $failed = $false
    try {
        $null = Invoke-SddWorkflowStep -ProjectRoot $fixture -Step closure -UiMode plain
    } catch {
        $failed = $_.Exception.Message -match 'blocked'
    }
    Assert-True $failed 'Domain stop reason Spec Kit process failureına çevrilmeli.'
    $preserved = Read-Ledger -StatePath (Join-Path $fixture '.sdd/state.json')
    Assert-True ($preserved.tasks[0].status -eq 'blocked') 'Failure sonrası authoritative domain state korunmalı.'

    $null = Initialize-SddEventContext -ProjectRoot $fixture -UiMode raw -Stage 'implement'
    try {
        Assert-True (Test-SddPartialStreaming) 'Raw workflow bridge modu partial agent streaming açmalı.'
    } finally {
        $null = Close-SddEventContext -Status completed
    }

    Write-Host 'SPECTATUI WORKFLOW INTEGRATION OK' -ForegroundColor Green
} finally {
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
