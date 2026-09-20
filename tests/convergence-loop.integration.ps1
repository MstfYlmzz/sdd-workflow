#requires -Version 7.0
$ErrorActionPreference='Stop'; Set-StrictMode -Version Latest
$repoRoot=Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'lib/common.ps1')
. (Join-Path $repoRoot 'lib/ledger.ps1')
. (Join-Path $repoRoot 'lib/stages.ps1')
. (Join-Path $repoRoot 'lib/tier0.ps1')
. (Join-Path $repoRoot 'lib/tier1.ps1')
. (Join-Path $repoRoot 'lib/loop.ps1')
. (Join-Path $repoRoot 'lib/converge.ps1')
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "ASSERT FAILED: $Message"}}

$script:timeline=[Collections.Generic.List[string]]::new()
$script:convergeCalls=0
$script:tasksPath=''

function Invoke-FakeClosureAgent {
    param([hashtable]$Request)
    if($Request.prompt -match '\[SDD IMPLEMENT BATCH'){
        $ids=@([regex]::Matches($Request.prompt,'(?m)^- (T\d{3,}):')|ForEach-Object{$_.Groups[1].Value})
        $script:timeline.Add("implement:$($ids -join ',')")
        foreach($id in $ids){Set-Content (Join-Path $Request.cwd "src/$id.txt") @("$id one","$id two","$id three")}
        & git -C $Request.cwd add src
        & git -C $Request.cwd commit --quiet -m ("implement "+($ids -join ', '))
        return [pscustomobject]@{ok=$true;session_id='impl';denied=@();last_message='done'}
    }
    $script:convergeCalls++
    $script:timeline.Add("converge:$script:convergeCalls")
    if($script:convergeCalls-eq 1){
        Add-Content $script:tasksPath @('','## Phase 2: Convergence','','- [ ] T002 Fix convergence gap in `src/T002.txt`')
        return [pscustomobject]@{ok=$true;session_id='conv1';denied=@();last_message='SDD_CONVERGE_RESULT {"outcome":"tasks_appended","tasks_appended":1,"summary":"gap"}'}
    }
    [pscustomobject]@{ok=$true;session_id='conv2';denied=@();last_message='SDD_CONVERGE_RESULT {"outcome":"converged","tasks_appended":0,"summary":"clean"}'}
}
function Resolve-Adapter{param([string]$AgentName)'Invoke-FakeClosureAgent'}
function Invoke-Analyze{param($Config,$Ledger,$ProjectRoot)[pscustomobject]@{ok=$true;blocked=$false;severity='none';finding_count=0;summary='clean'}}

$fixture=Join-Path ([IO.Path]::GetTempPath()) ("sdd-convergence-loop-"+[guid]::NewGuid().ToString('N'))
New-Item $fixture -ItemType Directory|Out-Null
try{
    foreach($d in @('.sdd','.sdd/logs','.specify','.agents/skills/speckit-converge','specs/001-loop','src')){New-Item (Join-Path $fixture $d) -ItemType Directory -Force|Out-Null}
    Set-Content (Join-Path $fixture '.gitignore') @('.sdd/logs/','.sdd/runs.jsonl')
    Set-Content (Join-Path $fixture '.specify/feature.json') '{"feature_directory":"specs/001-loop"}'
    Set-Content (Join-Path $fixture '.agents/skills/speckit-converge/SKILL.md') 'Converge.'
    Set-Content (Join-Path $fixture 'specs/001-loop/spec.md') '# spec'
    Set-Content (Join-Path $fixture 'specs/001-loop/plan.md') '# plan'
    $script:tasksPath=Join-Path $fixture 'specs/001-loop/tasks.md'
    Set-Content $script:tasksPath @('# Tasks','','## Phase 1: Initial','','- [x] T001 Initial work')
    Set-Content (Join-Path $fixture 'src/T001.txt') @('one','two','three')

    $ledger=[pscustomobject]@{
      version=1;spec_id='001-loop';gate_baseline=[pscustomobject]@{}
      stages=[pscustomobject]@{
        spec=[pscustomobject]@{status='completed'};plan=[pscustomobject]@{status='completed'}
        tasks=[pscustomobject]@{status='completed'};analyze=[pscustomobject]@{status='completed';highest_severity='none';finding_count=0;summary='clean'}
        implement=[pscustomobject]@{status='not_started'};converge=[pscustomobject]@{status='not_started';round=0}
      }
      tasks=@([pscustomobject]@{id='T001';title='Initial work';status='done';attempts=1;files=@('src/T001.txt');depends_on=@();story=$null;phase=1;parallel=$false;agent='fake';commit_sha=$null;last_gate_output=$null;updated_at=$null})
    }
    Write-Ledger $ledger (Join-Path $fixture '.sdd/state.json')
    & git -C $fixture init --quiet
    & git -C $fixture config user.email test@example.invalid
    & git -C $fixture config user.name Test
    & git -C $fixture add .
    & git -C $fixture commit --quiet -m initial

    $cfg=[pscustomobject]@{
      agents=[pscustomobject]@{
        implement=[pscustomobject]@{agent='fake';model='m';effort='medium'}
        converge=[pscustomobject]@{agent='fake';model='m';effort='medium'}
      }
      gates=@([pscustomobject]@{name='diff';cmd='git diff --check'})
      loop=[pscustomobject]@{batch_size=1;max_attempts=3;escalate_at=2;circuit_breaker=3;observe_every=0;enable_converge=$true;max_converge_rounds=3}
      analyze=[pscustomobject]@{block_on='critical'}
    }

    $r=Invoke-ImplementLoop -Config $cfg -Ledger $ledger -ProjectRoot $fixture
    Assert-True ($r.ok-and$r.reason-eq'completed') 'Closure tamamlanmalı.'
    Assert-True (($script:timeline -join '|')-eq'converge:1|implement:T002|converge:2') 'Converge task eklerse implement araya girmeden converge tekrar çalışmamalı.'
    Assert-True (@(Get-LedgerTasks $ledger).Count-eq2) 'Task toplamı convergence sonrası kalıcı 2 olmalı.'
    Assert-True (@(Get-LedgerTasks $ledger|Where-Object status -eq'done').Count-eq2) 'Yeni convergence task done olmalı.'
    Assert-True ($ledger.stages.converge.status-eq'completed'-and$ledger.stages.converge.round-eq2) 'İkinci converge turu clean bitmeli.'
    Write-Host 'CONVERGENCE LOOP INTEGRATION OK' -ForegroundColor Green
}finally{if(Test-Path $fixture){Remove-Item $fixture -Recurse -Force}}
