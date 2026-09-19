# SDD Workflow — Kısa Kullanıcı Rehberi

## Sistem ne yapar?

SDD Workflow, Spec Kit akışını Codex, Claude Code ve Cursor Agent arasında
stage bazında yönlendirir. Projenin gereksinimlerini dokümana dönüştürür,
uygulanabilir task listesi üretir, taskları küçük batch'lerle uygular ve her
batch'i deterministik kontrollerden geçirir.

Merkezi `sdd-workflow` reposu motoru içerir. Her uygulama reposu yalnız kendi
`.sdd` ayarlarını, Spec Kit assetlerini, speclerini ve ledger durumunu taşır.

## Bir kez kurulum

```powershell
git clone https://github.com/MstfYlmzz/sdd-workflow C:\Tools\sdd-workflow
cd C:\Tools\sdd-workflow
.\install.ps1
```

Yeni terminal açtıktan sonra komut her klasörden doğrudan kullanılabilir:

```powershell
sdd
```

## Yeni projeye ekleme

```powershell
cd C:\Projects\yeni-proje
sdd init
git add .
git commit -m "chore: initialize SDD workflow"
sdd config
```

`sdd init` idempotenttir. Config, ledger, Spec Kit script/template dosyaları ve
agent skill'lerini kurar; mevcut proje constitution dosyasını ezmez.

## Uçtan uca akış

1. `sdd spec -Prompt "ürün talebi"`: İhtiyaçları `spec.md` içinde açık ve test
   edilebilir gereksinimlere çevirir.
2. `sdd plan`: Teknik yaklaşımı, mimariyi, veri modelini ve sözleşmeleri üretir.
3. `sdd tasks`: Planı bağımlılıkları belli, numaralı tasklara böler ve ledger'a
   yükler.
4. `sdd analyze`: Spec, plan ve tasklar arasındaki çelişkileri read-only inceler.
   Kritik eşik aşılırsa implementasyonu durdurur.
5. `sdd implement`: Hazır taskları batch halinde seçer ve atanmış agent'a verir.
   Her batch sonrasında Tier 0 ile gerçek değişiklik, Tier 1 ile lint/type/build/
   test gate'leri doğrulanır. Başarılı taskların checkbox ve commit kaydını
   orkestratör yapar; hata retry/escalation/circuit-breaker akışına girer.
6. `sdd converge`: Final strict Tier 1 sonrasında upstream Spec Kit converge ile
   implementasyonun artefaktlarla semantik uyumunu denetler. Eksik iş bulursa
   yalnız yeni task ekler ve implement loop yeniden çalışır; kodu kendisi
   değiştirmez.

`sdd implement -ObserveEvery 1 -Ui tui` her batch sonrası gözlem molası verir.
Kesintisiz çalışma için `-ObserveEvery 0` kullanılır.

## TUI ve birden fazla spec

```powershell
sdd tui
```

Dashboard sayfaları: overview, specs, tasks, routing, history ve artifacts.
`Specs` sayfası `specs/*` klasörlerini listeler ve aktif speci işaretler.
Yukarı/aşağı ile bir spec seçilip Enter'a basıldığında o specin taskları
görüntülenir; bu salt-okunur gezinme aktif implement akışını değiştirmez.

Canlı agent görünümü için stage'i `-Ui tui` ile çalıştırın. `Tab` panel seçer;
ok/PageUp/PageDown veya mouse tekerleği seçili paneli kaydırır.

## Agent ve model seçimi

```powershell
sdd config                 # bütün stage'ler
sdd config implement       # yalnız implement
sdd config converge        # yalnız converge
```

Menüler ok tuşlarıyla çalışır. Seçimler projenin `.sdd/config.yaml` dosyasına
yazılır. Tek çalışmalık seçim için `-RunOnly`, komut satırı override'ı için
`-Agent`, `-Model` ve `-Effort` kullanılabilir.

## Güncelleme modeli

Motor/TUI/adapter değişikliklerini bütün projelere ulaştırmak:

```powershell
sdd self-update
```

Merkezi repo güncellendiği için tüm projeler sonraki komutta yeni motoru
kullanır. Skill, script veya template güncellemesini belirli projeye almak:

```powershell
cd C:\Projects\proje
sdd upgrade
```

Proje tarafından değiştirilmiş managed asset varsa komut dosyaları ezmez ve
durur. Değişikliği bilinçli olarak merkezi sürümle değiştirmek için:

```powershell
sdd upgrade -Force
```

Upgrade sonrasında `git diff` incelenmeli ve değişiklikler commit edilmelidir.
`.sdd/config.yaml`, `.sdd/state.json`, specler ve constitution proje verisidir;
merkezi self-update bunları değiştirmez.

## Günlük komutlar

```powershell
sdd status
sdd tui
sdd spec -Prompt "..."
sdd plan
sdd tasks
sdd analyze
sdd implement -Ui tui
sdd converge
sdd self-update
sdd upgrade
```

Implement loop temiz Git çalışma ağacı ister. Başlamadan önce `git status`
çıktısı boş olmalı; config veya upgrade değişiklikleri önce commit edilmelidir.
