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
    if ($null -eq $evt) { Write-SddLog -Message $Line -LogPath $LogPath -Level 'stream'; return }

    if ($evt.PSObject.Properties.Name -contains 'session_id' -and $evt.session_id) {
        $Result.session_id = [string]$evt.session_id
    }
    switch ([string]$evt.type) {
        'system' {
            if ($evt.PSObject.Properties.Name -contains 'subtype' -and $evt.subtype -eq 'init' -and $Result.session_id) {
                Write-SddLog -Message "session: $($Result.session_id)" -LogPath $LogPath -Level 'info'
            }
        }
        'assistant' {
            $content = if ($evt.PSObject.Properties.Name -contains 'message' -and $evt.message) { $evt.message.content } else { $evt.content }
            foreach ($part in @(ConvertTo-ClaudeTextParts -Content $content)) {
                $MessageParts.Add($part); Write-SddLog -Message $part -LogPath $LogPath -Level 'stream'
            }
        }
        'result' {
            $Result._completed = $true
            if ($evt.PSObject.Properties.Name -contains 'result' -and $evt.result) {
                $Result.last_message = [string]$evt.result
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
            $Result.denied.Add($msg); Write-SddLog -Message "HATA: $msg" -LogPath $LogPath -Level 'error'
        }
    }
}

function Invoke-ClaudeAgent {
    param([Parameter(Mandatory)] [hashtable] $Request)

    $args = [System.Collections.Generic.List[string]]::new()
    $args.Add('-p')
    $args.Add('--output-format'); $args.Add('stream-json')
    $args.Add('--verbose')
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
        last_message = $null; log_path = $Request.log_path; _completed = $false
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
        Write-SddLog -Message $_.Exception.Message -LogPath $Request.log_path -Level 'error'
    } finally { Pop-Location }

    if ($exitCode -ne 0) { $result.denied.Add("Claude CLI exit code: $exitCode") }
    if (-not $result.last_message -and $parts.Count -gt 0) { $result.last_message = $parts[$parts.Count - 1] }
    $result.ok = [bool]$result._completed -and $exitCode -eq 0 -and $result.denied.Count -eq 0
    $result.denied = @($result.denied)
    $result.Remove('_completed')
    return [pscustomobject]$result
}
