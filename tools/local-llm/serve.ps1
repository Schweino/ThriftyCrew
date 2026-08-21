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
    -c 16384           TOTAL context, divided among the slots below.
    --parallel 8       eight concurrent slots. This costs NO extra VRAM: -c is
                       the total KV budget and llama.cpp splits it, so 8 slots
                       is 2048 tokens each rather than 8x16384. Measured on
                       this box, a resolve prompt is 312 tokens and generation
                       is capped at 400, so 2048/slot is ~2.5x the requirement.
                       Decode is memory-BANDWIDTH bound at batch 1 (12.2 GiB of
                       weights read per step), and batching amortises that read
                       across eight sequences. MEASURED on this box, not
                       predicted: 36.6 -> 80.4 tok/s aggregate, i.e. 2.2x, and
                       it is flat past ~8 slots. It does NOT scale linearly --
                       once the weight reads are amortised, Q3_K dequantisation
                       compute becomes the ceiling. Verified not to be the JSON
                       grammar: dropping the schema entirely only moves it to
                       2.36x, which is why the schema stays (a 13% cost for a
                       structural valid-JSON guarantee is a good trade).
                       NOTE: the CLIENT must issue concurrent requests to use
                       these slots — see resolve.py --jobs. A sequential client
                       against eight slots is exactly as fast as one slot.
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
    # 4, and STAYING 4 — this was re-examined on 2026-08-21 and the answer held.
    #
    # -c is the TOTAL KV budget and llama.cpp splits it, so 8 slots meant 2048
    # tokens EACH: ample for a resolve call (312-token prompt, ~70 out) and far
    # too small for Learning Stage 1, whose prompt alone is ~1,000. Stage 1 died
    # with finish_reason=length at 882 completion tokens while max_tokens said
    # 4000 — the slot ceiling, not the request, was the limit, and it surfaced
    # as malformed JSON rather than as a config error. That is the shape of bug
    # worth paying to avoid.
    #
    # Going back to 8 slots WITHOUT re-breaking Stage 1 would need -c 26400+,
    # which means roughly doubling the KV cache. Measured free VRAM at 4 slots:
    # 1,092 MiB, against the ~1.5-2 GB that doubling needs on a 27B at q8_0. It
    # does not fit, and it is not worth wanting: the measured cost of 4 vs 8 is
    # 0.99 q/s against 1.08, an 8% give-back on occasional bulk runs, to buy a
    # context that fits every caller instead of only the smallest one.
    [int]$Slots      = 4,
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
    '--parallel', $Slots,
    '--alias', 'local-primary'
)

# A slot too small to hold prompt + generation makes llama.cpp truncate or
# refuse mid-run, which would look like a model failure rather than a config
# one. 312-token prompt + 400 generated + margin; fail here instead.
# The floor is set by the LARGEST caller, not the smallest. resolve needs ~840
# tokens; Learning Stage 1 sends a ~1,000-token prompt and asks for up to 2,200
# back, so anything under ~3,300 per slot silently truncates IT while resolve
# looks fine — which is exactly how 8 slots at 2,048 broke Stage 1 on
# 2026-08-20 and presented as malformed JSON rather than as a config error.
$perSlot = [math]::Floor($Context / $Slots)
if ($perSlot -lt 3300) {
    throw "Context $Context split across $Slots slots is $perSlot tokens/slot. Learning Stage 1 needs ~3,300 (1,000-token prompt + 2,200 requested). Raise -Context or lower -Slots. resolve alone would fit in 1,024, which is the trap: it fits and Stage 1 does not."
}

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
$logFile = Join-Path $logDir 'llama-server.log'
$serverArgs += @('--log-file', $logFile)

# WHY Win32_Process.Create AND NOT Start-Process.
#
# Start-Process with -RedirectStandardOutput/-RedirectStandardError calls
# CreateProcess with bInheritHandles=TRUE. That makes the child inherit EVERY
# inheritable handle this PowerShell holds -- including the stdout PIPE its own
# caller handed it -- regardless of where the child's own stdout was pointed.
# llama-server then holds the write end of that pipe forever, so any caller
# reading our output (`serve.ps1 | tail`, `$(serve.ps1)`, a CI step, an agent
# harness) blocks waiting for an EOF that cannot arrive until the SERVER dies.
# Measured 2026-08-20: the script completed and the server came up healthy,
# and the invoking shell still hung until it was killed by hand -- the worst
# shape of failure, because everything "worked".
#
# Win32_Process.Create creates the process with bInheritHandles=FALSE: no
# handle of ours crosses into the daemon. llama.cpp's own --log-file replaces
# the shell redirection we lose, which is better anyway (one ordered log
# instead of a split stdout/stderr pair).
$argLine = ($serverArgs | ForEach-Object {
    $a = [string]$_
    if ($a -match '\s') { '"' + $a + '"' } else { $a }
}) -join ' '
$create = Invoke-CimMethod -ClassName Win32_Process -MethodName Create `
                           -Arguments @{ CommandLine = ('"{0}" {1}' -f $server, $argLine) }
if ($create.ReturnValue -ne 0) {
    throw "Win32_Process.Create failed with code $($create.ReturnValue) (see Win32_Process docs)"
}
$serverPid = [int]$create.ProcessId
Write-Host "  pid     : $serverPid  (log: $logFile)"

# Wait for readiness. A 27B load off NVMe into VRAM takes a while on a cold cache.
$deadline = (Get-Date).AddSeconds(300)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 3
    if (-not (Get-Process -Id $serverPid -ErrorAction SilentlyContinue)) {
        Write-Host "llama-server exited early. Tail of its log:" -ForegroundColor Red
        if (Test-Path $logFile) { Get-Content $logFile -Tail 25 }
        throw "llama-server failed to start"
    }
    try {
        $h = Invoke-RestMethod -Uri "http://${ListenHost}:$Port/health" -TimeoutSec 3 -ErrorAction Stop
        if ($h.status -eq 'ok') {
            Write-Host "READY  http://${ListenHost}:$Port/v1  ($Slots slots)" -ForegroundColor Green
            return
        }
    } catch { }
}
throw "llama-server did not become healthy within 300s; see $logFile"
