<#
  HOLD SCOPE: cell - a regression names each violated row's board cell (QUARANTINE-CELL <id>|<store>|value); a violation
  no board cell carries, live or held, is named QUARANTINE-OFFBOARD and holds nothing (guards WARNs it; queue
  2026-09-26-f73dc7); with no readable board, or a violated row with no name, nothing is affirmed and the board holds
  (queue 2026-09-22-6e6a3b; test-asof-evidence-scope.ps1)
  audit-asof-evidence.ps1 - "no published price may claim a date newer than the capture it came from."

  WHY THIS EXISTS (2026-08-02, found by the C3 out-of-band sample).
  build-fareway-regular.ps1 merges EVERY out\fareway\fareway-shop-<date>.json extract and takes
  last-writer-wins per commodity. That merge is a coverage feature. But it used to stamp every emitted row
  with the BUILD date, so a price read off a 10-day-old extract shipped wearing today's date. Measured on
  the live 2026-08-01 file before the fix: 431 of 577 rows carried a date NEWER than the extract that
  supplied them, and 450 rows claimed as_of=2026-08-01 when only 27 commodities' winning row came from that
  day's extract.

  WHY A LAUNDERED DATE IS WORSE THAN A MISSING ONE, and why this needs a guard of its own rather than just
  the builder fix. Every freshness check in this estate is a comparison against as_of:
    - guards.ps1 guard 9 reports "% re-verified against the store TODAY" as rows where as_of == today.
      The laundering fed it a fabricated 78% against a true 6%. A staleness detector reading a number the
      builder wrote to be true is not a detector.
    - carry-forward-regular.ps1 expires a carried row from its ORIGINAL as_of. A laundered date resets that
      clock on every build, so the carry cap can never expire the row it was written to expire.
    - generate-board-overrides.ps1 accepts a feed row as corroboration only inside a 2-day as_of window.
    - sync-browser-links.ps1 only touches rows priced TODAY.
  Each of those is correct code reading a fabricated input, which is why the shopper-visible symptom was a
  price and not a date: 'Fareway Ranch Dressing' $0.99 last appeared in the 07-23/07-27/07-31 extracts, was
  absent from 08-01, published as_of 2026-08-01, and the store charges $2.48 - the board printed $0.0619/floz
  against a real $0.155. Three of the four defects the C3 sample found are this one mechanism.

  THE INVARIANT. For a store whose prices come from dated capture files, a row's as_of can never be later
  than the newest capture on disk that contains that product. A row that is fresher than any evidence for it
  is a date somebody wrote rather than measured. The check is deliberately DIRECTIONAL: an as_of OLDER than
  the newest sighting is fine (carry-forward keeps a row's original date on purpose, and a re-sighting at the
  same price does not re-verify anything this script can see).

  WHAT IT DOES NOT CLAIM. Rows whose product name appears in NO extract are counted and reported separately
  as UNBACKED, never as violations: heal-degraded-sizes, the API pullers and hand-verified rows all write
  real prices this surface has no evidence about, and calling them violations would delete verified data to
  satisfy a check. Naming them is the point - a store whose rows are mostly unbacked is a store this guard
  is mostly not watching, and that has to be visible rather than read as a clean pass.

  RATCHET, not a hard gate, for the reason audit-tile-integrity is one: it is 1 today (a Fareway row carried
  out of a regular file that was BUILT BEFORE the fix, so it inherited a laundered date; it expires on its
  own when that file ages past the carry cap). A gate that fails from day one is a gate that gets switched
  off. It fails when a store gets WORSE than out\asof-evidence-baseline.json, so the number can only go down.

  Exit codes: 0 clean/at-or-under baseline | 2 a store regressed (1 until 2026-09-25: guards scopes only an exit 2)
  | 3 could not evaluate (named, not silent).
  Usage: .\audit-asof-evidence.ps1 [-Baseline] [-Quiet] [-SelfTest]
#>
# WHAT THE SELF-TEST READS: only fixture captures and regular files it writes under a per-run temp root.
# gate-inputs: grocery\audit-asof-evidence.ps1
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop (2026-09-07)
param([switch]$Baseline, [switch]$Quiet, [switch]$SelfTest, [string]$Root = "")
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
$root = if ($Root) { $Root } elseif ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\grocery' }

# The stores whose everyday prices come from DATED capture files. A store absent from this table is not
# "clean", it is UNWATCHED, and the report says so by name rather than leaving a silent gap.
#   json = a JSON array of capture rows with a .name field   (Fareway storefront DOM extractor)
#   csv  = the pipe-delimited storefront sweep, name in col 3 (Aldi: id|term|name|prices|unit|size|href)
#   raw  = (optional) the RAW capture beside the selected one, a JSONL of {id, term, candidates[{name,...}]}.
#          The .json is select-fareway-shop's per-commodity WINNER, re-derived from the raw capture every time the
#          selection runs; the .jsonl is what the page actually showed. A product the store showed on date D is
#          seen on D whether or not it won its commodity's slot on the last selection pass (2026-09-26, queue
#          2026-09-26-e0d5cf: the 06:58 build dated 'Webster City Bacon Ends' $11.99 to the 09-26 capture that
#          held it, the 08:0x re-selection gave the bacon slot to a sale row, and this audit - reading only the
#          winners - called a measured date laundered and held the whole board).
$SOURCES = @(
  @{ store = 'Fareway'; prefix = 'fareway'; glob = 'out\fareway\fareway-shop-*.json';    kind = 'json'; raw = 'out\fareway\fareway-shop-*.jsonl' },
  @{ store = 'Aldi';    prefix = 'aldi';    glob = 'out\captures\aldi-capture-*.csv';    kind = 'csv'; nameIx = 2 }
)
# Stores deliberately NOT checkable here, with the reason, so "2 of 7 stores" never reads as a pass for the
# other five. Baker's/Hy-Vee/Family Fare pull through APIs that stamp as_of at fetch time from the same clock
# the row is written on - there is no separate dated artefact to disagree with. Sam's and Walmart ship
# freshness-ranked unions of dated files, which is a different mechanism with its own guard (guard 6).
$UNWATCHED = @(
  "Baker's (Kroger API - as_of is stamped at fetch, no separate dated artefact to check it against)",
  'Hy-Vee (Aisles Online API - same)',
  'Family Fare (headless pull - same)',
  "Sam's Club (dated-file union ranked by freshness, guard 6 owns it)",
  'Walmart (dated-file union ranked by freshness, guard 6 owns it)'
)

function Get-EvidenceKey([string]$s) {
  # Fold to the shape both surfaces agree on. The capture and the built row are the SAME string today, but
  # keying on the raw name would turn any future punctuation change into a wave of phantom violations, and a
  # guard that cries wolf is a guard that gets ignored. Collapsing too much only ever HIDES a violation,
  # which is the safe direction for a ratchet whose whole job is to detect an increase.
  $k = ([string]$s).ToLower().Trim()
  $k = ($k -replace '[^a-z0-9]', ' ')
  return ($k -replace '\s+', ' ').Trim()
}

function Get-LastSeen([string]$glob, [string]$kind, [int]$nameIx, [string]$base, [string]$rawGlob = '') {
  $seen = @{}
  $ext = [IO.Path]::GetExtension($glob)
  $files = @(Get-ChildItem (Join-Path $base $glob) -ErrorAction SilentlyContinue |
             Where-Object { $_.BaseName -match '\d{4}-\d{2}-\d{2}$' -and $_.Extension -eq $ext } | Sort-Object Name)
  if ($rawGlob) {
    # The raw capture's candidates are sightings too. Walked FIRST and kept as the newest date per name, so the
    # selected files below (also newest-wins) can only ever agree with or move a date forward to a real sighting.
    $rext = [IO.Path]::GetExtension($rawGlob)
    $rawFiles = @(Get-ChildItem (Join-Path $base $rawGlob) -ErrorAction SilentlyContinue |
                  Where-Object { $_.BaseName -match '\d{4}-\d{2}-\d{2}$' -and $_.Extension -eq $rext } | Sort-Object Name)
    foreach ($f in $rawFiles) {
      $dt = [regex]::Match($f.BaseName, '(\d{4}-\d{2}-\d{2})$').Groups[1].Value
      foreach ($line in [IO.File]::ReadAllLines($f.FullName, [Text.Encoding]::UTF8)) {
        if (-not $line.Trim()) { continue }
        $o = $null; try { $o = $line | ConvertFrom-Json } catch { continue }
        if ($null -eq $o -or -not $o.PSObject.Properties['candidates']) { continue }
        foreach ($c in @($o.candidates)) {
          if ($null -eq $c -or -not $c.PSObject.Properties['name']) { continue }
          $k = Get-EvidenceKey ([string]$c.name)
          if ($k -and (-not $seen.ContainsKey($k) -or $dt -gt $seen[$k])) { $seen[$k] = $dt }
        }
      }
    }
  }
  foreach ($f in $files) {
    $dt = [regex]::Match($f.BaseName, '(\d{4}-\d{2}-\d{2})$').Groups[1].Value
    if ($kind -eq 'json') {
      $rows = $null
      try { $rows = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
      foreach ($r in @($rows)) {
        if (-not $r.PSObject.Properties['name']) { continue }
        $k = Get-EvidenceKey ([string]$r.name)
        if ($k -and (-not $seen.ContainsKey($k) -or $dt -gt $seen[$k])) { $seen[$k] = $dt }   # files walked oldest-first, so the last write is the newest sighting
      }
    } else {
      foreach ($line in (Get-Content $f.FullName -Encoding UTF8)) {
        $p = $line -split '\|'
        if ($p.Count -le $nameIx) { continue }
        $k = Get-EvidenceKey $p[$nameIx]
        if ($k -and (-not $seen.ContainsKey($k) -or $dt -gt $seen[$k])) { $seen[$k] = $dt }
      }
    }
  }
  return @{ seen = $seen; files = $files.Count }
}

function Invoke-AsOfEvidence([string]$base) {
  $out = [ordered]@{ stores = @(); unwatched = $UNWATCHED; blind = @() }
  $stores = New-Object System.Collections.Generic.List[object]
  foreach ($s in $SOURCES) {
    $regF = @(Get-ChildItem (Join-Path $base ('out\regular\' + $s.prefix + '-regular-*.json')) -ErrorAction SilentlyContinue |
              Where-Object { $_.BaseName -match '\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Descending | Select-Object -First 1)
    if ($regF.Count -eq 0) { $out.blind += ("{0}: no out\regular\{1}-regular-<date>.json to check" -f $s.store, $s.prefix); continue }
    $doc = $null
    try { $doc = Read-JsonFile $regF[0].FullName } catch {
      $out.blind += ("{0}: {1} did not parse - {2}" -f $s.store, $regF[0].Name, $_.Exception.Message); continue
    }
    $rows = @($doc.deals)
    if ($rows.Count -eq 0) { $out.blind += ("{0}: {1} parsed to ZERO rows" -f $s.store, $regF[0].Name); continue }
    $nameIx = if ($s.ContainsKey('nameIx')) { [int]$s.nameIx } else { 0 }
    $rawG = if ($s.ContainsKey('raw')) { [string]$s.raw } else { '' }
    $ev = Get-LastSeen $s.glob $s.kind $nameIx $base $rawG
    if ($ev.files -eq 0) { $out.blind += ("{0}: no dated capture files matched {1} - this store's dates are unchecked, NOT clean" -f $s.store, $s.glob); continue }
    $viol = New-Object System.Collections.Generic.List[object]
    $unbacked = 0; $checked = 0
    foreach ($r in $rows) {
      if (-not $r.PSObject.Properties['as_of']) { continue }
      $ao = [string]$r.as_of
      if ($ao -notmatch '^\d{4}-\d{2}-\d{2}$') { continue }
      $k = Get-EvidenceKey ([string]$r.item)
      if (-not $k -or -not $ev.seen.ContainsKey($k)) { $unbacked++; continue }
      $checked++
      # String compare is exact for ISO dates and cannot throw on a malformed one, unlike [datetime].
      if ($ao -gt $ev.seen[$k]) {
        $viol.Add([ordered]@{ item = [string]$r.item; says = $ao; evidence = $ev.seen[$k]; price = [string]$r.ad_price })
      }
    }
    $stores.Add([ordered]@{
      store = $s.store; file = $regF[0].Name; rows = $rows.Count; checked = $checked
      unbacked = $unbacked; capture_files = $ev.files; violations = $viol.Count; detail = @($viol.ToArray())
    })
  }
  $out.stores = @($stores.ToArray())
  return $out
}

# The board cells a set of stores' violations priced. Returns { keys = '<id>|<store>'; offboard = 'store|item' } or $null.
# $null - FAIL CLOSED, the board holds - when the evidence to place a violation is missing: no board, an unreadable one,
# or a violated row with no name to look up. A violation whose store and folded name NO cell carries, live or held by an
# applied quarantine, is OFF-BOARD (2026-09-26, queue 2026-09-26-f73dc7): it cannot put a wrong number on the page, so it
# holds nothing and guards reports it as a WARN. Founding case: 'Webster City Bacon Ends' (Fareway) held the whole
# 2026-09-26 board from no cell at all.
function Get-AsOfViolationCells($Stores, [string]$Base) {
  $bf = @(Get-ChildItem (Join-Path $Base 'out\comparison-*.json') -ErrorAction SilentlyContinue |
          Where-Object { $_.Name -match '^comparison-\d{4}-\d{2}-\d{2}\.json$' } | Sort-Object Name -Descending | Select-Object -First 1)
  if ($bf.Count -eq 0) { return $null }
  $board = $null; try { $board = Read-JsonFile $bf[0].FullName } catch { return $null }
  if ($null -eq $board -or $null -eq $board.PSObject.Properties['comparison']) { return $null }
  $at = @{}
  foreach ($r in @($board.comparison)) {
    if ($null -eq $r) { continue }
    foreach ($s in @($r.stores)) { if ($null -eq $s) { continue }; $k = [string]$s.store + '|' + (Get-EvidenceKey ([string]$s.item)); if (-not $at.ContainsKey($k)) { $at[$k] = New-Object System.Collections.Generic.List[string] }; [void]$at[$k].Add([string]$r.id) }
  }
  # A cell an applied quarantine holds is still this row's cell: its held-back candidate is bad_item, so the second guards
  # run names it again (the hold stays) instead of calling it off-board.
  if ($board.PSObject.Properties['quarantine'] -and $board.quarantine) {
    foreach ($e in @($board.quarantine.cells)) {
      if ($null -eq $e -or -not [string]$e.bad_item) { continue }
      $k = [string]$e.store + '|' + (Get-EvidenceKey ([string]$e.bad_item)); if (-not $at.ContainsKey($k)) { $at[$k] = New-Object System.Collections.Generic.List[string] }
      if (-not $at[$k].Contains([string]$e.id)) { [void]$at[$k].Add([string]$e.id) }
    }
  }
  $keys = New-Object System.Collections.Generic.List[string]
  $off = New-Object System.Collections.Generic.List[string]
  foreach ($st in @($Stores)) {
    foreach ($v in @($st.detail)) {
      $ek = Get-EvidenceKey ([string]$v.item)
      if (-not $ek -or -not [string]$st.store) { return $null }
      $k = [string]$st.store + '|' + $ek
      if (-not $at.ContainsKey($k)) { $o = [string]$st.store + '|' + ([string]$v.item).Trim(); if (-not $off.Contains($o)) { [void]$off.Add($o) }; continue }
      foreach ($id in $at[$k]) { $kk = $id + '|' + [string]$st.store; if (-not $keys.Contains($kk)) { [void]$keys.Add($kk) } }
    }
  }
  return [pscustomobject]@{ keys = $keys.ToArray(); offboard = $off.ToArray() }
}

if ($SelfTest) {
  $fail = 0
  $T = Join-Path $env:TEMP ('asofev-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Path (Join-Path $T 'out\regular') -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $T 'out\fareway') -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $T 'out\captures') -Force | Out-Null
  try {
    # FROZEN FIXTURE - the founding bug verbatim. 'Fareway Ranch Dressing' $0.99 last appears in the
    # 2026-07-23 extract and is absent from 2026-08-01, yet the regular file dates it 2026-08-01. The store
    # charges $2.48. This is what the C3 sample caught at the shelf, and it MUST fire.
    (@(
      @{ id = 'ranch-dressing'; name = 'Fareway Ranch Dressing'; price = '0.99'; size = '16 fl oz' },
      @{ id = 'tomatoes';       name = 'NatureSweet Cherubs Tomatoes'; price = '9.99'; size = '10 oz' }
    ) | ConvertTo-Json -Depth 4) | Set-Content (Join-Path $T 'out\fareway\fareway-shop-2026-07-23.json') -Encoding UTF8
    (@(
      @{ id = 'tomatoes'; name = 'NatureSweet Cherubs Tomatoes'; price = '3.99'; size = '10 oz' }
    ) | ConvertTo-Json -Depth 4) | Set-Content (Join-Path $T 'out\fareway\fareway-shop-2026-08-01.json') -Encoding UTF8
    @{ store = 'Fareway'; price_type = 'everyday'; deals = @(
      @{ store = 'Fareway'; item = 'Fareway Ranch Dressing'; ad_price = '$0.99'; size = '16 fl oz'; as_of = '2026-08-01' },
      # CLEAN TWIN 1: dated to the extract that holds it - the whole point is that this must NOT fire.
      @{ store = 'Fareway'; item = 'NatureSweet Cherubs Tomatoes'; ad_price = '$3.99'; size = '10 oz'; as_of = '2026-08-01' },
      # CLEAN TWIN 2: an as_of OLDER than the newest sighting is lawful (carry-forward keeps original dates).
      @{ store = 'Fareway'; item = 'Fareway Ranch Dressing'; ad_price = '$0.99'; size = '16 fl oz'; as_of = '2026-07-23' },
      # CLEAN TWIN 3: no extract has ever seen this product -> UNBACKED, counted, never a violation.
      @{ store = 'Fareway'; item = 'Hand Verified Mystery Item'; ad_price = '$1.00'; size = '1 ct'; as_of = '2026-08-01' }
    ) } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $T 'out\regular\fareway-regular-2026-08-01.json') -Encoding UTF8
    # Aldi: pipe-delimited capture, and a row dated a day AFTER its only sighting.
    "eggs|eggs|goldhen grade a large eggs 12 ct|`$1.65|||https://x" | Set-Content (Join-Path $T 'out\captures\aldi-capture-2026-07-29.csv') -Encoding UTF8
    @{ store = 'Aldi'; price_type = 'everyday'; deals = @(
      @{ store = 'Aldi'; item = 'goldhen grade a large eggs 12 ct'; ad_price = '$1.65'; size = 'dozen'; as_of = '2026-07-30' }
    ) } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $T 'out\regular\aldi-regular-2026-07-30.json') -Encoding UTF8

    $res = Invoke-AsOfEvidence $T
    $fw = @($res.stores | Where-Object { $_.store -eq 'Fareway' })[0]
    $al = @($res.stores | Where-Object { $_.store -eq 'Aldi' })[0]
    function Chk([string]$label, [bool]$cond, [string]$got) {
      if ($cond) { Write-Output ("ok    " + $label) } else { Write-Output ("FAIL  " + $label + "   got: " + $got); $script:fail++ }
    }
    Chk 'MUST FIRE  ranch dressing dated 08-01 with 07-23 evidence' ($fw.violations -eq 1) ("violations=$($fw.violations)")
    Chk 'MUST FIRE  the violation NAMES the product and both dates' (($fw.detail.Count -eq 1) -and ($fw.detail[0].item -match 'Ranch Dressing') -and ($fw.detail[0].evidence -eq '2026-07-23')) (($fw.detail | ConvertTo-Json -Compress))
    Chk 'MUST NOT FIRE row dated to the extract that holds it does NOT fire' (-not (@($fw.detail | Where-Object { $_.item -match 'Cherubs' }).Count)) 'tomatoes flagged'
    Chk 'MUST NOT FIRE an as_of OLDER than the evidence is lawful (carry-forward)' (-not (@($fw.detail | Where-Object { $_.says -eq '2026-07-23' }).Count)) 'older row flagged'
    Chk 'UNBACKED row is counted, never a violation' ($fw.unbacked -eq 1 -and $fw.checked -eq 3) ("unbacked=$($fw.unbacked) checked=$($fw.checked)")
    Chk 'MUST FIRE  the CSV surface works too (Aldi, 1 violation)' ($al -and $al.violations -eq 1) ("violations=$($al.violations)")
    Chk 'unwatched stores are NAMED, so 2-of-7 never reads as a pass' ($res.unwatched.Count -ge 5) ("unwatched=$($res.unwatched.Count)")
    # FROZEN FIXTURE 2026-09-26 (queue 2026-09-26-e0d5cf), verbatim. 'Webster City Bacon Ends' $11.99 was read on
    # 09-26 (it is a candidate in fareway-shop-2026-09-26.jsonl) and the regular file dated it 09-26, but the later
    # re-selection gave the bacon slot to 'Fareway Hickory Smoked Bacon', so the SELECTED 09-26 file lacks it and
    # its newest selected sighting is 09-25. MUST NOT FIRE: a raw sighting on 09-26 backs the 09-26 date.
    # MUST FIRE twin: the same row dated 09-27, a day no capture - raw or selected - ever saw it.
    $B = Join-Path $T 'bacon'
    foreach ($d in @('out\regular', 'out\fareway')) { New-Item -ItemType Directory -Path (Join-Path $B $d) -Force | Out-Null }
    $bu = New-Object Text.UTF8Encoding($false)
    $bacon = 'Webster City Bacon Ends'
    [IO.File]::WriteAllText((Join-Path $B 'out\fareway\fareway-shop-2026-09-25.json'), ('[{"id":"bacon","name":"' + $bacon + '","price":"11.99"}]'), $bu)
    [IO.File]::WriteAllText((Join-Path $B 'out\fareway\fareway-shop-2026-09-26.json'), '[{"id":"bacon","name":"Fareway Hickory Smoked Bacon","price":"2.99"}]', $bu)
    [IO.File]::WriteAllText((Join-Path $B 'out\fareway\fareway-shop-2026-09-26.jsonl'), ('{"id":"bacon","term":"bacon","candidates":[{"name":"Fareway Hickory Smoked Bacon","price":"2.99"},{"name":"' + $bacon + '","price":"11.99","loc":"531573"}]}' + "`n"), $bu)
    [IO.File]::WriteAllText((Join-Path $B 'out\regular\fareway-regular-2026-09-27.json'), ('{"store":"Fareway","deals":[' +
      '{"store":"Fareway","item":"' + $bacon + '","ad_price":"$11.99","as_of":"2026-09-26"},' +
      '{"store":"Fareway","item":"' + $bacon + '","ad_price":"$11.99","as_of":"2026-09-27"}]}'), $bu)
    $res3 = Invoke-AsOfEvidence $B
    $fw3 = @($res3.stores | Where-Object { $_.store -eq 'Fareway' })[0]
    Chk 'MUST NOT FIRE a row dated to a RAW capture sighting (jsonl candidate) is backed, though the selected file dropped it (bacon ends 09-26)' ($fw3 -and -not (@($fw3.detail | Where-Object { $_.says -eq '2026-09-26' }).Count)) (($fw3.detail | ConvertTo-Json -Compress))
    Chk 'MUST FIRE  the same row dated 09-27, past every raw and selected sighting, still fires with evidence 09-26' ($fw3 -and $fw3.violations -eq 1 -and $fw3.detail[0].says -eq '2026-09-27' -and $fw3.detail[0].evidence -eq '2026-09-26') (($fw3.detail | ConvertTo-Json -Compress))
    Chk 'CLEAN TWIN a .jsonl is never read as a selected .json file (2 selected capture files counted, not 3)' ($fw3 -and $fw3.capture_files -eq 2) ("capture_files=$($fw3.capture_files)")
    # BLIND: a store with a regular file but no capture files at all must be named, not scored clean.
    Remove-Item (Join-Path $T 'out\captures\aldi-capture-2026-07-29.csv') -Force
    $res2 = Invoke-AsOfEvidence $T
    Chk 'no capture files -> BLIND and named, NOT a clean zero' ((@($res2.stores | Where-Object { $_.store -eq 'Aldi' }).Count -eq 0) -and (@($res2.blind | Where-Object { $_ -match 'Aldi' }).Count -eq 1)) (($res2.blind -join ' | '))
  } finally { Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue }
  if ($fail -eq 0) { Write-Output 'SELF-TEST PASS'; exit 0 } else { Write-Output "SELF-TEST FAIL: $fail case(s)"; exit 1 }
}

$res = Invoke-AsOfEvidence $root
$basePath = Join-Path $root 'out\asof-evidence-baseline.json'
$base = @{}
if (Test-Path $basePath) {
  try { $bd = Read-JsonFile $basePath; foreach ($p in $bd.PSObject.Properties) { $base[$p.Name] = [int]$p.Value } } catch {}
}

$outPath = Join-Path $root 'out\asof-evidence.json'
$res | ConvertTo-Json -Depth 6 | Set-Content $outPath -Encoding UTF8

if (-not $Quiet) {
  Write-Output 'as_of evidence (no published price may claim a date newer than the capture it came from)'
  foreach ($s in $res.stores) {
    Write-Output ("  {0,-12} {1,4} rows | {2,4} checked against {3} capture file(s) | {4} unbacked (no capture evidence either way) | {5} violation(s)" -f $s.store, $s.rows, $s.checked, $s.capture_files, $s.unbacked, $s.violations)
    foreach ($v in @($s.detail | Select-Object -First 8)) {
      Write-Output ("      {0}  says {1} but the newest capture holding it is {2}  ({3})" -f $v.item, $v.says, $v.evidence, $v.price)
    }
  }
  foreach ($b in $res.blind) { Write-Output ("  BLIND  " + $b) }
  Write-Output ("  NOT WATCHED by this check (no dated artefact to disagree with): " + ($res.unwatched -join '; '))
}

if ($Baseline) {
  $nb = [ordered]@{}
  foreach ($s in $res.stores) { $nb[[string]$s.store] = [int]$s.violations }
  $nb | ConvertTo-Json -Depth 3 | Set-Content $basePath -Encoding UTF8
  Write-Output ("baseline written: " + (($res.stores | ForEach-Object { "$($_.store)=$($_.violations)" }) -join ' '))
  exit 0
}

# A store with NO evaluable rows is not a pass. Exit 3 (blind) is the estate's "could not evaluate" code and
# guards.ps1 surfaces it as a WARN naming what went unproven.
if ($res.stores.Count -eq 0) {
  Write-Output 'asof-evidence: NOTHING was evaluable - no store had both a regular file and dated captures.'
  exit 3
}
$worse = @()
foreach ($s in $res.stores) {
  $b = if ($base.ContainsKey([string]$s.store)) { [int]$base[[string]$s.store] } else { 0 }
  if ([int]$s.violations -gt $b) { $worse += ("{0}: {1} row(s) claim a date no capture supports, baseline {2}" -f $s.store, $s.violations, $b) }
}
if ($worse.Count -gt 0) {
  # THE QUARANTINE PROTOCOL (2026-09-25, queue 2026-09-22-6e6a3b; cell-quarantine-lib.ps1 Get-TcChildQuarantineScope).
  # Every violation of a store that got worse is named as the board cell it priced, found on the newest comparison
  # board by store and the same folded name Get-EvidenceKey uses. It is a VALUE hold: the founding row's $0.99 was a
  # price the store no longer charged, so the number itself is never re-shown. A violation NO cell carries is named
  # OFF-BOARD and holds nothing (2026-09-26, queue 2026-09-26-f73dc7). Only when every violation is placed one way or the
  # other is the scope affirmed; when the board cannot be read, or a violated row has no name, nothing is affirmed and the
  # board holds as before.
  $placed = Get-AsOfViolationCells -Stores @($res.stores | Where-Object { $worse -match ('^' + [regex]::Escape([string]$_.store) + ':') }) -Base $root
  if ($null -ne $placed -and (@($placed.keys).Count + @($placed.offboard).Count) -gt 0) {
    foreach ($kk in @($placed.keys)) { Write-Output ('QUARANTINE-CELL ' + $kk + '|value') }
    foreach ($ob in @($placed.offboard)) { Write-Output ('QUARANTINE-OFFBOARD ' + $ob) }
    Write-Output ('QUARANTINE-SCOPE complete cells=' + @($placed.keys).Count + ' stores=0 offboard=' + @($placed.offboard).Count)
  }
  Write-Output ('asof-evidence FAIL - a store got WORSE than out\asof-evidence-baseline.json: ' + ($worse -join ' | '))
  Write-Output '  A row fresher than any capture that saw it is a date somebody wrote rather than measured, and every freshness check downstream (guard 9, the carry cap, the override window, link sync) reads it as truth.'
  exit 2
}
if ($res.blind.Count -gt 0) { exit 3 }
exit 0
