<#
  match-worklist-lib.ps1 - ONE worklist and ONE verdict ledger for the matching detectors.
  (plan-2026-09-22-9 item 2026-09-21-b96f21, plan-2026-09-22-10 item 2026-09-22-2dae07)

  Five detectors ask the same question - does this product belong to this commodity? - and until this file each
  wrote its own report that nobody consumed, and each paged a WHOLE-SET signature, so one new member re-paged every
  undecided old one (stores-dropped 15 fire days in 30, semantic-sweep 19, wrong-department 8):
    coverage   out/coverage-gaps.json        actionable rows (CLAIMED-BY, RULE-INVISIBLE)
    semantic   out/semantic-findings.json    coverage rows (a product no include can see)
    aisle      out/aisle-test.json           BLOCK rows (a live cell in a department its commodity never occupies)
    contested  out/audit/soundness-report.json new_contested (two rules admit the name; array order picked)
    band       band-refusals-backlog.json    rows a price band refused with no basis error to explain them

  THE LEDGER (grocery/match-verdicts.json, tracked) is what makes a decision stick: a key with a verdict never
  enters the worklist again, so it never pages again. The WORKLIST (out/match-worklist.json) keeps first_seen per
  key, so the alert blocks page a key only on its first day. The lane edits NO rule: a release or a widening is
  applied later, in gated batches, by apply-coverage-batch.ps1 -FromWorklist.

  THE CLASSIFIER, and its bar, written before it was built (plan-9): over the 24 frozen labels (21 coverage gaps +
  3 semantic rows of 2026-09-22) 0 wrong decisions among the keys it decides, coverage printed beside it. It
  decides only when TWO lexical signals agree: the product's HEAD NOUN (the noun the name is about, after
  'with/plus/in' tails, sizes and pack words are cut) must name the food of exactly one side (target or claimer),
  AND the other side's own tokens must not contain it. It abstains on anything it cannot read cleanly: a noun list
  ('Rings & Meatballs'), a pack/cup shape ('12 Pack', '4-4 oz Bowls'), a form the target names that the product
  does not state ('canned' pears vs 'Diced Pears'). The plan named the sidecar identity score as the second
  signal; the sidecar is not reachable from the daily chain's fan-out in every checkout (worktrees have no venv),
  so the second signal is the other commodity's token set instead - recorded as a deviation in plan-9.
  Kinds 'contested' and 'band' are DOCKET-ONLY for rule decisions (no labelled set exists for them yet): the lane
  lists them with the classifier's SUGGESTION and a person or the weekly agent decides with resolve-match-worklist
  -Decide, one key at a time. That is the plan's written fallback, per kind.
#>

$script:MwlForm = @{ 'canned' = 1; 'frozen' = 1; 'fresh' = 1; 'dried' = 1; 'jarred' = 1; 'bottled' = 1; 'boxed' = 1; 'instant' = 1 }
# Words that name no food: sizes, packs, marketing, connectives, retailer words. A head noun in this list is no
# head noun at all, and a commodity token in it proves nothing.
$script:MwlStop = @{}
foreach ($w in @('the','a','an','of','with','and','or','in','for','to','on','by','plus','oz','fl','lb','lbs','ct','count','pk','pack','packs','value','size','family','organic','natural','original','classic','brand','store','big','deal','each','bag','box','jar','can','bottle','pouch','tray','fresh','style','mix','new','large','small','medium','mini','jumbo','whole','sliced','diced','chopped','shredded','premium','select','choice','simple','truth','great','kroger','hy-vee','fareway','aldi','walmart','inspired','blend','free','added','no','sugar','low','reduced','fat','lite','light','regular','assorted','variety','food','foods','product','products','item','items','kit','piece','pieces','cut','cuts','bone-in','boneless','skinless','raw','cooked','ready','serve','to','ready-to-serve','x','ea')) { $script:MwlStop[$w] = 1 }
# adjective pairs a conjunction joins inside ONE product name ('Rich and Creamy'); anything else around &/and is
# read as a list of products and the classifier abstains.
$script:MwlAdj = @{}
foreach ($w in @('rich','creamy','sweet','salty','sour','hot','spicy','mild','chunky','smooth','tender','crispy','crunchy','light','fluffy','thick','zesty','tangy','savory','bold','soft','chewy','salted','unsalted','sea','black','white','red','green','sweet','tart','juicy','lean','bright','hearty','fruity')) { $script:MwlAdj[$w] = 1 }

function Get-MwlVariants([string]$t) {
  $t = $t.ToLowerInvariant().Trim("'", '"', '.', ',', '!', '?', ':', ';', '(', ')')
  $v = @($t)
  if ($t -match 'ies$' -and $t.Length -gt 4) { $v += ($t.Substring(0, $t.Length - 3) + 'y') }
  if ($t -match 'oes$' -and $t.Length -gt 4) { $v += $t.Substring(0, $t.Length - 2) }
  if ($t -match '(ch|sh|x|s)es$' -and $t.Length -gt 4) { $v += $t.Substring(0, $t.Length - 2) }
  if ($t -match 's$' -and $t -notmatch 'ss$' -and $t.Length -gt 3) { $v += $t.Substring(0, $t.Length - 1) }
  return ,$v
}
function Test-MwlIn([string]$tok, [hashtable]$set) {
  if (-not $tok -or -not $set) { return $false }
  foreach ($v in (Get-MwlVariants $tok)) { if ($set.ContainsKey($v)) { return $true } }
  return $false
}
function Get-MwlCommodityTokens($Commodity) {
  # id + label, split on '-', '/', '&' and spaces; singular variants added; stop words and form words kept apart.
  $set = @{}; $form = @{}
  if (-not $Commodity) { return [pscustomobject]@{ tokens = $set; form = $form } }
  $src = ([string]$Commodity.id + ' ' + [string]$Commodity.label) -replace '[-/&(),]', ' '
  foreach ($w in ($src -split '\s+')) {
    $w = $w.ToLowerInvariant().Trim()
    if (-not $w -or $w.Length -lt 3) { continue }
    if ($script:MwlForm.ContainsKey($w)) { $form[$w] = 1; continue }
    if ($script:MwlStop.ContainsKey($w)) { continue }
    foreach ($v in (Get-MwlVariants $w)) { $set[$v] = 1 }
  }
  return [pscustomobject]@{ tokens = $set; form = $form }
}
function Test-MwlAdLine([string]$Name) {
  # An ad LINE offering two or more products at one price ('apple or grape juice', 'fries, tots or onion rings').
  # 'or' between two WORDS; sizes of one product ('3 or 4 ct', '56 or 67.5 oz') are one product and do not count.
  return [bool]([regex]::IsMatch($Name, '(?i)(?<![\d.])\b[a-z][a-z''.]*\s+or\s+(?!\d)[a-z]'))
}
function Get-MwlHead([string]$Name) {
  <# The noun the product name is ABOUT. Returns head, prehead, list (a noun list: abstain), pack (a pack/cup
     shape: abstain) and core. Hyphenated words stay whole ('Shell-On' is not 'shell'). #>
  $n = [string]$Name
  $pack = [bool]([regex]::IsMatch($n, '(?i)\b\d+\s*(?:pack|pk|ct|count)\b|\b\d+\s*-\s*\d+(?:\.\d+)?\s*oz\b|\bcups?\b|\bbowls?\b|\bsnack\s+packs?\b'))
  # cut the name at the first comma when what precedes it is a phrase, not a lone brand word
  $parts = @($n -split ',')
  $core = $parts[0]
  if (($core.Trim() -split '\s+').Count -lt 2 -and $parts.Count -gt 1) { $core = $core + ' ' + $parts[1] }
  $core = [regex]::Replace($core, '(?i)\s+(?:with|plus|in|w/|featuring|made\s+with|for)\s+.*$', '')
  $core = [regex]::Replace($core, '(?i)\s+-\s+.*$', '')
  $core = [regex]::Replace($core, '(?i)\b\d+(?:\.\d+)?\s*(?:fl\.?\s*oz|oz|lbs?|ct|count|pk|pack|g|kg|ml|l)\b\.?', ' ')
  $core = [regex]::Replace($core, '\b[A-Z]{2,}(?:\s+[A-Z]{2,})*!+', ' ')    # 'BIG DEAL!'
  $core = [regex]::Replace($core, '[\u00AE\u2122!]', ' ')
  $words = @(($core -split '\s+') | Where-Object { $_ -and ($_ -notmatch '^[\d.%$/]+$') })
  $list = $false
  for ($i = 0; $i -lt $words.Count; $i++) {
    if ($words[$i] -match '^(?i)(&|and)$' -and $i -gt 0 -and $i -lt ($words.Count - 1)) {
      $l = $words[$i - 1].ToLowerInvariant().Trim(','); $r = $words[$i + 1].ToLowerInvariant().Trim(',')
      if (-not ($script:MwlAdj.ContainsKey($l) -and $script:MwlAdj.ContainsKey($r))) { $list = $true }
    }
  }
  if ([regex]::IsMatch($n, ',[^,]*(?:&|\band\b)')) { $list = $true }   # 'Brussels Sprouts, Butternut Squash & Onions'
  $content = @($words | Where-Object { -not $script:MwlStop.ContainsKey($_.ToLowerInvariant().Trim(',')) })
  $head = ''; $pre = ''
  if ($content.Count -gt 0) { $head = $content[$content.Count - 1].ToLowerInvariant().Trim(',', '.') }
  if ($content.Count -gt 1) { $pre = $content[$content.Count - 2].ToLowerInvariant().Trim(',', '.') }
  return [pscustomobject]@{ head = $head; prehead = $pre; list = $list; pack = $pack; core = $core.Trim() }
}
function Get-MwlStem([string]$w) {
  # the shortest singular variant, a trailing y dropped so cherry/cherries share one stem (a pattern prefix)
  $vv = Get-MwlVariants $w; $v = @($vv | Sort-Object Length); $s = [string]$v[0]   # assign first: the function returns ,$v
  if ($s.Length -gt 4 -and $s.EndsWith('y')) { $s = $s.Substring(0, $s.Length - 1) }
  return $s
}

function Get-MatchClassification {
  <# Pure. One key's decision: release | widen | confirm | ad-line | undecided, with the reason in words.
     -Target is the commodity the detector says the product belongs to (none for aisle/band);
     -Claimer is the commodity that holds it now (none for RULE-INVISIBLE / semantic). #>
  param([string]$Kind, [string]$Name, $Target, $Claimer, [hashtable]$Index = $null)
  $r = [pscustomobject]@{ decision = 'undecided'; why = ''; head = ''; pattern = '' }
  if (Test-MwlAdLine $Name) { $r.decision = 'ad-line'; $r.why = 'the line offers two or more products at one price (Q-adline-two-products: split per product at ingest)'; return $r }
  $h = Get-MwlHead $Name
  $r.head = $h.head
  if (-not $h.head) { $r.why = 'no head noun could be read'; return $r }
  if ($h.list) { $r.why = 'the name lists several foods (a conjunction between nouns); one head noun cannot speak for it'; return $r }
  if ($h.pack) { $r.why = 'a pack or cup shape: whether this is the target form or a snack cup is not in the name'; return $r }
  $T = Get-MwlCommodityTokens $Target
  $C = Get-MwlCommodityTokens $Claimer
  $inT = Test-MwlIn $h.head $T.tokens; $inC = Test-MwlIn $h.head $C.tokens
  $preT = Test-MwlIn $h.prehead $T.tokens; $preC = Test-MwlIn $h.prehead $C.tokens
  $stem = Get-MwlStem $h.head
  if ($Claimer -and $Target) {
    if ($inT -and -not $inC) {
      $r.decision = 'release'; $r.why = ("the head noun '" + $h.head + "' names " + $Target.id + ', and ' + $Claimer.id + "'s own words do not")
      # the narrowest exclude the name supports: the head phrase when the word before the head also names the target
      if ($h.prehead -and $preT -and -not $preC) { $r.pattern = ('\b' + [regex]::Escape((Get-MwlStem $h.prehead)) + '\w*\s+' + [regex]::Escape($stem)) } else { $r.pattern = ('\b' + [regex]::Escape($stem)) }
      return $r }
    if (-not $inT -and -not $inC -and $preT -and -not $preC -and $h.prehead) { $r.decision = 'release'; $r.why = ("the head phrase '" + $h.prehead + ' ' + $h.head + "' names " + $Target.id + ' and not ' + $Claimer.id); $r.pattern = ('\b' + [regex]::Escape((Get-MwlStem $h.prehead)) + '\w*\s+' + [regex]::Escape($stem)); return $r }
    if ($inC -and -not $inT -and -not $preT) { $r.decision = 'confirm'; $r.why = ("the head noun '" + $h.head + "' names " + $Claimer.id + ', the claim is right; ' + $Target.id + ' is a lookalike'); return $r }
    $r.why = ("head noun '" + $h.head + "' in target=" + $inT + ' claimer=' + $inC + ': the two signals do not agree'); return $r
  }
  if ($Target -and -not $Claimer) {
    # RULE-INVISIBLE: widen only when the head names the target and the target's FORM (canned, frozen...) is stated
    $formMissing = @($T.form.Keys | Where-Object { $Name -notmatch ('(?i)\b' + $_) })
    if ($inT -and $formMissing.Count -eq 0) {
      $toks = New-Object System.Collections.Generic.List[string]
      foreach ($w in (($Name -replace '[,()]', ' ') -split '\s+')) { $lw = $w.ToLowerInvariant().Trim('.', '!'); if ($lw -and (Test-MwlIn $lw $T.tokens) -and -not $toks.Contains((Get-MwlStem $lw))) { $toks.Add((Get-MwlStem $lw)) } }
      if ($toks.Count -lt 2) { $r.why = ("head noun '" + $h.head + "' names " + $Target.id + ' but only one of its words is in the name, so no widening narrower than the word itself can be derived'); return $r }
      $r.decision = 'widen'; $r.why = ("the head noun '" + $h.head + "' names " + $Target.id + ' and no rule admits the name')
      $r.pattern = ((@($toks | ForEach-Object { '\b' + [regex]::Escape($_) }) -join '.{0,30}'))
      return $r
    }
    if ($inT) { $r.why = ('the target names a form (' + ($formMissing -join ',') + ') the product does not state'); return $r }
    $r.why = ("head noun '" + $h.head + "' does not name " + $Target.id); return $r
  }
  if ($Claimer -and -not $Target) {
    # aisle / band: no detector named a target. Release is SUGGESTED only when the head noun names ANOTHER commodity's
    # food (-Index: token -> commodity ids) and neither the head nor the word before it is the claimer's.
    # AND no word of the claimer's appears anywhere in the name: measured 2026-09-22 on a 46-row sample of the band
    # backlog, the head-noun rule alone suggested 9 wrong releases ('Litehouse Herb, Freeze Dried Basil', 'Dial Liquid
    # Hand Soap AB Gold', 'Bounty Paper Towels ... White'), every one naming the claimer outside its head.
    $claimerWordInName = $false
    foreach ($w in (($Name -replace '[,()/&+]', ' ') -split '\s+')) { if ($w -and (Test-MwlIn $w $C.tokens)) { $claimerWordInName = $true; break } }
    if (-not $inC -and -not $preC -and -not $claimerWordInName -and $Index -and $h.head) {
      $hits = @(); foreach ($v in (Get-MwlVariants $h.head)) { if ($Index.ContainsKey($v)) { $hits += @($Index[$v]) } }
      $hits = @($hits | Where-Object { $_ -ne [string]$Claimer.id } | Sort-Object -Unique)
      if ($hits.Count -gt 0) { $r.decision = 'release'; $r.why = ("the head noun '" + $h.head + "' names " + ($hits -join '/') + ', not ' + $Claimer.id); $r.pattern = ('\b' + [regex]::Escape($stem)); return $r }
    }
    $r.why = ("head noun '" + $h.head + "' in claimer=" + $inC + '; no other commodity names it'); return $r
  }
  $r.why = 'neither side known'; return $r
}

# ---------------------------------------------------------------- the findings
function Get-MwlTokenIndex($Commodities) {
  # token -> commodity ids, over every commodity's own words (Get-MwlCommodityTokens)
  $ix = @{}
  foreach ($c in @($Commodities)) { if (-not $c) { continue }; foreach ($k in (Get-MwlCommodityTokens $c).tokens.Keys) { if (-not $ix.ContainsKey($k)) { $ix[$k] = New-Object System.Collections.Generic.List[string] }; [void]$ix[$k].Add([string]$c.id) } }
  return $ix
}
function Get-MwlKey([string]$Kind, [string]$Commodity, [string]$Store, [string]$Name) { return ($Kind + '|' + $Commodity + '|' + $Store + '|' + $Name) }

function Read-MatchFindings {
  <# One row per kind|commodity|store|name from every detector file that exists. A missing file is reported in
     .blind, never read as 'no findings'. #>
  param([string]$OutDir, [string]$GroceryDir)
  $rows = New-Object System.Collections.Generic.List[object]
  $blind = New-Object System.Collections.Generic.List[string]
  $rd = { param($p) try { return (Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null } }
  $f = Join-Path $OutDir 'coverage-gaps.json'
  $cg = if (Test-Path -LiteralPath $f) { & $rd $f } else { $null }
  if (-not $cg) { [void]$blind.Add('coverage') } else {
    foreach ($g in @($cg.gaps | Where-Object { $_ -and $_.actionable })) {
      $cl = ''; $m = [regex]::Match([string]$g.detail, "gave this name to '([^']+)'"); if ($m.Success) { $cl = $m.Groups[1].Value }
      [void]$rows.Add([pscustomobject]@{ key = (Get-MwlKey 'coverage' ([string]$g.commodity) ([string]$g.store) ([string]$g.candidate)); kind = 'coverage'; commodity = [string]$g.commodity; store = [string]$g.store; name = [string]$g.candidate; claimer = $cl; evidence = ([string]$g.reason + ': ' + [string]$g.detail) })
    }
  }
  $f = Join-Path $OutDir 'semantic-findings.json'
  $sf = if (Test-Path -LiteralPath $f) { & $rd $f } else { $null }
  if (-not $sf) { [void]$blind.Add('semantic') } else {
    foreach ($s in @($sf.coverage | Where-Object { $_ })) {
      [void]$rows.Add([pscustomobject]@{ key = (Get-MwlKey 'semantic' ([string]$s.id) ([string]$s.store) ([string]$s.product)); kind = 'semantic'; commodity = [string]$s.id; store = [string]$s.store; name = [string]$s.product; claimer = ''; evidence = ('cos=' + $s.cos + ' score=' + $s.score + ': ' + [string]$s.why) })
    }
  }
  $f = Join-Path $OutDir 'aisle-test.json'
  $at = if (Test-Path -LiteralPath $f) { & $rd $f } else { $null }
  if ($null -eq $at) { [void]$blind.Add('aisle') } else {
    foreach ($a in @($at | Where-Object { $_ -and [string]$_.verdict -eq 'BLOCK' })) {
      [void]$rows.Add([pscustomobject]@{ key = (Get-MwlKey 'aisle' ([string]$a.id) ([string]$a.store) ([string]$a.product)); kind = 'aisle'; commodity = ''; store = [string]$a.store; name = [string]$a.product; claimer = [string]$a.id; evidence = ('dept ' + [string]$a.dept + ': ' + [string]$a.reason) })
    }
  }
  $f = Join-Path (Join-Path $OutDir 'audit') 'soundness-report.json'
  $sr = if (Test-Path -LiteralPath $f) { & $rd $f } else { $null }
  if (-not $sr) { [void]$blind.Add('contested') } else {
    foreach ($c in @($sr.new_contested | Where-Object { $_ })) {
      if ($c -is [string]) { $c = [pscustomobject]@{ name = $c; chain = ''; winner = ''; form = $false; verdict = ''; cell = ''; crown = $false } }
      $others = @(([string]$c.chain -split '\s*>\s*') | ForEach-Object { ($_ -replace '\s*\(.*$', '').Trim() } | Where-Object { $_ -and $_ -ne [string]$c.winner })
      [void]$rows.Add([pscustomobject]@{ key = (Get-MwlKey 'contested' ([string]$c.winner) '' ([string]$c.name)); kind = 'contested'; commodity = ($others -join ','); store = ''; name = [string]$c.name; claimer = [string]$c.winner; crown = [bool]$c.crown; evidence = ('chain ' + [string]$c.chain + $(if ($c.form) { ' [FORM]' } else { '' }) + ' | engine ' + [string]$c.verdict + $(if ($c.cell) { ' | holds ' + [string]$c.cell } else { '' })) })
    }
  }
  $f = Join-Path $GroceryDir 'band-refusals-backlog.json'
  $bb = if (Test-Path -LiteralPath $f) { & $rd $f } else { $null }
  if (-not $bb) { [void]$blind.Add('band') } else {
    foreach ($k in @($bb.keys | Where-Object { $_ })) {
      $p = ([string]$k) -split '\|', 3
      if ($p.Count -lt 3) { continue }
      [void]$rows.Add([pscustomobject]@{ key = (Get-MwlKey 'band' $p[0] $p[1] $p[2]); kind = 'band'; commodity = ''; store = $p[1]; name = $p[2]; claimer = $p[0]; evidence = 'refused by the derived band with no basis error to explain it (backlog ' + [string]$bb.recorded + ')' })
    }
  }
  # Band rows OUTSIDE the backlog (plan-2026-09-25-7, queue 2026-09-23-57b66b): audit-band-refusals writes them with
  # first_seen to out/band-refusals-open.json and pages each on its first day only, so they wait HERE to be decided.
  # Until this the worklist read the backlog alone, and a new row was on no docket while it re-paged every day. A
  # missing open file is not blind: the backlog is still read, and the audit's own exit 3 names a run that never looked.
  $f = Join-Path $OutDir 'band-refusals-open.json'
  $bo = if (Test-Path -LiteralPath $f) { & $rd $f } else { $null }
  if ($bo) {
    foreach ($o in @($bo.rows | Where-Object { $_ -and $_.key })) {
      $p = ([string]$o.key) -split '\|', 3
      if ($p.Count -lt 3) { continue }
      [void]$rows.Add([pscustomobject]@{ key = (Get-MwlKey 'band' $p[0] $p[1] $p[2]); kind = 'band'; commodity = ''; store = $p[1]; name = $p[2]; claimer = $p[0]; evidence = 'refused by the derived band with no basis error to explain it (' + [string]$o.unit_price + ' against reference ' + [string]$o.band_ref + '; first seen ' + [string]$o.first_seen + ', not in the backlog)' })
    }
  }
  return [pscustomobject]@{ rows = $rows.ToArray(); blind = $blind.ToArray() }
}

# ---------------------------------------------------------------- the ledger
function Read-MatchVerdicts([string]$Path) {
  $h = @{}
  if (-not (Test-Path -LiteralPath $Path)) { return $h }
  $doc = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
  foreach ($v in @($doc.verdicts | Where-Object { $_ })) { $h[[string]$v.key] = $v }
  return $h
}
function Save-MatchVerdicts([string]$Path, [hashtable]$Verdicts) {
  $list = @($Verdicts.Keys | Sort-Object | ForEach-Object { $Verdicts[$_] })
  $doc = [ordered]@{
    note = 'The matching lane''s decision ledger (plan-2026-09-22-9 b96f21). One row per worklist key: confirm (the claim or refusal is right), applied (a release/widen rule shipped through apply-coverage-batch), reverted (a gate refused it; the reason is kept), known-wrong, ad-line. A key here never re-enters the worklist and never pages again. Written by resolve-match-worklist.ps1 and apply-coverage-batch.ps1 -FromWorklist; edit only through resolve-match-worklist.ps1 -Decide.'
    verdicts = $list }
  $json = ($doc | ConvertTo-Json -Depth 6) -replace "`r`n", "`n"
  [IO.File]::WriteAllText($Path, $json + "`n", (New-Object Text.UTF8Encoding($false)))
}
function New-MatchVerdict([string]$Key, $Row, [string]$Verdict, [string]$By, [string]$Reason, [string]$Pattern = '', [string]$Date = '') {
  if (-not $Date) { $Date = (Get-Date).ToString('yyyy-MM-dd') }
  return [pscustomobject][ordered]@{ key = $Key; kind = [string]$Row.kind; commodity = [string]$Row.commodity; claimer = [string]$Row.claimer; store = [string]$Row.store; name = [string]$Row.name; verdict = $Verdict; pattern = $Pattern; by = $By; date = $Date; reason = $Reason }
}

# ---------------------------------------------------------------- the worklist
function Merge-MatchWorklist {
  <# Pure. Today's findings against yesterday's worklist and the ledger: first_seen is kept, a key the detector no
     longer reports is dropped, a decided key is skipped. Returns rows with first_seen, last_seen and .new (first
     seen today). A kind that is BLIND today keeps yesterday's rows untouched, so a detector that did not run can
     neither re-page nor forget. #>
  param($Findings, $Previous, [hashtable]$Verdicts, [string]$Today, [string[]]$BlindKinds = @())
  $prev = @{}; foreach ($p in @($Previous | Where-Object { $_ })) { $prev[[string]$p.key] = $p }
  $out = New-Object System.Collections.Generic.List[object]
  $seen = @{}
  foreach ($f in @($Findings | Where-Object { $_ })) {
    $k = [string]$f.key
    if ($seen.ContainsKey($k)) { continue }; $seen[$k] = 1
    if ($Verdicts.ContainsKey($k)) { continue }
    $fs = $Today; if ($prev.ContainsKey($k) -and [string]$prev[$k].first_seen) { $fs = [string]$prev[$k].first_seen }
    $row = [ordered]@{}; foreach ($pr in $f.PSObject.Properties) { $row[$pr.Name] = $pr.Value }
    $row['first_seen'] = $fs; $row['last_seen'] = $Today; $row['new'] = ($fs -eq $Today)
    [void]$out.Add([pscustomobject]$row)
  }
  foreach ($p in $prev.Values) {
    if ($BlindKinds -contains [string]$p.kind -and -not $seen.ContainsKey([string]$p.key) -and -not $Verdicts.ContainsKey([string]$p.key)) {
      $p.new = $false; [void]$out.Add($p)
    }
  }
  return ,($out.ToArray())
}
function Get-MatchPageRows {
  <# The rows an alert block may page: this kind, first seen TODAY, still undecided. Everything else is either
     decided (the ledger) or already paged on its own first day. #>
  param($Worklist, [string]$Kind, [string]$Today)
  return ,(@($Worklist | Where-Object { $_ -and [string]$_.kind -eq $Kind -and [string]$_.first_seen -eq $Today }))
}
function Read-MatchWorklist([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return @() }
  try { $d = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json; return ,(@($d.rows | Where-Object { $_ })) } catch { return @() }
}

# ---------------------------------------------------------------- the soundness audit's two readers (2dae07)
function Get-ReviewedContested {
  <# The contested names audit-match-soundness treats as REVIEWED: the accepted baseline's list UNION every
     contested key the ledger CONFIRMED. One function, two records (merging them is a data migration not done here). #>
  param($Baseline, [string]$VerdictFile)
  $h = @{}
  foreach ($x in @($Baseline.contested)) { if ($x) { $h[[string]$x] = $true } }
  $v = Read-MatchVerdicts $VerdictFile
  foreach ($k in @($v.Keys)) { $e = $v[$k]; if ([string]$e.kind -eq 'contested' -and [string]$e.verdict -eq 'confirm') { $h[[string]$e.name] = $true } }
  return $h
}
function Get-LaneKnownContested {
  <# Contested names the lane already holds from an EARLIER day (worklist first_seen before today) or has decided in
     any way: they paged on their own first day and must not page again. #>
  param([string]$WorklistFile, [string]$VerdictFile, [string]$Today)
  $h = @{}
  foreach ($r in (Read-MatchWorklist $WorklistFile)) { if ([string]$r.kind -eq 'contested' -and [string]$r.first_seen -and [string]::CompareOrdinal([string]$r.first_seen, $Today) -lt 0) { $h[[string]$r.name] = $true } }
  $v = Read-MatchVerdicts $VerdictFile
  foreach ($k in @($v.Keys)) { $e = $v[$k]; if ([string]$e.kind -eq 'contested') { $h[[string]$e.name] = $true } }
  return $h
}
function Select-UnknownContestedConditions {
  <# Pure. Drops a NEW CONTESTED condition line whose product the lane already knows. Every other label passes. #>
  param($Conditions, [hashtable]$Known)
  $out = New-Object System.Collections.Generic.List[object]
  foreach ($c in @($Conditions | Where-Object { $_ })) {
    if ([string]$c.Label -eq 'NEW CONTESTED') {
      $m = [regex]::Match([string]$c.Text, '^(?:NEW-CONTESTED(?: \[FORM\])?|(?:CELL|CROWN)-BY-CONTEST) (.+?) \| ')
      if ($m.Success -and $Known.ContainsKey($m.Groups[1].Value)) { continue }
    }
    [void]$out.Add($c)
  }
  return ,($out.ToArray())
}
