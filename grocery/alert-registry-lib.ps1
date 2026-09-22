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
# Brad's page contract (ruling 1), plus condition 5 by ruling R16 (2026-09-10): memory that can leave this machine.
# The registry file's page_conditions says the same thing for a human; Get-AlertRegistryEntryProblems fails if they differ.
$script:AlertPageConditions = @('1 board-or-feed-wrong-or-held', '2 watcher-cannot-see', '3 scheduled-work-did-not-run-or-land', '4 live-cell-moved-unexplained', '5 private-data-exposure', 'escalation')
$script:AlertClassRank = @{ page = 3; review = 2; digest = 1 }
$script:AlertUnregisteredMarker = 'UNREGISTERED ALERT TYPE: '
# THE RESOLVER CONTRACT (2026-09-22, design/RCA-holistic-2026-09-22.md F5). Every entry names what CLOSES its findings.
# 'unassigned:<date>' is the grandfathered state of the types registered before the contract, counted by the ratchet
# in the registry file (resolver_ratchet.unassigned_max) so the count may only fall.
$script:AlertResolverKinds = @('lane', 'ruling', 'digest', 'unassigned')

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

function Get-AlertResolverKind {
  <# Pure. An entry's resolver string -> lane | ruling | digest | unassigned | missing | invalid.
     lane:<repo path>, ruling:<question id>, the bare word digest, or unassigned:<yyyy-MM-dd>. #>
  param([string]$Resolver)
  if (-not $Resolver) { return 'missing' }
  if ($Resolver -ceq 'digest') { return 'digest' }
  if ($Resolver -cmatch '^lane:\S+$') { return 'lane' }
  if ($Resolver -cmatch '^ruling:\S+$') { return 'ruling' }
  if ($Resolver -cmatch '^unassigned:\d{4}-\d{2}-\d{2}$') { return 'unassigned' }
  return 'invalid'
}

function Get-AlertEntryResolver {
  <# Pure. The resolver string an entry declares, '' when the field is absent (a presence question, asked as one). #>
  param($Entry)
  if ($null -eq $Entry) { return '' }
  $p = $Entry.PSObject.Properties['resolver']
  if ($null -eq $p) { return '' }
  return [string]$p.Value
}

function Get-AlertResolverRatchet {
  <# Pure. How many live (not retired) entries are still 'unassigned', against the mark the registry records. #>
  param($Registry)
  $n = 0
  foreach ($e in @($Registry.entries)) {
    if (-not $e) { continue }
    if ($e.PSObject.Properties['retired'] -and [string]$e.retired) { continue }
    if ((Get-AlertResolverKind (Get-AlertEntryResolver $e)) -eq 'unassigned') { $n++ }
  }
  $mark = $null
  $rr = $Registry.PSObject.Properties['resolver_ratchet']
  if ($null -ne $rr -and $null -ne $rr.Value -and $rr.Value.PSObject.Properties['unassigned_max']) { $mark = [int]$rr.Value.unassigned_max }
  return [pscustomobject]@{ unassigned = $n; mark = $mark; over = ($null -ne $mark -and $n -gt $mark); can_tighten = ($null -ne $mark -and $n -lt $mark) }
}

function Get-AlertDelivery {
  <# Pure. What send-alert does with one alert: queue it, mail it, and under which subject.
     -Escalates is page and -Lane weekly is review by ruling 1, whatever the subject says.
     THE TYPE IS RESOLVED FIRST, FOR EVERY ALERT (2026-09-22, plan-2026-09-22-10 item 2026-09-20-cb8f30). Until then a
     weekly-lane alert returned before the registered check, so 34 of 54 agent mints over 2026-09-11..09-22 carried an
     unregistered type and nothing stamped one. Now an unregistered agent alert is stamped exactly as a pipeline one is;
     what the sender then DOES with it is Test-AgentSendRefused below (Brad's ruling Q-sender-refuses-unregistered). #>
  param($Resolution, [string]$Subject, [string]$Escalates = '', [string]$Lane = '')
  $d = [pscustomobject]@{ class = 'page'; queue = $true; mail = $true; mail_subject = $Subject; unregistered = $false; resolverless = $false; entry_id = ''; note = '' }
  $readable = ($null -ne $Resolution -and $Resolution.registry_ok)
  if ($Escalates -or $Lane -eq 'weekly') {
    if ($readable -and -not $Resolution.registered) { $d.unregistered = $true }
    if ($readable -and $Resolution.registered) { $d.entry_id = [string]$Resolution.entry.id }
    if ($Escalates) { $d.note = 'an escalation (-Escalates) is page by ruling 1'; return $d }
    $d.class = 'review'; $d.mail = $false; $d.note = 'a triage-created item (-Lane weekly) is review by ruling 1'; return $d
  }
  if (-not $readable) { $d.note = 'the alert registry could not be read, so this alert FAILS TOWARD PAGE'; return $d }
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
  # A REGISTERED TYPE THAT NAMES NO RESOLVER IS QUEUED AND NEVER EMAILED (the resolver contract, F5). Queue is forced
  # ON, so a digest-class entry without one is not lost either: the durable record comes first, the page does not.
  $rk = Get-AlertResolverKind (Get-AlertEntryResolver $Resolution.entry)
  if ($rk -eq 'missing' -or $rk -eq 'invalid') {
    $d.resolverless = $true; $d.queue = $true; $d.mail = $false
    $d.note = ('registry entry ' + $d.entry_id + ' names no resolver (lane:, ruling: or digest), so it is queued and NOT emailed until it does')
  }
  return $d
}

# ---- AN AGENT'S UNREGISTERED ALERT IS REFUSED (Brad's ruling Q-sender-refuses-unregistered, 2026-09-22) -------------
# Brad's words: "Refuse agents only". The option he chose: an agent's alert with an unregistered title is refused on
# the spot; the agent must register the type or use an existing one and re-send in the same turn; the closing check
# (validate-triage-plan -Closing) refuses any leftover, so nothing is lost; alerts from the daily pipeline always get
# through. An agent's send is one carrying -Lane weekly or -Escalates, the two flags only a triage agent passes. A
# registry that cannot be read refuses NOTHING: ruling 1 fails toward delivery, and an unknown type is not a known one.
function Test-AgentSendRefused {
  <# Pure. $true when this send is an agent's (-Lane weekly or -Escalates) and its type is registered nowhere. #>
  param($Delivery, [string]$Lane = '', [string]$Escalates = '')
  if ($null -eq $Delivery) { return $false }
  if (-not ($Lane -eq 'weekly' -or $Escalates)) { return $false }
  return [bool]$Delivery.unregistered
}

# ---- A FAILURE CLASS OUTLIVES A SPLIT OR A RENAME (2026-09-22, plan-2026-09-22-10, the class-keyed return rate) ------
# The return rate keyed a failure by the TEXT of its alert subject, so the 09-21 split (five catch-all types retired
# into 75 successors) made every successor's first fire a brand-new type instead of the old class coming back. The
# class of a type is its registry entry followed up lineage_parent to the root. An entry that split or replaced another
# names it in lineage_parent; audit-alert-registry refuses a split_from with no lineage_parent, a parent that is not
# there or not retired, and a retired entry nothing descends from and no no_successor reason explains.
function Get-AlertLineageRoot {
  <# Pure. The entry at the top of Entry's lineage_parent chain. A missing parent or a cycle stops at the last entry
     reached, never throws (audit-alert-registry names both). $ById is an optional id -> entry dictionary. #>
  param($Registry, $Entry, $ById = $null)
  if ($null -eq $Entry) { return $null }
  if ($null -eq $ById) {
    $ById = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
    foreach ($e in @($Registry.entries)) { if ($e -and [string]$e.id -and -not $ById.ContainsKey([string]$e.id)) { $ById[[string]$e.id] = $e } }
  }
  $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  $cur = $Entry
  while ($true) {
    if (-not $seen.Add([string]$cur.id)) { break }
    $lp = $cur.PSObject.Properties['lineage_parent']
    if ($null -eq $lp -or -not [string]$lp.Value) { break }
    if (-not $ById.ContainsKey([string]$lp.Value)) { break }
    $cur = $ById[[string]$lp.Value]
  }
  return $cur
}

function Get-AlertClassKey {
  <# Pure. A queue type key -> 'class:<root entry id>' through Resolve-AlertClass (the resolution send-alert uses) and
     the lineage chain, or 'unregistered:<type key>' when no entry matches or the registry cannot be read, so an
     unregistered type is counted apart and never merged into a class. $Cache is an optional hashtable reused across calls. #>
  param($Registry, [string]$TypeKey, $Cache = $null)
  if ($null -ne $Cache -and $Cache.ContainsKey('k|' + $TypeKey)) { return [string]$Cache['k|' + $TypeKey] }
  $ById = $null
  if ($null -ne $Cache) {
    if (-not $Cache.ContainsKey('__byid')) {
      $bi = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
      foreach ($e in @($Registry.entries)) { if ($e -and [string]$e.id -and -not $bi.ContainsKey([string]$e.id)) { $bi[[string]$e.id] = $e } }
      $Cache['__byid'] = $bi
    }
    $ById = $Cache['__byid']
  }
  $res = Resolve-AlertClass $Registry $TypeKey
  $out = 'unregistered:' + $TypeKey
  if ($res.registry_ok -and $res.registered) {
    $rootE = Get-AlertLineageRoot $Registry $res.entry $ById
    $out = 'class:' + [string]$rootE.id
  }
  if ($null -ne $Cache) { $Cache['k|' + $TypeKey] = $out }
  return $out
}

function Get-AlertLineageProblems {
  <# Pure. The lineage rule: split_from needs a lineage_parent that exists and is retired; any lineage_parent must
     exist; the chain must not cycle; a retired entry must be some entry's lineage_parent or say no_successor. #>
  param($Registry)
  $p = New-Object System.Collections.Generic.List[string]
  $byId = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
  foreach ($e in @($Registry.entries)) { if ($e -and [string]$e.id -and -not $byId.ContainsKey([string]$e.id)) { $byId[[string]$e.id] = $e } }
  $parents = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  foreach ($e in @($Registry.entries)) {
    if (-not $e) { continue }
    $id = [string]$e.id
    $lpP = $e.PSObject.Properties['lineage_parent']
    $lp = if ($null -ne $lpP) { [string]$lpP.Value } else { '' }
    if ($lp) { [void]$parents.Add($lp) }
    if ($e.PSObject.Properties['split_from'] -and [string]$e.split_from -and -not $lp) {
      [void]$p.Add('entry ' + $id + ': split_from ' + [string]$e.split_from + ' names no lineage_parent - name the retired entry it replaced, or its first fire counts as a new class')
      continue
    }
    if (-not $lp) { continue }
    if (-not $byId.ContainsKey($lp)) { [void]$p.Add('entry ' + $id + ": lineage_parent '" + $lp + "' is not an entry in the registry"); continue }
    $par = $byId[$lp]
    if ($e.PSObject.Properties['split_from'] -and [string]$e.split_from -and -not ($par.PSObject.Properties['retired'] -and [string]$par.retired)) {
      [void]$p.Add('entry ' + $id + ": split_from with lineage_parent '" + $lp + "', which is not retired - a split retires its parent")
    }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $cur = $e
    while ($cur) {
      if (-not $seen.Add([string]$cur.id)) { [void]$p.Add('entry ' + $id + ': lineage_parent chain cycles back to ' + [string]$cur.id); break }
      $cp = $cur.PSObject.Properties['lineage_parent']
      if ($null -eq $cp -or -not [string]$cp.Value -or -not $byId.ContainsKey([string]$cp.Value)) { break }
      $cur = $byId[[string]$cp.Value]
    }
  }
  foreach ($e in @($Registry.entries)) {
    if (-not $e) { continue }
    if (-not ($e.PSObject.Properties['retired'] -and [string]$e.retired)) { continue }
    if ($parents.Contains([string]$e.id)) { continue }
    if ($e.PSObject.Properties['no_successor'] -and [string]$e.no_successor) { continue }
    [void]$p.Add('entry ' + [string]$e.id + ': retired, but no entry names it as lineage_parent and it carries no no_successor reason')
  }
  return ,$p
}

function Get-AlertRegistryEntryProblems {
  <# Pure. Every entry that cannot be applied as written: unknown class or match mode, no key, a regex that does
     not compile, no condition or emitter, a page condition outside the five, a duplicate id. #>
  param($Registry)
  $p = New-Object System.Collections.Generic.List[string]
  # THE CONTRACT IS WRITTEN TWICE, SO THE COPIES MUST AGREE (2026-09-10). The file's page_conditions is what a
  # person reads and this lib's list is what gets enforced. Found the day ruling R16 added a condition to the
  # file and this check refused it: a condition added to one copy and not the other now fails by name here.
  if ($null -ne $Registry.page_conditions) {
    $fileConds = @($Registry.page_conditions | Where-Object { $_ } | ForEach-Object { [string]$_ })
    $onlyFile = @($fileConds | Where-Object { $script:AlertPageConditions -notcontains $_ })
    $onlyLib = @($script:AlertPageConditions | Where-Object { $fileConds -notcontains $_ })
    if ($onlyFile.Count -gt 0 -or $onlyLib.Count -gt 0) {
      [void]$p.Add('page_conditions: the registry file and alert-registry-lib.ps1 disagree (only in the file: ' + ($onlyFile -join ', ') + '; only in the lib: ' + ($onlyLib -join ', ') + ')')
    }
  }
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
    elseif ([string]$e.class -eq 'page' -and $script:AlertPageConditions -notcontains [string]$e.condition) { [void]$p.Add($tag + ": page condition '" + [string]$e.condition + "' is not one of the page conditions") }
    if (-not [string]$e.emitter) { [void]$p.Add($tag + ': no emitter') }
    # A HOLD A PRODUCER CAN NEVER REACH (2026-09-22, Brad's ruling "Email first miss", plan-2026-09-22-10). A type whose
    # producer observes it at most N times a day, held for more than N observations, never mails a one-day occurrence:
    # watchdog-browser-capture-missing-today carried hold 2 while only the 14:15 slot-close run grades a day MISSING.
    # Checked wherever the entry declares its producer's cadence (producer_max_observations_per_day).
    if ($e.PSObject.Properties['producer_max_observations_per_day'] -and $e.PSObject.Properties['hold_observations']) {
      $pmx = 0; $hob = 0
      try { $pmx = [int]$e.producer_max_observations_per_day; $hob = [int]$e.hold_observations } catch { $pmx = 0 }
      if ($pmx -ge 1 -and $hob -gt $pmx) { [void]$p.Add($tag + ': hold_observations ' + $hob + ' exceeds what its producer can observe in a day (producer_max_observations_per_day ' + $pmx + '), so a one-day occurrence never mails') }
    }
    $isRetired = ($e.PSObject.Properties['retired'] -and [string]$e.retired)
    if (-not $isRetired) {
      $rs = Get-AlertEntryResolver $e
      $rk = Get-AlertResolverKind $rs
      if ($rk -eq 'missing') { [void]$p.Add($tag + ': no resolver - name what closes it: lane:<script that reads the finding into a worklist>, ruling:<question id>, or digest') }
      elseif ($rk -eq 'invalid') { [void]$p.Add($tag + ": resolver '" + $rs + "' is not lane:<path>, ruling:<id>, digest or unassigned:<yyyy-MM-dd>") }
    }
  }
  foreach ($lpx in (Get-AlertLineageProblems $Registry)) { [void]$p.Add($lpx) }
  $rat = Get-AlertResolverRatchet $Registry
  if ($null -eq $rat.mark -and $rat.unassigned -gt 0) { [void]$p.Add('resolver_ratchet.unassigned_max is missing, so the grandfathered unassigned count has no mark') }
  elseif ($rat.over) { [void]$p.Add('resolver_ratchet: ' + $rat.unassigned + " live entries are 'unassigned', above the mark " + $rat.mark + ' - a new type must name its resolver, never join the grandfathered set') }
  return ,$p
}
