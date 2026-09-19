# sdd-workflow

Spec Kit üstüne oturan, agent-agnostik bir spec-driven development orkestratörü.
Amaç: spec/plan/tasks üretildikten sonra implementasyonun **otonom** ilerlemesi;
insanın sadece dört noktada devrede olması.

Bu repo **generic**'tir. Hiçbir motor dosyası belirli bir projeyi bilmez.
Projeye özel routing, gate ve loop ayarları o projenin `.sdd/config.yaml`
dosyasındadır; spec ve çalışma durumu proje reposunda tutulur.

## Hızlı kurulum

Motoru bilgisayara bir kez clone edip global `sdd` komutunu kurun:

```powershell
git clone https://github.com/MstfYlmzz/sdd-workflow C:\Tools\sdd-workflow
cd C:\Tools\sdd-workflow
.\install.ps1
```

Yeni terminalde herhangi bir proje için:

```powershell
cd C:\Projects\yeni-proje
sdd init
sdd config
```

Motor güncellemeleri `sdd self-update` ile bütün projelere anında ulaşır.
Skill/template güncellemeleri proje içinde `sdd upgrade` ile alınır. Ayrıntılı
kurulum ve uçtan uca çalışma mantığı: [Kısa Kullanıcı Rehberi](docs/KULLANIM.md).

## İki-repo sınırı

```
sdd-workflow (bu repo)          proje reposu
  = LOGIC                         = CEVAP + ÇIKTI
  bin/, lib/, templates/          .sdd/config.yaml  (senin cevabın)
                                  .sdd/state.json   (üretilir)
                                  .agents/, .specify/ (managed asset)
                                  specs/            (spec/plan/tasks)
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
                                                          ▼
                                                Spec Kit converge
                                                   │           │
                                               hizalı       yeni task
                                                   │           └──▶ loop
[SEN DEVRALIRSIN] ◀── tamamlandı · blocked · circuit breaker
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
- **Spec Kit converge — "artefaktlarla implementasyon hâlâ hizalı mı?"**
  Semantik kararı upstream `speckit-converge` skill'i verir. Orkestratör bunu
  deterministik bir Tier 2 gibi yorumlamaz; yalnız write boundary, append-only
  `tasks.md`, benzersiz task ID ve tur sınırını doğrular. Eksik varsa yeni bir
  `Convergence` fazı eklenir ve implement loop devam eder.

Checkbox'ı her zaman **orkestratör** yazar, agent değil.

## Komutlar

```
sdd init                 projeye .sdd/ iskeletini kurar
sdd upgrade [-Force]     proje skill/script/template assetlerini günceller
sdd self-update          merkezi sdd-workflow reposunu fast-forward günceller
sdd spec   [-Prompt ...]  spec stage'i (-Prompt: düzeltip yeniden çalıştır)
sdd plan   [-Prompt ...]  plan stage'i
sdd tasks  [-Prompt ...]  tasks stage'i
sdd analyze              read-only tutarlılık analizi
sdd implement            otonom implement loop (Tier 0 + Tier 1 + converge)
sdd converge             upstream Spec Kit converge'ü tek başına çalıştırır
sdd implement -ObserveEvery N   her N başarılı batch'te gözlem molası
sdd implement -RevalidateFrom BASE -CandidateCommit COMMIT
                         başarısız validator sonrası mevcut commit'i agentsız doğrula
sdd status               ledger özeti
sdd config               bütün stage'leri sırayla, ok tuşlarıyla ayarlar
sdd config implement     yalnız implement routing'ini değiştirir
sdd config plan -RunOnly seçim yapar fakat config'e yazmaz
sdd tui                  specs/tasks/stages/routing/history/artifacts dashboard'u
```

Tüm çalışan komutlarda geçici routing override kullanılabilir:
`-Agent claude -Model sonnet -Effort high`. `-Select` interaktif seçiciyi açar;
`-Ui plain|tui|raw|auto` çıktı renderer'ını belirler. `tui`, AI mesajlarını,
araç/terminal olaylarını ve workflow/gate durumunu ayrı panellerde gösterir.
Plain mod ham komut çıktısını ana akışa dökmez; tam kayıt `.sdd/logs/` altında
kalır. Yapılandırılmış ve redakte edilmiş çalışma geçmişi `.sdd/runs.jsonl`
dosyasına yazılır; iki yol da `sdd init` tarafından Git dışında tutulur.

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
  converge.ps1           upstream converge + append/write-boundary doğrulaması
  events.ps1             normalize olaylar, redakte telemetry, renderer bus
  tui.ps1                live panel ve dashboard
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
converge    -> Codex / gpt-5.6-sol / high
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

Çalışan parçalar: stage runner'lar, hafızalı veya run-only agent seçimi,
Codex/Claude/Cursor event normalizasyonu, live TUI/dashboard, redakte telemetry,
Tier 0, probation + final strict Tier 1, retry/resume, revalidation, implement
loop ve upstream Spec Kit converge geri-besleme döngüsü. Windows/Linux mock
testleri gerçek sağlayıcı tokenı harcamadan `tests/` altında çalışır.

Gerçek CLI kabul testi bilinçli olarak kullanıcı ortamına bırakılır: ilgili üç
sağlayıcının kurulu ve oturumunun açık olması, model adlarının hesapta mevcut
olması gerekir. `sdd config` menüsü kurulum durumunu gösterir; Cursor mevcutsa
`agent --list-models` sonucunu da model önerilerine ekler.


---

## SpectaTUI experimental workflow

The current PowerShell CLI/TUI remains the supported fallback:

~~~text
sdd ...
sdd tui
~~~

The experimental path keeps the same SDD domain engine but lets the Spec Kit
workflow engine own pipeline run/resume/status and lets SpectaTUI launch it.

### Setup

Use Spec Kit 1.0.6 or later, then update managed project assets:

~~~powershell
sdd upgrade
~~~

This installs:

- .specify/workflows/sdd-native/workflow.yml
- .specify/workflows/steps/sdd-process/
- the sdd-native workflow registry entry

The project must already have an active feature with committed spec.md, plan.md
and tasks.md and a clean worktree.

### Run from SpectaTUI

Open **Automation Workflows**, select **SDD Native Closure**, then:

- r — run
- R — resume last run
- s — workflow status/history

Phase A runs:

~~~text
tasks-ready
→ analyze
→ autonomous-closure
    → existing implement loop
    → Tier 0 / Tier 1
    → final strict Tier 1
    → existing LLM-based Converge
    → convergence tasks? implement again
    → clean convergence
~~~

Agent/model/effort are **not** stored in the workflow YAML. They continue to
come from .sdd/config.yaml, so Codex/Claude/Cursor routing stays identical to the
legacy path.

### State ownership

- .specify/workflows/runs/<run-id>/... = pipeline execution position and
  run/resume/status state.
- .sdd/state.json = authoritative SDD domain state: tasks, attempts, sessions,
  validation, routing metadata and convergence.

Spec Kit run state is machine-local and Git-ignored; it is never a second task
ledger.

### Live output

A small project-local Spec Kit step named sdd-process is used because the stock
Spec Kit shell step buffers child output. sdd-process forwards the existing SDD
raw event stream live to the parent Specify process; SpectaTUI already streams
that process into its CLI output popup.

Phase A does not require a SpectaTUI fork for workflow execution. Phase B adds
a pinned source overlay for richer observability without replacing the stock
binary. Phase C keeps `sdd-native` as the same background CLI job but returns
directly to the Overview dashboard, where a dedicated **SDD Runtime** pane shows
parsed orchestration events while the normal Agent Output pane remains reserved
for the selected coding-agent tmux session.

Install the experimental UI side-by-side:

~~~powershell
sdd spectatui install
spectatui-sdd -p .
~~~

This build requires Git plus a Rust/Cargo stable toolchain. It is pinned to
SpectaTUI 1.1.0 commit `c039831190588c336abf4adba8a0d7c91c148774`, runs its
projection unit test and compile check, then installs as `spectatui-sdd`.

The SDD engine writes Git-ignored, read-only projections at
`.specify/sdd-status.json` and `.specify/sdd-events.json`. Patched SpectaTUI
uses them to show:

- explicit `conv` / Converge state
- active batch and task IDs
- retry attempt / max attempts
- agent / model / effort
- convergence round / max rounds
- task done/pending/blocked counts
- a capped, parsed runtime event feed without raw command-output spam

The projections are marked non-authoritative and are never used by the SDD engine
for control decisions. `.sdd/state.json` remains the domain source of truth.

### Resume and convergence

Spec Kit resumes only the top-level pipeline step. Exact task/session retry
semantics remain inside .sdd/state.json and the existing implement loop.
Observation pause maps to a native workflow PAUSED result. Converge remains the
normal LLM-based speckit-converge skill with the existing deterministic
append-only/write-boundary checks.

For the full semantics matrix, architecture decision, test coverage, and known
limitations see docs/SPECTATUI_NATIVE_WORKFLOW.md.

The old PowerShell TUI must not be removed until the patched UI has passed the
interactive Windows-terminal smoke/performance measurements.
