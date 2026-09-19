#requires -Version 7.0
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'lib/common.ps1')
. (Join-Path $repoRoot 'lib/ledger.ps1')
. (Join-Path $repoRoot 'lib/spectatui.ps1')

function Assert-True([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw "ASSERT FAILED: $Message" }
}

$fixture = Join-Path ([IO.Path]::GetTempPath()) ("sdd-specta-status-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture -Force | Out-Null
try {
    $null = Initialize-SddProject -ProjectRoot $fixture
    $statePath = Join-Path $fixture '.sdd/state.json'
    $ledger = Read-Ledger -StatePath $statePath
    $ledger.spec_id = '001-status'
    $ledger.stages.implement.status = 'running'
    $ledger.stages.implement | Add-Member -NotePropertyName agent -NotePropertyValue 'codex' -Force
    $ledger.stages.implement | Add-Member -NotePropertyName model -NotePropertyValue 'gpt-test' -Force
    $ledger.stages.implement | Add-Member -NotePropertyName effort -NotePropertyValue 'medium' -Force
    $ledger.tasks = @(
        [pscustomobject]@{id='T001';title='done';status='done';attempts=1;files=@();depends_on=@();story=$null;phase=1;parallel=$false},
        [pscustomobject]@{id='T002';title='pending';status='pending';attempts=1;files=@();depends_on=@();story=$null;phase=1;parallel=$false},
        [pscustomobject]@{id='T003';title='blocked';status='blocked';attempts=3;files=@();depends_on=@();story=$null;phase=1;parallel=$false}
    )
    Write-Ledger -Ledger $ledger -StatePath $statePath

    $profile = [pscustomobject]@{agent='codex';model='gpt-test';effort='high'}
    $args1 = @{
        ProjectRoot = $fixture
        Ledger = $ledger
        Stage = 'implement'
        Status = 'running'
        Batch = @($ledger.tasks[1])
        BatchNumber = 4
        Attempt = 2
        MaxAttempts = 3
        Profile = $profile
    }
    $null = Write-SddSpectaStatus @args1

    $path = Join-Path $fixture '.specify/sdd-status.json'
    Assert-True (Test-Path -LiteralPath $path) 'Projection dosyası üretilmeli.'
    $doc = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    Assert-True (-not [bool]$doc.authoritative) 'Projection authoritative state olmamalı.'
    Assert-True ($doc.spec_id -eq '001-status' -and $doc.stage -eq 'implement' -and $doc.status -eq 'running') 'Spec/stage/status doğru olmalı.'
    Assert-True ($doc.tasks.total -eq 3 -and $doc.tasks.done -eq 1 -and $doc.tasks.pending -eq 1 -and $doc.tasks.blocked -eq 1) 'Task sayaçları ledgerdan türetilmeli.'
    Assert-True (@($doc.runtime.batch).Count -eq 1 -and $doc.runtime.batch[0] -eq 'T002') 'Aktif batch görünmeli.'
    Assert-True ($doc.runtime.batch_number -eq 4 -and $doc.runtime.attempt -eq 2 -and $doc.runtime.max_attempts -eq 3) 'Batch/retry metadata görünmeli.'
    Assert-True ($doc.runtime.agent -eq 'codex' -and $doc.runtime.model -eq 'gpt-test' -and $doc.runtime.effort -eq 'high') 'Routing metadata görünmeli.'

    $ledger.stages.implement.status = 'completed'
    $ledger.stages.converge.status = 'running'
    $ledger.stages.converge | Add-Member -NotePropertyName round -NotePropertyValue 2 -Force
    $args2 = @{
        ProjectRoot = $fixture
        Ledger = $ledger
        Stage = 'converge'
        Status = 'running'
        Profile = [pscustomobject]@{agent='claude';model='sonnet';effort='medium'}
        ConvergenceRound = 2
        MaxConvergenceRounds = 3
    }
    $null = Write-SddSpectaStatus @args2
    $doc = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    Assert-True ($doc.stage -eq 'converge') 'Converge explicit stage olarak görünmeli.'
    Assert-True ($doc.runtime.convergence_round -eq 2 -and $doc.runtime.max_convergence_rounds -eq 3) 'Convergence round görünmeli.'

    Push-Location $fixture
    try {
        & git check-ignore -q .specify/sdd-status.json
        Assert-True ($LASTEXITCODE -eq 0) 'Projection Git-ignore edilmiş olmalı.'
    } finally {
        Pop-Location
    }

    Write-Host 'SPECTATUI STATUS INTEGRATION OK' -ForegroundColor Green
} finally {
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
