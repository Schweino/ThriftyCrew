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
  param($Comparison)
  $out = @{}
  foreach ($r in @($Comparison)) {
    $cs = [string]$r.cheapest_store
    foreach ($s in @($r.stores)) {
      $itm = [string]$s.item
      if (-not $itm) { continue }
      $isCrown = ([bool]$cs -and ([string]$s.store -eq $cs))
      if ($out.ContainsKey($itm) -and $out[$itm].crown -and -not $isCrown) { continue }
      $out[$itm] = [pscustomobject]@{
        text  = ([string]$r.id + ' @ ' + [string]$s.store + ' ' + [string]$s.per_unit + '/' + [string]$r.unit)
        crown = [bool]$isCrown
      }
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
  param($Report, $CellNames, [string]$ReadError = '')
  $winners = New-Object System.Collections.Generic.List[string]
  $review = New-Object System.Collections.Generic.List[string]
  if ($null -eq $Report) {
    return [pscustomobject]@{ Hold = $true; Reason = ('the soundness report could not be read (' + $ReadError + '), so nothing proves the changes are off the board'); Winners = $winners; Review = $review }
  }
  $changes = New-Object System.Collections.Generic.List[object]
  foreach ($m in (Get-SoundnessReportField $Report 'moved')) { [void]$changes.Add([pscustomobject]@{ name = [string]$m.name; line = ('MOVED ' + [string]$m.from + '->' + [string]$m.to + ': ' + [string]$m.name) }) }
  foreach ($d in (Get-SoundnessReportField $Report 'dropped')) { [void]$changes.Add([pscustomobject]@{ name = [string]$d.name; line = ('DROPPED ' + [string]$d.from + ': ' + [string]$d.name) }) }
  $ncNames = Get-SoundnessReportField $Report 'new_contested_names'
  if ($ncNames.Count -eq 0) { foreach ($n in (Get-SoundnessReportField $Report 'new_contested')) { if ($n -is [string]) { [void]$ncNames.Add($n) } else { [void]$ncNames.Add([string]$n.name) } } }
  foreach ($n in $ncNames) { [void]$changes.Add([pscustomobject]@{ name = [string]$n; line = ('NEW-CONTESTED: ' + [string]$n) }) }
  foreach ($cb in (Get-SoundnessReportField $Report 'cell_by_contest')) { [void]$changes.Add([pscustomobject]@{ name = [string]$cb.name; line = ('CELL-BY-CONTEST: ' + [string]$cb.name) }) }
  foreach ($c in $changes) {
    if (-not $c.name) { return [pscustomobject]@{ Hold = $true; Reason = ('a soundness change carries no product name, so it cannot be joined to the board: ' + $c.line); Winners = $winners; Review = $review } }
  }
  if ($changes.Count -eq 0) { return [pscustomobject]@{ Hold = $false; Reason = 'no moved, dropped or contested product against the reviewed baseline'; Winners = $winners; Review = $review } }
  if ($null -eq $CellNames -or $CellNames.Count -eq 0) {
    return [pscustomobject]@{ Hold = $true; Reason = ('the board being published could not be read or names no cell (' + $ReadError + '), so ' + $changes.Count + ' change(s) cannot be proven off the board'); Winners = $winners; Review = $review }
  }
  foreach ($c in $changes) {
    if ($CellNames.ContainsKey($c.name)) { [void]$winners.Add($c.line + '  [wins ' + [string]$CellNames[$c.name].text + ']') }
    elseif (-not $review.Contains($c.line)) { [void]$review.Add($c.line) }
  }
  if ($winners.Count -gt 0) { return [pscustomobject]@{ Hold = $true; Reason = ([string]$winners.Count + ' change(s) touch a published cell''s winning product'); Winners = $winners; Review = $review } }
  return [pscustomobject]@{ Hold = $false; Reason = ([string]$review.Count + ' change(s), none on any published cell'); Winners = $winners; Review = $review }
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
