<#
  common.ps1 — proje-agnostik yardımcılar.
  Kural: buradaki hiçbir fonksiyon proje ismi/klasörü/komutu SABİT yazmaz.
  İhtiyaç duyulan her projeye özel değer config'den okunur.
#>

Set-StrictMode -Version Latest

function Find-ProjectRoot {
    <#
      İçinde bulunulan klasörden yukarı doğru .sdd/ arar, bulunca ana klasörü
      döndürür. Bulamazsa hata verir ("sdd init çalıştır" der).
    #>
    param([string] $StartPath = (Get-Location).Path)

    $dir = Get-Item -LiteralPath $StartPath
    while ($null -ne $dir) {
        if (Test-Path -LiteralPath (Join-Path $dir.FullName '.sdd') -PathType Container) {
            return $dir.FullName
        }
        $dir = $dir.Parent
    }
    throw "Bu klasör bir SDD projesi değil (.sdd/ bulunamadı). Önce 'sdd init' çalıştır."
}

function Get-SddPaths {
    <#
      Projedeki .sdd/ altındaki standart yolları tek nesnede döndürür.
      Her yerde bu kullanılır ki yollar tek yerden yönetilsin.
    #>
    param([Parameter(Mandatory)] [string] $ProjectRoot)

    $sdd = Join-Path $ProjectRoot '.sdd'
    [pscustomobject]@{
        Root      = $ProjectRoot
        SddDir    = $sdd
        Config    = Join-Path $sdd 'config.yaml'
        State     = Join-Path $sdd 'state.json'
        SpecsDir  = Join-Path $sdd 'specs'
        LogsDir   = Join-Path $sdd 'logs'
    }
}

function Read-SddConfig {
    <#
      config.yaml'ı okur ve nesne olarak döndürür.
      powershell-yaml modülü varsa onu kullanır (tam YAML desteği); yoksa
      bu repo'nun sığ/düzenli config'i için yeterli olan yerleşik mini
      ayrıştırıcıya düşer. Böylece kullanıcı hiçbir şey kurmak zorunda değil.
    #>
    param([Parameter(Mandatory)] [string] $ConfigPath)

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "config.yaml bulunamadı: $ConfigPath"
    }
    $text = Get-Content -LiteralPath $ConfigPath -Raw

    if (Get-Module -ListAvailable powershell-yaml) {
        Import-Module powershell-yaml -ErrorAction Stop
        return ConvertFrom-Yaml $text
    }
    return ConvertFrom-MiniYaml $text
}

function ConvertFrom-MiniYaml {
    <#
      Yerleşik mini YAML ayrıştırıcı. TAM YAML DEĞİL — yalnızca bu repo'nun
      config.yaml şeklini destekler:
        - anahtar: değer
        - iki seviye girinti (nested map)
        - "- name: x / cmd: y" biçiminde nesne listeleri (gates)
        - satır içi akış eşlemesi: { a: 1, b: 2 }
        - # yorumları ve boş satırlar
      Sayılar int'e, true/false bool'a çevrilir.
    #>
    param([string] $Text)

    function Convert-Scalar([string] $v) {
        $v = $v.Trim()
        if ($v -match '^".*"$' -or $v -match "^'.*'$") { return $v.Substring(1, $v.Length - 2) }
        if ($v -match '^-?\d+$') { return [int] $v }
        if ($v -eq 'true')  { return $true }
        if ($v -eq 'false') { return $false }
        return $v
    }

    function Convert-Flow([string] $s) {
        # { a: 1, b: two } -> hashtable
        $h = [ordered]@{}
        $inner = $s.Trim().TrimStart('{').TrimEnd('}')
        foreach ($pair in $inner -split ',') {
            if ($pair -notmatch ':') { continue }
            $k, $v = $pair -split ':', 2
            $h[$k.Trim()] = Convert-Scalar $v
        }
        return $h
    }

    # Yorumları/boş satırları at, (indent, content) çiftlerini çıkar.
    $rows = foreach ($raw in ($Text -split "`r?`n")) {
        if ($raw -match '^\s*#' -or $raw.Trim() -eq '') { continue }
        $noComment = $raw -replace '\s+#.*$', ''
        if ($noComment.Trim() -eq '') { continue }
        [pscustomobject]@{
            Indent  = ($noComment -replace '\S.*$', '').Length
            Content = $noComment.Trim()
        }
    }
    $rows = @($rows)

    # Özyinelemeli inişli ayrıştırma: verilen girinti seviyesindeki bloğu
    # ayrıştırır, [ref]$i ile satır imlecini ilerletir. Liste mi map mi
    # olduğuna bloğun ilk satırı '-' ile başlıyor mu diye bakarak karar verir.
    function Parse-Block {
        param([int] $MinIndent, [ref] $i)

        if ($script:__rows[$i.Value].Content -match '^-\s') {
            # --- liste bloğu ---
            $list = [System.Collections.Generic.List[object]]::new()
            $listIndent = $script:__rows[$i.Value].Indent
            while ($i.Value -lt $script:__rows.Count -and
                   $script:__rows[$i.Value].Indent -eq $listIndent -and
                   $script:__rows[$i.Value].Content -match '^-\s*(.*)$') {
                $itemBody = $Matches[1].Trim()
                $obj = [ordered]@{}
                if ($itemBody -match '^([^:]+):\s*(.*)$') {
                    $obj[$Matches[1].Trim()] = Convert-Scalar $Matches[2]
                }
                $i.Value++
                # öğeye ait, daha girintili "k: v" satırları
                while ($i.Value -lt $script:__rows.Count -and $script:__rows[$i.Value].Indent -gt $listIndent) {
                    $sub = $script:__rows[$i.Value].Content
                    if ($sub -match '^([^:]+):\s*(.*)$') {
                        $k = $Matches[1].Trim(); $v = $Matches[2].Trim()
                        if ($v -eq '') { $i.Value++; $obj[$k] = Parse-Block -MinIndent ($listIndent + 1) -i $i }
                        elseif ($v -match '^\{.*\}$') { $obj[$k] = Convert-Flow $v; $i.Value++ }
                        else { $obj[$k] = Convert-Scalar $v; $i.Value++ }
                    } else { $i.Value++ }
                }
                $list.Add($obj)
            }
            return $list
        }

        # --- map bloğu ---
        $map = [ordered]@{}
        $blockIndent = $script:__rows[$i.Value].Indent
        while ($i.Value -lt $script:__rows.Count -and $script:__rows[$i.Value].Indent -eq $blockIndent) {
            $c = $script:__rows[$i.Value].Content
            if ($c -match '^([^:]+):\s*(.*)$') {
                $key = $Matches[1].Trim(); $val = $Matches[2].Trim()
                if ($val -eq '') {
                    $i.Value++
                    if ($i.Value -lt $script:__rows.Count -and $script:__rows[$i.Value].Indent -gt $blockIndent) {
                        $map[$key] = Parse-Block -MinIndent ($blockIndent + 1) -i $i
                    } else {
                        $map[$key] = [ordered]@{}
                    }
                }
                elseif ($val -match '^\{.*\}$') { $map[$key] = Convert-Flow $val; $i.Value++ }
                else { $map[$key] = Convert-Scalar $val; $i.Value++ }
            } else {
                $i.Value++
            }
        }
        return $map
    }

    $script:__rows = $rows
    $idx = 0
    if ($rows.Count -eq 0) { return [ordered]@{} }
    $result = Parse-Block -MinIndent 0 -i ([ref]$idx)
    Remove-Variable -Scope script -Name __rows -ErrorAction SilentlyContinue
    return $result
}

function Write-SddLog {
    <#
      Bir satırı hem terminale (canlı akış) hem .sdd/logs/ altındaki dosyaya
      yazar. "Terminal boş ama arkada çalışıyor" durumunu engelleyen şey bu:
      her şey foreground'da görünür, aynı anda kaydedilir.
    #>
    param(
        [Parameter(Mandatory)] [string] $Message,
        [string] $LogPath,
        [ValidateSet('info','warn','error','stream')] [string] $Level = 'info'
    )

    $stamp = (Get-Date).ToString('HH:mm:ss')
    $prefix = switch ($Level) {
        'warn'   { '[!]' }
        'error'  { '[x]' }
        'stream' { '   ' }
        default  { '[.]' }
    }
    $line = if ($Level -eq 'stream') { $Message } else { "$stamp $prefix $Message" }

    switch ($Level) {
        'error' { Write-Host $line -ForegroundColor Red }
        'warn'  { Write-Host $line -ForegroundColor Yellow }
        default { Write-Host $line }
    }
    if ($LogPath) {
        $dir = Split-Path -Parent $LogPath
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Add-Content -LiteralPath $LogPath -Value $line
    }
}

function Initialize-SddProject {
    <#
      `sdd init`: içinde bulunulan projeye .sdd/ iskeletini kurar,
      config.default.yaml'ı .sdd/config.yaml olarak kopyalar, boş bir
      state.json oluşturur. Var olan dosyaların üstüne YAZMAZ (idempotent).
    #>
    param(
        [string] $ProjectRoot = (Get-Location).Path,
        [string] $TemplatesDir
    )

    if (-not $TemplatesDir) {
        # bin/sdd.ps1 -> ../templates
        $TemplatesDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'templates'
    }

    $paths = Get-SddPaths -ProjectRoot $ProjectRoot
    $created = [System.Collections.Generic.List[string]]::new()
    $skipped = [System.Collections.Generic.List[string]]::new()

    foreach ($d in @($paths.SddDir, $paths.SpecsDir, $paths.LogsDir)) {
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null; $created.Add($d) }
    }

    # config.yaml — varsa dokunma
    if (Test-Path -LiteralPath $paths.Config) {
        $skipped.Add($paths.Config)
    } else {
        Copy-Item -LiteralPath (Join-Path $TemplatesDir 'config.default.yaml') -Destination $paths.Config
        $created.Add($paths.Config)
    }

    # state.json — varsa dokunma
    if (Test-Path -LiteralPath $paths.State) {
        $skipped.Add($paths.State)
    } else {
        $specId = Split-Path -Leaf $ProjectRoot
        $empty = [ordered]@{
            version          = 1
            spec_id          = $specId
            workflow_version = $null
            stages           = [ordered]@{
                spec      = @{ status = 'not_started' }
                plan      = @{ status = 'not_started' }
                tasks     = @{ status = 'not_started' }
                analyze   = @{ status = 'not_started' }
                implement = @{ status = 'not_started' }
            }
            gate_baseline    = [ordered]@{}
            tasks            = @()
        }
        $empty | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $paths.State -Encoding utf8
        $created.Add($paths.State)
    }

    [pscustomobject]@{ Created = $created; Skipped = $skipped; Paths = $paths }
}
