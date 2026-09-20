#requires -Version 7.0
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$repoRoot=Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'lib/common.ps1');. (Join-Path $repoRoot 'lib/ledger.ps1');. (Join-Path $repoRoot 'lib/stages.ps1');. (Join-Path $repoRoot 'lib/tier0.ps1');. (Join-Path $repoRoot 'lib/tier1.ps1');. (Join-Path $repoRoot 'lib/loop.ps1');. (Join-Path $repoRoot 'lib/converge.ps1')
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "ASSERT FAILED: $Message"}}
$script:mode='append';$script:tasksPath=''
function Invoke-FakeConvergeAgent{param([hashtable]$Request)
  if($script:mode-eq'append'){Add-Content $script:tasksPath "`n## Phase 2: Convergence`n`n- [ ] T002 Fix convergence gap in ``src/app.txt```n";return [pscustomobject]@{ok=$true;denied=@();last_message='SDD_CONVERGE_RESULT {"outcome":"tasks_appended","tasks_appended":1,"summary":"gap found"}'}}
  [pscustomobject]@{ok=$true;denied=@();last_message='SDD_CONVERGE_RESULT {"outcome":"converged","tasks_appended":0,"summary":"aligned"}'}
}
function Resolve-Adapter{param([string]$AgentName)'Invoke-FakeConvergeAgent'}
$fixture=Join-Path ([IO.Path]::GetTempPath()) ("sdd-converge-"+[guid]::NewGuid().ToString('N'));New-Item $fixture -ItemType Directory|Out-Null
try{
  foreach($d in @('.sdd','.sdd/logs','.specify','.agents/skills/speckit-converge','specs/001-x','src')){New-Item (Join-Path $fixture $d) -ItemType Directory -Force|Out-Null}
  Set-Content (Join-Path $fixture '.gitignore') ".sdd/logs/`n.sdd/runs.jsonl";Set-Content (Join-Path $fixture '.specify/feature.json') '{"feature_directory":"specs/001-x"}';Set-Content (Join-Path $fixture '.agents/skills/speckit-converge/SKILL.md') 'Converge.'
  Set-Content (Join-Path $fixture 'specs/001-x/spec.md') '# spec';Set-Content (Join-Path $fixture 'specs/001-x/plan.md') '# plan';$script:tasksPath=Join-Path $fixture 'specs/001-x/tasks.md';Set-Content $script:tasksPath "# Tasks`n`n## Phase 1: Setup`n`n- [x] T001 Initial task`n";Set-Content (Join-Path $fixture 'src/app.txt') 'ok'
  $ledger=[pscustomobject]@{version=1;spec_id='x';stages=[pscustomobject]@{spec=[pscustomobject]@{status='completed'};plan=[pscustomobject]@{status='completed'};tasks=[pscustomobject]@{status='completed'};analyze=[pscustomobject]@{status='completed'};implement=[pscustomobject]@{status='running'};converge=[pscustomobject]@{status='not_started';round=0}};gate_baseline=[pscustomobject]@{};tasks=@([pscustomobject]@{id='T001';title='Initial task';status='done';attempts=1;files=@();depends_on=@();agent=$null;commit_sha=$null;last_gate_output=$null;updated_at=$null})}
  $ledger|ConvertTo-Json -Depth 12|Set-Content (Join-Path $fixture '.sdd/state.json');$cfg=[pscustomobject]@{agents=[pscustomobject]@{converge=[pscustomobject]@{agent='fake';model='m';effort='high'}};loop=[pscustomobject]@{max_converge_rounds=3}}
  & git -C $fixture init --quiet;& git -C $fixture config user.email test@example.invalid;& git -C $fixture config user.name Test;& git -C $fixture add .;& git -C $fixture commit --quiet -m initial
  $r=Invoke-Converge -Config $cfg -Ledger $ledger -ProjectRoot $fixture;Assert-True ($r.ok-and$r.outcome-eq'tasks_appended'-and$r.tasks_appended-eq1) 'Converge yeni taskları içe aktarmalı.';Assert-True (@(Get-LedgerTasks $ledger|Where-Object { $_.id -eq 'T002' }).Count-eq1) 'T002 ledgerda olmalı.'
  $script:mode='clean';$r2=Invoke-Converge -Config $cfg -Ledger $ledger -ProjectRoot $fixture;Assert-True ($r2.ok-and$r2.outcome-eq'converged') 'Değişiklik yoksa converge tamamlanmalı.'
  $bad=Test-ConvergeAppend -Before "a`n- [ ] T009 old" -After "changed`n## Phase 2: Convergence`n- [ ] T010 new";Assert-True (-not$bad.ok) 'Mevcut içerik rewrite edilirse reddedilmeli.'

  $payload=Get-ConvergeResultPayload -Text 'prefix SDD_CONVERGE_RESULT {"outcome":"tasks_appended","tasks_appended":1,"summary":"gap"}Both background checks finished.'
  Assert-True ($payload -match '"outcome":"tasks_appended"') 'Converge contract JSON trailing provider text olsa da çıkarılmalı.'

  Add-Content $script:tasksPath "`n## Phase 3: Convergence`n`n- [ ] T003 Recover parser gap in ``src/app.txt```n"
  $ledger.stages.converge.status='interrupted'
  $ledger.stages.converge.round=2
  $ledger.stages.converge | Add-Member -NotePropertyName stop_reason -NotePropertyValue 'contract_missing' -Force
  $ledger.stages.implement.status='interrupted'
  $ledger.stages.implement | Add-Member -NotePropertyName stop_reason -NotePropertyValue 'contract_missing' -Force
  Set-Content (Join-Path $fixture '.sdd/logs/converge.log') '[AI:completed] summary SDD_CONVERGE_RESULT {"outcome":"tasks_appended","tasks_appended":1,"summary":"recover T003"}Both background checks finished.'
  $recovered=Try-RecoverConvergeContract -Ledger $ledger -ProjectRoot $fixture -TasksPath $script:tasksPath -Profile $cfg.agents.converge -LogPath (Join-Path $fixture '.sdd/logs/converge.log')
  Assert-True ($recovered.ok-and$recovered.recovered-and$recovered.outcome-eq'tasks_appended') 'contract_missing append aynı round içinde provider tekrar çağrılmadan recover edilmeli.'
  Assert-True ($recovered.round-eq2-and$ledger.stages.converge.round-eq2) 'Contract recovery yeni converge round tüketmemeli.'
  Assert-True (@(Get-LedgerTasks $ledger|Where-Object { $_.id -eq 'T003' }).Count-eq1) 'Recovered convergence task ledgera alınmalı.'
  Assert-True (@(Get-GitStatusForTier0 -ProjectRoot $fixture).Count-eq0) 'Recovered append checkpoint sonrası working tree temiz olmalı.'

  Write-Host 'CONVERGE INTEGRATION OK' -ForegroundColor Green
}finally{if(Test-Path $fixture){Remove-Item $fixture -Recurse -Force}}
