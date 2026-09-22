<#
  add-known-wrong.ps1 - the ONE COMMAND that moves a finding out of prose and into the publish path.

  The corpus's most damning fact is that audit findings lived as PROSE in .md files: honeydew was written up
  on 2026-07-29 with the store's own arithmetic and was STILL the published crown the next morning. A memory
  the pipeline cannot read is not a memory. This script is the intake: an auditor or an agent that has just
  adjudicated a (commodity, store, product) wrong runs one line, the ruling lands in known-wrong.json, and
  audit-known-wrong.ps1 - which guards.ps1 delegates to - refuses to publish that cell ever again.

  ADD (the normal case; -Name is optional, it is read off the current board):
    .\add-known-wrong.ps1 -Commodity salmon -Store Walmart -RuledBy "accuracy-agent" `
        -Evidence "Dry cat food. Held the salmon crown at 4.10/lb, 20.8% under the runner-up."

  ADD a product that is in a store FEED but has not reached a board yet:
    .\add-known-wrong.ps1 -Commodity coffee -Store Walmart -RuledBy me `
        -Name "Onyx Coffee Lab Salted Mocha Oat Milk Latte, 11 fl oz Can" -Evidence "RTD latte, not coffee."

  REVERSE a ruling that turns out to be wrong (the ONLY way an entry stops being enforced):
    .\add-known-wrong.ps1 -Reverse -Key "salmon|Walmart|blue-buffalo-cat-food" -RuledBy me `
        -Evidence "Walmart reused the id for a real salmon fillet; verified in store 2026-08-02."

  DELIBERATELY NOT SUPPORTED: deleting an entry, and editing a stored product name. Both are how a gate gets
  quietly made green. An entry leaves enforcement only by being REVERSED, on the record, with a named
  reviewer and a reason - and it stays in the file so the reversal itself is auditable.

  A typo'd commodity id or store name makes an entry PERMANENTLY UNFIRABLE, which is exactly the allowlist
  bug found 2026-07-30 (two entries justified by "the store does not carry the item" while the store carried
  it). So both are validated against commodities.json / stores.json before anything is written.

  After writing, this runs audit-known-wrong.ps1 and prints the verdict. A NEW finding is EXPECTED to turn
  the gate red: that is the point. Fix the commodity rule, re-run, and it goes green - and stays green.
#>
param(
  [string]$Commodity,
  [string]$Store,
  [string[]]$Name,
  [string]$ProductId,
  [string]$Evidence,
  [string]$RuledBy,
  [string]$Key,
  [string]$Verdict = 'wrong-product',
  [switch]$Reverse,
  [switch]$DryRun,
  [string]$Root,
  [string]$ListFile,
  [string[]]$AlsoName,
  [switch]$AllowCommaInName,
  [switch]$OneOffShape,
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
if (-not $Root) { $Root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path } }
if (-not $ListFile) { $ListFile = Join-Path $Root 'known-wrong.json' }
$outDir = Join-Path $Root 'out'

function Die([string]$m) { Write-Output ('add-known-wrong: ' + $m); exit 1 }

# THE -File COMMA TRAP (2026-09-18, queue 2026-09-18-37ac63). -Name is [string[]], and in-process
# (`& .\add-known-wrong.ps1 -Name 'A','B'`) it binds two names. Under `powershell -File` it does not: the
# comma list arrives as ONE string, 'A,B', with the quotes gone and no space after the comma. That string can
# never equal either product under Test-KnownWrong's normalised match, so the ruling is written, reads as done,
# and blocks nothing. It happened to the 2026-08-06 Jimmy Dean Biscuit Roll Ups ruling, inert for six weeks
# while the sweep re-paged the product (1 of 302 entries had the shape on 2026-09-18). A real name keeps a
# space after its commas ("Roll Ups, Sausage, Frozen"); a digit either side is a thousands separator
# ("1,000 ct"), never a join. -AllowCommaInName is the reviewed exit for a genuine name that has the shape.
function Get-JoinedNameTrap([string[]]$Names) {
  foreach ($n in @($Names)) {
    $s = [string]$n
    if ($s -match '(?<!\d),(?=[^\s\d])|(?<=\D),(?=\d)' -and $s -match ',\S') { return $s }
  }
  return ''
}

# A RECURRING WRONG-PRODUCT SHAPE IS AN EXCLUDE, NEVER A SECOND RULING (Brad's ruling "B" on queue 2026-09-21-7d64a6,
# 2026-09-22). known-wrong is keyed on ONE exact product name, so each new flavour or pack of a product already ruled pages
# again (three times on 2026-09-20 alone: two Ben's Original Ready Rice flavours on cooked-jasmine-rice and a Stayfree
# variant). A pattern here would be a SECOND pattern system beside the commodity excludes, which the matching gate
# (apply-coverage-batch, the routing artifact) already measures: gap F1 of design/RCA-holistic-2026-09-22.md. So the
# SECOND ruling for the same commodity and the same SHAPE is refused, and the author is pointed at the exclude.
# SHAPE = the first three words of the product name, lower-cased, apostrophes dropped ("bens original ready"). Measured
# over known-wrong.json on 2026-09-22: 14 of 258 active commodity|shape groups already hold a second ruling, and every
# one of the 14 is a family of one product line (Prego Italian Sausage sauces, Maxwell House International cafes, Great
# Value Classic Ranch). FIRST PLAUSIBLE NUMBER (three words), nothing else tried. -OneOffShape is the reviewed exit for a
# genuinely different product that happens to share three leading words.
function Get-KwShape([string]$Name) {
  $w = [regex]::Matches((([string]$Name).ToLower() -replace "['’]", ''), '[a-z0-9]+')
  if ($w.Count -lt 3) { return '' }
  return ($w[0].Value + ' ' + $w[1].Value + ' ' + $w[2].Value)
}
function Find-KwShapeSibling($Entries, [string]$Commodity, [string[]]$Names) {
  # The first ACTIVE wrong-product ruling on this commodity whose leading shape equals one of the new names', or $null.
  $want = @{}
  foreach ($n in @($Names)) { $s = Get-KwShape $n; if ($s) { $want[$s] = $true } }
  if ($want.Count -eq 0) { return $null }
  foreach ($e in @($Entries)) {
    if ($null -eq $e -or [string]$e.commodity -ne $Commodity -or [string]$e.verdict -ne 'wrong-product') { continue }
    if ($e.PSObject.Properties['reversed_on'] -and ([string]$e.reversed_on).Trim()) { continue }
    foreach ($n in @($e.names)) { $s = Get-KwShape $n; if ($s -and $want.ContainsKey($s)) { return [pscustomobject]@{ key = [string]$e.key; shape = $s; name = [string]$n } } }
  }
  return $null
}
if ($SelfTest) {
  $bad = 0; $ran = 0
  function _Ok([string]$label, [bool]$cond) { $script:ran++; if ($cond) { Write-Output ('  ok   ' + $label) } else { Write-Output ('  FAIL ' + $label); $script:bad++ } }
  # MUST FIRE, the founding value frozen verbatim from known-wrong.json key
  # breakfast-sandwiches|FamilyFare|jimmy-dean-biscuit-roll-ups-sausage-frozen-break (ruled 2026-08-06).
  $joined = 'Jimmy Dean Biscuit Roll Ups, Sausage, Frozen Breakfast 8 Ct,Jimmy Dean Maple Biscuit Roll Ups, Sausage, Frozen Breakfast 2 Ct'
  _Ok 'MUST FIRE  the joined Roll Ups name is recognised as the -File comma trap' ((Get-JoinedNameTrap @($joined)) -eq $joined)
  _Ok 'MUST FIRE  the minimal shape A 8 Ct,B 2 Ct is recognised' ((Get-JoinedNameTrap @('A 8 Ct,B 2 Ct')) -ne '')
  # CLEAN TWIN: a real name with commas followed by spaces is accepted, and so is each half on its own.
  _Ok 'CLEAN TWIN  a real name with ", " inside is accepted' ((Get-JoinedNameTrap @('Jimmy Dean Biscuit Roll Ups, Sausage, Frozen Breakfast 8 Ct', 'Jimmy Dean Maple Biscuit Roll Ups, Sausage, Frozen Breakfast 2 Ct')) -eq '')
  # MUST NOT FIRE: a thousands separator is not a join (a synthetic parser input, not a product claim).
  _Ok 'MUST NOT FIRE  "Cotton Swabs, 1,000 Count" (a thousands separator) is accepted' ((Get-JoinedNameTrap @('Cotton Swabs, 1,000 Count')) -eq '')
  # END TO END, THROUGH -File, which is where the trap lives: a child run in a per-run temp root must REFUSE the
  # comma list and leave the ledger byte-identical, and the same run with one real name must be accepted.
  $stRoot = Join-Path $env:TEMP ('akw-st-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
  try {
    New-Item -ItemType Directory -Path $stRoot -ErrorAction Stop | Out-Null
    $stList = Join-Path $stRoot 'known-wrong.json'
    [IO.File]::WriteAllText($stList, '{"entries":[]}', (New-Object System.Text.UTF8Encoding($false)))
    $me = $MyInvocation.MyCommand.Path
    if (-not $me) { $me = Join-Path $PSScriptRoot 'add-known-wrong.ps1' }
    $ev = 'self-test evidence string, long enough to pass the 20-char bar'
    # 'A 8 Ct,B 2 Ct' as ONE argument is exactly what -File receives when a shell hands it -Name "A 8 Ct","B 2 Ct".
    # (Passing a PowerShell array here would NOT reproduce it: a native call splits an array into separate args.)
    $o1 = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $me -Root $stRoot -Commodity 'breakfast-sandwiches' -Store 'Family Fare' -Name 'A 8 Ct,B 2 Ct' -Evidence $ev -RuledBy 'selftest' -DryRun)
    $rc1 = $LASTEXITCODE
    _Ok ('MUST FIRE  under -File, -Name "A 8 Ct","B 2 Ct" is REFUSED naming the comma trap (rc=' + $rc1 + ')') (($rc1 -eq 1) -and ((($o1 -join ' ')) -match 'comma'))
    _Ok 'MUST FIRE  the refused run left the ledger untouched' (([IO.File]::ReadAllText($stList)) -eq '{"entries":[]}')
    $o2 = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $me -Root $stRoot -Commodity 'breakfast-sandwiches' -Store 'Family Fare' -Name 'Jimmy Dean Biscuit Roll Ups, Sausage, Frozen Breakfast 8 Ct' -AlsoName 'Jimmy Dean Maple Biscuit Roll Ups, Sausage, Frozen Breakfast 2 Ct' -Evidence $ev -RuledBy 'selftest' -DryRun)
    $rc2 = $LASTEXITCODE
    $j2 = ($o2 -join "`n")
    _Ok ('CLEAN TWIN  under -File, one real name plus -AlsoName is accepted with TWO names (rc=' + $rc2 + ')') (($rc2 -eq 0) -and ($j2 -match 'ADDING') -and ($j2 -match 'Maple Biscuit Roll Ups') -and ($j2 -match 'Frozen Breakfast 8 Ct"'))
    # A RECURRING SHAPE IS AN EXCLUDE (Brad's ruling on 2026-09-21-7d64a6). The founding pair, frozen verbatim from
    # known-wrong.json: the cilantro-lime ruling exists, and the roasted-chicken flavour is the SECOND of the same shape.
    $benLedger = '{"entries":[{"key":"cooked-jasmine-rice|Bakers|bens-original-ready-rice-cilantro-lime-flavored","commodity":"cooked-jasmine-rice","store":"Baker''s","names":["Ben''s Original Ready Rice Cilantro Lime Flavored Rice, Easy Dinner Side, 8.5 oz Pouch"],"product_id":"0005480042344","verdict":"wrong-product","evidence":"Flavoured ready rice, not jasmine.","ruled_on":"2026-09-20","ruled_by":"triage-money-lane 2026-09-20","retire_when":"ruling-reversed"}]}'
    [IO.File]::WriteAllText($stList, $benLedger, (New-Object System.Text.UTF8Encoding($false)))
    $o3 = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $me -Root $stRoot -Commodity 'cooked-jasmine-rice' -Store "Baker's" -Name 'Ben''s Original Ready Rice Roasted Chicken Flavored Rice, Easy Dinner Side, 8.8 oz Pouch' -Evidence $ev -RuledBy 'selftest' -DryRun)
    $rc3 = $LASTEXITCODE
    _Ok ('MUST FIRE  the SECOND Ben''s Original Ready Rice ruling on cooked-jasmine-rice is REFUSED and points at the exclude (rc=' + $rc3 + ')') (($rc3 -eq 1) -and (($o3 -join ' ') -match 'apply-coverage-batch') -and (($o3 -join ' ') -match 'bens original ready'))
    $o4 = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $me -Root $stRoot -Commodity 'cooked-jasmine-rice' -Store "Baker's" -Name 'Kroger Yellow Rice Mix 8 oz' -Evidence $ev -RuledBy 'selftest' -DryRun)
    $rc4 = $LASTEXITCODE
    _Ok ('MUST NOT FIRE  a first ruling of a DIFFERENT shape on the same commodity is accepted (rc=' + $rc4 + ')') (($rc4 -eq 0) -and (($o4 -join ' ') -match 'ADDING'))
    $o5 = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $me -Root $stRoot -Commodity 'cooked-jasmine-rice' -Store "Baker's" -Name 'Ben''s Original Ready Rice Roasted Chicken Flavored Rice, Easy Dinner Side, 8.8 oz Pouch' -Evidence $ev -RuledBy 'selftest' -DryRun -OneOffShape)
    $rc5 = $LASTEXITCODE
    _Ok ('CLEAN TWIN  -OneOffShape is the reviewed exit and still ADDS the ruling (rc=' + $rc5 + ')') (($rc5 -eq 0) -and (($o5 -join ' ') -match 'ADDING'))
    _Ok 'MECHANISM  the shape is the first three words, apostrophes dropped' ((Get-KwShape 'Ben''s Original Ready Rice Cilantro Lime') -eq 'bens original ready')  } catch { Write-Output ('  FAIL end-to-end cases could not run: ' + $_.Exception.Message); $bad++ }
  finally { if (Test-Path -LiteralPath $stRoot) { Remove-Item -LiteralPath $stRoot -Recurse -Force -ErrorAction SilentlyContinue } }
  if ($bad -eq 0) { Write-Output ("add-known-wrong SELF-TEST PASS ($ran cases)") } else { Write-Output ("add-known-wrong SELF-TEST FAIL ($bad of $ran cases)") }
  exit $(if ($bad -eq 0) { 0 } else { 1 })
}

if (-not (Test-Path $ListFile)) { Die ("blocklist file not found: " + $ListFile) }
$raw = ((Get-Content $ListFile -Raw -Encoding UTF8) + '').Trim()
if ($raw.Length -eq 0) { Die ("blocklist file is empty: " + $ListFile + " - restore it from git before adding to it") }
$doc = $raw | ConvertFrom-Json
if ($null -eq $doc) { Die "blocklist file parsed to null" }
$entries = @()
if ($doc.PSObject.Properties.Name -contains 'entries') { $entries = @($doc.entries) }

if (-not $Evidence -or $Evidence.Trim().Length -lt 20) { Die "-Evidence is required and must actually say why (>= 20 chars). An entry without evidence is a rule nobody can review." }
if (-not $RuledBy) { Die "-RuledBy is required: every ruling names who made it." }

# ---------------------------------------------------------------- reverse
if ($Reverse) {
  if (-not $Key) { Die "-Reverse needs -Key (the exact key of the entry to reverse; run audit-known-wrong.ps1 to list them)" }
  $hit = $null
  foreach ($e in $entries) { if ([string]$e.key -eq $Key) { $hit = $e; break } }
  if ($null -eq $hit) { Die ("no entry with key '" + $Key + "'") }
  if ($hit.PSObject.Properties.Name -contains 'reversed_on' -and ([string]$hit.reversed_on).Trim()) { Die ("entry '" + $Key + "' is already reversed on " + [string]$hit.reversed_on) }
  $today = (Get-Date -Format 'yyyy-MM-dd')
  foreach ($p in @(@('reversed_on', $today), @('reversed_by', $RuledBy), @('reversal_reason', $Evidence.Trim()))) {
    if ($hit.PSObject.Properties.Name -contains $p[0]) { $hit.($p[0]) = $p[1] }
    else { Add-Member -InputObject $hit -MemberType NoteProperty -Name $p[0] -Value $p[1] }
  }
  Write-Output ("REVERSING " + $Key + " (by " + $RuledBy + ", " + $today + ")")
} else {
  # ---------------------------------------------------------------- add
  if (-not $Commodity) { Die "-Commodity is required" }
  if (-not $Store) { Die "-Store is required (exact name from stores.json, e.g. \"Baker's\", \"Sam's Club\", \"Family Fare\")" }

  # A typo here makes the entry permanently unfirable. Validate, do not guess.
  $cmF = Join-Path $Root 'commodities.json'
  if (Test-Path $cmF) {
    # assign FIRST: `@(Get-Content | ConvertFrom-Json)` does not unroll a bare top-level JSON array in PS 5.1
    $cmAll = Read-JsonFile $cmF
    $ids = @{}; foreach ($c in $cmAll) { if ($c -and $c.id) { $ids[[string]$c.id] = $true } }
    if ($ids.Count -ge 2 -and -not $ids.ContainsKey($Commodity)) { Die ("'" + $Commodity + "' is not a commodity id in commodities.json. An entry on a non-existent commodity can never fire.") }
  }
  $stF = Join-Path $Root 'stores.json'
  if (Test-Path $stF) {
    $names = @{}; foreach ($s in @((Read-JsonFile $stF).stores)) { if ($s -and $s.name) { $names[[string]$s.name] = [string]$s.regular_prefix } }
    if ($names.Count -ge 2 -and -not $names.ContainsKey($Store)) { Die ("'" + $Store + "' is not a store name in stores.json (" + (($names.Keys | Sort-Object) -join ', ') + ")") }
  }

  # -Name omitted: read the product the board is CURRENTLY publishing in that cell, so the ruling is
  # recorded against the exact spelling the pipeline produced rather than one a human retyped.
  $useNames = @(@($Name) + @($AlsoName) | Where-Object { ($_ + '').Trim() })
  # the -File comma trap (see Get-JoinedNameTrap above): refuse a joined name BEFORE anything is written
  $trap = Get-JoinedNameTrap $useNames
  if ($trap -and -not $AllowCommaInName) {
    Die ("name '" + $trap + "' carries a comma with no space after it - the PS 5.1 -File comma trap: -Name ""A"",""B"" under powershell -File arrives as ONE string 'A,B', which can never equal either product, so the ruling would block nothing (the 2026-08-06 Roll Ups ruling was inert for six weeks this way). Pass the second name with -AlsoName, or call in-process: & .\add-known-wrong.ps1 -Name 'A','B'. If this really is ONE product's name, pass -AllowCommaInName.")
  }
  $foundPid = ''
  $cmpF = @(Get-ChildItem (Join-Path $outDir 'comparison-*.json') -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1)
  $boardItem = ''
  foreach ($f in $cmpF) {
    foreach ($r in @((Read-JsonFile $f.FullName).comparison)) {
      if ([string]$r.id -ne $Commodity) { continue }
      foreach ($s in $r.stores) {
        if ([string]$s.store -ne $Store) { continue }
        if ([string]$s.item) { $boardItem = [string]$s.item }
      }
    }
  }
  if ($useNames.Count -eq 0) {
    if (-not $boardItem) { Die ("no product name given and the newest board has no named " + $Store + " cell for '" + $Commodity + "'. Pass -Name with the exact product name from the store feed.") }
    $useNames = @($boardItem)
    Write-Output ("reading the product name off the current board: '" + $boardItem + "'")
  }

  # product_id, when the store publishes one: it lets the gate re-derive today's spelling after the
  # pipeline mangles the name (it has shipped one product three ways in four days)
  if (-not $ProductId) {
    $prefix = ''
    if (Test-Path $stF) { foreach ($s in @((Read-JsonFile $stF).stores)) { if ([string]$s.name -eq $Store) { $prefix = [string]$s.regular_prefix } } }
    if ($prefix) {
      $want = @{}; foreach ($n in $useNames) { $want[(($n + '') -replace '[^a-zA-Z0-9]', '').ToLower()] = $true }
      $rf = @(Get-ChildItem (Join-Path $outDir ('regular\' + $prefix + '-regular-*.json')) -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1)
      foreach ($f in $rf) {
        foreach ($d in @((Read-JsonFile $f.FullName).deals)) {
          $k = (([string]$d.item) -replace '[^a-zA-Z0-9]', '').ToLower()
          if (-not $want.ContainsKey($k)) { continue }
          $p = @($d.PSObject.Properties.Name)
          if ($p -contains 'item_id' -and [string]$d.item_id) { $foundPid = [string]$d.item_id; break }
          if ($p -contains 'product_id' -and [string]$d.product_id) { $foundPid = [string]$d.product_id; break }
        }
      }
      if ($foundPid) { Write-Output ("resolved product id from the " + $Store + " feed: " + $foundPid) }
      else { Write-Output ("no product id available for this product at " + $Store + " - the normalized name is the only key (expected at Aldi, Sam's Club and Fareway)") }
    }
  } else { $foundPid = $ProductId }

  if (-not $Key) {
    $slug = ((($useNames[0] + '') -replace "'", '') -replace '[^a-zA-Z0-9]+', '-').ToLower().Trim('-')
    if ($slug.Length -gt 48) { $slug = $slug.Substring(0, 48).Trim('-') }
    $storeSlug = (($Store -replace "'", '') -replace '[^a-zA-Z0-9]+', '')
    $Key = $Commodity + '|' + $storeSlug + '|' + $slug
  }
  if ($Verdict -eq 'wrong-product' -and -not $OneOffShape) {
    $sib = Find-KwShapeSibling $entries $Commodity $useNames
    if ($null -ne $sib) {
      Die ("this is the SECOND wrong-product ruling on '" + $Commodity + "' for the shape '" + $sib.shape + "' (already ruled: " + $sib.key + "). A recurring shape is a commodity EXCLUDE, never another known-wrong line (Brad's ruling on 2026-09-21-7d64a6): measure it with  & .\apply-coverage-batch.ps1 -Excludes @{ '" + $Commodity + "' = @('<pattern for the shape>') }  so the matching gate routes it, then leave known-wrong for one-off products. If this really is a different product that shares three leading words, pass -OneOffShape.")
    }
  }  foreach ($e in $entries) { if ([string]$e.key -eq $Key) { Die ("an entry with key '" + $Key + "' already exists - pass a different -Key, or -Reverse it if the old ruling was wrong") } }

  $new = [ordered]@{
    key = $Key; commodity = $Commodity; store = $Store
    names = @($useNames); product_id = $foundPid
    verdict = $Verdict; evidence = $Evidence.Trim()
    seen_on_board = $(if ($boardItem) { 'yes - on the newest board when this ruling was made' } else { 'not on the newest board when this ruling was made' })
    ruled_on = (Get-Date -Format 'yyyy-MM-dd'); ruled_by = $RuledBy
    retire_when = 'ruling-reversed'
  }
  $entries = @(@($entries) + @([pscustomobject]$new))
  Write-Output ("ADDING " + $Key)
}

$doc.entries = @($entries)
$json = ($doc | ConvertTo-Json -Depth 12)
if ($DryRun) { Write-Output '--- DRY RUN, nothing written ---'; Write-Output $json; exit 0 }
# no-BOM UTF8: the file is pure ASCII by policy and several readers in this tree are BOM-sensitive
[IO.File]::WriteAllText($ListFile, $json, (New-Object System.Text.UTF8Encoding($false)))
Write-Output ("wrote " + $ListFile + " (" + @($entries).Count + " entries)")

$auditor = Join-Path $Root 'audit-known-wrong.ps1'
if (-not (Test-Path $auditor)) { Write-Output 'audit-known-wrong.ps1 not found next to the list - run it manually'; exit 0 }
Write-Output ''
Write-Output '--- audit-known-wrong.ps1 ---'
& powershell -NoProfile -ExecutionPolicy Bypass -File $auditor -Root $Root -ListFile $ListFile
$rc = $LASTEXITCODE
Write-Output ''
if ($rc -eq 2) { Write-Output 'RED, as expected for a live finding: the wrong product is still on the board. Fix the commodity rule in commodities.json, re-run compare-deals, and this goes green - and stays green.' }
elseif ($rc -eq 3) { Write-Output 'BLIND: the blocklist could not be evaluated. The entry is recorded but nothing was proven - fix the blindness before trusting the result.' }
else { Write-Output 'GREEN: the ruling is recorded and the board does not price it. It is now a regression test.' }
exit 0

