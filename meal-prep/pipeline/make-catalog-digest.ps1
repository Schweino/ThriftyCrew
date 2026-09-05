<#
  make-catalog-digest.ps1 - emit a COMPACT digest of the live recipe catalog for the sourcer/selector
  agents, so a recipe run never has to read the full recipes-db.json (3.9 MB now, ~11.5 MB at 1500 -
  unreadable whole in an agent's context). Implements the NEXT-RUN-PLAYBOOK "one catalog digest" step.

  For every live recipe it keeps only what dedup needs: slug, name, protein, and the sorted set of
  main ingredient item_ids (the board commodities, which is how the dedup-selector judges "same dish").
  Grouped by protein so each parallel selector reads only its own slice.

  Output: pipeline\catalog-digest.json
    { generated_from, recipe_count, by_protein: { chicken:[{slug,name,items:[...]}...], ... } }
  ~100 KB at 513 recipes vs 3.9 MB - a >30x read reduction per agent, and it stays small as the catalog
  grows (item_ids, not full ingredient rows/prose). Run this at the START of any recipe run; the sourcer
  and dedup-selector agents read catalog-digest.json instead of recipes-db.json.

  MAIN-INGREDIENT heuristic: an item_id is "main" if its grams are >= -MinGrams (default 60) OR it is the
  single largest line. This keeps proteins/starches/vegetables that define a dish and drops trace
  aromatics/spices that every dish shares (so the dedup key is meaningful, not swamped by salt+pepper).

  THE CALIBRATION TRAVELS WITH THE DIGEST (D12 rung 2, PLAN-recipe-hunter-v3 S2a part b). The live
  catalog's own internal pairwise similarity distribution is a property OF this digest - it is what
  says which similarity scores two PUBLISHED, ruled-distinct recipes actually sit at, and therefore
  the only honest floor under any dupe threshold. So it is rebuilt HERE, in the same act, rather than
  by a step someone has to remember: a distribution describing last week's catalog is worse than none,
  which is why its reader fingerprints it against the digest and refuses when the two disagree.
  It needs torch, so it runs under sidecar\.venv. If that interpreter is not there the digest still
  writes and this SAYS the calibration is now stale - could-not-look is never a clean bill, and the
  fingerprint downstream is what enforces it.
#>
param(
  [string]$DbPath = '',
  [string]$OutPath = '',
  [int]$MinGrams = 60,
  [switch]$NoCalibrate,
  # The sidecar venv is gitignored, so a git WORKTREE has none - and a worktree is exactly where this
  # change was built and proved. Naming the interpreter is how the happy path gets exercised somewhere
  # other than the main tree; nothing scheduled ever passes it.
  [string]$VenvPython = ''
)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$mp = Split-Path -Parent $here
$repo = Split-Path -Parent $mp
if (-not $DbPath)  { $DbPath  = Join-Path $mp 'recipes-db.json' }
if (-not $OutPath) { $OutPath = Join-Path $here 'catalog-digest.json' }

$doc = Read-JsonFile $DbPath
$byProt = [ordered]@{}
foreach ($r in $doc.recipes) {
  $prot = ([string]$r.protein) -replace '^ground\s+',''
  if (-not $prot) { $prot = 'other' }
  if (-not $byProt.Contains($prot)) { $byProt[$prot] = New-Object System.Collections.Generic.List[object] }
  # main item_ids: >= MinGrams, plus always the single largest line (so a tiny-portion dish still keys)
  $ings = @($r.ingredients | Where-Object { $_.item_id })
  $main = @($ings | Where-Object { [double]$_.grams -ge $MinGrams } | ForEach-Object { [string]$_.item_id })
  if (-not $main.Count -and $ings.Count) { $main = @(($ings | Sort-Object { -[double]$_.grams } | Select-Object -First 1).item_id) }
  $items = @($main | Sort-Object -Unique)
  $byProt[$prot].Add([ordered]@{ slug=[string]$r.slug; name=[string]$r.name; items=$items })
}
# stable ordering inside each protein (by slug) so the digest is deterministic / diff-friendly
$outProt = [ordered]@{}
foreach ($k in $byProt.Keys) { $outProt[$k] = @($byProt[$k] | Sort-Object { $_.slug }) }

$digest = [ordered]@{
  generated_from = [IO.Path]::GetFileName($DbPath)
  recipe_count   = @($doc.recipes).Count
  min_grams      = $MinGrams
  by_protein     = $outProt
}
$json = $digest | ConvertTo-Json -Depth 6 -Compress
[IO.File]::WriteAllText($OutPath, $json, (New-Object System.Text.UTF8Encoding($false)))
$sizeK = [math]::Round((Get-Item $OutPath).Length / 1KB, 1)
$counts = ($outProt.Keys | ForEach-Object { "$_=$(@($outProt[$_]).Count)" }) -join ' '
Write-Output ("catalog-digest.json: {0} recipes, {1} KB ({2}) -> {3}" -f $digest.recipe_count, $sizeK, $counts, $OutPath)

# ---- the calibration, in the same act (D12 rung 2) --------------------------------------------------
if (-not $NoCalibrate) {
  $venv = if ($VenvPython) { $VenvPython } else { Join-Path $repo 'sidecar\.venv\Scripts\python.exe' }
  $embed = Join-Path $here 'harvest_embed.py'
  if (-not (Test-Path $venv) -or -not (Test-Path $embed)) {
    # The parentheses matter: -f binds tighter than nothing here, and applied to a two-string
    # concatenation it formats only the SECOND half, which prints a literal {0} at the reader.
    Write-Output ((("  CALIBRATION NOT REFRESHED - {0} is not there. catalog-similarity.json now " +
      "describes an older digest, and every reader of it will report BLIND until this is re-run.")) -f $venv)
  } else {
    # -Digest is not passed: harvest_embed reads the same default path this script just wrote.
    & $venv $embed --calibrate | ForEach-Object { "  $_" }
    if ($LASTEXITCODE -ne 0) {
      Write-Output ((("  CALIBRATION NOT REFRESHED - harvest_embed --calibrate exited {0}. The " +
        "distribution beside this digest is stale and its reader will say so.")) -f $LASTEXITCODE)
    }
  }
}
