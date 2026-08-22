<#
  carry-forward-regular.ps1 - "absence from one throttled response is not evidence of absence from the
  store" (the Family Fare lesson of 2026-07-14), extended to the stores that never got it: Baker's,
  Aldi, Fareway (2026-07-23, improvement item 4).

  THE PROBLEM: these stores' everyday files are written wholesale by the browser agents, and
  compare-deals takes the NEWEST file per store. A partial pull (Akamai wall, agent interrupted,
  thin search results) therefore silently REPLACES a fuller capture, and the missing items fall off
  the board - the coverage guard then HOLDS the publish (safe, but a lost refresh day). These stores
  cannot use the Walmart/Sam's UNION: their sale rows are dated, so a freshness-ranked union would
  filter a still-valid sale out (pinned by compare-deals self-test case 13). The fix that IS safe is
  carry-forward at file level: after a new capture is written, items present in the PREVIOUS capture
  but absent from this one are copied in, stamped with their true capture date (as_of), and dropped
  once they age past -MaxCarryDays. The file stays a single newest-wins file; no ranker semantics change.

  Idempotent: carried rows land in the newest file, so a re-run finds nothing new to carry.
  Chained age: a carried row keeps its ORIGINAL as_of across successive carries and expires from that
  date, never from the date it was last copied.

  Called by: the weekly browser SKILL (Baker's step C, Aldi step F2), the Fareway builds
  (build-fareway-regular.ps1 tail). Run manually anytime; it only ever touches the newest file.
#>
param(
  [ValidateSet('bakers','aldi','fareway')][string]$Store,
  [int]$MaxCarryDays = 90,   # = capture policy MaxCarryDays (quarterly rotation); -SelfTest passes its own
  [string]$RegularDir = "",
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
# -Store is REQUIRED for a real run but must NOT be declared Mandatory (2026-08-08). PowerShell prompts for a
# missing mandatory parameter, so `-SelfTest` alone could never be invoked: it died with
# MissingMandatoryParameter on any non-interactive runner. This file's self-test therefore existed and had
# never once run - the "a fix needs a reachable self-test" class, found the day a change-time gate was added
# and 4 of 80 self-tests turned out to be unreachable for exactly this reason. Enforced explicitly instead.
if (-not $SelfTest -and -not $Store) { throw '-Store is required (bakers|aldi|fareway)' }
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$regDir = if ($RegularDir) { $RegularDir } else { Join-Path $root 'out\regular' }

function Get-CarryKey([string]$item) {
  <#
    The identity key for "do we already have this product today?".

    IT CANNOT BE THE RAW NAME. On 2026-07-29 Aldi changed its name format - trailing size tokens went from 3.4%
    of names to 88.3% ("Ground Beef 80/20" -> "Ground Beef 80 20 1 Per LB", "Broccoli Crowns" -> "Broccoli
    Crowns Per LB") - so every renamed product read as ABSENT and got carried from an 11-day-old file even
    though it HAD been pulled that morning. 199 of 335 published Aldi cells became stale duplicates of fresh
    rows, and the stale copy wins the ranking because ranking has no freshness tiebreak.

    So: fold case, flatten punctuation, and strip a TRAILING measure phrase (repeatedly - names carry more than
    one). Interior numbers are left alone, so two genuinely different sizes of the same product still key apart
    unless the size is the only thing at the end. Collapsing too much only ever SUPPRESSES a carry, which is the
    safe direction: a missing carried row costs coverage, a stale carried row prices the board wrong.
  #>
  $k = ([string]$item).ToLower().Trim()
  $k = ($k -replace '[^a-z0-9\. ]', ' ')
  $k = ($k -replace '\s+', ' ').Trim()
  $unit = '(?:fl\s*oz|floz|oz|ounces?|lbs?|pounds?|ct|count|pk|packs?|gal|gallons?|qt|quarts?|pt|pints?|ml|liters?|litres?|each|ea|dozen|doz)'
  for ($i = 0; $i -lt 4; $i++) {
    $before = $k
    # "1 Per LB" / "Per LB" / "20 OZ" - a quantity bound to a unit. Do NOT strip bare trailing numbers: that
    # would fold "ground beef 80 20" and "ground beef 93 7" onto the same key and suppress the carry for
    # whichever grind was not pulled today.
    $k = ($k -replace ('\s+\d+(?:\.\d+)?\s+per\s+' + $unit + '\.?$'), '')
    $k = ($k -replace ('\s+per\s+' + $unit + '\.?$'), '')
    $k = ($k -replace ('\s+\d+(?:\.\d+)?\s*' + $unit + '\.?$'), '')
    $k = $k.Trim()
    if ($k -eq $before -or -not $k) { break }
  }
  if (-not $k) { $k = ([string]$item).ToLower().Trim() }   # never return empty - fall back to the raw name
  return $k
}

function Invoke-CarryForward([string]$prefix, [string]$dir, [int]$maxDays) {
  $files = @(Get-ChildItem (Join-Path $dir ($prefix + '-regular-*.json')) -ErrorAction SilentlyContinue |
    Where-Object { $_.BaseName -match ('^' + [regex]::Escape($prefix) + '-regular-\d{4}-\d{2}-\d{2}$') } |
    Sort-Object Name -Descending)
  if ($files.Count -lt 2) { return "carry-forward [$prefix]: fewer than 2 dated captures - nothing to carry from" }
  $newF = $files[0]
  $newDate = [datetime]([regex]::Match($newF.BaseName, '(\d{4}-\d{2}-\d{2})$').Groups[1].Value)
  $new = Get-Content $newF.FullName -Raw | ConvertFrom-Json
  $have = @{}
  foreach ($d in @($new.deals)) { $have[(Get-CarryKey $d.item)] = $true }

  # ---------------------------------------------------------------------------------------------
  # A SEARCHED TERM THAT DID NOT RETURN AN ITEM IS THE STORE SAYING THE ITEM IS GONE (2026-08-22).
  #
  # THE BUG. This carried anything "absent from this pull", full stop. That is right for the ~590
  # terms a day's rotation never touches - they have no fresh data and their rows must survive. It is
  # WRONG for a term the pull DID search: if we asked Aldi for "boneless skinless chicken breast",
  # got 9 products back, and last week's winner was not among them, that product is out of stock or
  # delisted. Carrying it publishes a price for something the store does not sell.
  #
  # MEASURED, the day this shipped. The board's Aldi chicken-breast cell was
  # "Kirkwood Boneless Skinless Chicken Breast Fillets Family Pack" at $10.95/5 lb = $2.19/lb, carried
  # from 2026-08-15. That term WAS searched that morning and returned 9 products; the Kirkwood pack
  # was not one of them. Aldi's real cheapest was a family pack at $8.22 = $2.99/lb. So the board
  # published an unavailable product 27% under the true price, and beat the genuine winner with it.
  #
  # IT ALSO EXPLAINS THE DEAD LINKS. Those resurrected rows come from captures written before the
  # identity rule, so they carry no link_url and nothing can ever re-point their tile. Re-capturing
  # could not displace them either - carry-forward simply put them back the next build. 118 Aldi
  # cells were held open this way.
  #
  # WHY "COVERED" IS DEFINED AS "THIS CAPTURE HAS ROWS FOR THAT TERM", AND NOT "THE TERM WAS ASKED
  # FOR": a blocked term returns nothing, and a bot wall must never read as "the store dropped its
  # whole catalogue". A term that yielded zero rows is therefore NOT covered, so its items keep
  # carrying exactly as before. The failure direction is deliberate - we under-retire rather than
  # delete a store on a wall.
  $coveredTerms = @{}
  $newDateS = $newDate.ToString('yyyy-MM-dd')
  foreach ($d in @($new.deals)) {
    # Only rows THIS capture actually produced count. A row carried in by a previous run keeps its own
    # older as_of, and letting it mark its term "covered" would retire the very rows it came with.
    $rowAsOf = if ($d.PSObject.Properties['as_of']) { [string]$d.as_of } else { $newDateS }
    if ($rowAsOf -ne $newDateS) { continue }
    $t = if ($d.PSObject.Properties['found_by_term']) { ([string]$d.found_by_term).ToLower().Trim() } else { '' }
    if ($t) { $coveredTerms[$t] = $true }
  }
  # Does THIS capture record provenance at all? Used to scope the legacy-retirement rule below, so a
  # lane that never writes these fields is never punished for it.
  $newHasProvenance = $false
  foreach ($d in @($new.deals)) {
    $rowAsOf = if ($d.PSObject.Properties['as_of']) { [string]$d.as_of } else { $newDateS }
    if ($rowAsOf -ne $newDateS) { continue }
    if (($d.PSObject.Properties['found_by_term'] -and $d.found_by_term) -or
        ($d.PSObject.Properties['link_url'] -and $d.link_url)) { $newHasProvenance = $true; break }
  }
  $retired = 0
  $carried = 0; $expired = 0
  $outDeals = New-Object System.Collections.Generic.List[object]
  foreach ($d in @($new.deals)) { $outDeals.Add($d) }
  # WALK EVERY prior capture inside the window, newest first (2026-07-23 lesson: one-file-back missed items
  # that last appeared two pulls ago - Fareway bar-soap/cantaloupe/honeydew survived in the 07-15 file but not
  # 07-18, so a single-hop carry lost them). Newest occurrence of an item wins; the age cap still counts from
  # each row's ORIGINAL as_of, so walking further back can never resurrect anything past the policy window.
  $carrySrc = @()
  foreach ($prevF in ($files | Select-Object -Skip 1)) {
    $prevDate = [datetime]([regex]::Match($prevF.BaseName, '(\d{4}-\d{2}-\d{2})$').Groups[1].Value)
    if (($newDate - $prevDate).TotalDays -gt $maxDays) { break }   # files sorted newest-first; older = all out
    $prev = Get-Content $prevF.FullName -Raw | ConvertFrom-Json
    foreach ($d in @($prev.deals)) {
      $k = Get-CarryKey $d.item
      if (-not $k -or $have.ContainsKey($k)) { continue }

      # THE RETIREMENT TEST. If this capture searched the row's own term and returned products, but not
      # THIS product, the store no longer lists it - do not carry it. See the block above for the
      # measured case this exists for.
      $dTerm = if ($d.PSObject.Properties['found_by_term']) { ([string]$d.found_by_term).ToLower().Trim() } else { '' }
      if ($dTerm -and $coveredTerms.ContainsKey($dTerm)) {
        $have[$k] = $true      # decided: never reconsider it from an even older file
        $retired++
        continue
      }

      # NO TERM AND NO LINK IS A ROW NOTHING CAN EVER CHECK (2026-08-22).
      # The test above needs a found_by_term to ask "was this re-searched?". Rows captured before that
      # field existed have none - and the same era recorded no link_url either. Measured on Aldi that
      # day: 186 such rows, ALL from July, winning 75 live board cells. They cannot be re-found (no
      # term), cannot be linked (no url), and cannot be retired by the rule above, so they sit at the
      # front of the cheapest-sort forever. Two of them were the last things holding the board red.
      # Brad's reasoning, and it is the right one: if we cannot link, verify or re-find a product,
      # that generally means it is not available - so the cell should show the product the store
      # ACTUALLY sells. The chicken proved it: retiring an out-of-stock $2.19/lb pack let Aldi's real
      # $2.99/lb family pack win. Better a true price on a stocked item than a cheap one on a ghost.
      # NARROW ON PURPOSE: only rows that have NEITHER field. A row with either one is still
      # checkable and still carries. This retires provenance-less rows, never merely old ones.
      # ONLY WHEN THIS LANE DEMONSTRABLY RECORDS PROVENANCE NOW. The first version of this retired any
      # row lacking both fields, and the self-test caught it immediately: a fixture whose CURRENT
      # capture also records neither lost every carried row. That would gut any lane that simply does
      # not write these fields, turning a legacy-cleanup into data loss.
      # So the question is comparative, not absolute: does TODAY'S capture prove the store now records
      # provenance? If it does, a row carrying none is from an older contract and is unverifiable.
      # If it does not, this lane never recorded it and nothing may be retired on that basis.
      $dLink = if ($d.PSObject.Properties['link_url']) { [string]$d.link_url } else { '' }
      if ($newHasProvenance -and -not $dTerm -and -not $dLink) {
        $have[$k] = $true
        $retired++
        continue
      }

      $have[$k] = $true    # newest-first walk: first sighting wins, older sightings skipped
      # true capture date: a row already carried once keeps its original as_of
      $asOf = $prevDate
      if ($d.PSObject.Properties['as_of'] -and $d.as_of) { try { $asOf = [datetime]$d.as_of } catch {} }
      if (($newDate - $asOf).TotalDays -gt $maxDays) { $expired++; continue }
      $row = $d | Select-Object *   # shallow copy so we never mutate the prev doc
      if (-not $row.PSObject.Properties['as_of']) { $row | Add-Member -NotePropertyName as_of -NotePropertyValue $asOf.ToString('yyyy-MM-dd') }
      else { $row.as_of = $asOf.ToString('yyyy-MM-dd') }
      $outDeals.Add($row); $carried++
    }
    $carrySrc += $prevF.Name
  }
  $prevF = [pscustomobject]@{ Name = ($carrySrc -join ' + ') }   # for the note below
  if ($carried -eq 0 -and $expired -eq 0 -and $retired -eq 0) { return "carry-forward [$prefix]: newest capture already covers everything in the window - nothing carried" }
  $new.deals = $outDeals
  # note the operation in the envelope without disturbing other fields (price_mode etc. must survive)
  # `retired` is reported, never silent: it is the count of rows this build deliberately let go because
  # their term was re-searched and they did not come back. A number that jumps is worth looking at -
  # it means a whole term's products changed, or a lane started returning a different shape.
  $note = ("carry-forward: +{0} item(s) from {1} (absent from this pull; as_of-stamped, {2}-day cap), {3} expired, {4} retired (term re-searched, product gone)" -f $carried, $prevF.Name, $maxDays, $expired, $retired)
  if ($new.PSObject.Properties['carry_note']) { $new.carry_note = $note } else { $new | Add-Member -NotePropertyName carry_note -NotePropertyValue $note }
  $new | ConvertTo-Json -Depth 6 | Set-Content $newF.FullName -Encoding UTF8
  return "carry-forward [$prefix]: $note -> $($newF.Name)"
}

if ($SelfTest) {
  $fail = 0
  $T = Join-Path $env:TEMP ('cf-selftest-' + [guid]::NewGuid().ToString('N').Substring(0,8))
  New-Item -ItemType Directory -Path $T -Force | Out-Null
  try {
    $today = [datetime]::Today
    $d0 = $today.ToString('yyyy-MM-dd')                    # newest (partial: 1 item)
    $d1 = $today.AddDays(-5).ToString('yyyy-MM-dd')        # previous (3 items, 1 pre-carried and expired)
    $prevDeals = @(
      @{ store='Aldi'; item='Milk';   ad_price='$3.39'; size='1 gal' },
      @{ store='Aldi'; item='Eggs';   ad_price='$1.65'; size='dozen' },
      @{ store='Aldi'; item='Butter'; ad_price='$3.19'; size='16 oz'; as_of=$today.AddDays(-20).ToString('yyyy-MM-dd') }  # already 20d old -> expires
    )
    @{ store='Aldi'; price_type='everyday'; price_mode='in-store'; mode_verified=$d1; deals=$prevDeals } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $T "aldi-regular-$d1.json") -Encoding UTF8
    @{ store='Aldi'; price_type='everyday'; price_mode='in-store'; mode_verified=$d0; deals=@(@{ store='Aldi'; item='Milk'; ad_price='$3.45'; size='1 gal' }) } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $T "aldi-regular-$d0.json") -Encoding UTF8
    $r = Invoke-CarryForward 'aldi' $T 14
    Write-Output $r
    $out = Get-Content (Join-Path $T "aldi-regular-$d0.json") -Raw | ConvertFrom-Json
    $items = @($out.deals | ForEach-Object { $_.item })
    if ($items.Count -eq 2 -and ($items -contains 'Milk') -and ($items -contains 'Eggs')) { Write-Output 'ok    partial pull keeps its own row + carries the missing one' } else { Write-Output "FAIL  items = $($items -join ',') want Milk,Eggs"; $fail++ }
    if (-not ($items -contains 'Butter')) { Write-Output 'ok    20-day-old pre-carried row expired (14-day cap from ORIGINAL as_of)' } else { Write-Output 'FAIL  expired row was carried'; $fail++ }
    $eggs = $out.deals | Where-Object { $_.item -eq 'Eggs' }
    if ($eggs.as_of -eq $d1) { Write-Output "ok    carried row stamped as_of=$d1 (its true capture date)" } else { Write-Output "FAIL  eggs as_of=$($eggs.as_of)"; $fail++ }
    if ($out.price_mode -eq 'in-store' -and $out.mode_verified) { Write-Output 'ok    envelope (price_mode/mode_verified) survives untouched' } else { Write-Output 'FAIL  envelope damaged'; $fail++ }
    $milk = $out.deals | Where-Object { $_.item -eq 'Milk' }
    if ($milk.ad_price -eq '$3.45') { Write-Output 'ok    fresh row NOT overwritten by the stale one' } else { Write-Output "FAIL  milk = $($milk.ad_price)"; $fail++ }
    # idempotency: run again -> nothing new
    $r2 = Invoke-CarryForward 'aldi' $T 14
    $out2 = Get-Content (Join-Path $T "aldi-regular-$d0.json") -Raw | ConvertFrom-Json
    if (@($out2.deals).Count -eq 2) { Write-Output 'ok    idempotent (second run carries nothing new)' } else { Write-Output "FAIL  second run -> $(@($out2.deals).Count) rows"; $fail++ }

    # ---- RETIREMENT: a re-searched term whose product did not come back ------------------------
    # FROZEN FOUNDING CASE (2026-08-22). Aldi's chicken-breast cell published
    # "Kirkwood Boneless Skinless Chicken Breast Fillets Family Pack" at $2.19/lb, carried from
    # 08-15. That term WAS searched that morning and returned 9 products - the Kirkwood pack was not
    # among them, because it is out of stock. Aldi's real cheapest was $2.99/lb, so the board
    # published an unavailable product 27% under the true price and let it beat the genuine winner.
    # MUST-FIRE: with the fix, the gone product is retired. CLEAN TWIN: a product whose term was NOT
    # searched this pull still carries, because most terms are untouched on any given day.
    $T2 = Join-Path $env:TEMP ('cf-retire-' + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path $T2 -Force | Out-Null
    try {
      $prev2 = @(
        @{ store='Aldi'; item='Kirkwood Chicken Breast Fillets Family Pack'; ad_price='$10.95'; size='5 lb'; found_by_term='boneless skinless chicken breast' },
        @{ store='Aldi'; item='Friendly Farms Whole Milk';                   ad_price='$3.39';  size='1 gal'; found_by_term='milk gallon' }
      )
      # Today's pull searched the CHICKEN term (and found a different product) but never touched milk.
      $new2 = @(
        @{ store='Aldi'; item='Fresh Family Pack Boneless Skinless Chicken Breast'; ad_price='$8.22'; size='2.75 lb'; found_by_term='boneless skinless chicken breast'; as_of=$d0 }
      )
      @{ store='Aldi'; price_type='everyday'; deals=$prev2 } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $T2 "aldi-regular-$d1.json") -Encoding UTF8
      @{ store='Aldi'; price_type='everyday'; deals=$new2 }  | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $T2 "aldi-regular-$d0.json") -Encoding UTF8
      $null = Invoke-CarryForward 'aldi' $T2 14
      $o3 = Get-Content (Join-Path $T2 "aldi-regular-$d0.json") -Raw | ConvertFrom-Json
      $names = @($o3.deals | ForEach-Object { [string]$_.item })
      if ($names -notcontains 'Kirkwood Chicken Breast Fillets Family Pack') {
        Write-Output 'ok    MUST-FIRE: a product whose term was re-searched and did not return is RETIRED, not carried'
      } else { Write-Output 'FAIL  the out-of-stock product was carried again - the founding bug is back'; $fail++ }
      if ($names -contains 'Friendly Farms Whole Milk') {
        Write-Output 'ok    CLEAN TWIN: a product whose term was NOT searched this pull still carries'
      } else { Write-Output 'FAIL  retirement over-reached and dropped an untouched term'; $fail++ }

      # A BLOCKED TERM MUST NOT DELETE THE CATALOGUE. If today's pull yielded NO rows for a term
      # (a wall, a 403), that term is not "covered" and its products must survive untouched.
      $T3 = Join-Path $env:TEMP ('cf-wall-' + [guid]::NewGuid().ToString('N').Substring(0,8))
      New-Item -ItemType Directory -Path $T3 -Force | Out-Null
      try {
        @{ store='Aldi'; price_type='everyday'; deals=$prev2 } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $T3 "aldi-regular-$d1.json") -Encoding UTF8
        @{ store='Aldi'; price_type='everyday'; deals=@(@{ store='Aldi'; item='Something Else'; ad_price='$1.00'; size='1 ct'; found_by_term='unrelated term'; as_of=$d0 }) } |
          ConvertTo-Json -Depth 5 | Set-Content (Join-Path $T3 "aldi-regular-$d0.json") -Encoding UTF8
        $null = Invoke-CarryForward 'aldi' $T3 14
        $o4 = Get-Content (Join-Path $T3 "aldi-regular-$d0.json") -Raw | ConvertFrom-Json
        $n4 = @($o4.deals | ForEach-Object { [string]$_.item })
        if (($n4 -contains 'Kirkwood Chicken Breast Fillets Family Pack') -and ($n4 -contains 'Friendly Farms Whole Milk')) {
          Write-Output 'ok    a term that returned NOTHING is not "covered" - a wall cannot retire the catalogue'
        } else { Write-Output 'FAIL  a zero-row term retired products - a bot wall would delete the store'; $fail++ }
      } finally { Remove-Item $T3 -Recurse -Force -ErrorAction SilentlyContinue }
    } finally { Remove-Item $T2 -Recurse -Force -ErrorAction SilentlyContinue }
  } finally { Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue }
  if ($fail -eq 0) { Write-Output 'SELF-TEST PASS'; exit 0 } else { Write-Output "SELF-TEST FAIL: $fail case(s)"; exit 1 }
}

Write-Output (Invoke-CarryForward $Store $regDir $MaxCarryDays)
