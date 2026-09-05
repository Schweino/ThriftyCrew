<#
  promote-verdicts.ps1 - turn the semantic verify pass's DROP verdicts into PERMANENT commodity excludes.

  *** WHY THIS EXISTS ***
  The verify pass never converged. Across the first six weekly verdict files there are 81 DROP verdicts and
  14 of them are REPEATS - the same commodity+store judged wrong in more than one week (broccoli|Sam's Club
  and apples|Family Fare were each dropped THREE separate weeks). So every week an LLM re-derived the same
  judgment, and in any week the run was rushed or unattended the wrong product published. It did publish:
  price-history.json holds `record_low` entries banked from those wrong winners (strawberries $0.0833 from
  "Kroger Strawberry Applesauce", honey $0.1244 from "Kroger Rich N Honey Hot Dog Buns").

  A judgment that has to be re-made every week is not a rule. This promotes each DROP into a rule, so the
  wrong product dies once and the weekly pass only judges genuinely NEW entrants - the job shrinks instead
  of repeating, and an unattended run stops being dangerous.

  *** HOW A NAME BECOMES A RULE (and why it is gated) ***
  A verdict names the commodity and the STORE, not the offending product, so the item name is looked up in
  that week's comparison-<week>.json. From the name we look for a token (bigram preferred - "cold brew"
  beats "brew") that is present in the DROPPED item and present in NO item we ever KEPT for that commodity.
  That last condition is the whole safety story: a rule is only written if it provably cannot kill a product
  the board legitimately carries. Candidates that collide with the commodity's own include patterns or its
  label are refused outright - excluding "strawberry" from strawberries would delete the row.

  If no safe token exists, the verdict is NOT promoted and is reported as still needing weekly judgment.
  That is the honest outcome for a combined "A or B" ad line, where the problem is the source data rather
  than the product's identity.

  Provenance lives in exclude-provenance.json (never inside commodities.json, which the engine reads), so
  every promoted rule can be traced to the week, verdict and item that produced it - and reverted.

  ALWAYS re-run compare-deals afterwards and check store coverage did not fall. -Apply prints the command.

  Usage: .\promote-verdicts.ps1            # dry run, shows what it would write
         .\promote-verdicts.ps1 -Apply
         .\promote-verdicts.ps1 -SelfTest
#>
param(
  [switch]$Apply,
  [switch]$SelfTest,
  [string]$OutDir = "",
  # Apply only these commodity ids. The gates make a rule SAFE against everything we have ever seen, but they
  # cannot know a product that has not appeared yet - "applewood smoked" is a real bacon descriptor even
  # though no kept bacon row has said it. So the mechanical pass proposes and a human picks.
  [string[]]$Ids = @()
)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
$root = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\grocery' }
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }

# Words that can never carry product identity on their own. Brand names are deliberately NOT here: a brand
# token is normally rejected anyway because it also appears on items we keep.
$STOP = @(
  'the','and','or','with','for','in','of','a','an','to','per','each','ea','ct','count','pk','pack','oz','lb',
  'lbs','fl','gal','qt','pt','ml','g','kg','size','pack','value','family','great','simple','truth','our','my',
  'new','free','style','original','classic','premium','select','selection','fresh','natural','all','no','plus',
  'best','good','real','pure','extra','super','ultra','mini','big','large','small','medium','jumbo','deal',
  'save','price','sale','bag','box','jar','can','bottle','carton','container','piece','pieces','sliced','slice',
  'whole','cut','chopped','ground','light','dark','white','black','red','green','blue','yellow','sweet','hot',
  'mild','plain','made','from','by','it','is','are','was','this','that','more','less','low','high','non','usda'
)

function Get-Tokens([string]$name) {
  $s = ($name.ToLower() -replace '[^a-z0-9 ]', ' ') -replace '\s+', ' '
  $w = @($s.Trim().Split(' ') | Where-Object { $_.Length -ge 3 -and $_ -notmatch '^\d+$' })
  $uni = @($w | Where-Object { $STOP -notcontains $_ })
  $bi = New-Object System.Collections.ArrayList
  for ($i = 0; $i -lt $w.Count - 1; $i++) {
    $a = $w[$i]; $b = $w[$i + 1]
    # a bigram is useful even when one half is a stopword ("cold brew", "hot dog"); refuse only all-stopword pairs
    if (($STOP -contains $a) -and ($STOP -contains $b)) { continue }
    [void]$bi.Add("$a $b")
  }
  return @{ uni = $uni; bi = @($bi.ToArray()) }
}

function New-Pattern([string]$token) {
  # Tolerate singular AND plural, whichever way the token arrived. `\bbun\b` vs "Buns" is exactly how a rule
  # that EXISTS still fails to fire - it silently missed a wrong product for weeks. Words ending in "ss"
  # (molasses, grass) have no plural to fold, so they are left alone rather than shortened to a stem.
  $parts = $token.Split(' ')
  $out = New-Object System.Collections.ArrayList
  for ($i = 0; $i -lt $parts.Count; $i++) {
    $w = $parts[$i]
    if ($i -lt $parts.Count - 1) { [void]$out.Add([regex]::Escape($w)); continue }   # only the last word inflects
    if ($w -match 'ss$') { [void]$out.Add([regex]::Escape($w)) }
    elseif ($w -match 's$' -and $w.Length -ge 4) { [void]$out.Add([regex]::Escape($w.Substring(0, $w.Length - 1)) + 's?') }
    else { [void]$out.Add([regex]::Escape($w) + 's?') }
  }
  return ('\b' + (($out.ToArray()) -join '\s+') + '\b')
}

function Get-IdentityStems([object]$commodity) {
  # Every way this commodity names ITSELF: the id, the label, and the literal runs inside its include
  # patterns. A rule built out of one of these words does not describe the intruder, it describes the row.
  $words = New-Object System.Collections.ArrayList
  foreach ($w in ([string]$commodity.id -split '-')) { if ($w.Length -ge 4) { [void]$words.Add($w.ToLower()) } }
  foreach ($w in (([string]$commodity.label).ToLower() -split '[^a-z]+')) { if ($w.Length -ge 4) { [void]$words.Add($w) } }
  foreach ($inc in @($commodity.include)) {
    foreach ($w in (([string]$inc).ToLower() -split '[^a-z]+')) { if ($w.Length -ge 4 -and $w -ne 'bslash') { [void]$words.Add($w) } }
  }
  return @($words.ToArray() | Sort-Object -Unique)
}

function Test-Safe([string]$pattern, [string]$token, [string]$dropped, [string[]]$kept, [object]$commodity, [string[]]$stems) {
  if ($dropped -notmatch $pattern) { return 'does not match the item it came from' }

  # A SINGLE word that is the commodity's own identity is catastrophic: promoting \bstrawberrys?\b onto
  # strawberries would delete every "Strawberry ..." product on the row. A BIGRAM containing that word is
  # fine - "dole pineapple" only kills Dole's pineapple, because the other half constrains it.
  if ($token -notmatch ' ') {
    $t = $token.ToLower()
    foreach ($s in $stems) {
      $n = [Math]::Min(5, [Math]::Min($t.Length, $s.Length))
      if ($n -ge 4 -and $t.Substring(0, $n) -eq $s.Substring(0, $n)) { return ("is the commodity's own word ('$s')") }
    }
  }
  if (([string]$commodity.label) -match $pattern) { return 'matches the commodity label' }
  foreach ($k in $kept) { if ($k -match $pattern) { return ("would also kill kept item: " + $k) } }
  return ''
}

if ($SelfTest) {
  $fail = 0
  $cm = [pscustomobject]@{ id = 'honey'; label = 'Honey'; include = @('\bhoney\b'); exclude = @('\bbun\b') }
  $p = New-Pattern 'buns'
  if ('Kroger Rich N Honey Hot Dog Buns' -match $p) { Write-Output "ok    plural-tolerant pattern matches 'Buns'" } else { Write-Output "FAIL  plural pattern"; $fail++ }
  if ('Kroger Rich N Honey Hot Dog Bun' -match $p)  { Write-Output "ok    ...and still matches the singular" } else { Write-Output "FAIL  singular"; $fail++ }
  $hStems = Get-IdentityStems $cm
  $r = Test-Safe $p 'buns' 'Kroger Rich N Honey Hot Dog Buns' @('Kroger Clover Honey 12 oz','Local Raw Honey') $cm $hStems
  if ($r -eq '') { Write-Output "ok    'buns' is safe for honey (no kept honey item says buns)" } else { Write-Output "FAIL  expected safe, got: $r"; $fail++ }
  $r2 = Test-Safe (New-Pattern 'honey') 'honey' 'Kroger Rich N Honey Hot Dog Buns' @('Kroger Clover Honey 12 oz') $cm $hStems
  if ($r2 -ne '') { Write-Output "ok    'honey' is refused for honey ($r2)" } else { Write-Output "FAIL  should have refused the commodity's own word"; $fail++ }

  # the catastrophic case this guard exists for: a UNIGRAM equal to the row's own identity
  $cmS = [pscustomobject]@{ id='strawberries'; label='Strawberries'; include=@('strawberr'); exclude=@() }
  $sStems = Get-IdentityStems $cmS
  $rs = Test-Safe (New-Pattern 'strawberry') 'strawberry' 'Kroger Strawberry Applesauce' @('Fresh Strawberries 1 lb') $cmS $sStems
  if ($rs -ne '') { Write-Output "ok    unigram 'strawberry' refused on strawberries ($rs)" } else { Write-Output "FAIL  would have deleted the strawberries row"; $fail++ }
  # ...but a BIGRAM containing it is fine, because the other half constrains it
  $rb = Test-Safe (New-Pattern 'kroger strawberry') 'kroger strawberry' 'Kroger Strawberry Applesauce' @('Fresh Strawberries 1 lb') $cmS $sStems
  if ($rb -eq '') { Write-Output "ok    bigram 'kroger strawberry' allowed (constrained by the brand half)" } else { Write-Output "FAIL  bigram should be allowed, got: $rb"; $fail++ }

  $t = Get-Tokens 'Stok Cold Brew Coffee Black Unsweetened 48 FL OZ'
  if ($t.bi -contains 'cold brew') { Write-Output "ok    bigram 'cold brew' is offered" } else { Write-Output "FAIL  missing bigram"; $fail++ }
  $cm2 = [pscustomobject]@{ id='coffee'; label='Coffee (ground/beans)'; include=@('\bcoffee\b'); exclude=@() }
  $r3 = Test-Safe (New-Pattern 'cold brew') 'cold brew' 'Stok Cold Brew Coffee Black Unsweetened 48 FL OZ' @('Folgers Classic Roast Ground Coffee','Kroger Cold Brew Coffee Concentrate') $cm2 (Get-IdentityStems $cm2)
  if ($r3 -ne '') { Write-Output "ok    refused because a KEPT coffee item also says cold brew ($r3)" } else { Write-Output "FAIL  should have refused on kept-item collision"; $fail++ }
  if ($fail) { Write-Output "$fail FAILED"; exit 1 } else { Write-Output 'all self-tests pass'; exit 0 }
}

# ---------------- load history: every verdict file + the board it judged ----------------
$vFiles = @(Get-ChildItem (Join-Path $OutDir 'verify-verdicts-*.json') | Sort-Object Name)
if ($vFiles.Count -eq 0) { throw 'promote-verdicts: no verify-verdicts-*.json found' }

$drops = New-Object System.Collections.ArrayList     # {week,id,store,item,reason}
$keptNames = @{}                                      # id -> ArrayList of names we did NOT drop
foreach ($vf in $vFiles) {
  $vj = Read-JsonFile $vf.FullName
  $week = [string]$vj.week_of
  $cmpPath = Join-Path $OutDir ("comparison-$week.json")
  if (-not (Test-Path $cmpPath)) { Write-Output ("  (skipping $($vf.Name) - no comparison-$week.json to resolve item names)"); continue }
  $cj = Read-JsonFile $cmpPath

  if (-not (Test-Path variable:script:staleSkipped)) { $script:staleSkipped = 0 }
  $dropSet = @{}
  foreach ($c in @($vj.verdicts)) { foreach ($e in @($c.entries)) { if ($e.keep -eq $false) { $dropSet[("$($c.id)|$($e.store)")] = [string]$e.reason } } }

  foreach ($row in @($cj.comparison)) {
    foreach ($s in @($row.stores)) {
      $key = "$($row.id)|$($s.store)"
      if ($dropSet.ContainsKey($key)) {
        # STALENESS GATE. A verdict is keyed only by (id|store), and every comparison-<week>.json is rebuilt
        # AFTER its verdict file - so the item sitting in that cell now may be the REPLACEMENT product, not the
        # one the pass judged. Measured 2026-07-29: 16 of 74 verdicts had drifted, and 6 of 13 proposed rules
        # were built from the CORRECT product (Aldi's only ground coffee, Hy-Vee's cheese tortellini and queso,
        # Baker's strawberries). Applying them would have permanently deleted real products, silently, because
        # excludes never report what they removed - which voids the whole "provably cannot kill a legitimate
        # product" promise this script is built on.
        # The verdict reason quotes the judged item in 16 of 16 drift cases, so use it as the witness: if the
        # reason names a product and the cell now holds a different one, refuse and say so.
        $reason = [string]$dropSet[$key]
        $nowItem = [string]$s.item
        $quoted = [regex]::Match($reason, "['" + [char]0x2018 + [char]0x201C + '"]([^' + "'" + [char]0x2019 + [char]0x201D + '"]{6,})[' + "'" + [char]0x2019 + [char]0x201D + '"]')
        $stale = $false
        if ($quoted.Success) {
          $judged = $quoted.Groups[1].Value.Trim()
          # compare on shared significant words - store feeds re-title the same product constantly
          # The commodity's OWN words are not evidence that two products are the same: "Stok Cold Brew Coffee"
          # and "Beaumont Medium Classic Roast Coffee" share only the word "coffee", which every item on the
          # row carries by construction. Strip the row's own vocabulary before comparing.
          $own = @{}
          foreach ($w in (([string]$row.id + ' ' + [string]$row.commodity).ToLower() -replace '[^a-z0-9 ]', ' ') -split '\s+') {
            if ($w.Length -ge 4) { $own[$w] = $true; if ($w.EndsWith('s')) { $own[$w.Substring(0, $w.Length - 1)] = $true } else { $own[$w + 's'] = $true } }
          }
          $jw = @(($judged.ToLower() -replace '[^a-z0-9 ]', ' ') -split '\s+' | Where-Object { $_.Length -ge 4 -and -not $own.ContainsKey($_) })
          $nw = @(($nowItem.ToLower() -replace '[^a-z0-9 ]', ' ') -split '\s+' | Where-Object { $_.Length -ge 4 -and -not $own.ContainsKey($_) })
          if ($jw.Count -ge 2 -and $nw.Count -ge 1) {
            $shared = @($jw | Where-Object { $nw -contains $_ }).Count
            if ($shared -eq 0) { $stale = $true }
          }
          if ($stale) {
            Write-Output ("  STALE [$week $($row.id)|$($s.store)] verdict judged '{0}' but the cell now holds '{1}' - NOT promoting" -f $judged, $nowItem)
            $script:staleSkipped++
            continue
          }
        }
        [void]$drops.Add([pscustomobject]@{ week = $week; id = $row.id; store = $s.store; item = $nowItem; reason = $reason })
      } else {
        if (-not $keptNames.ContainsKey($row.id)) { $keptNames[$row.id] = New-Object System.Collections.ArrayList }
        [void]$keptNames[$row.id].Add([string]$s.item)
      }
    }
  }
}
Write-Output ("verdict files read : {0}   DROP verdicts resolved to an item name : {1}" -f $vFiles.Count, $drops.Count)

$cPath = Join-Path $root 'commodities.json'
# -Encoding UTF8 is load-bearing on any read that gets written back: PS 5.1's Get-Content defaults to the
# ANSI codepage, so a UTF-8 label round-trips to mojibake and the file grows every time. That is how
# creme-fraiche's label reached 4,639 characters (proved 2026-08-31: a 38-byte file came back 67 bytes).
$commodities = Get-Content $cPath -Raw -Encoding UTF8 | ConvertFrom-Json

# ---------------- derive one rule per commodity, covering as many of its drops as possible ----------------
$proposals = New-Object System.Collections.ArrayList
$unpromotable = New-Object System.Collections.ArrayList
$byId = $drops | Group-Object id

foreach ($g in $byId) {
  $id = $g.Name
  $cm = $commodities | Where-Object { $_.id -eq $id }
  if (-not $cm) { continue }
  $kept = if ($keptNames.ContainsKey($id)) { @($keptNames[$id].ToArray() | Sort-Object -Unique) } else { @() }
  $existing = @($cm.exclude)

  $stems = Get-IdentityStems $cm

  $remaining = New-Object System.Collections.ArrayList
  foreach ($d in @($g.Group)) { if (-not (@($existing | Where-Object { $d.item -match $_ }).Count)) { [void]$remaining.Add($d) } }
  if ($remaining.Count -eq 0) { continue }   # already covered by a rule that exists

  # Keep proposing rules for this commodity until every dropped item is covered or nothing safe is left.
  # One-rule-per-commodity used to leave the rest silently unpromoted, which is how a commodity with two
  # different intruders kept one of them forever.
  $guard = 0
  while ($remaining.Count -gt 0 -and $guard -lt 6) {
    $guard++
    $cand = @{}
    foreach ($d in @($remaining.ToArray())) {
      $t = Get-Tokens $d.item
      foreach ($tok in (@($t.bi) + @($t.uni))) { if (-not $cand.ContainsKey($tok)) { $cand[$tok] = 0 } }
    }
    $scored = New-Object System.Collections.ArrayList
    foreach ($tok in $cand.Keys) {
      $pat = New-Pattern $tok
      $why = ''
      foreach ($d in @($remaining.ToArray())) {
        if ($d.item -match $pat) { $why = Test-Safe $pat $tok $d.item $kept $cm $stems; if ($why) { break } }
      }
      if ($why) { continue }
      $covers = @($remaining.ToArray() | Where-Object { $_.item -match $pat }).Count
      if ($covers -lt 1) { continue }
      $isBi = if ($tok -match ' ') { 1 } else { 0 }
      [void]$scored.Add([pscustomobject]@{ token = $tok; pattern = $pat; covers = $covers; bigram = $isBi })
    }
    if ($scored.Count -eq 0) {
      foreach ($d in @($remaining.ToArray())) { [void]$unpromotable.Add($d) }
      break
    }
    $best = @($scored.ToArray() | Sort-Object @{e='covers';Descending=$true}, @{e='bigram';Descending=$true}, @{e='token'})[0]
    $covered = @($remaining.ToArray() | Where-Object { $_.item -match $best.pattern })
    [void]$proposals.Add([pscustomobject]@{
      id = $id; label = [string]$cm.label; pattern = $best.pattern; token = $best.token
      covers = $covered.Count; items = @($covered | ForEach-Object { $_.item } | Sort-Object -Unique)
      weeks = @($covered | ForEach-Object { $_.week } | Sort-Object -Unique)
      reason = [string]$covered[0].reason
    })
    $left = @($remaining.ToArray() | Where-Object { $_.item -notmatch $best.pattern })
    $remaining = New-Object System.Collections.ArrayList
    foreach ($d in $left) { [void]$remaining.Add($d) }
  }
}

Write-Output ''
Write-Output ("PROPOSED RULES: {0}  (covering {1} drop verdict(s))" -f $proposals.Count, (@($proposals.ToArray() | Measure-Object covers -Sum).Sum))
foreach ($p in @($proposals.ToArray() | Sort-Object id)) {
  Write-Output ("  {0,-24} {1,-26} kills {2}  [weeks {3}]" -f $p.id, $p.pattern, $p.covers, ($p.weeks -join ','))
  foreach ($i in $p.items) { Write-Output ("        - $i") }
}
if ($unpromotable.Count) {
  Write-Output ''
  Write-Output ("NOT PROMOTABLE (no token is safe - these stay a weekly judgment): {0}" -f $unpromotable.Count)
  foreach ($d in @($unpromotable.ToArray() | Sort-Object id)) { Write-Output ("  {0,-24} {1,-12} {2}" -f $d.id, $d.store, $d.item) }
}

if (-not $Apply) { Write-Output ''; Write-Output 'DRY RUN. Pass -Apply to write commodities.json + exclude-provenance.json.'; exit 0 }

# ---------------- write ----------------
Copy-Item $cPath (Join-Path $OutDir 'commodities.backup-before-promote.json') -Force
$provPath = Join-Path $root 'exclude-provenance.json'
if (Test-Path $provPath) { $prov = Read-JsonFile $provPath } else { $prov = [pscustomobject]@{ readme = ''; rules = @() } }
$provRules = New-Object System.Collections.ArrayList
foreach ($r in @($prov.rules)) { [void]$provRules.Add($r) }

$stamp = (Get-Date -Format 'yyyy-MM-dd')
$written = 0
# -Ids entries are "<id>" (all that commodity's proposals) or "<id>::<exact pattern>" (just that one), because
# a commodity can produce two proposals and only one of them may be worth keeping.
$toWrite = if ($Ids.Count) {
  @($proposals.ToArray() | Where-Object {
    $p = $_
    @($Ids | Where-Object {
      if ($_ -match '::') { $parts = $_ -split '::', 2; ($parts[0] -eq $p.id) -and ($parts[1] -eq $p.pattern) }
      else { $_ -eq $p.id }
    }).Count -gt 0
  })
} else { @($proposals.ToArray()) }
if ($Ids.Count) { Write-Output ("`n-Ids given: writing only {0} of {1} proposed rule(s)" -f $toWrite.Count, $proposals.Count) }
foreach ($p in $toWrite) {
  $cm = $commodities | Where-Object { $_.id -eq $p.id }
  $ex = New-Object System.Collections.ArrayList
  foreach ($e in @($cm.exclude)) { [void]$ex.Add($e) }
  if ($ex -contains $p.pattern) { continue }
  [void]$ex.Add($p.pattern)
  $cm.exclude = $ex.ToArray()
  $written++
  [void]$provRules.Add([pscustomobject]@{
    commodity = $p.id; pattern = $p.pattern; added = $stamp; source = 'promote-verdicts'
    from_weeks = $p.weeks; killed_items = $p.items; verdict_reason = $p.reason
  })
}
($commodities | ConvertTo-Json -Depth 10) | Set-Content $cPath -Encoding UTF8
$prov = [pscustomobject]@{
  readme = 'Provenance for excludes added by promote-verdicts.ps1. commodities.json is what the engine reads; this file records WHY each promoted rule exists, which weeks and items produced it, and is what you read before reverting one. A rule here was gated: it provably matched the dropped item and matched NO item the verify pass ever kept for that commodity.'
  rules  = $provRules.ToArray()
}
($prov | ConvertTo-Json -Depth 8) | Set-Content $provPath -Encoding UTF8

Write-Output ''
Write-Output ("APPLIED: {0} rule(s) written to commodities.json (backup in out\commodities.backup-before-promote.json)" -f $written)
Write-Output 'NOW VERIFY - a promoted rule must not cost a store a legitimate cell:'
Write-Output '  .\compare-deals.ps1 -MinStores 1 -BakersFile <..> -SamsFile <..>   then   .\audit-coverage-gaps.ps1'
