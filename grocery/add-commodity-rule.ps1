<#
  add-commodity-rule.ps1 - add include/exclude patterns to a commodity in commodities.json, SURGICALLY.

  WHY TEXT SURGERY AND NOT ConvertFrom-Json | ConvertTo-Json. commodities.json is 2.2 MB across 505 entries.
  Round-tripping it through PowerShell 5.1's ConvertTo-Json reformats every line, escapes every non-ASCII
  character, and silently truncates past -Depth. The diff would be 54,000 lines wide, which means nobody can
  review it and a mangled regex three commodities away would never be spotted. So this edits the bytes of one
  entry and PROVES it touched nothing else.

  THE PROOF (this is the part that matters): after writing, it re-parses the file and compares EVERY entry's
  serialized form against the original. Any entry other than the target that differs by a single character is
  a hard failure and the file is rolled back. A rule editor that can quietly corrupt a neighbour is worse than
  editing by hand, because it looks careful.

  Usage:
    add-commodity-rule.ps1 -Id pears -Exclude 'irregular\s+pears?'
    add-commodity-rule.ps1 -Id canned-pears -Include 'irregular\s+pears?' -Why "Fareway's canned pear pack"
    add-commodity-rule.ps1 -Id pears -Exclude 'a','b' -DryRun

  Patterns are stored verbatim. They are validated as legal .NET regex BEFORE anything is written, because an
  invalid pattern in this file throws at board-build time, i.e. at 3am in the nightly, not here.

  Exit 0 = written (or DryRun clean). Exit 1 = refused, nothing written.
#>
param(
  [Parameter(Mandatory = $true)][string]$Id,
  [string[]]$Include = @(),
  [string[]]$Exclude = @(),
  [string[]]$RemoveExclude = @(),
  [string[]]$RemoveInclude = @(),
  [string]$Why = '',
  [string]$File = '',
  [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $File) { $File = Join-Path $root 'commodities.json' }
function Say([string]$s) { Write-Output $s }
function Die([string]$s) { Write-Output ('add-commodity-rule: ' + $s); exit 1 }

if (-not (Test-Path $File)) { Die ('file not found: ' + $File) }
if ($Include.Count -eq 0 -and $Exclude.Count -eq 0 -and $RemoveExclude.Count -eq 0 -and $RemoveInclude.Count -eq 0) {
  Die 'nothing to do: pass -Include / -Exclude / -RemoveExclude / -RemoveInclude.'
}

# validate every pattern as a real regex before touching the file
foreach ($p in ($Include + $Exclude)) {
  try { [void][regex]::new($p) } catch { Die ('not a valid regex, refusing: ' + $p + '  (' + $_.Exception.Message + ')') }
}

$raw = [IO.File]::ReadAllText($File)
$before = $raw | ConvertFrom-Json
# TWO FILE SHAPES, ONE TOOL (2026-08-27) - the same gap new-commodity.ps1 carried, in its sibling.
# commodities.json is a bare top-level array; recipe-commodities.json nests its entries under a
# `commodities` key. Without this, every id in the RECIPE namespace answered "no commodity with id" -
# and the recipe namespace is exactly where the registrar sends form-splits, so a ruling could be
# approved and then be unexecutable by the two tools that exist to execute it.
$Entries = { param($doc) if ($null -ne $doc -and $doc.PSObject.Properties.Name -contains 'commodities') { return @($doc.commodities) } return @($doc) }
$bList = New-Object System.Collections.ArrayList; foreach ($x in (& $Entries $before)) { [void]$bList.Add($x) }
$target = $bList | Where-Object { [string]$_.id -eq $Id }
if ($null -eq $target) { Die ('no commodity with id ''' + $Id + '''. It must exist already; this script does not create commodities.') }

# ---- locate the entry's text block ----------------------------------------------------------------------
# Anchor on the id line, then walk braces outward to the object that contains it. Brace-walking (rather than a
# regex for the whole object) is what makes this safe against nested arrays and escaped braces in patterns.
$idPat = '"id":\s*"' + [regex]::Escape($Id) + '"'
$m = [regex]::Match($raw, $idPat)
if (-not $m.Success) { Die ('could not find the id line for ' + $Id + ' in the raw text.') }
if ([regex]::Matches($raw, $idPat).Count -ne 1) { Die ('the id ' + $Id + ' appears more than once in the raw text; refusing to guess which one.') }
$start = $raw.LastIndexOf('{', $m.Index)
if ($start -lt 0) { Die 'could not find the opening brace of the entry.' }
$depth = 0; $end = -1
for ($i = $start; $i -lt $raw.Length; $i++) {
  $ch = $raw[$i]
  if ($ch -eq '"') { # skip strings, honouring backslash escapes
    $i++
    while ($i -lt $raw.Length -and $raw[$i] -ne '"') { if ($raw[$i] -eq '\') { $i++ }; $i++ }
    continue
  }
  if ($ch -eq '{') { $depth++ }
  elseif ($ch -eq '}') { $depth--; if ($depth -eq 0) { $end = $i; break } }
}
if ($end -lt 0) { Die 'could not find the closing brace of the entry.' }
$block = $raw.Substring($start, $end - $start + 1)

# ---- insert into an array inside that block --------------------------------------------------------------
function Add-ToArray([string]$blk, [string]$key, [string[]]$vals) {
  if ($vals.Count -eq 0) { return $blk }
  $km = [regex]::Match($blk, '"' + $key + '":\s*\[')
  if (-not $km.Success) { throw ('entry has no "' + $key + '" array; this script does not create the array.') }
  # find the matching ] for this [
  $open = $blk.IndexOf('[', $km.Index)
  $d = 0; $close = -1
  for ($i = $open; $i -lt $blk.Length; $i++) {
    $ch = $blk[$i]
    if ($ch -eq '"') { $i++; while ($i -lt $blk.Length -and $blk[$i] -ne '"') { if ($blk[$i] -eq '\') { $i++ }; $i++ }; continue }
    if ($ch -eq '[') { $d++ } elseif ($ch -eq ']') { $d-- ; if ($d -eq 0) { $close = $i; break } }
  }
  if ($close -lt 0) { throw ('could not find the end of the "' + $key + '" array.') }
  $inner = $blk.Substring($open + 1, $close - $open - 1)
  $isEmpty = ($inner.Trim().Length -eq 0)
  # match the file's existing indentation for array elements
  $indent = '                    '
  $im = [regex]::Match($inner, '(?m)^([ \t]+)"')
  if ($im.Success) { $indent = $im.Groups[1].Value }
  $enc = @()
  foreach ($v in $vals) { $enc += ($indent + (ConvertTo-Json $v -Compress)) }
  $add = ($enc -join (",`r`n"))
  if ($isEmpty) { $newInner = "`r`n" + $add + "`r`n" + ($indent.Substring(0, [Math]::Max(0, $indent.Length - 4))) }
  else { $newInner = $inner.TrimEnd() + ",`r`n" + $add + "`r`n" + ($indent.Substring(0, [Math]::Max(0, $indent.Length - 4))) }
  return $blk.Substring(0, $open + 1) + $newInner + $blk.Substring($close)
}

function Remove-FromArray([string]$blk, [string]$key, [string[]]$vals) {
  # Removal exists so a bad pattern can be REPLACED, not layered over. Matching is on the exact stored string:
  # a fuzzy match here would delete a neighbouring rule that merely looks similar, and exclude lists are the
  # armour that keeps cat food out of the salmon cell.
  if ($vals.Count -eq 0) { return $blk }
  foreach ($v in $vals) {
    $enc = [regex]::Escape((ConvertTo-Json $v -Compress))
    # element plus its trailing comma+newline, or (if it is last) its LEADING comma+newline
    $pat1 = '(?m)^[ \t]*' + $enc + ',\r?\n'
    $pat2 = ',\r?\n[ \t]*' + $enc + '(?=\r?\n)'
    if ($blk -match $pat1) { $blk = [regex]::Replace($blk, $pat1, '', 1) }
    elseif ($blk -match $pat2) { $blk = [regex]::Replace($blk, $pat2, '', 1) }
    else { throw ('cannot remove from "' + $key + '": pattern not present verbatim -> ' + $v) }
  }
  return $blk
}

$newBlock = $block
try {
  $newBlock = Remove-FromArray $newBlock 'include' $RemoveInclude
  $newBlock = Remove-FromArray $newBlock 'exclude' $RemoveExclude
  $newBlock = Add-ToArray $newBlock 'include' $Include
  $newBlock = Add-ToArray $newBlock 'exclude' $Exclude
} catch { Die $_.Exception.Message }

$newRaw = $raw.Substring(0, $start) + $newBlock + $raw.Substring($end + 1)

# ---- prove it ---------------------------------------------------------------------------------------------
$after = $null
try { $after = $newRaw | ConvertFrom-Json } catch { Die ('the edit produced invalid JSON, nothing written: ' + $_.Exception.Message) }
$aList = New-Object System.Collections.ArrayList; foreach ($x in (& $Entries $after)) { [void]$aList.Add($x) }
if ($aList.Count -ne $bList.Count) { Die ('entry count changed ' + $bList.Count + ' -> ' + $aList.Count + '; refusing.') }

$collateral = New-Object System.Collections.ArrayList
for ($i = 0; $i -lt $bList.Count; $i++) {
  $bi = $bList[$i]; $ai = $aList[$i]
  if ([string]$bi.id -ne [string]$ai.id) { Die ('entry order changed at index ' + $i + '; refusing.') }
  if ([string]$bi.id -eq $Id) { continue }
  $bs = ($bi | ConvertTo-Json -Depth 8 -Compress)
  $as = ($ai | ConvertTo-Json -Depth 8 -Compress)
  if ($bs -ne $as) { [void]$collateral.Add([string]$bi.id) }
}
if ($collateral.Count -gt 0) {
  Die ('COLLATERAL DAMAGE: ' + $collateral.Count + ' other commodit(ies) changed (' + (($collateral | Select-Object -First 5) -join ', ') + '). Nothing written.')
}

$tNew = $aList | Where-Object { [string]$_.id -eq $Id }
$gotInc = @($tNew.include).Count - @($target.include).Count
$gotExc = @($tNew.exclude).Count - @($target.exclude).Count
$wantInc = $Include.Count - $RemoveInclude.Count
$wantExc = $Exclude.Count - $RemoveExclude.Count
if ($gotInc -ne $wantInc) { Die ('include changed by ' + $gotInc + ', expected ' + $wantInc + '; refusing.') }
if ($gotExc -ne $wantExc) { Die ('exclude changed by ' + $gotExc + ', expected ' + $wantExc + '; refusing.') }

Say ('add-commodity-rule: ' + $Id + '  include ' + ('{0:+#;-#;+0}' -f $wantInc) + '  exclude ' + ('{0:+#;-#;+0}' -f $wantExc) + '   (' + $bList.Count + '-entry file verified: 0 collateral changes)')
foreach ($p in $RemoveInclude) { Say ('    -include  ' + $p) }
foreach ($p in $RemoveExclude) { Say ('    -exclude  ' + $p) }
foreach ($p in $Include) { Say ('    +include  ' + $p) }
foreach ($p in $Exclude) { Say ('    +exclude  ' + $p) }
if ($Why) { Say ('    why: ' + $Why) }
if ($DryRun) { Say '    DRY RUN - nothing written.'; exit 0 }
[IO.File]::WriteAllText($File, $newRaw, (New-Object System.Text.UTF8Encoding($false)))
Say ('    wrote ' + $File)
exit 0
