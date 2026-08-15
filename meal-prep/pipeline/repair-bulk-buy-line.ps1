<#
  repair-bulk-buy-line.ps1 - bring the BUY SENTENCE on a bulk cost line into agreement with the package
  the recipe actually needs. Text only: it never touches a dollar figure.

  WHAT IT REPAIRS. Two shapes, both of them the same sentence going stale in different directions:

    OVERCLAIM  "Buy 1 (lasts several batches)" on a package that covers fewer than three batches. Until
               2026-08-15 cost-render-lib printed that string as a CONSTANT for every bulk line with
               starter_n under 2, never comparing package size to the amount used. 537 of the 1628 live
               lines sit under three batches (342 recipes). country-captain-chicken is the founding case:
               its cost line called the raisin box a several-batch box while its own shop_smart paragraph
               said "Not several batches". The lib is fixed; this carries the fix to specs already written.

    BUY-COUNT  "Buy 1" where db\costed.json now says starter_n >= 2 - the recipe needs two to four
               packages and the line tells the shopper to buy one. 52 lines, 45 recipes. These are frozen
               renders: the spec's cost block is a snapshot, and the item's pantry package was redefined
               under it afterwards. green-chile-ground-turkey-skillet is the worst - its own line reads
               "Diced Green Chiles, 3.5 cans: ... Buy 1", three and a half cans and buy one, in one sentence.

  WHY NOT recost-spec-cost-block. That script re-renders the whole block from TODAY's costed.json, which
  rewrites every dollar figure on the card because the board moved - its own header calls that "a price
  update wearing a repair's clothes" and makes -Slugs mandatory to prevent it. Measured 2026-08-15: 539 of
  544 specs disagree with today's engine on cost_batch, by up to $14.68. A wording repair must not smuggle
  a catalogue-wide price change in behind it, so this script derives the sentence from the spec's OWN
  frozen grams and changes nothing else. Every cost_* number, and every printed ~$, is left exactly as is.

  SCOPED TO THE cost_lines ARRAY, deliberately. Two live specs say "lasts several batches" in hand-written
  shop_smart prose (mississippi-pot-roast-bowls' pepperoncini jar, beef-chow-mein-noodles' oyster sauce).
  A file-wide string replace would rewrite a writer's paragraph as a side effect of a data repair, so every
  edit here is confined to one element span of one array, found with lib\json-db-io.ps1's scanners.
  SPEC-SCHEMA.md forbids ConvertFrom-Json | ConvertTo-Json on a spec (the prose carries \uXXXX escapes and
  the round trip rewrites them); the substrings this script swaps are plain ASCII, so no escape moves.

  The thresholds and the wording live in cost-render-lib.ps1 (Get-BulkCoverageWords), dot-sourced here so
  the repair and the renderer cannot disagree about what a package covers.

  Usage: .\repair-bulk-buy-line.ps1 [-Slugs a,b] [-Apply]      (default is a dry run over the catalogue)
         .\repair-bulk-buy-line.ps1 -SelfTest
#>
param(
  [string[]]$Slugs,
  [switch]$Apply,
  [switch]$SelfTest,
  [string]$Root = ""
)
$ErrorActionPreference='Stop'
$here = if($PSScriptRoot){ $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$mp   = if($Root){ $Root } else { Split-Path -Parent $here }
. (Join-Path $mp 'lib\json-db-io.ps1')
. (Join-Path $here 'cost-render-lib.ps1')

$script:BLANKET = 'Buy 1 (lasts several batches).'

function Get-BulkLineRepair {
  <#
    The replacement sentence for ONE cost line, or $null when the line is already right.
      $Raw : the line as stored (may carry <strong> escapes - never decoded, only searched)
      $Cl  : its db\costed.json row
      $Grams : the grams the SPEC states for it
    Returns @{ old; new; why; cls }.
  #>
  param([string]$Raw,$Cl,[double]$Grams)
  if($Raw -notmatch [regex]::Escape($script:BLANKET)){ return $null }
  if($null -eq $Cl -or $Grams -le 0){ return $null }
  $pkg = $Cl.starter_pkg_g
  if($null -eq $pkg -or [double]$pkg -le 0){ return $null }   # no package definition = no ratio to state
  $stn = if($null -ne $Cl.starter_n){ [int]$Cl.starter_n } else { 1 }

  if($stn -ge 2 -and $Cl.starter_pkg){
    # BUY-COUNT: the engine wants more than one package. This is the multi-pack sentence the renderer
    # would print today, byte for byte - see cost-render-lib's starter_n >= 2 branch.
    $new = 'Pantry staple; this batch alone uses about ' + $stn + ' ' + (Get-CostPlural ([string]$Cl.starter_pkg) $stn) + '.'
    return @{ old=$script:BLANKET; new=$new; cls='BUY-COUNT'; why=("engine wants " + $stn + " " + [string]$Cl.starter_pkg + ", line says buy 1") }
  }
  $cov = [double]$pkg / $Grams
  $words = Get-BulkCoverageWords $cov
  if($words -eq 'lasts several batches'){ return $null }      # >= 3 batches: the sentence is fair, leave it
  $new = 'Buy 1 (' + $words + ').'
  return @{ old=$script:BLANKET; new=$new; cls='OVERCLAIM'; why=("one " + [string]$Cl.starter_pkg + " covers " + $cov.ToString('0.00') + " batches") }
}

function Invoke-RepairSpec {
  param([string]$SpecPath,$CostRow,[bool]$DoApply)
  $io = Read-SpecText -Path $SpecPath
  $spec = $io.Text | ConvertFrom-Json
  $byItem=@{}; foreach($l in @($CostRow.lines)){ $byItem[[string]$l.item]=$l }
  # display name -> {canon, grams}. Specs written before the r300 convention omit `canon` when it equals
  # `item` (al-pastor's Rice row), so a missing canon falls back to item rather than matching nothing.
  $disp=@{}
  foreach($se in @($spec.scaler.ing)){
    $nm=[string]$se.item; if(-not $nm){ continue }
    $canon = if(($se.PSObject.Properties.Name -contains 'canon') -and $se.canon){ [string]$se.canon } else { $nm }
    $disp[$nm]=@{ canon=$canon; grams=[double]$se.grams }
  }
  $at = Find-JsonValueStart -Raw $io.Text -Key 'cost_lines'
  if($at -lt 0){ return @{ changed=$false; edits=@() } }
  $spans = @(Get-JsonArraySpans -Raw $io.Text -OpenIndex $at)
  $edits=@()
  $t = $io.Text
  # RIGHT TO LEFT so that every span index stays valid: an edit changes the length of the text after it.
  for($i=$spans.Count-1; $i -ge 0; $i--){
    $s=$spans[$i]
    $raw = $t.Substring($s.Start, $s.End - $s.Start + 1)
    if($raw -notmatch [regex]::Escape($script:BLANKET)){ continue }
    # "<display name>, <amount>: ~$<util>." - the name is everything before the FIRST comma
    $nm = $null
    $m = [regex]::Match($raw, '^"([^,]+),\s')
    if($m.Success){ $nm = $m.Groups[1].Value }
    if(-not $nm -or -not $disp.ContainsKey($nm)){ continue }
    $canon = $disp[$nm].canon
    $cl = if($byItem.ContainsKey($canon)){ $byItem[$canon] } else { $null }
    $rep = Get-BulkLineRepair -Raw $raw -Cl $cl -Grams $disp[$nm].grams
    if(-not $rep){ continue }
    $newRaw = $raw.Replace($rep.old, $rep.new)
    if($newRaw -eq $raw){ continue }
    $t = $t.Substring(0,$s.Start) + $newRaw + $t.Substring($s.End + 1)
    $edits += [pscustomobject]@{ item=$nm; cls=$rep.cls; why=$rep.why; new=$rep.new }
  }
  $changed = ($t -ne $io.Text)
  if($changed){
    $null = $t | ConvertFrom-Json                              # the result must still parse, dry run or not
    if($DoApply){ Write-SpecText -Path $SpecPath -Text $t -Bom $io.Bom }
  }
  return @{ changed=$changed; edits=$edits }
}

# ---------------------------------------------------------------------------------------------------
if($SelfTest){
  $fails=0
  function Chk([string]$n,[bool]$ok,[string]$got){
    if($ok){ Write-Output ("  ok   " + $n) } else { $script:fails++; Write-Output ("  FAIL " + $n + " -> " + $got) }
  }
  Write-Output 'repair-bulk-buy-line self-test'

  # FROZEN FIXTURES - every row below is copied from a real spec measured on 2026-08-15, and never read
  # from db\costed.json, per the guard-fixture rule. A fixture that reads live data stops testing the bug
  # the day the data moves.

  # MUST FIRE 1 - green-chile-ground-turkey-skillet: 396 g of chiles from a 113 g can, engine says 4 cans,
  # the line says buy 1. The spec's own amount ("3.5 cans") already contradicts its own instruction.
  $chiles = [pscustomobject]@{ item='Diced Green Chiles'; grams=396; util_cost=2.67; bulk=$true
                               starter_n=4; starter_pkg='4oz can'; starter_pkg_g=113 }
  $r1 = Get-BulkLineRepair -Raw ('"Diced Green Chiles, 3.5 cans: ~$5.13. <strong>' + $script:BLANKET + '</strong>"') -Cl $chiles -Grams 396
  Chk 'MUST FIRE  BUY-COUNT  3.5 cans but "Buy 1"' ($null -ne $r1 -and $r1.cls -eq 'BUY-COUNT') $(if($r1){$r1.cls}else{'no finding'})
  Chk 'MUST FIRE  BUY-COUNT  pluralises the package' ($null -ne $r1 -and $r1.new -eq 'Pantry staple; this batch alone uses about 4 4oz cans.') $(if($r1){$r1.new}else{''})

  # MUST FIRE 2 - country-captain-chicken's golden raisins: the line said "lasts several batches" while the
  # SAME SPEC's shop_smart said "Not several batches, but the box is not a one-and-done either". 1.88 batches.
  $raisins = [pscustomobject]@{ item='Golden Raisins'; grams=170; util_cost=2.64; bulk=$true
                                starter_n=1; starter_pkg='box'; starter_pkg_g=320 }
  $r2 = Get-BulkLineRepair -Raw ('"Golden Raisins, 1.25 cups: ~$2.64. ' + $script:BLANKET + '"') -Cl $raisins -Grams 170
  Chk 'MUST FIRE  OVERCLAIM  1.88 batches is not "several"' ($null -ne $r2 -and $r2.cls -eq 'OVERCLAIM') $(if($r2){$r2.cls}else{'no finding'})
  Chk 'MUST FIRE  OVERCLAIM  says what the box covers'      ($null -ne $r2 -and $r2.new -eq 'Buy 1 (covers about two batches).') $(if($r2){$r2.new}else{''})

  # MUST FIRE 3 - slow-cooker-beef-and-noodles: 924 g of broth from a 907 g carton. The 2% engine tolerance
  # keeps starter_n at 1, so this stays a "Buy 1" line - but it covers ONE batch, not several.
  $broth = [pscustomobject]@{ item='Beef Broth'; grams=924; util_cost=1.24; bulk=$true
                              starter_n=1; starter_pkg='32oz carton'; starter_pkg_g=907 }
  $r3 = Get-BulkLineRepair -Raw ('"Beef Broth, 3.75 cups: ~$1.24. ' + $script:BLANKET + '"') -Cl $broth -Grams 924
  Chk 'MUST FIRE  OVERCLAIM  a 0.98-batch carton is one batch' ($null -ne $r3 -and $r3.new -eq 'Buy 1 (covers this batch).') $(if($r3){$r3.new}else{'no finding'})

  # CLEAN TWIN - the same sentence on a package that really does last several batches must not move. Soy
  # sauce, 30 g from a 444 g bottle: 14.8 batches.
  $soy = [pscustomobject]@{ item='Soy Sauce'; grams=30; util_cost=0.18; bulk=$true
                            starter_n=1; starter_pkg='bottle'; starter_pkg_g=444 }
  $r4 = Get-BulkLineRepair -Raw ('"Soy Sauce, 2 tbsp: ~$0.18. ' + $script:BLANKET + '"') -Cl $soy -Grams 30
  Chk 'CLEAN TWIN 14.8 batches IS several - untouched' ($null -eq $r4) $(if($r4){$r4.new}else{'null'})

  # CLEAN TWIN - a bulk row with no pantry package definition has no ratio to state, so the vague sentence
  # is the honest one. Inventing a coverage number from a missing package is worse than saying little.
  $nodef = [pscustomobject]@{ item='Mystery Paste'; grams=100; util_cost=0.50; bulk=$true
                              starter_n=$null; starter_pkg=$null; starter_pkg_g=$null }
  $r5 = Get-BulkLineRepair -Raw ('"Mystery Paste, 1 tbsp: ~$0.50. ' + $script:BLANKET + '"') -Cl $nodef -Grams 100
  Chk 'CLEAN TWIN no package def - left alone' ($null -eq $r5) $(if($r5){$r5.new}else{'null'})

  # CLEAN TWIN - a NON-bulk line never carries this sentence, and must not be rewritten if it somehow does
  # not match the blanket exactly. "Buy 2 lbs: $4.00" is a different shape entirely.
  $r6 = Get-BulkLineRepair -Raw '"Pork Loin, 3.75 lb: ~$12.48. Buy 6 lbs: $12.84."' -Cl $soy -Grams 1700
  Chk 'CLEAN TWIN a real buy line is not the blanket' ($null -eq $r6) $(if($r6){$r6.new}else{'null'})

  # THE SCOPE GUARD - the founding reason this edits array spans and not the whole file. A spec whose
  # shop_smart says the same words in a writer's sentence must keep them; only the cost line moves.
  $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('rbbl-' + [guid]::NewGuid().ToString('N') + '.json')
  $fixture = @'
{
    "slug":  "fixture",
    "cost_lines":  [
                       "Golden Raisins, 1.25 cups: ~$2.64. Buy 1 (lasts several batches).",
                       "Pork Loin, 3.75 lb: ~$12.48. Buy 6 lbs: $12.84."
                   ],
    "shop_smart":  [
                       "A jar of pepperoncini lasts several batches and the brine is half the flavor."
                   ],
    "scaler":  {
                   "ing":  [
                               { "item": "Golden Raisins", "grams": 170, "buy": "1.25 cups" }
                           ]
               }
}
'@
  Set-Content -Path $tmp -Value $fixture -Encoding UTF8
  $row = [pscustomobject]@{ lines=@($raisins) }
  $res = Invoke-RepairSpec $tmp $row $true
  $after = Get-Content $tmp -Raw
  Chk 'the cost line was rewritten'            ($after -match 'covers about two batches')                    'not rewritten'
  Chk 'MUST NOT TOUCH shop_smart keeps "lasts several batches"' ($after -match 'pepperoncini lasts several batches') 'writer prose was rewritten'
  Chk 'the non-bulk buy line is untouched'     ($after -match 'Buy 6 lbs: \$12\.84\.')                       'buy line moved'
  Chk 'the file still parses'                  ($null -ne ($after | ConvertFrom-Json))                       'unparseable'
  Chk 'no dollar figure changed'               ($after -match '~\$2\.64\.')                                  'a printed cost moved'
  Remove-Item $tmp -Force -ErrorAction SilentlyContinue

  Write-Output ("self-test: " + $(if($fails){ "$fails FAILED" } else { 'all green' }))
  exit $(if($fails){ 1 } else { 0 })
}

$costed = Get-Content (Join-Path $mp 'db\costed.json') -Raw -Encoding utf8 | ConvertFrom-Json
$bySlug=@{}; foreach($r in $costed){ $bySlug[[string]$r.slug]=$r }
$targets = if($Slugs -and $Slugs.Count -gt 0){ $Slugs } else { @(Get-ChildItem (Join-Path $mp 'db\recipes\*.json') | Where-Object { $_.Name -notmatch '^(run-|recipes-)' -and $_.Name -ne '_index.json' } | ForEach-Object { $_.BaseName }) }
$nSpec=0; $nEdit=0; $byCls=@{}
foreach($slug in $targets){
  $sp = Join-Path $mp ('db\recipes\' + $slug + '.json')
  if(-not (Test-Path $sp)){ Write-Output ("FAIL  $slug - no spec file"); continue }
  $row = $bySlug[$slug]
  if(-not $row){ Write-Output ("SKIP  $slug - no costed row"); continue }
  $r = Invoke-RepairSpec $sp $row ([bool]$Apply)
  if(-not $r.changed){ continue }
  $nSpec++; $nEdit += @($r.edits).Count
  foreach($e in $r.edits){ $byCls[$e.cls] = 1 + [int]$byCls[$e.cls] }
  Write-Output ("{0}  {1}" -f $(if($Apply){'APPLIED'}else{'DRY    '}), $slug)
  foreach($e in $r.edits){ Write-Output ("           [{0}] {1,-24} {2}" -f $e.cls,$e.item,$e.why) }
}
Write-Output ''
Write-Output ("{0} line(s) across {1} spec(s)" -f $nEdit,$nSpec)
foreach($k in ($byCls.Keys | Sort-Object)){ Write-Output ("  {0,-10} {1}" -f $k,$byCls[$k]) }
if(-not $Apply){ Write-Output 'dry run - pass -Apply to write' }

