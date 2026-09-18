<# PowerShell 7 native TUI. ANSI alternate buffer is used only on an interactive terminal. #>

Set-StrictMode -Version Latest

$script:SddEsc = [char]27

function Get-SddTerminalSize {
    try {
        [pscustomobject]@{ Width = [Math]::Max(40, [Console]::WindowWidth); Height = [Math]::Max(12, [Console]::WindowHeight) }
    } catch { [pscustomobject]@{ Width = 100; Height = 30 } }
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

    $events = @($Context.events)
    $ai = @($events | Where-Object category -in @('assistant','reasoning_summary') | Select-Object -Last 5)
    $ops = @($events | Where-Object category -in @('tool','command','command_output','file_change') | Select-Object -Last 7)
    $flow = @($events | Where-Object category -in @('workflow','gate','error','usage') | Select-Object -Last 7)

    $lines.Add('│' + ' AI MESAJI'.PadRight($inner) + '│')
    if ($ai.Count -eq 0) { $lines.Add('│' + '  (henüz mesaj yok)'.PadRight($inner) + '│') }
    foreach ($e in $ai) { $lines.Add('│' + (Limit-SddText -Text ("  " + $e.message) -Width $inner).PadRight($inner) + '│') }
    $lines.Add('├' + ('─' * $inner) + '┤')
    $lines.Add('│' + ' İŞLEMLER / TERMİNAL'.PadRight($inner) + '│')
    foreach ($e in $ops) { $lines.Add('│' + (Limit-SddText -Text ('  ' + (Format-SddPlainEvent -Event $e)) -Width $inner).PadRight($inner) + '│') }
    $lines.Add('├' + ('─' * $inner) + '┤')
    $lines.Add('│' + ' WORKFLOW'.PadRight($inner) + '│')
    foreach ($e in $flow) { $lines.Add('│' + (Limit-SddText -Text ('  ' + (Format-SddPlainEvent -Event $e)) -Width $inner).PadRight($inner) + '│') }
    while ($lines.Count -lt ($Height - 2)) { $lines.Add('│' + (' ' * $inner) + '│') }
    if ($lines.Count -gt ($Height - 1)) { $lines = [System.Collections.Generic.List[string]]@($lines | Select-Object -First ($Height - 1)) }
    $lines.Add('└' + ('─' * $inner) + '┘')
    return @($lines)
}

function Start-SddLiveTui {
    param([Parameter(Mandatory)] [object] $Context)
    if (-not (Test-SddInteractiveTerminal)) { $Context.ui_mode = 'plain'; return }
    Write-Host -NoNewline "$script:SddEsc[?1049h$script:SddEsc[?25l"
    $Context.tui_active = $true
}

function Update-SddLiveTui {
    param([Parameter(Mandatory)] [object] $Context, [object] $Event)
    if (-not $Context.tui_active) { return }
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
        foreach ($task in @(Get-LedgerTasks $Ledger)) { $lines.Add((Limit-SddText -Text ('  {0,-7} {1,-11} {2}' -f $task.id,$task.status,$task.title) -Width $Width)) }
    } elseif ($Page -eq 'routing') {
        foreach ($name in @('spec','plan','tasks','analyze','implement','converge')) {
            $p=if($Config.agents.PSObject.Properties.Name-contains$name){$Config.agents.$name}else{$null}
            if($p){$cap=Get-SddAgentCapabilities -Agent $p.agent;$ready=if($cap.available){'ready'}else{'missing'};$lines.Add(('  {0,-10} {1,-8} {2}/{3}/{4}' -f $name,$ready,$p.agent,$p.model,$p.effort))}
        }
    } elseif ($Page -eq 'history') {
        foreach ($e in @($History|Select-Object -Last 25)) {
            $message=if($e.PSObject.Properties.Name-contains'message'){$e.message}else{''}
            $lines.Add((Limit-SddText -Text ("  $($e.timestamp) [$($e.stage)/$($e.category)] $($e.event_type) $message") -Width $Width))
        }
    } else {
        $feature=if($ProjectRoot){Get-FeatureDirectory -ProjectRoot $ProjectRoot}else{$null}
        foreach($name in @('spec.md','plan.md','tasks.md','research.md','data-model.md','quickstart.md')){$path=if($feature){Join-Path $feature $name}else{$name};$state=if($feature-and(Test-Path -LiteralPath $path)){'present'}else{'missing'};$lines.Add(('  {0,-18} {1}' -f $name,$state))}
    }
    $lines.Add(''); $lines.Add('Keys: ←/→ or Tab page · r refresh · e edit route · q quit')
    return @($lines)
}

function Show-SddDashboard {
    param([Parameter(Mandatory)] [string] $ProjectRoot)
    $paths = Get-SddPaths -ProjectRoot $ProjectRoot
    $interactive = Test-SddInteractiveTerminal
    $pages=@('overview','tasks','routing','history','artifacts');$index=0
    do {
        $ledger = Read-Ledger -StatePath $paths.State
        $config = Read-SddConfig -ConfigPath $paths.Config
        $history = @(Get-SddRunHistory -Path $paths.Runs -Last 50)
        $width = (Get-SddTerminalSize).Width
        $lines = Get-SddDashboardLines -Ledger $ledger -Config $config -History $history -Page $pages[$index] -ProjectRoot $ProjectRoot -Width $width
        if (-not $interactive) { $lines | ForEach-Object { Write-Host $_ }; return }
        Write-Host -NoNewline "$script:SddEsc[?1049h$script:SddEsc[?25l$script:SddEsc[H$script:SddEsc[2J"
        Write-Host -NoNewline ($lines -join [Environment]::NewLine)
        $key = [Console]::ReadKey($true)
        if($key.Key-in@('RightArrow','Tab')){$index=($index+1)%$pages.Count}
        elseif($key.Key-eq'LeftArrow'){$index=($index-1+$pages.Count)%$pages.Count}
        elseif($key.KeyChar-in@('e','E')){
            Write-Host -NoNewline "$script:SddEsc[?25h$script:SddEsc[?1049l"
            $null=Show-AgentSelection -Config $config -ConfigPath $paths.Config
        }
    } while ($key.KeyChar -notin @('q','Q'))
    Write-Host -NoNewline "$script:SddEsc[?25h$script:SddEsc[?1049l"
}
