<#
  adapters/claude.ps1 — Claude Code CLI adapteri.

  ORTAK SÖZLEŞME (üç adapter de aynı imzayı konuşur):
    girdi:  @{ prompt; model; effort; resume_session; cwd; log_path; allowed_tools }
    çıktı:  @{ ok; session_id; denied; stream }
      ok            : stage/batch başarılı bitti mi (process düzeyinde)
      session_id    : -Resume için; sonraki çağrı --resume ile sürer
      denied        : izin reddedilen işlemler (doluysa 'completed' sayma)
      stream        : canlı akıtılan çıktının log yolu

  Claude'a özgü çeviriler:
    effort -> model seçimi + thinking bütçesi
    resume -> --resume "<session_id>"
    izin   -> --permission-mode acceptEdits, --allowedTools "<liste>"
    çıktı  -> --output-format stream-json (canlı akış + denied yakalama)
#>

function Invoke-ClaudeAgent {
    param([hashtable] $Request)
    # TODO:
    #   claude -p "<prompt>" `
    #     --model <model> `
    #     --permission-mode acceptEdits `
    #     --allowedTools "<Request.allowed_tools>" `
    #     [--resume "<Request.resume_session>"] `
    #     --output-format stream-json
    #   stream-json'ı satır satır oku -> canlı akıt + logla,
    #   final result mesajından session_id ve permission_denials'ı çıkar.
    throw [System.NotImplementedException]::new('Invoke-ClaudeAgent')
}

function Convert-EffortToClaude {
    <#
      Soyut effort'u (low|medium|high) Claude'un model+thinking karşılığına çevirir.
    #>
    param([string] $Effort, [string] $Model)
    # TODO: eşleme tablosu.
    throw [System.NotImplementedException]::new('Convert-EffortToClaude')
}
