#requires -Version 7.0
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$repoRoot=Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'lib/common.ps1');. (Join-Path $repoRoot 'lib/ledger.ps1');. (Join-Path $repoRoot 'lib/events.ps1');. (Join-Path $repoRoot 'lib/stages.ps1');. (Join-Path $repoRoot 'lib/tui.ps1')
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "ASSERT FAILED: $Message"}}
$fixture=Join-Path ([IO.Path]::GetTempPath()) ("sdd-events-"+[guid]::NewGuid().ToString('N'));New-Item $fixture -ItemType Directory|Out-Null
try{
  New-Item (Join-Path $fixture '.sdd') -ItemType Directory|Out-Null
  $null=Initialize-SddEventContext -ProjectRoot $fixture -UiMode plain -Stage implement
  Send-SddEvent -Category command_output -EventType command_output -Message 'api_key=topsecret source code'
  Send-SddEvent -Category assistant -EventType agent_message -Message ('password=hunter2 '+('x'*500))
  $beforePartial=$script:SddEventContext.events.Count
  Send-SddEvent -Category assistant -EventType agent_message_partial -Provider cursor -Message 'Planning the '
  Send-SddEvent -Category assistant -EventType agent_message_partial -Provider cursor -Message 'implementation'
  Assert-True ($script:SddEventContext.events.Count-eq($beforePartial+1)-and$script:SddEventContext.events[-1].message-eq'Planning the implementation') 'Ardışık Cursor deltaları TUI için tek mesajda birleştirilmeli.'
  $null=Close-SddEventContext
  $runs=Join-Path $fixture '.sdd/runs.jsonl';$raw=Get-Content $runs -Raw
  Assert-True ($raw-notmatch'topsecret|source code|hunter2') 'Telemetry credential veya ham command output saklamamalı.'
  Add-Content $runs '{broken json'
  $history=@(Get-SddRunHistory $runs 20);Assert-True ($history.Count-ge3) 'Bozuk JSONL satırı sağlam geçmişi engellememeli.'
  $ledger=[pscustomobject]@{spec_id='fixture';stages=[pscustomobject]@{spec=[pscustomobject]@{status='completed'};plan=[pscustomobject]@{status='completed'};tasks=[pscustomobject]@{status='completed'};analyze=[pscustomobject]@{status='completed'};implement=[pscustomobject]@{status='running'};converge=[pscustomobject]@{status='not_started';round=0}};tasks=@([pscustomobject]@{id='T001';status='pending';title='A task'})}
  $cfg=[pscustomobject]@{agents=[pscustomobject]@{spec=[pscustomobject]@{agent='codex';model='m';effort='high'}}}
  foreach($page in @('overview','tasks','history','artifacts')){$lines=@(Get-SddDashboardLines -Ledger $ledger -Config $cfg -History $history -Page $page -ProjectRoot $fixture -Width 40);Assert-True ($lines.Count-gt2) "$page sayfası render edilmeli."}
  $wrapped=@(ConvertTo-SddWrappedLines -Text ('word '*30) -Width 20);Assert-True ($wrapped.Count-gt1-and@($wrapped|Where-Object{$_.Length-gt20}).Count-eq0) 'Uzun TUI metni panel genişliğinde sarılmalı.'
  $context=[ordered]@{stage='implement';run_id='1234567890';events=[Collections.Generic.List[object]]::new();tui_scroll=@{ai=0;ops=0;flow=0};tui_active_pane='ai'}
  $context.events.Add([pscustomobject]@{category='assistant';message=('message '*40);status='';command='';event_type='agent_message'})
  $live=@(Get-SddLiveTuiLines -Context $context -Width 50 -Height 20);Assert-True ($live.Count-eq20-and@($live|Where-Object{$_.Length-gt50}).Count-eq0) 'Live TUI ölçüleri terminale sığmalı.'
  $mouse=ConvertFrom-SddMouseSequence -Sequence "$([char]27)[<64;12;8M";Assert-True ($mouse.delta-eq1-and$mouse.x-eq12-and$mouse.y-eq8) 'SGR mouse wheel olayı ayrıştırılmalı.'
  Assert-True ((Get-SddPaneAtRow -Row 5 -TerminalHeight 30)-eq'ai') 'Mouse satırı ilgili TUI panelini seçmeli.'
  Write-Host 'EVENTS TUI INTEGRATION OK' -ForegroundColor Green
}finally{if(Test-Path $fixture){Remove-Item $fixture -Recurse -Force}}
