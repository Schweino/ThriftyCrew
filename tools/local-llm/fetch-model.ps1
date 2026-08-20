<#
.SYNOPSIS
  Download GGUF weights for the local inference stack (Phase 0).

.DESCRIPTION
  Default is the Phase 0 primary: Qwen3.8-27B at Unsloth's UD-Q3_K_XL dynamic
  quant — 13.1 GB on disk, ~14.2 GB resident with a q8_0 KV cache at 16k
  context, which leaves real headroom inside the 5070 Ti's 16 GB.

  Why this quant: Q3_K_XL is the largest 3-bit file that still leaves room for
  context and KV cache on a 16 GB card. IQ4_XS (~15.7 GB) fits the weights but
  not comfortably the cache, and tipping into offload collapses decode speed.

  Weights are stored OUTSIDE the repo (-Root, default C:\Codex\llm\models). They
  are reproducible from this script, so they do not belong in git — the same
  split sidecar\ already uses for its model environment.

.EXAMPLE
  pwsh tools/local-llm/fetch-model.ps1
  pwsh tools/local-llm/fetch-model.ps1 -Quant UD-Q4_K_M
  pwsh tools/local-llm/fetch-model.ps1 -Repo unsloth/Qwen3.8-27B-GGUF -Quant UD-IQ4_XS
#>
[CmdletBinding()]
param(
    [string]$Root   = "C:\Codex\llm",
    [string]$Repo   = "unsloth/Qwen3.8-27B-GGUF",
    [string]$Model  = "Qwen3.8-27B",
    [string]$Quant  = "UD-Q3_K_XL",
    [string]$Python
)

$ErrorActionPreference = 'Stop'

if (-not $Python) {
    foreach ($c in @("$env:LOCALAPPDATA\Programs\Python\Python312\python.exe",
                     "C:\Codex\Python312\python.exe")) {
        if (Test-Path $c) { $Python = $c; break }
    }
}
if (-not $Python -or -not (Test-Path $Python)) {
    throw "no Python found; run tools/local-llm/install.ps1 first"
}

$file   = "$Model-$Quant.gguf"
$target = Join-Path "$Root\models" $file

if (Test-Path $target) {
    $gb = [math]::Round((Get-Item $target).Length / 1GB, 2)
    Write-Host "already present: $target ($gb GB)" -ForegroundColor Green
    return
}

New-Item -ItemType Directory -Force -Path "$Root\models", "$Root\hf" | Out-Null
$env:HF_HUB_ENABLE_HF_TRANSFER = "1"     # multi-connection downloader
$env:HF_HOME = "$Root\hf"

Write-Host "downloading $Repo :: $file  (this is a multi-GB pull)" -ForegroundColor Cyan

$script = @"
import os
from huggingface_hub import hf_hub_download
p = hf_hub_download(repo_id=r'$Repo', filename=r'$file', local_dir=r'$Root\models')
print('DONE', p, os.path.getsize(p))
"@

& $Python -c $script
if ($LASTEXITCODE -ne 0) { throw "download failed (exit $LASTEXITCODE)" }

if (-not (Test-Path $target)) { throw "expected $target after download" }
$gb = [math]::Round((Get-Item $target).Length / 1GB, 2)
Write-Host "OK  $target  ($gb GB)" -ForegroundColor Green
Write-Host "Next: pwsh tools/local-llm/serve.ps1 -Model `"$target`""
