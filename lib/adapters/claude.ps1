<#
  Claude Code CLI adapteri (2.1.x).
  Resmî headless sözleşme: claude -p, --output-format stream-json,
  --resume, --model, --effort ve bypassPermissions.
#>

Set-StrictMode -Version Latest

function Convert-EffortToClaude {
    param([string] $Effort, [string] $Model)
    switch ($Effort) {
        'low'    { 'low' }
        'medium' { 'medium' }
        'high'   { 'high' }
        'xhigh'  { 'xhigh' }
        'max'    { 'max' }
        default  { 'medium' }
    }
}

function ConvertTo-ClaudeTextParts {
    param([object] $Content)
    $parts = [System.Collections.Generic.List[string]]::new()
    if ($Content -is [string]) { if ($Content) { $parts.Add($Content) }; return @($parts) }
    foreach ($block in @($Content)) {
        if ($null -eq $block) { continue }
        if ($block -is [string]) { if ($block) { $parts.Add($block) }; continue }
        if ($block.PSObject.Properties.Name -contains 'text' -and $block.text) { $parts.Add([string]$block.text) }
    }
    return @($parts)
}

function Read-ClaudeEvent {
    param(
        [string] $Line,
        [System.Collections.IDictionary] $Result,
        [System.Collections.Generic.List[string]] $MessageParts,
        [string] $LogPath
    )
    if ([string]::IsNullOrWhiteSpace($Line)) { return }
    $evt = $null
    try { $evt = $Line | ConvertFrom-Json -ErrorAction Stop } catch { }
    if ($null -eq $evt) { Send-SddEvent -Message $Line -LogPath $LogPath -Level 'stream' -Category 'command_output' -EventType 'provider_raw' -Source 'provider' -Provider 'claude'; return }

    if ($evt.PSObject.Properties.Name -contains 'session_id' -and $evt.session_id) {
        $Result.session_id = [string]$evt.session_id
    }
    switch ([string]$evt.type) {
        'system' {
            if ($evt.PSObject.Properties.Name -contains 'subtype' -and $evt.subtype -eq 'init' -and $Result.session_id) {
                Send-SddEvent -Message 'Claude session başladı' -LogPath $LogPath -Category 'workflow' -EventType 'session_started' -Source 'provider' -Provider 'claude' -Metadata @{resume_available=$true}
            }
        }
        'assistant' {
            $content = if ($evt.PSObject.Properties.Name -contains 'message' -and $evt.message) { $evt.message.content } else { $evt.content }
            foreach ($part in @(ConvertTo-ClaudeTextParts -Content $content)) {
                $MessageParts.Add($part); Send-SddEvent -Message $part -LogPath $LogPath -Level 'stream' -Category 'assistant' -EventType 'agent_message' -Source 'provider' -Provider 'claude'
            }
            foreach ($block in @($content)) {
                if ($null -eq $block -or $block -is [string] -or -not ($block.PSObject.Properties.Name -contains 'type')) { continue }
                if ($block.type -eq 'tool_use') {
                    Send-SddEvent -Message ([string]$block.name) -LogPath $LogPath -Category 'tool' -EventType 'tool_use' -Source 'provider' -Provider 'claude' -Status 'started'
                } elseif ($block.type -in @('thinking','reasoning') -and $block.PSObject.Properties.Name -contains 'thinking') {
                    Send-SddEvent -Message ([string]$block.thinking) -LogPath $LogPath -Category 'reasoning_summary' -EventType 'reasoning' -Source 'provider' -Provider 'claude'
                }
            }
        }
        'stream_event' {
            if ($evt.event -and $evt.event.delta -and $evt.event.delta.type -eq 'text_delta') {
                Send-SddEvent -Message ([string]$evt.event.delta.text) -LogPath $LogPath -Level 'stream' -Category 'assistant' -EventType 'agent_message_partial' -Source 'provider' -Provider 'claude'
            }
        }
        'result' {
            $Result._completed = $true
            if ($evt.PSObject.Properties.Name -contains 'result' -and $evt.result) {
                $Result.last_message = [string]$evt.result
            }
            if ($evt.PSObject.Properties.Name -contains 'usage') {
                $Result.usage = $evt.usage
                Send-SddEvent -Message 'Claude usage alındı' -LogPath $LogPath -Category 'usage' -EventType 'usage' -Source 'provider' -Provider 'claude' -Usage $evt.usage
            }
            $permissionDenials = if ($evt.PSObject.Properties.Name -contains 'permission_denials') { @($evt.permission_denials) } else { @() }
            foreach ($denial in $permissionDenials) {
                if ($denial) { $Result.denied.Add(($denial | ConvertTo-Json -Compress -Depth 8)) }
            }
            if (($evt.PSObject.Properties.Name -contains 'is_error' -and [bool]$evt.is_error) -or
                ($evt.PSObject.Properties.Name -contains 'subtype' -and $evt.subtype -notin @('success',''))) {
                $Result.denied.Add("Claude result: $($evt.subtype)")
            }
        }
        'error' {
            $msg = if ($evt.PSObject.Properties.Name -contains 'message') { [string]$evt.message } else { $Line }
            $Result.denied.Add($msg); Send-SddEvent -Message $msg -LogPath $LogPath -Level 'error' -Category 'error' -EventType 'provider_error' -Source 'provider' -Provider 'claude'
        }
    }
}

function Invoke-ClaudeAgent {
    param([Parameter(Mandatory)] [hashtable] $Request)

    $args = [System.Collections.Generic.List[string]]::new()
    $args.Add('-p')
    $args.Add('--output-format'); $args.Add('stream-json')
    $args.Add('--verbose')
    if ($Request.ContainsKey('stream_partial') -and $Request.stream_partial) { $args.Add('--include-partial-messages') }
    $args.Add('--permission-mode'); $args.Add('bypassPermissions')
    if ($Request.model) { $args.Add('--model'); $args.Add([string]$Request.model) }
    $args.Add('--effort'); $args.Add((Convert-EffortToClaude -Effort ([string]$Request.effort) -Model ([string]$Request.model)))
    if ($Request.ContainsKey('resume_session') -and $Request.resume_session) {
        $args.Add('--resume'); $args.Add([string]$Request.resume_session)
    }
    if ($Request.ContainsKey('allowed_tools') -and @($Request.allowed_tools).Count -gt 0) {
        $args.Add('--allowedTools')
        foreach ($tool in @($Request.allowed_tools)) { $args.Add([string]$tool) }
    }
    $args.Add([string]$Request.prompt)

    $result = [ordered]@{
        ok = $false; session_id = $null
        denied = [System.Collections.Generic.List[string]]::new()
        last_message = $null; log_path = $Request.log_path; usage = $null; _completed = $false
    }
    $parts = [System.Collections.Generic.List[string]]::new()
    $exitCode = -1
    Push-Location ([string]$Request.cwd)
    try {
        & claude @args 2>&1 | ForEach-Object {
            Read-ClaudeEvent -Line ([string]$_) -Result $result -MessageParts $parts -LogPath $Request.log_path
        }
        $exitCode = $LASTEXITCODE
    } catch {
        $result.denied.Add($_.Exception.Message)
        Send-SddEvent -Message $_.Exception.Message -LogPath $Request.log_path -Level 'error' -Category 'error' -EventType 'adapter_error' -Source 'adapter' -Provider 'claude'
    } finally { Pop-Location }

    if ($exitCode -ne 0) { $result.denied.Add("Claude CLI exit code: $exitCode") }
    if (-not $result.last_message -and $parts.Count -gt 0) { $result.last_message = $parts[$parts.Count - 1] }
    $result.ok = [bool]$result._completed -and $exitCode -eq 0 -and $result.denied.Count -eq 0
    $result.denied = @($result.denied)
    $result.Remove('_completed')
    return [pscustomobject]$result
}
