#requires -Version 7.0
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$repoRoot=Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'lib/common.ps1');. (Join-Path $repoRoot 'lib/stages.ps1')
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "ASSERT FAILED: $Message"}}
$fixture=Join-Path ([IO.Path]::GetTempPath()) ("sdd-routing-"+[guid]::NewGuid().ToString('N'));New-Item $fixture -ItemType Directory|Out-Null
try{
  $path=Join-Path $fixture 'config.yaml';Copy-Item (Join-Path $repoRoot 'templates/config.default.yaml') $path
  $before=(Get-Content $path|Where-Object{$_-match'^  implement:'})
  $cfg=Set-SddStageProfile -ConfigPath $path -StageName implement -Agent claude -Model sonnet -Effort high
  Assert-True ($cfg.agents.implement.agent-eq'claude'-and$cfg.agents.implement.model-eq'sonnet') 'Routing seçimi confige yazılmalı.'
  $profile=Get-StageProfile -Config $cfg -StageName implement -Agent cursor -Model auto -Effort medium
  Assert-True ($profile.override-and$profile.agent-eq'cursor') 'Run-only override kayıtlı profili ezebilmeli.'
  Assert-True ((Get-Content $path|Where-Object{$_-match'^  implement:'})-match'claude') 'Runtime override configi değiştirmemeli.'
  Assert-True ($before-ne(Get-Content $path|Where-Object{$_-match'^  implement:'})) 'Kalıcı seçim hedef satırı değiştirmeli.'
  Write-Host 'AGENT SELECTION INTEGRATION OK' -ForegroundColor Green
}finally{if(Test-Path $fixture){Remove-Item $fixture -Recurse -Force}}
