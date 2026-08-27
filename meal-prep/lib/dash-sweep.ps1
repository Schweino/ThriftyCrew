# dash-sweep.ps1 - THE em/en dash sweep over a built spec (Brad's rule).
#
# EXTRACTED 2026-08-27 from build-v2-spec.ps1 so a fixture can reach it. The sweep shipped
# reading its own ban list - see the comment below - and build-v2-spec had no self-test at all,
# because its body reads the intake file at line 101 and there was nowhere a fixture could run.
# The file's own header already notes that spec-guards enforces the same rule, so one copy of it
# in a lib both can dot-source is where this belonged anyway.

# THE ONE FIELD THE DASH SWEEP MUST NOT READ, and the reason is not an exception to Brad's rule but
# an application of it (2026-08-27). `forbidden_prose_terms` is the intake's list of characters and
# words the writer is FORBIDDEN to use, and an em dash is the first entry on it in every recipe that
# carries one. build-v2-spec copies that list into the spec as authoring metadata, and the sweep then
# read it as spec text and refused the recipe for containing the very character it is banning.
# Measured: three recipes of hunt-2026-08-27-ten - jamie-oliver-s-chicken-in-milk-seriously-delish,
# spaghetti-squash-boats-with-chicken and baked-stuffed-pork-chops - all refused with "EM DASH in
# spec text" while not one of them had an em dash anywhere a reader could see.
#
# The rule is about PROSE A READER GETS. This list is never rendered; it is instruction to the
# writer. Skipping it takes nothing away from the guard, and the clean twin is that every other
# string in the spec - including every prose field - is still swept exactly as before.
$script:DASH_SWEEP_SKIP = @('forbidden_prose_terms')

function Test-Dashes($spec){
  # em/en dash sweep over EVERY string (Brad's rule; spec-guards enforces the same), except the
  # authoring metadata that EXISTS to name the banned characters - see DASH_SWEEP_SKIP above.
  $q=New-Object System.Collections.Generic.Queue[object]
  $q.Enqueue($spec)
  while($q.Count -gt 0){
    $v=$q.Dequeue()
    if($null -eq $v){ continue }
    if($v -is [string]){
      if($v -match [char]0x2014){ throw ('EM DASH in spec text: ' + $v.Substring(0,[Math]::Min(70,$v.Length))) }
      if($v -match [char]0x2013){ throw ('EN DASH in spec text: ' + $v.Substring(0,[Math]::Min(70,$v.Length))) }
      continue
    }
    if($v -is [System.Collections.IDictionary]){
      foreach($k in @($v.Keys)){ if($script:DASH_SWEEP_SKIP -notcontains [string]$k){ $q.Enqueue($v[$k]) } }
      continue
    }
    if($v -is [System.Collections.IEnumerable]){ foreach($vv in $v){ $q.Enqueue($vv) }; continue }
    if($v -is [psobject] -and $v.PSObject.Properties.Count -gt 0){
      foreach($p in $v.PSObject.Properties){ if($script:DASH_SWEEP_SKIP -notcontains [string]$p.Name){ $q.Enqueue($p.Value) } }
    }
  }
}
