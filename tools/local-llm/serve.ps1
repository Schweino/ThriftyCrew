<#
.SYNOPSIS
  Start the local OpenAI-compatible inference endpoint (Phase 0 deliverable).

.DESCRIPTION
  Launches llama.cpp's llama-server with the settings validated for THIS box:
  RTX 5070 Ti (Blackwell, sm_120, 16 GB) + Ryzen 9 9950X + 64 GB RAM.

  Why these flags:
    -ngl 99            all layers on GPU; the Q3_K_XL weights are 12.2 GiB and fit.
    --cache-type-k/v   q8_0 KV cache. A 27B dense model at 16k context would
                       otherwise spend several GiB on the KV cache and tip the
                       card into offload, which collapses decode speed.
    -c 16384           satisfies the plan's ">=8k context headroom" acceptance bar
                       with room for the Resolve prompts' candidate blocks.
    --jinja            uses the model's own chat template. Qwen3.x REQUIRES this
                       for correct role handling and for reasoning-block parsing.
    --temp 0.1 etc.    low-variance settings: this endpoint's job is structured
                       JSON extraction and adjudication, not prose.

  CUDA note: this must be a CURRENT llama.cpp build. Qwen3.8 registers the
  `qwen35` architecture and any build from before its release week refuses to
  load the GGUF. Pinned build: b10509 (2026-08-20), CUDA 13.3 for sm_120.

.EXAMPLE
  pwsh tools/local-llm/serve.ps1
  pwsh tools/local-llm/serve.ps1 -Context 32768 -Port 8081
#>
[CmdletBinding()]
param(
    [string]$Model   = "C:\Codex\llm\models\Qwen3.8-27B-UD-Q3_K_XL.gguf",
    [string]$BinDir  = "C:\Codex\llm\bin",
    [string]$ListenHost = "127.0.0.1",
    [int]$Port       = 8080,
    [int]$Context    = 16384,
    [int]$GpuLayers  = 99,
    [string]$CacheType = "q8_0",
    [switch]$Foreground
)

$ErrorActionPreference = 'Stop'

$server = Join-Path $BinDir 'llama-server.exe'
if (-not (Test-Path $server)) { throw "llama-server.exe not found at $server. Run tools/local-llm/install.ps1 first." }
if (-not (Test-Path $Model))  { throw "Model not found at $Model. Run tools/local-llm/fetch-model.ps1 first." }

# Already listening? Don't start a second copy fighting for the same VRAM.
$live = $null
try { $live = Invoke-RestMethod -Uri "http://${ListenHost}:$Port/health" -TimeoutSec 2 -ErrorAction Stop } catch { }
if ($live) {
    Write-Host "Endpoint already live on http://${ListenHost}:$Port  (status: $($live.status))" -ForegroundColor Green
    return
}

$serverArgs = @(
    '-m', $Model,
    '--host', $ListenHost,
    '--port', $Port,
    '-c', $Context,
    '-ngl', $GpuLayers,
    '--cache-type-k', $CacheType,
    '--cache-type-v', $CacheType,
    '--jinja',
    '--temp', '0.1',
    '--top-p', '0.9',
    '--repeat-penalty', '1.05',
    '--parallel', '1',
    '--alias', 'local-primary'
)

Write-Host "Starting llama-server:" -ForegroundColor Cyan
Write-Host "  model   : $(Split-Path $Model -Leaf)"
Write-Host "  context : $Context   kv-cache: $CacheType   gpu-layers: $GpuLayers"
Write-Host "  endpoint: http://${ListenHost}:$Port/v1"

if ($Foreground) {
    & $server @serverArgs
    return
}

$logDir = Join-Path $PSScriptRoot 'logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$stdout = Join-Path $logDir 'llama-server.out.log'
$stderr = Join-Path $logDir 'llama-server.err.log'

$proc = Start-Process -FilePath $server -ArgumentList $serverArgs -PassThru `
                      -RedirectStandardOutput $stdout -RedirectStandardError $stderr `
                      -WindowStyle Hidden
Write-Host "  pid     : $($proc.Id)  (logs: $logDir)"

# Wait for readiness. A 27B load off NVMe into VRAM takes a while on a cold cache.
$deadline = (Get-Date).AddSeconds(300)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 3
    if ($proc.HasExited) {
        Write-Host "llama-server exited early (code $($proc.ExitCode)). Tail of stderr:" -ForegroundColor Red
        if (Test-Path $stderr) { Get-Content $stderr -Tail 25 }
        throw "llama-server failed to start"
    }
    try {
        $h = Invoke-RestMethod -Uri "http://${ListenHost}:$Port/health" -TimeoutSec 3 -ErrorAction Stop
        if ($h.status -eq 'ok') {
            Write-Host "READY  http://${ListenHost}:$Port/v1" -ForegroundColor Green
            return
        }
    } catch { }
}
throw "llama-server did not become healthy within 300s; see $stderr"
