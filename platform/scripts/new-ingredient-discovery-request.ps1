param(
  [Parameter(Mandatory=$true)][string]$OutputFile,
  [ValidateRange(1,50)][int]$TargetMissingIngredients = 50,
  [string]$SourceRef = 'codex-task://ingredient-discovery'
)
$ErrorActionPreference = 'Stop'
$requestedAt = (Get-Date).ToUniversalTime().ToString('o')
$id = 'ingredient_discovery_{0}_{1}' -f ((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')), ([guid]::NewGuid().ToString('N').Substring(0,8))
$request = 'Randomly source diverse, externally verified complete meal-prep recipes solely to discover required purchased ingredients missing from the active Omaha grocery catalog. Preserve every quantified required ingredient, ignore only true process water and optional garnish, and exclude seafood and ground chicken.'
$document = [ordered]@{ id = $id; request = $request; requestedAt = $requestedAt; sourceRef = $SourceRef; mode = 'missing-ingredients'; targetMissingIngredients = $TargetMissingIngredients }
$resolved = [IO.Path]::GetFullPath($OutputFile)
$parent = Split-Path -Parent $resolved
if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
[IO.File]::WriteAllText($resolved, ($document | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
Write-Output $resolved
