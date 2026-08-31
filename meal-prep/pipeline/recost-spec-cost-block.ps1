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

  -Slugs IS IN-PROCESS ONLY. -SlugFile IS THE `powershell -File` FORM, ON PURPOSE. Measured 2026-08-23:
  invoked as `powershell -File ...\recost-spec-cost-block.ps1 -Slugs $tenSlugArray -Apply`, this script
  recost ONE slug and printed "APPLIED <slug>" plus "1 spec(s) would change" - a line indistinguishable
  from a correct one-slug run. Nothing said nine names had been dropped. TWO different shapes do that:
  the -File parser binds the first bare word to -Slugs and leaves the rest unplaced (the measured one -
  note it contains no comma anywhere), while `-Slugs a,b` arrives instead as ONE element holding commas,
  the trap propagate-recipes.ps1's -AllowCreateFile header already documents. Neither is visible in the
  applied slug, and this script is the estate's ONLY sanctioned repair for a stale cost block - "a recost
  that silently skips rows" is precisely what the wave-preaudit cost-reconcile check exists to catch
  after the fact. So both shapes now THROW, naming the two working call forms (audit-unbid-ingredients
  SPLITS a comma-joined -Slugs because it only reads; hunt-run's -Terms refuses, because a joined string
  is a caller bug worth surfacing - a writer of reader-facing dollar figures belongs in the second camp),
  and every run ends with a requested/processed/changed tally so a short run is legible on its face.

  Usage: & .\recost-spec-cost-block.ps1 -Slugs a,b [-Apply]     in-process; default is a dry run
         powershell -NoProfile -ExecutionPolicy Bypass -File .\recost-spec-cost-block.ps1 -SlugFile <path> [-Apply]
                                                               <path> is newline-delimited, one slug per line
         .\recost-spec-cost-block.ps1 -SelfTest
#>
# PositionalBinding=$false + an explicit remaining-arguments sink, both load-bearing. Only -Slugs is
# positional, so a bare word after the first can NEVER bind to -SlugFile by position (it did while
# -SlugFile was declared plainly: `-File ... -Slugs a b` bound 'b' as the slug FILE). Everything the
# parser could not place lands in $Residue instead of vanishing, which is what makes the dropped names
# nameable in the refusal below rather than merely countable.
[CmdletBinding(PositionalBinding=$false)]
param(
  [Parameter(Position=0)][string[]]$Slugs,
  [string]$SlugFile = "",
  [switch]$Apply,
  [switch]$SelfTest,
  [Parameter(ValueFromRemainingArguments=$true)][string[]]$Residue
)
$ErrorActionPreference='Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$mp = Split-Path -Parent $here
. (Join-Path $mp 'lib\json-db-io.ps1')
. (Join-Path $here 'cost-render-lib.ps1')

# ---- INTERFACE GUARD: a slug list that lost members must never look like a smaller run ---------------
$script:SLUG_CALL_FORMS = @'
      in-process:  & meal-prep\pipeline\recost-spec-cost-block.ps1 -Slugs $slugArray -Apply
      via -File:   powershell -NoProfile -ExecutionPolicy Bypass -File meal-prep\pipeline\recost-spec-cost-block.ps1 -SlugFile <path> -Apply
                   (<path> holds one slug per line - the shape propagate-recipes.ps1 takes for
                    -AllowCreateFile, and the only one that crosses a process boundary intact)
'@

function Resolve-SlugRequest {
  <#
    Turn whatever the caller handed us into THE slug list, or refuse out loud. Returns @{ slugs; source }.
    Every refusal below is a caller-side marshalling bug whose only other symptom is a correct-LOOKING
    run over fewer specs than the operator asked for - see the header for the 2026-08-23 measurement.
  #>
  param([string[]]$Slugs, [string]$SlugFile, $Residue)

  # (a) THE MEASURED SHAPE. `-File ... -Slugs a b c` binds 'a' and parks 'b','c' in $Residue. -Slugs is
  #     this script's only positional parameter, so a remaining argument can only ever be a dropped slug.
  #     COMPACT FIRST, and never test @($Residue).Count on the raw value: an UNBOUND $Residue is $null,
  #     and @($null).Count is 1 in PS 5.1 - which made the guard refuse every clean run with "dropped 1
  #     name(s): " and no name. A guard that fires on correct calls is uninstalled within the week.
  $dropped = @(); foreach($rv in @($Residue)){ if($null -ne $rv -and ([string]$rv).Trim()){ $dropped += ([string]$rv).Trim() } }
  if(@($dropped).Count -gt 0){
    throw ("-Slugs dropped " + @($dropped).Count + " name(s) on the command line: " + (@($dropped) -join ', ') +
      "`n  A [string[]] does not survive ``powershell -File``: the parser binds the FIRST word to -Slugs" +
      " and discards the rest. Use one of:`n" + $script:SLUG_CALL_FORMS)
  }
  if($SlugFile -and @($Slugs).Count -gt 0){
    throw ("both -Slugs and -SlugFile were given - two lists cannot both be the run's authority.`n" + $script:SLUG_CALL_FORMS)
  }

  $out = @(); $src = ''
  if($SlugFile){
    if(-not (Test-Path $SlugFile)){ throw ("-SlugFile named $SlugFile but it does not exist - refusing to recost an empty list") }
    foreach($ln in @(Get-Content $SlugFile)){ $t = ([string]$ln).Trim(); if($t){ $out += $t } }
    $src = "-SlugFile $SlugFile"
  } else {
    foreach($sv in @($Slugs)){ if($null -ne $sv -and ([string]$sv).Trim()){ $out += ([string]$sv).Trim() } }
    $src = '-Slugs (in-process array)'
  }

  # (b) THE COMMA SHAPE, the one propagate's header documents. Refuse rather than split: splitting is
  #     safe in a read-only sweep, but here it would let a caller whose list ALREADY collapsed go on
  #     rewriting reader-facing dollars on the strength of a guess about what they meant.
  foreach($sv in $out){
    if($sv -match ','){
      throw ("slug '" + $sv + "' contains a comma, so a list of " + @(([string]$sv).Split(',')).Count +
        " names collapsed into one.`n" + $script:SLUG_CALL_FORMS)
    }
  }
  if(@($out).Count -eq 0){
    throw '-Slugs or -SlugFile is required, and must resolve to at least one slug (see the header: this is never a catalog-wide sweep)'
  }
  return @{ slugs=@($out); source=$src }
}

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

  # ---- Get-PkgLabel. costed.json carries package labels straight off the board row and some already count
  # themselves, so the buy line prefixed its own count onto them: "Buy " + 3 + " " + "1 head" rendered
  # "Buy 3 1 heads" across ten specs on 2026-08-16. Stripping a leading "1 " fixes that - but only when the
  # 1 is a redundant COUNT. In "1 lb bag" it is the package SIZE, and stripping it would render three
  # one-pound bags as "Buy 3 lb bags". A wave auditor flagged that as latent and measured it: today the only
  # leading-"1 " labels among all 172 distinct package labels are "1 bunch" and "1 head", so it has never
  # fired. That is precisely when it is cheap to close.
  #
  # The distinction is whether the unit token carries its own number. A BARE unit after the 1 means size
  # ("1 lb bag"). A token that already has digits is itself a size, so the 1 is a count ("1 0.75oz clamshell"
  # is one clamshell holding 0.75 oz, and reads "Buy 1 0.75oz clamshell").
  Chk 'MUST FIRE  a redundant count of one is stripped'            ((Get-PkgLabel '1 bunch') -eq 'bunch')        (Get-PkgLabel '1 bunch')
  Chk 'MUST FIRE  and for heads, the other live case'              ((Get-PkgLabel '1 head') -eq 'head')          (Get-PkgLabel '1 head')
  Chk 'MUST FIRE  a one-POUND bag keeps its 1 (size, not count)'   ((Get-PkgLabel '1 lb bag') -eq '1 lb bag')    (Get-PkgLabel '1 lb bag')
  Chk 'MUST FIRE  nor is a one-gallon jug stripped'                ((Get-PkgLabel '1 gal jug') -eq '1 gal jug')  (Get-PkgLabel '1 gal jug')
  Chk 'MUST FIRE  nor a one-ounce packet'                          ((Get-PkgLabel '1 oz packet') -eq '1 oz packet') (Get-PkgLabel '1 oz packet')
  Chk 'CLEAN TWIN a sized token after the 1 IS a count and strips' ((Get-PkgLabel '1 0.75oz clamshell') -eq '0.75oz clamshell') (Get-PkgLabel '1 0.75oz clamshell')
  Chk 'CLEAN TWIN so does a 750ml bottle'                          ((Get-PkgLabel '1 750ml bottle') -eq '750ml bottle') (Get-PkgLabel '1 750ml bottle')
  Chk 'CLEAN TWIN a non-one count is never touched'                ((Get-PkgLabel '2 lb bag') -eq '2 lb bag')    (Get-PkgLabel '2 lb bag')
  Chk 'CLEAN TWIN a spaceless size label is never touched'         ((Get-PkgLabel '12oz bag') -eq '12oz bag')    (Get-PkgLabel '12oz bag')
  Chk 'CLEAN TWIN a bare unit is never touched'                    ((Get-PkgLabel 'each') -eq 'each')            (Get-PkgLabel 'each')

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

  # --- THE INTERFACE. A slug list that lost members must refuse, never run smaller and say so calmly.
  # Measured 2026-08-23: `powershell -File ... -Slugs $tenSlugArray -Apply` recost ONE slug. Two distinct
  # shapes produce that, and BOTH are pinned, because the comma case alone would not have caught the
  # measured run - argv-splitting had already separated the ten names before the script saw any of them.
  function TryResolve($sl,$sf,$res){
    try   { $rr = Resolve-SlugRequest -Slugs $sl -SlugFile $sf -Residue $res
            return @{ threw=$false; slugs=@($rr.slugs); msg='' } }
    catch { return @{ threw=$true;  slugs=@();          msg=[string]$_ } }
  }
  # $null, not @(), is what an unbound remaining-arguments parameter actually holds, and @($null).Count
  # is 1 - so this MUST-NOT-FIRE twin is the one that keeps the guard from refusing every clean call.
  $nullRes = TryResolve @('a','b') '' $null
  Chk 'CLEAN TWIN an UNBOUND residue ($null, not @()) is not a dropped slug' (-not $nullRes.threw -and @($nullRes.slugs).Count -eq 2) $nullRes.msg
  Chk 'CLEAN TWIN nor is a residue of empty strings'                   (-not (TryResolve @('a') '' @('','  ')).threw) 'refused a blank residue'
  $resid = TryResolve @('a') '' @('b','c')
  Chk 'MUST FIRE  argv residue (the 2026-08-23 -File shape) throws'    $resid.threw ('resolved ' + @($resid.slugs).Count)
  Chk '   and the refusal names the slugs that were dropped'           ($resid.msg -match 'b, c')            $resid.msg
  Chk '   and it names the & call-operator form'                       ($resid.msg -match '&\s+meal-prep')   $resid.msg
  Chk '   and the -SlugFile form'                                      ($resid.msg -match '-SlugFile')       $resid.msg
  $comma = TryResolve @('a,b,c') '' @()
  Chk 'MUST FIRE  a comma-collapsed -Slugs element throws, not splits' $comma.threw ('resolved ' + @($comma.slugs).Count)
  Chk '   and it says how many names collapsed'                        ($comma.msg -match 'list of 3 names') $comma.msg
  Chk 'MUST FIRE  an empty request throws rather than sweeping all'    (TryResolve @() '' @()).threw         'resolved something'
  $ten = TryResolve @('s1','s2','s3','s4','s5','s6','s7','s8','s9','s10') '' @()
  Chk 'CLEAN TWIN a real in-process array of ten resolves to TEN'      (@($ten.slugs).Count -eq 10)          ([string]@($ten.slugs).Count)
  $one = TryResolve @('only-slug') '' @()
  Chk 'CLEAN TWIN one slug through -File (no residue, no comma) runs'  (@($one.slugs).Count -eq 1 -and $one.slugs[0] -eq 'only-slug') (@($one.slugs) -join '|')

  # -SlugFile is the shape that survives `powershell -File`, mirroring propagate's -AllowCreateFile
  $tmpSlugs = Join-Path $env:TEMP ('recost-selftest-slugs-' + $PID + '.txt')
  Set-Content -Path $tmpSlugs -Value "alpha`r`n`r`n  beta  `r`ngamma" -Encoding utf8
  $ff = TryResolve @() $tmpSlugs @()
  Chk 'CLEAN TWIN -SlugFile reads one per line, blanks dropped'        (@($ff.slugs).Count -eq 3)            (@($ff.slugs) -join '|')
  Chk '   and trims, so "  beta  " is not a different slug'            (@($ff.slugs)[1] -eq 'beta')          (@($ff.slugs) -join '|')
  Chk 'MUST FIRE  -Slugs and -SlugFile together throws'                (TryResolve @('a') $tmpSlugs @()).threw 'accepted both'
  Remove-Item $tmpSlugs -Force -ErrorAction SilentlyContinue
  Chk 'MUST FIRE  a -SlugFile that does not exist throws'              (TryResolve @() $tmpSlugs @()).threw  'accepted a missing file'

  # and the header must not go on advertising a call form the guard now refuses
  $selfSrc = Get-Content (Join-Path $here 'recost-spec-cost-block.ps1') -Raw -Encoding utf8
  Chk 'MUST FIRE  the usage header names -SlugFile as the -File form'  ($selfSrc -match ([regex]::Escape('-File .' + [char]92 + 'recost-spec-cost-block.ps1 -SlugFile'))) 'header does not document it'
  Chk 'MUST FIRE  the run prints a requested-vs-recost tally'          ($selfSrc -match 'recost tally: requested') 'no tally line'

  Write-Output ("self-test: " + $(if($fails){ "$fails FAILED" } else { 'all green' }))
  exit $(if($fails){ 1 } else { 0 })
}

# $Residue is the dropped-slug channel: with `powershell -File`, every name past the first lands there.
$req = Resolve-SlugRequest -Slugs $Slugs -SlugFile $SlugFile -Residue $Residue
$slugList = @($req.slugs)
Write-Output ("recost: {0} slug(s) requested via {1}" -f $slugList.Count, $req.source)
$costed = Get-Content (Join-Path $mp 'db\costed.json') -Raw -Encoding utf8 | ConvertFrom-Json
$bySlug = @{}; foreach($r in $costed){ $bySlug[[string]$r.slug] = $r }
$changed = 0; $recost = 0; $noSpec = 0
foreach($slug in $slugList){
  $sp = Join-Path $mp ('db\recipes\' + $slug + '.json')
  if(-not (Test-Path $sp)){ Write-Output ("FAIL  $slug - no spec file"); $noSpec++; continue }
  $row = $bySlug[$slug]
  if(-not $row){ throw ("no costed row for $slug - run engine\cost-recipes.ps1 -Slugs $slug first") }
  $r = Invoke-RecostSpec $sp $row ([bool]$Apply)
  $recost++
  if($r.changed){ $changed++ }
  Write-Output ("{0}  {1}  batch=`${2} true=`${3} ({4} cost lines)" -f $(if($Apply){'APPLIED'}else{'DRY    '}), $slug, $r.batch, $r.trueC, $r.lines)
}
Write-Output ("{0} spec(s) would change" -f $changed)
# THE TALLY. "1 spec(s) would change" reads identically whether one slug was asked for or ten were and
# nine were lost; requested-vs-processed is the number that cannot. Printed on every run, loud when short.
Write-Output ("recost tally: requested {0} | recost {1} | changed {2} | no spec {3}" -f $slugList.Count, $recost, $changed, $noSpec)
if($recost -ne $slugList.Count){
  Write-Output ("UNDER-APPLY: {0} of {1} requested slug(s) were NOT recost - this run did less than it was asked for." -f ($slugList.Count - $recost), $slugList.Count)
}
if(-not $Apply){ Write-Output 'dry run - pass -Apply to write' }
