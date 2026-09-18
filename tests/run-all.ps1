#requires -Version 7.0
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$parseErrors = [System.Collections.Generic.List[object]]::new()
Get-ChildItem -LiteralPath $repoRoot -Recurse -Filter '*.ps1' | ForEach-Object {
    $tokens = $null
    $parseIssues = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$parseIssues)
    foreach ($parseIssue in @($parseIssues)) { $parseErrors.Add($parseIssue) }
}
if ($parseErrors.Count -gt 0) { $parseErrors | Format-List; throw 'PowerShell parse kontrolü başarısız.' }
Write-Host 'PARSE OK' -ForegroundColor Green

$tests = @(
    'smoke.ps1',
    'codex-adapter.integration.ps1',
    'claude-adapter.integration.ps1',
    'cursor-adapter.integration.ps1',
    'events-tui.integration.ps1',
    'agent-selection.integration.ps1',
    'analyze.integration.ps1',
    'converge.integration.ps1',
    'loop.integration.ps1',
    'retry.integration.ps1',
    'revalidate.integration.ps1',
    'final-gate.integration.ps1'
)
foreach ($test in $tests) {
    Write-Host "`n=== $test ===" -ForegroundColor Cyan
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot $test)
    if ($LASTEXITCODE -ne 0) { throw "$test başarısız (exit=$LASTEXITCODE)." }
}
Write-Host "`nALL TESTS OK" -ForegroundColor Green
