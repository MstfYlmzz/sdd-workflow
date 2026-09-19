#requires -Version 7.0
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$repoRoot=Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'lib/common.ps1');. (Join-Path $repoRoot 'lib/ledger.ps1');. (Join-Path $repoRoot 'lib/stages.ps1');. (Join-Path $repoRoot 'lib/tui.ps1')
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw "ASSERT FAILED: $Message"}}
$fixture=Join-Path ([IO.Path]::GetTempPath()) ("sdd-install-"+[guid]::NewGuid().ToString('N'));New-Item $fixture -ItemType Directory|Out-Null
try{
  $shim=Join-Path $fixture 'shim';& (Join-Path $repoRoot 'install.ps1') -InstallDir $shim -NoPath
  Assert-True ((Test-Path (Join-Path $shim 'sdd.cmd'))-and(Test-Path (Join-Path $shim 'sdd.ps1'))) 'Global sdd shimleri kurulmalı.'
  $launcherError='';try{& (Join-Path $shim 'sdd.ps1') 'definitely-invalid' '-Prompt' @('first line','second line')}catch{$launcherError=$_.Exception.Message}
  Assert-True ($launcherError-match'^Bilinmeyen SDD komutu: definitely-invalid') 'Global shim Object[] prompt aktarırken parameter binder hatası vermemeli.'

  $project=Join-Path $fixture 'project';New-Item $project -ItemType Directory|Out-Null
  $init=Initialize-SddProject -ProjectRoot $project
  Push-Location $project
  try{$statusOutput=& (Join-Path $shim 'sdd.ps1') status 2>&1 6>&1}finally{Pop-Location}
  Assert-True (($statusOutput-join"`n")-match'SDD durumu') 'Global shim geçerli komutu dispatcher ve proje yolu çözümünden geçirmeli.'
  Assert-True (Test-Path (Join-Path $project '.agents/skills/speckit-implement/SKILL.md')) 'sdd init agent skill assetlerini kurmalı.'
  Assert-True (Test-Path (Join-Path $project '.specify/scripts/powershell/common.ps1')) 'sdd init Spec Kit scriptlerini kurmalı.'
  Assert-True (Test-Path (Join-Path $project '.sdd/assets.json')) 'Kurulu asset hashleri kaydedilmeli.'
  Set-Content (Join-Path $project '.specify/memory/constitution.md') 'PROJECT CONSTITUTION'
  $upgrade=Sync-SddProjectAssets -ProjectRoot $project
  Assert-True ((Get-Content (Join-Path $project '.specify/memory/constitution.md') -Raw)-match'PROJECT CONSTITUTION') 'Upgrade proje constitution dosyasını korumalı.'
  $managed=Join-Path $project '.agents/skills/speckit-implement/SKILL.md';Set-Content $managed 'CUSTOM'
  $blocked=$false;try{$null=Sync-SddProjectAssets -ProjectRoot $project}catch{$blocked=$true}
  Assert-True $blocked 'Değiştirilmiş managed asset normal upgrade sırasında ezilmemeli.'
  $null=Sync-SddProjectAssets -ProjectRoot $project -Force
  Assert-True ((Get-Content $managed -Raw)-notmatch'^CUSTOM') 'Force upgrade managed asseti yenilemeli.'

  New-Item (Join-Path $project 'specs/001-one') -ItemType Directory -Force|Out-Null;New-Item (Join-Path $project 'specs/002-two') -ItemType Directory -Force|Out-Null
  Set-Content (Join-Path $project '.specify/feature.json') '{"feature_directory":"specs/001-one"}'
  Set-Content (Join-Path $project 'specs/001-one/tasks.md') "- [x] T001 Done`n- [ ] T002 Open"
  Set-Content (Join-Path $project 'specs/002-two/tasks.md') "- [ ] T001 Other"
  $ledger=Read-Ledger (Join-Path $project '.sdd/state.json');$cfg=Read-SddConfig (Join-Path $project '.sdd/config.yaml')
  $specLines=@(Get-SddDashboardLines -Ledger $ledger -Config $cfg -Page specs -ProjectRoot $project -SelectedSpec '002-two' -Width 100)
  Assert-True (($specLines-join"`n")-match'001-one.*task 1/2'-and($specLines-join"`n")-match'002-two') 'TUI Specs sayfası bütün specleri ve ilerlemeyi göstermeli.'
  $taskLines=@(Get-SddDashboardLines -Ledger $ledger -Config $cfg -Page tasks -ProjectRoot $project -SelectedSpec '002-two' -Width 100)
  Assert-True (($taskLines-join"`n")-match'T001.*pending.*Other') 'TUI seçilen pasif specin tasklarını gösterebilmeli.'
  Write-Host 'INSTALL UPGRADE INTEGRATION OK' -ForegroundColor Green
}finally{if(Test-Path $fixture){Remove-Item $fixture -Recurse -Force}}
