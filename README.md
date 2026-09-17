# sdd-workflow

Spec Kit üstüne oturan, agent-agnostik bir spec-driven development orkestratörü.
Amaç: spec/plan/tasks üretildikten sonra implementasyonun **otonom** ilerlemesi;
insanın sadece dört noktada devrede olması.

Bu repo **generic**'tir. Hiçbir dosya belirli bir projeyi bilmez. Projeye dair
her şey, o projenin içindeki tek dosyadadır: `.sdd/config.yaml`.

## İki-repo sınırı

```
sdd-workflow (bu repo)          proje reposu
  = LOGIC                         = CEVAP + ÇIKTI
  bin/, lib/, templates/          .sdd/config.yaml  (senin cevabın)
                                  .sdd/state.json   (üretilir)
                                  .sdd/specs/       (üretilir)
                                  .sdd/logs/        (üretilir)
```

Kural: `.sdd/config.yaml` dışında hiçbir yerde proje ismi, klasör adı ya da
komut adı sabit yazılmaz. Bu disiplin sayesinde deneme sırasında çıkan
sorunların neredeyse tamamı **bu repoda** düzeltilir; proje reposuna dokunmazsın.

Kendine tek soru: *bu her projede mi böyle, yoksa sadece bu projede mi?*
Her projede → burada düzelt. Sadece bu projede → proje `config.yaml`'ı.

## Akış: insan bölgesi vs otonom bölge

```
[SEN ONAYLARSIN]                    [OTONOM — müdahale yok]
  spec  ─▶ plan ─▶ tasks ──▶  analyze ─▶ batch seç ─▶ agent çalıştır
                                                          │
                                              Tier 0 (iş yapıldı mı?)
                                                          │
                                              Tier 1 (proje ayakta mı?)
                                                       │      │
                                                    geçti    kaldı
                                                       │      │(retry, max 3)
                                                  checkbox+commit
                                                          │
                                                final strict Tier 1
                                                          │
[SEN DEVRALIRSIN] ◀── hepsi bitti · blocked · circuit breaker
```

İnsanın dört teması: `spec`, `plan`, `tasks` onayı ve döngü durunca devralma.
Bunun dışında: analyze raporu okunmaz (kritik değilse), checkbox elle
işaretlenmez, build hatasına elle girilmez.

## Doğrulama katmanları

- **Tier 0 — "agent gerçekten iş yaptı mı?"** Projeyi bilmez; git baseline ile
  sonrası fotoğrafını karşılaştırır, eklenen satırlarda basit arama yapar.
  Her projede aynı. (`lib/tier0.ps1`)
- **Tier 1 — "yapılan iş projeyi bozdu mu?"** Projenin kendi komutlarını
  (`config.gates`) çalıştırır, exit code'a bakar. Komut projede yoksa atlar;
  sadece baseline'a eklenen yeni hataları suçlar. Son task'tan sonra ise bütün
  `required` gate'ler strict modda mevcut ve yeşil olmak zorundadır; değilse
  otomatik repair task oluşur. (`lib/tier1.ps1`)
- **verify (Tier 2)** — "doğru şey mi yapıldı?" **Şimdilik yok.** İhtiyaç
  netleşince eklenir.

Checkbox'ı her zaman **orkestratör** yazar, agent değil.

## Komutlar

```
sdd init                 projeye .sdd/ iskeletini kurar
sdd spec   [-Prompt ...]  spec stage'i (-Prompt: düzeltip yeniden çalıştır)
sdd plan   [-Prompt ...]  plan stage'i
sdd tasks  [-Prompt ...]  tasks stage'i
sdd analyze              read-only tutarlılık analizi
sdd implement            otonom implement loop (Tier 0 + Tier 1)
sdd implement -ObserveEvery N   her N başarılı batch'te gözlem molası
sdd implement -RevalidateFrom BASE -CandidateCommit COMMIT
                         başarısız validator sonrası mevcut commit'i agentsız doğrula
sdd status               ledger özeti
sdd config               agent/model/effort seçim arayüzü (hafızalı)
```

`spec`, `plan` ve `tasks` için `-Prompt "<metin>"` aynı stage'i düzeltmeyle
yeniden çalıştırır; `-Resume` varsa sağlayıcı oturumunu sürdürür. Implement loop
idempotenttir: tekrar `sdd implement` çağrısı `done` task'ları atlar ve kaldığı
ledger durumundan devam eder.

Normal `sdd implement` girişi, completed/güncel bir analyze sonucu yoksa
analyze'ı otomatik çalıştırır. Analyze git ile read-only doğrulanır ve
`config.analyze.block_on` eşiğine ulaşan bulgu implementasyonu durdurur.

Validator hatası düzeltilirken agent'ın ürettiği commit zaten doğruysa aynı
işi ve token harcamasını tekrarlamak gerekmez. `-RevalidateFrom`, batch öncesi
commit'i; `-CandidateCommit` ise agent'ın implementation commit'ini alır. Loop
bu zincirin `BASE -> COMMIT -> HEAD` olduğunu doğrular, mevcut pending batch'e
Tier 0 + Tier 1 uygular ve agent çağırmadan checkpoint üretir.

### Implement commit sözleşmesi

- Agent yalnızca seçilen batch'i uygular ve implementation commit'ini üretir.
- Agent `.sdd/**` ve `tasks.md` dosyalarına dokunmaz; hook gerekmez.
- Orkestratör Tier 0 ve Tier 1 geçtikten sonra ledger ile checkbox'ları yazar ve
  ayrı bir checkpoint commit'i üretir.
- Başarısız doğrulamada task `done` olmaz. Ham hata aynı Codex oturumuna verilir,
  attempt artar ve aynı batch repair commit'iyle yeniden denenir.
- `escalate_at` sonrasında model değişmez; seçilmiş model korunur ve reasoning
  effort `high` seviyesine yükselir.
- `max_attempts`, `circuit_breaker`, manual task veya çözülemeyen bağımlılık
  döngüyü insana geri verir.

## Klasör yapısı

```
bin/sdd.ps1              giriş noktası (dispatcher, logic yok)
lib/
  common.ps1             proje kökü bulma, config okuma, loglama, init
  ledger.ps1             state.json okuma/yazma, tasks.md render, stale, uzlaştırma
  stages.ps1             stage runner + agent seçim arayüzü + analyze
  tier0.ps1              "iş yapıldı mı" — 9 git/dosya kontrolü
  tier1.ps1              "proje ayakta mı" — gate çalıştırıcı
  loop.ps1               otonom döngü: batch, retry, escalation, circuit breaker
  adapters/
    claude.ps1           Claude Code CLI
    codex.ps1            Codex CLI
    cursor.ps1           Cursor CLI
templates/
  config.default.yaml    projeye kopyalanan config şablonu
  state.schema.json      ledger JSON şeması
```

Üç adapter de **aynı sözleşmeyi** konuşur:
girdi `{prompt, model, effort, resume_session, cwd, log_path, allowed_tools}`,
çıktı `{ok, session_id, denied, stream}`. effort her sağlayıcıda farklı şeye
çevrilir ama arayüz aynıdır.

### Sağlayıcılar

- **Codex:** `codex exec --json`; model ve reasoning effort doğrudan aktarılır,
  retry aynı thread'i `exec resume` ile sürdürür.
- **Claude Code:** `claude -p --output-format stream-json`; `--model`,
  `--effort`, `--resume` ve `bypassPermissions` kullanılır.
- **Cursor Agent:** `agent -p --output-format stream-json`; `--model`,
  `--resume`, `--force`, `--sandbox disabled`, `--trust` ve `--workspace`
  kullanılır. Cursor CLI ayrı effort bayrağı sunmadığından model adı korunur;
  effort yalnızca ledger metadata'sı olarak kalır.

Varsayılan yeni-proje routing'i:

```
spec/plan   -> Codex / gpt-5.6-sol
tasks       -> Cursor / auto
analyze     -> Claude / sonnet
implement   -> Codex / gpt-5.6-sol
```

İlgili CLI'ların kurulu ve oturumlarının açık olması gerekir. İstenirse bütün
stage'ler `.sdd/config.yaml` üzerinden tek sağlayıcıya alınabilir.

## Testler

Token harcamayan, mock CLI tabanlı tam takım:

```powershell
pwsh -NoProfile -File .\tests\run-all.ps1
```

Gerçek Codex `resume` yolunu iki küçük çağrıyla doğrulayan opt-in test:

```powershell
$env:SDD_RUN_LIVE_CODEX = "1"
pwsh -NoProfile -File .\tests\live-codex-retry.ps1
Remove-Item Env:SDD_RUN_LIVE_CODEX
```

GitHub Actions aynı mock takımı hem `windows-latest` hem `ubuntu-latest`
üzerinde çalıştırır. Live test CI'da bilinçli olarak kapalıdır.

## İnşa durumu

Çalışan parçalar: `init`, `status`, `sync-tasks`, `spec`, `plan`, `tasks`,
read-only `analyze`, Codex/Claude/Cursor adapterleri, Tier 0, probation + final
strict Tier 1, retry/resume, revalidation ve implement loop. Windows/Linux CI
ve uçtan uca fixture testleri `tests/` altındadır.

Henüz taslak olan parça interaktif `config` seçimidir; routing YAML üzerinden
tam çalışır. Tier 2 semantik doğrulama bu sürümün kapsamı dışındadır.
