<#
  recost-spec-cost-block.ps1 - re-render cost_lines + the six cost_* numbers + scaler.cost on an
  EXISTING spec, from its current db\costed.json row, without re-serializing the file.

  WHEN TO RUN THIS, AND WHEN NOT TO. Only after the spec's INGREDIENT LIST changed - a restored PHANTOM
  ingredient, a removed one. The cost block then has a line that is not in it (or one that should not be),
  and no other tool can put it there: reanchor-machine-fields only stamps stat.cost_ps and
  head.costPerServing, and build-v2-spec renders the block from an intake file this recipe no longer has.

  -Slugs IS MANDATORY, deliberately. A spec's cost block is a SNAPSHOT frozen at its last build, and
  db\costed.json is regenerated daily against the live board - so on 2026-08-05 all 513 specs disagreed
  with costed.json on cost_batch, by up to $14.17. That is not drift to repair, it is what the field means.
  Running this over the catalog would rewrite every reader-facing dollar figure on the site because the
  board moved, which is a price update wearing a repair's clothes. It touches the slugs you name and no
  others.

  The rendering itself is pipeline\cost-render-lib.ps1, the same code build-v2-spec renders intake with -
  see that file's header for why there is one copy. This script only reads the spec back into the shapes
  that function wants ($gramsArr / $scalerIng) and splices the result in key-scoped.

  Usage: .\recost-spec-cost-block.ps1 -Slugs a,b [-Apply]        (default is a dry run)
         .\recost-spec-cost-block.ps1 -SelfTest
#>
param(
  [string[]]$Slugs,
  [switch]$Apply,
  [switch]$SelfTest
)
$ErrorActionPreference='Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$mp = Split-Path -Parent $here
. (Join-Path $mp 'lib\json-db-io.ps1')
. (Join-Path $here 'cost-render-lib.ps1')

function Get-SpecCostShapes($spec){
  <#
    The two arrays Render-CostFields reads, rebuilt from a stored spec.
      gramsArr : item = the CANONICAL name, because that is what costed.json's lines are keyed on.
      scalerIng: canon must exist on every row - Render-CostFields joins on it - but specs written before
                 the r300 convention omit `canon` when it equals `item` (al-pastor's Rice row does), so
                 a missing canon falls back to item rather than silently matching nothing and rendering
                 a cost block with a line missing.
  #>
  $scaler = @()
  foreach($se in @($spec.scaler.ing)){
    $canon = if(($se.PSObject.Properties.Name -contains 'canon') -and $se.canon){ [string]$se.canon } else { [string]$se.item }
    $scaler += [pscustomobject]@{ item=[string]$se.item; canon=$canon; buy=[string]$se.buy }
  }
  $grams = @()
  if($spec.PSObject.Properties.Name -contains 'ingredients_grams' -and @($spec.ingredients_grams).Count -gt 0){
    foreach($ig in @($spec.ingredients_grams)){ $grams += [pscustomobject]@{ item=[string]$ig.item; grams=[double]$ig.grams } }
  } else {
    # legacy specs carry no ingredients_grams; the scaler holds the same grams in the same order
    foreach($se in @($spec.scaler.ing)){
      $canon = if(($se.PSObject.Properties.Name -contains 'canon') -and $se.canon){ [string]$se.canon } else { [string]$se.item }
      $grams += [pscustomobject]@{ item=$canon; grams=[double]$se.grams }
    }
  }
  if($grams.Count -ne $scaler.Count){ throw ("parallel array mismatch: grams $($grams.Count) vs scaler $($scaler.Count)") }
  return @{ grams=$grams; scaler=$scaler }
}

function Format-JsonNumber([double]$v){
  # match the serializer the specs were written with: 2.30 stores as 2.3, 32.00 as 32
  return ([double]$v).ToString([System.Globalization.CultureInfo]::InvariantCulture)
}

function Set-JsonNumberField([string]$Text,[string]$Key,[double]$Value){
  $rx = [regex]('"' + [regex]::Escape($Key) + '"\s*:\s*-?[0-9]+(?:\.[0-9]+)?')
  $ms = $rx.Matches($Text)
  if($ms.Count -ne 1){ throw ("key '$Key' matched $($ms.Count) times (need exactly 1)") }
  return $rx.Replace($Text, ('"' + $Key + '":  ' + (Format-JsonNumber $Value)), 1)
}

function Set-JsonStringArray([string]$Text,[string]$Key,[string[]]$Values){
  <# Replace an array-of-strings value in place, keeping the file's own indentation for the elements
     and the closing bracket. Never re-serializes anything but this one array. #>
  $at = Find-JsonValueStart -Raw $Text -Key $Key
  if($at -lt 0){ throw "key '$Key' not found" }
  if($Text[$at] -ne '['){ throw "key '$Key' is not an array" }
  $spans = @(Get-JsonArraySpans -Raw $Text -OpenIndex $at)
  if($spans.Count -eq 0){ throw "key '$Key' is an empty array - no indentation to copy" }
  # the whitespace run that precedes the first element, and the one that precedes the closing bracket
  $elemLead = $Text.Substring($at + 1, $spans[0].Start - $at - 1)
  $close = $spans[$spans.Count-1].End + 1
  while($close -lt $Text.Length -and $Text[$close] -ne ']'){ $close++ }
  if($close -ge $Text.Length){ throw "key '$Key': closing bracket not found" }
  $closeLead = $Text.Substring($spans[$spans.Count-1].End + 1, $close - $spans[$spans.Count-1].End - 1)
  $parts = foreach($v in $Values){ ConvertTo-Json -InputObject ([string]$v) }
  $body = '[' + $elemLead + (($parts) -join (',' + $elemLead)) + $closeLead + ']'
  return $Text.Substring(0, $at) + $body + $Text.Substring($close + 1)
}

function Set-ScalerCost([string]$Text,[double]$TrueCost){
  # scaler.cost is a STRING copy of cost_batch_true (spec-guards compares them); scope it to the
  # scaler object so a "cost" key anywhere else in the spec can never be the one that gets rewritten
  $sc = Find-JsonValueStart -Raw $Text -Key 'scaler'
  if($sc -lt 0){ throw 'no scaler key' }
  $rx = [regex]('"cost"\s*:\s*"[0-9.]*"')
  $m = $rx.Match($Text, $sc)
  if(-not $m.Success){ throw 'scaler.cost not found' }
  return $Text.Substring(0, $m.Index) + ('"cost":  "' + $TrueCost.ToString('0.00') + '"') + $Text.Substring($m.Index + $m.Length)
}

function Invoke-RecostSpec([string]$SpecPath,$CostRow,[bool]$DoApply){
  $io = Read-SpecText -Path $SpecPath
  $spec = $io.Text | ConvertFrom-Json
  $shapes = Get-SpecCostShapes $spec
  $cf = Render-CostFields $CostRow $shapes.grams $shapes.scaler ([string]$spec.slug)
  $t = $io.Text
  $t = Set-JsonStringArray $t 'cost_lines' $cf.lines
  $t = Set-JsonNumberField $t 'cost_batch'            $cf.batch
  $t = Set-JsonNumberField $t 'cost_batch_true'       $cf.trueC
  $t = Set-JsonNumberField $t 'cost_per_serving'      $cf.cps
  $t = Set-JsonNumberField $t 'cost_per_serving_true' $cf.cpsTrue
  $t = Set-JsonNumberField $t 'cost_pantry_add'       $cf.pantryAdd
  $t = Set-JsonNumberField $t 'cost_first_run'        $cf.firstRun
  $t = Set-ScalerCost $t $cf.trueC
  $changed = ($t -ne $io.Text)
  if($DoApply -and $changed){ Write-SpecText -Path $SpecPath -Text $t -Bom $io.Bom }
  elseif($changed){ $null = $t | ConvertFrom-Json }   # dry run still proves the result parses
  return @{ changed=$changed; batch=$cf.batch; trueC=$cf.trueC; lines=@($cf.lines).Count; text=$t }
}

# ---------------------------------------------------------------------------------------------------
if($SelfTest){
  $fails = 0
  function Chk([string]$name,[bool]$ok,[string]$got){
    if($ok){ Write-Output ("  ok   " + $name) } else { $script:fails++; Write-Output ("  FAIL " + $name + " -> " + $got) }
  }
  Write-Output 'recost-spec-cost-block self-test'

  # --- the splice keeps the file's own indentation and rewrites only the named array
  $sample = @'
{
    "slug":  "x",
    "cost_lines":  [
                       "one",
                       "two"
                   ],
    "cost_batch":  1.5,
    "other_lines":  [
                        "untouched"
                    ]
}
'@
  $out = Set-JsonStringArray $sample 'cost_lines' @('alpha','beta','gamma')
  $p = $out | ConvertFrom-Json
  Chk 'array replaced'            (@($p.cost_lines).Count -eq 3 -and $p.cost_lines[2] -eq 'gamma') (@($p.cost_lines) -join '|')
  # \r?$ NOT $ (2026-08-08). In .NET multiline mode `$` matches before the \n but AFTER any \r, so this
  # assertion passed on LF text and failed on CRLF - and Set-JsonStringArray emits CRLF. The function was
  # preserving the indent correctly all along (measured: 23 spaces in, 23 out); only the anchor was wrong.
  # A test that depends on the line ending of the machine it runs on is not testing what it claims to.
  Chk 'element indent preserved'  ($out -match '(?m)^                       "alpha",\r?$')          $out
  Chk 'sibling array untouched'   ($p.other_lines[0] -eq 'untouched' -and $out -match '"untouched"') $out
  Chk 'number field scoped'       ((Set-JsonNumberField $sample 'cost_batch' 2.25) -match '"cost_batch":  2\.25') 'n/a'

  # --- MUST FIRE: cost_batch is a PREFIX of cost_batch_true; the anchor must not confuse them
  $two = '{"cost_batch":  10.0,"cost_batch_true":  20.0}'
  $r2 = Set-JsonNumberField $two 'cost_batch' 11
  $p2 = $r2 | ConvertFrom-Json
  Chk 'prefix key not clobbered'  ([double]$p2.cost_batch -eq 11 -and [double]$p2.cost_batch_true -eq 20) $r2

  # --- canon fallback: a scaler row without `canon` still joins to its costed line
  $legacy = [pscustomobject]@{
    slug='legacy'
    scaler=[pscustomobject]@{ ing=@([pscustomobject]@{ item='Rice'; grams=700; buy='3.75 cups dry' }) }
  }
  $sh = Get-SpecCostShapes $legacy
  Chk 'canon falls back to item'  ($sh.scaler[0].canon -eq 'Rice' -and $sh.grams[0].item -eq 'Rice') ($sh.scaler[0].canon)

  # --- the renderer's own exactness gate must FIRE when the costed row disagrees with the spec
  $badRow = [pscustomobject]@{
    lines=@([pscustomobject]@{ item='Rice'; grams=700; util_cost=0.86; bulk=$true; starter_n=1 })
    cost_batch=99.0; cost_batch_true=99.0; cost_pantry_add=0.0; cost_first_run=99.0
  }
  $threw = $false
  try { $null = Render-CostFields $badRow $sh.grams $sh.scaler 'legacy' } catch { $threw = $true }
  Chk 'MUST FIRE  rendered total != engine total throws' $threw 'no throw'

  # --- number formatting matches the stored serializer's shape
  Chk 'number format 2.30 -> 2.3'  ((Format-JsonNumber 2.30) -eq '2.3')  (Format-JsonNumber 2.30)
  Chk 'number format 32 -> 32'     ((Format-JsonNumber 32.0) -eq '32')   (Format-JsonNumber 32.0)

  Write-Output ("self-test: " + $(if($fails){ "$fails FAILED" } else { 'all green' }))
  exit $(if($fails){ 1 } else { 0 })
}

if(-not $Slugs -or $Slugs.Count -eq 0){ throw '-Slugs is required (see the header: this is never a catalog-wide sweep)' }
$costed = Get-Content (Join-Path $mp 'db\costed.json') -Raw -Encoding utf8 | ConvertFrom-Json
$bySlug = @{}; foreach($r in $costed){ $bySlug[[string]$r.slug] = $r }
$changed = 0
foreach($slug in $Slugs){
  $sp = Join-Path $mp ('db\recipes\' + $slug + '.json')
  if(-not (Test-Path $sp)){ Write-Output ("FAIL  $slug - no spec file"); continue }
  $row = $bySlug[$slug]
  if(-not $row){ throw ("no costed row for $slug - run engine\cost-recipes.ps1 -Slugs $slug first") }
  $r = Invoke-RecostSpec $sp $row ([bool]$Apply)
  if($r.changed){ $changed++ }
  Write-Output ("{0}  {1}  batch=`${2} true=`${3} ({4} cost lines)" -f $(if($Apply){'APPLIED'}else{'DRY    '}), $slug, $r.batch, $r.trueC, $r.lines)
}
Write-Output ("{0} spec(s) would change" -f $changed)
if(-not $Apply){ Write-Output 'dry run - pass -Apply to write' }
