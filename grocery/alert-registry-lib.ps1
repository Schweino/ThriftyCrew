<#
  alert-registry-lib.ps1 - which CLASS an alert type is, and what that class does. Pure functions only.

  THE CONTRACT (Brad, ruling 1, 2026-09-10; design\PLAN-zero-alert-days-2026-09-10.md section 7). Every alert
  type is exactly one class, recorded in grocery\alert-registry.json:
    page    emailed AND queued. Four conditions only, plus escalations to Brad.
    review  queued for triage, NEVER emailed. Triage-created residuals and findings (-Lane weekly) are review.
    digest  emailed, NEVER queued.
  An UNREGISTERED type is never dropped: it queues with unregistered=true and pages with its subject prefixed
  'UNREGISTERED ALERT TYPE: '. A registry that is missing or unparseable pages EVERY alert. Fail toward paging,
  never toward silence.

  WHY A LIBRARY. send-alert.ps1 applies the class and grocery\audit-alert-registry.ps1 proves the registry
  complete; if each carried its own matcher, the check could read green over a rule the mailer no longer
  follows. One matcher, two callers. The type-key derivation is the one exception: send-alert keeps its own
  copy so an alert still gets a key when this file cannot load, and its -SelfTest asserts the two agree.

  Dot-source:  . (Join-Path $root 'alert-registry-lib.ps1')
#>

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\json-io.ps1')   # Read-JsonFile: a BOM-less read is cp1252 otherwise

$script:AlertClasses = @('page', 'review', 'digest')
$script:AlertMatchModes = @('exact', 'prefix', 'regex')
$script:AlertPageConditions = @('1 board-or-feed-wrong-or-held', '2 watcher-cannot-see', '3 scheduled-work-did-not-run-or-land', '4 live-cell-moved-unexplained', 'escalation')
$script:AlertClassRank = @{ page = 3; review = 2; digest = 1 }
$script:AlertUnregisteredMarker = 'UNREGISTERED ALERT TYPE: '

function Get-AlertTypeKey {
  <# The subject with dates, rc=N and every number removed, lower case, non-letters collapsed. Identical to
     send-alert.ps1's ConvertTo-AlertTypeKey; send-alert's -SelfTest asserts that. #>
  param([string]$Subject)
  return (([string]$Subject).ToLower() `
      -replace '\d{4}-\d{2}-\d{2}', '' `
      -replace 'rc\s*=\s*\d+', '' `
      -replace '\d+(\.\d+)?', '' `
      -replace '[^a-z]+', ' ').Trim()
}

function Test-AlertRegistryShape {
  param($Doc)
  if ($null -eq $Doc) { return $false }
  if (-not $Doc.PSObject.Properties['entries']) { return $false }
  $e = @($Doc.entries | Where-Object { $_ })
  return ($e.Count -gt 0)
}

function Read-AlertRegistry {
  <# Returns ok/why/registry. Never throws: a registry that cannot be read is an answer (page everything). #>
  param([string]$Path)
  $st = [pscustomobject]@{ ok = $false; why = ''; registry = $null; path = $Path }
  if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { $st.why = ('the alert registry is missing (' + $Path + ')'); return $st }
  $doc = $null
  try { $doc = Read-JsonFile $Path } catch { $st.why = ('the alert registry could not be parsed: ' + $_.Exception.Message); return $st }
  if (-not (Test-AlertRegistryShape $doc)) { $st.why = 'the alert registry has no entries'; return $st }
  $st.ok = $true
  $st.registry = $doc
  return $st
}

function Test-AlertEntryMatch {
  param($Entry, [string]$TypeKey)
  $k = [string]$Entry.key
  if (-not $k) { return $false }
  $mode = [string]$Entry.match
  if ($mode -eq 'exact') { return [string]::Equals($TypeKey, $k, [StringComparison]::Ordinal) }
  if ($mode -eq 'prefix') {
    if (-not $TypeKey.StartsWith($k, [StringComparison]::Ordinal)) { return $false }
    return ($TypeKey.Length -eq $k.Length -or $TypeKey[$k.Length] -eq ' ')   # a word boundary, so 'site down' is not 'site downs'
  }
  if ($mode -eq 'regex') { try { return [regex]::IsMatch($TypeKey, $k) } catch { return $false } }
  return $false
}

function Resolve-AlertClass {
  <# Pure. Registry document + type key -> class, the winning entry, and whether the answer is trustworthy.
     Exact beats prefix and regex. A tie that remains is AMBIGUOUS and takes the most severe class. #>
  param($Registry, [string]$TypeKey)
  $r = [pscustomobject]@{ class = 'page'; registered = $false; registry_ok = $false; ambiguous = $false; entry = $null; candidates = 0; why = '' }
  if (-not (Test-AlertRegistryShape $Registry)) { $r.why = 'registry-unreadable'; return $r }
  $r.registry_ok = $true
  $hits = New-Object System.Collections.Generic.List[object]
  foreach ($e in @($Registry.entries)) { if ($e -and (Test-AlertEntryMatch $e $TypeKey)) { [void]$hits.Add($e) } }
  if ($hits.Count -eq 0) { $r.why = 'unregistered'; return $r }
  $exact = New-Object System.Collections.Generic.List[object]
  foreach ($h in $hits) { if ([string]$h.match -eq 'exact') { [void]$exact.Add($h) } }
  $cands = $hits
  if ($exact.Count) { $cands = $exact }
  $r.registered = $true
  $r.candidates = $cands.Count
  $r.entry = $cands[0]
  if ($cands.Count -gt 1) {
    $best = 'digest'
    foreach ($c in $cands) {
      $cc = [string]$c.class
      if ($script:AlertClasses -notcontains $cc) { $cc = 'page' }
      if ($script:AlertClassRank[$cc] -gt $script:AlertClassRank[$best]) { $best = $cc }
    }
    $r.ambiguous = $true; $r.class = $best; $r.why = 'ambiguous'
    return $r
  }
  $c1 = [string]$cands[0].class
  if ($script:AlertClasses -notcontains $c1) { $r.class = 'page'; $r.why = 'invalid-class'; return $r }
  $r.class = $c1
  return $r
}

function Get-AlertDelivery {
  <# Pure. What send-alert does with one alert: queue it, mail it, and under which subject.
     -Escalates is page and -Lane weekly is review by ruling 1, whatever the subject says. #>
  param($Resolution, [string]$Subject, [string]$Escalates = '', [string]$Lane = '')
  $d = [pscustomobject]@{ class = 'page'; queue = $true; mail = $true; mail_subject = $Subject; unregistered = $false; entry_id = ''; note = '' }
  if ($Escalates) { $d.note = 'an escalation (-Escalates) is page by ruling 1'; return $d }
  if ($Lane -eq 'weekly') { $d.class = 'review'; $d.mail = $false; $d.note = 'a triage-created item (-Lane weekly) is review by ruling 1'; return $d }
  if ($null -eq $Resolution -or -not $Resolution.registry_ok) { $d.note = 'the alert registry could not be read, so this alert FAILS TOWARD PAGE'; return $d }
  if (-not $Resolution.registered) {
    $d.unregistered = $true
    $d.mail_subject = $script:AlertUnregisteredMarker + $Subject
    $d.note = 'no registry entry matches this type, so it queues and pages as a registry defect'
    return $d
  }
  $d.entry_id = [string]$Resolution.entry.id
  $d.class = [string]$Resolution.class
  if ($d.class -eq 'review') { $d.mail = $false }
  if ($d.class -eq 'digest') { $d.queue = $false }
  if ($Resolution.ambiguous) { $d.note = 'more than one registry entry matches; the most severe class wins' }
  return $d
}

function Get-AlertRegistryEntryProblems {
  <# Pure. Every entry that cannot be applied as written: unknown class or match mode, no key, a regex that does
     not compile, no condition or emitter, a page condition outside the five, a duplicate id. #>
  param($Registry)
  $p = New-Object System.Collections.Generic.List[string]
  $seen = @{}
  $i = 0
  foreach ($e in @($Registry.entries)) {
    $i++
    if (-not $e) { continue }
    $id = [string]$e.id
    $tag = ('entry ' + $i + ' (' + $id + ')')
    if (-not $id) { [void]$p.Add($tag + ': no id') } elseif ($seen.ContainsKey($id)) { [void]$p.Add($tag + ': duplicate id') } else { $seen[$id] = $true }
    if ($script:AlertClasses -notcontains [string]$e.class) { [void]$p.Add($tag + ": class '" + [string]$e.class + "' is not page, review or digest") }
    if ($script:AlertMatchModes -notcontains [string]$e.match) { [void]$p.Add($tag + ": match '" + [string]$e.match + "' is not exact, prefix or regex") }
    if (-not [string]$e.key) { [void]$p.Add($tag + ': no key') }
    elseif ([string]$e.match -eq 'regex') { try { $null = [regex]::new([string]$e.key) } catch { [void]$p.Add($tag + ': the regex does not compile') } }
    if (-not [string]$e.condition) { [void]$p.Add($tag + ': no condition') }
    elseif ([string]$e.class -eq 'page' -and $script:AlertPageConditions -notcontains [string]$e.condition) { [void]$p.Add($tag + ": page condition '" + [string]$e.condition + "' is not one of the five") }
    if (-not [string]$e.emitter) { [void]$p.Add($tag + ': no emitter') }
  }
  return ,$p
}
