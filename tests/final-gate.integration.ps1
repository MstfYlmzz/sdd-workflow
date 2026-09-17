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

function Assert-True([bool] $Condition, [string] $Message) { if (-not $Condition) { throw "ASSERT FAILED: $Message" } }

$script:agentCalls = 0
function Invoke-FinalGateAgent {
    param([Parameter(Mandatory)] [hashtable] $Request)
    $script:agentCalls++
    if ($Request.prompt -match 'Repair Tier 1 failure') {
        Set-Content -LiteralPath (Join-Path $Request.cwd 'src/repair.txt') -Value @('repair','makes','gate green') -Encoding utf8
        & git -C $Request.cwd add src/repair.txt
        & git -C $Request.cwd commit --quiet -m 'final gate repair'
        & git -C $Request.cwd branch strict-green
    } else {
        Set-Content -LiteralPath (Join-Path $Request.cwd 'src/result.txt') -Value @('first','second','third') -Encoding utf8
        & git -C $Request.cwd add src/result.txt
        & git -C $Request.cwd commit --quiet -m 'T001 implementation'
    }
    [pscustomobject]@{ok=$true;session_id="session-$script:agentCalls";denied=@();last_message='done'}
}
function Resolve-Adapter { param([string] $AgentName) return 'Invoke-FinalGateAgent' }

$fixture = Join-Path ([IO.Path]::GetTempPath()) ("sdd-final-gate-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture -Force | Out-Null
try {
    foreach ($dir in @('.sdd','.sdd/logs','.specify','specs/001-final','src')) { New-Item -ItemType Directory -Path (Join-Path $fixture $dir) -Force | Out-Null }
    Set-Content -LiteralPath (Join-Path $fixture '.gitignore') -Value '.sdd/logs/' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $fixture '.specify/feature.json') -Value '{"feature_directory":"specs/001-final"}' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $fixture 'specs/001-final/tasks.md') -Value @('# Tasks','','- [ ] T001 Create `src/result.txt`') -Encoding utf8
    $ledger=[pscustomobject]@{version=1;spec_id='001-final';gate_baseline=[pscustomobject]@{};stages=[pscustomobject]@{
        spec=[pscustomobject]@{status='completed'};plan=[pscustomobject]@{status='completed'};tasks=[pscustomobject]@{status='completed'}
        analyze=[pscustomobject]@{status='completed';highest_severity='none';finding_count=0;summary='clean'}
        implement=[pscustomobject]@{status='not_started'}
    };tasks=@([pscustomobject]@{id='T001';title='Create `src/result.txt`';status='pending';attempts=0;files=@('src/result.txt');depends_on=@();agent=$null;commit_sha=$null;last_gate_output=$null;updated_at=$null})}
    Write-Ledger -Ledger $ledger -StatePath (Join-Path $fixture '.sdd/state.json')
    & git -C $fixture init --quiet
    & git -C $fixture config user.email 'sdd-test@example.invalid'
    & git -C $fixture config user.name 'SDD Test'
    & git -C $fixture add .
    & git -C $fixture commit --quiet -m initial

    $config=[pscustomobject]@{
        agents=[pscustomobject]@{implement=[pscustomobject]@{agent='fake';model='model';effort='medium'}}
        gates=@([pscustomobject]@{name='strict-ref';cmd='git rev-parse --verify refs/heads/strict-green'})
        loop=[pscustomobject]@{batch_size=1;max_attempts=3;escalate_at=2;circuit_breaker=3;observe_every=0}
        analyze=[pscustomobject]@{block_on='critical'}
    }
    $result=Invoke-ImplementLoop -Config $config -Ledger $ledger -ProjectRoot $fixture
    Assert-True ($result.ok -and $result.reason -eq 'completed') 'Final strict gate repair sonrasında loop tamamlanmalı.'
    Assert-True ($script:agentCalls -eq 2) 'Bir implement ve bir final repair agent çağrısı olmalı.'
    $repair=@($ledger.tasks | Where-Object { $_.PSObject.Properties.Name -contains 'strict_gates' -and $_.strict_gates })
    Assert-True ($repair.Count -eq 1 -and $repair[0].status -eq 'done') 'Strict final repair task ledgerda done olmalı.'
    Assert-True ((& git -C $fixture rev-parse --verify refs/heads/strict-green) -ne $null) 'Repair gate koşulunu gerçekten düzeltmeli.'
    Write-Host 'FINAL GATE INTEGRATION OK' -ForegroundColor Green
} finally {
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
