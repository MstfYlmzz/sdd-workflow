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
  $null=Close-SddEventContext
  $runs=Join-Path $fixture '.sdd/runs.jsonl';$raw=Get-Content $runs -Raw
  Assert-True ($raw-notmatch'topsecret|source code|hunter2') 'Telemetry credential veya ham command output saklamamalı.'
  Add-Content $runs '{broken json'
  $history=@(Get-SddRunHistory $runs 20);Assert-True ($history.Count-ge3) 'Bozuk JSONL satırı sağlam geçmişi engellememeli.'
  $ledger=[pscustomobject]@{spec_id='fixture';stages=[pscustomobject]@{spec=[pscustomobject]@{status='completed'};plan=[pscustomobject]@{status='completed'};tasks=[pscustomobject]@{status='completed'};analyze=[pscustomobject]@{status='completed'};implement=[pscustomobject]@{status='running'};converge=[pscustomobject]@{status='not_started';round=0}};tasks=@([pscustomobject]@{id='T001';status='pending';title='A task'})}
  $cfg=[pscustomobject]@{agents=[pscustomobject]@{spec=[pscustomobject]@{agent='codex';model='m';effort='high'}}}
  foreach($page in @('overview','tasks','history','artifacts')){$lines=@(Get-SddDashboardLines -Ledger $ledger -Config $cfg -History $history -Page $page -ProjectRoot $fixture -Width 40);Assert-True ($lines.Count-gt2) "$page sayfası render edilmeli."}
  Write-Host 'EVENTS TUI INTEGRATION OK' -ForegroundColor Green
}finally{if(Test-Path $fixture){Remove-Item $fixture -Recurse -Force}}
