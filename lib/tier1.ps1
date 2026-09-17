<#
  tier1.ps1 — "Yapılan iş projeyi bozdu mu?"

  Config'deki proje komutlarını ucuzdan pahalıya çalıştırır. Loop başındaki
  baseline'da zaten kırık olan bir gate batch'e yüklenmez; sonradan ortaya
  çıkan veya sonradan kullanılabilir hâle gelen gate ise mutlaka geçmelidir.
#>

Set-StrictMode -Version Latest

function Get-GateProperty {
    param([object] $Gate, [Parameter(Mandatory)] [string] $Name)
    if ($null -eq $Gate) { return $null }
    if ($Gate -is [System.Collections.IDictionary] -and $Gate.Contains($Name)) { return $Gate[$Name] }
    if ($Gate.PSObject.Properties.Name -contains $Name) { return $Gate.$Name }
    return $null
}

function Get-NpmScriptInfo {
    param([string] $Command, [string] $ProjectRoot)

    $prefix = $null
    $scriptName = $null
    if ($Command -match '^\s*npm(?:\.cmd)?\s+(?:--prefix\s+([^\s]+)\s+)?run\s+([^\s]+)') {
        $prefix = $Matches[1]; $scriptName = $Matches[2]
    }
    elseif ($Command -match '^\s*npm(?:\.cmd)?\s+(?:--prefix\s+([^\s]+)\s+)?test(?:\s|$)') {
        $prefix = $Matches[1]; $scriptName = 'test'
    }
    else { return $null }

    if ($prefix) { $prefix = $prefix.Trim('"', "'") }
    $packageRoot = if ($prefix) { Join-Path $ProjectRoot $prefix } else { $ProjectRoot }
    [pscustomobject]@{ PackageRoot = $packageRoot; ScriptName = $scriptName }
}

function Test-GateAvailable {
    param([Parameter(Mandatory)] [object] $Gate, [Parameter(Mandatory)] [string] $ProjectRoot)

    $command = [string](Get-GateProperty -Gate $Gate -Name 'cmd')
    if ([string]::IsNullOrWhiteSpace($command)) { return $false }

    $npm = Get-NpmScriptInfo -Command $command -ProjectRoot $ProjectRoot
    if ($npm) {
        $packagePath = Join-Path $npm.PackageRoot 'package.json'
        if (-not (Test-Path -LiteralPath $packagePath -PathType Leaf)) { return $false }
        try {
            $package = Get-Content -LiteralPath $packagePath -Raw | ConvertFrom-Json
            return ($package.PSObject.Properties.Name -contains 'scripts' -and
                    $null -ne $package.scripts -and
                    $package.scripts.PSObject.Properties.Name -contains $npm.ScriptName)
        } catch { return $false }
    }

    if ($command -match '^\s*npx(?:\.cmd)?\s+(?:--yes\s+)?([^\s]+)') {
        $tool = $Matches[1]
        $suffix = if ($IsWindows) { '.cmd' } else { '' }
        $localTool = Join-Path $ProjectRoot "node_modules/.bin/$tool$suffix"
        if (Test-Path -LiteralPath $localTool -PathType Leaf) { return $true }
        $packagePath = Join-Path $ProjectRoot 'package.json'
        if (Test-Path -LiteralPath $packagePath -PathType Leaf) {
            try {
                $package = Get-Content -LiteralPath $packagePath -Raw | ConvertFrom-Json
                foreach ($bucket in @('dependencies','devDependencies')) {
                    if ($package.PSObject.Properties.Name -contains $bucket -and
                        $package.$bucket -and $package.$bucket.PSObject.Properties.Name -contains $tool) { return $true }
                }
            } catch { }
        }
        return $false
    }

    $firstToken = (($command.Trim() -split '\s+', 2)[0]).Trim('"', "'")
    if (Get-Command $firstToken -ErrorAction SilentlyContinue) { return $true }
    $candidate = Join-Path $ProjectRoot $firstToken
    return (Test-Path -LiteralPath $candidate -PathType Leaf)
}

function Invoke-GateCommand {
    param(
        [Parameter(Mandatory)] [object] $Gate,
        [Parameter(Mandatory)] [string] $ProjectRoot,
        [string] $LogPath
    )

    $name = [string](Get-GateProperty -Gate $Gate -Name 'name')
    $command = [string](Get-GateProperty -Gate $Gate -Name 'cmd')
    $output = [System.Collections.Generic.List[string]]::new()
    Write-SddLog -Message "[Tier 1/$name] $command" -LogPath $LogPath -Level 'info'

    Push-Location $ProjectRoot
    try {
        if ($IsWindows) {
            & cmd.exe /d /s /c $command 2>&1 | ForEach-Object {
                $line = [string]$_; $output.Add($line)
                Write-SddLog -Message $line -LogPath $LogPath -Level 'stream'
            }
        } else {
            & /bin/sh -lc $command 2>&1 | ForEach-Object {
                $line = [string]$_; $output.Add($line)
                Write-SddLog -Message $line -LogPath $LogPath -Level 'stream'
            }
        }
        $exitCode = $LASTEXITCODE
    } catch {
        $exitCode = 1
        $output.Add($_.Exception.Message)
        Write-SddLog -Message $_.Exception.Message -LogPath $LogPath -Level 'error'
    } finally {
        Pop-Location
    }

    [pscustomobject]@{
        ok        = ($exitCode -eq 0)
        exit_code = $exitCode
        output    = ($output -join [Environment]::NewLine)
    }
}

function Measure-GateBaseline {
    param([Parameter(Mandatory)] [object] $Config, [Parameter(Mandatory)] [string] $ProjectRoot)

    $baseline = [ordered]@{}
    $paths = Get-SddPaths -ProjectRoot $ProjectRoot
    $logPath = Join-Path $paths.LogsDir 'implement-gates.log'
    foreach ($gate in @($Config.gates)) {
        $name = [string](Get-GateProperty -Gate $gate -Name 'name')
        if (-not $name) { continue }
        $available = Test-GateAvailable -Gate $gate -ProjectRoot $ProjectRoot
        $passing = $false
        if ($available) {
            $result = Invoke-GateCommand -Gate $gate -ProjectRoot $ProjectRoot -LogPath $logPath
            $passing = $result.ok
        }
        $baseline[$name] = [pscustomobject]@{
            available   = [bool]$available
            passing     = [bool]$passing
            measured_at = (Get-Date).ToString('o')
        }
    }
    return [pscustomobject]$baseline
}

function Invoke-Tier1 {
    param(
        [Parameter(Mandatory)] [object] $Config,
        [Parameter(Mandatory)] [string] $ProjectRoot,
        [Parameter(Mandatory)] [object] $Ledger,
        [switch] $Strict
    )

    $paths = Get-SddPaths -ProjectRoot $ProjectRoot
    $logPath = Join-Path $paths.LogsDir 'implement-gates.log'
    foreach ($gate in @($Config.gates)) {
        $name = [string](Get-GateProperty -Gate $gate -Name 'name')
        if (-not $name) { continue }
        $requiredValue = Get-GateProperty -Gate $gate -Name 'required'
        $required = if ($null -eq $requiredValue) { $true } else { [bool]$requiredValue }

        $availableNow = Test-GateAvailable -Gate $gate -ProjectRoot $ProjectRoot
        if (-not $availableNow) {
            if ($Strict -and $required) {
                return [pscustomobject]@{
                    ok = $false; failed_gate = $name
                    output = "[$name unavailable] Strict final doğrulamada config'deki gate kullanılabilir olmalı: $([string](Get-GateProperty -Gate $gate -Name 'cmd'))"
                }
            }
            Write-SddLog -Message "[Tier 1/$name] atlandı (projede tanımlı değil)" -LogPath $logPath -Level 'info'
            continue
        }

        $base = $null
        if ($Ledger.PSObject.Properties.Name -contains 'gate_baseline' -and $Ledger.gate_baseline -and
            $Ledger.gate_baseline.PSObject.Properties.Name -contains $name) {
            $base = $Ledger.gate_baseline.$name
        }

        $result = Invoke-GateCommand -Gate $gate -ProjectRoot $ProjectRoot -LogPath $logPath
        $wasKnownBroken = ($null -ne $base -and [bool]$base.available -and -not [bool]$base.passing)
        $wasUnavailable = ($null -ne $base -and -not [bool]$base.available)

        if (-not $required -and -not $result.ok) {
            Write-SddLog -Message "[Tier 1/$name] optional gate başarısız; bloklamadı" -LogPath $logPath -Level 'warn'
            continue
        }

        if (-not $Strict -and $wasKnownBroken -and -not $result.ok) {
            Write-SddLog -Message "[Tier 1/$name] baseline'da da kırık; batch'e yüklenmedi" -LogPath $logPath -Level 'warn'
            continue
        }
        if (-not $Strict -and $wasUnavailable -and -not $result.ok) {
            # Sıfır projede package script'i kaynak dosyalardan daha erken
            # doğabilir. Gate ilk kez yeşil olana kadar probation'dadır; ilk
            # geçişinden sonra baseline'a latch edilir ve artık bozulamaz.
            Write-SddLog -Message "[Tier 1/$name] yeni gate henüz yeşil değil; ilk başarılı geçişe kadar ertelendi" -LogPath $logPath -Level 'warn'
            continue
        }
        if (-not $result.ok) {
            return [pscustomobject]@{
                ok          = $false
                failed_gate = $name
                output      = "[$name exit=$($result.exit_code)]`n$($result.output)"
            }
        }

        # Başlangıçta olmayan veya kırık olan gate artık geçiyorsa yeni temiz
        # baseline olur; sonraki batch'ler bunu bozamaz.
        if ($null -eq $base) {
            $Ledger.gate_baseline | Add-Member -NotePropertyName $name -NotePropertyValue ([pscustomobject]@{}) -Force
            $base = $Ledger.gate_baseline.$name
        }
        $base | Add-Member -NotePropertyName available -NotePropertyValue $true -Force
        $base | Add-Member -NotePropertyName passing -NotePropertyValue $true -Force
        $base | Add-Member -NotePropertyName measured_at -NotePropertyValue ((Get-Date).ToString('o')) -Force
    }
    return [pscustomobject]@{ ok = $true; failed_gate = $null; output = $null }
}
