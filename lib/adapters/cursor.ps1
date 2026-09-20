<#
  Cursor Agent CLI adapteri.
  Resmî headless sözleşme: agent -p, stream-json, --resume, --force,
  --sandbox disabled, --trust ve --workspace.

  Cursor CLI ayrı bir reasoning-effort bayrağı yayımlamıyor. Adapter model
  adını değiştirmez; effort orkestratör metadata'sı olarak korunur.
#>

Set-StrictMode -Version Latest

function Convert-EffortToCursor {
    param([string] $Effort, [string] $Model)
    return $Model
}

function Get-CursorEventValue {
    param([object] $Object, [string[]] $Names)
    if ($null -eq $Object) { return $null }
    foreach ($name in $Names) {
        if ($Object.PSObject.Properties.Name -contains $name -and $null -ne $Object.$name) { return $Object.$name }
    }
    return $null
}

function Get-CursorEventTexts {
    param([object] $Event)
    $texts = [System.Collections.Generic.List[string]]::new()
    foreach ($candidate in @(
        (Get-CursorEventValue -Object $Event -Names @('text','result','content')),
        (Get-CursorEventValue -Object (Get-CursorEventValue -Object $Event -Names @('message')) -Names @('text','content'))
    )) {
        if ($candidate -is [string]) { if ($candidate) { $texts.Add($candidate) }; continue }
        foreach ($block in @($candidate)) {
            if ($block -is [string]) { if ($block) { $texts.Add($block) } }
            elseif ($null -ne $block -and $block.PSObject.Properties.Name -contains 'text' -and $block.text) { $texts.Add([string]$block.text) }
        }
    }
    return @($texts | Select-Object -Unique)
}

function Get-CursorToolValue {
    param([object] $Object, [string[]] $Names)
    if ($null -eq $Object) { return '' }
    foreach ($name in $Names) {
        if ($Object.PSObject.Properties.Name -contains $name -and $null -ne $Object.$name) {
            $value = $Object.$name
            if ($value -is [string]) { return [string]$value }
            return ($value | ConvertTo-Json -Compress -Depth 8)
        }
    }
    return ''
}

function Send-CursorToolActivity {
    param([object] $Tool, [string] $LogPath)
    if ($null -eq $Tool) { return }
    $name = Get-CursorToolValue -Object $Tool -Names @('name','tool_name','toolName')
    if (-not $name) { $name = 'tool' }
    $status = Get-CursorToolValue -Object $Tool -Names @('status','state')
    if (-not $status) { $status = 'running' }
    $args = Get-CursorEventValue -Object $Tool -Names @('args','arguments','input')
    if ($args -is [string] -and -not [string]::IsNullOrWhiteSpace($args)) {
        try { $args = $args | ConvertFrom-Json -ErrorAction Stop } catch { }
    }
    $command = Get-CursorToolValue -Object $args -Names @('command','cmd')
    $path = Get-CursorToolValue -Object $args -Names @('file_path','path','filename','target_file')

    if ($command -or $name -match '(?i)run_terminal_cmd|terminal|shell|bash|command') {
        Send-SddEvent -Message $name -Command $command -LogPath $LogPath -Category 'command' -EventType 'command_activity' -Source 'provider' -Provider 'cursor' -Status $status
    } elseif ($path -or $name -match '(?i)edit|write|patch|apply_patch|notebook') {
        $message = if ($path) { $path } else { $name }
        Send-SddEvent -Message $message -LogPath $LogPath -Category 'file_change' -EventType 'file_change' -Source 'provider' -Provider 'cursor' -Status $status
    } else {
        Send-SddEvent -Message $name -LogPath $LogPath -Category 'tool' -EventType 'tool_activity' -Source 'provider' -Provider 'cursor' -Status $status
    }
}

function Send-CursorStructuredActivities {
    param([object] $Event, [string] $LogPath)
    if ($null -eq $Event) { return }
    $type = [string](Get-CursorEventValue -Object $Event -Names @('type','event'))
    if ($type -match '(?i)tool') {
        $tool = Get-CursorEventValue -Object $Event -Names @('data','tool_call','toolCall')
        if ($null -eq $tool) { $tool = $Event }
        Send-CursorToolActivity -Tool $tool -LogPath $LogPath
    }

    $message = Get-CursorEventValue -Object $Event -Names @('message')
    $content = Get-CursorEventValue -Object $message -Names @('content')
    foreach ($block in @($content)) {
        if ($null -eq $block -or $block -is [string]) { continue }
        $blockType = [string](Get-CursorEventValue -Object $block -Names @('type'))
        if ($blockType -match '(?i)tool') { Send-CursorToolActivity -Tool $block -LogPath $LogPath }
    }

    if ($type -match '(?i)thinking|reasoning') {
        $text = Get-CursorToolValue -Object $Event -Names @('text','thinking','reasoning','content')
        if ($text) {
            Send-SddEvent -Message $text -LogPath $LogPath -Category 'reasoning_summary' -EventType 'reasoning' -Source 'provider' -Provider 'cursor'
        }
    }
}

function Read-CursorEvent {
    param(
        [string] $Line,
        [System.Collections.IDictionary] $Result,
        [System.Collections.Generic.List[string]] $MessageParts,
        [string] $LogPath
    )
    if ([string]::IsNullOrWhiteSpace($Line)) { return }
    $evt = $null
    try { $evt = $Line | ConvertFrom-Json -ErrorAction Stop } catch { }
    if ($null -eq $evt) { Send-SddEvent -Message $Line -LogPath $LogPath -Level 'stream' -Category 'command_output' -EventType 'provider_raw' -Source 'provider' -Provider 'cursor'; return }

    $session = Get-CursorEventValue -Object $evt -Names @('session_id','sessionId','chat_id','chatId')
    if ($session) { $Result.session_id = [string]$session }
    $type = [string](Get-CursorEventValue -Object $evt -Names @('type','event'))
    Send-CursorStructuredActivities -Event $evt -LogPath $LogPath
    if ($type -match '(?i)error|denied|permission_denied' -or
        ($evt.PSObject.Properties.Name -contains 'is_error' -and [bool]$evt.is_error)) {
        $msg = [string](Get-CursorEventValue -Object $evt -Names @('message','error','text'))
        if (-not $msg) { $msg = $Line }
        $Result.denied.Add($msg); Send-SddEvent -Message $msg -LogPath $LogPath -Level 'error' -Category 'error' -EventType 'provider_error' -Source 'provider' -Provider 'cursor'
    }
    $isResult = $type -match '(?i)^result$|complete|completed|done|finish'
    if ($isResult) { $Result._completed = $true }
    $isAssistant = $type -match '(?i)^assistant(?:_message)?$'
    $hasTimestamp = $evt.PSObject.Properties.Name -contains 'timestamp_ms'
    $hasModelCall = $evt.PSObject.Properties.Name -contains 'model_call_id'
    foreach ($part in @(Get-CursorEventTexts -Event $evt)) {
        if ($isAssistant -and [bool]$Result._stream_partial) {
            # Cursor partial sözleşmesi: yalnız timestamp'li, model_call_id'siz
            # olay yeni deltadır. Diğer assistant olayları buffered/final tekrar.
            if (-not $hasTimestamp -or $hasModelCall) { continue }
            $MessageParts.Add($part); $Result.last_message = ([string]$Result.last_message) + $part
            Send-SddEvent -Message $part -LogPath $LogPath -Level 'stream' -Category 'assistant' -EventType 'agent_message_partial' -Source 'provider' -Provider 'cursor'
            continue
        }
        if ($isResult) {
            $Result.last_message = $part
            if ($MessageParts.Count -eq 0) { $MessageParts.Add($part) }
            if ([bool]$Result._stream_partial -and -not [string]::IsNullOrWhiteSpace($part)) {
                Send-SddEvent -Message $part -LogPath $LogPath -Level 'stream' -Category 'assistant' -EventType 'agent_message' -Source 'provider' -Provider 'cursor' -Status 'completed'
            }
            continue
        }
        if ($isAssistant) {
            $MessageParts.Add($part); $Result.last_message = $part
            Send-SddEvent -Message $part -LogPath $LogPath -Level 'stream' -Category 'assistant' -EventType 'agent_message' -Source 'provider' -Provider 'cursor'
        }
    }
    $usage = Get-CursorEventValue -Object $evt -Names @('usage','token_usage','tokenUsage')
    if ($usage) { $Result.usage = $usage; Send-SddEvent -Message 'Cursor usage alındı' -LogPath $LogPath -Category 'usage' -EventType 'usage' -Source 'provider' -Provider 'cursor' -Usage $usage }
}

function Invoke-CursorAgent {
    param([Parameter(Mandatory)] [hashtable] $Request)

    $args = [System.Collections.Generic.List[string]]::new()
    $args.Add('-p')
    $args.Add('--output-format'); $args.Add('stream-json')
    if ($Request.ContainsKey('stream_partial') -and $Request.stream_partial) { $args.Add('--stream-partial-output') }
    $args.Add('--force')
    $args.Add('--sandbox'); $args.Add('disabled')
    $args.Add('--trust')
    $args.Add('--workspace'); $args.Add([string]$Request.cwd)
    $model = Convert-EffortToCursor -Effort ([string]$Request.effort) -Model ([string]$Request.model)
    if ($model) { $args.Add('--model'); $args.Add($model) }
    if ($Request.ContainsKey('resume_session') -and $Request.resume_session) {
        $args.Add('--resume'); $args.Add([string]$Request.resume_session)
    }
    $args.Add([string]$Request.prompt)

    $result = [ordered]@{
        ok = $false; session_id = $null
        denied = [System.Collections.Generic.List[string]]::new()
        last_message = $null; log_path = $Request.log_path; usage = $null; _completed = $false
        _stream_partial = [bool]($Request.ContainsKey('stream_partial') -and $Request.stream_partial)
    }
    $parts = [System.Collections.Generic.List[string]]::new()
    $exitCode = -1
    $agentStarted = Get-Date
    Send-SddEvent -Message "Cursor agent başladı · $($Request.model)" -LogPath $Request.log_path -Category 'agent' -EventType 'agent_started' -Source 'adapter' -Provider 'cursor' -Status 'running'
    Push-Location ([string]$Request.cwd)
    try {
        & agent @args 2>&1 | ForEach-Object {
            Read-CursorEvent -Line ([string]$_) -Result $result -MessageParts $parts -LogPath $Request.log_path
        }
        $exitCode = $LASTEXITCODE
    } catch {
        $result.denied.Add($_.Exception.Message)
        Send-SddEvent -Message $_.Exception.Message -LogPath $Request.log_path -Level 'error' -Category 'error' -EventType 'adapter_error' -Source 'adapter' -Provider 'cursor'
    } finally { Pop-Location }

    if ($exitCode -ne 0) { $result.denied.Add("Cursor CLI exit code: $exitCode") }
    # Cursor sürümleri completion event adını değiştirebildiğinden temiz exit,
    # parse edilmiş stream ve denial olmaması process-level başarıdır.
    $sawStream = $result._completed -or $parts.Count -gt 0 -or $result.session_id
    $result.ok = [bool]$sawStream -and $exitCode -eq 0 -and $result.denied.Count -eq 0
    $result.denied = @($result.denied)
    $duration = [long]((Get-Date) - $agentStarted).TotalMilliseconds
    Send-SddEvent -Message $(if ($result.ok) { 'Cursor agent tamamlandı' } else { 'Cursor agent başarısız' }) -LogPath $Request.log_path -Category 'agent' -EventType 'agent_completed' -Source 'adapter' -Provider 'cursor' -Status $(if ($result.ok) { 'completed' } else { 'failed' }) -DurationMs $duration
    $result.Remove('_completed'); $result.Remove('_stream_partial')
    return [pscustomobject]$result
}
