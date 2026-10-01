# soundness-publish-lib.ps1 - which matching-soundness findings HOLD the reader-facing post.
#
# Brad's ruling Q-2026-09-25-2-A (2026-09-25, option A): the matching-soundness gate in publish-deals-page.ps1
# holds the page post ONLY when a product that WINS a published board cell (any store column, crown or not)
# MOVED, DROPPED or became CONTESTED against the reviewed baseline. A change that touches only products on no
# board cell does not hold the post: it prints a REVIEW line and the baseline still waits for
# `audit-match-soundness.ps1 -Accept`. Before this, ANY moved or dropped name held the post, including names no
# cell reads, and that held it on 6 of 23 run days (2026-09-01..25) for correct rule changes that REMOVED wrong
# products (queue 2026-09-23-80f302).
#
# FAILS CLOSED. A report that cannot be read, is older than the audit run that should have written it, or has
# changes but cannot be joined to a board with at least one named cell, HOLDS. "Off-board" is proven by the
# join, never assumed (memory ruling-soundness-hold-only-on-published-cell).
#
# Known limit (leaves_open on 2026-09-23-80f302): the join reads the board being PUBLISHED. A DROPPED product
# is by construction on no cell of a board rebuilt under the new rules, so a drop of a product that won a cell
# on the PREVIOUS live board does not hold here; its cell is re-won by the next product the new rule admits.
#
# Dot-sourced by audit-match-soundness.ps1 (Get-CellNames / Select-CellByContest live here now so there is ONE
# implementation of "which names hold a cell") and by publish-deals-page.ps1. Fixtures: audit-match-soundness.ps1
# -SelfTest, the PUBLISH-HOLD cases.
#
# A FINDING ON A WINNING CELL QUARANTINES THAT CELL (Brad's ruling Q-2026-09-29-4-A, 2026-09-30; queue 2026-09-30-3851d2).
# Until 2026-10-01 a winner held the WHOLE post (exit 2 in publish-deals-page), so one wrong cell, or one good cell
# flagged as contested, held every cell and diverged post from feed (held 09-29 and twice on 09-30/10-01). Now
# `audit-match-soundness.ps1 -CellScope` runs inside guards.ps1 and names each winning cell through the QUARANTINE-CELL
# protocol (Get-SoundnessCellScope below), apply-cell-quarantine holds or withholds it, and the publish gate counts a
# change whose every cell is quarantined as REVIEW. The gate still HOLDS, fail-closed, when the report cannot be read
# or joined, or when a winner sits on a cell nothing quarantined (guards did not scope it, so nothing proves it safe).

if (-not (Get-Command Test-TcCellQuarantined -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'cell-quarantine-lib.ps1') }

function Get-CellNames {
  <#
    The product NAME on EVERY store cell of a comparison - not only the cheapest one - mapped to a
    readable description of the cell it holds and whether that cell is the crown.

    Was Get-CrownNames until 2026-09-08 (queue 2026-09-08-2e59b3), and the crown-only reader was SILENT
    on the founding case of that round: 'Fareway Steamables Green Beans', a frozen 12 oz microwave bag,
    held Fareway's fresh-green-beans cell at 1.92/lb while the CROWN sat at Walmart on 1.6201/lb. A
    wrong product does not have to be the cheapest in Omaha to be wrong on the board; it only has to
    hold a cell a reader will price a shop from.

    A PARAMETER rather than a file read, so the -SelfTest cases can be driven by a frozen board slice.

    A CROWN WINS A TIE: one product name can sit on several rows or stores. If any of them is the
    crown, the entry records the crown.
  #>
  # EVERY CELL A NAME HOLDS (2026-10-01, queue 2026-09-30-3851d2, ruling Q-2026-09-29-4-A): .cells lists each
  # {id, store, quarantined} the name wins, because a finding now QUARANTINES its cells rather than holding the board,
  # and one name can win several (two rows, or two stores). .text/.crown keep their old meaning for the report lines.
  # `quarantined` is Test-TcCellQuarantined's answer (cell-quarantine-lib.ps1), the one reader of that marker.
  param($Comparison)
  $out = @{}
  foreach ($r in @($Comparison)) {
    $cs = [string]$r.cheapest_store
    foreach ($s in @($r.stores)) {
      $itm = [string]$s.item
      if (-not $itm) { continue }
      $isCrown = ([bool]$cs -and ([string]$s.store -eq $cs))
      $txt = ([string]$r.id + ' @ ' + [string]$s.store + ' ' + [string]$s.per_unit + '/' + [string]$r.unit)
      $ref = [pscustomobject]@{ id = [string]$r.id; store = [string]$s.store; quarantined = [bool](Test-TcCellQuarantined $s) }
      if ($out.ContainsKey($itm)) {
        $e = $out[$itm]
        [void]$e.cells.Add($ref)
        if (-not $e.crown) { $e.text = $txt; $e.crown = [bool]$isCrown }
        continue
      }
      $lst = New-Object System.Collections.ArrayList
      [void]$lst.Add($ref)
      $out[$itm] = [pscustomobject]@{ text = $txt; crown = [bool]$isCrown; cells = $lst }
    }
  }
  return $out
}

function Select-CellByContest {
  # The intersection, as its own function so both the fixture and the live path drive the SHIPPED rule.
  param($NewContest, $CellNames)
  return @(@($NewContest) | Where-Object { $CellNames.ContainsKey([string]$_) })
}

function Get-SoundnessReportField {
  # A report field that may legitimately be ABSENT or null reads as an empty list; never @() a List here
  # (PS 5.1 throws on @($genericList) in some shapes - see audit-match-soundness.ps1, backlog I232).
  param($Report, [string]$Name)
  $out = New-Object System.Collections.Generic.List[object]
  if ($null -eq $Report) { return ,$out }
  $p = $null
  if ($Report -is [System.Collections.IDictionary]) { if ($Report.Contains($Name)) { $p = $Report[$Name] } }
  else { $pp = $Report.PSObject.Properties[$Name]; if ($pp) { $p = $pp.Value } }
  if ($null -eq $p) { return ,$out }
  if ($p -is [string]) { [void]$out.Add($p); return ,$out }
  foreach ($x in $p) { if ($null -ne $x) { [void]$out.Add($x) } }
  return ,$out
}

function Get-SoundnessPublishVerdict {
  <#
    PURE. $Report = the parsed soundness-report.json (or $null when it could not be read); $CellNames = the
    Get-CellNames map of the board being published (or $null when it could not be read); $ReadError = why a
    read failed, if one did. Returns Hold (bool), Reason (one line), Winners (lines for changes that touch a
    published cell's winner) and Review (lines for changes on no cell, which do not hold).
  #>
  # Cells (2026-10-01): one {id, store} per LIVE (unquarantined) cell a winner holds, de-duplicated, for
  # Get-SoundnessCellScope. A winner whose every cell is already quarantined is REVIEW, not a hold. A winner whose
  # entry carries no .cells list (a caller's own map) stays a hold with no cell named, so it fails closed as BOARD.
  # DE-DUP: cell_by_contest is the subset of new_contested_names that holds a cell, so a name in both is ONE change
  # (the 2026-10-01 08:18 HELD line said 4 changes for 2 products).
  param($Report, $CellNames, [string]$ReadError = '')
  $winners = New-Object System.Collections.Generic.List[string]
  $review = New-Object System.Collections.Generic.List[string]
  $cellsOut = New-Object System.Collections.ArrayList
  if ($null -eq $Report) {
    return [pscustomobject]@{ Hold = $true; Reason = ('the soundness report could not be read (' + $ReadError + '), so nothing proves the changes are off the board'); Winners = $winners; Review = $review; Cells = $cellsOut }
  }
  $changes = New-Object System.Collections.Generic.List[object]
  foreach ($m in (Get-SoundnessReportField $Report 'moved')) { [void]$changes.Add([pscustomobject]@{ name = [string]$m.name; line = ('MOVED ' + [string]$m.from + '->' + [string]$m.to + ': ' + [string]$m.name) }) }
  foreach ($d in (Get-SoundnessReportField $Report 'dropped')) { [void]$changes.Add([pscustomobject]@{ name = [string]$d.name; line = ('DROPPED ' + [string]$d.from + ': ' + [string]$d.name) }) }
  $ncNames = Get-SoundnessReportField $Report 'new_contested_names'
  if ($ncNames.Count -eq 0) { foreach ($n in (Get-SoundnessReportField $Report 'new_contested')) { if ($n -is [string]) { [void]$ncNames.Add($n) } else { [void]$ncNames.Add([string]$n.name) } } }
  $ncSeen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  foreach ($n in $ncNames) { [void]$ncSeen.Add([string]$n); [void]$changes.Add([pscustomobject]@{ name = [string]$n; line = ('NEW-CONTESTED: ' + [string]$n) }) }
  foreach ($cb in (Get-SoundnessReportField $Report 'cell_by_contest')) {
    if ([string]$cb.name -and $ncSeen.Contains([string]$cb.name)) { continue }
    [void]$changes.Add([pscustomobject]@{ name = [string]$cb.name; line = ('CELL-BY-CONTEST: ' + [string]$cb.name) })
  }
  foreach ($c in $changes) {
    if (-not $c.name) { return [pscustomobject]@{ Hold = $true; Reason = ('a soundness change carries no product name, so it cannot be joined to the board: ' + $c.line); Winners = $winners; Review = $review; Cells = $cellsOut } }
  }
  if ($changes.Count -eq 0) { return [pscustomobject]@{ Hold = $false; Reason = 'no moved, dropped or contested product against the reviewed baseline'; Winners = $winners; Review = $review; Cells = $cellsOut } }
  if ($null -eq $CellNames -or $CellNames.Count -eq 0) {
    return [pscustomobject]@{ Hold = $true; Reason = ('the board being published could not be read or names no cell (' + $ReadError + '), so ' + $changes.Count + ' change(s) cannot be proven off the board'); Winners = $winners; Review = $review; Cells = $cellsOut }
  }
  $cellSeen = @{}
  foreach ($c in $changes) {
    if ($CellNames.ContainsKey($c.name)) {
      $ent = $CellNames[$c.name]
      $hasCells = ($null -ne $ent.PSObject.Properties['cells'] -and $null -ne $ent.cells)
      $live = @(); $held = @()
      if ($hasCells) {
        $live = @(@($ent.cells) | Where-Object { $null -ne $_ -and -not $_.quarantined })
        $held = @(@($ent.cells) | Where-Object { $null -ne $_ -and $_.quarantined })
      }
      if ($hasCells -and $live.Count -eq 0 -and $held.Count -gt 0) {
        $hl = $c.line + '  [every cell it wins is QUARANTINED: ' + ((@($held | ForEach-Object { [string]$_.id + '|' + [string]$_.store })) -join ', ') + ']'
        if (-not $review.Contains($hl)) { [void]$review.Add($hl) }
        continue
      }
      [void]$winners.Add($c.line + '  [wins ' + [string]$ent.text + ']')
      foreach ($lc in $live) {
        $ck = [string]$lc.id + '|' + [string]$lc.store
        if ($cellSeen.ContainsKey($ck)) { continue }
        $cellSeen[$ck] = $true
        [void]$cellsOut.Add([pscustomobject]@{ id = [string]$lc.id; store = [string]$lc.store; name = [string]$c.name })
      }
    }
    elseif (-not $review.Contains($c.line)) { [void]$review.Add($c.line) }
  }
  if ($winners.Count -gt 0) { return [pscustomobject]@{ Hold = $true; Reason = ([string]$winners.Count + ' change(s) touch a published cell''s winning product'); Winners = $winners; Review = $review; Cells = $cellsOut } }
  return [pscustomobject]@{ Hold = $false; Reason = ([string]$review.Count + ' change(s), none on any live published cell'); Winners = $winners; Review = $review; Cells = $cellsOut }
}

function Get-SoundnessCellScope {
  <#
    PURE. Turns a Get-SoundnessPublishVerdict result into what `audit-match-soundness.ps1 -CellScope` prints for
    guards.ps1 (the QUARANTINE-CELL protocol, Get-TcChildQuarantineScope in cell-quarantine-lib.ps1). Returns
    Code and Lines:
      0  nothing to quarantine (no winner on a live cell);
      2  one 'QUARANTINE-CELL <id>|<store>|selection' per live winning cell, then 'QUARANTINE-SCOPE complete cells=N
         stores=0'. Always `selection`: the price is real, the product chosen for the cell is in doubt;
      1  a hold that names no cell (unreadable report, unjoinable board, a nameless change, a winner with no cell
         list). guards reads a non-2 exit as BOARD scoped, so this holds the board, fail-closed, as before.
  #>
  param($Verdict)
  $lines = New-Object System.Collections.Generic.List[string]
  if ($null -eq $Verdict) { [void]$lines.Add('match-soundness cell scope: BOARD hold - no verdict was computed'); return [pscustomobject]@{ Code = 1; Lines = $lines } }
  if (-not $Verdict.Hold) { [void]$lines.Add('match-soundness cell scope: nothing to quarantine (' + [string]$Verdict.Reason + ')'); return [pscustomobject]@{ Code = 0; Lines = $lines } }
  $cl = @(@($Verdict.Cells) | Where-Object { $null -ne $_ -and [string]$_.id -and [string]$_.store })
  if ($cl.Count -eq 0 -or $cl.Count -ne @(@($Verdict.Cells) | Where-Object { $null -ne $_ }).Count) {
    [void]$lines.Add('match-soundness cell scope: BOARD hold - ' + [string]$Verdict.Reason + ', and no complete cell list names where')
    return [pscustomobject]@{ Code = 1; Lines = $lines }
  }
  foreach ($w in $Verdict.Winners) { [void]$lines.Add('match-soundness QUARANTINE: ' + $w) }
  foreach ($c in $cl) { [void]$lines.Add('QUARANTINE-CELL ' + [string]$c.id + '|' + [string]$c.store + '|selection') }
  [void]$lines.Add('QUARANTINE-SCOPE complete cells=' + $cl.Count + ' stores=0')
  return [pscustomobject]@{ Code = 2; Lines = $lines }
}

function Read-SoundnessPublishVerdict {
  <#
    The IO half. Reads the report the audit run just wrote and the board being published, then asks the pure
    rule. A report older than $NotBefore was not written by this run (the audit threw before writing it), so it
    reads as unreadable and HOLDS.
  #>
  param([string]$ReportFile, [string]$CompareFile, [datetime]$NotBefore)
  $rep = $null; $cells = $null; $err = ''
  try {
    if (-not (Test-Path -LiteralPath $ReportFile)) { throw ('no report at ' + $ReportFile) }
    $wt = (Get-Item -LiteralPath $ReportFile).LastWriteTime
    if ($wt -lt $NotBefore.AddSeconds(-2)) { throw ('report last written ' + $wt.ToString('yyyy-MM-dd HH:mm:ss') + ', before this audit run started, so it is not this run''s') }
    $rep = ConvertFrom-Json ([IO.File]::ReadAllText($ReportFile, [Text.Encoding]::UTF8))
    if ($null -eq $rep) { throw 'report parsed to nothing' }
  } catch { $rep = $null; $err = $_.Exception.Message }
  if ($null -ne $rep) {
    try {
      if (-not $CompareFile -or -not (Test-Path -LiteralPath $CompareFile)) { throw ('no board at ' + $CompareFile) }
      $cells = Get-CellNames ((ConvertFrom-Json ([IO.File]::ReadAllText($CompareFile, [Text.Encoding]::UTF8))).comparison)
    } catch { $cells = $null; $err = $_.Exception.Message }
  }
  return (Get-SoundnessPublishVerdict -Report $rep -CellNames $cells -ReadError $err)
}
