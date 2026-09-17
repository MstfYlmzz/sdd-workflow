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

$script:fakeAttempts = 0
$script:seenEfforts = [System.Collections.Generic.List[string]]::new()
function Invoke-FlakyAgent {
    param([Parameter(Mandatory)] [hashtable] $Request)
    $script:fakeAttempts++
    $script:seenEfforts.Add([string]$Request.effort)
    $path = Join-Path $Request.cwd 'src/result.txt'
    if ($script:fakeAttempts -eq 1) {
        Set-Content -LiteralPath $path -Value @('first line','second line','TODO repair this') -Encoding utf8
    } else {
        Set-Content -LiteralPath $path -Value @('first line','second line','finished line') -Encoding utf8
    }
    & git -C $Request.cwd add src/result.txt
    & git -C $Request.cwd commit --quiet -m "T001 attempt $script:fakeAttempts"
    [pscustomobject]@{ ok = $true; session_id = 'retry-session'; denied = @(); last_message = 'done' }
}
function Resolve-Adapter { param([string] $AgentName) return 'Invoke-FlakyAgent' }

$fixture = Join-Path ([IO.Path]::GetTempPath()) ("sdd-retry-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture -Force | Out-Null
try {
    foreach ($dir in @('.sdd','.sdd/logs','.specify','specs/001-retry','src')) {
        New-Item -ItemType Directory -Path (Join-Path $fixture $dir) -Force | Out-Null
    }
    Set-Content -LiteralPath (Join-Path $fixture '.gitignore') -Value '.sdd/logs/' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $fixture '.specify/feature.json') -Value '{"feature_directory":"specs/001-retry"}' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $fixture 'specs/001-retry/tasks.md') -Value @('# Tasks','','- [ ] T001 Create `src/result.txt`') -Encoding utf8

    $ledger = [pscustomobject]@{
        version=1; spec_id='001-retry'
        stages=[pscustomobject]@{
            spec=[pscustomobject]@{status='completed'};plan=[pscustomobject]@{status='completed'}
            tasks=[pscustomobject]@{status='completed'};analyze=[pscustomobject]@{status='completed'}
            implement=[pscustomobject]@{status='not_started'}
        }
        gate_baseline=[pscustomobject]@{}
        tasks=@([pscustomobject]@{id='T001';title='Create `src/result.txt`';status='pending';attempts=0;files=@('src/result.txt');depends_on=@();agent=$null;commit_sha=$null;last_gate_output=$null;updated_at=$null})
    }
    Write-Ledger -Ledger $ledger -StatePath (Join-Path $fixture '.sdd/state.json')
    & git -C $fixture init --quiet
    & git -C $fixture config user.email 'sdd-test@example.invalid'
    & git -C $fixture config user.name 'SDD Test'
    & git -C $fixture add .
    & git -C $fixture commit --quiet -m 'initial'

    $config=[pscustomobject]@{
        agents=[pscustomobject]@{implement=[pscustomobject]@{agent='fake';model='gpt-5.6-sol';effort='medium'}}
        gates=@([pscustomobject]@{name='diff-check';cmd='git diff --check'})
        loop=[pscustomobject]@{batch_size=1;max_attempts=3;escalate_at=2;circuit_breaker=3;observe_every=0}
    }
    $result=Invoke-ImplementLoop -Config $config -Ledger $ledger -ProjectRoot $fixture
    Assert-True $result.ok 'İkinci denemede düzeltilen task tamamlanmalı.'
    Assert-True ($ledger.tasks[0].attempts -eq 2) 'Task attempts iki olmalı.'
    Assert-True ($script:seenEfforts.Count -eq 2 -and $script:seenEfforts[0] -eq 'medium' -and $script:seenEfforts[1] -eq 'high') 'Retry effort high seviyesine yükselmeli.'
    Assert-True ($ledger.tasks[0].status -eq 'done') 'Task iki tier geçince done olmalı.'
    Assert-True (-not $ledger.tasks[0].last_gate_output) 'Başarılı retry son hata metnini temizlemeli.'
    Write-Host 'RETRY INTEGRATION OK' -ForegroundColor Green
} finally {
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
