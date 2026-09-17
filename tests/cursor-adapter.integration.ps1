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
    Write-Host 'CURSOR ADAPTER INTEGRATION OK' -ForegroundColor Green
} finally {
    Remove-Item Function:\global:agent -ErrorAction SilentlyContinue
    Remove-Variable -Scope global -Name CURSOR_MOCK_CAPTURE -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
