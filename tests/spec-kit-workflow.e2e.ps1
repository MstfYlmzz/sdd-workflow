#requires -Version 7.0
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'lib/common.ps1')
. (Join-Path $repoRoot 'lib/ledger.ps1')

function Assert-True([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw "ASSERT FAILED: $Message" }
}

if (-not (Get-Command specify -ErrorAction SilentlyContinue)) {
    throw 'Spec Kit CLI gerekli. CI bu testten önce specify-cli v1.0.6 kurmalıdır.'
}

$fixture = Join-Path ([IO.Path]::GetTempPath()) ("sdd-speckit-e2e-" + [guid]::NewGuid().ToString('N'))
$shim = Join-Path $fixture 'bin'
$project = Join-Path $fixture 'project'
New-Item -ItemType Directory -Path $project -Force | Out-Null

try {
    & (Join-Path $repoRoot 'install.ps1') -InstallDir $shim -NoPath

    if (-not $IsWindows) {
        $posix = @'
#!/bin/sh
exec pwsh -NoProfile -File "$(dirname "$0")/sdd.ps1" "$@"
'@
        Set-Content -LiteralPath (Join-Path $shim 'sdd') -Value $posix -Encoding utf8 -NoNewline
        & chmod +x (Join-Path $shim 'sdd')
        if ($LASTEXITCODE -ne 0) { throw 'POSIX sdd test shim executable yapılamadı.' }
    }
    $env:PATH = "$shim$([IO.Path]::PathSeparator)$env:PATH"

    Push-Location $project
    try {
        & (Join-Path $shim 'sdd.ps1') init
        if ($LASTEXITCODE -ne 0) { throw 'sdd init başarısız.' }
    } finally {
        Pop-Location
    }

    foreach ($dir in @('specs/001-native','src')) {
        New-Item -ItemType Directory -Path (Join-Path $project $dir) -Force | Out-Null
    }

    Set-Content -LiteralPath (Join-Path $project '.specify/feature.json') -Value '{"feature_directory":"specs/001-native"}' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $project 'specs/001-native/spec.md') -Value '# Spec' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $project 'specs/001-native/plan.md') -Value '# Plan' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $project 'specs/001-native/tasks.md') -Value @(
        '# Tasks',
        '',
        '## Phase 1: Existing',
        '',
        '- [x] T001 Existing fixture task'
    ) -Encoding utf8

    $config = @'
agents:
  analyze:   { agent: codex, model: fixture, effort: medium }
  implement: { agent: codex, model: fixture, effort: medium }
  converge:  { agent: codex, model: fixture, effort: medium }
gates:
  - name: diff-check
    cmd: git diff --check
loop:
  batch_size: 1
  max_attempts: 2
  escalate_at: 2
  circuit_breaker: 2
  observe_every: 0
  enable_converge: false
  max_converge_rounds: 2
analyze:
  block_on: critical
'@
    Set-Content -LiteralPath (Join-Path $project '.sdd/config.yaml') -Value $config -Encoding utf8

    $statePath = Join-Path $project '.sdd/state.json'
    $ledger = Read-Ledger -StatePath $statePath
    $ledger.spec_id = '001-native'
    $ledger.stages.spec.status = 'completed'
    $ledger.stages.plan.status = 'completed'
    $ledger.stages.tasks.status = 'completed'
    $ledger.stages.analyze.status = 'completed'
    $ledger.stages.analyze | Add-Member -NotePropertyName highest_severity -NotePropertyValue 'none' -Force
    $ledger.stages.analyze | Add-Member -NotePropertyName finding_count -NotePropertyValue 0 -Force
    $ledger.stages.analyze | Add-Member -NotePropertyName summary -NotePropertyValue 'fixture clean' -Force
    $ledger.tasks = @(
        [pscustomobject]@{
            id='T001'; title='Existing fixture task'; status='done'; attempts=1
            files=@(); depends_on=@(); story=$null; phase=1; parallel=$false
            agent='fixture'; commit_sha=$null; last_gate_output=$null; updated_at=$null
        }
    )
    Write-Ledger -Ledger $ledger -StatePath $statePath

    & git -C $project config user.email 'sdd-test@example.invalid'
    & git -C $project config user.name 'SDD Test'
    & git -C $project add .
    & git -C $project commit --quiet -m 'spec kit workflow fixture'

    function Invoke-SpecifyJson {
        param([Parameter(Mandatory)] [string[]] $CliArgs)
        $stderrPath = Join-Path $fixture ("stderr-" + [guid]::NewGuid().ToString('N') + '.log')
        Push-Location $project
        try {
            $stdout = & specify @CliArgs --json 2> $stderrPath
            $code = $LASTEXITCODE
        } finally {
            Pop-Location
        }
        $stderr = if (Test-Path -LiteralPath $stderrPath) { Get-Content -LiteralPath $stderrPath -Raw } else { '' }
        $payload = $null
        if ($stdout) { $payload = (($stdout -join [Environment]::NewLine) | ConvertFrom-Json) }
        return [pscustomobject]@{ code=$code; payload=$payload; stderr=$stderr }
    }

    $first = Invoke-SpecifyJson -CliArgs @('workflow','run','sdd-native')
    Assert-True ($first.code -eq 0) "Spec Kit workflow run başarılı olmalı. stderr=$($first.stderr)"
    Assert-True ($first.payload.status -eq 'completed') 'İlk Spec Kit run completed olmalı.'
    Assert-True ($first.stderr -match 'workflow_prepare_completed') 'SDD raw eventleri Spec Kit parent prosesine forward edilmeli.'

    $domain = Read-Ledger -StatePath $statePath
    Assert-True ($domain.stages.implement.status -eq 'completed') '.sdd/state.json domain closure sonucunu authoritative tutmalı.'
    $runState = Join-Path $project ".specify/workflows/runs/$($first.payload.run_id)/state.json"
    Assert-True (Test-Path -LiteralPath $runState) 'Spec Kit ayrı pipeline run state tutmalı.'
    Assert-True (@(git -C $project status --porcelain).Count -eq 0) 'Spec Kit run state git worktreeyi kirletmemeli.'

    $beforeHash = (Get-FileHash -LiteralPath $statePath -Algorithm SHA256).Hash
    Set-Content -LiteralPath (Join-Path $project 'dirty.tmp') -Value 'force prepare failure' -Encoding utf8
    $failed = Invoke-SpecifyJson -CliArgs @('workflow','run','sdd-native')
    Assert-True ($failed.code -ne 0 -and $failed.payload.status -eq 'failed') 'Dirty worktree prepare stepini fail etmeli.'
    Assert-True ($failed.payload.current_step_id -eq 'tasks-ready') 'Failure doğru top-level stepte persist edilmeli.'
    $afterHash = (Get-FileHash -LiteralPath $statePath -Algorithm SHA256).Hash
    Assert-True ($beforeHash -eq $afterHash) 'Pipeline failure authoritative SDD domain stateini değiştirmemeli.'

    Remove-Item -LiteralPath (Join-Path $project 'dirty.tmp') -Force
    $resumed = Invoke-SpecifyJson -CliArgs @('workflow','resume',[string]$failed.payload.run_id)
    Assert-True ($resumed.code -eq 0 -and $resumed.payload.status -eq 'completed') 'Workflow resume failed top-level step üzerinden tamamlanmalı.'

    $status = Invoke-SpecifyJson -CliArgs @('workflow','status',[string]$failed.payload.run_id)
    Assert-True ($status.code -eq 0 -and $status.payload.status -eq 'completed') 'Workflow status resumed runı completed göstermeli.'
    Assert-True (@(git -C $project status --porcelain).Count -eq 0) 'Resume sonunda domain ve pipeline state worktree ile çakışmamalı.'

    Write-Host 'SPEC KIT WORKFLOW E2E OK' -ForegroundColor Green
} finally {
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
