param(
  [Parameter(Mandatory=$true)][string]$OutputFile,
  [Parameter(Mandatory=$true)][string]$Request,
  [string]$SourceRef = 'codex-task://current'
)
$ErrorActionPreference = 'Stop'
if ($Request.Trim().Length -lt 10) { throw 'Recipe request must contain at least 10 characters' }
$requestedAt = (Get-Date).ToUniversalTime().ToString('o')
$id = 'recipe_{0}_{1}' -f ((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')), ([guid]::NewGuid().ToString('N').Substring(0,8))
$document = [ordered]@{ id = $id; request = $Request.Trim(); requestedAt = $requestedAt; sourceRef = $SourceRef; mode = 'recipe'; targetMissingIngredients = 50 }
$resolved = [IO.Path]::GetFullPath($OutputFile)
$parent = Split-Path -Parent $resolved
if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
[IO.File]::WriteAllText($resolved, ($document | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
Write-Output $resolved
