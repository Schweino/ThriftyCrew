<#
  hold-scope-lib.ps1 - EVERY DELEGATED GUARD AUDIT DECLARES THE UNIT IT HOLDS AT (queue 2026-09-21-d16398, gap F3 of
  design/RCA-holistic-2026-09-22.md: "no gate declares the unit it refuses at").

  guards.ps1 runs a table of delegated audits (the f='audit-*.ps1' rows of its delegation loop). A hard failure a child
  does not scope holds the WHOLE board. Brad's 2026-09-21 ruling makes a bad cell quarantine itself, and scope was then
  taught one audit at a time, so nothing said which audits were still board-scoped or why. Each delegated audit now
  carries, in its header:
      HOLD SCOPE: cell|store|board - <reason>
  and audit-guard-contract.ps1 checks it: a delegate with no declaration is a finding; one declaring cell or store
  must actually print the QUARANTINE-SCOPE complete line guards reads (cell-quarantine-lib Get-TcChildQuarantineScope);
  one declaring board must say why. The number of board-scoped delegates is a RATCHET that may only fall
  ($script:TcHoldBoardMark), so a new delegate cannot arrive board-scoped without the mark moving in review.
  Pure over text: the caller passes guards.ps1's text and a reader for each delegate's text, so a fixture needs no tree.
#>

# 9 of 13 delegates were board-scoped on 2026-09-22 (measured over guards.ps1's delegation table at this change). A
# ratchet mark, not a tuning constant: it may only fall, one taught audit at a time.
$script:TcHoldBoardMark = 9

function Get-TcGuardDelegates([string]$GuardsText) {
  $out = New-Object System.Collections.ArrayList
  foreach ($m in [regex]::Matches($GuardsText, "@\{\s*f='(audit-[a-z0-9-]+\.ps1)'")) {
    $f = $m.Groups[1].Value
    if (-not ($out -contains $f)) { [void]$out.Add($f) }
  }
  return ,($out.ToArray())
}

function Get-TcHoldScopeDecl([string]$Text) {
  $m = [regex]::Match([string]$Text, '(?m)^\s*#?\s*HOLD SCOPE:\s*(cell|store|board)\b\s*(?:-\s*(.*))?$')
  if (-not $m.Success) { return $null }
  return [pscustomobject]@{ scope = $m.Groups[1].Value; reason = ([string]$m.Groups[2].Value).Trim() }
}

function Test-TcHoldScopeContract {
  <# .OUTPUTS { findings = string[]; delegates; board; mark } #>
  param([string]$GuardsText, [scriptblock]$ReadDelegate, [int]$Mark = $script:TcHoldBoardMark)
  $findings = New-Object System.Collections.ArrayList
  $del = Get-TcGuardDelegates $GuardsText
  $board = 0
  if ($del.Count -eq 0) { [void]$findings.Add('guards.ps1 names no delegated audit at all - the table could not be read, so nothing was checked') }
  foreach ($f in $del) {
    $txt = & $ReadDelegate $f
    if ($null -eq $txt) { [void]$findings.Add($f + ': delegated by guards.ps1 but not found'); continue }
    $d = Get-TcHoldScopeDecl $txt
    if ($null -eq $d) { [void]$findings.Add($f + ': no HOLD SCOPE declaration - an audit that names no scope holds the whole board, and nobody said so'); continue }
    if ($d.scope -eq 'board') {
      $board++
      if (-not $d.reason) { [void]$findings.Add($f + ': HOLD SCOPE board with no reason - board scope must say why') }
    } elseif ([string]$txt -notmatch 'QUARANTINE-SCOPE complete') {
      [void]$findings.Add($f + ': declares HOLD SCOPE ' + $d.scope + ' but never prints the QUARANTINE-SCOPE complete line, so guards would hold the whole board anyway')
    }
  }
  if ($board -gt $Mark) { [void]$findings.Add('board-scoped delegates rose to ' + $board + ' against a mark of ' + $Mark + ' - a new delegate arrived holding the whole board') }
  return [pscustomobject]@{ findings = $findings.ToArray(); delegates = $del.Count; board = $board; mark = $Mark }
}
