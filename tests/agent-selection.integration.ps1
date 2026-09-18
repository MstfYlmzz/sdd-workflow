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
  foreach($stage in @('spec','plan','tasks','analyze','implement','converge')){$cfg=Set-SddStageProfile -ConfigPath $path -StageName $stage -Agent codex -Model test-model -Effort high}
  Assert-True (@('spec','plan','tasks','analyze','implement','converge'|Where-Object{$cfg.agents.$_.model-ne'test-model'}).Count-eq0) 'Bütün stage routingleri sırayla güncellenebilmeli.'
  $models=@(Get-SddAgentModels -Agent codex -CurrentModel 'saved-model');Assert-True ($models[0]-eq'saved-model'-and$models.Count-gt1) 'Model listesi kayıtlı model ve fallback seçenekleri içermeli.'
  $menu=(Get-Command Select-SddMenuItem).ScriptBlock.ToString();Assert-True ($menu-match'\?1049h'-and$menu-notmatch'SetCursorPosition') 'Interaktif menü buffer koordinatı yerine alternate screen kullanmalı.'
  $legacy=[pscustomobject]@{agents=[pscustomobject]@{implement=[pscustomobject]@{agent='codex';model='old';effort='medium'}}}
  $fallback=Get-StageProfile -Config $legacy -StageName converge;Assert-True ($fallback.agent-eq'codex'-and$fallback.model-eq'gpt-5.6-sol') 'Eski configte eksik converge profili varsayılandan tamamlanmalı.'
  $legacyPath=Join-Path $fixture 'legacy.yaml';@"
agents:
  implement: { agent: codex, model: old, effort: medium }
  converge:  { agent: codex, model: gpt-5.6-terra, effort: high }
loop:
  batch_size: 3
"@|Set-Content $legacyPath
  $upgrade=Update-SddConfigCompatibility -ConfigPath $legacyPath;$legacyCfg=Read-SddConfig $legacyPath
  Assert-True ($upgrade.changed-and$legacyCfg.loop.enable_converge-and$legacyCfg.loop.max_converge_rounds-eq3) 'Converge routingi olan eski config otomatik etkinleştirilmeli.'
  Assert-True ($legacyCfg.ui.mode-eq'auto'-and-not$legacyCfg.ui.prompt_on_stage_start) 'Eksik UI varsayılanları eski confige eklenmeli.'
  $again=Update-SddConfigCompatibility -ConfigPath $legacyPath;Assert-True (-not$again.changed) 'Config yükseltmesi idempotent olmalı.'
  Write-Host 'AGENT SELECTION INTEGRATION OK' -ForegroundColor Green
}finally{if(Test-Path $fixture){Remove-Item $fixture -Recurse -Force}}
