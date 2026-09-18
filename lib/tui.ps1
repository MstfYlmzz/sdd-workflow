<# PowerShell 7 native TUI. ANSI alternate buffer is used only on an interactive terminal. #>

Set-StrictMode -Version Latest

$script:SddEsc = [char]27

function Get-SddTerminalSize {
    try {
        # Son sütuna yazmak Windows Terminal'de implicit line-wrap üretebilir.
        [pscustomobject]@{ Width = [Math]::Max(40, [Console]::WindowWidth - 1); Height = [Math]::Max(12, [Console]::WindowHeight) }
    } catch { [pscustomobject]@{ Width = 100; Height = 30 } }
}

function ConvertTo-SddWrappedLines {
    param([AllowNull()] [string] $Text, [int] $Width, [string] $ContinuationPrefix = '  ')
    if ($Width -lt 1) { return @('') }
    if ($null -eq $Text) { return @('') }
    $result = [System.Collections.Generic.List[string]]::new()
    foreach ($sourceLine in @(([string]$Text) -split "`r?`n", 0, 'RegexMatch')) {
        $remaining = $sourceLine
        if ($remaining.Length -eq 0) { $result.Add(''); continue }
        $first = $true
        while ($remaining.Length -gt $Width) {
            $cut = $Width
            $space = $remaining.LastIndexOf(' ', $Width - 1, $Width)
            if ($space -ge [Math]::Floor($Width * 0.45)) { $cut = $space }
            $result.Add($remaining.Substring(0,$cut).TrimEnd())
            $remaining = $remaining.Substring($cut).TrimStart()
            if ($remaining -and -not $first -and $ContinuationPrefix.Length -lt $Width) { }
            $first = $false
            if ($ContinuationPrefix -and $remaining) { $remaining = $ContinuationPrefix + $remaining }
        }
        $result.Add($remaining)
    }
    return @($result)
}

function Get-SddPaneContent {
    param([object[]] $Events, [int] $Width, [int] $Height, [int] $ScrollOffset = 0, [switch] $PlainMessage)
    $all = [System.Collections.Generic.List[string]]::new()
    foreach ($event in @($Events)) {
        $text = if ($PlainMessage) { [string]$event.message } else { Format-SddPlainEvent -Event $event }
        foreach ($line in @(ConvertTo-SddWrappedLines -Text ("  $text") -Width $Width -ContinuationPrefix '    ')) { $all.Add($line) }
    }
    if ($all.Count -eq 0) { $all.Add('  (henüz olay yok)') }
    $maxOffset = [Math]::Max(0,$all.Count-$Height)
    $offset = [Math]::Min([Math]::Max(0,$ScrollOffset),$maxOffset)
    $start = [Math]::Max(0,$all.Count-$Height-$offset)
    $visible=[System.Collections.Generic.List[string]]@($all | Select-Object -Skip $start -First $Height)
    while($visible.Count-lt$Height){$visible.Add('')}
    return @($visible)
}

function Limit-SddText {
    param([AllowNull()] [string] $Text, [int] $Width)
    if ($null -eq $Text) { return '' }
    $one = ($Text -replace "`r?`n", ' ↵ ')
    if ($one.Length -le $Width) { return $one }
    if ($Width -le 1) { return $one.Substring(0, [Math]::Max(0,$Width)) }
    return $one.Substring(0, $Width - 1) + '…'
}

function Get-SddLiveTuiLines {
    param([Parameter(Mandatory)] [object] $Context, [int] $Width = 100, [int] $Height = 30)
    $inner = [Math]::Max(20, $Width - 2)
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('┌' + ('─' * $inner) + '┐')
    $title = " SDD LIVE  stage=$($Context.stage)  run=$(([string]$Context.run_id).Substring(0,8)) "
    $lines.Add('│' + (Limit-SddText -Text $title -Width $inner).PadRight($inner) + '│')
    $lines.Add('├' + ('─' * $inner) + '┤')

    $events = @($Context.events); $available=[Math]::Max(6,$Height-9)
    $aiHeight=[Math]::Max(2,[Math]::Floor($available*0.30));$opsHeight=[Math]::Max(2,[Math]::Floor($available*0.40));$flowHeight=[Math]::Max(2,$available-$aiHeight-$opsHeight)
    $scroll=$Context.tui_scroll;$active=[string]$Context.tui_active_pane
    $ai = @($events | Where-Object category -in @('assistant','reasoning_summary'))
    $ops = @($events | Where-Object category -in @('tool','command','command_output','file_change'))
    $flow = @($events | Where-Object category -in @('workflow','gate','error','usage'))

    $mark=if($active-eq'ai'){'▶'}else{' '};$header=Limit-SddText -Text ("$mark AI MESAJI  [Tab panel · ↑/↓ scroll · End canlı]") -Width $inner;$lines.Add('│' + $header.PadRight($inner) + '│')
    foreach ($text in @(Get-SddPaneContent -Events $ai -Width $inner -Height $aiHeight -ScrollOffset ([int]$scroll.ai) -PlainMessage)) { $lines.Add('│' + $text.PadRight($inner) + '│') }
    $lines.Add('├' + ('─' * $inner) + '┤')
    $mark=if($active-eq'ops'){'▶'}else{' '};$header=Limit-SddText -Text ("$mark İŞLEMLER / TERMİNAL") -Width $inner;$lines.Add('│' + $header.PadRight($inner) + '│')
    foreach ($text in @(Get-SddPaneContent -Events $ops -Width $inner -Height $opsHeight -ScrollOffset ([int]$scroll.ops))) { $lines.Add('│' + $text.PadRight($inner) + '│') }
    $lines.Add('├' + ('─' * $inner) + '┤')
    $mark=if($active-eq'flow'){'▶'}else{' '};$header=Limit-SddText -Text ("$mark WORKFLOW") -Width $inner;$lines.Add('│' + $header.PadRight($inner) + '│')
    foreach ($text in @(Get-SddPaneContent -Events $flow -Width $inner -Height $flowHeight -ScrollOffset ([int]$scroll.flow))) { $lines.Add('│' + $text.PadRight($inner) + '│') }
    if ($lines.Count -gt ($Height - 1)) { $lines = [System.Collections.Generic.List[string]]@($lines | Select-Object -First ($Height - 1)) }
    $lines.Add('└' + ('─' * $inner) + '┘')
    return @($lines)
}

function Start-SddLiveTui {
    param([Parameter(Mandatory)] [object] $Context)
    if (-not (Test-SddInteractiveTerminal)) { $Context.ui_mode = 'plain'; return }
    Write-Host -NoNewline "$script:SddEsc[?1049h$script:SddEsc[?25l"
    $Context.tui_active_pane = 'ai'
    $Context.tui_scroll = @{ai=0;ops=0;flow=0}
    $Context.tui_active = $true
}

function Update-SddLiveInput {
    param([Parameter(Mandatory)] [object] $Context)
    try {
        while ([Console]::KeyAvailable) {
            $key=[Console]::ReadKey($true);$panes=@('ai','ops','flow');$pane=[string]$Context.tui_active_pane
            if($key.Key-eq'Tab'){$Context.tui_active_pane=$panes[($panes.IndexOf($pane)+1)%$panes.Count];continue}
            $step=switch($key.Key){'UpArrow'{1};'PageUp'{8};'DownArrow'{-1};'PageDown'{-8};'End'{-[int]$Context.tui_scroll[$pane]};default{0}}
            if($step-ne0){$Context.tui_scroll[$pane]=[Math]::Max(0,[int]$Context.tui_scroll[$pane]+$step)}
        }
    } catch { }
}

function Update-SddLiveTui {
    param([Parameter(Mandatory)] [object] $Context, [object] $Event)
    if (-not $Context.tui_active) { return }
    Update-SddLiveInput -Context $Context
    $size = Get-SddTerminalSize
    $lines = Get-SddLiveTuiLines -Context $Context -Width $size.Width -Height $size.Height
    Write-Host -NoNewline "$script:SddEsc[H$script:SddEsc[2J"
    Write-Host -NoNewline ($lines -join [Environment]::NewLine)
}

function Stop-SddLiveTui {
    param([Parameter(Mandatory)] [object] $Context)
    if (-not $Context.tui_active) { return }
    Write-Host -NoNewline "$script:SddEsc[?25h$script:SddEsc[?1049l"
    $Context.tui_active = $false
}

function Get-SddDashboardLines {
    param([Parameter(Mandatory)] [object] $Ledger, [object] $Config, [object[]] $History = @(),
          [ValidateSet('overview','tasks','routing','history','artifacts')] [string] $Page = 'overview',
          [string] $ProjectRoot = '', [int] $Width = 100)
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("SDD Dashboard — $($Ledger.spec_id) — $Page")
    $lines.Add(('=' * [Math]::Min($Width, 80)))
    if ($Page -eq 'overview') {
        $lines.Add('Stages')
        foreach ($name in @('spec','plan','tasks','analyze','implement','converge')) {
            if ($Ledger.stages.PSObject.Properties.Name -contains $name) {
                $st=$Ledger.stages.$name; $lines.Add(('  {0,-10} {1,-13}' -f $name,$st.status))
            }
        }
        $lines.Add(''); $lines.Add('Tasks')
        foreach ($grp in @(Get-LedgerTasks $Ledger | Group-Object status | Sort-Object Name)) { $lines.Add(('  {0,-12} {1}' -f $grp.Name,$grp.Count)) }
        $round=if($Ledger.stages.PSObject.Properties.Name-contains'converge'-and$Ledger.stages.converge.PSObject.Properties.Name-contains'round'){$Ledger.stages.converge.round}else{0};$lines.Add("  convergence  round $round")
    } elseif ($Page -eq 'tasks') {
        foreach ($task in @(Get-LedgerTasks $Ledger)) {
            foreach($line in @(ConvertTo-SddWrappedLines -Text ('  {0,-7} {1,-11} {2}' -f $task.id,$task.status,$task.title) -Width $Width -ContinuationPrefix '                     ')){$lines.Add($line)}
        }
    } elseif ($Page -eq 'routing') {
        foreach ($name in @('spec','plan','tasks','analyze','implement','converge')) {
            $p=if($Config.agents.PSObject.Properties.Name-contains$name){$Config.agents.$name}else{$null}
            if($p){$cap=Get-SddAgentCapabilities -Agent $p.agent;$ready=if($cap.available){'ready'}else{'missing'};$lines.Add(('  {0,-10} {1,-8} {2}/{3}/{4}' -f $name,$ready,$p.agent,$p.model,$p.effort))}
        }
    } elseif ($Page -eq 'history') {
        foreach ($e in @($History|Select-Object -Last 25)) {
            $message=if($e.PSObject.Properties.Name-contains'message'){$e.message}else{''}
            foreach($line in @(ConvertTo-SddWrappedLines -Text ("  $($e.timestamp) [$($e.stage)/$($e.category)] $($e.event_type) $message") -Width $Width -ContinuationPrefix '    ')){$lines.Add($line)}
        }
    } else {
        $feature=if($ProjectRoot){Get-FeatureDirectory -ProjectRoot $ProjectRoot}else{$null}
        foreach($name in @('spec.md','plan.md','tasks.md','research.md','data-model.md','quickstart.md')){$path=if($feature){Join-Path $feature $name}else{$name};$state=if($feature-and(Test-Path -LiteralPath $path)){'present'}else{'missing'};$lines.Add(('  {0,-18} {1}' -f $name,$state))}
    }
    $lines.Add(''); $lines.Add('Keys: ←/→ page · ↑/↓/PgUp/PgDn scroll · Home/End · r refresh · e edit · q quit')
    return @($lines)
}

function Show-SddDashboard {
    param([Parameter(Mandatory)] [string] $ProjectRoot)
    $paths = Get-SddPaths -ProjectRoot $ProjectRoot
    $interactive = Test-SddInteractiveTerminal
    $pages=@('overview','tasks','routing','history','artifacts');$index=0;$offset=0
    if($interactive){try{while([Console]::KeyAvailable){$null=[Console]::ReadKey($true)}}catch{}}
    do {
        $ledger = Read-Ledger -StatePath $paths.State
        $config = Read-SddConfig -ConfigPath $paths.Config
        $history = @(Get-SddRunHistory -Path $paths.Runs -Last 50)
        $size=Get-SddTerminalSize;$width=$size.Width
        $lines = Get-SddDashboardLines -Ledger $ledger -Config $config -History $history -Page $pages[$index] -ProjectRoot $ProjectRoot -Width $width
        if (-not $interactive) { $lines | ForEach-Object { Write-Host $_ }; return }
        $viewHeight=[Math]::Max(3,$size.Height-1);$maxOffset=[Math]::Max(0,$lines.Count-$viewHeight);$offset=[Math]::Min([Math]::Max(0,$offset),$maxOffset)
        $visible=@($lines|Select-Object -Skip $offset -First $viewHeight)
        while($visible.Count-lt$viewHeight){$visible+=(' '*[Math]::Max(0,$width))}
        $footer=Limit-SddText -Text ("[$($pages[$index])] satır $($offset+1)-$([Math]::Min($offset+$viewHeight,$lines.Count))/$($lines.Count)") -Width $width
        Write-Host -NoNewline "$script:SddEsc[?1049h$script:SddEsc[?25l$script:SddEsc[H$script:SddEsc[2J"
        Write-Host -NoNewline (($visible+@($footer))-join [Environment]::NewLine)
        $key = [Console]::ReadKey($true)
        if($key.Key-in@('RightArrow','Tab')){$index=($index+1)%$pages.Count;$offset=0}
        elseif($key.Key-eq'LeftArrow'){$index=($index-1+$pages.Count)%$pages.Count;$offset=0}
        elseif($key.Key-eq'UpArrow'){$offset=[Math]::Max(0,$offset-1)}
        elseif($key.Key-eq'DownArrow'){$offset=[Math]::Min($maxOffset,$offset+1)}
        elseif($key.Key-eq'PageUp'){$offset=[Math]::Max(0,$offset-$viewHeight)}
        elseif($key.Key-eq'PageDown'){$offset=[Math]::Min($maxOffset,$offset+$viewHeight)}
        elseif($key.Key-eq'Home'){$offset=0}
        elseif($key.Key-eq'End'){$offset=$maxOffset}
        elseif($key.KeyChar-in@('e','E')){
            Write-Host -NoNewline "$script:SddEsc[?25h$script:SddEsc[?1049l"
            $null=Show-AgentSelection -Config $config -ConfigPath $paths.Config
        }
    } while ($key.KeyChar -notin @('q','Q'))
    Write-Host -NoNewline "$script:SddEsc[?25h$script:SddEsc[?1049l"
}
