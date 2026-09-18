<#
  events.ps1 — sağlayıcı, gate ve orkestratör çıktısını ortak olaylara çevirir.

  Adapterler terminale doğrudan yazmaz. Olaylar aynı anda:
    - okunabilir log dosyasına,
    - append-only .sdd/runs.jsonl telemetry dosyasına,
    - plain/raw/TUI renderer'a
  gönderilir. Telemetry best-effort'tür; yazma hatası workflow'u durdurmaz.
#>

Set-StrictMode -Version Latest

$script:SddEventContext = $null
$script:SddEventSinkEnabled = $false
$script:InSddEvent = $false

function Test-SddInteractiveTerminal {
    try {
        return -not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected
    } catch { return $false }
}

function Resolve-SddUiMode {
    param([ValidateSet('auto','plain','tui','raw')] [string] $Mode = 'auto')
    if ($Mode -ne 'auto') { return $Mode }
    if (Test-SddInteractiveTerminal) { return 'plain' }
    return 'plain'
}

function Test-SddPartialStreaming {
    return [bool]($script:SddEventContext -and $script:SddEventContext.ui_mode -eq 'tui')
}

function Initialize-SddEventContext {
    param(
        [Parameter(Mandatory)] [string] $ProjectRoot,
        [ValidateSet('auto','plain','tui','raw')] [string] $UiMode = 'auto',
        [string] $RunId,
        [string] $Stage = ''
    )
    $paths = Get-SddPaths -ProjectRoot $ProjectRoot
    if (-not $RunId) { $RunId = [guid]::NewGuid().ToString('N') }
    $script:SddEventContext = [ordered]@{
        project_root = $ProjectRoot
        telemetry_path = $paths.Runs
        run_id = $RunId
        sequence = 0
        ui_mode = Resolve-SddUiMode -Mode $UiMode
        stage = $Stage
        started_at = (Get-Date).ToString('o')
        events = [System.Collections.Generic.List[object]]::new()
        warnings = [System.Collections.Generic.List[string]]::new()
        tui_active = $false
    }
    $script:SddEventSinkEnabled = $true
    if ($script:SddEventContext.ui_mode -eq 'tui' -and (Get-Command Start-SddLiveTui -ErrorAction SilentlyContinue)) {
        Start-SddLiveTui -Context $script:SddEventContext
    }
    Send-SddEvent -Message 'run başladı' -Category 'workflow' -EventType 'run_started' -Stage $Stage -Status 'running'
    return [pscustomobject]$script:SddEventContext
}

function Close-SddEventContext {
    param([ValidateSet('completed','failed','interrupted')] [string] $Status = 'completed')
    if ($script:SddEventContext) { Send-SddEvent -Message "run $Status" -Category 'workflow' -EventType 'run_completed' -Status $Status }
    if ($script:SddEventContext -and $script:SddEventContext.tui_active -and
        (Get-Command Stop-SddLiveTui -ErrorAction SilentlyContinue)) {
        Stop-SddLiveTui -Context $script:SddEventContext
    }
    $script:SddEventSinkEnabled = $false
    $context = $script:SddEventContext
    $script:SddEventContext = $null
    return $context
}

function ConvertTo-SddSafeText {
    param([AllowNull()] [object] $Value, [int] $MaxLength = 4000)
    if ($null -eq $Value) { return $null }
    $text = [string]$Value
    # Telemetry/display must not persist obvious credential assignments.
    $text = $text -replace '(?i)\b(api[_-]?key|access[_-]?token|refresh[_-]?token|secret|password)\s*[=:]\s*[^\s]+', '$1=<redacted>'
    if ($text.Length -gt $MaxLength) { return $text.Substring(0, $MaxLength) + '…' }
    return $text
}

function ConvertTo-SddTelemetryEvent {
    param([Parameter(Mandatory)] [object] $Event)
    $safe = [ordered]@{}
    foreach ($name in @('timestamp','run_id','sequence','source','provider','stage','category','event_type',
                        'severity','status','duration_ms','task_ids','batch','attempt','agent','model','effort',
                        'exit_code','usage','metadata')) {
        if ($Event.PSObject.Properties.Name -contains $name -and $null -ne $Event.$name) { $safe[$name] = $Event.$name }
    }
    if ($Event.PSObject.Properties.Name -contains 'message' -and $Event.message -and $Event.category -ne 'command_output') {
        $limit = if ($Event.category -in @('assistant','reasoning_summary')) { 300 } else { 1000 }
        $safe.message = ConvertTo-SddSafeText -Value $Event.message -MaxLength $limit
    }
    if ($Event.PSObject.Properties.Name -contains 'command' -and $Event.command) {
        $safe.command = ConvertTo-SddSafeText -Value $Event.command -MaxLength 1000
    }
    return [pscustomobject]$safe
}

function Write-SddTelemetryEvent {
    param([Parameter(Mandatory)] [object] $Event, [Parameter(Mandatory)] [string] $Path)
    try {
        $dir = Split-Path -Parent $Path
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $safe = ConvertTo-SddTelemetryEvent -Event $Event
        Add-Content -LiteralPath $Path -Value ($safe | ConvertTo-Json -Compress -Depth 12) -Encoding utf8
        return $true
    } catch {
        if ($script:SddEventContext) { $script:SddEventContext.warnings.Add($_.Exception.Message) }
        return $false
    }
}

function Format-SddPlainEvent {
    param([Parameter(Mandatory)] [object] $Event)
    $tag = switch ([string]$Event.category) {
        'assistant'         { 'AI' }
        'reasoning_summary' { 'THINK' }
        'tool'              { 'TOOL' }
        'command'           { 'CMD' }
        'command_output'    { 'OUT' }
        'file_change'       { 'FILE' }
        'gate'              { 'GATE' }
        'usage'             { 'USAGE' }
        'error'             { 'ERROR' }
        default             { 'SDD' }
    }
    $state = if ($Event.status) { ":$($Event.status)" } else { '' }
    $body = if ($Event.command) { [string]$Event.command } else { [string]$Event.message }
    if ([string]::IsNullOrWhiteSpace($body)) { $body = [string]$Event.event_type }
    return "[$tag$state] $body"
}

function Write-SddEventLog {
    param([Parameter(Mandatory)] [object] $Event, [string] $LogPath)
    if (-not $LogPath) { return }
    $dir = Split-Path -Parent $LogPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $line = Format-SddPlainEvent -Event $Event
    Add-Content -LiteralPath $LogPath -Value $line -Encoding utf8
}

function Send-SddEvent {
    param(
        [AllowEmptyString()] [string] $Message = '',
        [string] $LogPath,
        [ValidateSet('info','warn','error','stream')] [string] $Level = 'info',
        [string] $Category = 'workflow',
        [string] $EventType = 'message',
        [string] $Source = 'orchestrator',
        [string] $Provider = '',
        [string] $Stage = '',
        [string] $Status = '',
        [string] $Command = '',
        [Nullable[int]] $ExitCode,
        [Nullable[long]] $DurationMs,
        [object] $Usage,
        [hashtable] $Metadata
    )
    if (-not $script:SddEventContext) {
        # Tests and direct library use keep the original line-oriented behavior.
        $script:InSddEvent = $true
        try { Write-SddLog -Message $Message -LogPath $LogPath -Level $Level }
        finally { $script:InSddEvent = $false }
        return
    }

    $script:SddEventContext.sequence = [int]$script:SddEventContext.sequence + 1
    $severity = switch ($Level) { 'error' { 'error' }; 'warn' { 'warning' }; default { 'info' } }
    $evt = [pscustomobject][ordered]@{
        timestamp = (Get-Date).ToString('o')
        run_id = [string]$script:SddEventContext.run_id
        sequence = [int]$script:SddEventContext.sequence
        source = $Source
        provider = $Provider
        stage = $(if ($Stage) { $Stage } else { [string]$script:SddEventContext.stage })
        category = $Category
        event_type = $EventType
        severity = $severity
        message = (ConvertTo-SddSafeText -Value $Message)
        command = (ConvertTo-SddSafeText -Value $Command)
        status = $Status
        exit_code = $ExitCode
        duration_ms = $DurationMs
        usage = $Usage
        metadata = $Metadata
    }
    $script:SddEventContext.events.Add($evt)
    while ($script:SddEventContext.events.Count -gt 250) { $script:SddEventContext.events.RemoveAt(0) }

    Write-SddEventLog -Event $evt -LogPath $LogPath
    [void](Write-SddTelemetryEvent -Event $evt -Path $script:SddEventContext.telemetry_path)

    switch ([string]$script:SddEventContext.ui_mode) {
        'raw' {
            $payload = ConvertTo-SddTelemetryEvent -Event $evt
            Write-Host ($payload | ConvertTo-Json -Compress -Depth 12)
        }
        'tui' {
            if (Get-Command Update-SddLiveTui -ErrorAction SilentlyContinue) {
                Update-SddLiveTui -Context $script:SddEventContext -Event $evt
            }
        }
        default {
            # Başarılı/uzun komutların ham satırları log ve telemetry'de kalır;
            # ana terminalde AI mesajlarının arasına dökülmez.
            if ($evt.category -eq 'command_output' -or $evt.event_type -eq 'agent_message_partial') { return }
            $line = Format-SddPlainEvent -Event $evt
            $color = switch ($severity) { 'error' { 'Red' }; 'warning' { 'Yellow' }; default { 'Gray' } }
            Write-Host $line -ForegroundColor $color
        }
    }
}

function Get-SddRunHistory {
    param([Parameter(Mandatory)] [string] $Path, [int] $Last = 100)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    $events = [System.Collections.Generic.List[object]]::new()
    foreach ($line in @(Get-Content -LiteralPath $Path -Tail ([Math]::Max($Last * 3, $Last)))) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $events.Add(($line | ConvertFrom-Json -ErrorAction Stop)) } catch { continue }
    }
    return @($events | Select-Object -Last $Last)
}
