#requires -Version 7.0
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'lib/common.ps1')
. (Join-Path $repoRoot 'lib/ledger.ps1')
. (Join-Path $repoRoot 'lib/stages.ps1')
. (Join-Path $repoRoot 'lib/tier0.ps1')

function Assert-True([bool] $Condition, [string] $Message) { if (-not $Condition) { throw "ASSERT FAILED: $Message" } }

$script:analyzeSeverity = 'warning'
function Invoke-FakeAnalyzeAgent {
    param([Parameter(Mandatory)] [hashtable] $Request)
    $count = if ($script:analyzeSeverity -eq 'none') { 0 } else { 1 }
    $final = "Analysis complete.`nSDD_ANALYZE_RESULT {`"highest_severity`":`"$script:analyzeSeverity`",`"finding_count`":$count,`"summary`":`"fixture summary`"}"
    [pscustomobject]@{ok=$true;session_id='analyze-session';denied=@();last_message=$final;log_path=$Request.log_path}
}
function Resolve-Adapter { param([string] $AgentName) return 'Invoke-FakeAnalyzeAgent' }

$fixture = Join-Path ([IO.Path]::GetTempPath()) ("sdd-analyze-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture -Force | Out-Null
try {
    foreach ($dir in @('.sdd','.sdd/logs','.specify','.agents/skills/speckit-analyze','specs/001-analyze')) {
        New-Item -ItemType Directory -Path (Join-Path $fixture $dir) -Force | Out-Null
    }
    Set-Content -LiteralPath (Join-Path $fixture '.gitignore') -Value '.sdd/logs/' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $fixture '.specify/feature.json') -Value '{"feature_directory":"specs/001-analyze"}' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $fixture '.agents/skills/speckit-analyze/SKILL.md') -Value 'Analyze $ARGUMENTS and report.' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $fixture 'specs/001-analyze/spec.md') -Value @('# Spec','content','done') -Encoding utf8

    $ledger=[pscustomobject]@{stages=[pscustomobject]@{
        spec=[pscustomobject]@{status='completed'};plan=[pscustomobject]@{status='completed'}
        tasks=[pscustomobject]@{status='completed'};analyze=[pscustomobject]@{status='not_started'}
        implement=[pscustomobject]@{status='not_started'}
    };tasks=@()}
    $config=[pscustomobject]@{
        agents=[pscustomobject]@{analyze=[pscustomobject]@{agent='fake';model='model';effort='medium'}}
        analyze=[pscustomobject]@{block_on='critical'}
    }
    & git -C $fixture init --quiet
    & git -C $fixture config user.email 'sdd-test@example.invalid'
    & git -C $fixture config user.name 'SDD Test'
    & git -C $fixture add .
    & git -C $fixture commit --quiet -m initial

    $warning = Invoke-Analyze -Config $config -Ledger $ledger -ProjectRoot $fixture
    Assert-True ($warning.ok -and -not $warning.blocked -and $warning.severity -eq 'warning') 'Warning, critical eşiğinde implementi engellememeli.'
    Assert-True ($ledger.stages.analyze.highest_severity -eq 'warning') 'Analyze sonucu ledger stage kaydına yazılmalı.'
    Assert-True (@(Get-GitStatusForTier0 -ProjectRoot $fixture).Count -eq 0) 'Analyze read-only kalmalı.'

    $script:analyzeSeverity = 'critical'
    $critical = Invoke-Analyze -Config $config -Ledger $ledger -ProjectRoot $fixture -Force
    Assert-True ($critical.ok -and $critical.blocked) 'Critical bulgu implementi engellemeli.'
    Write-Host 'ANALYZE INTEGRATION OK' -ForegroundColor Green
} finally {
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
