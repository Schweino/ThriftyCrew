<#
  rollback-ttl-lib.ps1 - the durable "when did we FIRST see this rollback?" ledger.

  BRAD'S RULE (2026-08-21): "for walmart and sams, a rollback price we just stick with a 30 day TTL
  from when we first detect".

  THE WHOLE DIFFICULTY IS IN THE WORD *FIRST*. Walmart and Sam's publish no end date for a rollback -
  measured 2026-08-21: Walmart's ROLLBACK badge carries __typename/key/text/type/id/styleId and
  nothing temporal, promoData is Affirm financing only, promoDiscount is null; Sam's payload contains
  zero date-shaped values at all. So the window has to come from us, and the only honest anchor is the
  first day we observed it.

  IF THE ANCHOR MOVES, THE TTL IS INFINITE. A rollback is re-observed on every capture that covers its
  term. Stamping "today + 30" each time an observation lands would push the expiry forward forever and
  the price would never revert - a 30-day rule that silently means "never", which is strictly worse
  than no rule because it reads as governed. So first_seen is written ONCE per (store, item) and is
  NEVER advanced; only last_seen moves. That is the same discipline as `dates written, not measured`
  and as the FF cursor-commit rule: the durable fact is recorded when it happens and is not re-derived
  from the clock afterwards.

  KEYED BY THE STORE'S OWN ITEM ID, not the product name. A name changes when the merchant re-lists or
  re-titles an item and a name-keyed ledger would silently mint a new first_seen and restart the
  clock - the re-listing escape that `a ruling a store can escape by re-listing is not a ruling`
  describes. Walmart gives usItemId, Sam's gives productId; both are already captured.

  THE PRICE IS PART OF THE IDENTITY OF A ROLLBACK. If the rolled-back price CHANGES, that is a new
  rollback, not a continuation of the old one, and it earns a fresh 30 days. A store that cuts $5.96
  to $4.87 and later to $3.99 has run two promotions; carrying the first anchor forward would expire
  the second one early. Recorded as price_changed in the ledger so the reason is visible.

  DETECTION IS THE CAPTURE, NOT THE LEDGER (Brad, 2026-08-22). "30 days from when we first detect" means
  the day the store's feed first SHOWED the cut price - the row's as_of - not the day this ledger first
  processed the row. Pass -AsOf; the anchor is min(as_of, today). first_seen still never advances on a
  re-observation; it may move EARLIER when a capture proves the price was already there.

  CONCURRENT BUILDERS (2026-09-11). build-walmart-deals and build-sams-deals run side by side in capture-run's
  builder fan-out, and compare-deals and import-walmart-batch save this ledger too. Each LOADS it once, early,
  holds it in $script:RbLedger for the whole build and saves near the end - so the save wrote the whole file from a
  copy read long before, and whichever builder saved second erased every entry the first had just recorded. An
  erased first_seen is re-minted by the next build from ITS capture date, which is later: the TTL runs long, the
  exact failure this file exists to prevent. A lock around the save alone does not fix that, because the stale copy
  was read before the lock was taken. So the save takes lib\ledger-lock.ps1's lock, RE-READS the file inside it,
  and folds in only the entries this process changed ($script:RbTouched) by Merge-RollbackEntry's rules. The load
  takes the same lock, so it reads a whole file and never the instant between a sibling's delete and its move.

  WHICH DURABILITY CLASS THIS LEDGER IS IN: **NOT RE-DERIVED**, so its save FLUSHES TO THE DEVICE (Brad's
  ruling, 2026-09-12, backlog I117 - lib\atomic-write.ps1's header carries it verbatim, and the two classes).
  Everything above is the argument for it: first_seen is the day the store's feed first showed the cut price,
  and nothing can recompute that from a later capture. A lost write is not a stale number that the next build
  corrects; it is an anchor re-minted from a LATER date, which is the TTL-runs-long failure this file exists
  to prevent. The save therefore passes -Flush. The window a flush closes is narrow - a hard power event
  between the move and the page cache reaching the disk - and the cost measured on this box is under a
  millisecond on a save that happens once per build.
  Self-test: powershell -File grocery\rollback-ttl-lib.ps1 -SelfTest

  Usage:
      . rollback-ttl-lib.ps1
      $w = Get-RollbackWindow -Store 'Walmart' -ItemId '10450114' -Price 4.87 -Today '2026-08-21' -AsOf '2026-08-11'
      # -> @{ ad_from = '2026-08-11'; ad_to = '2026-09-10'; first_seen = '2026-08-11'; is_new = $true }
      Save-RollbackLedger        # once, after a build, to persist what the run observed
#>

# No param() block, so -SelfTest is read from $args (a dot-sourced param() block would reset the caller's own).
$__rbSelfTest = ($MyInvocation.InvocationName -ne '.') -and ($args -contains '-SelfTest')
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\ledger-lock.ps1')   # Enter-TcLedgerLock: the Walmart and Sam's builders save this ledger side by side
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\atomic-write.ps1')   # Write-TcAtomicFile: those builders' lock-free reads can hold the file at the replace

# The TTL itself. Brad's number, and it is a POLICY value rather than a measurement: neither store
# publishes a window, so this is the length we are choosing to stand behind, not one they gave us.
# Kept here beside the ledger it governs so the two can never disagree.
$script:RollbackTtlDays = 30

# Which stores this applies to. A store that PUBLISHES a window must never be given a TTL instead -
# Baker's states expirationDate per item and Family Fare states finish_date per offer, and inventing
# a 30-day guess over either would be replacing a fact with a worse one.
# FAREWAY JOINED THIS LIST 2026-08-21, on Brad's rule: "if product page shows a sale price, but it
# doesn't match a weekly or monthly ad, give it a 30 day TTL." It is the store with by far the most
# undated sales - 178 cells after ad-matching had already dated everything it could - and its own
# storefront publishes no end date for them (itemPromotions empty, secondaryPromotion null,
# promotionGroupId null, and on_sale_ind reports retailer:false, i.e. not a retailer promotion).
# ORDER MATTERS AND IS ENFORCED BY THE CALLER: a TTL is the LAST resort. A cell is dated by the
# store's own feed if it can be, then by the ad it was traced to, and only then by this. Fareway also
# states "Sale ends in N days" in saleDisclaimerString on SOME items; where that is captured it is a
# real date and must beat this guess.
$script:RollbackTtlStores = @('Walmart', "Sam's Club", 'Fareway')

$script:RbLedger = $null
$script:RbLedgerPath = $null
$script:RbDirty = $false
# The keys this process changed since its load or its last save. They are the ONLY entries a save takes from
# memory; every other entry is whatever is on disk at the moment of the save.
$script:RbTouched = $null

function Get-RollbackLedgerPath([string]$Root) {
  if (-not $Root) { $Root = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\grocery' } }
  return (Join-Path $Root 'rollback-first-seen.json')
}

function Read-RollbackLedgerFile([string]$Path) {
  <# The ledger on disk as key -> entry. A missing file is an empty ledger. A file that exists and cannot be read
     THROWS, because reading it as empty is how a save would replace every entry it holds. #>
  $h = @{}
  if (-not (Test-Path -LiteralPath $Path)) { return $h }
  $doc = ConvertFrom-Json ([IO.File]::ReadAllText($Path))
  if ($null -eq $doc) { throw ('{0} holds no JSON document' -f $Path) }
  foreach ($e in @($doc.entries)) {
    if ($null -eq $e) { continue }
    $h[[string]$e.key] = [ordered]@{
      store = [string]$e.store; item_id = [string]$e.item_id
      price = [double]$e.price; first_seen = [string]$e.first_seen
      last_seen = [string]$e.last_seen; price_changed = [int]$e.price_changed
    }
  }
  return $h
}

function Import-RollbackLedger([string]$Root = '') {
  if ($null -ne $script:RbLedger) { return }
  $script:RbLedgerPath = Get-RollbackLedgerPath $Root
  $script:RbLedger = @{}
  $script:RbTouched = New-Object 'System.Collections.Generic.HashSet[string]'
  # UNDER THE LOCK, so this reads a whole file. An unreadable ledger still loads as EMPTY, as it always has: this
  # build then anchors each rollback to its own capture, and Save-RollbackLedger refuses to overwrite the file.
  try {
    $lk = Enter-TcLedgerLock -Path $script:RbLedgerPath
    try { $script:RbLedger = Read-RollbackLedgerFile $script:RbLedgerPath } finally { Exit-TcLedgerLock $lk }
  } catch {
    Write-Warning ('rollback ledger not loaded (' + $_.Exception.Message + ') - this build anchors every rollback to its own capture date')
  }
}

function Set-RollbackTouched([string]$Key) {
  $script:RbDirty = $true
  if ($null -ne $script:RbTouched) { [void]$script:RbTouched.Add($Key) }
}

function Test-RollbackTtlStore([string]$Store) { return ($script:RollbackTtlStores -contains $Store) }
function Get-RollbackTtlDays { return $script:RollbackTtlDays }

function Get-RollbackWindow {
  <#
    .SYNOPSIS The window for one observed rollback, anchored to the day we FIRST saw it.
    .DESCRIPTION Returns $null for a store that publishes its own dates - the caller must use those.
                 Pure apart from the in-memory ledger; call Save-RollbackLedger to persist.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Store,
    # NOT Mandatory, deliberately. A row with no item id must come back as $null - "we cannot anchor
    # this honestly" - not as a parameter-binding crash. Mandatory rejects '' at the binder, before
    # the guard below can give that answer, which turns a legitimate no-op into a failed build.
    [string]$ItemId = '',
    [Parameter(Mandatory)][double]$Price,
    [string]$Today = '',
    [string]$Root = '',
    # THE DAY THE CAPTURE SHOWED THIS PRICE (the row's as_of), which is NOT the day the ledger met it.
    # BRAD'S RULING (2026-08-22): the TTL is 30 days FROM DETECTION, and detection is the capture that
    # first showed the discounted price. The ledger was born on 2026-08-21 and stamped every one of its
    # 368 entries with that day, while the rows it was reading carried as_of dates back to 2026-07-14 -
    # a rollback captured five weeks earlier was handed a fresh 30 days on the day the bookkeeping
    # started. Anchoring to min(as_of, today) makes the anchor a fact about the STORE, not about us.
    [string]$AsOf = ''
  )
  if (-not (Test-RollbackTtlStore $Store)) { return $null }
  if (-not $ItemId) { return $null }        # no stable key -> no honest anchor -> no window
  Import-RollbackLedger $Root
  $todayS = if ($Today) { $Today } else { (Get-Date).ToString('yyyy-MM-dd') }
  # The honest anchor: the capture date when it is a real date and not in the future; otherwise today.
  # A future as_of is a clock or file-naming fault, and must not start a window that has not opened.
  $anchor = $todayS
  if ($AsOf -match '^\d{4}-\d{2}-\d{2}$' -and $AsOf -lt $todayS) { $anchor = $AsOf }
  $key = "$Store|$ItemId"

  $e = $script:RbLedger[$key]
  $isNew = $false
  if (-not $e) {
    $e = [ordered]@{ store = $Store; item_id = $ItemId; price = $Price; first_seen = $anchor; last_seen = $todayS; price_changed = 0 }
    $script:RbLedger[$key] = $e; Set-RollbackTouched $key; $isNew = $true
  }
  elseif ([math]::Abs([double]$e.price - $Price) -gt 0.005) {
    # A DIFFERENT ROLLED-BACK PRICE IS A DIFFERENT PROMOTION. Re-anchor and say so.
    $e.price = $Price; $e.first_seen = $anchor; $e.price_changed = [int]$e.price_changed + 1
    $e.last_seen = $todayS; Set-RollbackTouched $key; $isNew = $true
  }
  else {
    # SAME ROLLBACK, SEEN AGAIN. last_seen moves; first_seen MUST NOT ADVANCE - that is the whole rule.
    if ([string]$e.last_seen -ne $todayS) { $e.last_seen = $todayS; Set-RollbackTouched $key }
    # ...but it MAY move BACKWARD, to a capture that provably showed this price earlier than the ledger
    # knew. Earlier is the safe direction: it can only shorten the window, never extend it, so the
    # infinite-TTL failure this file exists to prevent cannot arrive through it.
    if ($anchor -lt [string]$e.first_seen) { $e.first_seen = $anchor; Set-RollbackTouched $key }
  }

  $from = [string]$e.first_seen
  $to = ''
  try { $to = ([datetime]::ParseExact($from, 'yyyy-MM-dd', $null)).AddDays($script:RollbackTtlDays).ToString('yyyy-MM-dd') } catch { }
  return [ordered]@{
    ad_from = $from; ad_to = $to; first_seen = $from; last_seen = [string]$e.last_seen
    is_new = $isNew; ttl_days = $script:RollbackTtlDays
    basis = "TTL - neither store publishes a rollback end date; anchored to first detection (the capture's as_of)"
  }
}

function Merge-RollbackEntry {
  <#
    One entry THIS process changed, folded into the entry on disk now ($Theirs, or $null when a sibling never had it).
    The rules are the ledger's own, applied across two writers instead of two sightings:
      SAME PRICE       one promotion seen by both: the EARLIER first_seen (earlier only ever shortens a window - see
                       Get-RollbackWindow) and the LATER last_seen. Neither write undoes the other.
      DIFFERENT PRICE  two promotions, and only one is current: the entry with the LATER last_seen wins whole; on a
                       tie, the one that re-anchored more times (it recorded the newer cut); then this writer.
                       Chosen, not measured - it needs two builds to see one item at two prices on the same day.
    price_changed keeps the larger count either way.
  #>
  param($Mine, $Theirs)
  if ($null -eq $Theirs) { return $Mine }
  $pc = [Math]::Max([int]$Mine.price_changed, [int]$Theirs.price_changed)
  if ([math]::Abs([double]$Mine.price - [double]$Theirs.price) -le 0.005) {
    $fs = [string]$Mine.first_seen; $tf = [string]$Theirs.first_seen
    if ($tf -and (-not $fs -or [string]::CompareOrdinal($tf, $fs) -lt 0)) { $fs = $tf }
    $ls = [string]$Mine.last_seen; $tl = [string]$Theirs.last_seen
    if ($tl -and (-not $ls -or [string]::CompareOrdinal($tl, $ls) -gt 0)) { $ls = $tl }
    return [ordered]@{ store = $Mine.store; item_id = $Mine.item_id; price = $Mine.price; first_seen = $fs; last_seen = $ls; price_changed = $pc }
  }
  $w = $Mine
  $c = [string]::CompareOrdinal([string]$Theirs.last_seen, [string]$Mine.last_seen)
  if ($c -gt 0 -or ($c -eq 0 -and [int]$Theirs.price_changed -gt [int]$Mine.price_changed)) { $w = $Theirs }
  return [ordered]@{ store = $w.store; item_id = $w.item_id; price = $w.price; first_seen = $w.first_seen; last_seen = $w.last_seen; price_changed = $pc }
}

function Save-RollbackLedger([string]$Root = '') {
  if ($null -eq $script:RbLedger) { return $false }
  if (-not $script:RbDirty) { return $true }
  if (-not $script:RbLedgerPath) { $script:RbLedgerPath = Get-RollbackLedgerPath $Root }
  $path = $script:RbLedgerPath
  # MERGE UNDER THE LOCK - see CONCURRENT BUILDERS in the header. The read is INSIDE the lock, and only the keys this
  # process touched come from memory. A ledger nobody loaded through Import has no touched set, so all of it counts.
  $touched = if ($null -ne $script:RbTouched) { @($script:RbTouched) } else { @($script:RbLedger.Keys) }
  $lk = Enter-TcLedgerLock -Path $path
  try {
    $disk = $null
    try { $disk = Read-RollbackLedgerFile $path }
    catch { throw ('REFUSING to save the rollback ledger: {0} exists but could not be read ({1}). Saving would replace every entry it holds with this build''s; the file is left exactly as it was.' -f $path, $_.Exception.Message) }
    foreach ($k in $touched) {
      $mine = $script:RbLedger[$k]
      if ($null -eq $mine) { continue }
      $disk[$k] = Merge-RollbackEntry -Mine $mine -Theirs $disk[$k]
    }
    $doc = [ordered]@{
      updated = (Get-Date).ToString('s')
      ttl_days = $script:RollbackTtlDays
      note = 'When each Walmart / Sam''s / Fareway rollback was FIRST observed. first_seen is the as_of of the capture that first showed the cut price (detection = the capture, not the day this ledger met the row - Brad, 2026-08-22) and is NEVER advanced - re-observing a rollback moves last_seen only, because an anchor that moves makes a 30-day TTL infinite; it may move EARLIER when a capture proves the price was already there. A CHANGED rolled-back price is a new promotion and re-anchors, counted in price_changed. Keyed by the store''s own item id, never the name, so a re-listing cannot restart the clock.'
      entries = @($disk.Keys | Sort-Object | ForEach-Object {
        $v = $disk[$_]
        [ordered]@{ key = $_; store = $v.store; item_id = $v.item_id; price = $v.price
                    first_seen = $v.first_seen; last_seen = $v.last_seen; price_changed = $v.price_changed }
      })
    }
    # The bytes this tracked ledger always had: UTF-8, no BOM, nothing appended - hence -NoBom -NoNewline.
    # Retried (2026-09-11): the lock serialises the savers, not a lock-free Import in a sibling builder, and a bare
    # Move-Item over a file that reader holds open fails outright with the lock held.
    # -Flush (2026-09-12, Brad's I117 ruling): this ledger is in the NOT-RE-DERIVED class - see the header.
    [void](Write-TcAtomicFile -Path $path -Text ($doc | ConvertTo-Json -Depth 5) -NoBom -NoNewline -Flush)
    # This process now holds what is on disk, so a later lookup sees the siblings' entries and a later save starts clean.
    $script:RbLedger = $disk
    $script:RbTouched = New-Object 'System.Collections.Generic.HashSet[string]'
    $script:RbDirty = $false
  } finally { Exit-TcLedgerLock $lk }
  return $true
}

# ---- ONE HOME FOR "THIS ROW IS A MARKDOWN" (2026-09-05) -------------------------------------------------
# THREE callers need this and it existed as TWO hand-copies. build-walmart-deals and build-sams-deals each
# carried the same ten lines, and the copy already cost something: the Sam's paste referenced
# $script:CaptureDate, which that file never assigns, so -Today bound to '' and Get-RollbackWindow fell back
# to the day the BUILDER RAN. Rebuilding an older capture then handed a weeks-old rollback a fresh 30 days,
# which is exactly the infinite-TTL failure this library exists to prevent (fixed 2026-08-25, in one copy).
#
# The third caller is why this is being extracted now. import-walmart-batch.ps1 calls Build-Row DIRECTLY and
# never entered either loop, so a batch-imported markdown got no base_price, no marked_down and no TTL - it
# published as an everyday price with a fresh as_of and rode the 90-day Walmart carry. Measured 2026-09-05:
# 4 of a 22-row produce refresh were markdowns, one of them a CROWN (lemons $0.50, was $0.68).
# Adding a third copy of ten lines to fix that would have been the same bet the first two lost.
#
# Returns $true when it stamped a markdown, $false otherwise. Inert when the capture carries no was-price,
# so every caller behaves exactly as before on the older capture formats.
function Set-RollbackFields {
  param(
    [Parameter(Mandatory=$true)]$Row,          # a built row; stamped in place
    $Was,                                      # the store's was-price, any format, absent is normal
    [Parameter(Mandatory=$true)][string]$Store,
    [string]$ItemId = '',
    # The CAPTURE's date, not the clock. Passing the build day is what re-dated Sam's anchors; the honest
    # anchor is the day the store's feed showed the cut price, which is the row's own as_of.
    [Parameter(Mandatory=$true)][string]$Date,
    [string]$Root = ''
  )
  $wasV = 0.0; $curV = 0.0
  [void][double]::TryParse((([string]$Was) -replace '[^0-9.]',''), [ref]$wasV)
  [void][double]::TryParse((([string]$Row.ad_price) -replace '[^0-9.]',''), [ref]$curV)
  # A was-price at or BELOW the current price is not a markdown. Stores emit one on a reverted rollback or a
  # re-listing, and reading it as a discount would invent a promotion that is not there.
  if (-not ($wasV -gt 0 -and $curV -gt 0 -and $wasV -gt $curV)) { return $false }
  $rw = Get-RollbackWindow -Store $Store -ItemId $ItemId -Price $curV -Today $Date -AsOf $Date -Root $Root
  if (-not $rw) { return $false }
  Add-Member -InputObject $Row -NotePropertyName 'base_price'  -NotePropertyValue $wasV       -Force
  Add-Member -InputObject $Row -NotePropertyName 'marked_down' -NotePropertyValue $true       -Force
  Add-Member -InputObject $Row -NotePropertyName 'ad_from'     -NotePropertyValue $rw.ad_from -Force
  Add-Member -InputObject $Row -NotePropertyName 'ad_to'       -NotePropertyValue $rw.ad_to   -Force
  Add-Member -InputObject $Row -NotePropertyName 'ad_basis'    -NotePropertyValue $rw.basis   -Force
  return $true
}

# ---- SELF-TEST: the ledger under concurrent builders (2026-09-11) ---------------------------------------
# test-rollback-ttl.ps1 carries the TTL rules. This carries the one thing a single process cannot show: what a
# save does when a SIBLING saved in between. Every case writes only into a temp directory.
#
# AN ERROR PART-WAY IS A FAILURE, NEVER A SHORT PASS. The first draft named its row helper `R`, which PowerShell
# resolves to the built-in alias for Invoke-History before any function; with errors non-terminating the suite ran
# ZERO cases and printed PASS with exit 0. So errors terminate here, and an unexpected one is a counted failure.
if ($__rbSelfTest) {
  $script:rbN = 0; $script:rbBad = 0
  function T([string]$What, [bool]$Cond, [string]$Detail = '') {
    $script:rbN++
    if ($Cond) { Write-Output ('  ok    ' + $What) }
    else { $script:rbBad++; Write-Output ('  FAIL  ' + $What + $(if ($Detail) { ' -> ' + $Detail } else { '' })) }
  }
  function New-RbRow([string]$S, [string]$I, [double]$P, [string]$F, [string]$L, [int]$C = 0) {
    [pscustomobject]@{ store = $S; item_id = $I; price = $P; first_seen = $F; last_seen = $L; price_changed = $C }
  }
  # A ledger file in the shape Save-RollbackLedger writes, as a SIBLING process would have left it.
  function Write-RbFixture([string]$Path, [object[]]$Rows) {
    $doc = [ordered]@{ updated = '2026-08-01T00:00:00'; ttl_days = 30; note = 'fixture'
      entries = @($Rows | ForEach-Object { [ordered]@{ key = ($_.store + '|' + $_.item_id); store = $_.store; item_id = $_.item_id; price = $_.price
                                                       first_seen = $_.first_seen; last_seen = $_.last_seen; price_changed = $_.price_changed } }) }
    [IO.File]::WriteAllText($Path, ($doc | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
  }
  function Reset-RbMemory { $script:RbLedger = $null; $script:RbLedgerPath = $null; $script:RbDirty = $false; $script:RbTouched = $null }
  function New-RbRoot([string]$Name) { $d = Join-Path $dir $Name; [void][IO.Directory]::CreateDirectory($d); return $d }

  $dir = Join-Path ([IO.Path]::GetTempPath()) ('rbttl-lock-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
  [void][IO.Directory]::CreateDirectory($dir)
  $ErrorActionPreference = 'Stop'
  try {
    # ---- 1. A sibling saved after this build loaded: its new entry and its earlier anchor both survive ----
    $r1 = New-RbRoot 'r1'; $p1 = Get-RollbackLedgerPath $r1
    Write-RbFixture $p1 @((New-RbRow 'Walmart' 'a1' 2.00 '2026-08-10' '2026-08-10'), (New-RbRow 'Walmart' 'b1' 3.00 '2026-08-12' '2026-08-12'))
    Reset-RbMemory
    [void](Get-RollbackWindow -Store 'Walmart' -ItemId 'c1' -Price 1.00 -Today '2026-08-20' -Root $r1)
    Write-RbFixture $p1 @((New-RbRow 'Walmart' 'a1' 2.00 '2026-08-10' '2026-08-10'), (New-RbRow 'Walmart' 'b1' 3.00 '2026-08-05' '2026-08-19'), (New-RbRow "Sam's Club" 'd1' 4.00 '2026-08-18' '2026-08-18'))
    $err1 = ''
    try { [void](Save-RollbackLedger $r1) } catch { $err1 = $_.Exception.Message }
    $m1 = Read-RollbackLedgerFile $p1
    $keys1 = (@($m1.Keys) | Sort-Object) -join ','
    T 'MUST FIRE  a save keeps an entry a SIBLING saved after this build loaded the ledger (writing the loaded copy erased it)' `
      ($err1 -eq '' -and $m1.ContainsKey("Sam's Club|d1") -and $m1.ContainsKey('Walmart|c1') -and $m1.Count -eq 4) ("keys=$keys1 error=$err1")
    T 'MUST FIRE  and does not put back the anchor that sibling moved EARLIER on an entry this build never touched' `
      ($m1.ContainsKey('Walmart|b1') -and [string]$m1['Walmart|b1'].first_seen -eq '2026-08-05') ('b1.first_seen=' + [string]$m1['Walmart|b1'].first_seen)
    $seen1 = Get-RollbackWindow -Store "Sam's Club" -ItemId 'd1' -Price 4.00 -Today '2026-08-21' -Root $r1
    T 'CLEAN TWIN after the save this process reads the MERGED ledger - the sibling''s entry is known, anchored where the sibling put it' `
      ($seen1.first_seen -eq '2026-08-18' -and -not $seen1.is_new) ("first_seen=$($seen1.first_seen) is_new=$($seen1.is_new)")
    $b1 = [IO.File]::ReadAllBytes($p1)
    T 'CLEAN TWIN a save writes the bytes this tracked ledger always had: UTF-8 with no BOM, and nothing after the closing brace' `
      ($b1.Length -gt 3 -and $b1[0] -eq 0x7B -and $b1[$b1.Length - 1] -eq 0x7D) ('first=' + $b1[0] + ' last=' + $b1[$b1.Length - 1])

    # ---- 2. Both writers touched ONE rollback at the same price ----
    $r2 = New-RbRoot 'r2'; $p2 = Get-RollbackLedgerPath $r2
    Write-RbFixture $p2 @((New-RbRow 'Walmart' 'e1' 5.00 '2026-08-10' '2026-08-10'))
    Reset-RbMemory
    [void](Get-RollbackWindow -Store 'Walmart' -ItemId 'e1' -Price 5.00 -Today '2026-08-25' -AsOf '2026-08-25' -Root $r2)
    Write-RbFixture $p2 @((New-RbRow 'Walmart' 'e1' 5.00 '2026-08-01' '2026-08-15'))
    [void](Save-RollbackLedger $r2)
    $e2 = (Read-RollbackLedgerFile $p2)['Walmart|e1']
    T 'MUST FIRE  one rollback touched by BOTH writers keeps the sibling''s earlier first_seen and this build''s later last_seen' `
      ($e2.first_seen -eq '2026-08-01' -and $e2.last_seen -eq '2026-08-25') ("first=$($e2.first_seen) last=$($e2.last_seen)")

    # ---- 3. Both writers touched one item at DIFFERENT prices: two promotions, the later sighting wins ----
    $r3 = New-RbRoot 'r3'; $p3 = Get-RollbackLedgerPath $r3
    Write-RbFixture $p3 @((New-RbRow 'Walmart' 'f1' 5.00 '2026-08-10' '2026-08-10'), (New-RbRow 'Walmart' 'g1' 5.00 '2026-08-10' '2026-08-10'))
    Reset-RbMemory
    [void](Get-RollbackWindow -Store 'Walmart' -ItemId 'f1' -Price 4.00 -Today '2026-08-25' -AsOf '2026-08-25' -Root $r3)
    [void](Get-RollbackWindow -Store 'Walmart' -ItemId 'g1' -Price 5.00 -Today '2026-08-20' -AsOf '2026-08-20' -Root $r3)
    Write-RbFixture $p3 @((New-RbRow 'Walmart' 'f1' 5.00 '2026-08-10' '2026-08-20'), (New-RbRow 'Walmart' 'g1' 3.50 '2026-08-24' '2026-08-24' 1))
    [void](Save-RollbackLedger $r3)
    $m3 = Read-RollbackLedgerFile $p3
    T 'CLEAN TWIN a DIFFERENT rolled-back price is a different promotion and the later sighting wins from either side (f1 ours at 4.00, g1 the sibling''s at 3.50)' `
      ([double]$m3['Walmart|f1'].price -eq 4.00 -and $m3['Walmart|f1'].first_seen -eq '2026-08-25' -and [double]$m3['Walmart|g1'].price -eq 3.50 -and $m3['Walmart|g1'].first_seen -eq '2026-08-24') `
      (($m3['Walmart|f1'] | ConvertTo-Json -Compress) + ' ' + ($m3['Walmart|g1'] | ConvertTo-Json -Compress))

    # ---- 4. An unreadable ledger on disk is refused, not replaced ----
    $r4 = New-RbRoot 'r4'; $p4 = Get-RollbackLedgerPath $r4
    Write-RbFixture $p4 @((New-RbRow 'Walmart' 'h1' 2.00 '2026-08-10' '2026-08-10'))
    Reset-RbMemory
    [void](Get-RollbackWindow -Store 'Walmart' -ItemId 'h2' -Price 2.00 -Today '2026-08-20' -Root $r4)
    [IO.File]::WriteAllText($p4, '{ "entries": [ torn', (New-Object Text.UTF8Encoding($false)))
    $before4 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($p4))
    $err4 = ''
    try { [void](Save-RollbackLedger $r4) } catch { $err4 = $_.Exception.Message }
    T 'MUST FIRE  an UNREADABLE ledger on disk is refused - the save throws rather than replace every entry with this build''s' ($err4 -match 'REFUSING') ("error=$err4")
    T 'CLEAN TWIN and the refused file still holds exactly the bytes it had' ($before4 -eq [Convert]::ToBase64String([IO.File]::ReadAllBytes($p4))) 'bytes changed'

    # ---- 5. Four builders at once, each the way a real build runs: load early, observe its own, save late ----
    # BARRIERED INSIDE THE LOCK (lib\ledger-fixture.ps1; ops-and-gates.md: the barrier goes inside the writer). Each
    # writer is its own powershell.exe that pays its start-up and dot-sources this file first, and is then held on the
    # fixture gate inside Enter-TcLedgerLock - which its LOAD reaches - until all four are there. So the four loads land
    # together and every save follows a load its siblings also made. A 400-entry seed keeps each load and save long.
    $r5 = New-RbRoot 'r5'; $p5 = Get-RollbackLedgerPath $r5
    $seedRows = @(1..400 | ForEach-Object { New-RbRow 'Walmart' ('seed-' + $_) 1.00 '2026-08-01' '2026-08-01' })
    Write-RbFixture $p5 $seedRows
    $writer5 = Join-Path $dir 'rb-writer.ps1'
    $writer5Text = @'
param([string]$Lib, [string]$Root, [int]$Index)
$ErrorActionPreference = 'Stop'
. $Lib
[void](Get-RollbackWindow -Store 'Walmart' -ItemId 'seed-1' -Price 1.00 -Today '2026-08-20' -Root $Root)
for ($n = 0; $n -lt 50; $n++) { [void](Get-RollbackWindow -Store 'Walmart' -ItemId ('w' + $Index + '-' + $n) -Price 2.50 -Today '2026-08-20' -AsOf '2026-08-18' -Root $Root) }
try { [void](Save-RollbackLedger $Root); Write-Output 'SAVED'; exit 0 } catch { Write-Output ('REFUSED ' + $_.Exception.Message); exit 1 }
'@
    [IO.File]::WriteAllText($writer5, $writer5Text, (New-Object Text.UTF8Encoding($false)))
    $argSets5 = New-Object System.Collections.Generic.List[object]
    foreach ($i in 1..4) { $argSets5.Add([string[]]@('-Lib', $PSCommandPath, '-Root', $r5, '-Index', [string]$i)) }
    $run5 = Invoke-TcLedgerWriters -Script $writer5 -ArgSets $argSets5.ToArray()
    $w5 = @($run5.writers)
    $ran5 = @($w5 | Where-Object { $_.ran }).Count
    $saved5 = @($w5 | Where-Object { $_.ran -and $_.exit -eq 0 -and [string]$_.out -match '(?m)^SAVED$' }).Count
    $why5 = Format-TcWriterTrouble $w5
    $m5 = @{}
    try { $m5 = Read-RollbackLedgerFile $p5 } catch { $why5 += ' | ledger unreadable: ' + $_.Exception.Message }
    $new5 = 0
    foreach ($i in 1..4) { foreach ($n in 0..49) { if ($m5.ContainsKey('Walmart|w' + $i + '-' + $n)) { $new5++ } } }
    $seed5 = 0
    foreach ($n in 1..400) { if ($m5.ContainsKey('Walmart|seed-' + $n)) { $seed5++ } }
    Write-Output ('  info  barrier: {0} of 4 writers were at the barrier when released ({1} ms)' -f $run5.ready_at_go, $run5.go_ms)
    T 'PREMISE    every builder RAN - launched, at the barrier when the four were released together, and exited' ($ran5 -eq 4) ("ran $ran5 of 4" + $why5)
    T 'MUST FIRE  four builders that load, observe and save AT ONCE lose none of each other''s entries' ($new5 -eq 200) ("kept $new5 of 200 new entries; $saved5 of 4 said SAVED" + $why5)
    T 'MUST FIRE  and no entry was lost SILENTLY - every writer said SAVED, so a refusal would be counted as a refusal' ($saved5 -eq 4) ("$saved5 of 4 said SAVED" + $why5)
    T 'CLEAN TWIN all 400 entries already in the ledger are still there' ($seed5 -eq 400) ("kept $seed5 of 400")
  } catch {
    T 'the self-test ran to its end with no unexpected error' $false ($_.Exception.Message + ' (line ' + $_.InvocationInfo.ScriptLineNumber + ')')
  } finally {
    $ErrorActionPreference = 'Continue'
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
  }
  Write-Output ('rollback-ttl-lib SELF-TEST {0} ({1} of {2} failed)' -f $(if ($script:rbBad) { 'FAIL' } else { 'PASS' }), $script:rbBad, $script:rbN)
  Write-Output ('ROLLBACK-TTL-LIB-COMPLETE cases={0} failed={1}' -f $script:rbN, $script:rbBad)
  if ($script:rbBad -gt 0) { exit 1 }
  exit 0
}
