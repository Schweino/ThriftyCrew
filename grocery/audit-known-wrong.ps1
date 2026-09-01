<#
  audit-known-wrong.ps1 - THE BLOCKLIST GATE. "No crown a reasoner has ruled wrong is on the page."

  FOUNDING BUG (2026-07-29): audit findings lived as PROSE in .md files. honeydew was written up with the
  store's own arithmetic ($1.49/lb x 4.0 lb = $5.96) and was STILL the published crown the next morning,
  because nothing in the publish path can read a paragraph. 99 distinct wrong numbers reached shoppers in
  22 days; guards caught 5%. This file is the machine-readable half of that memory: every (commodity,
  store, product) a reasoner has ADJUDICATED wrong goes into known-wrong.json, and this audit refuses to
  publish a board that prices any of them again. It is a REGRESSION blocklist - it must be GREEN on a
  healthy board, and it goes red only when a defect that was already fixed comes back.

  WHY A NAME KEY AND NOT AN ID KEY. 85% of cells trace to a first-party product id, and every wrong product
  found this morning had one - identity proves "this price belongs to this product", never "this product
  belongs to this commodity". Worse, the board's stores[] cells carry NO id at all, and Aldi / Sam's /
  Fareway feeds publish none, so an id-only key could not evaluate 3 of 7 stores. So the key is the
  NORMALIZED PRODUCT NAME scoped to (commodity, store), with the id used only to RE-DERIVE today's spelling
  of a listed product from its own store feed.

  WHY NORMALIZED-EXACT AND NOT FUZZY. Measured over 35,362 board cells across all 19 dated boards plus the
  recipe board: 69 groups exist where several DIFFERENT raw spellings collapse to one normalized name, and
  all 69 are the SAME product re-encoded ("Jiffy(R) Corn Muffin Mix" three ways in four days, "Hy Vee" vs
  "Hy-Vee", "Clancy's" vs "Clancy S", smart quote vs mojibake pair). Zero of the 69 merged two different
  products. That is what makes the gate 100% precision BY CONSTRUCTION. The looser core-name key (same name
  with the trailing size clause stripped) merges 435 groups, and those DO contain genuinely different
  products - "Daisy Sour Cream 14 oz 2 pk" vs "48 oz", "Chunk Light Tuna 5 oz 4 Pack" vs the single can. So
  the core key is a REVIEW SIGNAL ONLY and never sets the exit code.

  ZERO-ROWS RULE. "No listed product is priced" is only meaningful if the check could see the products. It
  reports how many entries it could actually evaluate and exits 3 (could-not-evaluate) rather than 0 when
  the answer is none - a blocklist that examined nothing is not a clean board.

  RETIRE TRIGGERS. Every entry declares retire_when from a CLOSED vocabulary, and this audit EVALUATES the
  predicate every run and prints the ones that have fired. That is the direct fix for the allowlist bug
  found 2026-07-30, where two entries were justified by "the store does not carry the item" while the store
  carried it - a justification no machine could check, so it could never be retired and never be wrong.

  FAIL OPEN ON EVERYTHING THAT IS NOT THE BLOCKLIST. guards.ps1 delegates to this file and blocks the
  publish on any non-zero exit other than 3, so every input this audit reads that is NOT known-wrong.json
  is a new way for the whole board to be held hostage by an unrelated corrupt file. Three of them are new
  dependencies for the guards path - stores.json (guards reads it nowhere else today), the newest
  out\regular\<store> feed, and commodities.json - so each load is wrapped: a registry that will not parse
  becomes "trigger not evaluated" plus a NOTE, a feed that will not parse becomes "no id key for that
  store" plus a NOTE, and a board that will not parse becomes exit 3 (blind) with an accurate message
  instead of a HARD FAIL that misattributes the corruption to the blocklist. Only known-wrong.json itself
  fails closed, because a blocklist the gate cannot trust must never be reported as a pass.

  Usage:  audit-known-wrong.ps1                      (exit 0 clean / 2 a listed product is on the board / 3 blind)
          audit-known-wrong.ps1 -Root <dir>          (fixture tree)
          audit-known-wrong.ps1 -ListFile <path>     (fixture list)
          audit-known-wrong.ps1 -Report              (also write out\known-wrong-report.json)
#>
param(
  [string]$Root,
  [string]$ListFile,
  [switch]$Report
)
$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path } }
if (-not $ListFile) { $ListFile = Join-Path $Root 'known-wrong.json' }
$outDir = Join-Path $Root 'out'

# ---------------------------------------------------------------- normalizer
# Every non-alphanumeric byte becomes a space, so this is ENCODING-AGNOSTIC on purpose: "Coste" + n-tilde
# read as UTF-8 and the same bytes read as ANSI both land on the same normal form. Apostrophes are deleted
# rather than spaced so "Ken's" folds onto "Kens", and a stranded possessive "s" is re-joined so Aldi's
# "Clancy S Original Potato Chips" folds onto "Clancy's Original Potato Chips".
$KW_UNIT_TOKENS = @('oz','ozs','fl','lb','lbs','pound','pounds','ct','count','pk','pkg','pack','packs','pcs','pc','piece','pieces','g','gr','gram','grams','kg','ml','l','liter','liters','qt','quart','gal','gallon','each','ea','in','inch','sq','ft','roll','rolls','bag','bags','box','boxes','can','cans','bottle','bottles','jar','jars','pouch','pouches','tub','tubs','tray','trays','carton','cartons','case','cases','container','containers','sheet','sheets','load','loads','serving','servings','bar','bars','slice','slices','cup','cups','tbsp','tsp','pt','pint','pints')
function KwNorm([string]$Raw) {
  $s = ($Raw + '')
  if ($s.Length -eq 0) { return '' }
  $s = $s.Replace([string][char]0x2019, "'").Replace([string][char]0x2018, "'").Replace([string][char]0x00B4, "'").Replace([string][char]0x0060, "'")
  $s = $s.ToLower()
  $s = $s -replace "'", ''
  $s = $s -replace '[^a-z0-9]+', ' '
  $s = $s.Trim()
  if ($s.Length -eq 0) { return '' }
  $s = $s -replace '(?<=[a-z0-9]) s(?= |$)', 's'
  return (($s -replace '\s+', ' ').Trim())
}
function KwCore([string]$Norm) {
  $toks = @(($Norm + '') -split ' ' | Where-Object { $_ })
  $i = $toks.Count - 1
  while ($i -ge 0) {
    $t = $toks[$i]
    if ($t -match '^[0-9]+$' -or $KW_UNIT_TOKENS -contains $t) { $i-- } else { break }
  }
  if ($i -lt 0) { return '' }
  return (($toks[0..$i]) -join ' ')
}

$lines = New-Object System.Collections.Generic.List[string]
function Say([string]$m) { [void]$lines.Add($m); Write-Output $m }
$notes = New-Object System.Collections.Generic.List[string]

# ---------------------------------------------------------------- the list
if (-not (Test-Path $ListFile)) {
  Say ("KNOWN-WRONG AUDIT BLIND: the blocklist file is MISSING (" + $ListFile + "). Nothing was checked, so nothing was proven - the adjudicated-wrong products are unguarded until the file is restored. Unknown is not a pass.")
  exit 3
}
# ((Get-Content -Raw) + '') because [string]$null is $null and .Trim() throws on a zero-byte file; and
# '' | ConvertFrom-Json returns $null WITHOUT throwing, so the null is checked explicitly.
$listRaw = ((Get-Content $ListFile -Raw -Encoding UTF8) + '').Trim()
if ($listRaw.Length -eq 0) {
  Say ("KNOWN-WRONG AUDIT BLIND: the blocklist file is EMPTY (" + $ListFile + "). A zero-byte list parses to nothing without throwing; it is not an empty blocklist, it is an unreadable one.")
  exit 3
}
$doc = $null
try { $doc = $listRaw | ConvertFrom-Json } catch {
  Say ("KNOWN-WRONG AUDIT FAILED: the blocklist file will not parse as JSON (" + $ListFile + "): " + $_.Exception.Message)
  exit 2
}
if ($null -eq $doc) {
  Say ("KNOWN-WRONG AUDIT FAILED: the blocklist file parsed to null (" + $ListFile + ").")
  exit 2
}
$entries = @()
if ($doc.PSObject.Properties.Name -contains 'entries') { $entries = @($doc.entries) }
$entries = @($entries | Where-Object { $_ })

# ---------------------------------------------------------------- schema (fail closed: a malformed
# blocklist is a gate that does not do what it claims)
$RETIRE_VOCAB = @('ruling-reversed','commodity-retired','store-retired')
$schemaBad = New-Object System.Collections.Generic.List[string]
$i = 0
foreach ($e in $entries) {
  $i++
  $props = @($e.PSObject.Properties.Name)
  foreach ($req in @('key','commodity','store','names','retire_when','evidence','ruled_on','ruled_by')) {
    if ($props -notcontains $req) { [void]$schemaBad.Add("entry #$i is missing required field '$req'") }
  }
  if ($props -contains 'names') {
    $nm = @($e.names | Where-Object { ($_ + '').Trim() })
    if ($nm.Count -eq 0) { [void]$schemaBad.Add("entry #$i ('" + [string]$e.key + "') lists no product names, so it can never match anything") }
  }
  if ($props -contains 'retire_when') {
    if ($RETIRE_VOCAB -notcontains [string]$e.retire_when) {
      [void]$schemaBad.Add("entry #$i ('" + [string]$e.key + "') declares retire_when='" + [string]$e.retire_when + "', which is not in the closed vocabulary (" + ($RETIRE_VOCAB -join ', ') + "). An unevaluable retire trigger is the allowlist bug: nobody can ever prove the entry stale.")
    }
  }
}
$seenKeys = @{}
foreach ($e in $entries) {
  $k = [string]$e.key
  if ($k -and $seenKeys.ContainsKey($k)) { [void]$schemaBad.Add("duplicate key '" + $k + "' - one of the two rulings is invisible") }
  if ($k) { $seenKeys[$k] = $true }
}
if ($schemaBad.Count -gt 0) {
  Say ("KNOWN-WRONG AUDIT FAILED: the blocklist itself is malformed (" + $schemaBad.Count + " problem(s)); the gate cannot be trusted until it is fixed.")
  foreach ($m in $schemaBad) { Say ('  SCHEMA  ' + $m) }
  exit 2
}

# ---------------------------------------------------------------- the boards
# A board this audit cannot parse is NOT this audit's finding. guards.ps1 parses the same file a few lines
# after it calls us and will fail on it accurately; if we let the throw escape, the delegate loop records
# "HARD FAIL: no product a reasoner already ruled wrong is priced on the board" and blames the blocklist for
# a corrupt board. Exit 3 with the real reason instead.
$boards = @()
$boardErr = ''
try {
  $cmpF = @(Get-ChildItem (Join-Path $outDir 'comparison-*.json') -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1)
  foreach ($f in $cmpF) { $boards += ,@($f.Name, @((Get-Content $f.FullName -Raw | ConvertFrom-Json).comparison)) }
  $rbF = Join-Path $outDir 'recipe-board.json'
  if (Test-Path $rbF) { $boards += ,@('recipe-board.json', @((Get-Content $rbF -Raw | ConvertFrom-Json).comparison)) }
} catch {
  $boardErr = $_.Exception.Message
  $boards = @()
}
if ($boardErr) {
  Say ("KNOWN-WRONG AUDIT BLIND: a board file under " + $outDir + " would not parse, so the blocklist examined nothing: " + $boardErr + " - fix the board; this audit is not the finding.")
  exit 3
}

# cellsByKey: commodity|store -> list of cells; rowIds: commodity -> $true; namedRows: commodity -> $true
$cellsByKey = @{}; $rowIds = @{}; $namedRows = @{}
$cellsNamed = 0; $cellsUnnamed = 0
foreach ($b in $boards) {
  foreach ($r in $b[1]) {
    $id = [string]$r.id
    if (-not $id) { continue }
    $rowIds[$id] = $true
    foreach ($s in $r.stores) {
      $pu = 0.0
      if (($s.PSObject.Properties.Name -contains 'per_unit') -and $null -ne $s.per_unit) {
        try { $pu = [double]$s.per_unit } catch { $pu = 0.0 }
      }
      if ($pu -le 0) { continue }
      $item = [string]$s.item
      if (-not $item) { $cellsUnnamed++; continue }
      $cellsNamed++
      $namedRows[$id] = $true
      $k = $id + '|' + [string]$s.store
      if (-not $cellsByKey.ContainsKey($k)) { $cellsByKey[$k] = New-Object System.Collections.Generic.List[object] }
      [void]$cellsByKey[$k].Add([pscustomobject]@{
        board = $b[0]; id = $id; store = [string]$s.store; item = $item
        nfull = (KwNorm $item); ncore = (KwCore (KwNorm $item))
        per_unit = $pu; ad = [string]$s.ad; size = [string]$s.size
        crown = ([string]$r.cheapest_store -eq [string]$s.store)
      })
    }
  }
}

# ---------------------------------------------------------------- retire-trigger inputs
$liveCommodities = @{}
$cmF = Join-Path $Root 'commodities.json'
# PS 5.1 TRAP, hit while building this file: commodities.json is a BARE TOP-LEVEL ARRAY, and
# `@(Get-Content -Raw | ConvertFrom-Json)` does NOT unroll it - it yields ONE element holding the whole
# Object[]. Member enumeration then makes `$c.id` the array of all 503 ids, `[string]$c.id` a single
# space-joined mega-string, and the registry ends up with exactly one bogus key. Measured effect before
# the fix: commodity-retired fired on all 19 entries at once. Assign FIRST, then iterate the variable.
if (Test-Path $cmF) {
  try {
    $cmAll = Get-Content $cmF -Raw | ConvertFrom-Json
    foreach ($c in $cmAll) { if ($c -and $c.id) { $liveCommodities[[string]$c.id] = $true } }
  } catch {
    $liveCommodities = @{}
    [void]$notes.Add('commodities.json would not parse (' + $_.Exception.Message + '), so the commodity-retired trigger was NOT evaluated this run. That is a real problem, but it is not a blocklist finding and must not hold the board.')
  }
}
$liveStores = @{}
$stF = Join-Path $Root 'stores.json'
if (Test-Path $stF) {
  try {
    foreach ($s in @((Get-Content $stF -Raw | ConvertFrom-Json).stores)) { if ($s -and $s.name) { $liveStores[[string]$s.name] = [string]$s.regular_prefix } }
  } catch {
    $liveStores = @{}
    [void]$notes.Add('stores.json would not parse (' + $_.Exception.Message + '), so the store-retired trigger and the product-id key were NOT available this run. guards.ps1 reads stores.json nowhere else, so failing the board on it here would be a brand-new way for one small registry file to stop the publish.')
  }
}
# A registry that loaded almost nothing cannot be used to declare anything retired - that is the same
# "ok from zero rows" failure the retire triggers exist to prevent, pointed at the triggers themselves.
$commodityRegistryUsable = ($liveCommodities.Count -ge 2)
$storeRegistryUsable     = ($liveStores.Count -ge 2)

# id -> current feed name, per store, resolved lazily from the newest regular file for that store
$feedCache = @{}
function KwFeedName([string]$store, [string]$prodId) {
  if (-not $prodId) { return '' }
  if (-not $liveStores.ContainsKey($store)) { return '' }
  $prefix = $liveStores[$store]
  if (-not $prefix) { return '' }
  if (-not $feedCache.ContainsKey($store)) {
    $map = @{}
    $rf = @(Get-ChildItem (Join-Path $outDir ('regular\' + $prefix + '-regular-*.json')) -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1)
    foreach ($f in $rf) {
      try {
        foreach ($d in @((Get-Content $f.FullName -Raw | ConvertFrom-Json).deals)) {
          # ConvertFrom-Json rows are HETEROGENEOUS, so ask every row for its own id field
          $p = @($d.PSObject.Properties.Name)
          $v = ''
          if ($p -contains 'item_id') { $v = [string]$d.item_id }
          if (-not $v -and ($p -contains 'product_id')) { $v = [string]$d.product_id }
          if ($v) { $map[$v] = [string]$d.item }
        }
      } catch {
        [void]$script:notes.Add('the newest ' + $store + ' feed (' + $f.Name + ') would not parse, so the product-id key could not re-derive that store''s current spellings this run; the frozen adjudicated names are still enforced.')
      }
    }
    $feedCache[$store] = $map
  }
  $m = $feedCache[$store]
  if ($m.ContainsKey($prodId)) { return $m[$prodId] }
  return ''
}

# ---------------------------------------------------------------- evaluate
$blocked = New-Object System.Collections.Generic.List[object]
$review  = New-Object System.Collections.Generic.List[object]
$retire  = New-Object System.Collections.Generic.List[string]
$unevaluable = New-Object System.Collections.Generic.List[string]
$unfirable   = New-Object System.Collections.Generic.List[string]
# KEY-COLLISION is a DIFFERENT finding from UNFIRABLE and needs the opposite action - see the block
# below. Kept as its own list so a reader can never mistake one for the other.
$collision   = New-Object System.Collections.Generic.List[string]
$reversed = 0; $evaluable = 0; $idResolved = 0

foreach ($e in $entries) {
  $key   = [string]$e.key
  $cid   = [string]$e.commodity
  $store = [string]$e.store
  $props = @($e.PSObject.Properties.Name)

  # --- retire triggers, EVALUATED (not just declared)
  $revOn = ''; $revBy = ''
  if ($props -contains 'reversed_on') { $revOn = ([string]$e.reversed_on).Trim() }
  if ($props -contains 'reversed_by') { $revBy = ([string]$e.reversed_by).Trim() }
  $fired = @()
  if ($revOn -and $revBy) { $fired += 'ruling-reversed' }
  if ($commodityRegistryUsable -and -not $liveCommodities.ContainsKey($cid)) { $fired += 'commodity-retired' }
  if ($storeRegistryUsable -and -not $liveStores.ContainsKey($store)) { $fired += 'store-retired' }
  if ($fired.Count -gt 0) {
    [void]$retire.Add(('RETIRE-READY  ' + $key + '  trigger(s) fired: ' + ($fired -join ', ')))
  }
  if ($fired -contains 'ruling-reversed') {
    # a reversed ruling is history, not a gate. It stays in the file so the reversal is auditable.
    $reversed++
    continue
  }

  # --- can this entry be evaluated at all?
  if (-not $namedRows.ContainsKey($cid)) {
    [void]$unevaluable.Add(($key + " - commodity '" + $cid + "' has no NAMED priced cell on any loaded board, so this ruling was not tested this run"))
    continue
  }
  $evaluable++

  # --- the names this entry blocks: the frozen adjudicated spellings, plus today's spelling of the same
  #     product re-derived from its own store feed by id (the pipeline corrupts names; ids do not move)
  $wanted = @{}
  foreach ($n in @($e.names)) { $v = KwNorm ([string]$n); if ($v) { $wanted[$v] = [string]$n } }
  $prodId = ''
  if ($props -contains 'product_id') { $prodId = ([string]$e.product_id).Trim() }
  if ($prodId) {
    $fn = KwFeedName $store $prodId
    if ($fn) {
      $idResolved++
      $v = KwNorm $fn
      if ($v -and -not $wanted.ContainsKey($v)) { $wanted[$v] = $fn }
    }
  }
  $wantedCores = @{}
  foreach ($v in $wanted.Keys) { $c = KwCore $v; if ($c -and (@($c -split ' ').Count -ge 3)) { $wantedCores[$c] = $true } }

  $ck = $cid + '|' + $store
  if (-not $cellsByKey.ContainsKey($ck)) { continue }
  $matchedSomething = $false
  foreach ($cell in $cellsByKey[$ck]) {
    if ($wanted.ContainsKey($cell.nfull)) {
      $matchedSomething = $true
      [void]$blocked.Add([pscustomobject]@{ key=$key; cell=$cell; why='exact normalized name' })
    } elseif ($cell.ncore -and $wantedCores.ContainsKey($cell.ncore)) {
      $matchedSomething = $true
      [void]$review.Add([pscustomobject]@{ key=$key; cell=$cell; why='size-variant of a blocked product (core name matches)' })
    }
  }

  # --- UNFIRABLE: the KEY says this entry is about a product that IS on the board, but the stored NAME
  # cannot match it, so the ruling can never fire and the wrong product stays live and unguarded.
  #
  # WHY THIS IS NARROW, AND HAS TO BE (2026-08-29). "This entry matches nothing" is the NORMAL, HEALTHY
  # steady state of a ruling that worked: the commodity rule got fixed, the wrong product left the board,
  # and the entry sits dormant guarding against its return. Flagging that would page on every success.
  # What is NOT healthy is an entry whose key COLLIDES with a live board product while its name does not
  # match it - because the key is the name slugged and truncated to 48 chars (add-known-wrong.ps1:142),
  # two names that agree for 48 characters and diverge after produce ONE key and TWO different match
  # targets. Founding case: bay-leaves|Walmart|soeos-bay-leaves-16-oz-454g-bay-leaves-bulk-bay stored a
  # 70-char name ending "Bay Leaves Bulk, Bay Leaves Whole Dried" while the board carries the full
  # 168-char SEO title ending "...Natural Dried Bay Leaf, Dried Bay Leaves, Whole Bay Leaves". The key
  # collided, the name did not, add-known-wrong refused the re-issue as a duplicate, and the ruling was
  # permanently inert - Soeos held the Walmart crown at $1.4369/oz, SEVENTEEN TIMES cheap, through a full
  # rebuild that was supposed to have dropped it. Nothing reported it: the commodity had named cells, so
  # the UNEVALUABLE check above passed it straight through.
  if (-not $matchedSomething) {
    $keySlug = ''
    $kp = @($key -split '\|')
    if ($kp.Count -ge 3) { $keySlug = [string]$kp[2] }
    if ($keySlug) {
      foreach ($cell in $cellsByKey[$ck]) {
        $cellSlug = ([string]$cell.nfull) -replace '[^a-z0-9]+', '-'
        $cellSlug = $cellSlug.Trim('-')
        if ($cellSlug.Length -gt 48) { $cellSlug = $cellSlug.Substring(0, 48).Trim('-') }
        if ($cellSlug -eq $keySlug) {
          # WHICH OF TWO SHAPES IS THIS? They look identical from the key and they need OPPOSITE actions,
          # and until 2026-09-01 this check reported both as the first one (measured below).
          #
          #   (i) ONE PRODUCT, TWO SPELLINGS. Walmart rewrote the title; the stored name is the old
          #       spelling. Founding case, Soeos bay leaves: the stored 70-char name and the board's
          #       168-char SEO title still agree for 55 characters, well past the 47-char key. The
          #       ruling really is inert and really does leave a wrong product unguarded. Re-issue it.
          #
          #   (ii) TWO DIFFERENT PRODUCTS THE TRUNCATION MERGED. Found 2026-09-01 on
          #       ready-to-serve-long-grain-wild-rice-pouch: the ruling names "...Long Grain WHITE Rice
          #       Pouch, 8.8 oz" (plain white rice, correctly ruled wrong for a wild-rice commodity) and
          #       the board carries "...Long Grain & WILD Rice Pouch, 8.8 oz", which is the RIGHT product
          #       and matches the commodity's own include. The two slugs agree for exactly 48 characters
          #       and diverge at 49, so the 48-char cut is the ONLY thing that merged them. Following the
          #       advice above here - re-issue, reading the name off the board - would rule the correct
          #       product wrong and delete a good cell. The ruling is not inert at all: it matches on the
          #       stored NAME, which is intact, so it will fire the day its own product returns.
          #
          # THE DISCRIMINATOR IS MEASURED, NOT GUESSED: how far do the two full slugs agree, compared to
          # where the key was cut? Agreeing PAST the cut means the names were already the same string
          # family and the truncation is incidental (Soeos: 55 > 47). Diverging exactly AT the cut means
          # the truncation is what merged them (rice: 48 = 48). Same normalizer on both sides.
          $cellFull = ((([string]$cell.nfull) -replace '[^a-z0-9]+', '-')).Trim('-')
          $bestCommon = -1; $bestName = ''
          foreach ($n in @($e.names)) {
            $sf = (((KwNorm ([string]$n)) -replace '[^a-z0-9]+', '-')).Trim('-')
            $i = 0
            while ($i -lt [math]::Min($sf.Length, $cellFull.Length) -and $sf[$i] -eq $cellFull[$i]) { $i++ }
            if ($i -gt $bestCommon) { $bestCommon = $i; $bestName = [string]$n }
          }
          if ($bestCommon -gt $keySlug.Length) {
            [void]$unfirable.Add(($key + " - its key matches the board product '" + $cell.item +
              "' but none of its stored name(s) do, so this ruling can NEVER fire and that product is priced UNGUARDED at " +
              $cell.store + ". The two names still agree for " + $bestCommon + " characters, past the " + $keySlug.Length +
              "-char key, so this is ONE product under two spellings. Re-issue the ruling with -Key set to something " +
              "distinct and let add-known-wrong read the name off the board; do NOT reverse the original."))
          } else {
            [void]$collision.Add(($key + " - its key collides with the board product '" + $cell.item + "' at " +
              $cell.store + ", but the two names diverge at character " + $bestCommon + ", which is exactly where the 48-char " +
              "key was cut. The truncation is what merged them, so these are probably DIFFERENT products and the board one " +
              "may well be CORRECT. Ruled name: '" + $bestName + "'. Read both names before doing anything: do NOT re-issue " +
              "this ruling against the board name (that would block a correct cell), and do NOT reverse it. The ruling still " +
              "matches on its own stored name, so it fires the day its own product returns."))
          }
          break
        }
      }
    }
  }
}

# ---------------------------------------------------------------- report
$boardNames = @($boards | ForEach-Object { $_[0] })
Say ("known-wrong: " + $entries.Count + " adjudicated entries (" + $reversed + " reversed) / " + $evaluable + " evaluable / " + $idResolved + " re-derived from a store feed by product id")
Say ("             boards read: " + (($boardNames -join ', ')) + "   named priced cells examined: " + $cellsNamed + "   priced cells with no product name (not name-checkable): " + $cellsUnnamed)
foreach ($m in $notes) { Say ('  NOTE          ' + $m) }
if (-not $commodityRegistryUsable) { Say ('  NOTE          commodities.json loaded ' + $liveCommodities.Count + ' id(s), so the commodity-retired trigger was NOT evaluated this run.') }
if (-not $storeRegistryUsable)     { Say ('  NOTE          stores.json loaded ' + $liveStores.Count + ' store(s), so the store-retired trigger was NOT evaluated this run.') }
foreach ($m in $retire) { Say ('  ' + $m) }
foreach ($m in $unfirable)   { Say ('  UNFIRABLE     ' + $m) }
foreach ($m in $collision)   { Say ('  KEY-COLLISION ' + $m) }
foreach ($m in $unevaluable) { Say ('  UNEVALUABLE   ' + $m) }
foreach ($r in $review) {
  Say ("  REVIEW        [{0}] {1} '{2}' {3} - {4}" -f $r.cell.store, $r.cell.id, $r.cell.item, $r.cell.ad, $r.why)
  Say ("                matches blocklist entry " + $r.key + " (REVIEW ONLY - the core-name key merges genuinely different pack sizes, so it never sets the exit code)")
}
foreach ($b in $blocked) {
  Say ("  BLOCKED       [{0}] {1} '{2}' {3} per_unit={4} crown={5} board={6}" -f $b.cell.store, $b.cell.id, $b.cell.item, $b.cell.ad, $b.cell.per_unit, $b.cell.crown, $b.cell.board)
  Say ("                already ruled wrong: blocklist entry " + $b.key + " (matched on " + $b.why + ")")
}

if ($Report) {
  $rep = [ordered]@{
    generated = (Get-Date -Format 'yyyy-MM-dd HH:mm')
    entries = $entries.Count; reversed = $reversed; evaluable = $evaluable; id_resolved = $idResolved
    boards = $boardNames; cells_named = $cellsNamed; cells_unnamed = $cellsUnnamed
    blocked = @($blocked | ForEach-Object { [ordered]@{ key=$_.key; id=$_.cell.id; store=$_.cell.store; item=$_.cell.item; ad=$_.cell.ad; per_unit=$_.cell.per_unit; crown=$_.cell.crown; board=$_.cell.board } })
    review = @($review | ForEach-Object { [ordered]@{ key=$_.key; id=$_.cell.id; store=$_.cell.store; item=$_.cell.item; ad=$_.cell.ad } })
    retire_ready = @($retire); unevaluable = @($unevaluable); unfirable = @($unfirable); key_collision = @($collision); notes = @($notes)
  }
  if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Force $outDir | Out-Null }
  ($rep | ConvertTo-Json -Depth 6) | Set-Content (Join-Path $outDir 'known-wrong-report.json') -Encoding UTF8
}

if ($boards.Count -eq 0 -or $cellsNamed -eq 0) {
  Say 'KNOWN-WRONG AUDIT BLIND: examined ZERO named priced cells - out\comparison-*.json is missing, or every priced cell arrived without a product name. The blocklist proved NOTHING this run; "no listed product is on the board" is unknown, not clean.'
  exit 3
}
if ($entries.Count -eq 0) {
  Say 'KNOWN-WRONG AUDIT BLIND: the blocklist holds ZERO entries, so it can never fire. An empty regression blocklist after 99 adjudicated wrong numbers means findings are still living in prose.'
  exit 3
}
if ($evaluable -eq 0) {
  Say 'KNOWN-WRONG AUDIT BLIND: not ONE entry could be evaluated - every listed commodity is absent from the loaded boards (a renamed/typo commodity id makes an entry permanently unfirable, which is exactly the allowlist bug this file exists to avoid).'
  exit 3
}
if ($blocked.Count -gt 0) {
  Say ("KNOWN-WRONG AUDIT FAILED: " + $blocked.Count + " adjudicated-wrong product(s) are priced on the board. Board NOT safe to publish. Each one was already ruled wrong with evidence in known-wrong.json - fix the commodity rule (or reverse the ruling with add-known-wrong.ps1 -Reverse and say why).")
  exit 2
}

# ---------------------------------------------------------------------------
# The SECOND place a product identity lives: product-urls.json.
#
# A ruling used to be enforced against priced board cells only, so a product
# adjudicated wrong could still be the curated "See item" link the page shows.
# On 2026-08-20 TEN of them were: strawberries linked to Great Value Strawberry
# SYRUP, pineapple to Pineapple Teriyaki BRATS, lime-juice to a MAYONNAISE,
# sea-salt to POPCORN. The board price was right and the link sent the shopper
# to a different product entirely - a defect the board-cell check cannot see,
# because the curated file is a private second copy of the same identity.
# Same lesson as the everyday-price window: one ruling, every copy.
# ---------------------------------------------------------------------------
$purlPath = Join-Path $root 'product-urls.json'
if (Test-Path $purlPath) {
  $badLinks = New-Object System.Collections.Generic.List[object]
  # INDEXED, NOT RE-NORMALISED PER COMPARISON (2026-08-22 - performance, not behaviour).
  # This loop used to call KwNorm on EVERY blocklist entry's commodity and EVERY one of its names once per
  # curated link: ~3.5k links x ~100 entries x their names, each a chain of six regex replaces. Measured on
  # the live tree it was 14 of audit-known-wrong's 15.7 seconds, and audit-known-wrong was on its own 37% of
  # the whole publish gate.
  # KwNorm is a PURE function of its argument, so normalising each entry ONCE up front computes the same
  # strings the inner loop computed over and over. The index below is deliberately a LIST OF ENTRIES per
  # normalised commodity, NOT one merged name set: the original adds a finding PER MATCHING ENTRY (the
  # `break` exits the NAMES loop, not the entries loop), so two entries that share a normalised commodity
  # and both name the same link produced TWO findings. A merged set would silently report one. Entry order
  # is preserved for the same reason - the report is ordered, and an order change is a diff nobody asked for.
  $kwByCid = @{}
  foreach ($e in $entries) {
    # NOTE: an entry whose commodity normalises to '' is indexed under '' rather than dropped - the original
    # compared KwNorm(commodity) to KwNorm(cid) with no empty-string special case, so a degenerate id on both
    # sides matched. Keeping it means this index is equivalent on the edge cases too, not just the real ones.
    $ck = KwNorm ([string]$e.commodity)
    $eNames = @($e.names); if (-not $eNames -or $eNames.Count -eq 0) { continue }
    $nn = New-Object System.Collections.Generic.List[string]
    foreach ($en in $eNames) { [void]$nn.Add((KwNorm ([string]$en))) }
    if (-not $kwByCid.ContainsKey($ck)) { $kwByCid[$ck] = New-Object System.Collections.Generic.List[object] }
    [void]$kwByCid[$ck].Add([pscustomobject]@{ nnames = $nn })
  }
  try {
    $purlDoc = Get-Content $purlPath -Raw | ConvertFrom-Json
    $purlItems = if ($purlDoc.PSObject.Properties.Name -contains 'items') { $purlDoc.items } else { $purlDoc }
    foreach ($cProp in $purlItems.PSObject.Properties) {
      $cid = $cProp.Name
      if ($cProp.Value -isnot [psobject]) { continue }
      $cidNorm = KwNorm $cid
      if (-not $kwByCid.ContainsKey($cidNorm)) { continue }
      $cidEntries = $kwByCid[$cidNorm]
      foreach ($sProp in $cProp.Value.PSObject.Properties) {
        $entryVal = $sProp.Value
        if ($entryVal -isnot [psobject] -or -not $entryVal.PSObject.Properties.Name.Contains('name')) { continue }
        $nk = KwNorm ([string]$entryVal.name)
        if (-not $nk) { continue }
        foreach ($e in $cidEntries) {
          foreach ($en in $e.nnames) {
            if ($en -eq $nk) {
              $badLinks.Add([pscustomobject]@{ commodity = $cid; store = $sProp.Name; name = [string]$entryVal.name })
              break
            }
          }
        }
      }
    }
  } catch {
    Say ("KNOWN-WRONG AUDIT FAILED: product-urls.json will not parse (" + $_.Exception.Message + "); the curated-link half of this gate cannot be trusted.")
    exit 2
  }
  if ($badLinks.Count -gt 0) {
    foreach ($b in $badLinks) {
      Say ("  BLOCKED-LINK  [" + $b.store + "] " + $b.commodity + " curated link points at '" + $b.name + "', which is adjudicated wrong")
    }
    Say ("KNOWN-WRONG AUDIT FAILED: " + $badLinks.Count + " curated product-urls.json link(s) point at an adjudicated-wrong product. The price may be right while the 'See item' link sends the shopper to a different product. Remove the entry (or reverse the ruling and say why).")
    exit 2
  }
}
Say ("KNOWN-WRONG AUDIT OK: 0 of " + $entries.Count + " adjudicated-wrong products are priced on the board (" + $evaluable + " entries evaluable against " + $cellsNamed + " named priced cells; " + $review.Count + " near-match(es) for review).")
exit 0

