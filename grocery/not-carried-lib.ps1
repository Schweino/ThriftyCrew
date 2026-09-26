<#
  not-carried-lib.ps1 - the ONE reading of grocery\not-carried.json, and the ONE rule for what may be written there.

  THE DEFECT THIS EXISTS FOR (backlog I221, 2026-09-18). build-deals-page read the file as a `cells` list keyed
  `.id`, but the file holds an `entries` list keyed `.commodity`, so no "Doesn't carry" label ever rendered and
  every such cell read "No price yet". A reader and a writer that each spell a file's shape for themselves drift
  apart silently; both now call this file.

  THE SECOND DEFECT, WHICH IS WHY THE FIRST WAS NOT SIMPLY SWITCHED ON. derive-not-carried wrote an entry from ONE
  search: one Baker's query that came back empty, or came back with rows our matcher rejected. A poor search term
  looks identical to an absent product from here ('pork tenderloin whole boneless' at a Kroger store), and
  .claude\rules\grocery.md says it plainly: UNCHECKED IS NEVER NOT-CARRIED. search-verdict-lib.ps1's header has
  the measured case - four of ten terms in the 2026-08-15 trial would have been mis-ruled on their first query,
  and a second, differently worded query found the product every time. So:

    AN ENTRY IS TRUSTED ONLY WHEN
      - its verdict is 'not-carried', and
      - it is inside recheck_days of its `checked` date (the same expiry audit-coverage-gaps enforces), and
      - it is basis='declared' (a human looked), OR it is basis='derived' and carries AT LEAST TWO searches whose
        WORDING differs (Get-TcNotCarriedSearchKey: case, punctuation, word order and a plural 's' do not count
        as a different wording), every one of which came back empty or with no matching row.

  derive-not-carried REFUSES to write an entry that fails this, and SAYS SO with a count; build-deals-page shows
  "Doesn't carry" only for an entry that passes it. The same function decides both, so the page can never show
  a label the writer would refuse to write.

  A PRICE BEATS AN ENTRY. A store that holds a price on the row today is shown with that price, whatever an
  entry says - a price is a direct observation that the store sells something under this commodity, and a wrong
  product is known-wrong.json's job, not this file's. Get-TcNotCarriedStores takes the priced stores for that.

  SCOPE OF A CLEAN REPORT: this reads one file's shape and applies one rule. It cannot tell whether a store truly
  stocks an item; it can only refuse to believe one search.

  THE SWITCH IS -NotCarriedLibSelfTest, NOT -SelfTest: dot-sourcing runs this param() block in the caller's scope,
  and a lib declaring [switch]$SelfTest resets the caller's own (search-verdict-lib.ps1's header has the account).
#>
# The self-test runs temp fixtures and reads build-deals-page.ps1 and derive-not-carried.ps1 as text.
# gate-inputs: lib\json-io.ps1
# gate-inputs-text: grocery\build-deals-page.ps1, grocery\derive-not-carried.ps1
param([switch]$NotCarriedLibSelfTest)

$script:NC_OK_OUTCOMES = @('empty', 'success')

# One wording, however it is spelled: lower-case, punctuation to spaces, a trailing plural 's' dropped from words
# longer than three letters, words sorted and de-duplicated. 'Caraway Seeds' and 'caraway seed' are ONE wording;
# 'pork tenderloin whole boneless' and 'pork tenderloin' are two.
function Get-TcNotCarriedSearchKey([string]$Term) {
  $w = @((([string]$Term).ToLowerInvariant() -replace '[^a-z0-9]+', ' ').Trim() -split ' ' | Where-Object { $_ } |
         ForEach-Object { if ($_.Length -gt 3 -and $_.EndsWith('s') -and -not $_.EndsWith('ss')) { $_.Substring(0, $_.Length - 1) } else { $_ } } |
         Sort-Object -Unique)
  return ($w -join ' ')
}

# The searches an entry rests on. An entry written before `searches` existed carries one search, recorded in its
# evidence text ("searched '<term>': ...") and its outcome/row_count fields, and it is read as exactly that one.
function Get-TcNotCarriedSearches($Entry) {
  $out = New-Object System.Collections.ArrayList
  if ($null -eq $Entry) { return ,$out.ToArray() }
  if ($Entry.PSObject.Properties.Name -contains 'searches') {
    foreach ($s in @(@($Entry.searches) | Where-Object { $_ })) {
      [void]$out.Add([pscustomobject]@{ term = [string]$s.term; outcome = [string]$s.outcome; row_count = [int]$s.row_count })
    }
    return ,$out.ToArray()
  }
  $ev = if ($Entry.PSObject.Properties.Name -contains 'evidence') { [string]$Entry.evidence } else { '' }
  $m = [regex]::Match($ev, "searched '([^']+)'")
  if ($m.Success) {
    $oc = if ($Entry.PSObject.Properties.Name -contains 'outcome') { [string]$Entry.outcome } else { '' }
    $rc = if ($Entry.PSObject.Properties.Name -contains 'row_count') { [int]$Entry.row_count } else { 0 }
    [void]$out.Add([pscustomobject]@{ term = $m.Groups[1].Value; outcome = $oc; row_count = $rc })
  }
  return ,$out.ToArray()
}

# How many DIFFERENT wordings came back with nothing we could match. A search that errored, was throttled or was
# never asked is not evidence and does not count.
function Get-TcNotCarriedWordingCount($Searches) {
  $keys = @{}
  foreach ($s in @($Searches)) {
    if ($null -eq $s) { continue }
    if ($script:NC_OK_OUTCOMES -notcontains [string]$s.outcome) { continue }
    $k = Get-TcNotCarriedSearchKey ([string]$s.term)
    if ($k) { $keys[$k] = $true }
  }
  return $keys.Count
}

# The rule. Returns { Ok; Reason } where Reason is one of: trusted-declared, trusted-derived, not-a-not-carried-verdict,
# undated, expired, single-search, no-search, unknown-basis.
function Test-TcNotCarriedEntry($Entry, [datetime]$Today, [int]$RecheckDays = 90) {
  if ($null -eq $Entry) { return [pscustomobject]@{ Ok = $false; Reason = 'no-search' } }
  $verdict = if ($Entry.PSObject.Properties.Name -contains 'verdict') { [string]$Entry.verdict } else { 'not-carried' }
  if ($verdict -ne 'not-carried') { return [pscustomobject]@{ Ok = $false; Reason = 'not-a-not-carried-verdict' } }
  $checked = $null
  try { $checked = [datetime]::ParseExact([string]$Entry.checked, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) } catch { }
  if ($null -eq $checked) { return [pscustomobject]@{ Ok = $false; Reason = 'undated' } }
  if (($Today.Date - $checked.Date).TotalDays -gt $RecheckDays) { return [pscustomobject]@{ Ok = $false; Reason = 'expired' } }
  $basis = [string]$Entry.basis
  if ($basis -eq 'declared') { return [pscustomobject]@{ Ok = $true; Reason = 'trusted-declared' } }
  if ($basis -ne 'derived') { return [pscustomobject]@{ Ok = $false; Reason = 'unknown-basis' } }
  $n = Get-TcNotCarriedWordingCount (Get-TcNotCarriedSearches $Entry)
  if ($n -ge 2) { return [pscustomobject]@{ Ok = $true; Reason = 'trusted-derived' } }
  if ($n -eq 1) { return [pscustomobject]@{ Ok = $false; Reason = 'single-search' } }
  return [pscustomobject]@{ Ok = $false; Reason = 'no-search' }
}

# Read the file into commodity -> store -> $true, trusted entries only, with the count of what was left out and
# why, so a caller can print "shown 0 of 24" rather than a silent nothing.
function Read-TcNotCarriedMap([string]$Path, [datetime]$Today = (Get-Date)) {
  $res = [pscustomobject]@{ Map = @{}; Read = 0; Shown = 0; Refused = [ordered]@{}; RecheckDays = 90; Found = $false }
  if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $res }
  $res.Found = $true
  $doc = Read-JsonFile $Path
  if ($doc.PSObject.Properties.Name -contains 'recheck_days') { $res.RecheckDays = [int]$doc.recheck_days }
  foreach ($e in @(@($doc.entries) | Where-Object { $_ })) {
    $res.Read++
    $t = Test-TcNotCarriedEntry $e $Today $res.RecheckDays
    if (-not $t.Ok) {
      if (-not $res.Refused.Contains($t.Reason)) { $res.Refused[$t.Reason] = 0 }
      $res.Refused[$t.Reason]++
      continue
    }
    $id = [string]$e.commodity; $st = [string]$e.store
    if (-not $id -or -not $st) { continue }
    if (-not $res.Map.ContainsKey($id)) { $res.Map[$id] = @{} }
    if (-not $res.Map[$id].ContainsKey($st)) { $res.Map[$id][$st] = $true; $res.Shown++ }
  }
  return $res
}

# The stores to label "Doesn't carry" on one row: trusted entries for this commodity, minus every store that holds
# a price on the row (a price beats an entry). Sorted, so the page is stable.
function Get-TcNotCarriedStores($Map, [string]$Id, $PricedStores) {
  # Returns the stores down the pipeline, NOT comma-wrapped: callers write @(Get-TcNotCarriedStores ...), and a
  # comma-returned array inside @() reads as ONE element (.claude\rules\ops-and-gates.md). Empty returns nothing.
  if ($null -eq $Map -or -not $Map.ContainsKey($Id)) { return }
  $have = @{}; foreach ($p in @($PricedStores)) { if ($p) { $have[[string]$p] = $true } }
  $Map[$Id].Keys | Where-Object { -not $have.ContainsKey([string]$_) } | Sort-Object
}

# derive-not-carried's side of the rule: turn one (commodity, store)'s searches into an entry, or refuse. The refusal
# carries the reason so the caller can count it; nothing is written for a refused candidate.
function New-TcNotCarriedEntry([string]$Commodity, [string]$Store, $Searches, [string]$Source, [string]$Checked) {
  # One search per WORDING, the last one given (callers pass them oldest first), so thirteen daily re-asks of
  # one term stay one search and cannot pose as thirteen.
  $byKey = [ordered]@{}
  foreach ($s in @($Searches)) {
    if ($null -eq $s -or ($script:NC_OK_OUTCOMES -notcontains [string]$s.outcome)) { continue }
    $k = Get-TcNotCarriedSearchKey ([string]$s.term)
    if (-not $k) { continue }
    if ($byKey.Contains($k)) { $byKey.Remove($k) }
    $byKey[$k] = $s
  }
  $ok = @($byKey.Values)
  $n = Get-TcNotCarriedWordingCount $ok
  if ($n -lt 2) {
    $why = if ($n -eq 1) { 'single-search' } else { 'no-search' }
    return [pscustomobject]@{ Entry = $null; Refused = $why }
  }
  $parts = @($ok | ForEach-Object { "'" + [string]$_.term + "' -> " + $(if ([string]$_.outcome -eq 'empty') { 'no rows' } else { [string]$_.row_count + ' row(s), none matched' }) })
  $e = [ordered]@{
    commodity = $Commodity; store = $Store; basis = 'derived'; verdict = 'not-carried'
    evidence  = ('searched ' + $n + ' different wordings and none found this commodity: ' + ($parts -join '; '))
    searches  = @($ok | ForEach-Object { [ordered]@{ term = [string]$_.term; outcome = [string]$_.outcome; row_count = [int]$_.row_count; source = [string]$_.source } })
    source    = $Source; checked = $Checked
  }
  return [pscustomobject]@{ Entry = $e; Refused = '' }
}

if ($NotCarriedLibSelfTest) {
  $ErrorActionPreference = 'Stop'
  . (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')
  $pass = 0; $fail = 0
  function NcCase([string]$Name, [scriptblock]$Body) {
    $ok = $false
    try { $ok = [bool](& $Body) } catch { Write-Output ("  threw: " + $_.Exception.Message) }
    if ($ok) { $script:pass++; Write-Output ("  ok    " + $Name) } else { $script:fail++; Write-Output ("  FAIL  " + $Name) }
  }
  $today = [datetime]'2026-09-18'
  $dir = Join-Path ([IO.Path]::GetTempPath()) ('nclib-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
  New-Item -ItemType Directory -Path $dir -ErrorAction Stop | Out-Null
  try {
    # The file's REAL shape: an `entries` list keyed `.commodity`, exactly as derive-not-carried writes it.
    $two = '[{"term":"pork tenderloin whole boneless","outcome":"empty","row_count":0},{"term":"pork tenderloin","outcome":"success","row_count":3}]'
    $real = '{"recheck_days":90,"entries":[' +
      '{"commodity":"pork-tenderloin","store":"Baker''s","basis":"derived","verdict":"not-carried","searches":' + $two + ',"checked":"2026-09-10"},' +
      '{"commodity":"achiote-paste","store":"Baker''s","basis":"derived","verdict":"not-carried","evidence":"searched ''achiote paste'': the store''s own search returned no rows at all.","outcome":"empty","row_count":0,"checked":"2026-08-21"},' +
      '{"commodity":"fennel","store":"Aldi","basis":"declared","verdict":"not-carried","evidence":"looked on the shelf","checked":"2026-09-01"},' +
      '{"commodity":"jicama","store":"Hy-Vee","basis":"declared","verdict":"not-carried","evidence":"old","checked":"2026-05-01"}' +
      ']}'
    $f = Join-Path $dir 'not-carried.json'
    [IO.File]::WriteAllText($f, $real, (New-Object Text.UTF8Encoding($false)))
    $m = Read-TcNotCarriedMap $f $today

    NcCase 'MUST FIRE  the real file shape (entries keyed .commodity) yields "Doesn''t carry" for a trusted two-search entry at that store (the I221 reader bug)' {
      (@(Get-TcNotCarriedStores $m.Map 'pork-tenderloin' @('Walmart', 'Hy-Vee')) -join ',') -eq "Baker's"
    }
    NcCase 'CLEAN TWIN a store that holds a PRICE on the row keeps its price: the same entry names no store once Baker''s is priced' {
      $s = @(Get-TcNotCarriedStores $m.Map 'pork-tenderloin' @("Baker's", 'Walmart'))
      ($s.Count -eq 0) -and ((@(Get-TcNotCarriedStores $m.Map 'pork-tenderloin' @('Walmart')) -join ',') -eq "Baker's")
    }
    NcCase 'CLEAN TWIN a declared (human-checked) entry inside recheck_days is shown' {
      (@(Get-TcNotCarriedStores $m.Map 'fennel' @()) -join ',') -eq 'Aldi'
    }
    NcCase 'MUST FIRE  a derived entry resting on ONE search is refused and counted, never shown (the 2026-08-21 shape)' {
      (@(Get-TcNotCarriedStores $m.Map 'achiote-paste' @()).Count -eq 0) -and ($m.Refused['single-search'] -eq 1)
    }
    NcCase 'MUST FIRE  an entry past recheck_days is refused as expired' {
      (@(Get-TcNotCarriedStores $m.Map 'jicama' @()).Count -eq 0) -and ($m.Refused['expired'] -eq 1)
    }
    NcCase 'CLEAN TWIN the counts add up: read 4 = shown 2 + refused 2' {
      ($m.Read -eq 4) -and ($m.Shown -eq 2) -and ((($m.Refused.Values | Measure-Object -Sum).Sum) -eq 2)
    }
    NcCase 'MUST FIRE  the retired `cells`/.id shape reads as nothing, so a regression to it cannot pass as the real file' {
      $old = Join-Path $dir 'cells.json'
      [IO.File]::WriteAllText($old, '{"cells":[{"id":"pork-tenderloin","store":"Baker''s"}]}', (New-Object Text.UTF8Encoding($false)))
      $o = Read-TcNotCarriedMap $old $today
      ($o.Read -eq 0) -and ($o.Map.Count -eq 0)
    }
    NcCase 'MUST FIRE  two searches that differ only by case, plural or word order are ONE wording and refused' {
      $s = @([pscustomobject]@{ term = 'Caraway Seeds'; outcome = 'empty'; row_count = 0 }, [pscustomobject]@{ term = 'seed, caraway'; outcome = 'empty'; row_count = 0 })
      $r = New-TcNotCarriedEntry 'caraway-seeds' "Baker's" $s 'x.json' '2026-09-18'
      ($null -eq $r.Entry) -and ($r.Refused -eq 'single-search')
    }
    NcCase 'MUST FIRE  a search that errored or was never asked is not evidence: one real wording plus one rejected is refused' {
      $s = @([pscustomobject]@{ term = 'harissa'; outcome = 'empty'; row_count = 0 }, [pscustomobject]@{ term = 'harissa paste'; outcome = 'rejected'; row_count = 0 })
      $r = New-TcNotCarriedEntry 'harissa-paste' "Baker's" $s 'x.json' '2026-09-18'
      ($null -eq $r.Entry) -and ($r.Refused -eq 'single-search')
    }
    NcCase 'CLEAN TWIN two genuinely different wordings write an entry that carries both searches and passes the reader''s own rule' {
      $s = @([pscustomobject]@{ term = 'pork tenderloin whole boneless'; outcome = 'empty'; row_count = 0; source = 'a.json' }, [pscustomobject]@{ term = 'pork tenderloin'; outcome = 'success'; row_count = 3; source = 'b.json' })
      $r = New-TcNotCarriedEntry 'pork-tenderloin' "Baker's" $s 'b.json' '2026-09-18'
      $e = [pscustomobject]$r.Entry
      $back = ($e | ConvertTo-Json -Depth 6 | ConvertFrom-Json)
      ($r.Refused -eq '') -and (@($back.searches).Count -eq 2) -and ((Test-TcNotCarriedEntry $back $today 90).Ok)
    }
    # WIRING. The rule above guards nothing unless the page reads the file through it. Needles are built by
    # concatenation so this case can never be satisfied by its own source text.
    NcCase 'CLEAN TWIN build-deals-page reads not-carried.json through Read-TcNotCarriedMap and no longer reads a `cells` list' {
      $src = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'build-deals-page.ps1'))
      $callsLib = $src.Contains('Read-TcNotCarried' + 'Map') -and $src.Contains('not-carried' + '-lib.ps1')
      $oldRead = $src.Contains('$ncd' + '.cells')
      $callsLib -and -not $oldRead
    }
    NcCase 'CLEAN TWIN derive-not-carried builds its entries through New-TcNotCarriedEntry' {
      $src = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'derive-not-carried.ps1'))
      $src.Contains('New-TcNotCarried' + 'Entry') -and $src.Contains('not-carried' + '-lib.ps1')
    }
  } finally {
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
  }
  $total = $pass + $fail
  if ($total -ne 12) { Write-Output ("  FAIL  expected 12 cases to run, ran " + $total); $fail++ }
  if ($fail -eq 0) { Write-Output ("not-carried-lib SELF-TEST PASS ({0} of {0} cases)" -f $pass); exit 0 }
  Write-Output ("not-carried-lib SELF-TEST FAIL ({0} of {1} cases failed)" -f $fail, ($pass + $fail)); exit 1
}
