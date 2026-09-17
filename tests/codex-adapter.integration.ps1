#requires -Version 7.0
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'lib/common.ps1')
. (Join-Path $repoRoot 'lib/adapters/codex.ps1')

function Assert-True([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw "ASSERT FAILED: $Message" }
}

$fixture = Join-Path ([IO.Path]::GetTempPath()) ("sdd-codex-adapter-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture -Force | Out-Null
$oldPath = $env:PATH
try {
    $mock = Join-Path $fixture 'codex'
    $capture = Join-Path $fixture 'args.txt'
    $scriptBody = @'
#!/bin/sh
printf '%s\n' "$@" > "$CODEX_MOCK_ARGS"
printf '%s\n' '{"type":"thread.started","thread_id":"mock-session"}'
printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"mock done"}}'
printf '%s\n' '{"type":"turn.completed","usage":{}}'
exit 0
'@
    Set-Content -LiteralPath $mock -Value $scriptBody -Encoding utf8NoBOM
    & chmod +x $mock
    $env:PATH = "${fixture}:$oldPath"
    $env:CODEX_MOCK_ARGS = $capture

    $result = Invoke-CodexAgent -Request @{
        prompt = 'repair prompt'; model = 'gpt-5.6-sol'; effort = 'high'
        resume_session = 'session-123'; cwd = $fixture
        log_path = (Join-Path $fixture 'adapter.log')
    }
    Assert-True $result.ok 'Mock resume turn başarılı dönmeli.'
    Assert-True ($result.session_id -eq 'mock-session') 'Session id JSONL olayından okunmalı.'

    $argsSeen = @(Get-Content -LiteralPath $capture)
    $resumeIndex = [array]::IndexOf($argsSeen, 'resume')
    $sandboxIndex = [array]::IndexOf($argsSeen, '-s')
    $cwdIndex = [array]::IndexOf($argsSeen, '-C')
    $configIndex = [array]::IndexOf($argsSeen, '-c')
    Assert-True ($argsSeen[0] -eq 'exec') 'İlk argüman exec olmalı.'
    Assert-True ($resumeIndex -gt $sandboxIndex -and $resumeIndex -gt $cwdIndex -and $resumeIndex -gt $configIndex) 'Exec seçenekleri resume subcommandinden önce gelmeli.'
    Assert-True ($argsSeen[$resumeIndex + 1] -eq 'session-123') 'Resume session id doğru yerde olmalı.'
    Assert-True ($argsSeen[$resumeIndex + 2] -eq 'repair prompt') 'Resume prompt session id sonrasında olmalı.'
    Write-Host 'CODEX ADAPTER INTEGRATION OK' -ForegroundColor Green
} finally {
    $env:PATH = $oldPath
    Remove-Item Env:CODEX_MOCK_ARGS -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
