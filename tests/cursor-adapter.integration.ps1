#requires -Version 7.0
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'lib/common.ps1')
. (Join-Path $repoRoot 'lib/adapters/cursor.ps1')

function Assert-True([bool] $Condition, [string] $Message) { if (-not $Condition) { throw "ASSERT FAILED: $Message" } }

$fixture = Join-Path ([IO.Path]::GetTempPath()) ("sdd-cursor-adapter-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture -Force | Out-Null
try {
    $capture = Join-Path $fixture 'args.txt'
    $global:CURSOR_MOCK_CAPTURE = $capture
    function global:agent {
        Set-Content -LiteralPath $global:CURSOR_MOCK_CAPTURE -Value @($args) -Encoding utf8
        '{"type":"session.started","chatId":"cursor-session"}'
        '{"type":"assistant_message","message":{"content":[{"type":"text","text":"cursor done"}]}}'
        '{"type":"result","chatId":"cursor-session","result":"cursor done"}'
        $global:LASTEXITCODE = 0
    }

    $result = Invoke-CursorAgent -Request @{
        prompt='repair prompt'; model='auto'; effort='high'; resume_session='old-chat'
        cwd=$fixture; log_path=(Join-Path $fixture 'adapter.log')
    }
    Assert-True $result.ok 'Cursor mock turn başarılı olmalı.'
    Assert-True ($result.session_id -eq 'cursor-session' -and $result.last_message -eq 'cursor done') 'Cursor session ve mesaj ayrıştırılmalı.'
    $seen = @(Get-Content -LiteralPath $capture)
    foreach ($required in @('-p','stream-json','--force','disabled','--trust','--workspace','--model','auto')) {
        Assert-True ($seen -contains $required) "Cursor argümanı eksik: $required"
    }
    $resume = [array]::IndexOf($seen, '--resume')
    Assert-True ($resume -ge 0 -and $seen[$resume + 1] -eq 'old-chat') 'Cursor resume chat id aktarılmalı.'
    Assert-True ((Convert-EffortToCursor -Effort high -Model auto) -eq 'auto') 'Cursor effort model adını uydurmamalı.'

    $events=[Collections.Generic.List[object]]::new()
    function global:Send-SddEvent {
        param($Message,$EventType,$Category,$Provider,$LogPath,$Level,$Source,$Command,$Status,$DurationMs,$Usage,$Metadata)
        $events.Add([pscustomobject]@{message=$Message;event_type=$EventType;category=$Category;command=$Command;status=$Status})
    }
    $stream=[ordered]@{session_id=$null;denied=[Collections.Generic.List[string]]::new();last_message=$null;usage=$null;_completed=$false;_stream_partial=$true}
    $parts=[Collections.Generic.List[string]]::new()
    Read-CursorEvent '{"type":"assistant","timestamp_ms":1,"message":{"content":[{"type":"text","text":"Planning the "}]}}' $stream $parts ''
    Read-CursorEvent '{"type":"assistant","timestamp_ms":2,"message":{"content":[{"type":"text","text":"implementation"}]}}' $stream $parts ''
    Read-CursorEvent '{"type":"assistant","timestamp_ms":3,"model_call_id":"duplicate","message":{"content":[{"type":"text","text":"Planning the implementation"}]}}' $stream $parts ''
    Read-CursorEvent '{"type":"assistant","message":{"content":[{"type":"text","text":"Planning the implementation"}]}}' $stream $parts ''
    Assert-True (($events.message-join'')-eq'Planning the implementation'-and$events.Count-eq2) 'Yalnız gerçek Cursor deltaları yayınlanmalı; flush tekrarları atlanmalı.'
    Assert-True ($stream.last_message-eq'Planning the implementation') 'Cursor deltaları boşluksuz birleştirilmeli.'

    $completed=[ordered]@{session_id=$null;denied=[Collections.Generic.List[string]]::new();last_message=$null;usage=$null;_completed=$false;_stream_partial=$true}
    $completedParts=[Collections.Generic.List[string]]::new()
    Read-CursorEvent '{"type":"result","result":"Detailed report\nSDD_CONVERGE_RESULT {\"outcome\":\"tasks_appended\"}","message":{"content":[{"type":"text","text":"All tests passed."}]}}' $completed $completedParts ''
    Assert-True ($completed.last_message -match 'SDD_CONVERGE_RESULT') 'Cursor result eventindeki aggregate mesaj kısa nested mesaj tarafından ezilmemeli.'

    Read-CursorEvent '{"type":"tool_call","data":{"callId":"c1","name":"run_terminal_cmd","status":"running","args":{"command":"node --test tests/a.test.js"}}}' $stream $parts ''
    Read-CursorEvent '{"type":"tool_call","data":{"callId":"c2","name":"edit_file","status":"completed","args":{"path":"src/app.js"}}}' $stream $parts ''
    Assert-True (@($events | Where-Object { $_.category -eq 'command' -and $_.command -eq 'node --test tests/a.test.js' }).Count -eq 1) 'Cursor terminal toolu structured command event olmalı.'
    Assert-True (@($events | Where-Object { $_.category -eq 'file_change' -and $_.message -eq 'src/app.js' }).Count -eq 1) 'Cursor edit toolu structured file event olmalı.'
    Write-Host 'CURSOR ADAPTER INTEGRATION OK' -ForegroundColor Green
} finally {
    Remove-Item Function:\global:agent -ErrorAction SilentlyContinue
    Remove-Item Function:\global:Send-SddEvent -ErrorAction SilentlyContinue
    Remove-Variable -Scope global -Name CURSOR_MOCK_CAPTURE -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
