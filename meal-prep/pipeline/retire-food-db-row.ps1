<#
  retire-food-db-row.ps1 - retire ONE duplicate row from meal-prep\food-macros-db.json, in favour of
  the row that survives, and record the ruling so the merge is auditable and reversible.

  WHY THIS EXISTS. The write-time collision check (0b9f8bf5) stops the duplicate backlog GROWING - it
  names a collision at the write instead of parking the recipe - but it merges NOTHING. There has been
  no gated road for retiring the loser of a pair, so the four collisions that check found on 2026-08-26
  ('Apples' beside 'Apple', 'Lemons' beside 'Lemon', 'Green Bell Peppers' beside 'Green Bell Pepper',
  'Fresh Thyme' twice) sat in the file for nine days. The only alternative was a hand edit of a
  load-bearing data file with no gate on it, which is the shape this estate keeps building tools to
  avoid.

  WHAT IT REFUSES, and why each refusal is the point:

    * a retiring row that is REFERENCED ANYWHERE. A food-DB row is looked up by NAME - the conflict
      rule and Get-MacroRecompute are both name-keyed dicts - so retiring a name something still cites
      turns a working macro lookup into a silent absence. Every reference file is swept by exact
      quoted name, and the row is only retired when nothing cites it.
    * a survivor that does not exist. Retiring a row in favour of a name the DB does not hold is a
      deletion wearing a merge's clothes.
    * retire == survivor.

  WHAT IT IS NOT. It does not decide WHICH row survives. That is a food-identity call with real macro
  consequences - on 2026-09-04 the two contested pairs differed by 52 vs 63 cal and 20.2 vs 17 cal per
  100 g, and in both cases the row nobody used was the FDC-sourced one - so the ruling is Brad's and
  this script records it rather than making it. Provenance is never a merge tiebreak (2026-08-26).

  USAGE
    .\retire-food-db-row.ps1 -Retire 'Apples' -Survivor 'Apple' -Reason 'orphan; 63 cal is a different form' -WhatIf
    .\retire-food-db-row.ps1 -Retire 'Apples' -Survivor 'Apple' -Reason '...'
    .\retire-food-db-row.ps1 -SelfTest
#>
param(
  [string]$Retire = '',
  [string]$Survivor = '',
  [string]$Reason = '',
  [string]$DbFile = '',
  [string]$LedgerFile = '',
  [string[]]$RefRoots = @(),
  [switch]$WhatIf,
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
# COPY EVERY SWITCH INTO A PLAIN BOOL FIRST - a dot-sourced lib declaring its own [switch] rebinds it.
$runSelfTest = [bool]$SelfTest
$runWhatIf   = [bool]$WhatIf

$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$mp   = Split-Path -Parent $here
$repo = Split-Path -Parent $mp

$script:UTF8 = New-Object System.Text.UTF8Encoding($false)

function Die([string]$m) { Write-Output ("retire-food-db-row: REFUSED - " + $m); exit 1 }

# ===================================================================================================
# PURE PREDICATES - so every rule is pinned without a DB, a spec store or a disk write.
# ===================================================================================================

function Get-DbRows($doc) {
  <# The row list, whichever shape the file is in. An unreadable shape returns an EMPTY list and the
     caller refuses - never an empty list that reads as "the DB has no rows". #>
  if ($null -eq $doc) { return @() }
  if ($doc -is [System.Collections.IEnumerable] -and $doc -isnot [string] -and
      $doc -isnot [System.Collections.IDictionary]) { return @($doc) }
  if ($doc.PSObject.Properties.Name -contains 'items') { return @($doc.items) }
  return @()
}

function Find-RowIndex($rows, [string]$Name) {
  <# The index of the row whose item is EXACTLY this name, or -1. Exact, because the whole defect
     class this tool cleans up came from a lookup that was exact while the human eye was not. #>
  for ($i = 0; $i -lt @($rows).Count; $i++) {
    if ([string]$rows[$i].item -ceq $Name) { return $i }
  }
  return -1
}

function Test-NameCited([string]$Text, [string]$Name) {
  <# Is this name cited as a WHOLE JSON string in this text?

     THE QUOTES ARE THE CHECK. A substring sweep for 'Lemon' hits 'Lemons' and 'Lemon Juice' and would
     refuse every merge forever; a sweep that ignored quoting would hit prose. A food-DB row is cited
     by exact name in a JSON string, so that is what is looked for and nothing else. #>
  if (-not $Name) { return $false }
  $needle = '"' + $Name + '"'
  return $Text.Contains($needle)
}

function Get-MergeRecord($retireRow, $survivorRow, [string]$Reason, [string]$At) {
  <# BOTH ROWS, VERBATIM, so the merge is reversible from its own record. A ledger that stored only the
     name retired would make an undo a re-transcription. #>
  return [ordered]@{
    at        = $At
    retired   = $retireRow
    survivor  = $survivorRow
    reason    = $Reason
  }
}

# ===================================================================================================
if ($runSelfTest) {
  $fail = 0
  function T([string]$name, [bool]$ok, [string]$got = '') {
    if ($ok) { Write-Output ("  ok    " + $name) }
    else { $script:fail++; Write-Output ("  X     " + $name + "   got: " + $got) }
  }

  # --- Get-DbRows -----------------------------------------------------------------------------
  $rowsA = Get-DbRows ([pscustomobject]@{ items = @([pscustomobject]@{ item = 'A' }) })
  T "MUST FIRE  an items-wrapped DB yields its rows" (@($rowsA).Count -eq 1) (@($rowsA).Count)
  $rowsB = Get-DbRows (@([pscustomobject]@{ item = 'A' }, [pscustomobject]@{ item = 'B' }))
  T "MUST FIRE  a bare array DB yields its rows" (@($rowsB).Count -eq 2) (@($rowsB).Count)
  T "MUST FIRE  a shape this script does not recognise yields NO rows, so the caller refuses rather than reporting an empty DB" `
    (@(Get-DbRows ([pscustomobject]@{ nope = 1 })).Count -eq 0) 'non-empty'

  # --- Find-RowIndex --------------------------------------------------------------------------
  $rows = @([pscustomobject]@{ item = 'Apple' }, [pscustomobject]@{ item = 'Apples' })
  T "MUST FIRE  the index is found by EXACT name" ((Find-RowIndex $rows 'Apples') -eq 1) (Find-RowIndex $rows 'Apples')
  T "CLEAN TWIN a near name is NOT the row - 'Apple' must never resolve to 'Apples', which is the very confusion this file cleans up" `
    ((Find-RowIndex $rows 'Apple') -eq 0) (Find-RowIndex $rows 'Apple')
  T "MUST FIRE  a name the DB does not hold is -1, never 0" ((Find-RowIndex $rows 'Pear') -eq -1) (Find-RowIndex $rows 'Pear')
  T "MUST FIRE  the match is case SENSITIVE - 'apples' is not 'Apples', and a case-blind merge would retire a row nobody ruled on" `
    ((Find-RowIndex $rows 'apples') -eq -1) (Find-RowIndex $rows 'apples')

  # --- Test-NameCited -------------------------------------------------------------------------
  $doc = '{"item":"Lemons","note":"squeeze a Lemon over it","other":"Lemon Juice"}'
  T "MUST FIRE  a name cited as a whole JSON string is FOUND" (Test-NameCited $doc 'Lemons') 'not found'
  T "CLEAN TWIN the same name inside PROSE is not a citation - a food-DB row is cited by exact name, and a prose sweep would refuse every merge forever" `
    (-not (Test-NameCited $doc 'Lemon')) 'prose counted as a citation'
  T "CLEAN TWIN a LONGER name that merely starts with this one is not a citation either ('Lemon' must not match 'Lemon Juice')" `
    (-not (Test-NameCited '{"x":"Lemon Juice"}' 'Lemon')) 'prefix counted as a citation'
  T "MUST FIRE  an empty name is never cited, so a missing argument cannot read as a clean sweep" `
    (-not (Test-NameCited $doc '')) 'empty name matched'

  # --- Get-MergeRecord ------------------------------------------------------------------------
  $rec = Get-MergeRecord ([pscustomobject]@{ item = 'Apples'; calories = 63 }) `
                         ([pscustomobject]@{ item = 'Apple'; calories = 52 }) 'why' '2026-09-04T00:00:00'
  T "MUST FIRE  the record carries BOTH rows verbatim, so the merge is reversible from its own ledger rather than by re-transcribing a label" `
    (([string]$rec.retired.calories -eq '63') -and ([string]$rec.survivor.calories -eq '52')) (($rec | ConvertTo-Json -Compress))
  T "MUST FIRE  ...and the stated reason rides with it" ([string]$rec.reason -eq 'why') ([string]$rec.reason)

  # --- END TO END, over a scratch DB ----------------------------------------------------------
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ("rfdb-" + [Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $tmp | Out-Null
  try {
    $db  = Join-Path $tmp 'food.json'
    $led = Join-Path $tmp 'merges.json'
    $ref = Join-Path $tmp 'refs'
    New-Item -ItemType Directory -Path $ref | Out-Null
    $mk = {
      param($p)
      [IO.File]::WriteAllText($p, (@{ items = @(
        @{ item = 'Apple';  serving_grams = 100; calories = 52 },
        @{ item = 'Apples'; serving_grams = 100; calories = 63 }) } | ConvertTo-Json -Depth 6), $script:UTF8)
    }
    & $mk $db
    [IO.File]::WriteAllText((Join-Path $ref 'a.json'), '{"item":"Apple"}', $script:UTF8)

    $out = & $PSCommandPath -Retire 'Apples' -Survivor 'Apple' -Reason 'orphan' -DbFile $db `
                            -LedgerFile $led -RefRoots @($ref) 2>&1
    $rc  = $LASTEXITCODE
    $now = Get-DbRows (Get-Content $db -Raw -Encoding UTF8 | ConvertFrom-Json)
    T "MUST FIRE  a clean retire exits 0 and the row is GONE" `
      (($rc -eq 0) -and ((Find-RowIndex $now 'Apples') -eq -1)) ("rc=$rc rows=" + @($now).Count)
    T "MUST FIRE  ...and the SURVIVOR is untouched, with its own macros - a merge that quietly rewrote the survivor would be the defect wearing the fix's clothes" `
      (((Find-RowIndex $now 'Apple') -ge 0) -and ([string]$now[(Find-RowIndex $now 'Apple')].calories -eq '52')) `
      (($now | ConvertTo-Json -Compress))
    T "MUST FIRE  ...and the ledger records it" (Test-Path $led) 'no ledger'
    $ledDoc = Get-Content $led -Raw -Encoding UTF8 | ConvertFrom-Json
    T "MUST FIRE  ...naming both rows and the reason" `
      ((@($ledDoc.merges).Count -eq 1) -and ([string]$ledDoc.merges[0].retired.calories -eq '63') `
        -and ([string]$ledDoc.merges[0].reason -eq 'orphan')) (($ledDoc | ConvertTo-Json -Compress -Depth 6))

    # a REFERENCED row is refused
    & $mk $db
    [IO.File]::WriteAllText((Join-Path $ref 'a.json'), '{"item":"Apples"}', $script:UTF8)
    $out2 = & $PSCommandPath -Retire 'Apples' -Survivor 'Apple' -Reason 'orphan' -DbFile $db `
                             -LedgerFile $led -RefRoots @($ref) 2>&1
    $rc2  = $LASTEXITCODE
    $now2 = Get-DbRows (Get-Content $db -Raw -Encoding UTF8 | ConvertFrom-Json)
    T "MUST FIRE  a row something still CITES is refused, and the DB is left alone - a name-keyed lookup that loses its row goes silently absent, it does not error" `
      (($rc2 -ne 0) -and ((Find-RowIndex $now2 'Apples') -ge 0)) ("rc=$rc2 out=" + ($out2 -join ' '))
    T "MUST FIRE  ...and the refusal NAMES the file that cites it, so the next step is obvious rather than a search" `
      ((($out2 -join ' ') -match 'a\.json')) (($out2 -join ' '))

    # a survivor that does not exist is refused
    & $mk $db
    [IO.File]::WriteAllText((Join-Path $ref 'a.json'), '{"item":"Apple"}', $script:UTF8)
    $out3 = & $PSCommandPath -Retire 'Apples' -Survivor 'Pear' -Reason 'x' -DbFile $db `
                             -LedgerFile $led -RefRoots @($ref) 2>&1
    T "MUST FIRE  retiring in favour of a name the DB does not hold is refused - that is a deletion wearing a merge's clothes" `
      (($LASTEXITCODE -ne 0) -and ((Find-RowIndex (Get-DbRows (Get-Content $db -Raw -Encoding UTF8 | ConvertFrom-Json)) 'Apples') -ge 0)) `
      (($out3 -join ' '))

    # -WhatIf changes nothing
    $out4 = & $PSCommandPath -Retire 'Apples' -Survivor 'Apple' -Reason 'x' -DbFile $db `
                             -LedgerFile $led -RefRoots @($ref) -WhatIf 2>&1
    T "CLEAN TWIN -WhatIf reports the retire it WOULD do and writes nothing" `
      (($LASTEXITCODE -eq 0) -and ((Find-RowIndex (Get-DbRows (Get-Content $db -Raw -Encoding UTF8 | ConvertFrom-Json)) 'Apples') -ge 0)) `
      (($out4 -join ' '))

    # RETIRE == SURVIVOR, ON THE ROW NOTHING CITES. Using 'Apple' here passed for the WRONG REASON:
    # the reference file cites 'Apple', so the citation sweep refused it and the equality check was
    # never reached - measured 2026-09-04, when neutering the equality check turned nothing red. The
    # uncited row is the only one that reaches this branch.
    $out5 = & $PSCommandPath -Retire 'Apples' -Survivor 'Apples' -Reason 'x' -DbFile $db `
                             -LedgerFile $led -RefRoots @($ref) 2>&1
    T "MUST FIRE  retiring a row in favour of ITSELF is refused - and on a row NOTHING cites, so this is the equality check answering and not the citation sweep" `
      (($LASTEXITCODE -ne 0) -and ((Find-RowIndex (Get-DbRows (Get-Content $db -Raw -Encoding UTF8 | ConvertFrom-Json)) 'Apples') -ge 0)) `
      (($out5 -join ' '))

    # NON-ASCII SURVIVES THE ROUND TRIP. Get-Content's ANSI default has corrupted this estate's UTF-8
    # before (three writers of commodities.json, 2026-08-29); a merge that doubled an accent on every
    # untouched row would be a silent data defect with a green exit code.
    [IO.File]::WriteAllText($db, (@{ items = @(
      @{ item = 'Jalapeno Puree'; calories = 29 },
      @{ item = 'Cafe Creme'; calories = 40 },
      @{ item = 'Apples'; calories = 63 },
      @{ item = 'Apple'; calories = 52 }) } | ConvertTo-Json -Depth 6).Replace('Jalapeno', "Jalape$([char]0x00F1)o").Replace('Cafe', "Caf$([char]0x00E9)"), $script:UTF8)
    $before = [IO.File]::ReadAllText($db, $script:UTF8)
    & $PSCommandPath -Retire 'Apples' -Survivor 'Apple' -Reason 'x' -DbFile $db `
                     -LedgerFile $led -RefRoots @($ref) 2>&1 | Out-Null
    $after = [IO.File]::ReadAllText($db, $script:UTF8)
    T "MUST FIRE  a non-ASCII row NOT being retired survives the rewrite byte for byte - the ANSI-default read is how this estate has doubled accents before" `
      (($after -match ([regex]::Escape("Jalape$([char]0x00F1)o"))) -and ($after -match ([regex]::Escape("Caf$([char]0x00E9)")))) `
      ($after.Substring(0, [Math]::Min(160, $after.Length)))
    T "CLEAN TWIN ...and it really was there to begin with, so the assertion above is not passing on an absence" `
      ($before -match ([regex]::Escape("Jalape$([char]0x00F1)o"))) 'the fixture never wrote it'
  } finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
  }

  Write-Output ''
  if ($fail) { Write-Output ("retire-food-db-row SELF-TEST FAIL (" + $fail + ")"); Write-Output 'RETIRE-FOOD-DB-ROW-COMPLETE'; exit 1 }
  Write-Output 'retire-food-db-row SELF-TEST PASS'
  Write-Output 'RETIRE-FOOD-DB-ROW-COMPLETE'
  exit 0
}

# ===================================================================================================
# THE RUN
# ===================================================================================================
if (-not $DbFile)     { $DbFile = Join-Path $mp 'food-macros-db.json' }
if (-not $LedgerFile) { $LedgerFile = Join-Path $mp 'db\food-db-merges.json' }
if (-not @($RefRoots).Count) {
  # Every place a food-DB row is cited by name. db\recipes is the spec store the cards render from;
  # ingredients.json is the vocabulary the canon name resolves through.
  $RefRoots = @((Join-Path $mp 'db\recipes'), (Join-Path $mp 'db\ingredients.json'),
                (Join-Path $mp 'recipes-db.json'), (Join-Path $mp 'db\costed.json'),
                (Join-Path $mp 'db\densities.json'), (Join-Path $mp 'db\each-nouns.json'))
}

if (-not $Retire)   { Die 'pass -Retire <exact row name> (or -SelfTest). An empty run would prove nothing.' }
if (-not $Survivor) { Die 'pass -Survivor <exact row name>: this script records a ruling, it does not make one.' }
if ($Retire -ceq $Survivor) { Die "-Retire and -Survivor are the same row ('$Retire')." }
if (-not $Reason)   { Die 'pass -Reason: a merge with no stated reason is not auditable.' }
if (-not (Test-Path $DbFile)) { Die "no food DB at $DbFile" }

$doc  = Get-Content $DbFile -Raw -Encoding UTF8 | ConvertFrom-Json
$rows = Get-DbRows $doc
if (-not @($rows).Count) { Die "read 0 rows from $DbFile - that is a shape this script does not recognise, not an empty DB." }

$ri = Find-RowIndex $rows $Retire
$si = Find-RowIndex $rows $Survivor
if ($ri -lt 0) { Die "no row named exactly '$Retire' (the match is case sensitive)." }
if ($si -lt 0) { Die "no row named exactly '$Survivor' to retire it in favour of - that would be a deletion, not a merge." }

# THE CITATION SWEEP.
$cites = @()
foreach ($root in $RefRoots) {
  if (-not (Test-Path $root)) { continue }
  $files = if ((Get-Item $root).PSIsContainer) { Get-ChildItem -Path $root -Filter '*.json' -File -Recurse } else { Get-Item $root }
  foreach ($f in $files) {
    $txt = [IO.File]::ReadAllText($f.FullName, $script:UTF8)
    if (Test-NameCited $txt $Retire) { $cites += $f.FullName }
  }
}
if (@($cites).Count) {
  Write-Output ("retire-food-db-row: REFUSED - '$Retire' is still cited by " + @($cites).Count + " file(s):")
  @($cites | Select-Object -First 10) | ForEach-Object { Write-Output ("    " + $_) }
  Write-Output "  A food-DB row is looked up by NAME, so retiring one that is still cited turns a working"
  Write-Output "  macro lookup into a silent absence. Re-point those citations at '$Survivor' first."
  exit 1
}

Write-Output ("retire-food-db-row: '$Retire' -> '$Survivor'")
Write-Output ("  retiring: " + ($rows[$ri] | ConvertTo-Json -Compress -Depth 4))
Write-Output ("  survivor: " + ($rows[$si] | ConvertTo-Json -Compress -Depth 4))
Write-Output ("  cited by: nothing (" + @($RefRoots).Count + " root(s) swept)")

if ($runWhatIf) {
  Write-Output '  -WhatIf: nothing written.'
  Write-Output 'RETIRE-FOOD-DB-ROW-COMPLETE'
  exit 0
}

$at = (Get-Date).ToString('s')
$rec = Get-MergeRecord $rows[$ri] $rows[$si] $Reason $at

$kept = @(); for ($i = 0; $i -lt @($rows).Count; $i++) { if ($i -ne $ri) { $kept += $rows[$i] } }
if ($doc.PSObject.Properties.Name -contains 'items') { $doc.items = $kept; $payload = $doc } else { $payload = $kept }

# UTF8 WITHOUT A BOM, THROUGH WriteAllText. Set-Content defaults to the system ANSI codepage.
$tmp = $DbFile + '.tmp'
[IO.File]::WriteAllText($tmp, ($payload | ConvertTo-Json -Depth 12), $script:UTF8)
Move-Item -Force $tmp $DbFile

$led = if (Test-Path $LedgerFile) { Get-Content $LedgerFile -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
$merges = @(); if ($led -and ($led.PSObject.Properties.Name -contains 'merges')) { $merges = @($led.merges) }
$merges += $rec
$ledDir = Split-Path -Parent $LedgerFile
if ($ledDir -and -not (Test-Path $ledDir)) { New-Item -ItemType Directory -Path $ledDir -Force | Out-Null }
[IO.File]::WriteAllText($LedgerFile, ([ordered]@{
  readme = 'Food-DB duplicate merges. Each record carries BOTH rows verbatim so the merge is reversible from this file alone. Written only by retire-food-db-row.ps1.'
  merges = $merges } | ConvertTo-Json -Depth 12), $script:UTF8)

Write-Output ("  retired. " + @($kept).Count + " row(s) remain; ruling recorded in " + $LedgerFile)
Write-Output 'RETIRE-FOOD-DB-ROW-COMPLETE'
exit 0
