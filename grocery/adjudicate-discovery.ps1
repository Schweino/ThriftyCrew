<#
  adjudicate-discovery.ps1 - THE ONE COMMAND that turns a discovery candidate into a decision.

  WHY THIS EXISTS. `discover-hyvee.ps1` gives Hy-Vee its first discovery path and writes a docket, because
  Hy-Vee publishes NO per-product department and the CATEGORY facet its search exposes is SILENTLY IGNORED
  when passed back as a filter (three request shapes, all returned the identical unfiltered results with a
  cat litter still sitting in "baking soda"). A filter that looks applied and is not is worse than none, so
  discovery stops at a docket. But a docket nobody can rule on pays NOTHING: the first live run found
  That's Smart! peanut butter 33.4% under the held Hy-Vee price and ketchup 29% under, and those findings
  sat in a JSON file that no script read. This is the reader.

  THE REVIEW HAS TO ASSUME 1 IN 7 IS WRONG. That is measured, not cautious: the same first run surfaced a
  Hendrickson's Sweet Vinegar & Olive Oil DRESSING and a Pasta Roni Garlic & Olive Oil VERMICELLI, both
  matching the olive-oil include and both beating the held price - ~14%, the same rate the Family Fare
  browse test produced. So every rule below is built for a docket that is one-seventh wrong:

    * NOTHING IS BULK. There is no -All and no -AcceptRemaining. One key, one ruling, one reviewer, one
      reason. A bulk verb is how a 14% error rate gets rubber-stamped in a single keystroke.
    * ACCEPT DOES NOT PRICE ANYTHING. It appends the product to hyvee-catalog-adds.json, which is a WORK
      LIST for pull-regular-hyvee.ps1 - the price is then fetched from Hy-Vee's own API, the size is
      derived on the never-priced-before path every new product takes, and compare-deals decides whether
      it wins anything. An accepted product that takes a cell becomes an ARRIVAL, so it lands right back on
      the arrivals desk in front of the cohort-divergence check that caught the bath soap and the cat food.
      Acceptance routes a candidate INTO the estate's review, not around it.
    * ACCEPT IS REFUSED WHEN THE SAVING IS AN ARTEFACT. If the candidate's size names a different kind of
      quantity than the commodity is priced in, the "beats by X%" that justified the review is arithmetic,
      not money (4.6 WEIGHT ounces divided as fluid ounces). That refusal is overridable, but only with
      -AcceptDespiteBasis and a reason, on the record.
    * REJECT IS ENFORCED, NOT FILED. It delegates to add-known-wrong.ps1, so compare-deals refuses to price
      that (commodity, store, product) at all. A ruling the pipeline cannot read is not a ruling - honeydew
      was written up in prose on 2026-07-29 and was still the published crown the next morning.
    * A RULED CANDIDATE NEVER COMES BACK. Both verdicts land in discovery-verdicts.json, which
      discover-hyvee.ps1 and build-arrivals-docket.ps1 both consult. A queue that re-asks a settled
      question teaches its reader to skim, and a skimmed queue is the same as no queue.

  NOTHING HERE IS REVERSIBLE BY DELETION, by design. An accept that turns out wrong is retired the normal
  way - add-known-wrong.ps1 on the product - and the ledger keeps the original ruling so the mistake is
  auditable. Deleting entries is how a gate gets quietly made green.

  Usage:
    .\adjudicate-discovery.ps1 -List
    .\adjudicate-discovery.ps1 -Key hyvee|peanut-butter|2970357 -Accept -RuledBy brad `
        -Evidence "That's Smart! is Hy-Vee's value label. 40 oz creamy peanut butter, $3.98. Real product."
    .\adjudicate-discovery.ps1 -Key hyvee|olive-oil|39221 -Reject -RuledBy brad `
        -Evidence "Pasta Roni VERMICELLI - a boxed pasta side, not olive oil. Matched the include on 'olive oil'."
    .\adjudicate-discovery.ps1 -SelfTest
#>
param(
  [string]$Key = '',
  [switch]$Accept,
  [switch]$Reject,
  [string]$RuledBy = '',
  [string]$Evidence = '',
  [switch]$AcceptDespiteBasis,
  [switch]$List,
  [switch]$DryRun,
  [switch]$SelfTest,
  [string]$Root = '',
  [string]$DiscoveryFile = '',
  [string]$VerdictsFile = '',
  [string]$CatalogFile = ''
)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
if (-not $Root) { $Root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path } }
$outDir = Join-Path $Root 'out'
if (-not $DiscoveryFile) { $DiscoveryFile = Join-Path $outDir 'hyvee-discovery.json' }
if (-not $VerdictsFile)  { $VerdictsFile  = Join-Path $Root 'discovery-verdicts.json' }
if (-not $CatalogFile)   { $CatalogFile   = Join-Path $Root 'hyvee-catalog-adds.json' }
. (Join-Path $Root 'discovery-lib.ps1')
. (Join-Path $Root 'native-lib.ps1')   # Invoke-Native: a native child's stderr under EAP=Stop is TERMINATING, and `2>&1`/`2>$null` CAUSE that (native-lib.ps1)

function Die([string]$m) { Write-Output ('adjudicate-discovery: ' + $m); exit 1 }

function Read-JsonDoc {
  param([string]$Path, [string]$What)
  # ((Get-Content -Raw) + '') because [string]$null is $null so .Trim() on a zero-byte file THROWS, and
  # '' | ConvertFrom-Json returns $null WITHOUT throwing.
  if (-not (Test-Path $Path)) { Die ($What + ' not found: ' + $Path) }
  $raw = ((Get-Content -LiteralPath $Path -Raw -Encoding UTF8) + '').Trim()
  if ($raw -eq '') { Die ($What + ' is EMPTY on disk: ' + $Path + ' - restore it from git rather than writing into it') }
  $d = $raw | ConvertFrom-Json
  if ($null -eq $d) { Die ($What + ' parsed to null: ' + $Path) }
  return $d
}

function Get-OpenCandidates {
  param([string]$DiscPath, [string]$VerdPath)
  # Returns @{ open = @(...); settled = <int>; total = <int> }. An unreadable docket is an ERROR, never an
  # empty list: "the store found nothing" and "we could not read the file" must not print the same.
  $doc = Read-JsonDoc $DiscPath 'discovery docket'
  $cands = @($doc)
  if ($doc.PSObject.Properties.Name -contains 'candidates') { $cands = @($doc.candidates) }
  $verd = Get-DiscoveryVerdicts $VerdPath
  $open = New-Object 'System.Collections.Generic.List[object]'
  $settled = 0
  foreach ($c in @($cands | Where-Object { $_ })) {
    $k = Get-DiscoveryKey -Store ([string]$c.store) -Commodity ([string]$c.id) -ProductId ([string]$c.product_id) -Product ([string]$c.product)
    if ($verd.ContainsKey($k)) { $settled++; continue }
    $open.Add([pscustomobject]@{ key = $k; cand = $c })
  }
  return @{ open = $open.ToArray(); settled = $settled; total = @($cands).Count }
}

# ------------------------------------------------------------------ SELF-TEST (hermetic; writes to TEMP only)
if ($SelfTest) {
  $f = 0; $p = 0
  function T($cond, $msg) { if ($cond) { Write-Output ('  PASS  ' + $msg); $script:p++ } else { Write-Output ('  FAIL  ' + $msg); $script:f++ } }
  Write-Output 'adjudicate-discovery -SelfTest'

  $tmp = Join-Path $env:TEMP ('adjdisc-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Path $tmp -Force | Out-Null
  $dF = Join-Path $tmp 'disc.json'; $vF = Join-Path $tmp 'verd.json'; $cF = Join-Path $tmp 'cat.json'
  # The founding docket, in miniature: one real find, one wrong product that also carries a false basis.
  @(
    [ordered]@{ id = 'peanut-butter'; store = 'Hy-Vee'; product = "That's Smart! Creamy Peanut Butter"; size = '40 oz'; price = 3.98; per_unit = 0.0995; unit = 'oz'; held_per_unit = 0.1495; beats_by_pct = 33.4; product_id = '2970357' },
    [ordered]@{ id = 'olive-oil'; store = 'Hy-Vee'; product = 'Pasta Roni Garlic & Olive Oil Vermicelli'; size = '4.6 oz'; price = 1.48; per_unit = 0.3217; unit = 'floz'; held_per_unit = 0.4112; beats_by_pct = 21.8; product_id = '39221' }
  ) | ConvertTo-Json -Depth 4 | Set-Content $dF -Encoding UTF8
  '{ "entries": [] }' | Set-Content $vF -Encoding UTF8
  '{ "items": [] }' | Set-Content $cF -Encoding UTF8
  $base = @('-Root', $Root, '-DiscoveryFile', $dF, '-VerdictsFile', $vF, '-CatalogFile', $cF)
  function Run($extra) {
    $rargs = @($base) + @($extra)
    $r = Invoke-NativeScript $PSCommandPath @rargs
    return @{ rc = $r.ExitCode; text = ((@($r.Lines) | Out-String)) }
  }

  # MUST-FIRE 1: the basis artefact. The vermicelli "beats" olive oil only because 4.6 WEIGHT ounces were
  # divided as fluid ounces. Accepting it on that saving must be refused.
  $r = Run @('-Key', 'hyvee|olive-oil|39221', '-Accept', '-RuledBy', 'selftest', '-Evidence', 'pretend a reviewer accepted this on its stated saving')
  T ($r.rc -ne 0 -and $r.text -match 'BASIS') 'MUST-FIRE: accepting a candidate whose saving is a basis artefact is REFUSED'
  T ((Get-Content $cF -Raw) -notmatch '39221') 'MUST-FIRE: the refused accept wrote NOTHING to the catalogue'

  # MUST-FIRE 2: no evidence, no reviewer - a ruling nobody signed is a rule nobody can review.
  $r = Run @('-Key', 'hyvee|peanut-butter|2970357', '-Accept', '-RuledBy', 'selftest', '-Evidence', 'too short')
  T ($r.rc -ne 0 -and $r.text -match 'Evidence') 'MUST-FIRE: a ruling with no real evidence is refused'
  $r = Run @('-Key', 'hyvee|peanut-butter|2970357', '-Accept', '-Evidence', 'a perfectly good long-enough reason for the ruling')
  T ($r.rc -ne 0 -and $r.text -match 'RuledBy') 'MUST-FIRE: a ruling with no named reviewer is refused'

  # MUST-FIRE 3: a key that is not on the docket. A typo makes a ledger entry that can never match a
  # candidate - the permanently-unfirable-entry bug the known-wrong allowlist shipped on 2026-07-30.
  $r = Run @('-Key', 'hyvee|olive-oil|99999999', '-Reject', '-RuledBy', 'selftest', '-Evidence', 'ruling against a key that is not on any docket')
  T ($r.rc -ne 0 -and $r.text -match 'not on the current discovery docket') 'MUST-FIRE: a key absent from the docket is refused, not recorded'

  # MUST-FIRE 4: both verbs, or neither. An ambiguous ruling must never pick a default.
  $r = Run @('-Key', 'hyvee|peanut-butter|2970357', '-Accept', '-Reject', '-RuledBy', 'selftest', '-Evidence', 'contradictory ruling that must not be guessed at')
  T ($r.rc -ne 0) 'MUST-FIRE: -Accept and -Reject together is refused rather than resolved'

  # CLEAN TWIN: the real find goes through, and it writes a WORK LIST entry - not a price, not a board cell.
  $r = Run @('-Key', 'hyvee|peanut-butter|2970357', '-Accept', '-RuledBy', 'selftest', '-Evidence', "That's Smart! is Hy-Vee's own value label; 40 oz creamy peanut butter is the commodity.")
  T ($r.rc -eq 0) 'CLEAN TWIN: a real cheaper product is accepted'
  $catDoc = Read-JsonFile $cF
  T (@($catDoc.items).Count -eq 1 -and [string]$catDoc.items[0].product_id -eq '2970357') 'the accept appended exactly one catalogue work-list entry, keyed by the store product id'
  T (-not ($catDoc.items[0].PSObject.Properties.Name -contains 'price')) 'the catalogue entry carries NO price - the puller fetches it from the store'
  T (-not ($catDoc.items[0].PSObject.Properties.Name -contains 'size')) 'the catalogue entry carries NO size - Hy-Vee''s own size field is not dependable, so the new-product path derives it'

  # SETTLED means settled: the same key cannot be ruled twice, and it drops off the open list.
  $r = Run @('-Key', 'hyvee|peanut-butter|2970357', '-Reject', '-RuledBy', 'selftest', '-Evidence', 'trying to overwrite a ruling that already exists on the record')
  T ($r.rc -ne 0 -and $r.text -match 'already ruled') 'MUST-FIRE: a candidate cannot be ruled twice'
  $r = Run @('-List')
  T ($r.text -match '1 open' -and $r.text -match '1 already ruled') 'the settled candidate leaves the open queue and is counted as ruled'

  # The basis refusal is OVERRIDABLE, on the record - a reviewer who has checked the size may still proceed.
  $r = Run @('-Key', 'hyvee|olive-oil|39221', '-Accept', '-AcceptDespiteBasis', '-RuledBy', 'selftest', '-Evidence', 'reviewer states they checked the size by hand and accept the basis risk knowingly')
  T ($r.rc -eq 0 -and $r.text -match 'BASIS OVERRIDDEN') 'the basis refusal can be overridden explicitly, and says so out loud'
  $vDoc = Read-JsonFile $vF
  T (@($vDoc.entries | Where-Object { [string]$_.key -eq 'hyvee|olive-oil|39221' }).basis_overridden -eq $true) 'the override is recorded in the ledger, not just printed'

  Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
  if ($f -gt 0) { Write-Output ('adjudicate-discovery SELFTEST: ' + $f + ' FAILED'); exit 2 }
  Write-Output ('adjudicate-discovery SELFTEST: all ' + $p + ' passed')
  exit 0
}

# ------------------------------------------------------------------ list
if ($List) {
  $q = Get-OpenCandidates $DiscoveryFile $VerdictsFile
  Write-Output ('discovery docket: ' + $q.total + ' candidate(s) - ' + @($q.open).Count + ' open, ' + $q.settled + ' already ruled')
  Write-Output ('  source: ' + $DiscoveryFile)
  Write-Output ('  ledger: ' + $VerdictsFile)
  if (@($q.open).Count -eq 0) { Write-Output '  nothing awaiting a ruling'; exit 0 }
  Write-Output ''
  Write-Output '  Ranked reading order lives in the arrivals desk (build-arrivals-docket.ps1, PROSPECTS section).'
  Write-Output '  ~1 in 7 of these is a WRONG PRODUCT and none of them was machine-vetted.'
  foreach ($o in $q.open) {
    $c = $o.cand
    $b = Test-DiscoveryBasisSuspect -Size ([string]$c.size) -Unit ([string]$c.unit)
    Write-Output ''
    Write-Output ('  ' + $o.key)
    Write-Output ('      ' + [string]$c.id + '  ' + [string]$c.product + '  [' + [string]$c.size + ' @ $' + ('{0:N2}' -f [double]$c.price) + ']')
    Write-Output ('      $' + ('{0:N4}' -f [double]$c.per_unit) + '/' + [string]$c.unit + ' vs held $' + ('{0:N4}' -f [double]$c.held_per_unit) +
      $(if ($null -ne $c.beats_by_pct) { '  (beats by ' + $c.beats_by_pct + '%)' } else { '  (we hold nothing here)' }))
    if ($b -ne '') { Write-Output ('      BASIS SUSPECT: ' + $b) }
  }
  exit 0
}

# ------------------------------------------------------------------ rule
if ($Accept -and $Reject) { Die 'pass -Accept OR -Reject, never both. An ambiguous ruling must not be resolved by a default.' }
if (-not ($Accept -or $Reject)) { Die 'pass -Accept or -Reject (or -List to see what is open).' }
if (-not $Key) { Die '-Key is required (copy it from the arrivals desk PROSPECTS section or from -List).' }
if (-not $RuledBy) { Die '-RuledBy is required: every ruling names who made it.' }
if (-not $Evidence -or $Evidence.Trim().Length -lt 20) { Die '-Evidence is required and must actually say why (>= 20 chars). A ruling without evidence is a rule nobody can review.' }

$q = Get-OpenCandidates $DiscoveryFile $VerdictsFile
$verd = Get-DiscoveryVerdicts $VerdictsFile
if ($verd.ContainsKey($Key)) {
  $e = $verd[$Key]
  Die ("'" + $Key + "' was already ruled " + [string]$e.verdict + ' on ' + [string]$e.ruled_on + ' by ' + [string]$e.ruled_by +
    ". A ruling is not overwritten. If it was wrong, retire the product through add-known-wrong.ps1 so the reversal itself is on the record.")
}
$hit = @($q.open | Where-Object { $_.key -eq $Key }) | Select-Object -First 1
if (-not $hit) {
  Die ("'" + $Key + "' is not on the current discovery docket (" + $DiscoveryFile + "). A ledger entry keyed to a " +
    "candidate that does not exist can never match anything - that is the permanently-unfirable-entry bug. " +
    "Run -List to see the open keys; if discovery has rotated past this term, the candidate returns on a later run.")
}
$c = $hit.cand
$commodity = [string]$c.id
$store = [string]$c.store
$product = [string]$c.product
$prodId = ([string]$c.product_id).Trim()
$basis = Test-DiscoveryBasisSuspect -Size ([string]$c.size) -Unit ([string]$c.unit)

Write-Output ('candidate : ' + $product + '  [' + [string]$c.size + ' @ $' + ('{0:N2}' -f [double]$c.price) + ']')
Write-Output ('commodity : ' + $commodity + ' @ ' + $store + '   $' + ('{0:N4}' -f [double]$c.per_unit) + '/' + [string]$c.unit +
  ' vs held $' + ('{0:N4}' -f [double]$c.held_per_unit))
if ($basis -ne '') { Write-Output ('BASIS     : ' + $basis) }

$today = (Get-Date -Format 'yyyy-MM-dd')
$entry = [ordered]@{
  key = $Key; store = $store; commodity = $commodity
  product = $product; product_id = $prodId; size = [string]$c.size
  per_unit = $c.per_unit; unit = [string]$c.unit; held_per_unit = $c.held_per_unit; beats_by_pct = $c.beats_by_pct
  verdict = $(if ($Accept) { 'accepted' } else { 'rejected' })
  basis_suspect = $basis
  basis_overridden = [bool]($Accept -and $basis -ne '' -and $AcceptDespiteBasis)
  evidence = $Evidence.Trim(); ruled_by = $RuledBy; ruled_on = $today
  docket_source = (Split-Path -Leaf $DiscoveryFile)
}

if ($Accept) {
  # THE BASIS REFUSAL. The candidate's stated saving is what put it in front of a reviewer, and when the size
  # names a different kind of quantity than the commodity is priced in, that saving is arithmetic rather than
  # money. Refuse by default; let a reviewer who has actually checked the size proceed, on the record.
  if ($basis -ne '' -and -not $AcceptDespiteBasis) {
    Die ("REFUSED on BASIS - " + $basis + [Environment]::NewLine +
      "  The 'beats by " + [string]$c.beats_by_pct + "%' that justified this review is an artefact of that mismatch, not a saving." + [Environment]::NewLine +
      "  If the product really is this commodity and you have checked the size yourself, re-run with -AcceptDespiteBasis and say so in -Evidence." + [Environment]::NewLine +
      "  If it is not this commodity, -Reject files it in known-wrong.json where compare-deals will refuse to price it.")
  }
  if ($store -ne 'Hy-Vee') { Die ("this command's accept path writes the HY-VEE catalogue work list; '" + $store + "' has no such file. Reject is store-agnostic; accept is not.") }
  if ($prodId -eq '' -or $prodId -notmatch '^\d+$') {
    Die ("accept needs the store's numeric productId (got '" + $prodId + "'). pull-regular-hyvee.ps1 fetches the price BY id; " +
      'an entry without one is a work-list row that can never be priced.')
  }
  if ($basis -ne '') { Write-Output 'BASIS OVERRIDDEN by -AcceptDespiteBasis - recorded in the ledger.' }

  $cat = Read-JsonDoc $CatalogFile 'Hy-Vee catalogue work list'
  $items = @()
  if ($cat.PSObject.Properties.Name -contains 'items') { $items = @($cat.items) }
  foreach ($it in $items) { if (([string]$it.product_id) -eq $prodId) { Die ('product id ' + $prodId + ' is already on the Hy-Vee catalogue work list (added ' + [string]$it.added_on + ')') } }
  # NO price and NO size, deliberately. The puller fetches the price from Hy-Vee's own API and derives the
  # size on the never-priced-before path, because Hy-Vee's size field reports one unit of a multipack and
  # mislabels ounces as counts. Storing our discovery-time numbers here would smuggle an unverified size
  # into the catalogue under cover of a human ruling.
  $add = [ordered]@{
    product_id = $prodId; name = $product; commodity = $commodity
    added_on = $today; added_by = $RuledBy; evidence = $Evidence.Trim()
    seen_at_discovery = ('$' + ('{0:N2}' -f [double]$c.price) + ' / ' + [string]$c.size + ' = $' + ('{0:N4}' -f [double]$c.per_unit) + '/' + [string]$c.unit +
      ' against a held $' + ('{0:N4}' -f [double]$c.held_per_unit) + ' - EVIDENCE ONLY, the puller re-derives both')
  }
  $items = @(@($items) + @([pscustomobject]$add))
  $cat.items = @($items)
  if (-not $DryRun) { [IO.File]::WriteAllText($CatalogFile, ($cat | ConvertTo-Json -Depth 12), (New-Object System.Text.UTF8Encoding($false))) }
  Write-Output ('ACCEPTED -> ' + $CatalogFile + ' (' + @($items).Count + ' catalogue work-list entr(y/ies))')
  Write-Output '  This adds the product to the Hy-Vee REFRESH work list. It sets no price and takes no board cell:'
  Write-Output '  pull-regular-hyvee.ps1 prices it from the store, compare-deals decides whether it wins, and if it'
  Write-Output '  takes a cell it arrives on this same desk as a scored ARRIVAL.'
} else {
  # REJECT IS ENFORCED, NOT FILED. add-known-wrong.ps1 is the intake compare-deals actually reads.
  $kw = Join-Path $Root 'add-known-wrong.ps1'
  if (-not (Test-Path $kw)) { Die ('add-known-wrong.ps1 not found next to this script (' + $kw + ") - a reject that only writes this ledger would be enforced by NOTHING.") }
  Write-Output ''
  Write-Output '--- add-known-wrong.ps1 (the ruling compare-deals enforces) ---'
  # A CHILD PROCESS, with SCALAR arguments only. Calling it in-process with & would run its `exit` in THIS
  # scope and end the run before the ledger is written; passing an ARRAY through `powershell -File` flattens
  # it so element 2 binds to the next positional parameter (that hazard bit three scripts on 2026-08-01).
  $kwArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $kw,
    '-Commodity', $commodity, '-Store', $store, '-Name', $product,
    '-RuledBy', $RuledBy, '-Evidence', $Evidence.Trim(), '-Verdict', 'wrong-product')
  if ($prodId -ne '') { $kwArgs += @('-ProductId', $prodId) }
  if ($DryRun) { $kwArgs += @('-DryRun') }
  & powershell @kwArgs
  $rc = $LASTEXITCODE
  Write-Output '--- end add-known-wrong.ps1 ---'
  if ($rc -ne 0) {
    Die ('add-known-wrong.ps1 REFUSED the ruling (rc=' + $rc + '). Nothing was written to the discovery ledger: ' +
      'a reject this ledger records but the pipeline does not enforce is exactly the prose-in-a-markdown-file failure.')
  }
  Write-Output ('REJECTED -> known-wrong.json. compare-deals will not price ' + $store + "'s '" + $product + "' as " + $commodity + '.')
}

# ledger LAST, and only once the enforcing half has succeeded
$vdoc = Read-JsonDoc $VerdictsFile 'discovery verdict ledger'
$ents = @()
if ($vdoc.PSObject.Properties.Name -contains 'entries') { $ents = @($vdoc.entries) }
$ents = @(@($ents) + @([pscustomobject]$entry))
$vdoc.entries = @($ents)
if ($DryRun) {
  Write-Output '--- DRY RUN, nothing written to the ledger ---'
  Write-Output (([pscustomobject]$entry) | ConvertTo-Json -Depth 6)
  exit 0
}
[IO.File]::WriteAllText($VerdictsFile, ($vdoc | ConvertTo-Json -Depth 12), (New-Object System.Text.UTF8Encoding($false)))
Write-Output ('ledger: wrote ' + $VerdictsFile + ' (' + @($ents).Count + ' ruling(s)) - this candidate will not be asked about again')
exit 0
