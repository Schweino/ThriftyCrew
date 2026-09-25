<#
  unpriced-takedown.ps1 - a LIVE recipe whose recost cannot price an ingredient comes DOWN, and goes back UP
  when every line prices again. The daily chain runs it; nobody runs it by hand to take a page down.

  THE RULING (Brad, 2026-09-25, Q1-2026-09-20-partial-cost in grocery\triage-plans\plan-2026-09-20-2.json):
  asked "When a live recipe can't be fully re-costed because one ingredient has no store price right now, what
  should its page show?", he answered "(B) Take the recipe down", over keeping the last full cost with a dated
  badge. For exactly this case it overrides the 2026-09-21 line that "a recipe page should ALWAYS be able to be
  costed" (.claude\rules\meal-prep.md). Until this script the manifest silently SKIPPED such a recipe and the
  page kept its last cost, unmarked, indefinitely (turkey-wild-rice-casserole on 2026-09-19, its title
  ingredient missing, 35% under its true cost).

  WHAT COUNTS AS UNPRICED. engine\cost-recipes.ps1 drops a line it cannot price and counts it in the costed
  row's lines_unpriced; it never names it. So the line is named HERE, by the same projection the engine costs
  from (the spec's scaler.ing, canon or item, grams > 0) minus the lines the costed row kept. Why it dropped is
  the engine's own words (db\cost-flags.txt, and costed.stamp.json's set-aside held lines) plus the carriage
  verdict the row records in `uncarried`. Every unpriced line on a live page comes down, whatever its class:
    CARRIED-NO-PRICE   carried, but no board, feed or fresh ledger price (the case Brad ruled on);
    NOT-CARRIED        no Omaha store stocks it (the six held by hand on 2026-09-19 were this class);
    UNKNOWN-CARRIAGE   nobody has looked (UNCHECKED IS NEVER NOT-CARRIED, and the cost is still understated).
  The class is recorded so a reader of the ledger can tell a capture gap from a missing product.

  THE ROADS IT USES, NEVER ITS OWN. Down is hold-recipe.ps1 -Apply (Ghost draft, verified by re-read, the slug
  recorded in db\held-recipes.json so engine\publish.ps1 refuses it, its published-hash removed). Up is
  hold-recipe.ps1 -Release, then meal-prep\lib\gated-republish-lib.ps1's Invoke-TcGatedRepublish -CostOnly, the
  road the daily republish takes: build, allergen line, publish once, and only a card PROVABLY the one that was
  live with its cost block swapped. retire-recipe.ps1 is never called: it DELETEs the post.

  ONE LEDGER: db\unpriced-takedowns.json. A row per slug: its lines and why, the date it came down, the
  visibility the estate believed it sold at, the published-hash it had when it came down (so the cost-only
  proof still works after hold-recipe removed that hash), the date it came back, and which pages were sent.

  IDEMPOTENT, AND WHAT MAKES IT SO. Every step is check-then-act on state another reader can see, and every act
  is safe to repeat:
    * a hold is refused by hold-recipe when the slug is already held, so re-running a take-down that landed does
      nothing; a crash after Ghost was drafted but before the hold was written leaves "Ghost already has it as
      a DRAFT", and the retry finishes the local half with -SkipGhost;
    * the ledger row is written BEFORE the hold (state taking-down, carrying the hash hold-recipe is about to
      remove) and moved to down AFTER it, so a crash anywhere leaves a row that names what to finish; a hold
      whose reason carries this script's prefix and has no row is rebuilt into one, so the held list alone is
      enough to recover;
    * a restore re-reads Ghost before it acts: already published and not held means the publish landed and only
      the record is left. Release refuses a slug that is not held, and publish skips an unchanged hash, so
      neither doubles;
    * pages are AT LEAST ONCE: a page stays due in the ledger until the chain has sent it and calls back with
      -MarkPaged. A crash between the two re-sends it on the next run, and send-alert's once-per-type-per-day
      gate absorbs a same-day repeat. At-most-once would lose the one page that says a live recipe came down.
  A HOLD THIS SCRIPT DID NOT MAKE IS NEVER RELEASED. Only a held reason starting with the prefix below is ours.

  THE CIRCUIT BREAKER. More than $script:UtdBreakerShareDenominator-ths (2%) of live recipes coming down in ONE
  run means the board or the feed broke, not the recipes. Then NOTHING comes down, the step is held, and it
  pages. The bar and what else was tried: see $script:UtdBreakerShareDenominator below.
  WHEN THE PRODUCER STOPS. The chain runs this only after cost-recipes exited 0 in the same run. A costed stamp
  older than -MaxCostedAgeHours, an unreadable costed.json, held list or published set is BLIND (exit 3): nothing
  comes down and nothing goes up. So a dead recost cannot take pages down, and cannot bring any back either: a
  recipe that is down STAYS down until a fresh recost proves every line prices. That is the safe direction for
  money (a page with an understated cost is never live), and the cost is that a missed restore is silent; the
  chain logs the count of recipes down and how long each has been down on every run, and the BLIND exit pages.

  THE KILL SWITCH: db\unpriced-takedown-switch.json, `mode`. 'dry-run' (as shipped) reports what it WOULD take
  down or bring back and writes NOTHING. 'on' acts. Anything else is refused (exit 3). -DryRun forces dry-run,
  and the chain passes it under -NoPublish, so a rehearsal can never reach Ghost.

  PAYWALL, IN THE DIRECTION THAT LOSES MONEY. A recipe the estate sells as paid (recipes-db.json `visibility`)
  is never restored while Ghost shows its post as public: publish.ps1 PRESERVES the live visibility on update,
  so a republish would carry a leak forward. And after the republish Ghost is read again; a paid recipe that
  came back public is drafted again on the spot and pages. memory: paywall-leak-direction-unwatched.

  Usage (the chain):  .\unpriced-takedown.ps1 -ResultFile <tmp.json> [-DryRun]
                      .\unpriced-takedown.ps1 -MarkPaged <key>[,<key>...]
  By hand:            .\unpriced-takedown.ps1 -DryRun            what it would do today, writes nothing
                      .\unpriced-takedown.ps1 -SelfTest
  Exit 0 ran (the result says what it did), 3 could not evaluate (nothing acted), 1 a self-test failure.
  Last line: UNPRICED-TAKEDOWN-COMPLETE mode=<m> live=<n> down=<n> would=<n> restored=<n> breaker=<held|ok> ...
#>
param(
  [string]$Root = '',
  [switch]$DryRun,
  [string]$ResultFile = '',
  [string]$MarkPaged = '',
  [int]$MaxCostedAgeHours = 26,
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$__jioRoot = $PSScriptRoot; while ($__jioRoot -and -not (Test-Path (Join-Path $__jioRoot 'lib\json-io.ps1'))) { $__jioRoot = Split-Path $__jioRoot -Parent }
if (-not $__jioRoot) { throw ('json-io.ps1 not found walking up from ' + $PSScriptRoot) }
. (Join-Path $__jioRoot 'lib\json-io.ps1')
. (Join-Path $__jioRoot 'lib\atomic-write.ps1')
. (Join-Path $__jioRoot 'lib\ledger-lock.ps1')
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:UtdHere = $here
$script:UtdRepo = $__jioRoot
. (Join-Path (Split-Path $here -Parent) 'lib\held-state.ps1')

# The prefix that marks a hold as THIS mechanism's. A hold without it (Brad's, a session's) is never released here.
$script:UtdReasonPrefix = 'unpriced-takedown: '

# THE BREAKER BAR: a run may take down at most 1/50 (2%) of the live recipes; more holds the step. Integer
# arithmetic (n * 50 -gt live), so the case at the bar is exact and never decided by a double.
# CHOSEN FROM A MEASUREMENT, 2026-09-25: all 100 committed versions of db\costed.json (2026-07-26 to 2026-09-25),
# counting rows with lines_unpriced > 0 that db\held-recipes.json at the same commit did not hold. 88 versions read
# 0. The rest: 1 recipe (baked-stuffed-pork-chops x5, peruvian-pollo-saltado, turkey-wild-rice-casserole x2);
# 9 once (2026-08-16, a new wave being built, 544 -> 568 specs that hour, so not live pages); 8 for two days
# (2026-08-09..11, Dried Ancho Chiles alone, a single ingredient, 1.5% of 542); and 18 ONCE (2026-08-09 06:27,
# 3.3%: ancho, Apple and Pepperoncini together; Apple and Pepperoncini were back within three hours). The bar is
# the smallest round share that lets every persistent single-ingredient episode through (8 of 542) and holds the
# one transient spike (18 of 542). ALSO CONSIDERED: 1% (5 recipes at 577 live) would have held the ancho week,
# which is exactly the case Brad ruled should come down; 5% would have let the 18 through; a fixed count (the
# chain's own republish cap is 150) does not scale with the catalogue; a bar on DISTINCT ingredients cannot see
# the spike (it was 3). This is the first bar chosen from that history, not the survivor of a sweep, over six
# non-zero episodes in two months: a thin base, stated so the next reader re-measures before moving it.
$script:UtdBreakerShareDenominator = 50

$script:UtdApiUrl = 'https://map-to-success.ghost.io'

function Get-UtdPaths([string]$Mp) {
  return [pscustomobject]@{
    Costed    = (Join-Path $Mp 'db\costed.json')
    Stamp     = (Join-Path $Mp 'db\costed.stamp.json')
    Flags     = (Join-Path $Mp 'db\cost-flags.txt')
    Specs     = (Join-Path $Mp 'db\recipes')
    Hashes    = (Join-Path $Mp 'db\published-hashes.json')
    Db        = (Join-Path $Mp 'db')
    RecipesDb = (Join-Path $Mp 'recipes-db.json')
    Ledger    = (Join-Path $Mp 'db\unpriced-takedowns.json')
    Switch    = (Join-Path $Mp 'db\unpriced-takedown-switch.json')
  }
}

function Get-UtdMode {
  <# The kill switch. Returns @{ mode; why }. mode is 'dry-run', 'on', or '' (refused: unreadable or unknown). #>
  param([string]$SwitchPath, [bool]$ForceDry)
  $m = 'dry-run'; $why = 'no switch file: dry-run'
  if (Test-Path -LiteralPath $SwitchPath) {
    try { $j = Read-JsonFile $SwitchPath; $m = [string]$j.mode; $why = ('switch file says ' + $m) }
    catch { return [pscustomobject]@{ mode = ''; why = ('the switch file could not be read: ' + $_.Exception.Message) } }
  }
  switch ($m) {
    'dry-run' { }
    'on'      { }
    default   { return [pscustomobject]@{ mode = ''; why = ("unknown kill-switch mode '" + $m + "' - refusing to act or to guess") } }
  }
  if ($ForceDry -and $m -eq 'on') { $m = 'dry-run'; $why = ($why + ', forced to dry-run by -DryRun') }
  return [pscustomobject]@{ mode = $m; why = $why }
}

function Get-UtdSpecKeys {
  <# The engine's own projection of a spec: scaler.ing, canon when set else item, grams > 0. #>
  param($Spec)
  $keys = @()
  if ($null -eq $Spec -or -not $Spec.PSObject.Properties['scaler'] -or $null -eq $Spec.scaler) { return ,$keys }
  foreach ($i in @($Spec.scaler.ing)) {
    if ($null -eq $i) { continue }
    $g = 0.0; try { $g = [double]$i.grams } catch { $g = 0.0 }
    if ($g -le 0) { continue }
    $k = if ($i.PSObject.Properties['canon'] -and $i.canon) { [string]$i.canon } else { [string]$i.item }
    $keys += $k
  }
  return ,$keys
}

function Get-UtdUnpricedLines {
  <#
    PURE. The lines a costed row dropped, each @{ item; class; gap }. $FlagLines are the engine's flag lines (a
    'LIVE :: ' prefix allowed). A row that claims unpriced lines the spec diff cannot name still returns one line,
    so a count the names cannot explain is never read as zero.
  #>
  param($Row, $Spec, [string[]]$FlagLines)
  $out = @()
  $n = 0; try { $n = [int]$Row.lines_unpriced } catch { $n = 0 }
  $keys = Get-UtdSpecKeys $Spec
  $left = @{}
  foreach ($l in @($Row.lines)) { if ($l -and $l.item) { $k = [string]$l.item; if ($left.ContainsKey($k)) { $left[$k]++ } else { $left[$k] = 1 } } }
  $missing = @()
  foreach ($k in $keys) { if ($left.ContainsKey($k) -and $left[$k] -gt 0) { $left[$k]-- } else { $missing += $k } }
  if ($n -le 0 -and $missing.Count -eq 0) { return ,$out }
  $carr = @{}
  foreach ($u in @($Row.uncarried)) { $us = [string]$u; if ($us -match '^(.*) \[([A-Z-]+)\]$') { $carr[$Matches[1]] = $Matches[2] } }
  $name = [string]$Row.proposed_name
  foreach ($k in ($missing | Select-Object -Unique)) {
    $reasons = @()
    foreach ($f in @($FlagLines)) {
      $fl = [string]$f; if ($fl.StartsWith('LIVE :: ', [StringComparison]::Ordinal)) { $fl = $fl.Substring(8) }
      $pre = $name + ' :: ' + $k + ' :: '
      if ($fl.StartsWith($pre, [StringComparison]::Ordinal)) { $reasons += $fl.Substring($pre.Length) }
    }
    $verdict = if ($carr.ContainsKey($k)) { $carr[$k] } else { 'CARRIED' }
    $class = switch ($verdict) {
      'CARRIED'     { 'CARRIED-NO-PRICE' }
      'NOT-CARRIED' { 'NOT-CARRIED' }
      default       { 'UNKNOWN-CARRIAGE' }   # any other verdict (UNKNOWN, PENDING, a new word) is not proof of carriage
    }
    $engine = if ($reasons.Count) { ($reasons | Select-Object -Unique) -join '; ' } else { 'no engine flag line names it' }
    $out += [pscustomobject]@{ item = $k; class = $class; gap = ('carriage ' + $verdict + '; engine: ' + $engine) }
  }
  if ($out.Count -eq 0) {
    $out += [pscustomobject]@{ item = '(unnamed line)'; class = 'UNKNOWN-CARRIAGE'; gap = ('the costed row says ' + $n + ' unpriced line(s) and the spec names none of them') }
  }
  return ,$out
}

function Test-UtdBreaker {
  <# PURE. $true when taking $Count down would pass the bar: Count * denominator > Live. Live 0 with any Count trips. #>
  param([int]$Count, [int]$Live, [int]$Denominator = $script:UtdBreakerShareDenominator)
  if ($Count -le 0) { return $false }
  return (($Count * $Denominator) -gt $Live)
}

function Test-UtdPaywallRestoreSafe {
  <# PURE. May a post come back with the visibility Ghost holds? Only 'public' is free; a paid recipe held public refuses. #>
  param([string]$Believed, [string]$GhostVisibility)
  if ([string]::Equals($GhostVisibility, 'public', [StringComparison]::OrdinalIgnoreCase) -and -not [string]::Equals($Believed, 'public', [StringComparison]::OrdinalIgnoreCase)) { return $false }
  return $true
}

function Read-UtdLedger([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) {
    return [pscustomobject]@{ _doc = 'Recipes the daily chain took down because a recost could not price a line (Brad, 2026-09-25, Q1-2026-09-20-partial-cost), and their restores. Written by meal-prep\pipeline\unpriced-takedown.ps1 only.'; rows = [pscustomobject]@{}; events = @(); pages = [pscustomobject]@{} }
  }
  $j = Read-JsonFile $Path
  if (-not $j.PSObject.Properties['rows'])   { $j | Add-Member -NotePropertyName rows -NotePropertyValue ([pscustomobject]@{}) -Force }
  if (-not $j.PSObject.Properties['events']) { $j | Add-Member -NotePropertyName events -NotePropertyValue @() -Force }
  if (-not $j.PSObject.Properties['pages'])  { $j | Add-Member -NotePropertyName pages -NotePropertyValue ([pscustomobject]@{}) -Force }
  return $j
}

function Update-UtdLedger {
  <# Read-modify-write under the ledger lock; the read is INSIDE it. $Change gets the ledger and edits it in place. #>
  param([string]$Path, [scriptblock]$Change)
  $lk = Enter-TcLedgerLock -Path $Path
  try {
    $j = Read-UtdLedger $Path
    & $Change $j
    [void](Write-TcAtomicFile -Path $Path -Text ($j | ConvertTo-Json -Depth 8) -NoBom)
  } finally { Exit-TcLedgerLock $lk }
}

function Set-UtdRow($Ledger, [string]$Slug, [hashtable]$Fields) {
  $row = $Ledger.rows.PSObject.Properties[$Slug]
  if ($null -eq $row) { $Ledger.rows | Add-Member -NotePropertyName $Slug -NotePropertyValue ([pscustomobject]@{ slug = $Slug; pages = [pscustomobject]@{} }) -Force; $row = $Ledger.rows.PSObject.Properties[$Slug] }
  foreach ($k in $Fields.Keys) { $row.Value | Add-Member -NotePropertyName $k -NotePropertyValue $Fields[$k] -Force }
}

function Add-UtdEvent($Ledger, [string]$Slug, [string]$Event, [string]$Detail, [string]$At) {
  $Ledger.events = @(@($Ledger.events) + [pscustomobject]@{ at = $At; slug = $Slug; event = $Event; detail = $Detail })
}

function Add-UtdPageDue($Ledger, [string]$Slug, [string]$Key) {
  # A due page is a key with a $null sent date. Adding a key that is already there changes nothing.
  $bag = if ($Slug) { $Ledger.rows.PSObject.Properties[$Slug].Value.pages } else { $Ledger.pages }
  if (-not $bag.PSObject.Properties[$Key]) { $bag | Add-Member -NotePropertyName $Key -NotePropertyValue $null -Force }
}

# ---- THE REAL SEAMS (the self-test replaces every one) ------------------------------------------------------
function New-UtdRealSeams([string]$Mp) {
  $hr = Join-Path $script:UtdHere 'hold-recipe.ps1'
  $repo = $script:UtdRepo
  $api = $script:UtdApiUrl
  return @{
    Hold = {
      param([string]$Slug, [string]$Reason, [bool]$SkipGhost)
      $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $hr, '-Slug', $Slug, '-Reason', $Reason, '-Apply', '-Root', $Mp)
      if ($SkipGhost) { $a += '-SkipGhost' }
      $o = @(& powershell @a | ForEach-Object { [string]$_ })
      return [pscustomobject]@{ rc = $LASTEXITCODE; out = ($o -join ' | ') }
    }.GetNewClosure()
    Release = {
      param([string]$Slug, [string]$Reason)
      $o = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $hr -Slug $Slug -Release -Reason $Reason -Apply -Root $Mp | ForEach-Object { [string]$_ })
      return [pscustomobject]@{ rc = $LASTEXITCODE; out = ($o -join ' | ') }
    }.GetNewClosure()
    GhostRead = {
      param([string]$Slug)
      try {
        . (Join-Path $repo 'lib\ghost-lib.ps1')
        $key = Get-GhostKey -Root $repo
        if (-not $key) { return [pscustomobject]@{ ok = $false; status = ''; visibility = ''; why = 'no Ghost admin key' } }
        $jwt = Get-GhostJWT $key
        $p = (Invoke-GhostApi -Uri "$api/ghost/api/admin/posts/slug/$Slug/?fields=id,status,visibility" -Headers @{ Authorization = "Ghost $jwt"; 'Accept-Version' = (Get-GhostAcceptVersion) }).posts[0]
        if (-not $p) { return [pscustomobject]@{ ok = $false; status = ''; visibility = ''; why = 'Ghost has no post with that slug' } }
        return [pscustomobject]@{ ok = $true; status = [string]$p.status; visibility = [string]$p.visibility; why = '' }
      } catch { return [pscustomobject]@{ ok = $false; status = ''; visibility = ''; why = ('Ghost read failed: ' + $_.Exception.Message) } }
    }.GetNewClosure()
    Republish = {
      param([string]$Slug, [string]$JournalPath)
      . (Join-Path $Mp 'lib\gated-republish-lib.ps1')
      Push-Location $Mp
      try {
        $rp = Invoke-TcGatedRepublish -Slugs @($Slug) -CostOnly -JournalPath $JournalPath `
          -Build { param($s) & '.\engine\build-cards.ps1' -Slugs $s } -Publish { param($s) & '.\engine\publish.ps1' -Slugs $s }
      } finally { Pop-Location }
      $heldWhy = @(@($rp.Held) | Where-Object { $_.slug -eq $Slug } | ForEach-Object { [string]$_.stage + ': ' + [string]$_.why })
      $ok = ($rp.PublishInvoked -and $rp.PublishRc -eq 0 -and @($rp.PublishOut).Count -gt 0 -and $heldWhy.Count -eq 0)
      $why = if ($ok) { '' } elseif ($heldWhy.Count) { 'the gated republish held it: ' + ($heldWhy -join '; ') } else { 'publish did not succeed: rc=' + $rp.PublishRc + ' ' + ((@($rp.PublishOut) | Select-Object -Last 1) -join '') }
      return [pscustomobject]@{ ok = $ok; why = $why }
    }.GetNewClosure()
  }
}

function Save-UtdRefusal {
  <# A restore that could not finish: the row keeps $State, the reason is recorded, and ONE page per slug per cause is due. #>
  param([string]$LedgerPath, [string]$Slug, [string]$Name, [string]$Code, [string]$Why, [string]$State, [string]$Today)
  $rk = 'restore-refused:' + $Slug + ':' + $Code
  Update-UtdLedger $LedgerPath { param($j) Set-UtdRow $j $Slug @{ state = $State; restore_refused = $Why }; Add-UtdEvent $j $Slug 'restore-refused' $Why $Today; Add-UtdPageDue $j $Slug $rk }.GetNewClosure()
  return [pscustomobject]@{ slug = $Slug; name = $Name; stage = 'restore'; why = $Why }
}

# ---- THE RUN ----------------------------------------------------------------------------------------------
function Invoke-UtdRun {
  param([string]$Mp, [bool]$ForceDry, [int]$MaxAgeHours, [datetime]$Now, [hashtable]$Seams)
  $P = Get-UtdPaths $Mp
  $today = $Now.ToString('yyyy-MM-dd')
  $res = [ordered]@{ mode = ''; why = ''; blind = ''; live = 0; would = @(); would_restore = @(); taken_down = @(); restored = @(); refused = @(); still_down = @(); breaker = [ordered]@{ tripped = $false; count = 0; bar = 0; live = 0 }; pages = @() }

  $md = Get-UtdMode -SwitchPath $P.Switch -ForceDry $ForceDry
  $res.mode = $md.mode; $res.why = $md.why
  if (-not $md.mode) { $res.blind = $md.why; return $res }

  # INPUTS. Every one a could-not-look is BLIND, never an empty answer.
  $costed = $null; $stamp = $null
  try { $costedRaw = Read-JsonFile $P.Costed; $costed = @($costedRaw) } catch { $res.blind = ('db\costed.json could not be read: ' + $_.Exception.Message); return $res }
  if ($costed.Count -eq 0) { $res.blind = 'db\costed.json holds no rows'; return $res }
  try { $stamp = Read-JsonFile $P.Stamp } catch { $res.blind = ('db\costed.stamp.json could not be read: ' + $_.Exception.Message); return $res }
  $gen = $null; try { $gen = [datetime]([string]$stamp.generated) } catch { $gen = $null }
  if ($null -eq $gen) { $res.blind = 'db\costed.stamp.json names no generated time'; return $res }
  $ageH = ($Now - $gen).TotalHours
  if ($ageH -gt $MaxAgeHours) { $res.blind = ('the recost is {0:N1} h old (bar {1} h, stamp {2}): acting on it would take pages down, or bring them back, on a stale board' -f $ageH, $MaxAgeHours, [string]$stamp.generated); return $res }
  $hashes = $null
  try { $hashes = Read-JsonFile $P.Hashes } catch { $res.blind = ('db\published-hashes.json could not be read: ' + $_.Exception.Message); return $res }
  $pubNames = @(); if ($hashes) { $pubNames = @($hashes.PSObject.Properties | ForEach-Object { [string]$_.Name } | Where-Object { $_ }) }   # never @(.Properties.Name): an empty object gives @($null), one "slug"
  if ($pubNames.Count -eq 0) { $res.blind = 'db\published-hashes.json names no published recipe, so the live set is unknown'; return $res }
  $held = Get-HeldRecipeSet $P.Db
  if (-not $held.ok) { $res.blind = $held.why; return $res }
  $believed = @{}
  try { foreach ($r in @((Read-JsonFile $P.RecipesDb).recipes)) { if ($r -and $r.slug) { $believed[[string]$r.slug] = [string]$r.visibility } } }
  catch { $res.blind = ('recipes-db.json could not be read, so what each recipe is sold as is unknown: ' + $_.Exception.Message); return $res }
  $flagLines = @()
  if (Test-Path -LiteralPath $P.Flags) { $flagLines = @([IO.File]::ReadAllLines($P.Flags, [Text.Encoding]::UTF8)) }
  if ($stamp.PSObject.Properties['flags_set_aside'] -and $stamp.flags_set_aside) { $flagLines += @($stamp.flags_set_aside.held_lines) }
  $ledger = $null
  try { $ledger = Read-UtdLedger $P.Ledger } catch { $res.blind = ('db\unpriced-takedowns.json could not be read: ' + $_.Exception.Message); return $res }

  $pubSet = @{}; foreach ($n in $pubNames) { $pubSet[[string]$n] = $true }
  $liveCount = @($pubNames | Where-Object { -not $held.slugs.ContainsKey([string]$_) }).Count
  $res.live = $liveCount

  # WHAT EACH ROW IS MISSING
  $byslug = @{}
  foreach ($row in $costed) {
    if ($null -eq $row -or -not $row.slug) { continue }
    $s = [string]$row.slug
    $specPath = Join-Path $P.Specs ($s + '.json')
    $spec = $null; if (Test-Path -LiteralPath $specPath) { try { $spec = Read-JsonFile $specPath } catch { $spec = $null } }
    $lines = Get-UtdUnpricedLines -Row $row -Spec $spec -FlagLines $flagLines
    $unc = 0; try { $unc = [int]$row.lines_uncarried } catch { $unc = 0 }
    $byslug[$s] = [pscustomobject]@{ name = [string]$row.proposed_name; lines = $lines; fully = (($lines.Count -eq 0) -and ($unc -eq 0) -and ($null -ne $spec)) }
  }

  # OURS: ledger rows, plus any hold carrying our prefix that has no row (a crash between the hold and the row)
  $ours = @{}
  foreach ($lrow in @($ledger.rows.PSObject.Properties)) { $ours[$lrow.Name] = $lrow.Value }
  foreach ($hs in @($held.slugs.Keys)) {
    if (([string]$held.slugs[$hs]).StartsWith($script:UtdReasonPrefix, [StringComparison]::Ordinal) -and -not $ours.ContainsKey([string]$hs)) {
      $ours[[string]$hs] = [pscustomobject]@{ slug = [string]$hs; state = 'down'; rebuilt_from_hold = $true; taken_down = ''; journal_hash = $null; pages = [pscustomobject]@{} }
    }
  }

  # TAKE-DOWN CANDIDATES: published, not held, not already ours-in-flight, with at least one unpriced line
  $cands = @()
  foreach ($s in @($pubSet.Keys | Sort-Object)) {
    if ($held.slugs.ContainsKey($s)) { continue }
    if (-not $byslug.ContainsKey($s)) { continue }
    $b = $byslug[$s]
    if ($b.lines.Count -eq 0) { continue }
    $cands += [pscustomobject]@{ slug = $s; name = $b.name; lines = $b.lines }
  }
  foreach ($c in $cands) { $res.would += [pscustomobject]@{ slug = $c.slug; name = $c.name; lines = $c.lines } }
  # IN-FLIGHT: a row that says taking-down finishes, whatever the breaker says: it already passed one
  $inflight = @($ours.Values | Where-Object { [string]$_.state -eq 'taking-down' })

  # RESTORE CANDIDATES: ours, down or restoring, and every line prices again
  $restores = @()
  foreach ($o in @($ours.Values)) {
    $st = [string]$o.state
    if ($st -ne 'down' -and $st -ne 'restoring') { continue }
    $s = [string]$o.slug
    if ($byslug.ContainsKey($s) -and $byslug[$s].fully) { $restores += $o }
    else { $res.still_down += [pscustomobject]@{ slug = $s; since = [string]$o.taken_down } }
  }
  foreach ($o in $restores) { $res.would_restore += [pscustomobject]@{ slug = [string]$o.slug } }

  $trip = Test-UtdBreaker -Count $cands.Count -Live $liveCount
  $res.breaker = [ordered]@{ tripped = $trip; count = $cands.Count; bar = [int][math]::Floor($liveCount / $script:UtdBreakerShareDenominator); live = $liveCount }

  if ($md.mode -eq 'dry-run') { return $res }

  # ---------------------------------------------------------------- ON ----------------------------------------
  $toTake = @()
  if ($trip) {
    $bkey = 'breaker:' + $today
    Update-UtdLedger $P.Ledger { param($j) Add-UtdEvent $j '' 'breaker-held' ("{0} live recipe(s) would come down, over the bar of {1} ({2} live): none taken down" -f $cands.Count, $res.breaker.bar, $liveCount) $today; Add-UtdPageDue $j '' $bkey }.GetNewClosure()
  } else { $toTake = $cands }
  foreach ($f in $inflight) {
    if (@($toTake | Where-Object { $_.slug -eq [string]$f.slug }).Count -eq 0) {
      $fl = if ($byslug.ContainsKey([string]$f.slug)) { $byslug[[string]$f.slug].lines } else { @($f.lines) }
      $toTake += [pscustomobject]@{ slug = [string]$f.slug; name = [string]$f.name; lines = $fl }
    }
  }

  foreach ($c in $toTake) {
    $s = $c.slug
    $why = (@($c.lines | ForEach-Object { $_.item + ' (' + $_.class + ': ' + $_.gap + ')' }) -join '; ')
    $reason = $script:UtdReasonPrefix + $today + ' ' + $why + ". Brad's ruling Q1-2026-09-20-partial-cost (B): a live recipe that cannot be fully costed comes down."
    $jh = $null; if ($hashes.PSObject.Properties[$s]) { $jh = [string]$hashes.$s }
    $prior = $null; if ($ours.ContainsKey($s)) { $prior = $ours[$s] }
    if ($null -ne $prior -and $prior.PSObject.Properties['journal_hash'] -and $prior.journal_hash) { $jh = [string]$prior.journal_hash }
    $vis = if ($believed.ContainsKey($s)) { $believed[$s] } else { 'paid' }
    $lines = $c.lines; $nm = $c.name
    # 1. THE INTENT ROW FIRST: it carries the hash hold-recipe is about to remove
    Update-UtdLedger $P.Ledger { param($j) Set-UtdRow $j $s @{ name = $nm; state = 'taking-down'; taken_down = $today; lines = @($lines); journal_hash = $jh; visibility = $vis; restored = $null } }.GetNewClosure()
    # 2. THE HOLD, through hold-recipe; a Ghost already drafted by a crashed run finishes with -SkipGhost
    $heldNow = Get-HeldRecipeSet $P.Db
    if (-not $heldNow.slugs.ContainsKey($s)) {
      $h = & $Seams.Hold $s $reason $false
      if ($h.rc -ne 0 -and ([string]$h.out) -match 'already has .* as a DRAFT') { $h = & $Seams.Hold $s $reason $true }
      if ($h.rc -ne 0) {
        $res.refused += [pscustomobject]@{ slug = $s; name = $nm; stage = 'takedown'; why = ('hold-recipe refused: ' + [string]$h.out) }
        $fkey = 'takedown-failed:' + $s + ':' + $today
        Update-UtdLedger $P.Ledger { param($j) Add-UtdEvent $j $s 'takedown-failed' ([string]$h.out) $today; Add-UtdPageDue $j $s $fkey }.GetNewClosure()
        continue
      }
    }
    # 3. DOWN, and the page is due
    $dkey = 'takedown:' + $s + ':' + $today
    if ($null -ne $prior -and $prior.PSObject.Properties['taken_down'] -and $prior.taken_down) { $dkey = 'takedown:' + $s + ':' + [string]$prior.taken_down }
    Update-UtdLedger $P.Ledger { param($j) Set-UtdRow $j $s @{ state = 'down' }; Add-UtdEvent $j $s 'takedown' $why $today; Add-UtdPageDue $j $s $dkey }.GetNewClosure()
    $res.taken_down += [pscustomobject]@{ slug = $s; name = $nm; lines = $lines }
  }

  foreach ($o in $restores) {
    $s = [string]$o.slug
    $nm = if ($byslug.ContainsKey($s)) { $byslug[$s].name } else { $s }
    $vis = if ($believed.ContainsKey($s)) { $believed[$s] } else { 'paid' }
    $heldNow = Get-HeldRecipeSet $P.Db
    $isHeld = $heldNow.slugs.ContainsKey($s)
    if ($isHeld -and -not ([string]$heldNow.slugs[$s]).StartsWith($script:UtdReasonPrefix, [StringComparison]::Ordinal)) {
      # SOMEONE ELSE HOLDS IT NOW (Brad, a session): theirs to release, never ours
      Update-UtdLedger $P.Ledger { param($j) Set-UtdRow $j $s @{ state = 'manual-hold' }; Add-UtdEvent $j $s 'manual-hold' 'every line prices again, but the recipe is held for another reason - left alone' $today }.GetNewClosure()
      $res.refused += [pscustomobject]@{ slug = $s; name = $nm; stage = 'restore'; why = 'held for another reason; not ours to release' }
      continue
    }

    # 1. LOOK FIRST: what does Ghost hold, and would this bring a paid recipe back free?
    $g = & $Seams.GhostRead $s
    if (-not $g.ok) { $res.refused += (Save-UtdRefusal $P.Ledger $s $nm 'ghost-unread' ('could not read the post before restoring it: ' + $g.why) 'down' $today); continue }
    if (-not (Test-UtdPaywallRestoreSafe -Believed $vis -GhostVisibility $g.visibility)) {
      $res.refused += (Save-UtdRefusal $P.Ledger $s $nm 'paywall' ('recipes-db sells it as ' + $vis + ' but Ghost holds the post as ' + $g.visibility + ': a republish preserves that, so it would come back FREE') 'down' $today); continue
    }
    $published = ((-not $isHeld) -and ([string]$g.status -eq 'published'))
    if (-not $published) {
      Update-UtdLedger $P.Ledger { param($j) Set-UtdRow $j $s @{ state = 'restoring' } }.GetNewClosure()
      # 2. RELEASE (ours only), 3. REPUBLISH through the gated road, cost-only, proved against the hash it had live
      if ($isHeld) {
        $rl = & $Seams.Release $s ('every line prices again (' + $today + ')')
        if ($rl.rc -ne 0) { $res.refused += (Save-UtdRefusal $P.Ledger $s $nm 'release' ('hold-recipe -Release refused: ' + [string]$rl.out) 'down' $today); continue }
      }
      $jp = Join-Path ([IO.Path]::GetTempPath()) ('utd-j-' + [guid]::NewGuid().ToString('N') + '.json')
      $jh = $null; if ($o.PSObject.Properties['journal_hash'] -and $o.journal_hash) { $jh = [string]$o.journal_hash }
      $jo = [ordered]@{}; if ($jh) { $jo[$s] = $jh }
      [IO.File]::WriteAllText($jp, (ConvertTo-Json ([pscustomobject]$jo) -Depth 3), (New-Object Text.UTF8Encoding($false)))
      $rp = $null
      try { $rp = & $Seams.Republish $s $jp } catch { $rp = [pscustomobject]@{ ok = $false; why = ('republish threw: ' + $_.Exception.Message) } } finally { Remove-Item -LiteralPath $jp -Force -ErrorAction SilentlyContinue }
      if (-not $rp.ok) {
        # NOT LIVE AND NOT PROTECTED is the state to leave least: put the hold back (Ghost is still a draft)
        $g2 = & $Seams.GhostRead $s
        $skip = ($g2.ok -and [string]$g2.status -eq 'draft')
        $rh = & $Seams.Hold $s ($script:UtdReasonPrefix + $today + ' restore did not land, held again: ' + $rp.why) $skip
        $res.refused += (Save-UtdRefusal $P.Ledger $s $nm 'republish' ('the republish did not land (' + $rp.why + '); held again, rc ' + $rh.rc) 'down' $today); continue
      }
    }
    # 4. VERIFY BY RE-READING, in the direction that loses money
    $g3 = & $Seams.GhostRead $s
    if (-not $g3.ok -or [string]$g3.status -ne 'published') {
      $res.refused += (Save-UtdRefusal $P.Ledger $s $nm 'unverified' ('after the republish Ghost reports status ' + [string]$g3.status + ' ' + [string]$g3.why) 'restoring' $today); continue
    }
    if (-not (Test-UtdPaywallRestoreSafe -Believed $vis -GhostVisibility $g3.visibility)) {
      $rh = & $Seams.Hold $s ($script:UtdReasonPrefix + $today + ' came back FREE after a restore (sold as ' + $vis + '), drafted again') $false
      $res.refused += (Save-UtdRefusal $P.Ledger $s $nm 'came-back-free' ('a ' + $vis + ' recipe came back ' + [string]$g3.visibility + ' - drafted again, hold rc ' + $rh.rc) 'down' $today); continue
    }
    $rkey = 'restored:' + $s + ':' + $today
    Update-UtdLedger $P.Ledger { param($j) Set-UtdRow $j $s @{ state = 'restored'; restored = $today; restore_refused = $null }; Add-UtdEvent $j $s 'restored' 'every line prices again; republished cost-only and verified' $today; Add-UtdPageDue $j $s $rkey }.GetNewClosure()
    $res.restored += [pscustomobject]@{ slug = $s; name = $nm }
  }

  # PAGES DUE (unsent), read back from the ledger so a page a crashed run left due is sent now
  $fin = Read-UtdLedger $P.Ledger
  $pg = @()
  foreach ($k in @($fin.pages.PSObject.Properties)) { if ($null -eq $k.Value) { $pg += [pscustomobject]@{ key = $k.Name; kind = ($k.Name -split ':')[0]; slug = ''; name = ''; detail = ("{0} live recipe(s) would have come down in one run, over the bar of {1} ({2} live, 1/{3}). NONE was taken down. A mass take-down means the board or feed broke, not the recipes: read today's board and feed before anything else. Would-take-down: {4}" -f $res.breaker.count, $res.breaker.bar, $liveCount, $script:UtdBreakerShareDenominator, ((@($res.would) | ForEach-Object { $_.slug + ' [' + ((@($_.lines) | ForEach-Object { $_.item }) -join ', ') + ']' }) -join '; ')) } } }
  foreach ($rp in @($fin.rows.PSObject.Properties)) {
    $r = $rp.Value
    foreach ($k in @($r.pages.PSObject.Properties)) {
      if ($null -ne $k.Value) { continue }
      $kind = ($k.Name -split ':')[0]
      $det = switch ($kind) {
        'takedown'         { 'Taken down to a draft on ' + [string]$r.taken_down + ': ' + ((@($r.lines) | ForEach-Object { $_.item + ' - ' + $_.class + ' (' + $_.gap + ')' }) -join '; ') + '. It comes back by itself when every line prices again. Ledger: meal-prep\db\unpriced-takedowns.json.' }
        'takedown-failed'  { 'The chain could not take this recipe down; it is STILL LIVE with a cost that leaves out a line. ' + ((@($fin.events) | Where-Object { $_.slug -eq $rp.Name -and $_.event -eq 'takedown-failed' } | Select-Object -Last 1 | ForEach-Object { $_.detail }) -join '') }
        'restored'         { 'Every line prices again; republished cost-only through the gated road on ' + [string]$r.restored + ' and verified live at its sold visibility.' }
        'restore-refused'  { 'Every line prices again but the restore was refused: ' + [string]$r.restore_refused }
        default            { throw ('unpriced-takedown: unknown page kind in the ledger: ' + $k.Name) }
      }
      $pg += [pscustomobject]@{ key = $k.Name; kind = $kind; slug = $rp.Name; name = $(if ($r.PSObject.Properties['name']) { [string]$r.name } else { $rp.Name }); detail = $det }
    }
  }
  $res.pages = $pg
  return $res
}

function Invoke-UtdMarkPaged([string]$Mp, [string]$Keys, [string]$Today) {
  $P = Get-UtdPaths $Mp
  $want = @(([string]$Keys).Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
  $marked = 0
  Update-UtdLedger $P.Ledger {
    param($j)
    foreach ($k in $want) {
      if ($j.pages.PSObject.Properties[$k]) { $j.pages.$k = $Today; $script:UtdMarked++ ; continue }
      foreach ($rp in @($j.rows.PSObject.Properties)) { if ($rp.Value.pages.PSObject.Properties[$k]) { $rp.Value.pages.$k = $Today; $script:UtdMarked++ } }
    }
  }.GetNewClosure()
}

function Format-UtdComplete($R) {
  return ('UNPRICED-TAKEDOWN-COMPLETE mode={0} live={1} would={2} down={3} restored={4} would_restore={5} still_down={6} refused={7} breaker={8} bar={9} pages={10}{11}' -f $R.mode, $R.live, @($R.would).Count, @($R.taken_down).Count, @($R.restored).Count, @($R.would_restore).Count, @($R.still_down).Count, @($R.refused).Count, $(if ($R.breaker.tripped) { 'held' } else { 'ok' }), $R.breaker.bar, @($R.pages).Count, $(if ($R.blind) { ' blind=' + ($R.blind -replace '\s', '_').Substring(0, [math]::Min(60, $R.blind.Length)) } else { '' }))
}

# =============================================================================================================
if ($SelfTest) {
  $script:uc = 0; $script:uf = 0
  function UtdT([string]$Name, [bool]$Ok, [string]$Got) {
    $script:uc++
    if ($Ok) { Write-Output ('  ok    ' + $Name) } else { Write-Output ('  FAIL  ' + $Name + '   got: ' + $Got); $script:uf++ }
  }
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ('utd-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
  New-Item -ItemType Directory -Path $tmp -ErrorAction Stop | Out-Null
  $u8 = New-Object Text.UTF8Encoding($false)
  $now = [datetime]'2026-09-25T09:00:00'
  try {
    # A fixture meal-prep: N live recipes, every one fully priced, plus whatever a case adds.
    function New-UtdFixture([string]$Name, [int]$Live) {
      $m = Join-Path $tmp $Name
      [void](New-Item -ItemType Directory -Force (Join-Path $m 'db\recipes'))
      $rows = @(); $hash = [ordered]@{}; $rdb = @()
      for ($i = 1; $i -le $Live; $i++) {
        $s = ('fx-recipe-{0:D3}' -f $i)
        $spec = [pscustomobject]@{ slug = $s; name = ('Fx Recipe ' + $i); scaler = [pscustomobject]@{ ing = @([pscustomobject]@{ item = 'Chicken'; grams = 1000 }, [pscustomobject]@{ item = 'Rice'; grams = 500 }) } }
        [IO.File]::WriteAllText((Join-Path $m ('db\recipes\' + $s + '.json')), ($spec | ConvertTo-Json -Depth 6), $u8)
        $rows += [pscustomobject]@{ proposed_name = ('Fx Recipe ' + $i); slug = $s; lines_priced = 2; lines_unpriced = 0; lines_uncarried = 0; uncarried = @(); lines = @([pscustomobject]@{ item = 'Chicken' }, [pscustomobject]@{ item = 'Rice' }) }
        $hash[$s] = ('h' + $i)
        $rdb += [pscustomobject]@{ slug = $s; visibility = 'paid' }
      }
      [IO.File]::WriteAllText((Join-Path $m 'db\costed.json'), (ConvertTo-Json @($rows) -Depth 6), $u8)
      [IO.File]::WriteAllText((Join-Path $m 'db\costed.stamp.json'), (ConvertTo-Json ([pscustomobject]@{ generated = '2026-09-25T08:10:00'; scope = 'full'; flags_set_aside = [pscustomobject]@{ held_lines = @() } }) -Depth 4), $u8)
      [IO.File]::WriteAllText((Join-Path $m 'db\published-hashes.json'), (ConvertTo-Json ([pscustomobject]$hash) -Depth 3), $u8)
      [IO.File]::WriteAllText((Join-Path $m 'recipes-db.json'), (ConvertTo-Json ([pscustomobject]@{ recipes = @($rdb) }) -Depth 4), $u8)
      [IO.File]::WriteAllText((Join-Path $m 'db\cost-flags.txt'), '', $u8)
      return $m
    }
    # Make fx-recipe-NNN lose a line the way the engine loses one: the costed row keeps only Chicken.
    function Set-UtdUnpriced([string]$M, [string[]]$Slugs, [string]$Item = 'Rice', [string]$Verdict = '') {
      $cp = Join-Path $M 'db\costed.json'
      $rowsRaw = Read-JsonFile $cp; $rows = @($rowsRaw)
      $flags = @()
      foreach ($r in $rows) {
        if ($Slugs -contains [string]$r.slug) {
          $r.lines = @($r.lines | Where-Object { $_.item -ne $Item }); $r.lines_unpriced = 1; $r.lines_priced = 1
          if ($Verdict) { $r.uncarried = @($Item + ' [' + $Verdict + ']'); $r.lines_uncarried = 1 }
          $flags += ('LIVE :: ' + $r.proposed_name + ' :: ' + $Item + ' :: NO PRICE BASIS')
        }
      }
      [IO.File]::WriteAllText($cp, (ConvertTo-Json @($rows) -Depth 6), $u8)
      [IO.File]::WriteAllText((Join-Path $M 'db\cost-flags.txt'), (($flags -join "`n") + "`n"), $u8)
    }
    function Set-UtdPriced([string]$M, [string[]]$Slugs) {
      $cp = Join-Path $M 'db\costed.json'
      $rowsRaw = Read-JsonFile $cp; $rows = @($rowsRaw)
      foreach ($r in $rows) { if ($Slugs -contains [string]$r.slug) { $r.lines = @([pscustomobject]@{ item = 'Chicken' }, [pscustomobject]@{ item = 'Rice' }); $r.lines_unpriced = 0; $r.lines_priced = 2; $r.uncarried = @(); $r.lines_uncarried = 0 } }
      [IO.File]::WriteAllText($cp, (ConvertTo-Json @($rows) -Depth 6), $u8)
      [IO.File]::WriteAllText((Join-Path $M 'db\cost-flags.txt'), '', $u8)
    }
    function Set-UtdSwitch([string]$M, [string]$Mode) { [IO.File]::WriteAllText((Join-Path $M 'db\unpriced-takedown-switch.json'), ('{ "mode": "' + $Mode + '" }'), $u8) }
    # FAKE GHOST + STUB SEAMS. Hold and Release run the REAL hold-recipe.ps1 with -SkipGhost against the fixture,
    # so the held list and the hash removal are the production writer's own; the stub plays only Ghost's part.
    $hrPath = Join-Path $here 'hold-recipe.ps1'
    function New-UtdStubSeams([string]$M, [hashtable]$Ghost, [hashtable]$Calls, [bool]$RepublishOk = $true, [string]$ComesBackAs = '') {
      $hr = $hrPath
      return @{
        Hold = { param([string]$Slug, [string]$Reason, [bool]$SkipGhost)
          $Calls['hold'] = 1 + [int]$Calls['hold']
          if (-not $SkipGhost) {
            if ($Ghost.ContainsKey($Slug) -and $Ghost[$Slug].status -eq 'draft') { return [pscustomobject]@{ rc = 1; out = ("hold-recipe: ghost already has '" + $Slug + "' as a DRAFT.") } }
            if ($Ghost.ContainsKey($Slug)) { $Ghost[$Slug].status = 'draft' }
          }
          $o = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $hr -Slug $Slug -Reason $Reason -Apply -SkipGhost -Root $M | ForEach-Object { [string]$_ })
          return [pscustomobject]@{ rc = $LASTEXITCODE; out = ($o -join ' | ') } }.GetNewClosure()
        Release = { param([string]$Slug, [string]$Reason)
          $Calls['release'] = 1 + [int]$Calls['release']
          $o = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $hr -Slug $Slug -Release -Reason $Reason -Apply -Root $M | ForEach-Object { [string]$_ })
          return [pscustomobject]@{ rc = $LASTEXITCODE; out = ($o -join ' | ') } }.GetNewClosure()
        GhostRead = { param([string]$Slug)
          if (-not $Ghost.ContainsKey($Slug)) { return [pscustomobject]@{ ok = $false; status = ''; visibility = ''; why = 'no post' } }
          return [pscustomobject]@{ ok = $true; status = $Ghost[$Slug].status; visibility = $Ghost[$Slug].visibility; why = '' } }.GetNewClosure()
        Republish = { param([string]$Slug, [string]$JournalPath)
          $Calls['republish'] = 1 + [int]$Calls['republish']
          $Calls['journal'] = [IO.File]::ReadAllText($JournalPath)
          if (-not $RepublishOk) { return [pscustomobject]@{ ok = $false; why = 'fixture: the gated republish held it (drift)' } }
          # publish.ps1 sets status=published and PRESERVES the live visibility; it writes the published-hash back
          $Ghost[$Slug].status = 'published'
          if ($ComesBackAs) { $Ghost[$Slug].visibility = $ComesBackAs }
          $hp = Join-Path $M 'db\published-hashes.json'; $hj = Read-JsonFile $hp; $hj | Add-Member -NotePropertyName $Slug -NotePropertyValue 'h-new' -Force
          [IO.File]::WriteAllText($hp, ($hj | ConvertTo-Json -Depth 3), (New-Object Text.UTF8Encoding($false)))
          return [pscustomobject]@{ ok = $true; why = '' } }.GetNewClosure()
      }
    }
    function New-UtdGhost([int]$Live, [string]$Vis = 'paid') { $g = @{}; for ($i = 1; $i -le $Live; $i++) { $g[('fx-recipe-{0:D3}' -f $i)] = @{ status = 'published'; visibility = $Vis } }; return $g }
    function Get-UtdHeld([string]$M) { return (Get-HeldRecipeSet (Join-Path $M 'db')) }

    # ---- PURE PARTS ---------------------------------------------------------------------------------------
    $rowFx = [pscustomobject]@{ proposed_name = 'Turkey Wild Rice Casserole'; lines_unpriced = 1; uncarried = @(); lines = @([pscustomobject]@{ item = 'Ground Turkey' }) }
    $specFx = [pscustomobject]@{ scaler = [pscustomobject]@{ ing = @([pscustomobject]@{ item = 'Ground Turkey'; grams = 900 }, [pscustomobject]@{ item = 'Wild Rice'; grams = 855 }, [pscustomobject]@{ item = 'Water'; grams = 0 }) } }
    $flFx = @('LIVE :: Turkey Wild Rice Casserole :: Wild Rice :: MAPPED BID NOT ON ANY BOARD (wild-rice)', 'LIVE :: Turkey Wild Rice Casserole :: Wild Rice :: NO PRICE BASIS')
    $ul = Get-UtdUnpricedLines -Row $rowFx -Spec $specFx -FlagLines $flFx
    UtdT 'MUST FIRE  the founding row (turkey-wild-rice-casserole, 2026-09-19) names Wild Rice, carried, with the engine''s two reasons' (($ul.Count -eq 1) -and ($ul[0].item -eq 'Wild Rice') -and ($ul[0].class -eq 'CARRIED-NO-PRICE') -and ($ul[0].gap -like '*MAPPED BID NOT ON ANY BOARD (wild-rice); NO PRICE BASIS*')) (ConvertTo-Json @($ul) -Compress)
    UtdT 'MUST NOT FIRE a zero-gram spec line (Water) is not an unpriced line' (@($ul | Where-Object { $_.item -eq 'Water' }).Count -eq 0) (ConvertTo-Json @($ul) -Compress)
    $rowNc = [pscustomobject]@{ proposed_name = 'Harissa Chicken Rice Bowls'; lines_unpriced = 1; uncarried = @('Harissa Paste [NOT-CARRIED]'); lines = @() }
    $specNc = [pscustomobject]@{ scaler = [pscustomobject]@{ ing = @([pscustomobject]@{ item = 'Harissa Paste'; grams = 80 }) } }
    $ulNc = Get-UtdUnpricedLines -Row $rowNc -Spec $specNc -FlagLines @()
    UtdT 'CLEAN TWIN  a NOT-CARRIED line is classed NOT-CARRIED, not carried-no-price' (($ulNc.Count -eq 1) -and ($ulNc[0].class -eq 'NOT-CARRIED')) (ConvertTo-Json @($ulNc) -Compress)
    $rowGhost = [pscustomobject]@{ proposed_name = 'X'; lines_unpriced = 2; uncarried = @(); lines = @([pscustomobject]@{ item = 'A' }) }
    $ulG = Get-UtdUnpricedLines -Row $rowGhost -Spec ([pscustomobject]@{ scaler = [pscustomobject]@{ ing = @([pscustomobject]@{ item = 'A'; grams = 5 }) } }) -FlagLines @()
    UtdT 'MUST FIRE  a row claiming unpriced lines the spec cannot name still returns a line, never an agreeing zero' (($ulG.Count -eq 1) -and ($ulG[0].item -eq '(unnamed line)')) (ConvertTo-Json @($ulG) -Compress)
    $dupSpec = [pscustomobject]@{ scaler = [pscustomobject]@{ ing = @([pscustomobject]@{ item = 'Lemon'; grams = 70 }, [pscustomobject]@{ item = 'Lemon'; grams = 5 }) } }
    $ulD = Get-UtdUnpricedLines -Row ([pscustomobject]@{ proposed_name = 'Y'; lines_unpriced = 1; uncarried = @(); lines = @([pscustomobject]@{ item = 'Lemon' }) }) -Spec $dupSpec -FlagLines @()
    UtdT 'MUST FIRE  the diff is a MULTISET: one of two Lemon lines dropped is still named' (($ulD.Count -eq 1) -and ($ulD[0].item -eq 'Lemon')) (ConvertTo-Json @($ulD) -Compress)
    # THE BAR, AT IT AND ONE PAST IT (1/50 of live; integers, so the double decides nothing)
    UtdT 'MUST NOT FIRE the breaker at the bar: 10 of 500 live (exactly 2%) passes' (-not (Test-UtdBreaker -Count 10 -Live 500)) 'tripped'
    UtdT 'MUST FIRE  the breaker one past the bar: 11 of 500 live holds' (Test-UtdBreaker -Count 11 -Live 500) 'passed'
    UtdT 'MUST FIRE  the breaker with no live set and any take-down holds (an empty live set is not permission)' (Test-UtdBreaker -Count 1 -Live 0) 'passed'
    UtdT 'MUST NOT FIRE nothing to take down never trips' (-not (Test-UtdBreaker -Count 0 -Live 0)) 'tripped'
    UtdT 'MUST FIRE  a paid recipe Ghost holds public is not restore-safe' (-not (Test-UtdPaywallRestoreSafe -Believed 'paid' -GhostVisibility 'public')) 'safe'
    UtdT 'CLEAN TWIN  a paid recipe held paid, and a public one held public, are restore-safe' ((Test-UtdPaywallRestoreSafe -Believed 'paid' -GhostVisibility 'paid') -and (Test-UtdPaywallRestoreSafe -Believed 'public' -GhostVisibility 'public')) 'unsafe'
    $mBad = Get-UtdMode -SwitchPath (Join-Path $tmp 'nope.json') -ForceDry $false
    UtdT 'CLEAN TWIN  no switch file is dry-run' ($mBad.mode -eq 'dry-run') $mBad.mode
    [IO.File]::WriteAllText((Join-Path $tmp 'sw.json'), '{ "mode": "yes please" }', $u8)
    $mBad2 = Get-UtdMode -SwitchPath (Join-Path $tmp 'sw.json') -ForceDry $false
    UtdT 'MUST FIRE  an unknown switch mode is refused, not guessed' ($mBad2.mode -eq '') $mBad2.why
    [IO.File]::WriteAllText((Join-Path $tmp 'sw2.json'), '{ "mode": "on" }', $u8)
    $mF = Get-UtdMode -SwitchPath (Join-Path $tmp 'sw2.json') -ForceDry $true
    UtdT 'MUST FIRE  -DryRun forces dry-run over a switch that says on' ($mF.mode -eq 'dry-run') $mF.mode

    # ---- END TO END ---------------------------------------------------------------------------------------
    # A. dry-run (the shipped switch) writes NOTHING and still reports the would-take-down row
    $mA = New-UtdFixture 'a' 100
    Set-UtdUnpriced $mA @('fx-recipe-007')
    $before = @(Get-ChildItem -LiteralPath $mA -Recurse -File | ForEach-Object { $_.FullName + '=' + (Get-FileHash -LiteralPath $_.FullName).Hash })
    $gA = New-UtdGhost 100; $cA = @{}
    $rA = Invoke-UtdRun -Mp $mA -ForceDry $false -MaxAgeHours 26 -Now $now -Seams (New-UtdStubSeams $mA $gA $cA)
    $after = @(Get-ChildItem -LiteralPath $mA -Recurse -File | ForEach-Object { $_.FullName + '=' + (Get-FileHash -LiteralPath $_.FullName).Hash })
    UtdT 'MUST FIRE  dry-run reports the recipe it WOULD take down, with the line' ((@($rA.would).Count -eq 1) -and ($rA.would[0].slug -eq 'fx-recipe-007') -and ($rA.would[0].lines[0].item -eq 'Rice')) (Format-UtdComplete $rA)
    UtdT 'MUST NOT FIRE dry-run writes nothing: every file byte-identical, no ledger, no hold, no Ghost write' ((($before -join '|') -eq ($after -join '|')) -and ([int]$cA['hold'] -eq 0) -and ($gA['fx-recipe-007'].status -eq 'published') -and (@($rA.pages).Count -eq 0)) ('files ' + $before.Count + '->' + $after.Count + ' hold=' + [int]$cA['hold'])

    # B. ON: an unpriceable line drafts the recipe, records why, and pages ONCE
    Set-UtdSwitch $mA 'on'
    $rB = Invoke-UtdRun -Mp $mA -ForceDry $false -MaxAgeHours 26 -Now $now -Seams (New-UtdStubSeams $mA $gA $cA)
    $hB = Get-UtdHeld $mA
    $lB = Read-JsonFile (Join-Path $mA 'db\unpriced-takedowns.json')
    $hashB = Read-JsonFile (Join-Path $mA 'db\published-hashes.json')
    UtdT 'MUST FIRE  an unpriceable line on a live recipe drafts it: Ghost draft, held with our reason, hash removed' (($gA['fx-recipe-007'].status -eq 'draft') -and $hB.slugs.ContainsKey('fx-recipe-007') -and ([string]$hB.slugs['fx-recipe-007']).StartsWith($script:UtdReasonPrefix) -and (-not $hashB.PSObject.Properties['fx-recipe-007'])) ((Format-UtdComplete $rB) + ' ghost=' + $gA['fx-recipe-007'].status)
    UtdT '  ...and the ledger records the recipe, the line, the store gap, the date and the hash it had live' (($lB.rows.'fx-recipe-007'.state -eq 'down') -and ($lB.rows.'fx-recipe-007'.lines[0].item -eq 'Rice') -and ($lB.rows.'fx-recipe-007'.lines[0].gap -like '*NO PRICE BASIS*') -and ($lB.rows.'fx-recipe-007'.taken_down -eq '2026-09-25') -and ($lB.rows.'fx-recipe-007'.journal_hash -eq 'h7')) ($lB.rows.'fx-recipe-007' | ConvertTo-Json -Depth 5 -Compress)
    $pB = @($rB.pages | Where-Object { $_.kind -eq 'takedown' })
    UtdT '  ...and exactly one takedown page is due, naming the recipe and the line' (($pB.Count -eq 1) -and ($pB[0].slug -eq 'fx-recipe-007') -and ($pB[0].detail -like '*Rice - CARRIED-NO-PRICE*')) (ConvertTo-Json @($rB.pages) -Depth 4 -Compress)
    Invoke-UtdMarkPaged $mA $pB[0].key '2026-09-25'
    $rB2 = Invoke-UtdRun -Mp $mA -ForceDry $false -MaxAgeHours 26 -Now $now -Seams (New-UtdStubSeams $mA $gA $cA)
    UtdT 'MUST NOT FIRE a second run the same day neither holds again nor pages again once the page was sent' ((@($rB2.pages).Count -eq 0) -and (@($rB2.taken_down).Count -eq 0) -and ([int]$cA['hold'] -eq 1)) ('pages=' + @($rB2.pages).Count + ' holds=' + [int]$cA['hold'])
    UtdT 'CLEAN TWIN  a fully priced live recipe is untouched: still published, not held, hash kept' (($gA['fx-recipe-008'].status -eq 'published') -and (-not $hB.slugs.ContainsKey('fx-recipe-008')) -and ($hashB.'fx-recipe-008' -eq 'h8')) ('ghost=' + $gA['fx-recipe-008'].status)

    # C. a page the chain did not mark stays due (at least once), and survives the run that did not send it
    $mC = New-UtdFixture 'c' 100; Set-UtdSwitch $mC 'on'; Set-UtdUnpriced $mC @('fx-recipe-003')
    $gC = New-UtdGhost 100; $cC = @{}
    $null = Invoke-UtdRun -Mp $mC -ForceDry $false -MaxAgeHours 26 -Now $now -Seams (New-UtdStubSeams $mC $gC $cC)
    $rC2 = Invoke-UtdRun -Mp $mC -ForceDry $false -MaxAgeHours 26 -Now $now -Seams (New-UtdStubSeams $mC $gC $cC)
    UtdT 'MUST FIRE  an unsent takedown page is still due on the next run (at least once)' (@($rC2.pages | Where-Object { $_.kind -eq 'takedown' -and $_.slug -eq 'fx-recipe-003' }).Count -eq 1) (ConvertTo-Json @($rC2.pages) -Depth 4 -Compress)

    # D. CRASH RECOVERY: Ghost drafted, nothing local written (a run died inside hold-recipe) -> the retry finishes with -SkipGhost
    $mD = New-UtdFixture 'd' 100; Set-UtdSwitch $mD 'on'; Set-UtdUnpriced $mD @('fx-recipe-004')
    $gD = New-UtdGhost 100; $gD['fx-recipe-004'].status = 'draft'; $cD = @{}
    $rD = Invoke-UtdRun -Mp $mD -ForceDry $false -MaxAgeHours 26 -Now $now -Seams (New-UtdStubSeams $mD $gD $cD)
    UtdT 'MUST FIRE  a Ghost already drafted by a crashed run is finished locally (-SkipGhost), not left half-done' (((Get-UtdHeld $mD).slugs.ContainsKey('fx-recipe-004')) -and (@($rD.taken_down).Count -eq 1) -and ([int]$cD['hold'] -eq 2)) ((Format-UtdComplete $rD) + ' holds=' + [int]$cD['hold'])
    # D2. a hold with our prefix and NO ledger row (crash after hold-recipe, before the row) is rebuilt into one
    Remove-Item -LiteralPath (Join-Path $mD 'db\unpriced-takedowns.json') -Force
    Set-UtdPriced $mD @('fx-recipe-004')
    $rD2 = Invoke-UtdRun -Mp $mD -ForceDry $false -MaxAgeHours 26 -Now $now -Seams (New-UtdStubSeams $mD $gD $cD)
    UtdT 'MUST FIRE  a hold of ours with no ledger row is still restored when its lines price (the held list alone recovers)' ((@($rD2.restored).Count -eq 1) -and ($gD['fx-recipe-004'].status -eq 'published') -and -not ((Get-UtdHeld $mD).slugs.ContainsKey('fx-recipe-004'))) (Format-UtdComplete $rD2)

    # E. RESTORE: every line prices again -> released, republished through the gated seam with the hash it had live
    Set-UtdPriced $mA @('fx-recipe-007')
    $rE = Invoke-UtdRun -Mp $mA -ForceDry $false -MaxAgeHours 26 -Now $now -Seams (New-UtdStubSeams $mA $gA $cA)
    $lE = Read-JsonFile (Join-Path $mA 'db\unpriced-takedowns.json')
    UtdT 'MUST FIRE  a restored price republishes it: released, published, ledger restored, restore page due' ((@($rE.restored).Count -eq 1) -and ($gA['fx-recipe-007'].status -eq 'published') -and -not ((Get-UtdHeld $mA).slugs.ContainsKey('fx-recipe-007')) -and ($lE.rows.'fx-recipe-007'.state -eq 'restored') -and (@($rE.pages | Where-Object { $_.kind -eq 'restored' }).Count -eq 1)) (Format-UtdComplete $rE)
    UtdT '  ...and the cost-only proof was handed the hash the page had live (h7), not an empty journal' (([string]$cA['journal']) -match '"fx-recipe-007"\s*:\s*"h7"') ([string]$cA['journal'])
    UtdT 'CLEAN TWIN  the paid recipe came back PAID (the restore of a paid recipe stays paid)' ($gA['fx-recipe-007'].visibility -eq 'paid') $gA['fx-recipe-007'].visibility
    $rE2 = Invoke-UtdRun -Mp $mA -ForceDry $false -MaxAgeHours 26 -Now $now -Seams (New-UtdStubSeams $mA $gA $cA)
    UtdT 'MUST NOT FIRE a restored recipe is not restored twice' ((@($rE2.restored).Count -eq 0) -and ([int]$cA['republish'] -eq 1)) ('republish calls=' + [int]$cA['republish'])

    # F. PAYWALL, the money-losing direction: Ghost holds a paid recipe's post PUBLIC -> no restore at all
    $mF = New-UtdFixture 'f' 100; Set-UtdSwitch $mF 'on'; Set-UtdUnpriced $mF @('fx-recipe-005')
    $gF = New-UtdGhost 100; $cF = @{}
    $null = Invoke-UtdRun -Mp $mF -ForceDry $false -MaxAgeHours 26 -Now $now -Seams (New-UtdStubSeams $mF $gF $cF)
    $gF['fx-recipe-005'].visibility = 'public'      # the rotation, or a hand in Ghost admin, freed the draft
    Set-UtdPriced $mF @('fx-recipe-005')
    $rF = Invoke-UtdRun -Mp $mF -ForceDry $false -MaxAgeHours 26 -Now $now -Seams (New-UtdStubSeams $mF $gF $cF)
    UtdT 'MUST FIRE  a paid recipe whose post Ghost holds public is NOT restored: still draft, still held, refusal paged' (($gF['fx-recipe-005'].status -eq 'draft') -and ((Get-UtdHeld $mF).slugs.ContainsKey('fx-recipe-005')) -and ([int]$cF['republish'] -eq 0) -and (@($rF.pages | Where-Object { $_.kind -eq 'restore-refused' }).Count -eq 1)) (Format-UtdComplete $rF)
    # F2. it comes back FREE after the republish (a race) -> drafted again on the spot
    $mF2 = New-UtdFixture 'f2' 100; Set-UtdSwitch $mF2 'on'; Set-UtdUnpriced $mF2 @('fx-recipe-006')
    $gF2 = New-UtdGhost 100; $cF2 = @{}
    $null = Invoke-UtdRun -Mp $mF2 -ForceDry $false -MaxAgeHours 26 -Now $now -Seams (New-UtdStubSeams $mF2 $gF2 $cF2)
    Set-UtdPriced $mF2 @('fx-recipe-006')
    $rF2 = Invoke-UtdRun -Mp $mF2 -ForceDry $false -MaxAgeHours 26 -Now $now -Seams (New-UtdStubSeams $mF2 $gF2 $cF2 $true 'public')
    UtdT 'MUST FIRE  a paid recipe that comes back public is drafted again at once and pages' (($gF2['fx-recipe-006'].status -eq 'draft') -and ((Get-UtdHeld $mF2).slugs.ContainsKey('fx-recipe-006')) -and (@($rF2.restored).Count -eq 0) -and (@($rF2.pages | Where-Object { $_.kind -eq 'restore-refused' -and $_.key -like '*came-back-free' }).Count -eq 1)) (Format-UtdComplete $rF2)

    # G. a republish the gated road holds leaves the recipe HELD again (never released-and-unpublished)
    $mG = New-UtdFixture 'g' 100; Set-UtdSwitch $mG 'on'; Set-UtdUnpriced $mG @('fx-recipe-009')
    $gG = New-UtdGhost 100; $cG = @{}
    $null = Invoke-UtdRun -Mp $mG -ForceDry $false -MaxAgeHours 26 -Now $now -Seams (New-UtdStubSeams $mG $gG $cG)
    Set-UtdPriced $mG @('fx-recipe-009')
    $rG = Invoke-UtdRun -Mp $mG -ForceDry $false -MaxAgeHours 26 -Now $now -Seams (New-UtdStubSeams $mG $gG $cG $false)
    UtdT 'MUST FIRE  a restore the gated republish holds is held again and pages; the post stays a draft' (((Get-UtdHeld $mG).slugs.ContainsKey('fx-recipe-009')) -and ($gG['fx-recipe-009'].status -eq 'draft') -and (@($rG.restored).Count -eq 0) -and (@($rG.pages | Where-Object { $_.kind -eq 'restore-refused' }).Count -eq 1)) (Format-UtdComplete $rG)

    # H. A HOLD THAT IS NOT OURS IS NEVER RELEASED
    $mH = New-UtdFixture 'h' 100; Set-UtdSwitch $mH 'on'; Set-UtdUnpriced $mH @('fx-recipe-010')
    $gH = New-UtdGhost 100; $cH = @{}
    $null = Invoke-UtdRun -Mp $mH -ForceDry $false -MaxAgeHours 26 -Now $now -Seams (New-UtdStubSeams $mH $gH $cH)
    $hp = Join-Path $mH 'db\held-recipes.json'; $hj = Read-JsonFile $hp
    foreach ($x in @($hj.held)) { if ($x.slug -eq 'fx-recipe-010') { $x.reason = 'Brad: not a dish we sell' } }
    [IO.File]::WriteAllText($hp, ($hj | ConvertTo-Json -Depth 5), $u8)
    Set-UtdPriced $mH @('fx-recipe-010')
    $rH = Invoke-UtdRun -Mp $mH -ForceDry $false -MaxAgeHours 26 -Now $now -Seams (New-UtdStubSeams $mH $gH $cH)
    UtdT 'MUST NOT FIRE a hold whose reason is not ours is never released, even when every line prices' (((Get-UtdHeld $mH).slugs.ContainsKey('fx-recipe-010')) -and ([int]$cH['release'] -eq 0) -and ($gH['fx-recipe-010'].status -eq 'draft')) (Format-UtdComplete $rH)

    # I. THE BREAKER, end to end, at the bar and one past it (100 live -> bar 2)
    $mI = New-UtdFixture 'i' 100; Set-UtdSwitch $mI 'on'; Set-UtdUnpriced $mI @('fx-recipe-001', 'fx-recipe-002')
    $gI = New-UtdGhost 100; $cI = @{}
    $rI = Invoke-UtdRun -Mp $mI -ForceDry $false -MaxAgeHours 26 -Now $now -Seams (New-UtdStubSeams $mI $gI $cI)
    UtdT 'MUST NOT FIRE the breaker at the bar end to end: 2 of 100 live (2%) come down' ((-not $rI.breaker.tripped) -and (@($rI.taken_down).Count -eq 2) -and ($rI.breaker.bar -eq 2)) (Format-UtdComplete $rI)
    $mJ = New-UtdFixture 'j' 100; Set-UtdSwitch $mJ 'on'; Set-UtdUnpriced $mJ @('fx-recipe-001', 'fx-recipe-002', 'fx-recipe-003')
    $gJ = New-UtdGhost 100; $cJ = @{}
    $rJ = Invoke-UtdRun -Mp $mJ -ForceDry $false -MaxAgeHours 26 -Now $now -Seams (New-UtdStubSeams $mJ $gJ $cJ)
    $jPub = @($gJ.Keys | Where-Object { $gJ[$_].status -eq 'published' }).Count
    UtdT 'MUST FIRE  the breaker one past the bar: 3 of 100 would come down, NONE does, and it pages' (($rJ.breaker.tripped) -and (@($rJ.taken_down).Count -eq 0) -and ([int]$cJ['hold'] -eq 0) -and ($jPub -eq 100) -and (@($rJ.pages | Where-Object { $_.kind -eq 'breaker' }).Count -eq 1)) (Format-UtdComplete $rJ)
    UtdT '  ...and the held step is SPOKEN: the would-take-down list is still reported' (@($rJ.would).Count -eq 3) (Format-UtdComplete $rJ)

    # K. WHEN THE PRODUCER STOPS: a stale recost is BLIND and acts on nothing
    $mK = New-UtdFixture 'k' 100; Set-UtdSwitch $mK 'on'; Set-UtdUnpriced $mK @('fx-recipe-001')
    $gK = New-UtdGhost 100; $cK = @{}
    $rK = Invoke-UtdRun -Mp $mK -ForceDry $false -MaxAgeHours 26 -Now ([datetime]'2026-09-26T12:00:00') -Seams (New-UtdStubSeams $mK $gK $cK)
    UtdT 'MUST FIRE  a recost older than the bar is BLIND: nothing comes down' (($rK.blind -like '*h old*') -and ([int]$cK['hold'] -eq 0) -and ($gK['fx-recipe-001'].status -eq 'published')) (Format-UtdComplete $rK)
    [IO.File]::WriteAllText((Join-Path $mK 'db\published-hashes.json'), '{}', $u8)
    $rK2 = Invoke-UtdRun -Mp $mK -ForceDry $false -MaxAgeHours 26 -Now $now -Seams (New-UtdStubSeams $mK $gK $cK)
    UtdT 'MUST FIRE  an empty published set is BLIND, never "nothing is live"' (($rK2.blind -like '*names no published recipe*') -and ([int]$cK['hold'] -eq 0)) (Format-UtdComplete $rK2)

    # L. THE CLI: the real script, as the chain calls it, dry-run, writes its result file and its marker
    $rf = Join-Path $tmp 'result.json'
    $mL = New-UtdFixture 'l' 100; Set-UtdUnpriced $mL @('fx-recipe-011')
    [IO.File]::WriteAllText((Join-Path $mL 'db\costed.stamp.json'), (ConvertTo-Json ([pscustomobject]@{ generated = (Get-Date).ToString('s'); scope = 'full' })), $u8)
    $cliOut = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Root $mL -ResultFile $rf | ForEach-Object { [string]$_ })
    $cliRc = $LASTEXITCODE
    $cliRes = $null; if (Test-Path -LiteralPath $rf) { $cliRes = Read-JsonFile $rf }
    UtdT 'CLEAN TWIN  the CLI in dry-run exits 0, names the recipe, writes the result file, and ends on its marker' (($cliRc -eq 0) -and ($null -ne $cliRes) -and (@($cliRes.would).Count -eq 1) -and ($cliOut[-1] -like 'UNPRICED-TAKEDOWN-COMPLETE mode=dry-run live=100 would=1 *')) ("rc=$cliRc last=" + $(if ($cliOut.Count) { $cliOut[-1] } else { '(none)' }))
  } catch {
    UtdT 'the self-test ran to the end' $false ($_.Exception.Message + ' @ ' + $_.InvocationInfo.ScriptLineNumber + ' ' + ($_.ScriptStackTrace -replace '\r?\n',' <- '))
  } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
  # A LITERAL LIST KNOWS ITS OWN NUMBER: a case that silently did not run is a failure, not a smaller suite
  $expect = 38
  if ($script:uc -ne $expect) { Write-Output ("  FAIL  ran {0} case(s), the suite has {1}" -f $script:uc, $expect); $script:uf++ }
  if ($script:uf -eq 0) { Write-Output ("unpriced-takedown SELF-TEST PASS ({0} cases)" -f $script:uc); exit 0 }
  Write-Output ("unpriced-takedown SELF-TEST FAIL ({0} of {1} case(s))" -f $script:uf, $script:uc); exit 1
}

# =============================================================================================================
$mpRoot = if ($Root) { $Root } else { Split-Path -Parent $here }
if ($MarkPaged) {
  Invoke-UtdMarkPaged $mpRoot $MarkPaged ((Get-Date).ToString('yyyy-MM-dd'))
  Write-Output ('UNPRICED-TAKEDOWN-COMPLETE mode=mark-paged keys=' + @($MarkPaged.Split(',') | Where-Object { $_.Trim() }).Count)
  exit 0
}
$seams = New-UtdRealSeams $mpRoot
$res = Invoke-UtdRun -Mp $mpRoot -ForceDry ([bool]$DryRun) -MaxAgeHours $MaxCostedAgeHours -Now (Get-Date) -Seams $seams
foreach ($w in @($res.would))         { Write-Output ('  ' + $(if ($res.mode -eq 'on') { 'candidate' } else { 'WOULD take down' }) + '  ' + $w.slug + ' :: ' + ((@($w.lines) | ForEach-Object { $_.item + ' [' + $_.class + '] ' + $_.gap }) -join ' || ')) }
foreach ($w in @($res.would_restore)) { Write-Output ('  ' + $(if ($res.mode -eq 'on') { 'restore candidate' } else { 'WOULD restore' }) + '  ' + $w.slug) }
foreach ($w in @($res.taken_down))    { Write-Output ('  TAKEN DOWN  ' + $w.slug) }
foreach ($w in @($res.restored))      { Write-Output ('  RESTORED  ' + $w.slug) }
foreach ($w in @($res.refused))       { Write-Output ('  REFUSED  ' + $w.slug + ' (' + $w.stage + '): ' + $w.why) }
foreach ($w in @($res.still_down))    { Write-Output ('  still down  ' + $w.slug + ' since ' + $w.since) }
if ($res.breaker.tripped) { Write-Output ("  BREAKER HELD: {0} of {1} live would come down, over the bar of {2} (1/{3}); none taken down" -f $res.breaker.count, $res.breaker.live, $res.breaker.bar, $script:UtdBreakerShareDenominator) }
if ($res.blind) { Write-Output ('  COULD NOT EVALUATE: ' + $res.blind + ' - nothing taken down, nothing restored') }
if ($ResultFile) { [IO.File]::WriteAllText($ResultFile, (ConvertTo-Json ([pscustomobject]$res) -Depth 8), (New-Object Text.UTF8Encoding($false))) }
Write-Output (Format-UtdComplete $res)
if ($res.blind) { exit 3 }
exit 0
