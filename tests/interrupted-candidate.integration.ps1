#requires -Version 7.0
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'lib/common.ps1')
. (Join-Path $repoRoot 'lib/ledger.ps1')
. (Join-Path $repoRoot 'lib/stages.ps1')
. (Join-Path $repoRoot 'lib/tier0.ps1')
. (Join-Path $repoRoot 'lib/tier1.ps1')
. (Join-Path $repoRoot 'lib/loop.ps1')

function Assert-True([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw "ASSERT FAILED: $Message" }
}

$script:agentCalls = 0
function Invoke-MustNotRunAgent {
    param([Parameter(Mandatory)] [hashtable] $Request)
    $script:agentCalls++
    throw 'Committed interrupted candidate should be revalidated, not reimplemented.'
}
function Resolve-Adapter { param([string] $AgentName) return 'Invoke-MustNotRunAgent' }

$fixture = Join-Path ([IO.Path]::GetTempPath()) ("sdd-interrupted-candidate-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture -Force | Out-Null
try {
    foreach ($dir in @('.sdd','.sdd/logs','.specify','specs/001-interrupted','src')) {
        New-Item -ItemType Directory -Path (Join-Path $fixture $dir) -Force | Out-Null
    }
    Set-Content -LiteralPath (Join-Path $fixture '.gitignore') -Value @('.sdd/logs/','.sdd/runs.jsonl') -Encoding utf8
    Set-Content -LiteralPath (Join-Path $fixture '.specify/feature.json') -Value '{"feature_directory":"specs/001-interrupted"}' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $fixture 'specs/001-interrupted/tasks.md') -Value @('# Tasks','','- [ ] T001 Create `src/result.txt`') -Encoding utf8

    $ledger = [pscustomobject]@{
        version=1; spec_id='001-interrupted'
        stages=[pscustomobject]@{
            spec=[pscustomobject]@{status='completed'};plan=[pscustomobject]@{status='completed'}
            tasks=[pscustomobject]@{status='completed'};analyze=[pscustomobject]@{status='completed';highest_severity='none';finding_count=0;summary='clean'}
            implement=[pscustomobject]@{status='not_started'}
        }
        gate_baseline=[pscustomobject]@{}
        tasks=@([pscustomobject]@{id='T001';title='Create `src/result.txt`';status='pending';attempts=0;files=@('src/result.txt');depends_on=@();agent=$null;commit_sha=$null;last_gate_output=$null;updated_at=$null})
    }
    Write-Ledger -Ledger $ledger -StatePath (Join-Path $fixture '.sdd/state.json')

    & git -C $fixture init --quiet
    & git -C $fixture config user.email 'sdd-test@example.invalid'
    & git -C $fixture config user.name 'SDD Test'
    & git -C $fixture add .
    & git -C $fixture commit --quiet -m 'initial'
    $baseline = (& git -C $fixture rev-parse HEAD).Trim()

    Set-Content -LiteralPath (Join-Path $fixture 'src/result.txt') -Value @('one','two','three') -Encoding utf8
    & git -C $fixture add src/result.txt
    & git -C $fixture commit --quiet -m 'T001 implementation'
    $candidate = (& git -C $fixture rev-parse HEAD).Trim()

    $ledger.stages.implement.status = 'running'
    $ledger.stages.implement | Add-Member -NotePropertyName stop_reason -NotePropertyValue 'running' -Force
    $ledger.stages.implement | Add-Member -NotePropertyName active_batch -NotePropertyValue @('T001') -Force
    $ledger.stages.implement | Add-Member -NotePropertyName active_baseline -NotePropertyValue $baseline -Force
    Write-Ledger -Ledger $ledger -StatePath (Join-Path $fixture '.sdd/state.json')

    $config=[pscustomobject]@{
        agents=[pscustomobject]@{implement=[pscustomobject]@{agent='fake';model='gpt-5.6-sol';effort='medium'}}
        gates=@([pscustomobject]@{name='diff-check';cmd='git diff --check'})
        loop=[pscustomobject]@{batch_size=1;max_attempts=3;escalate_at=2;circuit_breaker=3;observe_every=0}
    }

    $result=Invoke-ImplementLoop -Config $config -Ledger $ledger -ProjectRoot $fixture -ObserveEvery 1

    Assert-True ($result.ok -and $result.reason -eq 'observe_pause') 'Recovered candidate should validate and reach observation pause.'
    Assert-True ($script:agentCalls -eq 0) 'Recovered committed candidate must not call the implementation agent again.'
    Assert-True ($ledger.tasks[0].status -eq 'done') 'Recovered candidate task should become done after validation.'
    Assert-True ($ledger.tasks[0].commit_sha -eq $candidate) 'Recovered candidate SHA should be recorded.'
    Assert-True (@($ledger.stages.implement.active_batch).Count -eq 0) 'Active batch must clear after successful recovery validation.'
    Assert-True ([string]::IsNullOrWhiteSpace([string]$ledger.stages.implement.active_baseline)) 'Active baseline must clear after successful recovery validation.'
    Assert-True (@(Get-GitStatusForTier0 -ProjectRoot $fixture).Count -eq 0) 'Recovered candidate checkpoint should leave the worktree clean.'
    Write-Host 'INTERRUPTED CANDIDATE INTEGRATION OK' -ForegroundColor Green
} finally {
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
