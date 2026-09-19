#requires -Version 7.0
<# SDD workflow komut satırı giriş noktası.
   Argümanlar bilerek PowerShell parameter binder'a bırakılmaz. Global shim'den
   aktarılan çok satırlı -Prompt değeri Object[] olabilir. #>
$supportedCommands=@('init','upgrade','self-update','spectatui','spec','plan','tasks','analyze','implement','converge','status','config','tui','sync-tasks','workflow-stage')
$Command=if($args.Count){[string]$args[0]}else{''}
$Rest=@(if($args.Count-gt1){$args[1..($args.Count-1)]})
if($Command-and$Command-notin$supportedCommands){throw "Bilinmeyen SDD komutu: $Command"}
$ErrorActionPreference='Stop'
try { [Console]::OutputEncoding=[Text.Encoding]::UTF8; $OutputEncoding=[Text.Encoding]::UTF8; $PSDefaultParameterValues['*:Encoding']='utf8' } catch {}
$here=Split-Path -Parent $PSCommandPath; $lib=Join-Path (Split-Path -Parent $here) 'lib'
. (Join-Path $lib 'common.ps1'); . (Join-Path $lib 'ledger.ps1'); . (Join-Path $lib 'spectatui.ps1'); . (Join-Path $lib 'events.ps1'); . (Join-Path $lib 'tui.ps1')
. (Join-Path $lib 'stages.ps1'); . (Join-Path $lib 'tier0.ps1'); . (Join-Path $lib 'tier1.ps1'); . (Join-Path $lib 'converge.ps1'); . (Join-Path $lib 'loop.ps1'); . (Join-Path $lib 'workflow.ps1')
Get-ChildItem (Join-Path $lib 'adapters') -Filter '*.ps1' | ForEach-Object { . $_.FullName }

function Show-Help {
    Write-Host "`nsdd — spec-driven development orkestratörü`n" -ForegroundColor Cyan
    Write-Host '  sdd init | upgrade [-Force] | self-update | status | tui'
    Write-Host '  sdd spectatui install [-SkipTests]   patched SpectaTUI yan-yana kurulum'
    Write-Host '  sdd spec|plan|tasks|analyze [-Agent A] [-Model M] [-Effort E] [-Ui auto|plain|tui|raw]'
    Write-Host '  sdd implement [-ObserveEvery N] [-Agent A] [-Model M] [-Effort E] [-Ui MODE]'
    Write-Host '  sdd converge [-Agent A] [-Model M] [-Effort E] [-Ui MODE]'
    Write-Host '  sdd config               tüm stage routinglerini sırayla ayarlar'
    Write-Host '  sdd config <stage>       yalnız verilen stage routing ayarını değiştirir'
    Write-Host '  sdd config --json        routing bilgisini makine-okunur verir'
    Write-Host "  sdd config set <stage> -Agent A -Model M -Effort E`n"
}
function Get-CommonArguments {
    param([object[]]$Arguments)
    $r=[ordered]@{agent='';model='';effort='';ui='auto';select=$false;run_only=$false;remaining=[Collections.Generic.List[object]]::new()}; $a=@($Arguments)
    for($i=0;$i-lt$a.Count;$i++) { switch -Regex ([string]$a[$i]) {
        '^-Agent$' { if(++$i-ge$a.Count){throw '-Agent için değer gerekli.'};$r.agent=$a[$i];continue }
        '^-Model$' { if(++$i-ge$a.Count){throw '-Model için değer gerekli.'};$r.model=$a[$i];continue }
        '^-Effort$' { if(++$i-ge$a.Count){throw '-Effort için değer gerekli.'};$r.effort=$a[$i];continue }
        '^-Ui$' { if(++$i-ge$a.Count-or$a[$i]-notin@('auto','plain','tui','raw')){throw '-Ui: auto, plain, tui veya raw olmalı.'};$r.ui=$a[$i];continue }
        '^-Select$' {$r.select=$true;continue}; '^-RunOnly$' {$r.run_only=$true;continue}; default {$r.remaining.Add($a[$i])}
    }}; [pscustomobject]$r
}
function Get-CommandProfile {
    param($Config,[string]$Stage,$Options,[string]$ConfigPath)
    if($Options.select){return Show-AgentSelection -Config $Config -ConfigPath $ConfigPath -StageName $Stage -RunOnly:$Options.run_only}
    if($Options.agent-or$Options.model-or$Options.effort){return Get-StageProfile -Config $Config -StageName $Stage -Agent $Options.agent -Model $Options.model -Effort $Options.effort}
    $ui=if($Config.PSObject.Properties.Name-contains'ui'){$Config.ui}else{$null}
    if($ui-and$ui.PSObject.Properties.Name-contains'prompt_on_stage_start'-and[bool]$ui.prompt_on_stage_start-and(Test-SddInteractiveTerminal)){return Show-AgentSelection -Config $Config -ConfigPath $ConfigPath -StageName $Stage}
    $null
}
function Get-ConfiguredUi {
    param($Config,[string]$Requested)
    if($Requested-ne'auto'){return $Requested}
    if($Config-and$Config.PSObject.Properties.Name-contains'ui'-and$Config.ui-and$Config.ui.PSObject.Properties.Name-contains'mode'){return [string]$Config.ui.mode}
    'auto'
}
function Invoke-WithEventContext {
    param([string]$ProjectRoot,[string]$Stage,[string]$UiMode,[scriptblock]$Action)
    $null=Initialize-SddEventContext -ProjectRoot $ProjectRoot -UiMode $UiMode -Stage $Stage; $status='completed'
    try{return & $Action}catch{$status='failed';throw}finally{$null=Close-SddEventContext -Status $status}
}
function Invoke-Sdd {
    if(-not$Command){Show-Help;return}
    if($Command-eq'self-update'){$x=Update-SddInstallation;Write-Host "`nSDD motoru güncel: $($x.version.Substring(0,[Math]::Min(8,$x.version.Length)))" -ForegroundColor Green;Write-Host "Sonraki komutlar yeni sürümü kullanacak.`n";return}
    if($Command-eq'init'){$projectRoot=(Get-Location).Path;$x=Initialize-SddProject -ProjectRoot $projectRoot;if(Get-Command Write-SddSpectaConfig -ErrorAction SilentlyContinue){$null=Write-SddSpectaConfig -ProjectRoot $projectRoot};Write-Host "`nSDD kuruldu." -ForegroundColor Green;foreach($p in $x.Created){Write-Host "  + $p" -ForegroundColor Green};foreach($p in $x.Skipped){Write-Host "  = $p (zaten var, dokunulmadı)" -ForegroundColor DarkGray};Write-Host "`nSonraki: .sdd/config.yaml'ı gözden geçir, sonra 'sdd status'.`n";return}
    if($Command-eq'spectatui'){$sub=if($Rest.Count){[string]$Rest[0]}else{''};if($sub-ne'install'){throw 'Kullanım: sdd spectatui install [-SkipTests]'};$installer=Join-Path (Split-Path -Parent $here) 'scripts/install-spectatui-sdd.ps1';if(-not(Test-Path -LiteralPath $installer)){throw "SpectaTUI installer bulunamadı: $installer"};$installArgs=@(if($Rest.Count-gt1){$Rest[1..($Rest.Count-1)]});& $installer @installArgs;return}
    $root=Find-ProjectRoot;$paths=Get-SddPaths $root
    $upgrade=Update-SddConfigCompatibility -ConfigPath $paths.Config
    $machineConfigJson = ($Command -eq 'config' -and $Rest.Count -eq 1 -and ([string]$Rest[0]) -eq '--json')
    if($upgrade.changed -and -not $machineConfigJson){Write-Host "Config güncellendi: $($upgrade.keys -join ', ')" -ForegroundColor DarkGray}
    switch($Command){
      'upgrade'{$force=$false;if($Rest.Count-gt1-or($Rest.Count-eq1-and$Rest[0]-ne'-Force')){throw 'Kullanım: sdd upgrade [-Force]'};if($Rest.Count-eq1){$force=$true};$x=Sync-SddProjectAssets -ProjectRoot $root -Force:$force;if(Get-Command Write-SddSpectaConfig -ErrorAction SilentlyContinue){$null=Write-SddSpectaConfig -ProjectRoot $root};Write-Host "`nProje SDD assetleri güncellendi: $($x.updated.Count) dosya" -ForegroundColor Green;Write-Host "Workflow: $($x.workflow_version.Substring(0,[Math]::Min(8,$x.workflow_version.Length)))";if($x.updated.Count){Write-Host 'Değişiklikleri inceleyip proje reposunda commit edin.' -ForegroundColor Yellow}}
      'status'{Show-LedgerStatus $paths.State}
      'tui'{Show-SddDashboard $root}
      'config'{
        $firstConfigArg = if ($Rest.Count -gt 0) { [string]$Rest[0] } else { '' }
        if ($Rest.Count -eq 1 -and $firstConfigArg -eq '--json') {
            $doc = Get-SddSpectaConfigDocument -ProjectRoot $root
            if ($null -eq $doc) { throw 'SDD config okunamadı.' }
            $doc | ConvertTo-Json -Depth 8
            return
        }
        if ($Rest.Count -ge 2 -and $firstConfigArg -eq 'set') {
            $stage = [string]$Rest[1]
            $validStages = @('spec','plan','tasks','analyze','implement','converge')
            if ($stage -notin $validStages) {
                throw 'Kullanım: sdd config set <stage> -Agent A -Model M -Effort E'
            }
            $tail = @()
            if ($Rest.Count -gt 2) { $tail = @($Rest[2..($Rest.Count - 1)]) }
            $o = Get-CommonArguments -Arguments $tail
            $agentValue = [string]$o.agent
            $modelValue = [string]$o.model
            $effortValue = [string]$o.effort
            if ($o.remaining.Count -gt 0 -or -not $agentValue -or -not $modelValue -or -not $effortValue) {
                throw 'Kullanım: sdd config set <stage> -Agent A -Model M -Effort E'
            }
            $null = Set-SddStageProfile -ConfigPath $paths.Config -StageName $stage -Agent $agentValue -Model $modelValue -Effort $effortValue
            $doc = Get-SddSpectaConfigDocument -ProjectRoot $root
            $doc | ConvertTo-Json -Depth 8
            return
        }
        $o = Get-CommonArguments -Arguments $Rest
        if ($o.remaining.Count -gt 1) { throw 'Kullanım: sdd config [stage] [-RunOnly]' }
        $stage = 'all'
        if ($o.remaining.Count -gt 0) { $stage = [string]$o.remaining[0] }
        $cfg = Read-SddConfig -ConfigPath $paths.Config
        $null = Show-AgentSelection -Config $cfg -ConfigPath $paths.Config -StageName $stage -RunOnly:$o.run_only
      }
      'sync-tasks'{$L=Read-Ledger $paths.State;$fd=Get-FeatureDirectory $root;if(-not$fd){throw '.specify/feature.json yok.'};$tm=Join-Path $fd 'tasks.md';$L=Import-TasksToLedger $L $tm;Write-Ledger $L $paths.State;Write-Host "`n$(@(Get-LedgerTasks $L).Count) task ledger'a yüklendi." -ForegroundColor Green;Show-LedgerStatus $paths.State}
      'workflow-stage'{$stage=if($Rest.Count-eq1){[string]$Rest[0]}else{''};if($stage-notin@('prepare','analyze','closure')){throw 'Kullanım: sdd workflow-stage prepare|analyze|closure'};$wr=Invoke-SddWorkflowStep -ProjectRoot $root -Step $stage -UiMode raw;if($wr.pause){exit 75}}
      {$_-in@('spec','plan','tasks')}{
        $o=Get-CommonArguments $Rest;$cfg=Read-SddConfig $paths.Config;$L=Read-Ledger $paths.State;$profile=Get-CommandProfile $cfg $Command $o $paths.Config
        $stageArgs='';$prompt='';$resume=$false;$a=@($o.remaining);for($i=0;$i-lt$a.Count;$i++){switch -Regex([string]$a[$i]){'^-Prompt$'{if(++$i-ge$a.Count){throw '-Prompt için değer gerekli.'};$prompt=if($a[$i]-is[Array]){@($a[$i]|ForEach-Object{[string]$_})-join[Environment]::NewLine}else{[string]$a[$i]};continue};'^-Resume$'{$resume=$true;continue};default{$stageArgs=(@($stageArgs,[string]$a[$i])|Where-Object{$_})-join' '}}}
        $res=Invoke-WithEventContext $root $Command (Get-ConfiguredUi $cfg $o.ui) {Invoke-Stage -Name $Command -ProjectRoot $root -Config $cfg -Ledger $L -Arguments $stageArgs -Prompt $prompt -Resume:$resume -ProfileOverride $profile};Write-Ledger $L $paths.State
        if($res.ok){Write-Host "`n[$Command] tamamlandı." -ForegroundColor Green}else{Write-Host "`n[$Command] başarısız." -ForegroundColor Red}
      }
      'analyze'{$o=Get-CommonArguments $Rest;if($o.remaining.Count){throw "Bilinmeyen analyze argümanı: $($o.remaining-join' ')"};$cfg=Read-SddConfig $paths.Config;$L=Read-Ledger $paths.State;$p=Get-CommandProfile $cfg 'analyze' $o $paths.Config;$res=Invoke-WithEventContext $root 'analyze' (Get-ConfiguredUi $cfg $o.ui) {Invoke-Analyze -Config $cfg -Ledger $L -ProjectRoot $root -Force -ProfileOverride $p};Write-Ledger $L $paths.State;if(-not$res.ok){Write-Host "`n[analyze] başarısız: $($res.output)" -ForegroundColor Red}elseif($res.blocked){Write-Host "`n[analyze] implement engellendi: $($res.severity)" -ForegroundColor Red}else{Write-Host "`n[analyze] geçti: $($res.severity), $($res.finding_count) bulgu" -ForegroundColor Green}}
      'converge'{$o=Get-CommonArguments $Rest;if($o.remaining.Count){throw "Bilinmeyen converge argümanı: $($o.remaining-join' ')"};$cfg=Read-SddConfig $paths.Config;$L=Read-Ledger $paths.State;$p=Get-CommandProfile $cfg 'converge' $o $paths.Config;$res=Invoke-WithEventContext $root 'converge' (Get-ConfiguredUi $cfg $o.ui) {Invoke-Converge -Config $cfg -Ledger $L -ProjectRoot $root -ProfileOverride $p -Force};Write-Ledger $L $paths.State;if($res.ok){Write-Host "`n[converge] $($res.outcome) — eklenen task: $($res.tasks_appended)" -ForegroundColor Green}else{Write-Host "`n[converge] durdu: $($res.outcome) — $($res.output)" -ForegroundColor Yellow}}
      'implement'{
        $o=Get-CommonArguments $Rest;$cfg=Read-SddConfig $paths.Config;$L=Read-Ledger $paths.State;$p=Get-CommandProfile $cfg 'implement' $o $paths.Config;$obs=-1;$from='';$candidate='';$a=@($o.remaining)
        for($i=0;$i-lt$a.Count;$i++){switch -Regex($a[$i]){'^-ObserveEvery$'{if(++$i-ge$a.Count-or$a[$i]-notmatch'^\d+$'){throw '-ObserveEvery için sayı gerekli.'};$obs=[int]$a[$i];continue};'^-Resume$'{continue};'^-RevalidateFrom$'{if(++$i-ge$a.Count){throw 'SHA gerekli.'};$from=$a[$i];continue};'^-CandidateCommit$'{if(++$i-ge$a.Count){throw 'SHA gerekli.'};$candidate=$a[$i];continue};default{throw "Bilinmeyen implement argümanı: $($a[$i])"}}}
        $res=Invoke-WithEventContext $root 'implement' (Get-ConfiguredUi $cfg $o.ui) {Invoke-ImplementLoop -Config $cfg -Ledger $L -ProjectRoot $root -ObserveEvery $obs -RevalidateFrom $from -CandidateCommit $candidate -ProfileOverride $p}
        if($res.ok-and$res.reason-eq'completed'){Write-Host "`n[implement] tamamlandı — implement ve converge geçti." -ForegroundColor Green}elseif($res.reason-eq'observe_pause'){Write-Host "`n[implement] gözlem molası." -ForegroundColor Yellow}else{Write-Host "`n[implement] durdu: $($res.reason)" -ForegroundColor Yellow;if($res.output){Write-Host "  $($res.output)"}}
      }
    }
}
Invoke-Sdd
