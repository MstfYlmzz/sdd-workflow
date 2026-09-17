#requires -Version 7.0
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'lib/common.ps1')
. (Join-Path $repoRoot 'lib/ledger.ps1')
. (Join-Path $repoRoot 'lib/stages.ps1')
. (Join-Path $repoRoot 'lib/tier0.ps1')
. (Join-Path $repoRoot 'lib/tier1.ps1')
. (Join-Path $repoRoot 'lib/loop.ps1')

function Assert-True([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw "ASSERT FAILED: $Message" }
}

$fixture = Join-Path ([IO.Path]::GetTempPath()) ("sdd-smoke-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture -Force | Out-Null
try {
    & git -C $fixture init --quiet
    & git -C $fixture config user.email 'sdd-test@example.invalid'
    & git -C $fixture config user.name 'SDD Test'
    New-Item -ItemType Directory -Path (Join-Path $fixture 'src') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $fixture 'specs/001-smoke') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $fixture 'src/base.txt') -Value @('one','two','three') -Encoding utf8
    Set-Content -LiteralPath (Join-Path $fixture 'specs/001-smoke/tasks.md') -Value @(
        '# Tasks', '', '## Phase 1: Setup', '', '- [ ] T001 [P] Keep this exact task text in `src/new.txt`'
    ) -Encoding utf8
    & git -C $fixture add .
    & git -C $fixture commit --quiet -m 'initial'

    $baseline = Get-GitBaseline -ProjectRoot $fixture
    Set-Content -LiteralPath (Join-Path $fixture 'src/new.txt') -Value @('alpha','beta','gamma') -Encoding utf8
    & git -C $fixture add src/new.txt
    & git -C $fixture commit --quiet -m 'T001 implementation'
    $task = [pscustomobject]@{ id = 'T001'; title = 'add file'; files = @('src/new.txt') }
    $tier0 = Invoke-Tier0 -ProjectRoot $fixture -Baseline $baseline -Task $task
    Assert-True $tier0.ok "Tier 0 valid commit'i kabul etmeli: $($tier0.hard_fails -join '; ')"

    $badBaseline = Get-GitBaseline -ProjectRoot $fixture
    Add-Content -LiteralPath (Join-Path $fixture 'src/new.txt') -Value 'TODO later'
    & git -C $fixture add src/new.txt
    & git -C $fixture commit --quiet -m 'bad placeholder'
    $badTier0 = Invoke-Tier0 -ProjectRoot $fixture -Baseline $badBaseline -Task $task
    Assert-True (-not $badTier0.ok) 'Tier 0 yeni TODO satırını reddetmeli.'

    $ledger = [pscustomobject]@{
        tasks = @([pscustomobject]@{
            id = 'T001'; title = 'different ledger title'; status = 'done'; attempts = 1
            files = @('src/new.txt'); depends_on = @(); agent = 'codex'; commit_sha = 'abc'
            last_gate_output = $null; updated_at = $null
        })
    }
    $tasksPath = Join-Path $fixture 'specs/001-smoke/tasks.md'
    Render-TasksMd -Ledger $ledger -OutPath $tasksPath
    $rendered = Get-Content -LiteralPath $tasksPath -Raw
    Assert-True ($rendered -match '## Phase 1: Setup') 'Render phase başlığını korumalı.'
    Assert-True ($rendered -match '- \[x\] T001 \[P\] Keep this exact task text') 'Render açıklamayı koruyup checkbox işaretlemeli.'

    $passGate = [pscustomobject]@{ name = 'git-ok'; cmd = 'git status --porcelain' }
    $oldBroken = [pscustomobject]@{ name = 'old-broken'; cmd = 'git rev-parse --verify refs/heads/definitely-missing' }
    $config = [pscustomobject]@{ gates = @($passGate, $oldBroken) }
    $gateBaseline = Measure-GateBaseline -Config $config -ProjectRoot $fixture
    Assert-True $gateBaseline.'git-ok'.passing 'Geçen gate baseline içinde passing olmalı.'
    Assert-True (-not $gateBaseline.'old-broken'.passing) 'Kırık gate baseline içinde failing olmalı.'
    $gateLedger = [pscustomobject]@{ gate_baseline = $gateBaseline }
    $tier1 = Invoke-Tier1 -Config $config -ProjectRoot $fixture -Ledger $gateLedger
    Assert-True $tier1.ok 'Baseline içinde zaten kırık gate batch hatası sayılmamalı.'

    $newBroken = [pscustomobject]@{ name = 'new-broken'; cmd = 'git rev-parse --verify refs/heads/also-missing' }
    $config.gates = @($passGate, $newBroken)
    $tier1New = Invoke-Tier1 -Config $config -ProjectRoot $fixture -Ledger $gateLedger
    Assert-True (-not $tier1New.ok) 'Baseline sonrasında eklenen kırık gate Tier 1 fail olmalı.'

    $profile = Get-EscalatedProfile -BaseProfile ([pscustomobject]@{ agent='codex'; model='gpt-5.6-sol'; effort='medium' }) -Attempt 2
    Assert-True ($profile.model -eq 'gpt-5.6-sol' -and $profile.effort -eq 'high') 'Escalation modeli sabit tutup effort yükseltmeli.'

    Write-Host 'SMOKE OK' -ForegroundColor Green
} finally {
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
