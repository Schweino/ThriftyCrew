<#
.SYNOPSIS
  Start the local OpenAI-compatible inference endpoint (Phase 0 deliverable).

.DESCRIPTION
  Launches llama.cpp's llama-server with the settings validated for THIS box:
  RTX 5070 Ti (Blackwell, sm_120, 16 GB) + Ryzen 9 9950X + 64 GB RAM.

  ONE OWNER OF THE CARD. (Brad's ruling 2026-08-22, narrowed the same day by
  PLAN-local-matching phase 2.)
    This model takes ~13 GB of the 16 GB card and leaves ~1 GB free. The
    semantic sidecar sweep (sidecar\sweep.py, run by
    grocery\audit-semantic-identity.ps1 in the 07:00 daily pipeline and 2-3x a
    day) needs ~3 GB of VRAM for bge-m3 + the reranker. The two cannot share
    the card: with this server up the sweep OOMs.

    The original ruling was NEVER SCHEDULED, start it by hand, stop it before
    07:00. That was the right rule while nothing owned the ordering, and it was
    paid for nightly in graph work that simply did not happen. The rule is now
    what it always meant:

      - NOTHING starts llama-server except graph\pipeline\nightly.ps1, which
        runs the sweep FIRST, waits for the sidecar to exit, checks nvidia-smi,
        and stops this server in a finally block that runs on success, failure,
        timeout and Ctrl-C;
      - nothing schedules that chain except
        graph\pipeline\install-nightly-task.ps1, whose default window ends at
        06:30 - half an hour clear of the 07:00 ad pull;
      - start it by hand for interactive work, and STOP IT WHEN YOU ARE DONE
        (`graph\pipeline\nightly.ps1 -StopOnly` does exactly that);
      - nothing else in Task Scheduler or the pipeline may start it.
    audit-semantic-identity.ps1 still checks nvidia-smi first and still goes
    BLIND (exit 3, naming llama-server as the holder) rather than launching a
    sweep that will OOM. It is now a BACKSTOP for a rule something enforces
    rather than the rule itself - and BLIND still means the semantic guard did
    not run that day.
    Ollama is a separate process and a separate decision; this rule is about
    llama-server only.

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
                       these slots — see resolve.py --jobs, whose default is
                       COUPLED to -Slots below (both 4; change both or
                       neither - more jobs than slots just queues inside the
                       server and burns client timeouts). A sequential client
                       against eight slots is exactly as fast as one slot.
                       (The 8-slot figures above are the 2026-08 measurement;
                       -Slots is 4 today, see the param note for why.)
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

# Failure-path forensics, captured BEFORE the launch.
#
# The old failure path ran `Get-Content $logFile -Tail 25` unconditionally. When
# the server dies before writing anything -- which is exactly what a Code
# Integrity block looks like -- that prints the PREVIOUS run's log: slot timings,
# a clean startup banner, a model that loaded fine. On 2026-08-25 that stale tail
# sent the diagnosis chasing a CUDA/driver fault for a day while the real cause
# (Smart App Control) sat unread in the CodeIntegrity event log. SAC has been
# ENFORCING on this box since 2026-06-23, so it was not a new setting that broke
# this. What changed on 2026-08-25 was not the policy either -- its version was
# byte-identical across the 08-13, 08-22 and 08-25 refreshes -- but Microsoft's
# cloud reputation verdict for these unsigned files, re-read after the 15:47
# refresh flushed the cached one. NOTHING LOCAL CHANGED, which is exactly why
# looking for a local change (driver, CUDA, build, model) found nothing.
# A log line this attempt did not write is not evidence about this attempt.
$logPreLen   = if (Test-Path $logFile) { (Get-Item $logFile).Length } else { -1 }
$startedAt   = Get-Date

function Show-StartFailure {
    <#
      .SYNOPSIS
        Report why THIS start attempt died, using only what THIS attempt produced.
      .DESCRIPTION
        Three things the old path did not say and should have:
          1. the exit code (0xC0E90002 names a Code Integrity kill on sight);
          2. whether the server wrote any log at all this run, said plainly
             rather than papered over with an earlier run's tail;
          3. whether Windows Code Integrity blocked the load, which is invisible
             in the Application event log and in llama.cpp's own output.
    #>
    param(
        [int]$ServerPid,
        [System.Diagnostics.Process]$Proc,
        [datetime]$Since,
        [long]$PreLen,
        [string]$LogPath,
        [string]$BinPath
    )

    $code = $null
    if ($Proc) { try { if ($Proc.HasExited) { $code = $Proc.ExitCode } } catch { } }
    if ($null -ne $code) {
        Write-Host ("llama-server (pid {0}) exited early with code {1} (0x{2:X8})." -f $ServerPid, $code, $code) -ForegroundColor Red
    } else {
        Write-Host ("llama-server (pid {0}) exited early (exit code not retrievable - it died before we could open a handle)." -f $ServerPid) -ForegroundColor Red
    }

    # -- this run's log lines, or an honest statement that there are none.
    if (-not (Test-Path $LogPath)) {
        Write-Host "  log: $LogPath does not exist. The server wrote nothing." -ForegroundColor Yellow
    } else {
        $item = Get-Item $LogPath
        if ($item.LastWriteTime -lt $Since) {
            Write-Host ("  log: THE SERVER WROTE NOTHING THIS RUN. {0} was last written {1}, before this attempt began at {2}." -f $LogPath, $item.LastWriteTime.ToString('s'), $Since.ToString('s')) -ForegroundColor Yellow
            Write-Host "       Everything in that file belongs to an earlier run and says nothing about this failure." -ForegroundColor Yellow
        } else {
            $new = ''
            if ($PreLen -ge 0 -and $item.Length -gt $PreLen) {
                $fs = [System.IO.File]::Open($LogPath, 'Open', 'Read', 'ReadWrite')
                try {
                    $null = $fs.Seek($PreLen, 'Begin')
                    $sr = New-Object System.IO.StreamReader($fs)
                    $new = $sr.ReadToEnd()
                } finally { $fs.Dispose() }
            } else {
                # truncated or rewritten in place: all of it belongs to this run.
                $new = Get-Content $LogPath -Raw -ErrorAction SilentlyContinue
            }
            $lines = @($new -split "`r?`n" | Where-Object { $_ -match '\S' })
            if ($lines.Count -eq 0) {
                Write-Host "  log: opened but left empty this run. The server wrote nothing." -ForegroundColor Yellow
            } else {
                Write-Host ("  log: {0} line(s) written by THIS run:" -f $lines.Count) -ForegroundColor Yellow
                $lines | Select-Object -Last 25 | ForEach-Object { Write-Host "    $_" }
            }
        }
    }

    # -- a silent death with no log is the signature of a Code Integrity block.
    # Event messages carry the NT device path (\Device\HarddiskVolumeN\Codex\...),
    # never the drive letter, so match on the drive-stripped tail of $BinPath.
    $needle = $BinPath -replace '^[A-Za-z]:', ''
    $ci = @()
    try {
        $ci = @(Get-WinEvent -FilterHashtable @{
                    LogName   = 'Microsoft-Windows-CodeIntegrity/Operational'
                    Id        = 3077
                    StartTime = $Since.AddSeconds(-30)
                } -ErrorAction Stop | Where-Object { $_.Message -like "*$needle*" })
    } catch { }

    if ($ci.Count -gt 0) {
        Write-Host ''
        Write-Host ("  CODE INTEGRITY BLOCKED THIS START - {0} event(s) in Microsoft-Windows-CodeIntegrity/Operational:" -f $ci.Count) -ForegroundColor Red
        $ci | Select-Object -First 3 | ForEach-Object {
            Write-Host ("    [{0}] {1}" -f $_.TimeCreated.ToString('HH:mm:ss'), $_.Message) -ForegroundColor Red
        }
        $sac = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' -ErrorAction SilentlyContinue).VerifiedAndReputablePolicyState
        if ($sac -eq 1) {
            Write-Host ''
            Write-Host '    Smart App Control is ON and ENFORCING (VerifiedAndReputablePolicyState = 1).' -ForegroundColor Red
            Write-Host '    The llama.cpp binaries are unsigned, so SAC refuses to load them.' -ForegroundColor Red
            Write-Host '    This is NOT a CUDA, driver, GPU, model or build fault. Rebuilding or' -ForegroundColor Red
            Write-Host '    re-downloading llama.cpp will NOT fix it: a new build is equally unsigned.' -ForegroundColor Red
            Write-Host '    Fix: Windows Security -> App & browser control -> Smart App Control -> Off.' -ForegroundColor Red
        }
    }
}

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

# Grab a handle NOW, while it is (probably) still alive. .ExitCode is only
# readable after exit if the handle was opened before it -- and the exit code is
# the single most diagnostic byte we get when the server dies silently.
$serverProc = Get-Process -Id $serverPid -ErrorAction SilentlyContinue
if ($serverProc) { try { $null = $serverProc.Handle } catch { } }

# Wait for readiness. A 27B load off NVMe into VRAM takes a while on a cold cache.
$deadline = (Get-Date).AddSeconds(300)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 3
    if (-not (Get-Process -Id $serverPid -ErrorAction SilentlyContinue)) {
        Show-StartFailure -ServerPid $serverPid -Proc $serverProc -Since $startedAt `
                          -PreLen $logPreLen -LogPath $logFile -BinPath $BinDir
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
