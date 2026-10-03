
# ---------------------------------------------------------------- publish-deals-page CHANGE GATE
# The MUST-FIRE / CLEAN-TWIN pair lives in that script's own -SelfTest (frozen synthetic signatures, never
# regenerated from the live board). Founding bug 2026-07-29: 13 invocations pushed the SAME week's board to
# Ghost 12 times. Run it daily so a DEAD short-circuit (every run upserts again) and, far worse, a
# short-circuit that started skipping REAL changes (a price move that never ships) both surface here.
# READ THE SOURCE BEFORE INVOKING IT. publish-deals-page is a SIMPLE script (no [CmdletBinding()]), so an
# unknown -SelfTest does NOT error: PowerShell drops the string into $args and the script runs its normal
# path - measured - and the admin key resolves from meal-prep\.ghostkey, so a publish-deals-page that lost
# its -SelfTest handler would make this daily fixture suite perform a REAL Ghost publish. Prove the hermetic
# handler exists AND sits ahead of the first live step (the admin-key resolution) before running it; if it
# does not, fail loudly and invoke nothing.
if (Use-Unit 'u074-publish-deals-page-change-gate') {
$pdpSelfIdx = $pdpSrc.IndexOf('if ($SelfTest) {')
$pdpKeyIdx  = $pdpSrc.IndexOf('Ghost admin key missing')
if (($pdpSrc -notmatch '\[switch\]\$SelfTest') -or $pdpSelfIdx -lt 0 -or $pdpKeyIdx -lt 0 -or $pdpSelfIdx -gt $pdpKeyIdx) {
  Bad 'publish-deals-page has no hermetic -SelfTest handler ahead of its admin-key step - the change-gate fixture could not be run, and must NOT be invoked (an unknown -SelfTest lands in $args and the script performs a REAL publish)'
} else {
  $r = RunPS 'publish-deals-page.ps1' @('-SelfTest')
  if ($r.rc -eq 0 -and $r.text -match 'SELFTEST PASS') { Ok 'publish-deals-page change gate still skips an unchanged board and still publishes a one-byte change' }
  else { Bad ('publish-deals-page -SelfTest failed or lost its change-gate fixture: ' + ((($r.text -split "`n") | Select-Object -Last 3) -join ' | ')) }
}
# ...and the two callers that must understand a skip (source asserts - house precedent for caller plumbing).
$prtSrc = Get-Content (Join-Path $root 'publish-retry-until-live.ps1') -Raw
if ($prtSrc -match 'CURRENT omaha-grocery-prices') { Ok 'publish-retry-until-live counts a short-circuited (CURRENT) board as success, so the retry task can still delete itself' }
else { Bad 'publish-retry-until-live accepts only PUBLISHED - against the change gate it would retry every 20 min forever on a board that is already live' }
if ($pdpSrc -match 'guide unchanged') { Ok 'publish-deals-page tells a store-guide upsert apart from a store-guide skip' }
else { Bad 'publish-deals-page prints "store guide republished" on any rc=0 again - publish-store-guide also exits 0 when it skips, which is how the 07-29 audit counted 12 phantom guide upserts' }
} # u074-publish-deals-page-change-gate

# ---------------------------------------------------------------- N+6. no script may sign another script's name
# 2026-07-30: build-walmart-deals.ps1 is a fork of build-sams-deals.ps1 (capture-lib.ps1:14-19) and inherited
# that name in EVERY operator-facing string. A real pull printed "build-sams-deals: 4626 raw -> 3444 priced ->
# walmart-regular-2026-07-29.json", and a missing -In threw "build-sams-deals: -In not found", which sends the
# operator to the wrong script AND the wrong capture file. Line 2 of that header was hand-corrected once on
# 2026-07-26 and the usage block two lines below it was missed - a hand fix does not close a copy-paste class.
# The check reads BOTH the dictionary of script names and each file's own name off the filesystem, so there is
# no hard-coded text that could pass by going stale. A script legitimately labels output from a child it RUNS
# (check-ad-cycles logs 'prune-bad-links: ...'), so a name is only a lie when the file does not ALSO carry that
# .ps1 as a bare path string. Measured on the live tree 2026-07-30: 3 findings, all real, and all 4 delegating
# sites (check-ad-cycles x3, run-daily-local) stay silent - dropping the bare-path exemption raises the count
# from 3 to 7, which is how we know that clause is load-bearing and not dead. Comments are not scanned, so
# honest provenance notes ("ported from build-sams-deals") never cry wolf. Costs ~1.0s over 138 scripts.
# NOT extended to STORE nouns on purpose: that variant was built and measured at 3 false positives out of 5
# (audit-walmart-fullpull is deliberately dual-store, audit-ff-missing-products holds a store list, and
# import-walmart-batch's Member's Mark name is inside a frozen fixture) - 60% cry-wolf, so it stays out.
function Get-MisnamedEmitters([string]$scanDir) {
  $own = @{}
  foreach ($p in (Get-ChildItem (Join-Path $scanDir '*.ps1') -File -EA SilentlyContinue)) { $own[$p.BaseName.ToLower()] = $true }
  $hits = New-Object System.Collections.ArrayList
  foreach ($p in (Get-ChildItem (Join-Path $scanDir '*.ps1') -File -EA SilentlyContinue)) {
    # ((Get-Content -Raw) + '') - [string]$null is $null, so .Trim() on a zero-byte script would throw
    $src = ((Get-Content $p.FullName -Raw) + '')
    if (-not $src.Trim()) { continue }
    $perr = $null
    $toks = @([System.Management.Automation.PSParser]::Tokenize($src, [ref]$perr) | Where-Object { $_.Type -eq 'String' })
    # every script this file POINTS AT: a string token that is nothing but a .ps1 path
    $points = @{}
    foreach ($t in $toks) {
      $c = ([string]$t.Content).Trim()
      # A STRING ENDING IN .ps1 IS NOT NECESSARILY A PATH. grocery\cutover-feed-url.ps1 holds a REGEX whose
      # tail is 'cutover-feed-url\.ps1' - pipes and backslashes and all - and GetFileNameWithoutExtension
      # throws "Illegal characters in path" on it, which killed this whole auditor mid-run: 176 lines in,
      # rc=1, and NOT ONE line saying FAIL. A watcher that dies silently is worse than one that reports,
      # so reject anything carrying a character a path cannot hold before asking .NET to parse it.
      if ($c -match '\.ps1$' -and $c -notmatch '[\s:]' -and ($c.IndexOfAny([IO.Path]::GetInvalidPathChars()) -lt 0) -and $c -notmatch '[*?|]') {
        $points[([IO.Path]::GetFileNameWithoutExtension($c)).ToLower()] = $true
      }
    }
    $me = $p.BaseName.ToLower()
    foreach ($t in $toks) {
      $m = [regex]::Match(([string]$t.Content), '^\s*\[?([A-Za-z][A-Za-z0-9]*(?:-[A-Za-z0-9]+)+)(?:\.ps1)?\s*(?::|\])')
      if (-not $m.Success) { continue }
      $said = $m.Groups[1].Value.ToLower()
      if ($said -eq $me -or -not $own.ContainsKey($said) -or $points.ContainsKey($said)) { continue }
      $null = $hits.Add(("{0}:{1} signs '{2}'" -f $p.Name, $t.StartLine, $said))
    }
  }
  return @($hits.ToArray())
}
# MUST FIRE + CLEAN TWIN. Synthetic on purpose - three throwaway scripts, never derived from live source, so
# the bug they encode cannot evaporate the way a regenerated fixture does. The honest twin carries BOTH silence
# conditions at once (it signs its own name AND labels a child it really invokes), which is the exact shape of
# the legitimate sites in the estate.
if (Use-Unit 'u075-n-6-no-script-may-sign-another' -Reads 'grocery/*.ps1') {
$fxSg = Register-Fx (Join-Path $env:TEMP ('ta-signs-' + [guid]::NewGuid().ToString('N').Substring(0,8)))
New-Item -ItemType Directory -Path $fxSg -Force | Out-Null
Set-Content (Join-Path $fxSg 'fx-sams-twin.ps1') "Write-Output 'fx-sams-twin: 1 raw -> 1 priced'" -Encoding UTF8
Set-Content (Join-Path $fxSg 'fx-forked-builder.ps1') @'
if (-not $In) { throw "fx-sams-twin: -In not found: $In" }
Write-Output ("fx-sams-twin: {0} raw -> {1} priced" -f 4626, 3444)
'@ -Encoding UTF8
Set-Content (Join-Path $fxSg 'fx-honest-builder.ps1') @'
$out = & powershell -File (Join-Path $root 'fx-sams-twin.ps1')
Write-Output ('fx-sams-twin: ' + $out)
Write-Output ("fx-honest-builder: {0} raw -> {1} priced" -f 4626, 3444)
'@ -Encoding UTF8
$sg = @(Get-MisnamedEmitters $fxSg)
if ((@($sg | Where-Object { $_ -like 'fx-forked-builder.ps1:*' }).Count -eq 2) -and (@($sg | Where-Object { $_ -like 'fx-honest-builder.ps1:*' }).Count -eq 0)) {
  Ok 'signs-its-own-name FIRES on the forked builder and stays silent on the honest twin (self-label + labelling a child it runs)'
} else { Bad ('signs-its-own-name fixture wrong - the checker cannot see its founding bug: ' + ($sg -join ' | ')) }
Remove-Item $fxSg -Recurse -Force -ErrorAction SilentlyContinue
$sgLive = @(Get-MisnamedEmitters $root)
if ($sgLive.Count -eq 0) { Ok 'no grocery script signs another script''s name (the build-walmart-deals/build-sams-deals fork class)' }
else { Bad ('a script emits under another script''s name - a failure sends the operator to the wrong script and the wrong capture file: ' + ($sgLive -join '; ')) }
} # u075-n-6-no-script-may-sign-another

# ---------------------------------------------------------------- N+9. the match-soundness sweep cache
# audit-match-soundness re-derived its whole name->commodity sweep on every invocation: 51.5s of a 53.0s run,
# ~75% of every publish, and it ran 15 times on 2026-07-29 (14 publish-deals-page invocations in
# out\logs\weekly-post-capture-2026-07.log plus the daily check-ad-cycles call) on inputs that mostly had not
# changed. It now stamps a SHA1 of its closed input set next to match-baseline.json and reuses the sweep.
# A cache is a gate that must arm: if the stamp ever matches when an input HAS changed, this audit silently
# reports last run's answer, and it is the gate that decides whether the publish HOLDs.
# The fixture never re-implements the hash - it takes the fingerprint the script itself wrote and corrupts
# only the ANSWER under it, so "the cache was consulted" and "the cache was rejected" are visible in stdout.
if (Use-Unit 'u076-n-9-the-match-soundness-sweep-cache') {
$fxMs = NewFxDir 'ms-cache'
New-Item -ItemType Directory -Force (Join-Path $fxMs 'out\audit') | Out-Null
New-Item -ItemType Directory -Force (Join-Path $fxMs 'out\regular') | Out-Null
# The script and every sibling it dot-sources (verdict-lib, alert-lib, match-worklist-lib, soundness-publish-lib,
# cell-quarantine-lib since 2026-10-01 3851d2, ...), derived from its source by Copy-FxWithDeps (sandbox.ps1), not
# a hand-kept list. global-exclude-lib.ps1 and compare-deals.ps1 are stubbed below, after the copy.
$msCopied = Copy-FxWithDeps $root 'audit-match-soundness.ps1' $fxMs
foreach ($msNeed in @('soundness-publish-lib.ps1', 'cell-quarantine-lib.ps1', 'verdict-lib.ps1')) {
  if ($msCopied -notcontains $msNeed) { Bad ('u076 sandbox: Copy-FxWithDeps did not carry ' + $msNeed + ' - the dependency walk is broken (got: ' + ($msCopied -join ', ') + ')') }
}
Set-Content (Join-Path $fxMs 'commodities.json') '[{"id":"lemons","include":["lemon"],"exclude":[]},{"id":"limes","include":["lime"],"exclude":[]}]' -Encoding UTF8
# The fixture's exclude list is a LIBRARY now (backlog I82), not an array literal inside a stub engine.
# compare-deals.ps1 stays here because it is still part of the cache fingerprint below; it just no
# longer carries the list, so a fixture that forgot to update would go BLIND loudly rather than quietly.
Set-Content (Join-Path $fxMs 'global-exclude-lib.ps1') "function Get-TcGlobalExclude { @(`n  'scented candle'`n) }`n" -Encoding UTF8
Set-Content (Join-Path $fxMs 'compare-deals.ps1') "# fixture engine stub`n" -Encoding UTF8
Set-Content (Join-Path $fxMs 'out\regular\hyvee-regular-2026-01-01.json') '{"deals":[{"item":"Fresh Lemon 1 ct"},{"item":"Fresh Lime 1 ct"}]}' -Encoding UTF8
$msBaseJson = '{"generated":"2026-01-01 00:00","names":{"Fresh Lemon 1 ct":"lemons","Fresh Lime 1 ct":"limes"},"contested":[]}'
Set-Content (Join-Path $fxMs 'out\audit\match-baseline.json') $msBaseJson -Encoding UTF8
$msCache = Join-Path $fxMs 'out\audit\match-sweep-cache.json'
} # u076-n-9-the-match-soundness-sweep-cache
function MsPoison() {
  $cj = ConvertFrom-Json ([IO.File]::ReadAllText($script:msCache))
  $nk = @($cj.names_k); $nv = @($cj.names_v)
  $pv = New-Object System.Collections.Generic.List[string]
  for ($i = 0; $i -lt $nk.Count; $i++) { if ([string]$nk[$i] -eq 'Fresh Lemon 1 ct') { [void]$pv.Add('limes') } else { [void]$pv.Add([string]$nv[$i]) } }
  Set-Content $script:msCache -Value ([ordered]@{ fp = [string]$cj.fp; count = [int]$cj.count; names_k = $nk; names_v = $pv.ToArray(); contest_k = @($cj.contest_k); contest_v = @($cj.contest_v) } | ConvertTo-Json -Depth 4 -Compress) -Encoding UTF8
}
if (Use-Unit 'u076-n-9-the-match-soundness-sweep-cache') {
$r = RunPSAt $fxMs 'audit-match-soundness.ps1' @()
if ($r.rc -eq 0 -and $r.text -match 'MOVED=0  DROPPED=0') { Ok 'match-soundness cold run agrees with its frozen baseline' }
else { Bad ('match-soundness cold run did not match the frozen baseline (rc=' + $r.rc + '): ' + $r.text) }
if (-not (Test-Path $msCache)) { Bad 'no sweep cache was stamped - the input fingerprint is gone, so the 51s sweep reruns on every publish again' }
else {
  # CLEAN TWIN: byte-identical inputs must HIT (the poisoned answer is what surfaces).
  MsPoison
  $r = RunPSAt $fxMs 'audit-match-soundness.ps1' @()
  if ($r.rc -eq 2 -and $r.text -match 'MOVED    lemons -> limes') { Ok 'byte-identical inputs HIT the sweep cache' }
  else { Bad ('byte-identical inputs did NOT hit the sweep cache (rc=' + $r.rc + ') - the fingerprint never matches and the cache is dead weight: ' + $r.text) }
  # MUST FIRE: a one-byte, semantically NEUTRAL change to ANY input must MISS, so the true answer returns.
  foreach ($inp in @(
      @{ n = 'the script itself'; f = (Join-Path $fxMs 'audit-match-soundness.ps1'); add = "`n# fixture byte`n" },
      @{ n = 'commodities.json';  f = (Join-Path $fxMs 'commodities.json');          add = ' ' },
      @{ n = 'compare-deals.ps1'; f = (Join-Path $fxMs 'compare-deals.ps1');         add = "`n# fixture byte`n" },
      @{ n = 'global-exclude-lib.ps1'; f = (Join-Path $fxMs 'global-exclude-lib.ps1'); add = "`n# fixture byte`n" },
      @{ n = 'verdict-lib.ps1';   f = (Join-Path $fxMs 'verdict-lib.ps1');           add = "`n# fixture byte`n" },
      @{ n = 'a store feed file'; f = (Join-Path $fxMs 'out\regular\hyvee-regular-2026-01-01.json'); add = ' ' })) {
    $keep = [IO.File]::ReadAllBytes($inp.f)
    RunPSAt $fxMs 'audit-match-soundness.ps1' @() | Out-Null
    MsPoison
    [IO.File]::WriteAllText($inp.f, ([IO.File]::ReadAllText($inp.f) + $inp.add))
    $r = RunPSAt $fxMs 'audit-match-soundness.ps1' @()
    if ($r.rc -eq 0 -and $r.text -match 'MOVED=0  DROPPED=0') { Ok ('a one-byte change to ' + $inp.n + ' MISSES the sweep cache') }
    else { Bad ('a one-byte change to ' + $inp.n + ' still served the STALE sweep (rc=' + $r.rc + ') - that input is not in the fingerprint: ' + $r.text) }
    [IO.File]::WriteAllBytes($inp.f, $keep)
  }
  # -Accept snapshots $names into the baseline and everything in it goes invisible to this audit forever
  # after, so it must never read a cached sweep - nor write one.
  RunPSAt $fxMs 'audit-match-soundness.ps1' @() | Out-Null
  MsPoison
  $msCacheTicks = (Get-Item $msCache).LastWriteTime.Ticks
  $r = RunPSAt $fxMs 'audit-match-soundness.ps1' @('-Accept')
  $msNewBase = ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $fxMs 'out\audit\match-baseline.json')))
  if ($r.rc -eq 0 -and ([string]$msNewBase.names.'Fresh Lemon 1 ct') -eq 'lemons') { Ok '-Accept ignores the sweep cache and baselines a freshly swept truth' }
  else { Bad ('-Accept blessed a CACHED mapping into the permanent baseline (got ' + [string]$msNewBase.names.'Fresh Lemon 1 ct' + ') - a stale sweep is now invisible forever') }
  # (2026-10-03) BOTH TRACKED FILES THIS AUDIT WRITES ARE THE BYTES GIT STORES: the BOM their blobs carry, no CR, one
  # trailing LF. Set-Content wrote ConvertTo-Json's CRLF over the LF blobs, so every run left them ` M` with an empty
  # diff and a hand LF repair could drop the BOM. -Accept writes match-baseline.json and leaves through Exit-Guard
  # BEFORE the report, so soundness-report.json here is the plain run's, the one just before MsPoison above. The
  # baseline seed is Set-Content's CRLF, so a CRLF writer shows.
  foreach ($msTr in @(@('match-baseline.json', '-Accept'), @('soundness-report.json', 'the plain run'))) {
    $msTb = [IO.File]::ReadAllBytes((Join-Path $fxMs ('out\audit\' + $msTr[0])))
    $msTcr = 0; foreach ($msX in $msTb) { if ($msX -eq 13) { $msTcr++ } }
    $msTbom = ($msTb.Length -ge 3 -and $msTb[0] -eq 0xEF -and $msTb[1] -eq 0xBB -and $msTb[2] -eq 0xBF)
    if ($r.rc -eq 0 -and $msTcr -eq 0 -and $msTbom -and $msTb[-1] -eq 0x0A) { Ok ($msTr[1] + ' writes ' + $msTr[0] + ' LF with its BOM kept (CR count 0), so an unchanged run leaves git status clean') }
    else { Bad ($msTr[1] + ' wrote ' + $msTr[0] + ' with ' + $msTcr + ' CR byte(s), bom=' + $msTbom + ' (rc=' + $r.rc + ') - the tracked file reads modified with an empty diff') }
  }
  # 2026-09-22 (queue 2026-09-22-e9aed3): an accept names the commodities it released a product from and re-checks
  # their links. This copy has no deriver beside it, so the branch must SAY it skipped, never pass silently.
  if ($r.text -match 'link re-check( SKIPPED - derive-links-from-prices\.ps1 is not beside|: no commodity lost|: \d+ commodit\(ies\) released)') { Ok '-Accept reaches the released-commodity link re-check and states what it did' }
  else { Bad ('-Accept printed no link re-check line - the released-link trigger was never reached: ' + $r.text) }
  if ((Get-Item $msCache).LastWriteTime.Ticks -eq $msCacheTicks) { Ok '-Accept does not write the sweep cache either (write path skipped entirely)' }
  else { Bad '-Accept wrote the sweep cache - the write path is not skipped' }
  # An unusable stamp must fall through to the real sweep ('' | ConvertFrom-Json returns $null WITHOUT throwing).
  Set-Content (Join-Path $fxMs 'out\audit\match-baseline.json') $msBaseJson -Encoding UTF8
  foreach ($junk in @('', '   ', '{"fp":"deadbeef","count":2', '{"fp":"deadbeef","count":0,"names_k":[],"names_v":[],"contest_k":[],"contest_v":[]}')) {
    Set-Content $msCache -Value $junk -Encoding UTF8
    $r = RunPSAt $fxMs 'audit-match-soundness.ps1' @()
    if ($r.rc -eq 0 -and $r.text -match 'MOVED=0  DROPPED=0') { Ok ('an unusable sweep stamp (len ' + $junk.Length + ') falls through to the real sweep') }
    else { Bad ('an unusable sweep stamp (len ' + $junk.Length + ') changed the verdict (rc=' + $r.rc + '): ' + $r.text) }
  }
  # BLIND: zero ingested products must never be stamped, must not read as all-clear, and must not be
  # baselined (-Accept over an empty sweep erased 18,123 names -> 129 bytes and exited 0 on 2026-07-30).
  Remove-Item $msCache -Force -ErrorAction SilentlyContinue
  Remove-Item (Join-Path $fxMs 'out\regular\hyvee-regular-2026-01-01.json') -Force
  $msBaseSize = (Get-Item (Join-Path $fxMs 'out\audit\match-baseline.json')).Length
  $r = RunPSAt $fxMs 'audit-match-soundness.ps1' @()
  if ($r.rc -eq 3 -and $r.text -match 'BLIND') { Ok 'match-soundness reports BLIND (exit 3) when ZERO products were ingested' }
  else { Bad ('match-soundness returned rc=' + $r.rc + ' having ingested NOTHING - a zero-product run still reads as a clean board: ' + $r.text) }
  if (-not (Test-Path $msCache)) { Ok 'a sweep that read ZERO products is never stamped (cannot be replayed as all-clear)' }
  else { Bad 'an empty sweep was cached - "0 products, all clear" can now be served forever' }
  $r = RunPSAt $fxMs 'audit-match-soundness.ps1' @('-Accept')
  if ($r.rc -eq 3 -and (Get-Item (Join-Path $fxMs 'out\audit\match-baseline.json')).Length -eq $msBaseSize) { Ok '-Accept REFUSES an empty sweep (the reviewed baseline survives intact)' }
  else { Bad ('-Accept baselined an EMPTY sweep (rc=' + $r.rc + ', baseline now ' + (Get-Item (Join-Path $fxMs 'out\audit\match-baseline.json')).Length + ' bytes) - this audit is blinded permanently and the empty map is a TRACKED file') }
}
Remove-Item $fxMs -Recurse -Force -ErrorAction SilentlyContinue
} # u076-n-9-the-match-soundness-sweep-cache

# ---- (m) verdict IDENTITY: which item did the verdict judge? (the N+3 behavioural half) ----------------
# FOUNDING BUG (2026-08-16, queue 2026-08-07-79b768), frozen from the real 2026-08-15 verdict row and never
# regenerated from the live board: the garlic verdict judged 'Marketside Tandoori Style Garlic Naan Bites,
# 7.05 oz, 15 Count' while its reason quotes the bare flavour word 'Garlic'. The gate keyed off that quote,
# so it resolved the drop to Aldi's real Garlic ($1.69 / 3 ct = $0.5633/each) and refused -Accept naming an
# innocent product, under the verdict's store rather than the row's. verify-apply and purge-verdict-lows had
# both been reading the entry's own 'item' field since 2026-08-05; only this gate was still re-parsing prose,
# so the rule had three homes and the third one kept an expired premise.
# Both directions live here: it must block the NAAN, and it must NOT block Garlic. The legacy no-item-field
# entry is the third case, because hoisting identity to a field that older files do not have is exactly how a
# fix like this silently disarms every pre-2026-08-05 verdict.
if (Use-Unit 'u077-m-verdict-identity-which-item-did') {
$fxVi = NewFxDir 'verdict-identity'
New-Item -ItemType Directory -Force (Join-Path $fxVi 'out\audit') | Out-Null
New-Item -ItemType Directory -Force (Join-Path $fxVi 'out\regular') | Out-Null
$viCopied = Copy-FxWithDeps $root 'audit-match-soundness.ps1' $fxVi   # derived, not a hand-kept list (sandbox.ps1)
if ($viCopied -notcontains 'cell-quarantine-lib.ps1') { Bad ('u077 sandbox: Copy-FxWithDeps did not carry cell-quarantine-lib.ps1 (got: ' + ($viCopied -join ', ') + ')') }
Set-Content (Join-Path $fxVi 'commodities.json') '[{"id":"garlic","include":["garlic"],"exclude":[]},{"id":"pinto-beans","include":["pinto bean"],"exclude":[]}]' -Encoding UTF8
Set-Content (Join-Path $fxVi 'out\regular\hyvee-regular-2026-01-01.json') '{"deals":[{"item":"Marketside Tandoori Style Garlic Naan Bites, 7.05 oz, 15 Count"},{"item":"Garlic"},{"item":"Member''s Mark Pinto Beans 12 lbs."}]}' -Encoding UTF8
Set-Content (Join-Path $fxVi 'out\audit\match-baseline.json') '{"generated":"2026-01-01 00:00","names":{"Garlic":"garlic"},"contested":[]}' -Encoding UTF8
# The judged item is in the item field; the reason quotes a DIFFERENT real commodity. Frozen verbatim.
$viVerdict = '{"week_of":"2026-08-15","verdicts":[{"id":"garlic","entries":[{"store":"Walmart","keep":false,' +
  '"item":"Marketside Tandoori Style Garlic Naan Bites, 7.05 oz, 15 Count",' +
  '"reason":"NAAN bread bites, not fresh garlic bulbs - ''Garlic'' is a flavour descriptor. Held the cheapest garlic cell at $0.268/each."}]}]}'
# The pre-2026-08-05 shape: NO item field at all, identity recoverable only from the quote, apostrophe and all.
$viLegacy = '{"week_of":"2026-07-17","verdicts":[{"id":"pinto-beans","entries":[{"store":"Sam''s Club","keep":false,' +
  '"reason":"''Member''s Mark Pinto Beans 12 lbs.'' is a 12-lb bag of DRY pinto beans, not the canned commodity."}]}]}'
Set-Content (Join-Path $fxVi 'out\verify-verdicts-2026-07-17.json') $viLegacy -Encoding UTF8
Set-Content (Join-Path $fxVi 'out\verify-verdicts-2026-08-15.json') $viVerdict -Encoding UTF8
Set-Content (Join-Path $fxVi 'global-exclude-lib.ps1') "function Get-TcGlobalExclude { @(`n  'scented candle'`n) }`n" -Encoding UTF8
Set-Content (Join-Path $fxVi 'compare-deals.ps1') "# fixture engine stub`n" -Encoding UTF8
$r = RunPSAt $fxVi 'audit-match-soundness.ps1' @('-Accept')
if ($r.rc -eq 2 -and $r.text -match "ACCEPT REFUSED" -and $r.text -match "\[garlic\] 'Marketside Tandoori Style Garlic Naan Bites, 7\.05 oz, 15 Count'") {
  Ok 'verdict identity MUST-FIRE: the gate blocks the NAAN BITES the verdict actually judged (item field wins over the quoted flavour word)'
} else { Bad ('the -Accept gate did not block the judged naan item (rc=' + $r.rc + ') - it is not reading the entry item field: ' + $r.text) }
if ($r.text -notmatch "\[garlic\] 'Garlic'") { Ok "verdict identity: Aldi's real 'Garlic' is NOT blocked by a verdict that only mentioned garlic as a flavour (no false block)" }
else { Bad "the -Accept gate blocked the innocent 'Garlic' row again - prose re-parsing is back, and a false block is what teaches people to reach for -ForceAccept" }
if ($r.text -match "\[pinto-beans\] 'Member's Mark Pinto Beans 12 lbs\.'") { Ok 'verdict identity FALLBACK: a pre-2026-08-05 entry with no item field still keys off the quoted name, apostrophe intact' }
else { Bad ('an entry with no item field no longer blocks - hoisting identity to the item field silently disarmed every legacy verdict file: ' + $r.text) }
# CLEAN TWIN: the live 2026-08-15 situation - the naan is GLOBAL_EXCLUDEd (so the drop was already honoured)
# and only the real Garlic remains. Nothing outstanding, so -Accept must go through at exit 0.
Set-Content (Join-Path $fxVi 'global-exclude-lib.ps1') "function Get-TcGlobalExclude { @(`n  'naan'`n) }`n" -Encoding UTF8
Remove-Item (Join-Path $fxVi 'out\verify-verdicts-2026-07-17.json') -Force
$r = RunPSAt $fxVi 'audit-match-soundness.ps1' @('-Accept')
if ($r.rc -eq 0 -and $r.text -match 'baseline ACCEPTED' -and $r.text -notmatch 'ACCEPT REFUSED') { Ok 'verdict identity CLEAN TWIN: with the judged naan item unmatched, -Accept passes and the real Garlic is baselined normally' }
else { Bad ('the clean twin was REFUSED (rc=' + $r.rc + ') - the gate now blocks on a verdict whose product no longer routes there: ' + $r.text) }
Remove-Item $fxVi -Recurse -Force -ErrorAction SilentlyContinue
} # u077-m-verdict-identity-which-item-did

# ---- (l) the weekly-run lock (added 2026-07-30) --------------------------------------------------------
# FOUNDING BUG: on 2026-07-29 the 8:30 daily job ran a full 46m42s cycle (ad-cycle-log 08:31:06 ->
# 09:17:48) INSIDE the weekly run - weekly-post-capture's -Phase publish wrote out\verified-2026-07-29.json
# and published the live board at 08:46:24-08:51:39, and the daily then graded that board, hard-failed, and
# auto-repaired links on top of it at 09:14:23. Both halves are the requirement: a live weekly run must
# stand the daily down, and a lock the weekly never released must NOT - a stale lock that silently disables
# the daily forever is strictly worse than the waste it prevents. Locks here are written by the REAL
# -Acquire path at the REAL phase timestamps; a hand-written fixture lock would pass whether or not the
# writer still stamps an expiry, and - worse - would pass on a weekly that hands the tree back mid-run.
if (Use-Unit 'u078-l-the-weekly-run-lock-added-2026-07') {
$fxWl = NewFxDir 'weekly-lock'
$wlF  = Join-Path $fxWl 'weekly-run.lock'
# MUST STAND DOWN: the founding run, replayed. These are the actual phase START times of 2026-07-29 from
# out\logs\weekly-post-capture-2026-07.log. The daily fires at 08:30:01, between the 08:00:26 links phase
# and the 08:46:24 publish phase - a 44.8-minute judgment gap with no phase executing.
foreach ($stamp in @('2026-07-29T07:17:22','2026-07-29T07:29:20','2026-07-29T07:32:30','2026-07-29T07:36:03','2026-07-29T07:54:11','2026-07-29T07:56:30','2026-07-29T08:00:26')) {
  $null = RunPS 'weekly-run-lock.ps1' @('-LockFile',$wlF,'-Acquire','-Phase','replay','-Now',$stamp)
}
$wpcLk = Get-Content (Join-Path $root 'weekly-post-capture.ps1') -Raw
if ($wpcLk -match "weekly-run-lock\.ps1'\) @\('-Release'") {
  # the weekly hands the tree back mid-run: the three links phases at 07:55:21, 07:58:07 and 08:01:34 each
  # ended in push-data, so the lock is GONE before the daily tick. Model that, do not paper over it.
  Remove-Item $wlF -Force -ErrorAction SilentlyContinue
}
$r = RunPS 'weekly-run-lock.ps1' @('-LockFile',$wlF,'-Now','2026-07-29T08:30:01')
if ($r.rc -eq 2 -and $r.text -match 'HELD') { Ok 'weekly lock: the REPLAYED 2026-07-29 run still holds the tree at the 08:30 daily tick' }
else { Bad ('weekly lock is NOT held at 08:30 on a replay of the founding run (rc=' + $r.rc + ') - the 46m42s collision of 2026-07-29 still happens: ' + $r.text) }
# ...and must survive the REAL maximum in-run pause: 12:58:25 -> 16:05:53 = 187.5 min, measured over all 383
# timestamped lines of that run. A TTL under this expires while the agent is still working.
$null = RunPS 'weekly-run-lock.ps1' @('-LockFile',$wlF,'-Acquire','-Phase','publish','-Now','2026-07-29T12:58:25')
$r = RunPS 'weekly-run-lock.ps1' @('-LockFile',$wlF,'-Now','2026-07-29T16:05:53')
if ($r.rc -eq 2) { Ok 'weekly lock: the real 187.5-min agent judgment pause still reads HELD' }
else { Bad ('weekly lock expired inside the REAL max in-run pause (rc=' + $r.rc + ') - the TTL is shorter than a normal weekly gap') }
# MUST NOT STAND DOWN, AND MUST SAY SO: nothing in the weekly releases the lock, so the end state is always
# an abandoned one. That run's last phase was 19:07:26; by the next 08:30 tick it must be dead.
$null = RunPS 'weekly-run-lock.ps1' @('-LockFile',$wlF,'-Acquire','-Phase','publish','-Now','2026-07-29T19:07:26')
$r = RunPS 'weekly-run-lock.ps1' @('-LockFile',$wlF,'-Now','2026-07-30T08:30:01')
if ($r.rc -eq 0 -and $r.text -match 'STALE' -and $r.text -match 'EXPIRED' -and $r.text -match 'must never disable the daily job') { Ok 'weekly lock: a finished/abandoned lock EXPIRES before the next daily, says so loudly, and does NOT stand it down' }
else { Bad ('weekly lock did not expire by the next 08:30 (rc=' + $r.rc + ') - a finished or crashed weekly would disable the 8:30 job: ' + $r.text) }
# the expiry the reader trusts must come from the FILE, not from a constant on the read side
$wlJson = try { (((Get-Content $wlF -Raw -Encoding UTF8) + '').Trim() | ConvertFrom-Json) } catch { $null }
if ($wlJson -and $wlJson.expires -and $wlJson.refreshed -and $wlJson.acquired -and $wlJson.pid) { Ok 'weekly lock carries its own acquired/refreshed/expires/pid stamp' }
else { Bad 'weekly lock file lost its self-describing expiry - the reader has nothing to read and the TTL can drift' }
# CLEAN TWIN: no lock is a definite answer, not a blind one, and never blocks the daily (6 days in 7).
Remove-Item $wlF -Force -ErrorAction SilentlyContinue
$r = RunPS 'weekly-run-lock.ps1' @('-LockFile',$wlF,'-Now','2026-07-30T08:30:01')
if ($r.rc -eq 0 -and $r.text -match 'none - no weekly refresh') { Ok 'weekly lock clean twin: no lock = the daily runs, and says nothing alarming' }
else { Bad ('weekly lock false-positived with no lock present (rc=' + $r.rc + '): ' + $r.text) }
# an unreadable lock must FAIL OPEN and NAME the blindness (exit 3), never silently block the day's prices
Set-Content $wlF '' -Encoding UTF8
$r = RunPS 'weekly-run-lock.ps1' @('-LockFile',$wlF,'-Now','2026-07-30T08:30:01')
if ($r.rc -eq 3 -and $r.text -match 'CANNOT EVALUATE') { Ok 'weekly lock: an empty lock is exit 3 (could-not-evaluate) and fails OPEN' }
else { Bad ('weekly lock did not report could-not-evaluate on an empty file (rc=' + $r.rc + '): ' + $r.text) }
Set-Content $wlF 'not json at all' -Encoding UTF8
$r = RunPS 'weekly-run-lock.ps1' @('-LockFile',$wlF,'-Now','2026-07-30T08:30:01')
if ($r.rc -eq 3 -and $r.text -match 'CANNOT EVALUATE') { Ok 'weekly lock: a corrupt lock is exit 3 and fails OPEN' }
else { Bad ('weekly lock did not report could-not-evaluate on a corrupt file (rc=' + $r.rc + '): ' + $r.text) }
$null = RunPS 'weekly-run-lock.ps1' @('-LockFile',$wlF,'-Acquire','-Phase','links','-Now','2026-07-30T08:00:00')
$null = RunPS 'weekly-run-lock.ps1' @('-LockFile',$wlF,'-Release')
if (-not (Test-Path $wlF)) { Ok 'weekly lock: -Release removes it (so the daily can sweep its own stale debris)' }
else { Bad 'weekly lock: -Release left the file behind - a swept stale lock would come straight back every morning' }
Remove-Item $fxWl -Recurse -Force -ErrorAction SilentlyContinue
# and BOTH callers must still be wired to it - a lock nobody takes and nobody checks is a no-op that
# passes every behavioural test above (source asserts: house precedent for caller plumbing).
# (run-daily-local.ps1's stand-down assert retired with that runner on 2026-08-22; capture-run has no weekly to stand down for - the weekly browser agent is disabled)
if ($wpcLk -match "weekly-run-lock\.ps1'\) @\('-Acquire'") { Ok 'weekly-post-capture still takes the lock on every phase' }
else { Bad 'weekly-post-capture stopped taking the weekly lock - the daily has nothing to stand down for' }
if ($wpcLk -match "weekly-run-lock\.ps1'\) @\('-Release'") { Bad 'weekly-post-capture releases the lock mid-run again - on 2026-07-29 a links phase finished at 08:01:34 and the next phase was 08:46:24, so releasing hands grocery\out back 28 min before the 08:30 daily fires. The lock expires on its own TTL; nothing in the weekly may hand it back.' }
else { Ok 'weekly-post-capture never hands the tree back mid-run (the lock expires on its own TTL)' }
} # u078-l-the-weekly-run-lock-added-2026-07

# ---------------------------------------------------------------- N+6. script census: is every file in this
# directory still reachable? 2026-07-30: 33 of the 144 .ps1 in grocery\ (out\ and archive\ aside) were named
# by no other executable file in the repo, and another 37 sat inside out\ - the pipeline's own OUTPUT
# directory. At that ratio a live weekly-by-hand script is indistinguishable from a finished one-shot that
# would clobber a backup if you ran it. audit-script-census.ps1 holds that line with a recorded SET of
# deliberate entry points plus a recorded COUNT for out\; its header names them all.
# DO NOT NAME A GROCERY SCRIPT IN THIS COMMENT. The census greps filenames across executable files, so a
# mention here is indistinguishable from a call and would silently retire that script from the census (it
# already happened once while this block was being written). Fixtures are synthetic zzz-* trees only.
# HYGIENE OR BLIND, FOR THE LIVE CASE (2026-09-26, queue 2026-09-26-8163f7; the one-tally-two-verdicts shape). On
# 2026-09-26 one untracked file pushed the live census over its wide mark, the census exited 2 exactly as designed,
# every census fixture fired, and this file scored it Bad, so the day paged "a GUARD has gone blind". 'ok' needs exit
# 0, the clean line and a census that still sees (uncalled > 0). 'hygiene' needs exit 2, the census's own
# "script-census FAIL: N finding(s)" line and a census that still sees. Everything else is 'blind', so a crash, an
# exit 3, a timeout (124) or an empty census still lands in the loud arm: the new tier is never where an unknown
# verdict goes quiet.
function Get-ScriptCensusLiveTier([int]$Rc, [string]$Text) {
  $m = [regex]::Match([string]$Text, '(\d+) uncalled, (\d+) recorded as deliberate')
  if (-not ($m.Success -and [int]$m.Groups[1].Value -gt 0)) { return 'blind' }
  if ($Rc -eq 0 -and $Text -match 'no unrecorded orphan') { return 'ok' }
  if ($Rc -eq 2 -and $Text -match 'script-census FAIL: \d+ finding') { return 'hygiene' }
  return 'blind'
}
if (Use-Unit 'u079-n-6-script-census-is-every-file-in' -Always 'audit-script-census scans every file under the repository root for callers') {
# The tier function's own frozen cases. The MUST FIRE text is the founding run's (2026-09-26 test-auditors-fail, the
# live census over its wide mark); each blind case is a shape the old single verdict also had to catch.
$scSees = 'script-census: 714 script(s) + 38 under out\, read against 836 executable file(s); 109 uncalled, 70 recorded as deliberate'
$scCases = @(
  @('MUST FIRE: the founding day, an unrecorded script over the wide mark at exit 2, is HYGIENE and not blindness', 2, ($scSees + "`n  FAIL    WIDE RATCHET ROSE: 74 unrecorded orphan(s) outside grocery\, over the high-water mark of 73.`nscript-census FAIL: 1 finding(s)."), 'hygiene'),
  @('MUST FIRE: a new strict-tier ORPHAN at exit 2 is HYGIENE', 2, ($scSees + "`n  FAIL    ORPHAN grocery\zzz-new.ps1 - no executable file in the repo names it`nscript-census FAIL: 1 finding(s)."), 'hygiene'),
  @('CLEAN TWIN: a clean census that still sees its recorded set is ok', 0, ($scSees + "`n  ok      no unrecorded orphan; out\ holds 38 one-off(s), at or under baseline"), 'ok'),
  @('MUST FIRE: an EMPTY census (0 uncalled, the self-exclusion removed) reading clean at exit 0 is BLIND', 0, "script-census: 714 script(s) + 38 under out\, read against 836 executable file(s); 0 uncalled, 70 recorded as deliberate`n  ok      no unrecorded orphan; out\ holds 38 one-off(s), at or under baseline", 'blind'),
  @('MUST FIRE: an EMPTY census at exit 2 is BLIND, never hygiene', 2, "script-census: 0 script(s) + 0 under out\, read against 836 executable file(s); 0 uncalled, 70 recorded as deliberate`nscript-census FAIL: 1 finding(s).", 'blind'),
  @('MUST FIRE: exit 3 (the census found nothing to examine) is BLIND', 3, 'script-census: BLIND - nothing to examine', 'blind'),
  @('MUST FIRE: a timeout (124) after the count line is BLIND, never hygiene', 124, $scSees, 'blind'),
  @('MUST FIRE: exit 2 with no finding line (a crash after the count) is BLIND', 2, $scSees, 'blind')
)
foreach ($c in $scCases) {
  $got = Get-ScriptCensusLiveTier -Rc $c[1] -Text $c[2]
  if ($got -eq $c[3]) { Ok ('script-census live tier  ' + $c[0]) } else { Bad ('script-census live tier  ' + $c[0] + ' - got ' + $got + ', want ' + $c[3]) }
}
$r = Get-Early 'early:census-live' (Join-Path $root 'audit-script-census.ps1') @()
# The live twin asserts TWO things, because "clean" alone is exactly what a self-defeated census reports.
# The census must not count ITSELF as a source: its own KNOWN table quotes every recorded name, so the day
# that exclusion is dropped the census reports 0 uncalled, prints "no unrecorded orphan", and exits 0
# forever. The uncalled count is read from the guard's own output, never hard-coded here: it can never
# legitimately reach 0 while the SKILL-launched and Task-Scheduler-launched entry points exist.
# THE LIVE CASE ASKS TWO QUESTIONS AND NOW GIVES TWO VERDICTS (2026-09-26, queue 2026-09-26-8163f7). An orphan on
# the live tree is the census WORKING: it is the estate's housekeeping, and it goes to Hygiene. Only a census that
# cannot see (an empty census, rc 3, a crash, any exit it does not define) is Bad. The tier is decided by
# Get-ScriptCensusLiveTier, driven by its own frozen cases just above this line.
$scM = [regex]::Match($r.text, '(\d+) uncalled, (\d+) recorded as deliberate')
$scTier = Get-ScriptCensusLiveTier -Rc $r.rc -Text $r.text
if ($scTier -eq 'ok') { Ok ('script-census clean twin: no unrecorded orphan, out\ at baseline, and it still SEES its recorded set (' + $scM.Groups[1].Value + ' uncalled)') }
elseif ($scTier -eq 'hygiene') { Hygiene ('script-census found an unrecorded script on the live tree (rc=' + $r.rc + ') - the census SEES (' + $scM.Groups[1].Value + ' uncalled) and every census fixture below still fires; no watcher is blind. Wire the named script in, archive it, or record it in KNOWN: ' + $r.text) }
else { Bad ('script-census reported an EMPTY census or an exit it does not define (rc=' + $r.rc + ') - the self-exclusion that stops its own KNOWN table from marking everything "called" was removed, or the census could not run: ' + $r.text) }
$fxSc = NewFxDir 'sc-orphan'
Set-Content (Join-Path $fxSc 'zzz-new-thing.ps1') 'Write-Output "new"' -Encoding UTF8
Set-Content (Join-Path $fxSc 'zzz-caller.ps1') '& (Join-Path $PSScriptRoot "zzz-helper.ps1")' -Encoding UTF8
Set-Content (Join-Path $fxSc 'zzz-helper.ps1') 'Write-Output "helper"' -Encoding UTF8
Set-Content (Join-Path $fxSc 'zzz-wire.js') '// nightly: zzz-caller.ps1' -Encoding UTF8
# -StrictPrefix '' BECAUSE A FIXTURE TREE HAS NO grocery\ (2026-09-09). Without it every fixture orphan
# fell into the WIDE tier and was measured against the LIVE high-water mark of 73, so this must-fire and
# the two below could not fire at all. They had been reporting FAIL correctly and the fixture was the
# thing that was broken.
$r = RunPS 'audit-script-census.ps1' @('-Root', $fxSc, '-ScanRoot', $fxSc, '-WholeTreeIsStrict')
if ($r.rc -eq 2 -and $r.text -match 'ORPHAN zzz-new-thing\.ps1') { Ok 'script-census FIRES on a script no executable file names' }
else { Bad ('script-census missed a brand-new orphan (rc=' + $r.rc + '): ' + $r.text) }
Set-Content (Join-Path $fxSc 'zzz-run.cmd') 'powershell -File zzz-new-thing.ps1' -Encoding UTF8
$r = RunPS 'audit-script-census.ps1' @('-Root', $fxSc, '-ScanRoot', $fxSc, '-WholeTreeIsStrict')
if ($r.rc -eq 0 -and $r.text -match '0 uncalled') { Ok 'script-census SILENT once that script is wired in (a .cmd launcher counts as a caller)' }
else { Bad ('script-census still fires after the orphan was wired in (rc=' + $r.rc + '): ' + $r.text) }
New-Item -ItemType Directory -Force (Join-Path $fxSc 'out') | Out-Null
Set-Content (Join-Path $fxSc 'out\zzz-oneoff.ps1') 'Write-Output "one-off"' -Encoding UTF8
$r = RunPS 'audit-script-census.ps1' @('-Root', $fxSc, '-ScanRoot', $fxSc, '-OutBaseline', '0', '-WholeTreeIsStrict')
if ($r.rc -eq 2 -and $r.text -match 'OUTPUT directory') { Ok 'script-census ratchet FIRES when a one-off is written into out\' }
else { Bad ('script-census let out\ grow past its recorded baseline (rc=' + $r.rc + '): ' + $r.text) }
$r = RunPS 'audit-script-census.ps1' @('-Root', $fxSc, '-ScanRoot', $fxSc, '-OutBaseline', '1', '-WholeTreeIsStrict')
if ($r.rc -eq 0) { Ok 'script-census ratchet SILENT at the recorded baseline (a ratchet, not a hard zero)' }
else { Bad ('script-census ratchet fires at its own recorded baseline (rc=' + $r.rc + ') - it would fail from day one') }
# A VENDORED ENVIRONMENT IS NOT A REPO SCRIPT (2026-09-26, queue 2026-09-26-1f95a4 and its 7 prior closes of this type).
# The main checkout's gitignored sidecar venv carried an activate script no worktree has, so the wide tier read one over
# its mark only where the bot pushes from, and the bot's push was refused four times.
$fxScV = NewFxDir 'sc-venv'
New-Item -ItemType Directory -Force (Join-Path $fxScV 'side\.venv\Scripts') | Out-Null
New-Item -ItemType Directory -Force (Join-Path $fxScV 'web\node_modules\pkg') | Out-Null
Set-Content (Join-Path $fxScV 'side\.venv\Scripts\activate.ps1') 'Write-Output "venv"' -Encoding UTF8
Set-Content (Join-Path $fxScV 'web\node_modules\pkg\install.ps1') 'Write-Output "npm"' -Encoding UTF8
Set-Content (Join-Path $fxScV 'zzz-real-orphan.ps1') 'Write-Output "real"' -Encoding UTF8
$r = RunPS 'audit-script-census.ps1' @('-Root', $fxScV, '-ScanRoot', $fxScV, '-WholeTreeIsStrict')
if ($r.text -notmatch 'activate\.ps1' -and $r.text -notmatch 'install\.ps1') { Ok 'script-census MUST NOT FIRE on a script inside a .venv or node_modules directory (vendored, not the repo''s own)' }
else { Bad ('script-census counted a vendored environment''s script as a repo orphan (rc=' + $r.rc + '): ' + $r.text) }
if ($r.rc -eq 2 -and $r.text -match 'ORPHAN zzz-real-orphan\.ps1') { Ok 'script-census CLEAN TWIN: a real orphan beside the pruned vendored dirs still fires' }
else { Bad ('script-census stopped seeing a real orphan once vendored dirs were pruned (rc=' + $r.rc + '): ' + $r.text) }
# A RISE NAMES ITS SCRIPTS (same day): the wide mark is a count, so the failure lists every unrecorded wide orphan.
$fxScW = NewFxDir 'sc-wide'
Set-Content (Join-Path $fxScW 'zzz-wide-orphan.ps1') 'Write-Output "wide"' -Encoding UTF8
Set-Content (Join-Path $fxScW 'script-census-wide-baseline.json') '{"uncalled": 0}' -Encoding UTF8
$r = RunPS 'audit-script-census.ps1' @('-Root', $fxScW, '-ScanRoot', $fxScW)
if ($r.rc -eq 2 -and $r.text -match 'WIDE RATCHET ROSE' -and $r.text -match 'wide-unrecorded zzz-wide-orphan\.ps1') { Ok 'script-census MUST FIRE: a wide-tier rise over its mark of 0 names the unrecorded script' }
else { Bad ('script-census wide rise did not fire or did not name its script (rc=' + $r.rc + '): ' + $r.text) }
Set-Content (Join-Path $fxScW 'script-census-wide-baseline.json') '{"uncalled": 1}' -Encoding UTF8
$r = RunPS 'audit-script-census.ps1' @('-Root', $fxScW, '-ScanRoot', $fxScW)
if ($r.rc -eq 0 -and $r.text -notmatch 'wide-unrecorded') { Ok 'script-census CLEAN TWIN: at its wide mark of 1 it passes and lists nothing' }
else { Bad ('script-census failed or listed names at its own wide mark (rc=' + $r.rc + '): ' + $r.text) }
$fxScB = NewFxDir 'sc-blind'
$r = RunPS 'audit-script-census.ps1' @('-Root', $fxScB, '-ScanRoot', $fxScB, '-WholeTreeIsStrict')
if ($r.rc -eq 3 -and $r.text -match 'BLIND') { Ok 'script-census goes BLIND (exit 3) with nothing to examine instead of reporting a clean zero' }
else { Bad ('script-census reported a result from an empty tree (rc=' + $r.rc + ') - "0 orphans" from zero examination is back') }

# A SIBLING CHECKOUT IS NOT A SECOND SET OF SCRIPTS (2026-08-03 -> 08-06). Another session left a git
# worktree inside the scanned tree and this census was red for four days: 35 ORPHANs, every one of them a
# copy living inside that worktree. The noise was the harmless half. The worktree also holds a COPY of the
# census, and a copy is not the running file, so it was read as a SOURCE - and its recorded table quotes
# every deliberate entry point, so the census could see 0 of its own recorded set while still exiting 2 for
# transient files. Both halves are pinned below. The fixture is built to a real worktree's SHAPE - a
# directory whose .git is a FILE holding a gitdir: line - because that marker, not the path it sits at, is
# what the prune keys on. Nothing here may key on \.claude\worktrees\: the live worktrees already sit under
# two different parents and the next one need not sit under either.
$fxWt = NewFxDir 'sc-worktree'
Set-Content (Join-Path $fxWt 'zzz-main.ps1')   '& (Join-Path $PSScriptRoot "zzz-helper.ps1")' -Encoding UTF8
Set-Content (Join-Path $fxWt 'zzz-helper.ps1') 'Write-Output "helper"' -Encoding UTF8
Set-Content (Join-Path $fxWt 'zzz-wire.js')    '// nightly: zzz-main.ps1' -Encoding UTF8
$fxWtTwin = Join-Path $fxWt '.claude\worktrees\zzz-sibling'
New-Item -ItemType Directory -Force $fxWtTwin | Out-Null
Set-Content (Join-Path $fxWtTwin '.git') 'gitdir: C:/nowhere/.git/worktrees/zzz-sibling' -Encoding UTF8
Set-Content (Join-Path $fxWtTwin 'zzz-copied-oneoff.ps1') 'Write-Output "a transient copy"' -Encoding UTF8
# the masking half: the ONLY file that names the orphan added below lives inside the pruned checkout
Set-Content (Join-Path $fxWtTwin 'zzz-vouch.js') '// zzz-orphan-for-real.ps1' -Encoding UTF8
$r = RunPS 'audit-script-census.ps1' @('-Root', $fxWt, '-ScanRoot', $fxWt, '-WholeTreeIsStrict')
if ($r.rc -eq 0 -and $r.text -match 'skipped nested checkout' -and $r.text -notmatch 'zzz-copied-oneoff') { Ok 'script-census CLEAN TWIN: a sibling git worktree in the tree is pruned whole, not counted as 1 more orphan' }
else { Bad ('script-census counts a sibling worktree''s copies as scripts (rc=' + $r.rc + ') - the 2026-08-03 four-day red is back: ' + $r.text) }
Set-Content (Join-Path $fxWt 'zzz-orphan-for-real.ps1') 'Write-Output "new"' -Encoding UTF8
$r = RunPS 'audit-script-census.ps1' @('-Root', $fxWt, '-ScanRoot', $fxWt, '-WholeTreeIsStrict')
if ($r.rc -eq 2 -and $r.text -match 'ORPHAN zzz-orphan-for-real\.ps1' -and $r.text -notmatch 'zzz-copied-oneoff') { Ok 'script-census MUST-FIRE with that sibling still present: a real new orphan is still caught, and a file inside the pruned checkout cannot vouch for it' }
else { Bad ('script-census went blind to a real orphan while a sibling worktree was present (rc=' + $r.rc + ') - the prune is swallowing the tree it is meant to census, or a copy of the repo is being read as a caller: ' + $r.text) }

Remove-Item $fxSc, $fxScB, $fxWt -Recurse -Force -ErrorAction SilentlyContinue
} # u079-n-6-script-census-is-every-file-in

# ---------------------------------------------------------------- N. arrivals desk (build-arrivals-docket)
# MUST FIRE: 2026-07-28. "Dr Teal's Foaming Bath with Pure Epsom Salt, Nourish & Protect with Coconut Oil"
# arrived in coconut-oil at Baker's and took the crown at 17c/oz. It carried a real Kroger product_id, a real
# price and a working link, so every identity, basis, band and link check passed it. The ONLY thing wrong was
# that the product is not the commodity, and nothing on the board records that decision.
# THE POINT OF THIS FIXTURE is the head cut. Scoring the FULL product name matches "Coconut Oil" in the tail
# and the bath soap scores a PERFECT 0.00 divergence - measured, along with the cat-food-as-salmon case
# falling off the docket entirely. If someone "simplifies" Get-ArrivalHead to score the whole name, this test
# is what stops it, so do not relax it to a rank or a substring of the item text.
if (Use-Unit 'u080-n-arrivals-desk-build-arrivals') {
$r = RunPS 'build-arrivals-docket.ps1' @('-CompareFile', (Join-Path $fix 'arrivals-mustfire-board.json'), '-BaselineDir', (Join-Path $fix 'arrivals-baseline'), '-CommoditiesFile', (Join-Path $fix 'arrivals-commodities.json'), '-OutFile', (Register-Fx (Join-Path $env:TEMP ('arrdock-' + [guid]::NewGuid().ToString('N').Substring(0,8) + '.json'))))
if ($r.text -match 'FLAG#1' -and $r.text -match 'coconut-oil' -and $r.text -match 'div=1\.00' -and $r.text -match 'CROWN') { Ok 'arrivals-docket RANKS the bath-soap-as-coconut-oil crown arrival FIRST' }
else { Bad ('arrivals-docket MISSED its founding bug (head cut broken, or crowns no longer ranked first): ' + $r.text) }
# MUST FIRE: a commodity with ONE other priced cell cannot be scored at all. 41 of 492 commodities are in that
# state, and "no flag" from an unscorable row is the exact silence this estate has been burned by.
if ($r.text -match 'BLIND' -and $r.text -match 'harissa-paste' -and $r.text -match 'thin-cohort') { Ok 'arrivals-docket reports a 1-cell cohort BLIND instead of passing it' }
else { Bad ('arrivals-docket silently passed an unscorable thin cohort: ' + $r.text) }
# MUST BE SILENT: the SAME arrival, the SAME crown, the SAME 17c/oz - with a real coconut oil. If this flags,
# the score is tracking novelty or cheapness rather than divergence and the whole docket is noise.
$r2 = RunPS 'build-arrivals-docket.ps1' @('-CompareFile', (Join-Path $fix 'arrivals-clean-board.json'), '-BaselineDir', (Join-Path $fix 'arrivals-baseline'), '-CommoditiesFile', (Join-Path $fix 'arrivals-commodities.json'), '-OutFile', (Register-Fx (Join-Path $env:TEMP ('arrdock-' + [guid]::NewGuid().ToString('N').Substring(0,8) + '.json'))))
if ($r2.text -match 'FLAGGED at div >= 0\.75: 0') { Ok 'arrivals-docket SILENT on the same crown arrival with the right product' }
else { Bad ('arrivals-docket flagged a correct new product - it is scoring novelty, not divergence: ' + $r2.text) }
if ($r2.text -match 'harissa-paste' -and $r2.text -match 'thin-cohort') { Ok 'arrivals-docket still reports the thin cohort BLIND on the clean board' }
else { Bad 'arrivals-docket dropped its BLIND report on a clean board - BLIND must describe the cohort, not the verdict' }
# MUST FIRE: with no baseline there is no delta, and "every cell is an arrival" is not a review queue. A check
# that examined nothing must say so rather than emit 2,792 rows that read like findings.
$r3 = RunPS 'build-arrivals-docket.ps1' @('-CompareFile', (Join-Path $fix 'arrivals-mustfire-board.json'), '-BaselineDir', (Join-Path $fix 'arrivals-baseline'), '-CommoditiesFile', (Join-Path $fix 'arrivals-commodities.json'), '-OutFile', (Register-Fx (Join-Path $env:TEMP ('arrdock-' + [guid]::NewGuid().ToString('N').Substring(0,8) + '.json'))), '-N', '0')
if ($r3.rc -eq 3 -and $r3.text -match 'ZERO baseline boards') { Ok 'arrivals-docket exits 3 when it has NO baseline to diff against' }
else { Bad ('arrivals-docket claimed a usable delta with zero baseline (rc=' + $r3.rc + ')') }
} # u080-n-arrivals-desk-build-arrivals

# ---------------------------------------------------------------- N2. the PROSPECTS section (F1 adjudication)
# discover-hyvee.ps1 writes a docket of products that are NOT on the board and would beat what we hold. It had
# no reader, so discovery paid nothing. These fixtures pin the reader.
# WHY IT CANNOT BE MACHINE-VETTED: Hy-Vee publishes no per-product department, and the CATEGORY facet its
# search response exposes is SILENTLY IGNORED when passed back as a filter (three request shapes tried, all
# returned the identical unfiltered results with a cat litter still in "baking soda"). Measured on the first
# live run: ~14% of candidates are WRONG PRODUCTS. So the section must rank and explain, never pass.
if (Use-Unit 'u081-n2-the-prospects-section-f1') {
$proArgs = @('-CompareFile', (Join-Path $fix 'arrivals-clean-board.json'), '-BaselineDir', (Join-Path $fix 'arrivals-baseline'),
  '-CommoditiesFile', (Join-Path $fix 'arrivals-commodities.json'), '-DiscoveryFile', (Join-Path $fix 'arrivals-prospects.json'),
  '-VerdictsFile', (Join-Path $fix 'arrivals-prospect-verdicts.json'),
  '-OutFile', (Register-Fx (Join-Path $env:TEMP ('arrdock-' + [guid]::NewGuid().ToString('N').Substring(0,8) + '.json'))))
$rp = RunPS 'build-arrivals-docket.ps1' $proArgs
# MUST FIRE: the 2026-07-28 bath soap, re-staged as a PROSPECT. It has to rank first, carry div 1.00 from the
# head cut, and be named a crown-taker - a prospect that cannot win changes no shopper's price, so that
# distinction is the severity signal the reader sorts on.
if ($rp.text -match 'FLAG#1' -and $rp.text -match "Dr Teal" -and $rp.text -match 'div=1\.00' -and $rp.text -match 'TAKES CROWN') {
  Ok 'prospects: the bath-soap-as-coconut-oil candidate ranks FIRST, div 1.00, named as a crown-taker'
} else { Bad ('prospects MISSED the founding wrong product (head cut, ranking or crown arithmetic broken): ' + $rp.text) }
# MUST FIRE, INDEPENDENTLY: 34 FLUID ounces divided into a commodity priced per WEIGHT ounce. This is the
# defect that made a Pasta Roni vermicelli "beat" olive oil by 21.8% on the first live docket - a REAL price
# on a FALSE basis, where every number in the row is individually defensible. Divergence and basis are
# separate detectors on purpose; the vermicelli scored only 0.50 and the floor would have missed it.
if ($rp.text -match 'BASIS' -and $rp.text -match 'names a VOLUME') { Ok 'prospects: a size in fluid ounces against a per-weight commodity is flagged as a BASIS defect' }
else { Bad ('prospects passed a false basis - the saving is arithmetic, not money: ' + $rp.text) }
# MUST BE SILENT: a real coconut oil, right basis, same store, same docket, also beating the held price.
if ($rp.text -match 'ctx #2' -and $rp.text -match 'Nutiva' -and $rp.text -match 'no crown') { Ok 'prospects: the real coconut oil is listed as context, unflagged, and correctly reads no crown' }
else { Bad ('prospects flagged a correct product or got the crown arithmetic wrong - it is scoring novelty, not divergence: ' + $rp.text) }
# MUST FIRE: a candidate a human already ruled on must LEAVE the queue and still be COUNTED. A settled
# candidate that silently vanishes is indistinguishable from a discovery run that stopped working.
if ($rp.text -match 'PROSPECTS awaiting a ruling: 2 \(1 would take a crown, 1 flagged, 1 already ruled\)' -and $rp.text -notmatch 'Blue Buffalo') {
  Ok 'prospects: the already-ruled cat-food candidate leaves the queue and is counted as settled, not dropped'
} else { Bad ('prospects re-asked a settled question, or dropped it without counting it: ' + $rp.text) }
# MUST FIRE: no docket on disk is NOT "no candidates". Discovery not having run and discovery finding nothing
# are different facts and must never print the same.
$rp2 = RunPS 'build-arrivals-docket.ps1' @('-CompareFile', (Join-Path $fix 'arrivals-clean-board.json'), '-BaselineDir', (Join-Path $fix 'arrivals-baseline'),
  '-CommoditiesFile', (Join-Path $fix 'arrivals-commodities.json'), '-DiscoveryFile', (Join-Path $fix 'no-such-discovery-docket.json'),
  '-VerdictsFile', (Join-Path $fix 'arrivals-prospect-verdicts.json'),
  '-OutFile', (Register-Fx (Join-Path $env:TEMP ('arrdock-' + [guid]::NewGuid().ToString('N').Substring(0,8) + '.json'))))
if ($rp2.text -match 'BLIND' -and $rp2.text -match 'discovery has not run') { Ok 'prospects: a missing docket reports BLIND rather than a clean zero' }
else { Bad ('prospects turned a missing discovery docket into "no candidates": ' + $rp2.text) }
# MUST FIRE: the prospects section must not overwrite the ARRIVALS baseline-adequacy reason. Shipped and
# caught the same day: the loop reused $why, the docket-level variable, so a run with no baseline printed
# "DEGRADED: no-board-row for ketchup" and its exit-3 line named the wrong reason entirely - a check that
# reports the wrong cause of its own blindness sends the reader to the wrong bug. Same clobber family as
# $Matches being global in PS 5.1. A prospect whose commodity is off this board forces the collision.
$rp3 = RunPS 'build-arrivals-docket.ps1' @('-CompareFile', (Join-Path $fix 'arrivals-mustfire-board.json'), '-BaselineDir', (Join-Path $fix 'arrivals-baseline'),
  '-CommoditiesFile', (Join-Path $fix 'arrivals-commodities.json'), '-DiscoveryFile', (Join-Path $fix 'arrivals-prospects-offboard.json'),
  '-VerdictsFile', (Join-Path $fix 'arrivals-prospect-verdicts.json'), '-N', '0',
  '-OutFile', (Register-Fx (Join-Path $env:TEMP ('arrdock-' + [guid]::NewGuid().ToString('N').Substring(0,8) + '.json'))))
if ($rp3.text -match 'DEGRADED: ZERO baseline boards' -and $rp3.text -match 'no-board-row') {
  Ok 'prospects: an off-board prospect is reported as unscorable WITHOUT overwriting the docket-level DEGRADED reason'
} else { Bad ('the prospects loop clobbered the arrivals baseline-adequacy reason again: ' + $rp3.text) }
# The fixtures must stay frozen. Both were authored from the founding cases, not from a live docket, and a
# fixture regenerated from live data proves only that the code agrees with itself.
$rpF = @((Get-Content (Join-Path $fix 'arrivals-prospects.json') -Raw) + (Get-Content (Join-Path $fix 'arrivals-prospect-verdicts.json') -Raw))
if ($rpF -match 'NEVER regenerate' -and $rpF -match '9990003') { Ok 'prospects fixtures are still the frozen founding cases' }
else { Bad 'the prospects fixtures were regenerated - they no longer pin the founding wrong products' }

# MUST FIRE: the docket is a QUEUE, not a report of the last slice. discover-hyvee walks a BOUNDED ROTATION
# (40 of 526 terms), and it used to overwrite the file - so a candidate nobody adjudicated before the cursor
# moved on vanished until the rotation came back around ~13 days later. Caught the first time discovery ran
# twice: a 12-term slice replaced 11 open candidates (That's Smart! peanut butter at -33.4%, ketchup at -29%)
# with 2. Source-scanned because reproducing it needs two live network runs.
$dhSrc = Get-Content (Join-Path $root 'discover-hyvee.ps1') -Raw
$dhMergeAt = $dhSrc.IndexOf('MERGE, NEVER OVERWRITE')
$dhWriteAt = $dhSrc.IndexOf('($docket.ToArray() | ConvertTo-Json')
if ($dhMergeAt -gt 0 -and $dhWriteAt -gt $dhMergeAt -and $dhSrc -match '\$docket\.Add\(\$p\); \$carried\+\+') {
  Ok 'discovery docket MERGES the open queue forward instead of overwriting it with the current slice'
} else { Bad 'discover-hyvee overwrites its docket again - every unadjudicated candidate outside the current 40-term slice is being discarded' }
# MUST FIRE, the ordering half of the cycle wiring: the desk reads the docket, so discovery has to run first.
$cacSrc = (Expand-SelfTestPointers -Text ((Expand-SelfTestPointers -Text ([IO.File]::ReadAllText((Join-Path $root 'check-ad-cycles.ps1'))) -Path (Join-Path $root 'check-ad-cycles.ps1'))) -Path (Join-Path $root 'check-ad-cycles.ps1'))
$cacDisc = $cacSrc.IndexOf("'discover-hyvee.ps1'")
$cacArr  = $cacSrc.IndexOf("'build-arrivals-docket.ps1'")
if ($cacDisc -gt 0 -and $cacArr -gt $cacDisc) { Ok 'the cycle runs discover-hyvee BEFORE the arrivals desk that reads its docket' }
else { Bad 'check-ad-cycles builds the arrivals docket before discovery writes it - the PROSPECTS section will always show yesterday' }

# the verdict intake itself: 14 hermetic checks, including that ACCEPT writes a work-list row and not a price
$r = RunPS 'adjudicate-discovery.ps1' @('-SelfTest')
if ($r.rc -eq 0 -and $r.text -match 'SELFTEST: all') { Ok ('adjudicate-discovery self-test: ' + (($r.text -split "`n" | Where-Object { $_ -match 'SELFTEST: all' }) -join '')) }
else { Bad ('adjudicate-discovery self-test FAILED: ' + $r.text) }
} # u081-n2-the-prospects-section-f1

# ---------------------------------------------------------------- N3. recipe-board product identity
# MUST FIRE: recipe-board store rows carried {store, per_unit, type, bulk} and nothing else. derive-recipe-
# floors CHOSE a product to price each cell from and threw its identity away, so nothing downstream could
# match those cells: resolve-hyvee-links matches BY SIZE FIRST and logged "no size match (ours: / )" -
# correctly REFUSING rather than guess, which is the founding minced-garlic fix (board published 32 oz while
# the link opened 4.5 oz) - and guard 3 reported 10 pins whose board cell has no product name to check.
# The fixture is COPIED to a temp dir first: this script writes its proposal and report into -OutDir, and a
# fixture run must never write where the live run writes.
if (Use-Unit 'u082-n3-recipe-board-product-identity') {
$fxRf = Register-Fx (Join-Path $env:TEMP ('taudit-rf-' + [guid]::NewGuid().ToString('N').Substring(0, 8)))
New-Item -ItemType Directory -Path $fxRf -Force | Out-Null
Copy-Item (Join-Path $fix 'recipe-floors\*.json') $fxRf -Force
$r = RunPS 'derive-recipe-floors.ps1' @('-Root', $fxRf, '-OutDir', $fxRf)
$rfProp = $null
try { $rfProp = ((Read-TextFile (Join-Path $fxRf 'recipe-floors-proposed.json')) + '').Trim() | ConvertFrom-Json } catch {}
} # u082-n3-recipe-board-product-identity
function RfCell($id, $store) {
  foreach ($row in @($rfProp.comparison)) { if ([string]$row.id -eq $id) { foreach ($s in @($row.stores)) { if ([string]$s.store -eq $store) { return $s } } } }
  return $null
}
if (Use-Unit 'u082-n3-recipe-board-product-identity') {
$mg = RfCell 'minced-garlic' 'Hy-Vee'
# The cheapest everyday candidate is the 32 oz jar at the SAME per-unit the row already held, so this also
# pins that identity is stamped when the PRICE DOES NOT MOVE - 313 live cells sat at an unchanged price with
# no product name, and a fix that only stamped changed cells would have left them exactly as they were.
if ($mg -and [string]$mg.item -eq 'Spice World Minced Garlic' -and [string]$mg.size -eq '32 oz') {
  Ok 'recipe floors: a cell is stamped with the product its price came from, even when the price is unchanged'
} else { Bad ('recipe-board rows are being written without product identity again: ' + ($mg | ConvertTo-Json -Compress)) }
# MUST FIRE: an EMPTY size is written as NOTHING. '' is exactly what produces the resolver's "ours: / " and
# it reads as an answer; absent reads as the question it is.
$rb2 = RfCell 'rye-bread' 'Hy-Vee'
if ($rb2 -and [string]$rb2.item -eq 'Hy-Vee Jewish Rye Bread' -and -not ($rb2.PSObject.Properties.Name -contains 'size')) {
  Ok 'recipe floors: a candidate with no size writes NO size rather than an empty one the resolver would read as an answer'
} else { Bad ('an empty size was written as a real size - the resolver will match against nothing: ' + ($rb2 | ConvertTo-Json -Compress)) }
# MUST FIRE: identity travels WITH the price or not at all. A row nothing re-prices keeps its old number, so
# it must NOT be handed a product name - that name would describe a price that came from somewhere else,
# which is the wrong-basis class (a real product attached to a real price that is not its own).
$nr = RfCell 'no-refresh-path' 'Hy-Vee'
if ($nr -and -not ($nr.PSObject.Properties.Name -contains 'item') -and $r.text -match 'no-board-match') {
  Ok 'recipe floors: a row with no candidate keeps its price AND gets no invented identity'
} else { Bad ('identity was stamped onto a cell whose price came from somewhere else: ' + ($nr | ConvertTo-Json -Compress)) }
if ((Get-Content (Join-Path $fix 'recipe-floors\recipe-board-everyday.json') -Raw) -match 'NEVER regenerate') { Ok 'recipe-floors fixture is still the frozen identity gap' }
else { Bad 'the recipe-floors fixture was regenerated - it no longer pins the shape the bug lived in' }
# MUST FIRE: a recipe-only row the staples board cannot price falls back to the RECIPE pool. Founding case -
# boneless-skinless-chicken-thigh @ Hy-Vee held the recipe-board CROWN at $1.99/lb while the store charged
# $3.996, because no staples commodity matches that cut so nothing re-priced it since 2026-07-12.
$rp = RfCell 'recipe-pool-only' 'Hy-Vee'
if ($rp -and [double]$rp.per_unit -eq 3.996 -and [string]$rp.item -eq 'Tyson Boneless Skinless Chicken Thighs') {
  Ok 'recipe floors: a row with no staples twin is priced (and named) from the recipe pool instead of sitting frozen'
} else { Bad ('the recipe-pool fallback stopped reaching a recipe-only row - it will sit frozen again: ' + ($rp | ConvertTo-Json -Compress)) }
# MUST FIRE: the pool is a SECOND-CLASS source and every cell from it is reported for review, never blended
# into the staples count. Measured before use: 7 of 10 diverging cells were WRONG PRODUCTS (Mt. OLIVE pickles
# as olives, Oreo Zero Sugar COOKIES as zero-sugar-soda, apple JUICE and Gerber baby food as apple).
$rfRep = $null
try { $rfRep = ((Read-TextFile (Join-Path $fxRf 'recipe-floors-report.json')) + '').Trim() | ConvertFrom-Json } catch {}
if ($rfRep -and @($rfRep.recipe_pool_cells).Count -ge 1 -and (@($rfRep.recipe_pool_ids) -contains 'recipe-pool-only') -and $r.text -match 'RECIPE POOL') {
  Ok 'recipe floors: every cell priced from the recipe pool is reported separately for review, not blended in'
} else { Bad 'the recipe pool is being used without being declared - a second-class source is passing as a staples-derived one' }
# MUST FIRE: the fallback removes the MAPPING question, not the BASIS one. A pool entry whose unit differs
# from the row's is still refused - the brown-sugar 16x lesson.
$wu = RfCell 'wrong-unit-pool' 'Hy-Vee'
if ($wu -and [double]$wu.per_unit -eq 1.49 -and -not ($wu.PSObject.Properties.Name -contains 'item')) {
  Ok 'recipe floors: a pool entry in a different unit is REFUSED, price and identity both untouched'
} else { Bad ('the fallback took a price across an unreconciled unit - a real number on a false basis: ' + ($wu | ConvertTo-Json -Compress)) }
Remove-Item $fxRf -Recurse -Force -ErrorAction SilentlyContinue
} # u082-n3-recipe-board-product-identity

# ---------------------------------------------------------------- N4. multipack SIZE REPAIR
# The repair half of guard 5. Its 8 hermetic cases include the two that decide whether it is safe at all:
# the founding Heinz row must repair (name states 2 x 50.5 oz, feed returned one bottle, $0.2968/oz against
# a true $0.1484), and guard 5's OWN founding bug must still be REFUSED ("ReaLemon 100% Lemon Juice (2 pk)",
# size "48 fl oz", no per-unit weight in the name) - inventing a total there is guessing at the exact point
# the guard exists to stop guessing. It also round-trips through Test-MpClassify, so a repair that does not
# actually satisfy the gate it was written for cannot pass.
if (Use-Unit 'u083-n4-multipack-size-repair') {
$r = RunPS 'repair-multipack-sizes.ps1' @('-SelfTest')
if ($r.rc -eq 0 -and $r.text -match 'SELFTEST: all') { Ok ('multipack size repair self-test: ' + (($r.text -split "`n" | Where-Object { $_ -match 'SELFTEST: all' }) -join '')) }
else { Bad ('multipack size repair self-test FAILED: ' + $r.text) }
} # u083-n4-multipack-size-repair
# MUST FIRE: a repair that writes a size guard 5 still rejects is decoration. Pinned as a pair here as well
# as inside the self-test, because THIS suite is what runs daily.
. (Join-Path $root 'multipack-lib.ps1')
if (Use-Unit 'u083-n4-multipack-size-repair') {
$mpBad = 'Heinz Tomato Ketchup, 2 Pack 50.5 Oz'
$mpFix = Get-MpRepairedSize $mpBad '50.5 oz'
if ((Test-MpClassify 'Family Fare' $mpBad '50.5 oz' @()) -eq 'reject' -and $mpFix -eq '2 pk 50.5 oz' -and (Test-MpClassify 'Family Fare' $mpBad $mpFix @()) -ne 'reject') {
  Ok 'multipack repair and guard 5 agree: the rejected row repairs, and the repaired row passes'
} else { Bad ('the repair and the guard have drifted apart - repaired size was [' + $mpFix + ']') }
} # u083-n4-multipack-size-repair

# ---------------------------------------------------------------- N5. rule-batch gate (apply-coverage-batch)
# MUST FIRE, and it is a source scan because the bug is an ORDERING one that a unit test cannot see.
# The theft baseline used to be whatever comparison-<date>.json happened to be on disk. Store pulls run on
# their own schedules, so any feed refreshed since that file was written appears as a moved cell the moment
# compare-deals runs again - and verify-no-regression blames the batch. MEASURED 2026-08-01: with the rule
# edit fully REVERTED and nothing changed at all, the check still reported 6 moved Family Fare cells
# (coffee-creamer, english-muffins, ground-cinnamon, honey, hot-dogs, pepperoni) and 3 gained ones, purely
# because a Family Fare pull had landed after the board file was written. A one-word exclude on dried-thyme
# cannot move pepperoni. It is invisible at crown level too - none of the six held a crown - so a crown diff
# reports "0 changed" and looks clean. Any batch run in that window was auto-reverted on merit it never
# lacked, which is the same shape as the visibility gate that had to be rebuilt twice.
if (Use-Unit 'u084-n5-rule-batch-gate-apply-coverage') {
$acbSrc = Get-Content (Join-Path $root 'apply-coverage-batch.ps1') -Raw
$acbRebuildAt = $acbSrc.IndexOf('rebuilding the board under the CURRENT rules')
$acbFreezeAt  = $acbSrc.IndexOf('$baseCmp = Join-Path $OutDir ''_baseline-batch.json''')
if ($acbRebuildAt -gt 0 -and $acbFreezeAt -gt $acbRebuildAt) { Ok 'rule-batch gate rebuilds the board BEFORE freezing its theft baseline (a stale baseline reverts correct work)' }
else { Bad 'apply-coverage-batch freezes a theft baseline it did not just rebuild - an unrelated feed refresh will be blamed on the batch and revert it' }
# MUST FIRE: an empty batch would run every gate and prove nothing.
$r = RunPS 'apply-coverage-batch.ps1' @()
if ($r.rc -eq 1 -and $r.text -match 'empty batch would run every gate') { Ok 'rule-batch gate refuses an empty batch instead of reporting a clean run over nothing' }
else { Bad ('apply-coverage-batch accepted an empty batch (rc=' + $r.rc + '): ' + $r.text) }
# MUST FIRE, cheaply and BEFORE the expensive baseline rebuild: a pattern that does not compile matches
# nothing, so the batch would read as "bought nothing" rather than "was never a rule". Same family as a
# typo'd commodity id, which is checked beside it.
$acbBadRx = & powershell -NoProfile -ExecutionPolicy Bypass -Command "& { `$ErrorActionPreference='Continue'; & '$(Join-Path $root 'apply-coverage-batch.ps1')' -Excludes @{ 'dried-thyme' = @('local(\s+roots') } 2>&1 | Out-String; exit `$LASTEXITCODE }"
if ($LASTEXITCODE -eq 1 -and $acbBadRx -match 'not a valid regex' -and $acbBadRx -notmatch 'rebuilding the board') {
  Ok 'rule-batch gate rejects an uncompilable pattern BEFORE it spends a compare-deals on it'
} else { Bad ('apply-coverage-batch let an uncompilable pattern through, or only caught it after the baseline rebuild: ' + $acbBadRx) }
$acbBadId = & powershell -NoProfile -ExecutionPolicy Bypass -Command "& { `$ErrorActionPreference='Continue'; & '$(Join-Path $root 'apply-coverage-batch.ps1')' -Excludes @{ 'no-such-commodity-xyz' = @('foo') } 2>&1 | Out-String; exit `$LASTEXITCODE }"
if ($LASTEXITCODE -eq 1 -and $acbBadId -match 'can never fire') { Ok 'rule-batch gate rejects a batch on a commodity id that does not exist' }
else { Bad ('apply-coverage-batch accepted a non-existent commodity id: ' + $acbBadId) }
# MUST FIRE: the batch's link repair must not reach past the commodities it edited. Called in bulk,
# resolve-hyvee-links rewrote every Hy-Vee link on the board as a side effect of a ONE-commodity exclude and
# re-introduced the poultry-seasoning divergence, failing the publish on a row the batch never touched.
$acbSrcHv = [regex]::Match($acbSrc, "resolve-hyvee-links\.ps1'\)\s*@hvArgs")
if ($acbSrcHv.Success -and $acbSrc -match '\$hvArgs = @\{ Ids = @\(\$TouchedIds\) \}') { Ok 'rule-batch link repair calls resolve-hyvee-links SCOPED to the batch, not in bulk' }
else { Bad 'apply-coverage-batch runs a BULK resolve-hyvee-links in its repair chain again - a one-commodity edit will rewrite every Hy-Vee link' }
} # u084-n5-rule-batch-gate-apply-coverage

# ---------------------------------------------------------------- N10. sample scope (C3)
# MUST FIRE: a STORE-SCOPED verification draw and a WHOLE-BOARD draw sample different populations, and
# pooling them yields a number that describes neither. Measured the first time a scoped sample was recorded
# (Aldi+Fareway, 2026-08-01): it pooled straight into the previous whole-board run and reported 14 defects -
# Sam's Club, Hy-Vee, Family Fare and Walmart cells among them - against a 760-cell Aldi+Fareway
# denominator. A numerator drawn from outside its own denominator is not a rate.
if (Use-Unit 'u085-n10-sample-scope-c3') {
$vsSrc = Get-Content (Join-Path $root 'build-verification-sample.ps1') -Raw
if ($vsSrc -match 'store_scope\s*=') { Ok 'verification sample records WHICH population it estimates (store scope)' }
else { Bad 'build-verification-sample no longer records store_scope - a scoped draw will pool into a whole-board one and quote a rate for neither' }
$rsSrc = Get-Content (Join-Path $root 'record-sample-verdict.ps1') -Raw
if ($rsSrc -match 'DROPPED ' -and $rsSrc -match 'RunScope' -and $rsSrc -match '\$scopeWanted') {
  Ok 'verdict recorder pools only same-population runs and NAMES the ones it drops'
} else { Bad 'record-sample-verdict pools runs of different store scope again - it will average a scoped sample into a whole-board one' }
# and the live history must not contain a run with no scope recorded (LIVE-TWIN: the banked history is the subject)
$vhP = Join-Path $root 'out\verification-history.json'
if (Test-Path $vhP) {
  $vh = $null; try { $vh = ((Read-TextFile $vhP) + '').Trim() | ConvertFrom-Json } catch {}
  $noScope = @(@($vh.runs) | Where-Object { -not ($_.PSObject.Properties['store_scope']) })
  if ($noScope.Count -eq 0) { Ok 'every banked verification run declares the population it estimates' }
  else { Bad ('verification history holds ' + $noScope.Count + ' run(s) with no store_scope - they will pool with anything') }
}
} # u085-n10-sample-scope-c3

# ---------------------------------------------------------------- N9. public feeds are BOM-less (L7)
# Set-Content -Encoding UTF8 emits a UTF-8 BOM in PS 5.1. Browsers strip it per spec, so the live page was
# never broken - but PS 5.1's OWN ConvertFrom-Json chokes on it, which is how a verification pass reported
# the public feed "malformed" when it was fine and spent the morning on a non-bug. Our own tooling must be
# able to read what we publish. Source-scanned because the live files only lose their BOM on the next
# publish, so a file check would fail for a day and then pass for the wrong reason.
if (Use-Unit 'u086-n9-public-feeds-are-bom-less-l7') {
foreach ($bw in @(
    @{ f = 'grocery\build-deals-page.ps1'; n = 'price-history.json'; pat = '\[IO\.File\]::WriteAllText\(\$histOut' }
    @{ f = 'grocery\build-deals-page.ps1'; n = 'board.json'; pat = '\[IO\.File\]::WriteAllText\(\$boardOut' }
    @{ f = 'grocery\export-feed.ps1'; n = 'smp-feed.json'; pat = "\[IO\.File\]::WriteAllText\(\(Join-Path \`$pub 'smp-feed\.json'\)|Write-TcAtomicFile -Path \`$pubFeedPath -Text \`$json -NoBom" }
    @{ f = 'meal-prep\rotate-free-dinners.ps1'; n = 'free-dinners.json'; pat = "\[IO\.File\]::WriteAllText\(\(Join-Path \`$pubDir 'free-dinners\.json'\)" }
  )) {
  $bwTxt = Get-Content (Join-Path (Split-Path $root -Parent) $bw.f) -Raw
  if ($bwTxt -match $bw.pat) { Ok ('public feed ' + $bw.n + ' is written BOM-less (PS 5.1 cannot parse its own BOM)') }
  else { Bad ('public feed ' + $bw.n + ' is back on Set-Content -Encoding UTF8, which writes a BOM our own ConvertFrom-Json cannot read') }
}
} # u086-n9-public-feeds-are-bom-less-l7

# ---------------------------------------------------------------- N8. multi-term search (F3)
# 210 of 429 commodities have a Family Fare product name that does not contain our single search term, so
# one term per commodity is structurally unable to reach them. commodity-search.json now allows an ARRAY.
# THE WHOLE DANGER IS THAT AN ARRAY DOES NOT FAIL, IT JOINS: `[string]$_.Value` turns
# ["popsicles","ice pops"] into the one search "popsicles ice pops", which matches nothing while looking
# exactly like an ordinary term that found nothing - and 23 scripts read that file.
. (Join-Path $root 'search-terms-lib.ps1')
if (Use-Unit 'u087-n8-multi-term-search-f3') {
$stFix = [pscustomobject]@{ 'popsicles' = @('popsicles', 'ice pops'); 'apples' = 'apples'; 'empty-one' = ''; 'dead-array' = @('', '  ') }
$stPairs = @(Get-SearchTermPairs $stFix)
if (@($stPairs | Where-Object { $_.id -eq 'popsicles' }).Count -eq 2 -and @($stPairs | Where-Object { $_.id -eq 'apples' }).Count -eq 1) {
  Ok 'search terms: an array expands to real separate searches and a plain string still yields exactly one'
} else { Bad ('search-term expansion is wrong - a multi-term commodity is not producing separate searches: ' + (($stPairs | ForEach-Object { $_.id + '=' + $_.term }) -join '; ')) }
if (@($stPairs | Where-Object { $_.id -eq 'empty-one' -or $_.id -eq 'dead-array' }).Count -eq 0) { Ok 'search terms: an empty term produces NO search rather than a blank one that would match the whole catalogue' }
else { Bad 'an empty search term is being issued as a real search' }
# MUST FIRE: the primary term is what every single-string consumer gets, and it must be the FIRST one, so
# a chip q= or a worklist label is identical to what it was before arrays existed.
if ((Get-PrimarySearchTerm $stFix 'popsicles') -eq 'popsicles' -and (Get-PrimarySearchTerm $stFix 'apples') -eq 'apples' -and (Get-PrimarySearchTerm $stFix 'nope') -eq '') {
  Ok 'search terms: single-string consumers get the FIRST term, never the joined one, and a missing id yields empty'
} else { Bad 'Get-PrimarySearchTerm is not returning the stable first term - single-term consumers will search a joined string' }
# MUST FIRE, and this is the one that matters: NO consumer may still cast the terms object to a string.
# That cast is silent, so nothing downstream could ever report it.
# CODE LINES ONLY. The comments that explain this trap quote the offending cast verbatim, so a whole-file
# regex flags the very files that fixed it - a scan that cannot tell an explanation from an instance.
$stOffenders = @()
foreach ($sf in (Get-ChildItem (Join-Path $root '*.ps1') -File)) {
  if ($sf.Name -eq 'search-terms-lib.ps1' -or $sf.Name -eq 'test-auditors.ps1') { continue }
  $sTxt = Get-Content $sf.FullName -Raw
  if ($sTxt -notmatch 'commodity-search\.json') { continue }
  # PRODUCTION STATEMENTS ONLY (queue 2026-09-11-220094), for the same reason the comment filter exists: a
  # fixture frozen inside a guard's own -SelfTest block quotes the cast to prove it is refused.
  $bad = @(@(Get-TcProductionLines -Path $sf.FullName | ForEach-Object { [string]$_.text }) | Where-Object {
      $ln = $_.Trim()
      if ($ln.StartsWith('#')) { return $false }
      ($ln -match '\[string\]\$p\.Value' -and $ln -match '\$term') -or ($ln -match '\[string\]\$terms\.\$id') -or ($ln -match '\[string\]\$_\.Value' -and $ln -match '\$term')
    })
  if ($bad.Count) { $stOffenders += ($sf.Name + ' (' + $bad.Count + ')') }
}
if ($stOffenders.Count -eq 0) { Ok 'search terms: no consumer of commodity-search.json casts a term value to a string (an array would JOIN, not fail)' }
else { Bad ('these readers of commodity-search.json still flatten a term value, so a multi-term commodity becomes one dead search: ' + ($stOffenders -join ', ')) }
# the live file must stay usable by the lib
$stLive = (Read-JsonFile (Join-Path $root 'commodity-search.json')).terms
$stLiveFindings = @(Test-SearchTermShape $stLive)
if ($stLiveFindings.Count -eq 0) { Ok 'search terms: the live commodity-search.json has no empty terms and no degenerate arrays' }
else { Bad ('commodity-search.json shape findings: ' + ($stLiveFindings -join ' | ')) }
} # u087-n8-multi-term-search-f3

# ---------------------------------------------------------------- N7. the coverage ratchet's own config
# F4 asked for tolerances narrowed "from the week's accumulated ledger data" and there WAS none - the ledger
# is a single overwritten snapshot, so every tolerance had been hand-seeded from one green run with no
# reason recorded. These pin the three defects that turned up while looking.
if (Use-Unit 'u088-n7-the-coverage-ratchet-s-own-config') {
$fxCl = Register-Fx (Join-Path $env:TEMP ('taudit-cl-' + [guid]::NewGuid().ToString('N').Substring(0, 8)))
New-Item -ItemType Directory -Path $fxCl -Force | Out-Null
Copy-Item (Join-Path $fix 'coverage-ledger\coverage-ledger.json') $fxCl -Force
$clBase = Join-Path $fxCl 'coverage-baseline.json'
Copy-Item (Join-Path $fix 'coverage-ledger\coverage-baseline.json') $clBase -Force
$r = RunPS 'audit-coverage-ledger.ps1' @('-OutDir', $fxCl, '-BaselineFile', $clBase, '-Phase', 'all')
# MUST FIRE: a tolerance of 1.0 puts the regression floor at 0, and BLIND already owns everything <= 0, so
# REGRESSED can never fire. Two live checks shipped in that state - the gates-that-can-never-arm class.
if ($r.text -match 'DEAD-RATCHET\s+dead-ratchet-check') { Ok 'coverage ratchet reports a tolerance that makes its own REGRESSED verdict structurally unfirable' }
else { Bad ('a dead ratchet (tolerance 1.0, floor 0) passed as ok: ' + $r.text) }
# MUST FIRE: an override with no reason cannot be reviewed or narrowed later, which is exactly why F4 had
# nothing to narrow FROM.
if ($r.text -match 'UNJUSTIFIED TOLERANCE: unjustified-check') { Ok 'coverage ratchet reports a tolerance override that records no reason' }
else { Bad ('an undocumented tolerance override passed silently: ' + $r.text) }
# MUST FIRE: -Accept must RAISE only. Lowering on one bad run makes the rows it stopped looking at
# unguarded forever - it would have baked in audit-ff-carry at 40 against a 464 baseline (91% lost).
$r2 = RunPS 'audit-coverage-ledger.ps1' @('-OutDir', $fxCl, '-BaselineFile', $clBase, '-Phase', 'all', '-Accept')
$clAfter = ((Read-TextFile $clBase) + '').Trim() | ConvertFrom-Json
if ([int]$clAfter.checks.'shrunk-check'.examined -eq 1000 -and $r2.text -match 'KEPT HIGH') {
  Ok '-Accept RAISES the coverage ratchet but refuses to lower it, and names the rows it kept high'
} else { Bad ('-Accept silently lowered a high-water mark - the coverage it stopped watching is now unguarded forever: ' + [string]$clAfter.checks.'shrunk-check'.examined) }
# ...and -AcceptLower is the explicit way to do it on purpose.
$r3 = RunPS 'audit-coverage-ledger.ps1' @('-OutDir', $fxCl, '-BaselineFile', $clBase, '-Phase', 'all', '-Accept', '-AcceptLower')
$clAfter2 = ((Read-TextFile $clBase) + '').Trim() | ConvertFrom-Json
if ([int]$clAfter2.checks.'shrunk-check'.examined -eq 40 -and $r3.text -match 'LOWERED') { Ok '-AcceptLower lowers the ratchet deliberately and says which rows it moved down' }
else { Bad '-AcceptLower did not lower the baseline, so a real permanent drop can never be accepted' }
} # u088-n7-the-coverage-ratchet-s-own-config

# ---- -Check: lowering ONE row by name (2026-09-01) -------------------------------------------------
# WHY THIS EXISTS. audit-everyday-mismatch's floor sat 12.5% above its real population for ten days
# with the cause proved and written down, because -AcceptLower was all-or-nothing: settling that one
# row meant also dropping five rows that were NOT in breach to their own current counts. The baseline's
# own note said "Accept it the day the tool can lower ONE check by name." A SECOND dropped row is
# injected here on purpose - the shipped fixture has only one, and a scope test with nothing to spare
# cannot tell scoping from a plain accept.
if (Use-Unit 'u089-check-lowering-one-row-by-name') {
$fxCk = Register-Fx (Join-Path $env:TEMP ('taudit-ck-' + [guid]::NewGuid().ToString('N').Substring(0, 8)))
New-Item -ItemType Directory -Path $fxCk -Force | Out-Null
Copy-Item (Join-Path $fix 'coverage-ledger\coverage-ledger.json') $fxCk -Force
$ckBase = Join-Path $fxCk 'coverage-baseline.json'
Copy-Item (Join-Path $fix 'coverage-ledger\coverage-baseline.json') $ckBase -Force
$ckLed = Join-Path $fxCk 'coverage-ledger.json'
$ckB = Read-JsonFile $ckBase
$ckL = Read-JsonFile $ckLed
$ckB.checks | Add-Member -NotePropertyName 'other-shrunk' -NotePropertyValue ([pscustomobject]@{ examined = 800; tolerance = 0.10; max_age_days = 99; phase = 'all'; why = 'second dropped row, so the scope has something to spare' }) -Force
$ckL.checks | Add-Member -NotePropertyName 'other-shrunk' -NotePropertyValue ([pscustomobject]@{ examined = 100; eligible = 100; skipped = 0; blind = $false; as_of = ([string]$ckL.checks.'shrunk-check'.as_of); detail = 'second dropped row' }) -Force
$ckB | ConvertTo-Json -Depth 12 | Set-Content $ckBase -Encoding utf8
$ckL | ConvertTo-Json -Depth 12 | Set-Content $ckLed  -Encoding utf8

# A TYPO MUST NOT READ AS A CAREFUL SCOPED ACCEPT THAT CHANGED NOTHING.
# rc 3 is COULD NOT EVALUATE, which is what a refused argument is - it evaluated nothing. rc 2 in this
# auditor means "findings, gated", and using it here also made audit-guard-contract report the file
# HALF-COVERED, because a verdict exit must carry the completion marker and a refusal must not.
$rc1 = RunPS 'audit-coverage-ledger.ps1' @('-OutDir', $fxCk, '-BaselineFile', $ckBase, '-Phase', 'all', '-Accept', '-AcceptLower', '-Check', 'shrunk-checkk')
$ckT = Read-JsonFile $ckBase
if ($rc1.rc -eq 3 -and $rc1.text -match 'does not carry' -and [int]$ckT.checks.'shrunk-check'.examined -eq 1000) {
  Ok '-Check refuses a name the baseline does not carry, and writes nothing'
} else { Bad ('-Check accepted an unknown name (rc=' + $rc1.rc + '), so a typo reads as a scoped accept that silently moved no floor') }

# -Check ALONE does nothing, and saying so beats half-applying an intent.
$rc2 = RunPS 'audit-coverage-ledger.ps1' @('-OutDir', $fxCk, '-BaselineFile', $ckBase, '-Phase', 'all', '-Accept', '-Check', 'shrunk-check')
if ($rc2.rc -eq 3 -and $rc2.text -match 'scopes -AcceptLower') { Ok '-Check without -AcceptLower is refused rather than silently ignored' }
else { Bad ('-Check without -AcceptLower was accepted (rc=' + $rc2.rc + '), so a scope can be typed and quietly not applied') }

# THE POINT OF THE WHOLE FEATURE: one row down, the other still defended.
$rc3 = RunPS 'audit-coverage-ledger.ps1' @('-OutDir', $fxCk, '-BaselineFile', $ckBase, '-Phase', 'all', '-Accept', '-AcceptLower', '-Check', 'shrunk-check')
$ckA = Read-JsonFile $ckBase
if ([int]$ckA.checks.'shrunk-check'.examined -eq 40 -and [int]$ckA.checks.'other-shrunk'.examined -eq 800) {
  Ok '-Check lowers ONLY the named row and leaves every other dropped floor defended'
} else { Bad ('-Check did not scope the lowering: shrunk-check=' + [string]$ckA.checks.'shrunk-check'.examined + ' other-shrunk=' + [string]$ckA.checks.'other-shrunk'.examined) }
# AND THE LABEL MUST MATCH THE ROW. The first cut printed LOWERED against every breached row while its
# own HELD lines said otherwise - a report contradicting itself, and the half naming numbers is the
# half a reader believes.
if ($rc3.text -match 'HELD\s+other-shrunk' -and $rc3.text -notmatch 'LOWERED\s+other-shrunk') {
  Ok '-Check reports the spared row as HELD and never labels it LOWERED'
} else { Bad 'the scoped accept labelled a row it did not touch as LOWERED' }
Remove-Item $fxCk -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $fxCl -Recurse -Force -ErrorAction SilentlyContinue
} # u089-check-lowering-one-row-by-name

# ---------------------------------------------------------------- N6. Hy-Vee link price provenance
# MUST FIRE: the link's stored price must be the one the BOARD priced, never the search endpoint's.
# Hy-Vee publishes several prices per product and only Omaha #01's is the one it charges - the whole reason
# pull-regular-hyvee exists - and resolve-hyvee-links was stamping the SEARCH API's tagPriceValue beside the
# link. Measured on poultry-seasoning, the row that re-introduced the consistency divergence THREE times and
# was written off as an unexplained "quality problem": right product (Morton & Bassett, 2.1 oz, same name and
# size the board holds), stamped $9.99 while the feed the board priced says $5.81. 9.99/2.1 = $4.7571/oz vs
# 5.81/2.1 = $2.7667/oz, and guard 1 hard-failed the publish at 1.72x. Nothing was wrong with the MATCH.
# It survived because the match gate accepts price agreement OR an overwhelming name match, so an identical
# name lets a disagreeing price straight through unchecked.
if (Use-Unit 'u090-n6-hy-vee-link-price-provenance') {
$rhvSrc = Get-Content (Join-Path $root 'resolve-hyvee-links.ps1') -Raw
if ($rhvSrc -match '\$price = if \(\$ourPrice -gt 0\) \{ \$ourPrice \}' -and $rhvSrc -notmatch '(?m)^\s*\$price = \[double\]\$best\.pricing\.tagPriceValue\s*$') {
  Ok 'resolve-hyvee-links stores the price the BOARD priced, not the search endpoint''s (the poultry-seasoning root cause)'
} else { Bad 'resolve-hyvee-links is stamping the search API price beside a link again - that is the wrong one of Hy-Vee''s several prices and it hard-fails the factor guard' }
} # u090-n6-hy-vee-link-price-provenance

# ---------------------------------------------------------------- (u) store-taxonomy: the second opinion
# The ONLY watcher that does not inherit the include regex's premise. Its founding bug is the class that
# produced 47 of the 99 wrong numbers in 22 days: Family Fare's own catalogue files "Blue Buffalo Natural
# Puppy Chicken And Brown Rice Recipe Food For Puppies" under pets_wildlife/dog/dry_dog_food while our
# brown-rice include claims it is brown rice. Its fixtures are frozen strings from 2026-07-30 and must never
# be regenerated from a later board.
if (Use-Unit 'u091-u-store-taxonomy-the-second-opinion') {
$r = RunPS 'audit-store-taxonomy.ps1' @('-SelfTest')
if ($r.rc -eq 0 -and $r.text -match 'MUST-FIRE' -and $r.text -match 'SELF-TEST PASS') { Ok 'store-taxonomy -SelfTest passes with its founding-bug fixtures armed' }
else { Bad ('store-taxonomy -SelfTest failed or lost its founding-bug fixtures: ' + ((($r.text -split "`n") | Select-Object -Last 3) -join ' | ')) }
$stSrc = Get-Content (Join-Path $root 'audit-store-taxonomy.ps1') -Raw
if ($stSrc -match 'blue_buffalo_natural_puppy') { Ok 'the Blue Buffalo dog-food-as-brown-rice row is still the must-fire fixture' }
else { Bad 'store-taxonomy lost its Blue Buffalo fixture - the wrong-product class it was written for is no longer proven catchable' }
if ($stSrc -match 'kraft_grated_cheese_parmesan_cheese_8_oz') { Ok 'the taxonomy-less-URL trap (3 live rows) is still pinned - a slug must never be read as a department' }
else { Bad 'store-taxonomy lost the taxonomy-less-URL fixture - it can invent a department for a row that carries none' }
} # u091-u-store-taxonomy-the-second-opinion

# ---------------------------------------------------------------- (u2) ff-carry: the fixtures nobody could reach
# 2026-07-31. audit-ff-carry got a full frozen fixture block (own-feed-coverage MUST-FIRE/CLEAN-TWIN, plus the
# multi-buy cheapest-pick pair) guarded by `if ($SelfTest)` - and the matching `[switch]$SelfTest` never landed
# on its param(). $SelfTest was permanently $null, so the block was unreachable dead code. Worse, under -File
# an undeclared -SelfTest does NOT error (it lands in $args), so `audit-ff-carry.ps1 -SelfTest` quietly ran the
# LIVE network audit and looked like it worked. Second half of the same bug: the pull-state early exits sat
# ABOVE the block, so even once reachable, a -SelfTest run on a day with no FF file - or no empty terms, the
# HEALTHY state - printed SKIP/OK and exited 0 having executed zero fixtures.
# Both halves are checked structurally BEFORE invoking, because the invocation alone cannot tell the
# difference between "fixtures passed" and "fixtures were skipped" if the script regresses to exiting early.
if (Use-Unit 'u092-u2-ff-carry-the-fixtures-nobody') {
$ffcS = Get-Content (Join-Path $root 'audit-ff-carry.ps1') -Raw
if ($ffcS -match '\[switch\]\$SelfTest') { Ok 'audit-ff-carry declares [switch]$SelfTest (its fixture block is reachable at all)' }
else { Bad 'audit-ff-carry has an if ($SelfTest) block with no [switch]$SelfTest on param() - the fixtures are dead code again, and -SelfTest silently runs the LIVE audit instead of erroring' }
$ffcSelfIdx = $ffcS.IndexOf('if ($SelfTest) {')
$ffcGateIdx = $ffcS.IndexOf('ff-carry: SKIP (no FF regular file)')
if ($ffcSelfIdx -ge 0 -and $ffcGateIdx -ge 0 -and $ffcGateIdx -lt $ffcSelfIdx -and $ffcS -notmatch 'if \(-not \$SelfTest\) \{') {
  Bad 'audit-ff-carry pull-state exits are back above its fixture block and no longer skipped under -SelfTest - a self-test run on a healthy day exits 0 without running one fixture'
} else { Ok 'audit-ff-carry skips its pull-state exits under -SelfTest (fixtures run in every data state)' }
# Hermetic: -OutDir points at an empty scratch dir, so a PASS here proves the fixtures ran WITHOUT an FF file
# present. That is precisely the state that used to fake a pass, so it doubles as the regression test.
$ffcOut = Register-Fx (Join-Path $env:TEMP ('ffc-selftest-' + [guid]::NewGuid().ToString('N').Substring(0,8)))
$null = New-Item -ItemType Directory -Path $ffcOut -Force
$r = RunPS 'audit-ff-carry.ps1' @('-SelfTest', '-OutDir', $ffcOut)
if ($r.rc -eq 0 -and $r.text -match 'SELF-TEST PASS') { Ok 'ff-carry -SelfTest passes with NO FF file present (fixtures are data-state independent)' }
else { Bad ('ff-carry -SelfTest failed or skipped with no FF file: rc=' + $r.rc + ' ' + ((($r.text -split "`n") | Select-Object -Last 3) -join ' | ')) }
if ($ffcS -match 'Our Family Chili Beans') { Ok 'the chili-beans own-feed-coverage fixture is still armed (the 15-of-24 false-positive class)' }
else { Bad 'ff-carry lost its chili-beans fixture - the "already priced in this very pull" false-positive class is no longer proven catchable' }
if ($ffcS -match '4 for \$5\.00') { Ok 'the multi-buy cheapest-pick fixture is still armed ("4 for $5.00" must not read as 45)' }
else { Bad 'ff-carry lost the multi-buy fixture - the digit-stripping bug that made $5.00 look like $45 is unguarded' }

# THE ZERO-PROBE FALSE OK (2026-07-31, caught live). Every Freshop call sits in an empty catch, so a
# throttled window returns nothing for all of them, $victims stays empty, and ff-carry printed the same
# confident "OK no term is missing from the feed" as a run that really checked 123 terms. Observed:
# "ff-carry: OK ... (0 of 466 empty term(s) re-probed)" exit 0, with the coverage ledger beside it saying
# BLIND. It now exits 3 instead. Two things can rot: the gate keying off the WRONG count, and the caller
# re-flattening exit 3 into a crash report. Both are source checks - the behaviour needs a throttled
# Freshop, which cannot be summoned on demand and must never be faked by hitting the live API harder.
$ffcOkIdx = $ffcS.IndexOf('ff-carry: OK  no term is missing')
$ffcBlindIdx = $ffcS.IndexOf('$attempted -gt 0 -and $probed -eq 0')
if ($ffcBlindIdx -ge 0 -and $ffcOkIdx -ge 0 -and $ffcBlindIdx -lt $ffcOkIdx) { Ok 'ff-carry refuses to print OK when Freshop answered none of the terms it needed to probe (exit 3, blind)' }
else { Bad 'ff-carry no longer gates its OK line on having actually probed something - a fully throttled run reads as a clean bill of health again (the 2026-07-31 zero-probe false OK)' }
if ($ffcS -match '\$attempted\s*=\s*\$emptyTerms\.Count\s*-\s*\$suppressed') { Ok 'ff-carry measures blindness against terms it actually had to probe, not the raw empty-term count' }
else { Bad 'ff-carry blindness is no longer keyed on $emptyTerms.Count - $suppressed - a pull that legitimately suppressed every term will now be reported blind (cry-wolf) or a real blind run missed' }
if ($cacSrc -match '\$fcRc -eq 3') { Ok 'check-ad-cycles reports an ff-carry could-not-evaluate separately from a crash' }
else { Bad 'check-ad-cycles has no $fcRc -eq 3 branch - a blind-but-healthy ff-carry is logged as "DID NOT RUN ... see stderr" and points the reader at an empty stderr' }
} # u092-u2-ff-carry-the-fixtures-nobody
