<#
  tier0.ps1 — "Agent gerçekten bir iş yaptı mı?"

  Tier 0 proje komutlarını bilmez. Bir batch başlamadan alınan git commit'ini
  batch sonrasındaki HEAD ile karşılaştırır. Agent'ın anlattığına değil, git
  kanıtına bakar. .sdd/logs çalışma sırasında değişebildiği için yalnızca temiz
  tree kontrolünde görmezden gelinir; commit'e girerse yan hasar sayılır.
#>

Set-StrictMode -Version Latest

function Invoke-GitCapture {
    param(
        [Parameter(Mandatory)] [string] $ProjectRoot,
        [Parameter(Mandatory)] [string[]] $Arguments,
        [switch] $AllowFailure
    )

    $lines = @(& git -C $ProjectRoot @Arguments 2>&1 | ForEach-Object { [string]$_ })
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "git $($Arguments -join ' ') başarısız (exit=$exitCode): $($lines -join [Environment]::NewLine)"
    }
    [pscustomobject]@{
        ExitCode = $exitCode
        Lines     = $lines
        Text      = ($lines -join [Environment]::NewLine)
    }
}

function New-Tier0Check {
    param([string[]] $HardFails = @(), [string[]] $Warnings = @())
    [pscustomobject]@{
        ok         = (@($HardFails).Count -eq 0)
        hard_fails = @($HardFails)
        warnings   = @($Warnings)
    }
}

function Get-GitBaseline {
    param([Parameter(Mandatory)] [string] $ProjectRoot)

    $inside = Invoke-GitCapture -ProjectRoot $ProjectRoot -Arguments @('rev-parse','--is-inside-work-tree') -AllowFailure
    if ($inside.ExitCode -ne 0 -or $inside.Text.Trim() -ne 'true') {
        throw "Implement loop bir git çalışma ağacı gerektirir: $ProjectRoot"
    }
    $head = Invoke-GitCapture -ProjectRoot $ProjectRoot -Arguments @('rev-parse','--verify','HEAD') -AllowFailure
    if ($head.ExitCode -ne 0 -or -not $head.Text.Trim()) {
        throw "Implement loop başlamadan önce en az bir başlangıç commit'i gerekli."
    }
    return $head.Text.Trim()
}

function Get-GitStatusForTier0 {
    param([Parameter(Mandatory)] [string] $ProjectRoot)

    # Log dosyaları orkestratör tarafından agent çalışırken yazılır. Bunlar
    # çalışma ağacı temizliği kararına dahil değildir.
    $res = Invoke-GitCapture -ProjectRoot $ProjectRoot -Arguments @(
        'status','--porcelain','--untracked-files=all','--','.',':(exclude).sdd/logs/**',':(exclude).sdd/runs.jsonl',':(exclude).spectatui.toml'
    )
    return @($res.Lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Get-ChangedFileRecords {
    param([Parameter(Mandatory)] [string] $ProjectRoot, [Parameter(Mandatory)] [string] $Baseline)

    $res = Invoke-GitCapture -ProjectRoot $ProjectRoot -Arguments @(
        'diff','--name-status','--find-renames',"$Baseline..HEAD",'--'
    )
    $records = foreach ($line in $res.Lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = $line -split "`t"
        if ($parts.Count -lt 2) { continue }
        $status = $parts[0]
        $path = if ($status -match '^R' -and $parts.Count -ge 3) { $parts[2] } else { $parts[1] }
        [pscustomobject]@{ Status = $status; Path = ($path -replace '\\','/'); Raw = $line }
    }
    return @($records)
}

function Get-AddedLines {
    param([Parameter(Mandatory)] [string] $ProjectRoot, [Parameter(Mandatory)] [string] $Baseline)

    $res = Invoke-GitCapture -ProjectRoot $ProjectRoot -Arguments @(
        'diff','--unified=0','--no-color',"$Baseline..HEAD",'--'
    )
    return @($res.Lines | Where-Object { $_ -match '^\+(?!\+\+\+)' } | ForEach-Object { $_.Substring(1) })
}

function Test-DiffExists {
    param($ProjectRoot, $Baseline)
    $changed = @(Get-ChangedFileRecords -ProjectRoot $ProjectRoot -Baseline $Baseline)
    if ($changed.Count -eq 0) { return New-Tier0Check -HardFails @('Baseline sonrasında hiçbir dosya değişmedi.') }
    return New-Tier0Check
}

function Test-FilesTouched {
    param($ProjectRoot, $Baseline, $Task)

    $expected = @()
    if ($Task.PSObject.Properties.Name -contains 'files' -and $Task.files) {
        $expected = @($Task.files | ForEach-Object { ([string]$_ -replace '\\','/').TrimStart([char[]]'./') })
    }
    if ($expected.Count -eq 0) { return New-Tier0Check }

    $changed = @(Get-ChangedFileRecords -ProjectRoot $ProjectRoot -Baseline $Baseline | ForEach-Object { $_.Path })
    $matched = $false
    foreach ($want in $expected) {
        foreach ($actual in $changed) {
            if ($actual -eq $want -or $actual.StartsWith("$want/") -or $want.StartsWith("$actual/")) {
                $matched = $true
                break
            }
        }
        if ($matched) { break }
    }
    if (-not $matched) {
        return New-Tier0Check -Warnings @(
            "$($Task.id): beklenen dosyalardan hiçbiri değişmedi. Beklenen: $($expected -join ', '); değişen: $($changed -join ', ')"
        )
    }
    return New-Tier0Check
}

function Test-FilesSubstantial {
    param($ProjectRoot, $Baseline)

    $fails = [System.Collections.Generic.List[string]]::new()
    $added = @(Get-ChangedFileRecords -ProjectRoot $ProjectRoot -Baseline $Baseline | Where-Object { $_.Status -eq 'A' })
    foreach ($record in $added) {
        $fullPath = Join-Path $ProjectRoot ($record.Path -replace '/', [IO.Path]::DirectorySeparatorChar)
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { continue }
        $bytes = [IO.File]::ReadAllBytes($fullPath)
        if ($bytes -contains 0) { continue } # binary dosya: satır ölçümü uygulanamaz
        $meaningful = @(Get-Content -LiteralPath $fullPath -ErrorAction SilentlyContinue | Where-Object {
            $s = $_.Trim()
            $s -and $s -notmatch '^(#|//|/\*|\*|<!--|-->)'
        })
        if ($meaningful.Count -lt 3) {
            $fails.Add("Yeni dosya anlamlı içerik taşımıyor (<3 satır): $($record.Path)")
        }
    }
    return New-Tier0Check -HardFails @($fails)
}

function Test-NoPlaceholders {
    param($AddedLines)
    $hits = @($AddedLines | Where-Object {
        # Tireyi de identifier parçası say: "todo-list" gibi gerçek ürün/paket
        # adları TODO marker'ı değildir; "TODO:" ve "FIXME(" yine yakalanır.
        $_ -match '(?i)(?<![\w-])(TODO|FIXME)(?![\w-])|not\s+implemented|NotImplementedException'
    } | Select-Object -First 10)
    if ($hits.Count -gt 0) {
        return New-Tier0Check -HardFails @("Eklenen satırlarda placeholder bulundu: $($hits -join ' | ')")
    }
    return New-Tier0Check
}

function Test-NoSuppressions {
    param($AddedLines)
    $hits = @($AddedLines | Where-Object {
        $_ -match '(?i)@ts-ignore|@ts-nocheck|eslint-disable|pytest\.mark\.skip|\b(xit|xdescribe|test\.skip|describe\.skip|it\.skip)\s*\('
    } | Select-Object -First 10)
    if ($hits.Count -gt 0) {
        return New-Tier0Check -HardFails @("Eklenen satırlarda kontrol/test bastırma bulundu: $($hits -join ' | ')")
    }
    return New-Tier0Check
}

function Get-TestDeclarationCount {
    param([string[]] $Lines)
    if ($null -eq $Lines) { return 0 }
    return @($Lines | Where-Object {
        $_ -match '(?i)(^|\W)(test|it|describe|context)\s*\(|(^|\W)(def\s+test_|it\s+["''])'
    }).Count
}

function Test-TestCountKept {
    param($ProjectRoot, $Baseline)

    $fails = [System.Collections.Generic.List[string]]::new()
    $testFiles = @(Get-ChangedFileRecords -ProjectRoot $ProjectRoot -Baseline $Baseline | Where-Object {
        $_.Path -match '(?i)(^|/)(__tests__|tests?)(/|$)|\.(test|spec)\.[^/]+$'
    })
    foreach ($record in $testFiles) {
        if ($record.Status -eq 'A') { continue }
        $beforeResult = Invoke-GitCapture -ProjectRoot $ProjectRoot -Arguments @('show',"$Baseline`:$($record.Path)") -AllowFailure
        $before = if ($beforeResult.ExitCode -eq 0) { $beforeResult.Lines } else { @() }
        $fullPath = Join-Path $ProjectRoot ($record.Path -replace '/', [IO.Path]::DirectorySeparatorChar)
        $after = if (Test-Path -LiteralPath $fullPath -PathType Leaf) { @(Get-Content -LiteralPath $fullPath) } else { @() }
        $beforeCount = Get-TestDeclarationCount -Lines $before
        $afterCount = Get-TestDeclarationCount -Lines $after
        if ($afterCount -lt $beforeCount) {
            $fails.Add("Test sayısı azaldı: $($record.Path) ($beforeCount -> $afterCount)")
        }
    }
    return New-Tier0Check -HardFails @($fails)
}

function Test-NoCollateral {
    param($ProjectRoot, $Baseline)

    $fails = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()
    foreach ($record in @(Get-ChangedFileRecords -ProjectRoot $ProjectRoot -Baseline $Baseline)) {
        $path = $record.Path
        if ($path -match '(^|/)node_modules(/|$)') { $fails.Add("node_modules commit'e girdi: $path") }
        if ($path -match '(^|/)\.sdd/logs(/|$)') { $fails.Add("Çalışma logu commit'e girdi: $path") }
        if ($path -match '(^|/)\.env($|\.)' -and $path -notmatch '(?i)\.env\.(example|sample|template)$') {
            $fails.Add("Potansiyel gizli ortam dosyası commit'e girdi: $path")
        }
        if ($record.Status -eq 'D' -and $path -match '(?i)(^|/)(__tests__|tests?)(/|$)|\.(test|spec)\.[^/]+$') {
            $fails.Add("Test dosyası silindi: $path")
        }
        if ($path -match '(?i)(^|/)(package-lock\.json|npm-shrinkwrap\.json|yarn\.lock|pnpm-lock\.yaml|poetry\.lock|Pipfile\.lock)$') {
            $warnings.Add("Lockfile değişti; dependency değişikliği task kapsamıyla doğrulanmalı: $path")
        }
    }
    return New-Tier0Check -HardFails @($fails) -Warnings @($warnings)
}

function Test-TasksMdUntouched {
    param($ProjectRoot, $Baseline)
    $hits = @(Get-ChangedFileRecords -ProjectRoot $ProjectRoot -Baseline $Baseline | Where-Object {
        [IO.Path]::GetFileName($_.Path) -ieq 'tasks.md'
    })
    if ($hits.Count -gt 0) {
        return New-Tier0Check -HardFails @("Agent tasks.md dosyasına dokundu; checkbox yalnızca orkestratöründür: $(@($hits.Path) -join ', ')")
    }
    return New-Tier0Check
}

function Test-CommittedClean {
    param($ProjectRoot, $Baseline)

    $fails = [System.Collections.Generic.List[string]]::new()
    $count = Invoke-GitCapture -ProjectRoot $ProjectRoot -Arguments @('rev-list','--count',"$Baseline..HEAD") -AllowFailure
    if ($count.ExitCode -ne 0 -or [int]($count.Text.Trim()) -lt 1) {
        $fails.Add('Agent baseline sonrasında commit üretmedi.')
    }
    $dirty = @(Get-GitStatusForTier0 -ProjectRoot $ProjectRoot)
    if ($dirty.Count -gt 0) {
        $fails.Add("Çalışma ağacı temiz değil: $($dirty -join ' | ')")
    }
    return New-Tier0Check -HardFails @($fails)
}

function Invoke-Tier0 {
    param(
        [Parameter(Mandatory)] [string] $ProjectRoot,
        [Parameter(Mandatory)] [string] $Baseline,
        [Parameter(Mandatory)] [object] $Task
    )

    $hardFails = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()
    $addedLines = @(Get-AddedLines -ProjectRoot $ProjectRoot -Baseline $Baseline)
    $checks = @(
        (Test-DiffExists -ProjectRoot $ProjectRoot -Baseline $Baseline),
        (Test-FilesTouched -ProjectRoot $ProjectRoot -Baseline $Baseline -Task $Task),
        (Test-FilesSubstantial -ProjectRoot $ProjectRoot -Baseline $Baseline),
        (Test-NoPlaceholders -AddedLines $addedLines),
        (Test-NoSuppressions -AddedLines $addedLines),
        (Test-TestCountKept -ProjectRoot $ProjectRoot -Baseline $Baseline),
        (Test-NoCollateral -ProjectRoot $ProjectRoot -Baseline $Baseline),
        (Test-TasksMdUntouched -ProjectRoot $ProjectRoot -Baseline $Baseline),
        (Test-CommittedClean -ProjectRoot $ProjectRoot -Baseline $Baseline)
    )
    foreach ($check in $checks) {
        foreach ($item in @($check.hard_fails)) { if ($item) { $hardFails.Add([string]$item) } }
        foreach ($item in @($check.warnings)) { if ($item) { $warnings.Add([string]$item) } }
    }
    return New-Tier0Check -HardFails @($hardFails | Select-Object -Unique) -Warnings @($warnings | Select-Object -Unique)
}
