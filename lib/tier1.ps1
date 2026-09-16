<#
  tier1.ps1 — "Yapılan iş projeyi bozdu mu?"
  Projenin KENDİ komutlarını (config.gates) çalıştırır, exit code'a bakar.
  Komutların sahibi değil, çağırıcısıdır. İki kural:
    - Komut projede TANIMLI DEĞİLSE sessizce ATLA (sıfır proje / erken batch).
    - Sadece baseline'a EKLENEN yeni hataları suçla; zaten kırık olanı değil.
  Sıra ucuzdan pahalıya; ilk hatada dur.

  Sözleşme: Invoke-Tier1 döndürür:
    { ok: bool, failed_gate: string|null, output: string|null }
  output ham hata metnidir; retry promptuna OLDUĞU GİBİ girer (özetlenmez).
#>

function Measure-GateBaseline {
    <#
      Loop başlamadan bir kez çalışır. Her gate için:
        - komut tanımlı mı (available)
        - tanımlıysa şu an geçiyor mu (passing)
      Sonucu ledger.gate_baseline'a yazar. Sıfır projede hepsi
      available=false çıkar; script'ler geldikçe yeniden ölçülüp zenginleşir.
    #>
    param([object] $Config, [string] $ProjectRoot)
    # TODO: her gate için Test-GateAvailable + (varsa) çalıştır, geçiş durumunu kaydet.
    throw [System.NotImplementedException]::new('Measure-GateBaseline')
}

function Test-GateAvailable {
    <#
      Bir gate komutunun bu projede çalıştırılabilir olup olmadığını söyler.
      Örn: 'npm run lint' için package.json'da 'lint' script'i var mı.
      Yoksa gate atlanır (hata değil). Bu, yumurta-tavuk sorununu çözer:
      T001 script'leri kurana kadar o gate'ler yok sayılır.
    #>
    param([object] $Gate, [string] $ProjectRoot)
    # TODO: komuta göre varlık kontrolü (npm script / dosya / çalıştırılabilir).
    throw [System.NotImplementedException]::new('Test-GateAvailable')
}

function Invoke-Tier1 {
    <#
      Config'deki gate'leri sırayla çalıştırır:
        - available değilse: atla
        - baseline'da zaten passing=false ise: bu gate'i suçlama (yeni değil)
        - çalıştır; exit code != 0 ve baseline'da geçiyorduysa: HARD FAIL,
          ham çıktıyı döndür, KALAN gate'leri çalıştırma (ilk hatada dur)
        - hepsi geçerse: ok
    #>
    param([object] $Config, [string] $ProjectRoot, [object] $Ledger)
    # TODO: yukarıdaki akış.
    throw [System.NotImplementedException]::new('Invoke-Tier1')
}

function Invoke-GateCommand {
    <#
      Tek bir gate komutunu çalıştırır, stdout+stderr'i canlı akıtır ve
      log'a yazar, exit code'u döndürür. "Arkada sessiz çalışma yok" kuralı
      burada da geçerli: gate çıktısı da görünür.
    #>
    param([object] $Gate, [string] $ProjectRoot, [string] $LogPath)
    # TODO: komutu çalıştır, Tee benzeri akıt, exit code döndür.
    throw [System.NotImplementedException]::new('Invoke-GateCommand')
}
