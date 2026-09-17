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

function Invoke-FakeAgent {
    param([Parameter(Mandatory)] [hashtable] $Request)
    $matches = [regex]::Matches($Request.prompt, '(?m)^- (T\d{3,}):')
    foreach ($match in $matches) {
        $id = $match.Groups[1].Value
        $path = Join-Path $Request.cwd "src/$id.txt"
        Set-Content -LiteralPath $path -Value @("$id line one", "$id line two", "$id line three") -Encoding utf8
    }
    & git -C $Request.cwd add src
    & git -C $Request.cwd commit --quiet -m ("fake implement " + (($matches | ForEach-Object { $_.Groups[1].Value }) -join ', '))
    [pscustomobject]@{ ok = $true; session_id = [guid]::NewGuid().ToString(); denied = @(); last_message = 'done' }
}

# Test adapterini gerçek adapter çözümlemesinin önüne al.
function Resolve-Adapter { param([string] $AgentName) return 'Invoke-FakeAgent' }

$fixture = Join-Path ([IO.Path]::GetTempPath()) ("sdd-loop-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture -Force | Out-Null
try {
    foreach ($dir in @('.sdd','.sdd/logs','.specify','specs/001-loop','src')) {
        New-Item -ItemType Directory -Path (Join-Path $fixture $dir) -Force | Out-Null
    }
    Set-Content -LiteralPath (Join-Path $fixture '.gitignore') -Value '.sdd/logs/' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $fixture '.specify/feature.json') -Value '{"feature_directory":"specs/001-loop"}' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $fixture 'specs/001-loop/tasks.md') -Value @(
        '# Tasks', '', '## Phase 1: First', '', '- [ ] T001 Create `src/T001.txt`', '',
        '## Phase 2: Second', '', '- [ ] T002 Create `src/T002.txt`'
    ) -Encoding utf8

    $ledger = [pscustomobject]@{
        version = 1; spec_id = '001-loop'
        stages = [pscustomobject]@{
            spec = [pscustomobject]@{status='completed'}; plan = [pscustomobject]@{status='completed'}
            tasks = [pscustomobject]@{status='completed'}; analyze = [pscustomobject]@{status='completed';highest_severity='none';finding_count=0;summary='clean'}
            implement = [pscustomobject]@{status='not_started'}
        }
        gate_baseline = [pscustomobject]@{}
        tasks = @(
            [pscustomobject]@{id='T001';title='Create `src/T001.txt`';status='pending';attempts=0;files=@('src/T001.txt');depends_on=@();agent=$null;commit_sha=$null;last_gate_output=$null;updated_at=$null},
            [pscustomobject]@{id='T002';title='Create `src/T002.txt`';status='pending';attempts=0;files=@('src/T002.txt');depends_on=@('T001');agent=$null;commit_sha=$null;last_gate_output=$null;updated_at=$null}
        )
    }
    Write-Ledger -Ledger $ledger -StatePath (Join-Path $fixture '.sdd/state.json')

    & git -C $fixture init --quiet
    & git -C $fixture config user.email 'sdd-test@example.invalid'
    & git -C $fixture config user.name 'SDD Test'
    & git -C $fixture add .
    & git -C $fixture commit --quiet -m 'initial'

    $config = [pscustomobject]@{
        agents = [pscustomobject]@{ implement = [pscustomobject]@{agent='fake';model='gpt-5.6-sol';effort='medium'} }
        gates = @([pscustomobject]@{name='diff-check';cmd='git diff --check'})
        loop = [pscustomobject]@{batch_size=1;max_attempts=3;escalate_at=2;circuit_breaker=3;observe_every=0}
    }
    $result = Invoke-ImplementLoop -Config $config -Ledger $ledger -ProjectRoot $fixture
    Assert-True ($result.ok -and $result.reason -eq 'completed') 'Loop iki batch sonunda tamamlanmalı.'
    Assert-True (@($ledger.tasks | Where-Object status -eq 'done').Count -eq 2) 'İki task da done olmalı.'
    Assert-True ($ledger.stages.implement.status -eq 'completed') 'Implement stage completed olmalı.'
    Assert-True ((Get-Content -LiteralPath (Join-Path $fixture 'specs/001-loop/tasks.md') -Raw) -match '- \[x\] T002') 'tasks.md checkboxları işaretlenmeli.'
    Assert-True (@(Get-GitStatusForTier0 -ProjectRoot $fixture).Count -eq 0) 'Loop sonunda çalışma ağacı temiz olmalı.'
    Assert-True ((& git -C $fixture rev-list --count HEAD) -ge 6) 'Agent ve checkpoint commitleri üretilmeli.'
    Write-Host 'LOOP INTEGRATION OK' -ForegroundColor Green
} finally {
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
