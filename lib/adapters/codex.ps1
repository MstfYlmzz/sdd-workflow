<#
  adapters/codex.ps1 — Codex CLI adapteri.
  Aynı ortak sözleşmeyi konuşur (bkz. adapters/claude.ps1 başlığı).

  Codex'e özgü çeviriler:
    effort -> reasoning effort (low|medium|high) — burada birebir karşılık var
    resume -> Codex'in kendi oturum sürdürme mekanizması (varsa); yoksa
              çıktıda ok=true ama session_id=null döner -> loop baştan çalıştırır
    izin   -> --sandbox <mod> (otonom loop için tam erişim gereken mod)
    çıktı  -> --json (satır satır olay akışı) -> canlı akış + logla
#>

function Invoke-CodexAgent {
    param([hashtable] $Request)
    # TODO:
    #   codex exec "<prompt>" `
    #     --model <model> `
    #     --reasoning-effort <effort> `
    #     --sandbox <mod> `
    #     --json
    #   json olay akışını oku -> canlı akıt + logla,
    #   varsa oturum kimliğini çıkar (yoksa null).
    throw [System.NotImplementedException]::new('Invoke-CodexAgent')
}

function Convert-EffortToCodex {
    <#
      Soyut effort'u Codex reasoning effort'una çevirir. Genelde birebir
      (low/medium/high) ama tek yerde tutulur ki değişirse burada değişsin.
    #>
    param([string] $Effort)
    # TODO: eşleme.
    throw [System.NotImplementedException]::new('Convert-EffortToCodex')
}
