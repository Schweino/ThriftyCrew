<#
  sams-capture-store-lib.ps1 - the Sam's Club capture's #tc-store line, read and ruled on before a row is priced.

  Split out of build-sams-deals.ps1 on 2026-10-02 (design\PLAN-browser-refresh-hardening-2026-10-02.md W1), word
  for word apart from the club-id pin that change added, because that pin pushed the builder past its file-size
  mark (ops\audit-file-size-budget.ps1). build-sams-deals.ps1 dot-sources this file and its self-test drives every
  function here (cases 12a to 12f); nothing else calls them. Reads stores.json beside this file; writes nothing.
  Read-SamsCapture stays in the builder: it calls Import-CaptureCsv, whose drop counters the builder reports, and
  ops/audit-capture-ingest-reporting.ps1 holds each caller of Import-CaptureCsv to that report.
#>
# ---- THE CLUB A CAPTURE WAS READ AT (2026-09-18, backlog I124) -------------------------------------------------
# Sam's prices are per-club. samsIdentity() in pull-sams-instore.js has always READ the club off the page and nothing
# kept it, so this file stamped every sams-deals file club="Omaha Sam's Club, 13130 L St, 68137" from a LITERAL -
# while the session had moved to 15429 Blackwell Dr on 2026-08-15 (pull-browser-stores.py's seed_hint). The feed
# declared a club it never read, the aldi-store-is-ola-42 shape, and nothing on disk could say which club a price
# came from. samsSweepToCsv now opens the capture with one line per distinct club the rows were read at:
#     #tc-store store="15429 Blackwell Dr, Omaha, NE 68116" id="8146" read="page" rows=152
# and this is the one place that line is ruled on. The capture is REFUSED, and nothing is written, when it has:
#   no store line                 it cannot say which club it read (unless -WaiveMissingStoreLine, see param)
#   a store line that won't parse a club we cannot read is a club we did not read
#   store="UNRECORDED"            some rows were persisted by an agent that did not keep the club
#   a store without "Omaha"       another city's club
#   more than one store           one file names one club, and a sweep that straddled two cannot
# THE CLUB IS PINNED, BY ID, SINCE 2026-10-02 (Brad's ruling; design\PLAN-browser-refresh-hardening-2026-10-02.md W1).
# Until then it was only RECORDED, because no ruling named a club, and the line was ruled on by a WORD: any store
# containing "Omaha" passed, the Walmart-3153 shape gr-07 closed for Walmart. Brad ruled 13130 L St, 68137, which
# samsclub.com names club #8146; stores.json -> Sam's Club -> store_identity.club_id holds it, and
# pull-sams-instore.js mirrors it as SAMS_SANCTIONED_CLUB (this file's self-test fails when they disagree). The line
# now carries the id each search RESPONSE named (samsResponseClub, the PICKUP storeId on its item nodes):
#     #tc-store store="Omaha Sam's Club" id="8146" read="response" rows=152
# and the capture is ALSO refused when a line has no id (a capture older than the id; there is no waiver, because a
# price whose club cannot be named by id is exactly what this ruling exists to keep off the board), an id of
# UNRECORDED, or any id but the sanctioned club. The store label stays as the page read it, and the word test on it
# stays too: it is weaker than the id and costs nothing.
# WHY REFUSE RATHER THAN BUILD AND FLAG: compare-deals unions Sam's slices across 14 days and the cursor advances only
# on a written file, so a refused capture costs one repeated slice; a file written anyway carries a club nobody read.
# Both copies of the line's text live in this file and in pull-sams-instore.js, and test-pull-agent-lib.ps1 pins the
# emitter's exact bytes while this file's self-test pins the parser.
function Split-SamsCaptureStore {
  param([string[]]$Lines, [string]$Sanctioned = (Get-SamsSanctionedClub $PSScriptRoot))
  $cols = 'q|n|lp|up|id|was'
  $kept   = New-Object System.Collections.ArrayList
  $stores = New-Object System.Collections.ArrayList
  $bad    = New-Object System.Collections.ArrayList
  $sawColumns = $false
  foreach ($ln in $Lines) {
    $s = [string]$ln
    if ($s -match '^\s*#tc-store\b') {
      $m = [regex]::Match($s, '^\s*#tc-store\s+store="([^"]*)"(?:\s+id="([^"]*)")?\s+read="([^"]*)"\s+rows=(\d+)\s*$')
      if ($m.Success) { [void]$stores.Add([pscustomobject]@{ store = $m.Groups[1].Value.Trim(); id = $m.Groups[2].Value.Trim(); read = $m.Groups[3].Value.Trim(); rows = [int]$m.Groups[4].Value }) }
      else { [void]$bad.Add($s.Trim()) }
      continue
    }
    # A same-day rescue appends a second sweep's output to a copy of the morning capture, header and all
    # ([[same-day-rescue-rebuilds-per-store]]). The second header is not a record. Both the six-column header and the
    # older five-column one are recognised; only an EXACT copy of the first header seen is dropped.
    $t = $s.Trim()
    # 'q|n|lp|up|id|was|ful' is the seven-column header samsSweepToCsv writes since 2026-09-19 (the `ful` channel).
    if ([string]::Equals($t, 'q|n|lp|up|id|was|ful', [StringComparison]::Ordinal) -or [string]::Equals($t, $cols, [StringComparison]::Ordinal) -or [string]::Equals($t, 'q|n|lp|up|id', [StringComparison]::Ordinal)) {
      if ($sawColumns) { continue }
      $sawColumns = $true
    }
    [void]$kept.Add($s)
  }
  # ORDINAL throughout: this text arrived from a web page (ops-and-gates.md, -ne ignores NUL).
  $distinct = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  $ids = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  $total = 0
  $unrec = New-Object System.Collections.ArrayList
  $notOmaha = New-Object System.Collections.ArrayList
  $noId = New-Object System.Collections.ArrayList
  $otherId = New-Object System.Collections.ArrayList
  foreach ($x in $stores) {
    [void]$distinct.Add($x.store)
    $total += $x.rows
    if (-not $x.store -or [string]::Equals($x.store, 'UNRECORDED', [StringComparison]::Ordinal) -or
        [string]::Equals($x.id, 'UNRECORDED', [StringComparison]::Ordinal)) { [void]$unrec.Add($x) }
    elseif (-not $x.id) { [void]$noId.Add($x) }
    elseif ($x.store -notmatch '(?i)\bOmaha\b') { [void]$notOmaha.Add($x) }
    elseif (-not [string]::Equals($x.id, $Sanctioned, [StringComparison]::Ordinal)) { [void]$otherId.Add($x) }
    if ($x.id) { [void]$ids.Add($x.id) }
  }
  $why = ''
  if ($bad.Count) {
    $why = ('a store line does not parse: [' + $bad[0] + '] - a club we cannot read is a club we did not read.')
  } elseif ($stores.Count -eq 0) {
    $why = 'the capture carries no #tc-store line, so it cannot say which Sam''s Club it read. Re-capture through samsSweepToCsv in pull-sams-instore.js, which writes one; never hand-assemble this file.'
  } elseif (-not $Sanctioned) {
    $why = 'stores.json names no Sam''s Club store_identity.club_id, so no club can be sanctioned and none is assumed.'
  } elseif ($unrec.Count) {
    $n = 0; foreach ($x in $unrec) { $n += $x.rows }
    $why = ('{0} row(s) were captured with no club read (store or id "UNRECORDED"), so they cannot be attributed to any club.' -f $n)
  } elseif ($noId.Count) {
    $why = ('the store line names no club id (it predates the 2026-10-02 pin), so the rows cannot be shown to be the board''s club ' + $Sanctioned + '. Re-capture through samsSweepToCsv in pull-sams-instore.js.')
  } elseif ($notOmaha.Count) {
    $why = ('club "{0}" is not an Omaha club.' -f $notOmaha[0].store)
  } elseif ($otherId.Count) {
    $why = ('the capture was read at club {0}, not the board''s club {1} (13130 L St, Brad''s ruling 2026-10-02). Switch the club in Brad''s Chrome and re-capture.' -f $otherId[0].id, $Sanctioned)
  } elseif ($ids.Count -gt 1) {
    $why = ('the sweep straddles {0} club ids ({1}) - one file names one club.' -f $ids.Count, (@($ids) -join '; '))
  } elseif ($distinct.Count -gt 1) {
    $why = ('the sweep straddles {0} clubs ({1}) - one file names one club.' -f $distinct.Count, (@($distinct) -join '; '))
  }
  $store = ''; $read = ''; $clubId = ''
  if (-not $why) { $store = $stores[0].store; $read = $stores[0].read; $clubId = $stores[0].id }
  return @{ lines = $kept.ToArray(); store = $store; id = $clubId; read = $read; rows = $total; refuse = $why }
}

# The board's club id, from the registry (2026-10-02). '' when stores.json names none, which Split-SamsCaptureStore
# refuses: a club we cannot rule on is not a club we may assume (Get-FarewaySanctionedLocation's rule).
function Get-SamsSanctionedClub([string]$Root) {
  $f = Join-Path $Root 'stores.json'
  if (-not (Test-Path -LiteralPath $f)) { return '' }
  $reg = [IO.File]::ReadAllText($f, [Text.Encoding]::UTF8) | ConvertFrom-Json
  foreach ($st in @($reg.stores)) {
    if ([string]$st.name -eq "Sam's Club" -and $st.store_identity -and $st.store_identity.club_id) { return [string]$st.store_identity.club_id }
  }
  return ''
}

# What the doc-level `club` says. The club READ when there is one; an explicit NOT RECORDED under the waiver.
function Get-SamsClubLabel($cs, [bool]$waived) {
  if ($waived) { return 'club NOT RECORDED in the capture - it predates the #tc-store line, built under -WaiveMissingStoreLine, so the basis of these rows rests on whoever captured them' }
  return [string]$cs.store
}
