<#
  tier0.ps1 — "Agent gerçekten bir iş yaptı mı?"
  Projenin ne olduğunu BİLMEZ. Sadece git baseline ile sonrası fotoğrafını
  karşılaştırır ve eklenen satırlarda basit metin araması yapar.
  Her projede aynı kod çalışır; bakım gerektirmez.

  Sözleşme: Invoke-Tier0 bir sonuç nesnesi döndürür:
    { ok: bool, hard_fails: string[], warnings: string[] }
  hard_fails doluysa batch başarısız; warnings retry promptuna eklenir ama
  tek başına batch'i düşürmez.
#>

function Get-GitBaseline {
    <#
      Agent çalışmadan ÖNCE HEAD'i döndürür. "Önce" fotoğrafı budur.
      Loop her batch'te bunu alır, batch sonrası buna karşı diff'ler.
    #>
    param([string] $ProjectRoot)
    # TODO: git rev-parse HEAD
    throw [System.NotImplementedException]::new('Get-GitBaseline')
}

function Invoke-Tier0 {
    <#
      Tüm Tier 0 kontrollerini sırayla çalıştırır ve sonucu toplar.
      Kontroller (dokümandaki 9 kontrol):
        1. Diff var mı?            git diff --stat baseline..HEAD + status boşsa HARD FAIL
        2. Doğru dosyalar mı?      task.files ile değişen dosyalar; uyuşmazlık WARNING
        3. Dosyalar dolu mu?       yeni dosyada <3 anlamlı satır -> HARD FAIL
        4. Placeholder var mı?     EKLENEN satırlarda TODO/FIXME/not implemented -> HARD FAIL
        5. Bastırma var mı?        EKLENEN satırlarda @ts-ignore/eslint-disable/.skip/xit -> HARD FAIL
        6. Test sayısı düştü mü?   test dosyalarındaki test sayısı azaldıysa -> HARD FAIL
        7. Yan hasar var mı?       silinen test / node_modules / .env / lockfile -> HARD FAIL (bazıları WARNING)
        8. tasks.md'ye dokunuldu mu? dokunulduysa -> HARD FAIL (geri al)
        9. Commit + temiz tree?    baseline'dan sonra >=1 commit ve status boş
      Kritik incelik: 4, 5, 6 SADECE EKLENEN satırlara bakar (git diff'in +
      satırları), tüm dosyaya değil. Yoksa eski TODO'lar yanlış alarm verir.
    #>
    param(
        [string] $ProjectRoot,
        [string] $Baseline,
        [object] $Task
    )
    # TODO: aşağıdaki yardımcıları çağırıp sonucu birleştir.
    throw [System.NotImplementedException]::new('Invoke-Tier0')
}

function Get-AddedLines {
    <#
      baseline..HEAD arası diff'ten SADECE eklenen ('+') satırları döndürür.
      Kontrol 4/5/6'nın hepsi bunu kullanır — ortak zemin.
    #>
    param([string] $ProjectRoot, [string] $Baseline)
    # TODO: git diff --unified=0; '+' ile başlayan (ama '+++' olmayan) satırları topla.
    throw [System.NotImplementedException]::new('Get-AddedLines')
}

function Test-DiffExists      { param($ProjectRoot,$Baseline) throw [System.NotImplementedException]::new('Test-DiffExists') }      # kontrol 1
function Test-FilesTouched    { param($ProjectRoot,$Baseline,$Task) throw [System.NotImplementedException]::new('Test-FilesTouched') } # kontrol 2 (warning)
function Test-FilesSubstantial{ param($ProjectRoot,$Baseline) throw [System.NotImplementedException]::new('Test-FilesSubstantial') } # kontrol 3
function Test-NoPlaceholders  { param($AddedLines) throw [System.NotImplementedException]::new('Test-NoPlaceholders') }             # kontrol 4
function Test-NoSuppressions  { param($AddedLines) throw [System.NotImplementedException]::new('Test-NoSuppressions') }             # kontrol 5
function Test-TestCountKept   { param($ProjectRoot,$Baseline) throw [System.NotImplementedException]::new('Test-TestCountKept') }   # kontrol 6
function Test-NoCollateral    { param($ProjectRoot,$Baseline) throw [System.NotImplementedException]::new('Test-NoCollateral') }    # kontrol 7
function Test-TasksMdUntouched{ param($ProjectRoot,$Baseline) throw [System.NotImplementedException]::new('Test-TasksMdUntouched') }# kontrol 8
function Test-CommittedClean  { param($ProjectRoot,$Baseline) throw [System.NotImplementedException]::new('Test-CommittedClean') }  # kontrol 9
