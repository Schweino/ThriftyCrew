<#
  annotate-writer-note.ps1 - append a resolution sentence to ONE writer_notes entry on ONE spec, in place.

  WHY. A writer note is the recipe's own record of what was wrong when it was built. When the thing it flags
  is later fixed, the note becomes a false statement sitting inside a live spec ("broccoli is UNPRICED here")
  that the batch auditor and the next writer both read as current. Deleting it loses the history that
  explains the recipe's shape; leaving it lies. Appending is the only honest edit, and it needs to be as
  narrowly proved as any other write to a spec.

  PROSE-SAFE, like rebid-ingredient.ps1 and recost-spec-cost-block.ps1: the spec is never re-serialized,
  because the prose carries \uXXXX escapes that a ConvertTo-Json round trip would rewrite. The note is
  located by a unique substring, the append happens in the raw text, and then it is proved that exactly one
  writer_notes entry changed, that it changed only by gaining the suffix, and that every other field in the
  document is byte-identical.

  Usage:
    .\annotate-writer-note.ps1 -Slug x -Match 'BLOCKER FLAG for the repair' -Append 'RESOLVED 2026-08-16: ...'
    .\annotate-writer-note.ps1 ... -Apply
    .\annotate-writer-note.ps1 -SelfTest
#>
param(
  [string]$Slug = '',
  [string]$Match = '',
  [string]$Append = '',
  [string]$SpecsDir = '',
  [switch]$Apply,
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$mp   = Split-Path -Parent $here
if (-not $SpecsDir) { $SpecsDir = Join-Path $mp 'db\recipes' }

function Say([string]$s) { Write-Output $s }
function Die([string]$s) { Write-Output ('annotate-writer-note: ' + $s); exit 1 }

# A note lives in the JSON as an escaped string. To find it in the RAW text we must escape the caller's
# plain-text needle the same way the file does, or a needle containing an apostrophe or a backslash path
# (both of which these notes are full of) will never match what is on disk.
# The six-character sequence a spec file carries in place of an apostrophe. Held in a variable because
# writing it inline next to single-quoted PowerShell strings is how this function got mangled once already.
$script:APOS = [string][char]0x5C + 'u0027'
function ConvertTo-JsonNeedle([string]$s) {
  $e = $s -replace '\\', '\\' -replace '"', '\"'
  # PowerShell's ConvertTo-Json escapes apostrophes as '; the spec files are written that way.
  return ($e -replace "'", $script:APOS)
}

if ($SelfTest) {
  $bad = 0
  function T([string]$n, [bool]$ok, [string]$got) {
    if ($ok) { Say ('  ok    ' + $n) } else { Say ('  X     ' + $n + '   got: ' + $got); $script:bad++ }
  }
  T 'a plain needle is unchanged'   ((ConvertTo-JsonNeedle 'BLOCKER FLAG') -eq 'BLOCKER FLAG')            (ConvertTo-JsonNeedle 'BLOCKER FLAG')
  $wantApos = 'item ' + $script:APOS + 'Broccoli' + $script:APOS
  T 'an apostrophe becomes the u0027 escape' ((ConvertTo-JsonNeedle "item 'Broccoli'") -eq $wantApos) (ConvertTo-JsonNeedle "item 'Broccoli'")
  T 'a backslash path is doubled'   ((ConvertTo-JsonNeedle 'db\ingredients.json') -eq 'db\\ingredients.json') (ConvertTo-JsonNeedle 'db\ingredients.json')
  T 'a quote is escaped'            ((ConvertTo-JsonNeedle 'say "hi"') -eq 'say \"hi\"')                   (ConvertTo-JsonNeedle 'say "hi"')
  if ($bad) { Say ("annotate-writer-note SELF-TEST FAIL ({0})" -f $bad); exit 1 }
  Say 'annotate-writer-note SELF-TEST PASS'; exit 0
}

if (-not $Slug)   { Die 'pass -Slug (or -SelfTest)' }
if (-not $Match)  { Die 'pass -Match <a substring unique to the note>' }
if (-not $Append) { Die 'pass -Append <the sentence to add>' }

$path = Join-Path $SpecsDir ($Slug + '.json')
if (-not (Test-Path $path)) { Die ('no spec at ' + $path) }
$raw = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) -replace '^\xEF\xBB\xBF', ''
$before = $raw | ConvertFrom-Json
$bNotes = @($before.writer_notes)
if ($bNotes.Count -lt 1) { Die ('spec ' + $Slug + ' has no writer_notes') }

$hits = @($bNotes | Where-Object { $_ -like ('*' + $Match + '*') })
if ($hits.Count -eq 0) { Die ("no writer_notes entry on " + $Slug + " contains '" + $Match + "'") }
if ($hits.Count -gt 1) { Die ([string]$hits.Count + " writer_notes entries on " + $Slug + " contain '" + $Match + "' - give a needle that picks exactly one") }
$targetIdx = [array]::IndexOf($bNotes, $hits[0])

# Locate the note's closing quote in the raw text and splice the suffix in just before it.
$needle = ConvertTo-JsonNeedle $Match
$at = $raw.IndexOf($needle)
if ($at -lt 0) { Die ("the note is in the parsed document but its escaped form was not found in the raw text - refusing to guess at the offset") }
if ($raw.IndexOf($needle, $at + 1) -ge 0) { Die 'the escaped needle appears more than once in the raw text - refusing' }
# walk forward to the end of this JSON string: the first unescaped double quote
$i = $at
while ($i -lt $raw.Length) {
  if ($raw[$i] -eq '"' -and $raw[$i - 1] -ne '\') { break }
  $i++
}
if ($i -ge $raw.Length) { Die 'could not find the end of the note string' }
$suffix = ConvertTo-JsonNeedle (' ' + $Append)
$newRaw = $raw.Substring(0, $i) + $suffix + $raw.Substring($i)

# ---- prove it --------------------------------------------------------------------------------------------
$after = $null
try { $after = $newRaw | ConvertFrom-Json } catch { Die ('the edit produced invalid JSON, nothing written: ' + $_.Exception.Message) }
$aNotes = @($after.writer_notes)
if ($aNotes.Count -ne $bNotes.Count) { Die ('writer_notes count moved ' + $bNotes.Count + ' -> ' + $aNotes.Count + '; refusing.') }
for ($k = 0; $k -lt $bNotes.Count; $k++) {
  if ($k -eq $targetIdx) {
    if ($aNotes[$k] -ne ($bNotes[$k] + ' ' + $Append)) { Die 'the target note did not change by exactly the appended sentence; refusing.' }
  } elseif ($aNotes[$k] -ne $bNotes[$k]) { Die ('writer_notes[' + $k + '] changed collaterally; refusing.') }
}
$bo = $before | Select-Object -Property * -ExcludeProperty writer_notes | ConvertTo-Json -Depth 30 -Compress
$ao = $after  | Select-Object -Property * -ExcludeProperty writer_notes | ConvertTo-Json -Depth 30 -Compress
if ($bo -ne $ao) { Die 'a field outside writer_notes changed; refusing.' }

Say ('annotate-writer-note: ' + $Slug + '  writer_notes[' + $targetIdx + ']  +' + $Append.Length + ' chars, 0 collateral changes')
if (-not $Apply) { Say '    DRY RUN - nothing written. Re-run with -Apply.'; exit 0 }
[IO.File]::WriteAllText($path, $newRaw, (New-Object System.Text.UTF8Encoding($false)))
Say ('    wrote ' + $path)
exit 0
