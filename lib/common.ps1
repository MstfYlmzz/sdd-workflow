<#
  common.ps1 — proje-agnostik yardımcılar.
  Kural: buradaki hiçbir fonksiyon proje ismi/klasörü/komutu SABİT yazmaz.
  İhtiyaç duyulan her projeye özel değer config'den okunur.
#>

function Find-ProjectRoot {
    <#
      İçinde bulunulan klasörden yukarı doğru .sdd/ arar, bulunca döner.
      Bulamazsa hata verir ("sdd init çalıştır" der).
    #>
    param([string] $StartPath = (Get-Location).Path)
    # TODO: yukarı doğru .sdd/ ara; bulunca ana klasörü döndür.
    throw [System.NotImplementedException]::new('Find-ProjectRoot')
}

function Get-SddPaths {
    <#
      Projedeki .sdd/ altındaki standart yolları tek nesnede döndürür:
      Config, State, SpecsDir, LogsDir. Her yerde bu kullanılır ki yollar
      tek yerden yönetilsin.
    #>
    param([string] $ProjectRoot)
    # TODO: .sdd/config.yaml, .sdd/state.json, .sdd/specs, .sdd/logs yollarını üret.
    throw [System.NotImplementedException]::new('Get-SddPaths')
}

function Read-SddConfig {
    <#
      config.yaml'ı okur ve nesne olarak döndürür. YAML ayrıştırma için
      powershell-yaml modülü ya da basit bir ayrıştırıcı kullanılır.
    #>
    param([string] $ConfigPath)
    # TODO: YAML oku -> hashtable/pscustomobject
    throw [System.NotImplementedException]::new('Read-SddConfig')
}

function Write-SddLog {
    <#
      Bir satırı hem terminale (canlı akış) hem .sdd/logs/ altındaki dosyaya
      yazar. "Terminal boş ama arkada çalışıyor" durumunu engelleyen şey bu:
      her şey foreground'da görünür, aynı anda kaydedilir.
    #>
    param(
        [string] $Message,
        [string] $LogPath,
        [ValidateSet('info','warn','error','stream')] [string] $Level = 'info'
    )
    # TODO: zaman damgalı satırı Tee benzeri hem konsola hem dosyaya yaz.
    throw [System.NotImplementedException]::new('Write-SddLog')
}

function Initialize-SddProject {
    <#
      `sdd init`: içinde bulunulan projeye .sdd/ iskeletini kurar,
      config.default.yaml'ı .sdd/config.yaml olarak kopyalar, boş bir
      state.json oluşturur. Var olan dosyaların üstüne YAZMAZ.
    #>
    param([string] $ProjectRoot = (Get-Location).Path)
    # TODO: templates/config.default.yaml -> .sdd/config.yaml
    #       boş ledger -> .sdd/state.json  (state.schema.json'a uygun)
    #       .sdd/specs, .sdd/logs klasörleri
    throw [System.NotImplementedException]::new('Initialize-SddProject')
}
