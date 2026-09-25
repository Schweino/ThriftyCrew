<#
  commodity-rule-text-lib.ps1 - add an include or exclude pattern to grocery/commodities.json by editing its TEXT,
  so a batch writes the bytes a hand edit would and nothing else.

  WHY (2026-09-25, Q-laundry-rule-gaps, grocery/triage-plans/plan-2026-09-25-3.json). apply-coverage-batch.ps1 wrote
  the file with `($coms | ConvertTo-Json -Depth 12) | Set-Content -Encoding UTF8`, and under PS 5.1 that re-serialise
  did four things nobody asked for: every \u00XX escape in the rules became a raw character (jalape[n\u00f1] became
  jalape[n + the raw letter], so guards warned of mojibake inside the matching rules), a BOM was prepended, CRLF was
  written over an eol=lf blob, and every hand-written one-line band_override object was reflowed onto several lines.
  One added pattern produced an 85+/45- diff. Get-IdentityRulesHash (identity-lib.ps1) hashes these bytes, so the
  soundness -Accept run over the batch-written file recorded a rules_hash the hand-committed file never matched, and
  sessions re-applied the diff by hand and re-accepted.

  THE SHAPE IT EDITS (surveyed over all 593 commodities that day): each commodity opens `    {`, has one
  `        "id":  "<id>",` line, and closes `    },` (or `    }` for the last). Every include, exclude and relax_global is
  `        "<field>":  [`, one quoted string per line, then a line holding only `]` or `],`. An empty array is written
  with one blank line between the brackets, the way PS 5.1 wrote it. Anything else is REFUSED with a throw: a guess at
  an unfamiliar layout is how a rule file gets corrupted, and the caller still holds its backup.
  A commodity with NO relax_global (348 of 593 on 2026-09-25) gets one as its LAST property, the place Add-Member
  puts it, so the text parses to the same objects the batch edited in memory.

  A NEW ELEMENT IS ENCODED THE WAY THE FILE ALREADY IS: PS 5.1's serializer escapes < > & ' as \u003c \u003e \u0026
  \u0027, and every character above U+007E is escaped as lower-case \uXXXX, so the file stays pure ASCII and a rule
  that deliberately matches a mojibake pair (memory mojibake-tolerance-is-not-corruption) keeps its escapes.
#>

function ConvertTo-TcCommodityJsonString {
  <# One JSON string literal, quotes included, in the escape style commodities.json already uses. Pure. #>
  param([AllowEmptyString()][string]$Value)
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append('"')
  foreach ($ch in $Value.ToCharArray()) {
    $code = [int]$ch
    switch ($ch) {
      '"' { [void]$sb.Append('\"'); continue }
      '\' { [void]$sb.Append('\\'); continue }
      "`b" { [void]$sb.Append('\b'); continue }
      "`f" { [void]$sb.Append('\f'); continue }
      "`n" { [void]$sb.Append('\n'); continue }
      "`r" { [void]$sb.Append('\r'); continue }
      "`t" { [void]$sb.Append('\t'); continue }
      default {
        if ($code -lt 0x20 -or $code -gt 0x7e -or $ch -eq '<' -or $ch -eq '>' -or $ch -eq '&' -or $ch -eq "'") { [void]$sb.Append(('\u{0:x4}' -f $code)) }
        else { [void]$sb.Append($ch) }
      }
    }
  }
  [void]$sb.Append('"')
  return $sb.ToString()
}

function Add-TcCommodityRulePattern {
  <# Returns $Text with $Pattern appended to commodity $Id's $Field array, every other byte untouched. Returns $Text
     unchanged when the array already holds $Pattern. Throws on any layout it does not recognise. Pure. #>
  param(
    [Parameter(Mandatory = $true)][string]$Text,
    [Parameter(Mandatory = $true)][string]$Id,
    [Parameter(Mandatory = $true)][ValidateSet('include', 'exclude', 'relax_global')][string]$Field,
    [Parameter(Mandatory = $true)][string]$Pattern
  )
  $lines = [System.Collections.Generic.List[string]]::new([string[]]($Text -split "`n"))
  $idLine = '        "id":  ' + (ConvertTo-TcCommodityJsonString $Id) + ','
  $at = @(for ($i = 0; $i -lt $lines.Count; $i++) { if ([string]::Equals($lines[$i], $idLine, [StringComparison]::Ordinal)) { $i } })
  if ($at.Count -ne 1) { throw ("commodities.json: expected exactly one line '" + $idLine.Trim() + "', found " + $at.Count) }
  $end = -1
  for ($i = $at[0] + 1; $i -lt $lines.Count; $i++) { if ($lines[$i] -cmatch '^    \},?$') { $end = $i; break } }
  if ($end -lt 0) { throw ("commodities.json: commodity '" + $Id + "' has no closing '    }' line") }
  $keyLine = '        "' + $Field + '":  ['
  $open = @(for ($i = $at[0] + 1; $i -lt $end; $i++) { if ([string]::Equals($lines[$i], $keyLine, [StringComparison]::Ordinal)) { $i } })
  $anyKey = @(for ($i = $at[0] + 1; $i -lt $end; $i++) { if ($lines[$i].StartsWith('        "' + $Field + '":', [StringComparison]::Ordinal)) { $i } })
  if ($anyKey.Count -eq 0) {
    # ABSENT: the array becomes the object's LAST property, where Add-Member puts it, at the indent PS 5.1 gives a key of
    # this length (the close bracket under the column after '"<field>":  ', the elements four further in).
    if ($end - 1 -le $at[0]) { throw ("commodities.json: commodity '" + $Id + "' has no property after its id to follow") }
    $closeIndent = 8 + ('"' + $Field + '":  ').Length
    $lines[$end - 1] = $lines[$end - 1] + ','
    $lines.InsertRange($end, [string[]]@($keyLine, ((' ' * ($closeIndent + 4)) + (ConvertTo-TcCommodityJsonString $Pattern)), ((' ' * $closeIndent) + ']')))
    return ($lines -join "`n")
  }
  if ($open.Count -ne 1) { throw ("commodities.json: commodity '" + $Id + "' has " + $open.Count + " '" + $Field + "' array line(s) in the one-string-per-line layout, expected 1") }
  $close = -1
  for ($i = $open[0] + 1; $i -lt $end; $i++) { if ($lines[$i] -cmatch '^ *\],?$') { $close = $i; break } }
  if ($close -lt 0) { throw ("commodities.json: commodity '" + $Id + "' " + $Field + " array has no closing ']' line") }
  $body = @(for ($i = $open[0] + 1; $i -lt $close; $i++) { $lines[$i] })
  $enc = ConvertTo-TcCommodityJsonString $Pattern
  $empty = ($body.Count -eq 1 -and [string]::IsNullOrEmpty($body[0]))
  if ($empty) {
    $indent = ([regex]::Match($lines[$close], '^ *')).Length + 4
    $lines[$open[0] + 1] = (' ' * $indent) + $enc
    return ($lines -join "`n")
  }
  if ($body.Count -eq 0) { throw ("commodities.json: commodity '" + $Id + "' " + $Field + " array has no element and no blank line, a layout this writer does not know") }
  for ($k = 0; $k -lt $body.Count; $k++) {
    $want = if ($k -eq $body.Count - 1) { '^ +"(?:[^"\\]|\\.)*"$' } else { '^ +"(?:[^"\\]|\\.)*",$' }
    if ($body[$k] -notmatch $want) { throw ("commodities.json: commodity '" + $Id + "' " + $Field + " line " + ($open[0] + 2 + $k) + " is not one quoted string per line: " + $body[$k]) }
  }
  $existing = ConvertFrom-Json ('[' + ($body -join "`n") + ']')   # assigned, never @()-wrapped: PS 5.1 emits a parsed array as ONE object
  foreach ($e in $existing) { if ([string]::Equals([string]$e, $Pattern, [StringComparison]::Ordinal)) { return $Text } }
  $last = $close - 1
  $indent = ([regex]::Match($lines[$last], '^ *')).Length
  $lines[$last] = $lines[$last] + ','
  $lines.Insert($close, (' ' * $indent) + $enc)
  return ($lines -join "`n")
}

function Write-TcCommoditiesFile {
  <# Writes commodities.json text as the blob git stores: UTF-8, no BOM, LF, one trailing LF. $true when it wrote. #>
  param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Text)
  $t = ($Text -replace "`r`n", "`n").TrimEnd("`n")
  return (Write-TcLfFile -Path $Path -Text $t -NoBom)
}
