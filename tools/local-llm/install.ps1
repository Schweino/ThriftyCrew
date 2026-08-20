<#
.SYNOPSIS
  Install the local inference toolchain (Phase 0).

.DESCRIPTION
  Reproduces the validated Phase 0 stack on this class of machine:
    GPU  NVIDIA RTX 5070 Ti, 16 GB, Blackwell (compute capability 12.0 / sm_120)
    CPU  AMD Ryzen 9 9950X
    RAM  64 GB

  TWO THINGS HERE ARE NOT INTERCHANGEABLE, and both cost real debugging time:

  1. CUDA 13.3, not 12.4. The 5070 Ti is Blackwell (sm_120). The CUDA 12.4
     builds predate that target and will not run the kernels.

  2. A CURRENT llama.cpp build. Qwen3.8 registers the `qwen35` architecture;
     any build from before its release week (2026-08-14) refuses the GGUF
     outright. Pinned here to b10509.

  Weights are NOT installed into the repo. They live under -Root (default
  C:\Codex\llm), the same split sidecar\ uses: source and config are tracked,
  the multi-GB environment is reproducible from this script.

.EXAMPLE
  pwsh tools/local-llm/install.ps1
  pwsh tools/local-llm/install.ps1 -Release b10600 -SkipModel
#>
[CmdletBinding()]
param(
    [string]$Root    = "C:\Codex\llm",
    [string]$Release = "b10509",
    [string]$Cuda    = "13.3",
    [switch]$SkipModel,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

function Say($m, $c = 'Cyan') { Write-Host $m -ForegroundColor $c }

Say "=== ThriftyCrew local inference install ==="

# --- 1. verify the GPU actually is what this script assumes -----------------
$cc = $null
try { $cc = (& nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>$null | Select-Object -First 1) } catch { }
if (-not $cc) {
    Write-Warning "nvidia-smi not found. A CUDA GPU is required for a usable decode rate."
} else {
    $name = (& nvidia-smi --query-gpu=name,memory.total --format=csv,noheader | Select-Object -First 1)
    Say "  GPU: $name  (compute capability $cc)"
    if ([double]$cc -ge 12.0 -and $Cuda -notmatch '^13') {
        Write-Warning "compute capability $cc is Blackwell; CUDA $Cuda builds may lack sm_120 kernels. Prefer -Cuda 13.3."
    }
}

# --- 2. Python -------------------------------------------------------------
$py = $null
foreach ($c in @("$env:LOCALAPPDATA\Programs\Python\Python312\python.exe",
                 "C:\Codex\Python312\python.exe", "C:\Program Files\Python312\python.exe")) {
    if (Test-Path $c) { $py = $c; break }
}
if (-not $py) {
    $reg = 'HKLM:\SOFTWARE\Python\PythonCore\3.12\InstallPath', 'HKCU:\SOFTWARE\Python\PythonCore\3.12\InstallPath'
    foreach ($k in $reg) {
        if (Test-Path $k) {
            $p = Join-Path ((Get-ItemProperty $k).'(default)') 'python.exe'
            if (Test-Path $p) { $py = $p; break }
        }
    }
}
if (-not $py) {
    Say "  installing Python 3.12 via winget ..."
    winget install --id Python.Python.3.12 -e --source winget `
        --accept-package-agreements --accept-source-agreements --disable-interactivity | Out-Null
    $py = "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe"
}
if (-not (Test-Path $py)) { throw "could not locate a Python 3.12 interpreter" }
Say "  Python: $py  ($(& $py --version))"
# NOTE: the WindowsApps python.exe is a Store stub that shadows the real install
# on PATH. Always invoke the resolved absolute path, never a bare `python`.

& $py -m pip install --quiet --upgrade "huggingface_hub[hf_transfer]" | Out-Null
Say "  huggingface_hub: $(& $py -c 'import huggingface_hub;print(huggingface_hub.__version__)')"

# --- 3. llama.cpp ----------------------------------------------------------
New-Item -ItemType Directory -Force -Path $Root, "$Root\bin", "$Root\models" | Out-Null
$server = "$Root\bin\llama-server.exe"

if ((Test-Path $server) -and -not $Force) {
    Say "  llama.cpp already present at $Root\bin (use -Force to reinstall)"
} else {
    $base = "https://github.com/ggml-org/llama.cpp/releases/download/$Release"
    foreach ($f in @("llama-$Release-bin-win-cuda-$Cuda-x64.zip",
                     "cudart-llama-bin-win-cuda-$Cuda-x64.zip")) {
        $out = Join-Path $Root $f
        Say "  downloading $f ..."
        Invoke-WebRequest -Uri "$base/$f" -OutFile $out -UseBasicParsing
        Expand-Archive -Path $out -DestinationPath "$Root\bin" -Force
        Remove-Item $out -Force
    }
    if (-not (Test-Path $server)) { throw "llama-server.exe missing after extract" }
    Say "  llama.cpp $Release (CUDA $Cuda) installed"
}

# --- 4. weights ------------------------------------------------------------
if (-not $SkipModel) {
    & (Join-Path $PSScriptRoot 'fetch-model.ps1') -Root $Root -Python $py
}

Say ""
Say "Done. Next:" 'Green'
Say "  pwsh tools/local-llm/serve.ps1"
Say "  python graph/bench/bench.py        # Phase 0 acceptance gate"
