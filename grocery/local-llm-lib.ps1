<#
  local-llm-lib.ps1 — PowerShell client for the local inference endpoint.

  Follows the conventions of the other grocery/*-lib.ps1 files: dot-source it,
  call the functions, no side effects at load.

      . "$PSScriptRoot\local-llm-lib.ps1"
      if (Test-LocalLLM) { $r = Invoke-LocalLLM -System $s -User $u -Schema $schema }

  TWO NON-OBVIOUS RULES, both established by Phase 0 measurement on this box:

  1. ALWAYS send enable_thinking=false for structured work. Qwen3.8 is a
     reasoning model; left alone it spends the whole token budget in a
     reasoning block and returns EMPTY content. This lib defaults it off.

  2. Prefer -Schema. llama.cpp grammar-constrains output to a JSON Schema, which
     is what makes "valid JSON" a guarantee rather than a hope.

  The pipeline must degrade gracefully when the endpoint is down: Test-LocalLLM
  is cheap, and every caller in the daily chain is expected to fall back to the
  legacy deterministic path rather than fail the run. The board must publish
  even with no local model available.
#>

$script:TcLlmEndpoint = if ($env:TC_LLM_ENDPOINT) { $env:TC_LLM_ENDPOINT } else { 'http://127.0.0.1:8080/v1' }
$script:TcLlmModel    = if ($env:TC_LLM_MODEL)    { $env:TC_LLM_MODEL }    else { 'local-primary' }

function Get-LocalLLMEndpoint { $script:TcLlmEndpoint }

function Test-LocalLLM {
    <#  .SYNOPSIS Is the local endpoint up and loaded? Cheap; safe to call per-step. #>
    [CmdletBinding()] param([int]$TimeoutSec = 5)
    $base = $script:TcLlmEndpoint -replace '/v1/?$', ''
    try {
        $h = Invoke-RestMethod -Uri "$base/health" -TimeoutSec $TimeoutSec -ErrorAction Stop
        return ($h.status -eq 'ok')
    } catch { return $false }
}

function Invoke-LocalLLM {
    <#
      .SYNOPSIS  One structured call to the local model.
      .OUTPUTS   PSCustomObject: Content, Parsed, Model, PromptTokens,
                 CompletionTokens, ElapsedSec, TokensPerSec, OutputHash, Ok, Error
      .NOTES     Never throws on a model/transport failure — returns Ok=$false so
                 the daily pipeline can fall back instead of dying.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$System,
        [Parameter(Mandatory)][string]$User,
        [hashtable]$Schema,
        [int]$MaxTokens = 2048,
        [double]$Temperature = 0.1,
        [switch]$Think,
        [int]$TimeoutSec = 600,
        [int]$Retries = 2
    )

    $payload = @{
        model       = $script:TcLlmModel
        messages    = @(
            @{ role = 'system'; content = $System },
            @{ role = 'user';   content = $User }
        )
        max_tokens  = $MaxTokens
        temperature = $Temperature
        chat_template_kwargs = @{ enable_thinking = [bool]$Think }
    }
    if ($Schema) {
        $payload.response_format = @{
            type = 'json_schema'
            json_schema = @{ name = 'out'; strict = $true; schema = $Schema }
        }
    }

    $body = $payload | ConvertTo-Json -Depth 20 -Compress
    $attempt = 0
    while ($true) {
        try {
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $r = Invoke-RestMethod -Uri "$($script:TcLlmEndpoint)/chat/completions" `
                                   -Method Post -Body $body -ContentType 'application/json' `
                                   -TimeoutSec $TimeoutSec -ErrorAction Stop
            $sw.Stop()

            $content = $r.choices[0].message.content
            $parsed  = $null
            if ($content) {
                $clean = ($content -replace '^\s*```(?:json)?\s*', '' -replace '\s*```\s*$', '').Trim()
                try { $parsed = $clean | ConvertFrom-Json } catch { $parsed = $null }
            }

            $secs = [Math]::Max($sw.Elapsed.TotalSeconds, 0.0001)
            $sha  = [System.Security.Cryptography.SHA256]::Create()
            $hash = -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes([string]$content)) |
                           ForEach-Object { $_.ToString('x2') })
            $sha.Dispose()

            return [pscustomobject]@{
                Ok               = $true
                Error            = $null
                Content          = $content
                Parsed           = $parsed
                Model            = $r.model
                PromptTokens     = $r.usage.prompt_tokens
                CompletionTokens = $r.usage.completion_tokens
                ElapsedSec       = [Math]::Round($secs, 3)
                TokensPerSec     = [Math]::Round($r.usage.completion_tokens / $secs, 1)
                OutputHash       = $hash
            }
        } catch {
            $attempt++
            if ($attempt -gt $Retries) {
                return [pscustomobject]@{
                    Ok = $false; Error = $_.Exception.Message; Content = $null; Parsed = $null
                    Model = $script:TcLlmModel; PromptTokens = 0; CompletionTokens = 0
                    ElapsedSec = 0; TokensPerSec = 0; OutputHash = $null
                }
            }
            Start-Sleep -Seconds (1.5 * $attempt)
        }
    }
}

function Invoke-LocalJudgment {
    <#
      .SYNOPSIS  Local-first judgment with an explicit escalation verdict (plan §7).
      .DESCRIPTION
        Returns the local verdict plus ShouldEscalate. The CALLER decides what to
        do with an escalation (queue it for the Claude agent); this lib never
        calls Claude itself, because in this estate Claude runs as scheduled
        agents with real-Chrome and repo access, not as a library call.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$System,
        [Parameter(Mandatory)][string]$User,
        [hashtable]$Schema,
        [double]$EscalateBelow = 0.75,
        [int]$MaxTokens = 800
    )
    $r = Invoke-LocalLLM -System $System -User $User -Schema $Schema -MaxTokens $MaxTokens
    $conf = $null
    if ($r.Ok -and $r.Parsed -and ($r.Parsed.PSObject.Properties.Name -contains 'confidence')) {
        $conf = [double]$r.Parsed.confidence
    }
    $escalate = (-not $r.Ok) -or ($null -eq $conf) -or ($conf -lt $EscalateBelow)
    return [pscustomobject]@{
        Ok = $r.Ok; Verdict = $r.Parsed; Confidence = $conf
        ShouldEscalate = $escalate; Raw = $r
    }
}
