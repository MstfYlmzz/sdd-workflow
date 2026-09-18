<#
  adapters/codex.ps1 — Codex CLI adapteri (codex-cli 0.153.x).
  Aynı ortak sözleşmeyi konuşur:
    girdi:  @{ prompt; model; effort; resume_session; cwd; log_path; output_schema }
    çıktı:  @{ ok; session_id; denied; last_message; log_path }

  Codex'e özgü gerçek bayraklar (0.153.4 `codex exec --help` çıktısından):
    -m <model>                          model seçimi
    -c model_reasoning_effort="<e>"     effort (ayrı bayrak yok, config override)
    -s danger-full-access               sandbox: tam erişim (otonom loop için)
    -C <dir>                            çalışma kökü
    --json                              stdout'a JSONL olay akışı
    -o <file>                           agent'ın son mesajını dosyaya yaz
    --output-schema <file>              (opsiyonel) yapılandırılmış çıktı şeması
    codex exec resume <thread_id> ...   önceki oturumu sürdür

  JSONL olay tipleri (gözlemlenen):
    {"type":"thread.started","thread_id":"..."}          -> session_id
    {"type":"turn.started"}
    {"type":"item.completed","item":{"type":"agent_message","text":"..."}}
    {"type":"turn.completed","usage":{...}}
    (hata/red durumları da event olarak gelir -> denied'a toplanır)
#>

Set-StrictMode -Version Latest

function Invoke-CodexAgent {
    param([Parameter(Mandatory)] [hashtable] $Request)

    $codexArgs = [System.Collections.Generic.List[string]]::new()
    $codexArgs.Add('exec')

    # exec seçenekleri subcommand'den ÖNCE gelmeli. Özellikle -s/-C/-c,
    # `codex exec resume` sonrasında geçerli ResumeArgs değildir.
    if ($Request.ContainsKey('model') -and $Request.model) {
        $codexArgs.Add('-m'); $codexArgs.Add([string]$Request.model)
    }
    if ($Request.ContainsKey('effort') -and $Request.effort) {
        $codexArgs.Add('-c'); $codexArgs.Add("model_reasoning_effort=`"$($Request.effort)`"")
    }

    # Otonom loop: tam erişim, onay yok
    $codexArgs.Add('-s'); $codexArgs.Add('danger-full-access')

    if ($Request.ContainsKey('cwd') -and $Request.cwd) {
        $codexArgs.Add('-C'); $codexArgs.Add([string]$Request.cwd)
    }
    if ($Request.ContainsKey('output_schema') -and $Request.output_schema) {
        $codexArgs.Add('--output-schema'); $codexArgs.Add([string]$Request.output_schema)
    }

    # Son mesajı ayrı dosyaya da yazdır (ayrıştırmaya güvenmeden)
    $lastMsgFile = [System.IO.Path]::GetTempFileName()
    $codexArgs.Add('-o'); $codexArgs.Add($lastMsgFile)

    $codexArgs.Add('--json')

    # Resume subcommand'i tüm exec seçeneklerinden sonra gelir.
    if ($Request.ContainsKey('resume_session') -and $Request.resume_session) {
        $codexArgs.Add('resume')
        $codexArgs.Add([string]$Request.resume_session)
    }

    # Prompt en sona; resume'da SESSION_ID'den sonraki positional prompt'tur.
    if ($Request.ContainsKey('prompt') -and $Request.prompt) {
        $codexArgs.Add([string]$Request.prompt)
    }

    $result = [ordered]@{
        ok           = $false
        session_id   = $null
        denied       = [System.Collections.Generic.List[string]]::new()
        last_message = $null
        log_path     = $Request.log_path
        usage        = $null
    }
    $script:__sawTurn = $false
    $cliExitCode = 0
    $messageParts = [System.Collections.Generic.List[string]]::new()

    # codex'i çalıştır, JSONL'i satır satır CANLI işle (pipeline streaming)
    & codex @codexArgs 2>&1 | ForEach-Object {
        $line = [string]$_
        Read-CodexEvent -Line $line -Result $result -MessageParts $messageParts `
                        -OnTurnCompleted { $script:__sawTurn = $true } -LogPath $Request.log_path
    }
    $cliExitCode = $LASTEXITCODE

    if ($cliExitCode -ne 0) {
        $result.denied.Add("Codex CLI exit code: $cliExitCode")
    }

    # son mesajı dosyadan al (varsa), yoksa toplanan parçalardan
    if (Test-Path -LiteralPath $lastMsgFile) {
        $fileMsg = (Get-Content -LiteralPath $lastMsgFile -Raw -ErrorAction SilentlyContinue)
        if ($fileMsg) { $result.last_message = $fileMsg.TrimEnd() }
        Remove-Item -LiteralPath $lastMsgFile -ErrorAction SilentlyContinue
    }
    if (-not $result.last_message -and $messageParts.Count -gt 0) {
        $result.last_message = ($messageParts -join "`n")
    }

    $result.ok = [bool]$script:__sawTurn -and ($result.denied.Count -eq 0)
    $result.denied = @($result.denied)
    Remove-Variable -Scope script -Name __sawTurn -ErrorAction SilentlyContinue
    return [pscustomobject]$result
}

function Read-CodexEvent {
    <#
      Tek bir JSONL satırını ayrıştırır: session_id yakalar, agent_message
      metnini toplar + canlı akıtır, turn.completed işaretler, hata/red
      olaylarını denied'a ekler. JSON olmayan satırlar ham akıtılır.
    #>
    param(
        [string] $Line,
        [System.Collections.IDictionary] $Result,
        [System.Collections.Generic.List[string]] $MessageParts,
        [scriptblock] $OnTurnCompleted,
        [string] $LogPath
    )
    if ([string]::IsNullOrWhiteSpace($Line)) { return }

    $evt = $null
    try { $evt = $Line | ConvertFrom-Json -ErrorAction Stop } catch { }

    if ($null -eq $evt) {
        # JSON değil (ör. stderr uyarısı) — ham akıt + logla
        Send-SddEvent -Message $Line -LogPath $LogPath -Level 'stream' -Category 'command_output' -EventType 'provider_raw' -Source 'provider' -Provider 'codex'
        return
    }

    switch ($evt.type) {
        'thread.started' {
            if ($evt.PSObject.Properties.Name -contains 'thread_id') {
                $Result.session_id = $evt.thread_id
                Send-SddEvent -Message 'Codex session başladı' -LogPath $LogPath -Category 'workflow' -EventType 'session_started' -Source 'provider' -Provider 'codex' -Metadata @{resume_available=$true}
            }
        }
        'turn.started' { }
        'item.started' {
            if ($evt.item -and $evt.item.type -eq 'command_execution') {
                $cmd = if ($evt.item.PSObject.Properties.Name -contains 'command') { [string]$evt.item.command } else { '' }
                if ($cmd) { Send-SddEvent -Command $cmd -LogPath $LogPath -Category 'command' -EventType 'command_started' -Source 'provider' -Provider 'codex' -Status 'running' }
            } elseif ($evt.item -and $evt.item.type -in @('mcp_tool_call','web_search')) {
                Send-SddEvent -Message ([string]$evt.item.type) -LogPath $LogPath -Category 'tool' -EventType ([string]$evt.item.type) -Source 'provider' -Provider 'codex' -Status 'running'
            }
        }
        'item.completed' {
            if ($evt.item -and $evt.item.type -eq 'agent_message' -and $evt.item.PSObject.Properties.Name -contains 'text') {
                $MessageParts.Add([string]$evt.item.text)
                Send-SddEvent -Message $evt.item.text -LogPath $LogPath -Level 'stream' -Category 'assistant' -EventType 'agent_message' -Source 'provider' -Provider 'codex'
            }
            elseif ($evt.item -and $evt.item.type -eq 'command_execution') {
                # çalıştırılan komutları da akıt (görünürlük için)
                $cmd = if ($evt.item.PSObject.Properties.Name -contains 'command') { $evt.item.command } else { '' }
                if ($cmd) { Send-SddEvent -Command $cmd -LogPath $LogPath -Category 'command' -EventType 'command_completed' -Source 'provider' -Provider 'codex' -Status ([string]$evt.item.status) }
            }
            elseif ($evt.item -and $evt.item.type -eq 'reasoning') {
                $summary = if ($evt.item.PSObject.Properties.Name -contains 'text') { [string]$evt.item.text } elseif ($evt.item.PSObject.Properties.Name -contains 'summary') { [string]$evt.item.summary } else { 'Reasoning adımı tamamlandı' }
                Send-SddEvent -Message $summary -LogPath $LogPath -Category 'reasoning_summary' -EventType 'reasoning' -Source 'provider' -Provider 'codex'
            }
            elseif ($evt.item -and $evt.item.type -in @('file_change','mcp_tool_call','web_search','plan_update')) {
                Send-SddEvent -Message ([string]$evt.item.type) -LogPath $LogPath -Category 'tool' -EventType ([string]$evt.item.type) -Source 'provider' -Provider 'codex' -Status ([string]$evt.item.status)
            }
        }
        'turn.completed' {
            if ($evt.PSObject.Properties.Name -contains 'usage') {
                $Result.usage = $evt.usage
                Send-SddEvent -Message 'Codex usage alındı' -LogPath $LogPath -Category 'usage' -EventType 'usage' -Source 'provider' -Provider 'codex' -Usage $evt.usage
            }
            if ($OnTurnCompleted) { & $OnTurnCompleted }
        }
        'error' {
            $msg = if ($evt.PSObject.Properties.Name -contains 'message') { $evt.message } else { 'bilinmeyen hata' }
            $Result.denied.Add([string]$msg)
            Send-SddEvent -Message $msg -LogPath $LogPath -Level 'error' -Category 'error' -EventType 'provider_error' -Source 'provider' -Provider 'codex'
        }
        default {
            # tanınmayan olay tipleri: sessizce logla (akıtma)
            if ($LogPath) { Send-SddEvent -Message $Line -LogPath $LogPath -Level 'stream' -Category 'tool' -EventType ([string]$evt.type) -Source 'provider' -Provider 'codex' }
        }
    }
}

function Convert-EffortToCodex {
    <#
      Soyut effort'u Codex model_reasoning_effort'una çevirir.
      Codex low|medium|high bekliyor; birebir geçiyoruz ama geçersiz değeri
      medium'a sabitliyoruz.
    #>
    param([string] $Effort)
    switch ($Effort) {
        'low'    { 'low' }
        'medium' { 'medium' }
        'high'   { 'high' }
        default  { 'medium' }
    }
}
