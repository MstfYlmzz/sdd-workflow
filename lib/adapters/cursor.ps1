<#
  adapters/cursor.ps1 — Cursor CLI adapteri.
  Aynı ortak sözleşmeyi konuşur (bkz. adapters/claude.ps1 başlığı).

  Cursor'a özgü çeviriler:
    effort -> Cursor'un kendi karşılığı (model/mod seçimi)
    resume -> destekliyorsa oturum kimliği; değilse null -> loop baştan çalıştırır
    izin   -> otomatik onay modu (otonom loop için)
    çıktı  -> Cursor'un olay/stream formatı -> canlı akış + logla

  NOT: Cursor'ı ağırlıklı hangi stage'de kullanacağın (implement mi, düşünme
  ağırlıklı stage'ler mi) config'de belirlenir; adapter stage'e bakmaz,
  sadece verilen isteği çalıştırır.
#>

function Invoke-CursorAgent {
    param([hashtable] $Request)
    # TODO:
    #   cursor <alt-komut> "<prompt>" --model <model> [effort/onay bayrakları]
    #   çıktı akışını oku -> canlı akıt + logla, varsa oturum kimliğini çıkar.
    throw [System.NotImplementedException]::new('Invoke-CursorAgent')
}

function Convert-EffortToCursor {
    param([string] $Effort, [string] $Model)
    # TODO: eşleme.
    throw [System.NotImplementedException]::new('Convert-EffortToCursor')
}
