<#
  instore-lib.ps1 - THE one definition of "is this row an IN-STORE shelf price?".

  ONE COPY ON PURPOSE. compare-deals.ps1 enforces this rule and audit-coverage-gaps.ps1 has to agree with
  it: that auditor reports "this store carries the product but is missing from the board", and every row
  this gate refuses looks exactly like one of those gaps. Its own header says an auditor that disagrees
  with the engine is a permanent false alarm, which is why it already lifts $GLOBAL_EXCLUDE out of the
  engine rather than keeping a second opinion. Same reasoning, same fix: both dot-source this.

      . (Join-Path $root 'instore-lib.ps1')
      if (-not (Test-InStore $row.fulfillment)) { ... }
#>

# IN-STORE PRICE MODE, ENFORCED PER ROW (2026-08-31). Brad's standing rule is that this board publishes
# what a shopper pays ON THE SHELF in Omaha. The Walmart capture carries that answer per row and nothing
# read it: `fulfillment` is STORE for a shelf item, FC for a walmart.com item shipped from a fulfillment
# centre, and MARKETPLACE for a third-party seller. Every one of those rows was being admitted and stamped
# source_ad='everyday shelf price', which is a false provenance claim on a price no Omaha shelf carries.
#
# THE FOUNDING BUG: achiote-paste. The 2026-08-30 capture holds BOTH of these -
#     Chef Merito Achiote Seasoning Paste, 3.5 Oz                              STORE   $2.27
#     Chef Merito Achiote ... Annatto Seed Paste, 3.5 oz, (Pack of 12)         FC     $16.24  <- won the crown
# the same jar, from the same brand, and the board crowned the shipped 12-pack case at $0.3867/oz because a
# case wins on per-unit. cochinita-pibil was then billed the whole 42 oz case and its cheapest-everywhere
# price computed 55% ABOVE its everyday price.
#
# ABSENT SIGNAL IS NOT A VERDICT. Only walmart-regular-2026-08-30 carries the field at all (499 of 525 rows);
# every older capture in the carry window has none, and a missing field must never read as "not in store" -
# that would empty most of the Walmart column on the day this shipped. So no signal passes, and the gate arms
# itself store by store as captures refresh. See the could-not-run-is-not-a-failure class.
# MEASURED 2026-08-31, so nobody has to re-derive it. The signal is WALMART-ONLY today - no other
# store's capture carries a fulfillment field on any row - and it arrived with the 08-30 pull:
#     walmart-regular-2026-08-29   234 rows,      0 carry the signal
#     walmart-regular-2026-08-30   525 rows,    499 carry it  (95%)
#     walmart-regular-2026-08-31 11694 rows,  11603 carry it  (99%)
#
# THE UNKNOWNS ARE FILLING IN, WHICH IS THE THING TO CHECK RATHER THAN ASSUME. Walmart is priced from
# a 90-day UNION, so a board cell held by a row captured before 08-30 has no signal and is ADMITTED by
# the rule above. Counting Walmart board cells whose winning product appears in NO signal-carrying
# capture, as each one landed:
#     signal up to 2026-08-29 -> 529 of 529 unknown (100%)
#     signal up to 2026-08-30 -> 508 of 529         ( 96%)
#     signal up to 2026-08-31 ->  71 of 529         ( 13%)
# So they resolve as captures refresh, exactly as designed, and the remaining 71 clear when a later
# pull returns those products or their rows age out of the window. DO NOT GATE ON THEM: an absent
# signal is not evidence a product is off the shelf, and hard-failing the unknowns would empty most of
# the Walmart column for a fact nobody measured. That is the could-not-run-is-not-a-failure class.
$SHELF_FULFILLMENT = @('STORE')
function Test-InStore($ful) {
  $f = ('' + $ful).Trim().ToUpper()
  if (-not $f) { return $true }
  return ($SHELF_FULFILLMENT -contains $f)
}

# =====================================================================================================
# CHANNEL PROOF BY ITEM ID - the doubt promoted to a REFUSAL (2026-09-01)
# =====================================================================================================
# Test-InStore above answers ONE row's question from ONE row's field, and it admits a blank because a
# blank used to mean "captured before the field existed". audit-instore-channel.ps1 showed that a blank
# is now ambiguous, named the two shapes where it is not innocent, and deliberately dropped NOTHING
# because only a shelf-badge probe could settle them.
#
# THAT PROBE HAS RUN. 2026-09-01, all 21 doubted cells, in Brad's Chrome against Omaha L St / 68137,
# no bot wall and no CAPTCHA on any of them (out\instore-badge-evidence.json holds URL, item id, live
# price and a quoted page observation per cell):
#     19 of 21 NOT IN STORE   2 of 21 IN STORE   0 walled   0 unreadable
# Eight of the nine doubted CROWNS were wrong, i.e. eight live reader-facing "cheapest in Omaha" claims
# were quoting a price no Omaha shelf carries. The three shapes the probe found:
#   (a) an outright marketplace listing with a named third-party seller (fish sauce sold by "Noelle's
#       Suitcase", Miracle Whip by "Ociene LLC") - never a shelf price at all;
#   (b) an "(N pack)" bundle that exists only as an online item number, out of stock at Omaha L St;
#   (c) sold by Walmart.com but ship-from-FC, no store-level stock line, Delivery "Not available".
# "Cannot prove an in-store channel" therefore predicted "not in store" 19 times out of 21, which is
# what justifies refusing instead of watching.
#
# THE RULE: THE NEWEST FIELD-BEARING SIGHTING OF AN ITEM ID IS AUTHORITATIVE FOR THAT ITEM ID.
# A capture is FIELD-BEARING when it populates `fulfillment` on at least half its rows - the real files
# sit at 99% or at 0%, never near the line, so the threshold is not a judgement call. Inside such a
# capture a blank is not "not collected", it is "the puller could not attribute this row", and over half
# of those are the "(N pack)" bundles of shape (b). So:
#     row says STORE                    -> ADMIT (the store's own word, per row, always wins)
#     row says FC / MARKETPLACE         -> REFUSE (unchanged, this is the achiote gate)
#     row blank, id proven STORE later  -> ADMIT (a fresher capture answered the question positively)
#     row blank, id refused later       -> REFUSE (a fresher capture answered it negatively)
#     row blank, id never seen with the field -> ADMIT (absent evidence is still not evidence)
# Keying on the ITEM ID rather than on the row is what closes the hole the watcher could only report:
# the engine unions 90 days, so refusing the 08-31 row of a ship-only product achieves nothing while its
# pre-field 08-11 row is still standing. Measured over the 58,605 Walmart rows on disk 2026-09-01:
# 11,737 item ids carry a field-bearing sighting (8,814 STORE, 2,089 FC, 742 MARKETPLACE, 92 blank), and
# the rule refuses 6,470 rows of which 3,016 were already refused by fulfillment alone.
#
# THE PICKUP WORD IS NOT THE PROOF, AND NO GATE HERE MAY READ ONE. The probe found "Pickup: Check
# nearby" and "Pickup: Get it nearby" on ship-only items - they are prompts, not confirmations, and
# apple-cider-vinegar and grits both wear "Get it nearby" while shipping from a fulfilment centre. The
# only positive tell is a STORE-LEVEL line ("As soon as 6pm today", "Out of stock at Omaha L St
# Supercenter / Available for pickup nearby"). This library never sees a page; it reads the capture's
# own `fulfillment` verdict, which is that store-level answer already reduced to a word.
#
# THE REVIEWED EXCEPTION LIST exists because 2 of the 21 were real. El Guapo bay leaves (item 30919180,
# live $1.63 = board, "Out of stock at Omaha L St Supercenter / Available for pickup nearby" - a genuine
# store SKU that happens to be off the shelf today) and Scott paper towels (item 8886020987, live $6.84 =
# board, Pickup "As soon as 6pm today"). Refusing those would throw away two correct cells, which is the
# same error in the other direction. An entry only ever overrides a DOUBT verdict: a row whose own
# fulfillment says FC or MARKETPLACE is refused no matter what the list says, because that is the store
# stating the answer rather than us failing to find it.
$CHANNEL_SHIP_ONLY = @('FC', 'MARKETPLACE')

function Get-ChannelFileDate([string]$fileBase) {
  # 'walmart-regular-2026-08-31' -> '2026-08-31'; '' when the name carries no date (a fixture, an ad row).
  $m = [regex]::Match(('' + $fileBase), '(\d{4}-\d{2}-\d{2})\s*$')
  if ($m.Success) { return $m.Groups[1].Value }
  return ''
}

function Get-ChannelAllowlist {
  <# Reviewed exceptions, in the estate's standard allowlist shape: { readme, allow: [ ... ] }.
     Keyed store|id|<item_id> first (ids do not move; Walmart rewrites titles), store|nm|<lowercased name>
     as the fallback for a store that publishes no id. A file that will not parse yields an EMPTY list,
     never a crash: this runs inside the board build, and a corrupt exception file must fail towards
     refusing more rather than towards taking the engine down. #>
  param([string]$Path)
  $h = @{}
  if (-not $Path -or -not (Test-Path $Path)) { return $h }
  $doc = $null
  try { $doc = Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $h }
  if ($null -eq $doc) { return $h }
  foreach ($e in @($doc.allow)) {
    if ($null -eq $e) { continue }
    $st = ('' + $e.store).Trim()
    if (-not $st) { continue }
    $why = ('' + $e.why).Trim()
    $iid = ('' + $e.item_id).Trim()
    $nm = ('' + $e.item).Trim()
    if ($iid) { $h[($st + '|id|' + $iid)] = $why }
    if ($nm) { $h[($st + '|nm|' + $nm.ToLower())] = $why }
  }
  return $h
}

function New-ChannelIndex {
  <# ONE pass over the rows the engine has already loaded - no file is re-read. Rows need .store,
     .fulfillment, a capture file name (.src_file) and an id (.item_id or .product_id).

     PS 5.1: every hashtable value here is a plain string or a bool. Storing a
     System.Collections.Generic.List[object] as a hashtable VALUE makes even a flat $h[$key] throw
     "Argument types do not match" while $h.ContainsKey($key) returns True - reproduced 2026-09-01 and
     already written down in audit-instore-channel.ps1's header.

     AND THE ROWS ARE ENUMERATED BARE, NEVER `@($Rows)`. A second PS 5.1 trap, isolated 2026-09-01:
     wrapping a PARAMETER that is bound to a System.Collections.Generic.List[object] in @() throws
     "Argument types do not match" outright. `foreach ($r in $Rows)` on the same value works. Minimal
     repro on 5.1.26100:
         function T1 { param($Rows) foreach ($r in @($Rows)) { $r.name } }   # throws
         function T2 { param($Rows) foreach ($r in $Rows)    { $r.name } }   # fine
         $l = New-Object System.Collections.Generic.List[object]; $l.Add([pscustomobject]@{name='x'})
     The engine passes exactly that List, so the @() form crashed the whole board build while the
     self-test - which passed a plain ARRAY - stayed green. That is why the self-test now runs BOTH
     shapes: a fixture that cannot reach the caller's real type proves nothing about the caller. #>
  param($Rows, $Allowlist)
  $rowsSeen = @{}      # store|file -> total rows
  $rowsField = @{}     # store|file -> rows carrying a fulfillment
  if ($null -eq $Rows) { $Rows = @() }
  foreach ($r in $Rows) {
    if ($null -eq $r) { continue }
    $k = ('' + $r.store) + '|' + ('' + $r.src_file)
    if ($rowsSeen.ContainsKey($k)) { $rowsSeen[$k] = $rowsSeen[$k] + 1 } else { $rowsSeen[$k] = 1; $rowsField[$k] = 0 }
    if (('' + $r.fulfillment).Trim()) { $rowsField[$k] = $rowsField[$k] + 1 }
  }
  $bearing = @{}
  foreach ($k in $rowsSeen.Keys) { $bearing[$k] = (($rowsSeen[$k] -gt 0) -and (($rowsField[$k] / $rowsSeen[$k]) -ge 0.5)) }

  $verdict = @{}       # store|id -> the newest field-bearing fulfillment word ('' = seen blank)
  $vdate = @{}         # store|id -> that sighting's capture date
  $vfile = @{}         # store|id -> that sighting's capture file, for the message
  foreach ($r in $Rows) {
    if ($null -eq $r) { continue }
    $file = '' + $r.src_file
    if (-not $bearing[(('' + $r.store) + '|' + $file)]) { continue }
    $iid = ('' + $r.item_id).Trim()
    if (-not $iid) { $iid = ('' + $r.product_id).Trim() }
    if (-not $iid) { continue }
    $key = ('' + $r.store) + '|' + $iid
    $d = Get-ChannelFileDate $file
    if ((-not $vdate.ContainsKey($key)) -or ($d -ge $vdate[$key])) {
      $vdate[$key] = $d; $vfile[$key] = $file; $verdict[$key] = ('' + $r.fulfillment).Trim().ToUpper()
    }
  }
  if ($null -eq $Allowlist) { $Allowlist = @{} }
  return [pscustomobject]@{ Bearing = $bearing; Verdict = $verdict; VDate = $vdate; VFile = $vfile; Allow = $Allowlist }
}

function Get-ChannelVerdict {
  <# -> @{ in_store = [bool]; why = <short code>; detail = <one line a human can act on> }
     $Index may be $null (no capture context available), in which case this degrades exactly to
     Test-InStore and nothing new is refused. #>
  param($Index, [string]$Store, [string]$SrcFile, [string]$ItemId, $Fulfillment, [string]$ItemName = '')
  $f = ('' + $Fulfillment).Trim().ToUpper()
  if ($f) {
    if ($SHELF_FULFILLMENT -contains $f) { return [pscustomobject]@{ in_store = $true; why = 'STORE'; detail = '' } }
    return [pscustomobject]@{ in_store = $false; why = $f
      detail = ("the capture row itself records fulfillment={0}, so the store states this listing is not sold on the Omaha shelf" -f $f) }
  }
  if ($null -eq $Index) { return [pscustomobject]@{ in_store = $true; why = 'NO-SIGNAL'; detail = '' } }

  $iid = ('' + $ItemId).Trim()
  $key = $Store + '|' + $iid
  # An exception is allowed to name the product instead of its id, for a store that publishes none.
  # Resolved to ONE key here so every branch below asks the same question.
  $allowKeyId = ''
  if ($iid -and $Index.Allow.ContainsKey($Store + '|id|' + $iid)) { $allowKeyId = $Store + '|id|' + $iid }
  elseif (('' + $ItemName).Trim() -and $Index.Allow.ContainsKey($Store + '|nm|' + ('' + $ItemName).Trim().ToLower())) { $allowKeyId = $Store + '|nm|' + ('' + $ItemName).Trim().ToLower() }
  if ($iid -and $Index.Verdict.ContainsKey($key)) {
    $v = '' + $Index.Verdict[$key]
    if ($SHELF_FULFILLMENT -contains $v) {
      return [pscustomobject]@{ in_store = $true; why = 'PROVEN-STORE-BY-FRESHER-CAPTURE'; detail = '' }
    }
    if ($allowKeyId) {
      return [pscustomobject]@{ in_store = $true; why = 'REVIEWED-EXCEPTION'
        detail = ("reviewed exception for '{0}' (item {1}) at {2}: {3}" -f $ItemName, $iid, $Store, $Index.Allow[$allowKeyId]) }
    }
    if ($v) {
      return [pscustomobject]@{ in_store = $false; why = 'PRE-FIELD-ROW-OUTLIVING-A-REFUSAL'
        detail = ("this row states no channel, but item {0} reads {1} in the field-bearing capture {2} - the freshest answer the store gave about this listing is that it is not a shelf item" -f $iid, $v, $Index.VFile[$key]) }
    }
    return [pscustomobject]@{ in_store = $false; why = 'BLANK-IN-FIELD-BEARING-CAPTURE'
      detail = ("item {0} has an EMPTY fulfillment in {1}, a capture that populates the field on the rest of its rows, so the channel was never attributed rather than never collected" -f $iid, $Index.VFile[$key]) }
  }

  # No id, or an id no field-bearing capture has ever seen. A blank inside a field-bearing capture is
  # still a blank the puller could not attribute, so shape (a) is caught even for an id-less row.
  if ($Index.Bearing[($Store + '|' + ('' + $SrcFile))]) {
    if ($allowKeyId) {
      return [pscustomobject]@{ in_store = $true; why = 'REVIEWED-EXCEPTION'; detail = ("reviewed exception for '{0}' (item {1}) at {2}: {3}" -f $ItemName, $iid, $Store, $Index.Allow[$allowKeyId]) }
    }
    return [pscustomobject]@{ in_store = $false; why = 'BLANK-IN-FIELD-BEARING-CAPTURE'
      detail = ("an EMPTY fulfillment in {0}, a capture that populates the field on the rest of its rows" -f $SrcFile) }
  }
  return [pscustomobject]@{ in_store = $true; why = 'NO-SIGNAL'; detail = '' }
}
