#requires -Version 7.0
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'lib/common.ps1')
. (Join-Path $repoRoot 'lib/adapters/claude.ps1')

function Assert-True([bool] $Condition, [string] $Message) { if (-not $Condition) { throw "ASSERT FAILED: $Message" } }

$fixture = Join-Path ([IO.Path]::GetTempPath()) ("sdd-claude-adapter-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture -Force | Out-Null
try {
    $capture = Join-Path $fixture 'args.txt'
    $global:CLAUDE_MOCK_CAPTURE = $capture
    function global:claude {
        Set-Content -LiteralPath $global:CLAUDE_MOCK_CAPTURE -Value @($args) -Encoding utf8
        '{"type":"system","subtype":"init","session_id":"claude-session"}'
        '{"type":"stream_event","event":{"type":"message_start","message":{"id":"msg-1"}}}'
        '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"partial"}}}'
        '{"type":"assistant","message":{"content":[{"type":"text","text":"working"}]}}'
        '{"type":"result","subtype":"success","is_error":false,"result":"claude done","session_id":"claude-session","permission_denials":[]}'
        $global:LASTEXITCODE = 0
    }

    $result = Invoke-ClaudeAgent -Request @{
        prompt='repair prompt'; model='sonnet'; effort='high'; resume_session='old-session'
        cwd=$fixture; log_path=(Join-Path $fixture 'adapter.log')
    }
    Assert-True $result.ok 'Claude mock turn başarılı olmalı.'
    Assert-True ($result.session_id -eq 'claude-session' -and $result.last_message -eq 'claude done') 'Claude session ve final mesajı ayrıştırılmalı.'
    $seen = @(Get-Content -LiteralPath $capture)
    Assert-True ($seen -contains '-p' -and $seen -contains 'stream-json') 'Claude print stream-json kullanmalı.'
    Assert-True ($seen -contains 'bypassPermissions') 'Claude non-interactive izin modu kullanmalı.'
    $resume = [array]::IndexOf($seen, '--resume')
    Assert-True ($resume -ge 0 -and $seen[$resume + 1] -eq 'old-session') 'Claude resume id aktarılmalı.'
    Assert-True ((Convert-EffortToClaude -Effort high -Model sonnet) -eq 'high') 'Claude effort doğrudan eşlenmeli.'

    $events=[Collections.Generic.List[object]]::new()
    function Send-SddEvent {
        param($Message,$EventType,$Category,$Provider,$LogPath,$Level,$Source,$Command,$Status,$DurationMs,$Usage,$Metadata,$Stage,$ExitCode)
        $events.Add([pscustomobject]@{message=$Message;event_type=$EventType;category=$Category;command=$Command;status=$Status})
    }
    $bash = '{"type":"tool_use","name":"Bash","input":{"command":"node --test tests/a.test.js"}}' | ConvertFrom-Json
    $edit = '{"type":"tool_use","name":"Write","input":{"file_path":"src/app.js"}}' | ConvertFrom-Json
    Send-ClaudeToolActivity -Block $bash -LogPath ''
    Send-ClaudeToolActivity -Block $edit -LogPath ''
    Assert-True (@($events | Where-Object { $_.category -eq 'command' -and $_.command -eq 'node --test tests/a.test.js' }).Count -eq 1) 'Claude Bash toolu structured terminal event olmalı.'
    Assert-True (@($events | Where-Object { $_.category -eq 'file_change' -and $_.message -eq 'src/app.js' }).Count -eq 1) 'Claude Write toolu structured file event olmalı.'
    Write-Host 'CLAUDE ADAPTER INTEGRATION OK' -ForegroundColor Green
} finally {
    Remove-Item Function:\global:claude -ErrorAction SilentlyContinue
    Remove-Variable -Scope global -Name CLAUDE_MOCK_CAPTURE -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
