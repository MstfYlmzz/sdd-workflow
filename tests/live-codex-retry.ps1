#requires -Version 7.0
<#
  Gerçek Codex CLI resume testi. Varsayılan test takımında token harcamaz.
  Çalıştırmak için: $env:SDD_RUN_LIVE_CODEX='1'; pwsh tests/live-codex-retry.ps1
#>
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($env:SDD_RUN_LIVE_CODEX -ne '1') {
    Write-Host 'LIVE CODEX RETRY SKIPPED (SDD_RUN_LIVE_CODEX=1 değil).' -ForegroundColor Yellow
    exit 0
}
if (-not (Get-Command codex -ErrorAction SilentlyContinue)) { throw 'codex CLI PATH içinde bulunamadı.' }

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'lib/common.ps1')
. (Join-Path $repoRoot 'lib/ledger.ps1')
. (Join-Path $repoRoot 'lib/stages.ps1')
. (Join-Path $repoRoot 'lib/tier0.ps1')
. (Join-Path $repoRoot 'lib/tier1.ps1')
. (Join-Path $repoRoot 'lib/loop.ps1')
. (Join-Path $repoRoot 'lib/adapters/codex.ps1')

function Assert-True([bool] $Condition, [string] $Message) { if (-not $Condition) { throw "ASSERT FAILED: $Message" } }

$script:liveCalls = 0
function Invoke-LiveCodexWithInjectedFailure {
    param([Parameter(Mandatory)] [hashtable] $Request)
    $script:liveCalls++
    $result = Invoke-CodexAgent -Request $Request
    if ($result.ok -and $script:liveCalls -eq 1) {
        Add-Content -LiteralPath (Join-Path $Request.cwd 'src/result.txt') -Value 'TODO injected validator failure'
        & git -C $Request.cwd add src/result.txt
        & git -C $Request.cwd commit --quiet -m 'test: inject retry failure'
    }
    return $result
}
function Resolve-Adapter { param([string] $AgentName) return 'Invoke-LiveCodexWithInjectedFailure' }

$fixture = Join-Path ([IO.Path]::GetTempPath()) ("sdd-live-codex-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture -Force | Out-Null
$keep = $false
try {
    foreach ($dir in @('.sdd','.sdd/logs','.specify','specs/001-live','src')) { New-Item -ItemType Directory -Path (Join-Path $fixture $dir) -Force | Out-Null }
    Set-Content -LiteralPath (Join-Path $fixture '.gitignore') -Value '.sdd/logs/' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $fixture '.specify/feature.json') -Value '{"feature_directory":"specs/001-live"}' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $fixture 'specs/001-live/spec.md') -Value @('# Live retry fixture','Create one plain text result file.','No placeholders are allowed.') -Encoding utf8
    Set-Content -LiteralPath (Join-Path $fixture 'specs/001-live/plan.md') -Value @('# Plan','Create and commit the requested file.','Run git diff --check.') -Encoding utf8
    Set-Content -LiteralPath (Join-Path $fixture 'specs/001-live/tasks.md') -Value @('# Tasks','','- [ ] T001 Create `src/result.txt` with at least three meaningful completed lines') -Encoding utf8
    $ledger=[pscustomobject]@{version=1;spec_id='001-live';gate_baseline=[pscustomobject]@{};stages=[pscustomobject]@{
        spec=[pscustomobject]@{status='completed'};plan=[pscustomobject]@{status='completed'};tasks=[pscustomobject]@{status='completed'}
        analyze=[pscustomobject]@{status='completed';highest_severity='none';finding_count=0;summary='fixture'}
        implement=[pscustomobject]@{status='not_started'}
    };tasks=@([pscustomobject]@{id='T001';title='Create `src/result.txt` with at least three meaningful completed lines';status='pending';attempts=0;files=@('src/result.txt');depends_on=@();agent=$null;commit_sha=$null;last_gate_output=$null;updated_at=$null})}
    Write-Ledger -Ledger $ledger -StatePath (Join-Path $fixture '.sdd/state.json')
    & git -C $fixture init --quiet
    & git -C $fixture config user.email 'sdd-live@example.invalid'
    & git -C $fixture config user.name 'SDD Live Test'
    & git -C $fixture add .
    & git -C $fixture commit --quiet -m initial

    $model = if ($env:SDD_LIVE_CODEX_MODEL) { $env:SDD_LIVE_CODEX_MODEL } else { 'gpt-5.6-sol' }
    $config=[pscustomobject]@{
        agents=[pscustomobject]@{implement=[pscustomobject]@{agent='codex';model=$model;effort='medium'}}
        gates=@([pscustomobject]@{name='diff-check';cmd='git diff --check'})
        loop=[pscustomobject]@{batch_size=1;max_attempts=3;escalate_at=2;circuit_breaker=3;observe_every=0}
        analyze=[pscustomobject]@{block_on='critical'}
    }
    $result=Invoke-ImplementLoop -Config $config -Ledger $ledger -ProjectRoot $fixture
    Assert-True ($result.ok -and $result.reason -eq 'completed') 'Gerçek Codex retry loop tamamlanmalı.'
    Assert-True ($script:liveCalls -eq 2 -and $ledger.tasks[0].attempts -eq 2) 'İlk fail sonrası aynı task bir kez resume edilmelidir.'
    Assert-True ($ledger.tasks[0].status -eq 'done') 'Task retry sonrası done olmalı.'
    Write-Host "LIVE CODEX RETRY OK — fixture: $fixture" -ForegroundColor Green
} catch {
    $keep = $true
    Write-Host "LIVE CODEX RETRY FAILED — fixture korundu: $fixture" -ForegroundColor Red
    throw
} finally {
    if (-not $keep -and $env:SDD_KEEP_LIVE_FIXTURE -ne '1' -and (Test-Path -LiteralPath $fixture)) {
        Remove-Item -LiteralPath $fixture -Recurse -Force
    }
}
