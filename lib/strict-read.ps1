# strict-read.ps1 - read a field that may legitimately be ABSENT, in a way Set-StrictMode accepts.
#
# WHY THIS EXISTS (backlog I179, Brad's ruling 2026-09-19: pilot `Set-StrictMode -Version Latest` in a handful of
# daily-chain entry scripts). Under strict mode `$row.as_of` THROWS when the row has no as_of property, where
# without it the read is a silent $null. Most JSON this estate reads has OPTIONAL fields (an ad row carries no
# as_of by design, a regular row carries no ad_to), and the code relies on "absent reads as empty" on purpose.
# That reliance is exactly what strict mode cannot tell apart from a misspelt name, so the pilot scripts say
# which reads are optional by routing them through this one function, and every OTHER read stays strict: a typo
# in a field that must exist now throws instead of reading as empty.
#
# SAME ANSWER AS THE BARE READ, for every input the bare read accepts without strict mode:
#   a PSCustomObject (ConvertFrom-Json, [pscustomobject]@{}) -> the property's value, or $null when absent
#   a hashtable / IDictionary                               -> $Obj[$Name], or $null when absent (a bare
#                                                              `$h.key` read on a hashtable never throws under
#                                                              strict mode either; this keeps both shapes one call)
#   $null                                                    -> $null (a bare `$null.x` is $null unstrict)
# It never unrolls a collection value and never coerces. So ASSIGN, THEN WRAP: `$d = Get-TcField $j 'deals';
# @($d)` is exactly `@($j.deals)`, while an inline `@(Get-TcField $j 'deals')` is one element holding the whole
# array - the estate's standing rule against wrapping a function call inline (ops-and-gates.md).
#
# A LIBRARY: no param() block (dot-sourcing one would reset the caller's own switches) and no Set-StrictMode
# (the mode follows the caller - lib\chain-verdict-lib.ps1 records why).

function Get-TcField {
  param($Obj, [string]$Name)
  if ($null -eq $Obj) { return $null }
  if ($Obj -is [System.Collections.IDictionary]) {
    if ($Obj.Contains($Name)) { return ,$Obj[$Name] }
    return $null
  }
  $p = $Obj.PSObject.Properties[$Name]
  if ($null -eq $p) { return $null }
  return ,$p.Value
}
