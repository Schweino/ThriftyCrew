<#
  audit-ghost-drift.ps1 - does the LIVE Ghost page still match the local source it was published from?

  WHY THIS EXISTS (2026-08-08). Sixteen tools are published as a single lexical html card whose body is a
  local file (publish-tool-post.ps1 -Slug <slug> -File <name>-tool.html). Nothing ever checked afterwards
  that the live card still equals that file. Two of the sixteen had already drifted: my-crew and
  cheapest-protein carry absolute https://www.thriftycrew.com/... links in their "All the tools" nav where
  the local sources carry relative /... links (19 links x 27 chars = 513 bytes, and 1 x 27 = 27 bytes -
  the deltas reconcile exactly, so nothing else differs).

  Neither is broken for a reader, and that is the point: this class is SILENT. The damage is directional and
  arrives later - the next person to republish my-crew from local, for any unrelated reason, silently reverts
  19 live links, and nothing would have said so. Once local and live disagree, "which copy is right?" becomes
  archaeology, and the estate has already paid for that lesson with the recipe cards.

  WHAT IT COMPARES. The bytes of the html card, because bytes are what the publisher writes. Not rendered
  text, not a normalized form - a normalizer would have hidden this exact finding, since both link styles
  render identically.

  BLIND IS NOT CLEAN. No key, an unreachable API, or a post whose card cannot be read exits 3. A run that
  examined nothing must never print "no drift", which is the zero-rows collapse this estate keeps re-learning.

  THE ALLOWLIST IS KEYED TO THE DRIFT, NOT THE SLUG. A reviewed difference is recorded as slug + the SHA of
  the live body it was reviewed against. Silencing by slug alone would switch the tool off for that page
  forever - the next, different drift on my-crew would never be seen. Change the live body and it speaks up
  again.

  Usage: .\audit-ghost-drift.ps1 [-ShowDiff] [-Discover] [-Accept <slug>] | -SelfTest
  Exit:  0 = every mapped tool matches (or is allowlisted), 1 = drift found, 3 = could not evaluate
#>
param([switch]$ShowDiff, [switch]$Discover, [string]$Accept = '', [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\guard-contract.ps1')
$root = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\income\grocery' }
$repo = Split-Path $root -Parent
$API  = 'https://map-to-success.ghost.io'
$manifestPath  = Join-Path $root 'ghost-tool-manifest.json'
$allowPath     = Join-Path $root 'ghost-drift-allowlist.json'

function Get-BodyHash { param([string]$Text)
  if ($null -eq $Text) { return '' }
  return [BitConverter]::ToString((New-Object Security.Cryptography.SHA256Managed).ComputeHash(
    [Text.Encoding]::UTF8.GetBytes($Text))).Replace('-', '').Substring(0, 16)
}

function Compare-ToolBody { param($Local, $Live)
  <# Pure: no files, no network, so the self-test can drive it with frozen fixtures. Returns the verdict plus
     the first differing region, found by trimming the common prefix and suffix - that is what makes the
     output actionable ("19 links gained a host") instead of just "512 bytes different".

     The params are UNTYPED on purpose. Declared as [string], PS 5.1 coerces a $null argument to '' before
     the body runs, so the "$null -eq $Live" blind check below could never fire and an absent live body
     read as an empty one - a difference, but reported as ordinary drift instead of could-not-evaluate.
     Caught by the must-fire fixture, which is the only reason it is not still in here. #>
  if ([string]::IsNullOrEmpty($Local) -or [string]::IsNullOrEmpty($Live)) { return [pscustomobject]@{ same = $false; blind = $true } }
  if ($Local -eq $Live) { return [pscustomobject]@{ same = $true; blind = $false; delta = 0 } }
  $pre = 0
  while ($pre -lt $Local.Length -and $pre -lt $Live.Length -and $Local[$pre] -eq $Live[$pre]) { $pre++ }
  $suf = 0
  while ($suf -lt ($Local.Length - $pre) -and $suf -lt ($Live.Length - $pre) -and
         $Local[$Local.Length - 1 - $suf] -eq $Live[$Live.Length - 1 - $suf]) { $suf++ }
  return [pscustomobject]@{
    same     = $false
    blind    = $false
    delta    = ($Live.Length - $Local.Length)
    prefix   = $pre
    localMid = $Local.Substring($pre, $Local.Length - $pre - $suf)
    liveMid  = $Live.Substring($pre, $Live.Length - $pre - $suf)
  }
}

function Test-Allowlisted { param($Allow, [string]$Slug, [string]$LiveHash)
  foreach ($a in @($Allow)) { if ($a.slug -eq $Slug -and $a.live_hash -eq $LiveHash) { return $true } }
  return $false
}

# ---------------------------------------------------------------- self-test: frozen fixtures, no network
if ($SelfTest) {
  $f = 0
  function T($m, $c, $g) { if ($c) { Write-Output ("ok    " + $m) } else { Write-Output ("FAIL  " + $m + "   got: " + $g); $script:f++ } }

  T 'identical bodies are clean' (Compare-ToolBody 'abc' 'abc').same 'reported drift'

  # FROZEN FIXTURE, the founding case: the cheapest-protein nav link, relative locally and absolute live.
  $lo = '<p>Want dinners? <a href="/whats-for-dinner-tonight/">tonight</a></p>'
  $lv = '<p>Want dinners? <a href="https://www.thriftycrew.com/whats-for-dinner-tonight/">tonight</a></p>'
  $r  = Compare-ToolBody $lo $lv
  T 'MUST FIRE  an absolute-vs-relative link difference is drift' (-not $r.same) 'called it clean'
  T 'the delta is the host that live gained (27 chars)' ($r.delta -eq 27) $r.delta
  T 'the differing region is isolated, not the whole file' ($r.liveMid -eq 'https://www.thriftycrew.com') $r.liveMid
  T 'local side of that region is empty (live only ADDED)' ($r.localMid -eq '') "[$($r.localMid)]"

  # a normalizer would have hidden the founding finding - assert we did NOT write one
  T 'MUST FIRE  bytes are compared, not rendered text (both links render the same)' `
    (-not (Compare-ToolBody '<a href="/x/">x</a>' '<a href="https://www.thriftycrew.com/x/">x</a>').same) 'normalized the difference away'

  T 'MUST FIRE  a missing live body is BLIND, never clean' (Compare-ToolBody 'abc' $null).blind 'treated absent as clean'

  # the allowlist must be keyed to the DRIFT, not the page
  $allow = @([pscustomobject]@{ slug = 'my-crew'; live_hash = 'AAAA1111BBBB2222' })
  T 'a reviewed drift is silenced'                (Test-Allowlisted $allow 'my-crew' 'AAAA1111BBBB2222') 'still cried'
  T 'MUST FIRE  a DIFFERENT drift on the same slug still fires' `
    (-not (Test-Allowlisted $allow 'my-crew' 'CCCC3333DDDD4444')) 'slug-wide silence: the next drift would be invisible'
  T 'MUST FIRE  the same hash on another slug is not silenced' `
    (-not (Test-Allowlisted $allow 'my-staples' 'AAAA1111BBBB2222')) 'hash matched across pages'

  T 'a body hash is stable and 16 chars' ((Get-BodyHash 'abc') -eq (Get-BodyHash 'abc') -and (Get-BodyHash 'abc').Length -eq 16) (Get-BodyHash 'abc')
  T 'different bodies hash differently' ((Get-BodyHash 'abc') -ne (Get-BodyHash 'abd')) 'collision'

  if ($f -eq 0) { Write-Output 'SELF-TEST PASS'; exit 0 } else { Write-Output "SELF-TEST FAIL: $f case(s)"; exit 1 }
}

# ---------------------------------------------------------------- live: fetch every mapped tool's card
. (Join-Path $repo 'lib\ghost-lib.ps1')
$key = if ($env:GHOST_ADMIN_KEY) { $env:GHOST_ADMIN_KEY } else {
  $kf = Join-Path $repo 'meal-prep\.ghostkey'
  if (Test-Path $kf) { (Get-Content $kf -Raw).Trim() } else { '' }
}
if (-not $key) {
  Write-Output 'ghost-drift: COULD NOT EVALUATE - no GHOST_ADMIN_KEY and no meal-prep\.ghostkey, so nothing was compared'
  exit 3
}

function Get-CardBody { param([string]$Slug)
  $jwt = Get-GhostJWT -Key $key
  $p = (Invoke-RestMethod -Uri "$API/ghost/api/admin/posts/slug/$Slug/?formats=lexical&fields=id,slug,lexical" `
        -Headers @{ Authorization = "Ghost $jwt"; 'Accept-Version' = 'v5.0' } -TimeoutSec 45).posts[0]
  if (-not $p -or -not $p.lexical) { return $null }
  $lex = $p.lexical | ConvertFrom-Json
  $html = ''
  foreach ($c in $lex.root.children) { if ($c.type -eq 'html' -and $c.html) { $html += [string]$c.html } }
  if (-not $html) { return $null }
  return $html
}

if ($Discover) {
  # Rebuild the manifest by CONTENT, because the slug is not derivable from the filename (leak-finder-tool
  # publishes to money-leak-finder). Fingerprints on slices spread through the file, so a partially drifted
  # page still matches - whole-file matching would only ever find the tools that have NOT drifted.
  $bodies = @{}
  $page = 1
  do {
    $jwt = Get-GhostJWT -Key $key
    $r = Invoke-RestMethod -Uri "$API/ghost/api/admin/posts/?limit=100&page=$page&formats=lexical&fields=id,slug,lexical" `
          -Headers @{ Authorization = "Ghost $jwt"; 'Accept-Version' = 'v5.0' } -TimeoutSec 90
    foreach ($p in $r.posts) {
      if (-not $p.lexical) { continue }
      try { $lex = $p.lexical | ConvertFrom-Json } catch { continue }
      $h = ''
      foreach ($c in $lex.root.children) { if ($c.type -eq 'html' -and $c.html) { $h += [string]$c.html } }
      if ($h) { $bodies[$p.slug] = $h }
    }
    $page++
  } while ($r.meta.pagination.next)
  Write-Output ("discover: {0} html-card post(s) fetched" -f $bodies.Count)

  $map = @()
  foreach ($lf in (Get-ChildItem (Join-Path $repo '*-tool.html') -File | Sort-Object Name)) {
    $local = [IO.File]::ReadAllText($lf.FullName)
    $probe = @()
    for ($i = 1; $i -le 7; $i++) {
      $at = [int]([math]::Floor($local.Length * $i / 8))
      if ($at + 120 -lt $local.Length) { $probe += $local.Substring($at, 120) }
    }
    $best = $null; $bestHits = 0
    foreach ($s in $bodies.Keys) {
      $hits = 0
      foreach ($pr in $probe) { if ($bodies[$s].Contains($pr)) { $hits++ } }
      if ($hits -gt $bestHits) { $bestHits = $hits; $best = $s }
    }
    if ($best -and $bestHits -ge 4) {
      $map += [pscustomobject]@{ slug = $best; file = $lf.Name; matched_slices = ("{0}/{1}" -f $bestHits, $probe.Count) }
      Write-Output ("  {0,-34} -> {1}  ({2}/{3} slices)" -f $lf.Name, $best, $bestHits, $probe.Count)
    } else {
      Write-Output ("  {0,-34} -> NO CONFIDENT MATCH ({1} slices) - left out of the manifest rather than guessed" -f $lf.Name, $bestHits)
    }
  }
  (@{ generated = (Get-Date -Format 'yyyy-MM-dd'); note = 'slug<->local source for the tool posts; rebuild with -Discover'; tools = $map } |
    ConvertTo-Json -Depth 5) | Out-File $manifestPath -Encoding utf8
  Write-Output ("manifest written: {0} tool(s) -> {1}" -f $map.Count, $manifestPath)
  Write-GuardComplete -Name 'ghost-drift' -Summary ("discover mapped={0}" -f $map.Count)
  exit 0
}

if (-not (Test-Path $manifestPath)) {
  Write-Output ("ghost-drift: COULD NOT EVALUATE - no manifest at {0}. Run -Discover once to build it." -f $manifestPath)
  exit 3
}
$manifest = @((Get-Content $manifestPath -Raw | ConvertFrom-Json).tools)
if (-not $manifest.Count) {
  Write-Output 'ghost-drift: COULD NOT EVALUATE - the manifest maps zero tools, so a clean result would prove nothing'
  exit 3
}
$allow = @()
if (Test-Path $allowPath) { try { $allow = @((Get-Content $allowPath -Raw | ConvertFrom-Json).allow) } catch { } }

$clean = @(); $drift = @(); $blind = @()
foreach ($t in $manifest) {
  $lf = Join-Path $repo $t.file
  if (-not (Test-Path $lf)) { $blind += ("{0}: local source {1} is gone" -f $t.slug, $t.file); continue }
  $local = [IO.File]::ReadAllText($lf)
  $live = $null
  try { $live = Get-CardBody $t.slug } catch { $blind += ("{0}: {1}" -f $t.slug, $_.Exception.Message); continue }
  if ($null -eq $live) { $blind += ("{0}: no html card on the live post" -f $t.slug); continue }

  $r = Compare-ToolBody $local $live
  if ($r.same) { $clean += $t.slug; continue }
  $h = Get-BodyHash $live
  if (Test-Allowlisted $allow $t.slug $h) { $clean += ($t.slug + ' (reviewed drift)'); continue }
  $drift += [pscustomobject]@{ slug = $t.slug; file = $t.file; delta = $r.delta; hash = $h
                               localMid = $r.localMid; liveMid = $r.liveMid; prefix = $r.prefix }
}

if ($Accept) {
  $hit = @($drift | Where-Object { $_.slug -eq $Accept })
  if (-not $hit.Count) { Write-Output ("nothing to accept: {0} is not currently drifted" -f $Accept); exit 1 }
  $new = @($allow) + @([pscustomobject]@{ slug = $Accept; live_hash = $hit[0].hash
                                          reviewed = (Get-Date -Format 'yyyy-MM-dd')
                                          reason = 'REPLACE ME: why the live body is allowed to differ' })
  (@{ allow = $new } | ConvertTo-Json -Depth 5) | Out-File $allowPath -Encoding utf8
  Write-Output ("recorded {0} @ {1} in the allowlist - now write the reason field, an unexplained silence is not a review" -f $Accept, $hit[0].hash)
  Write-GuardComplete -Name 'ghost-drift' -Summary ("accepted={0}" -f $Accept)
  exit 0
}

Write-Output ("ghost-drift: {0} of {1} mapped tool(s) match their local source" -f $clean.Count, $manifest.Count)
foreach ($b in $blind) { Write-Output ("  BLIND  " + $b) }
foreach ($d in $drift) {
  Write-Output ("  DRIFT  {0,-26} live is {1:+#;-#;0} byte(s) vs {2}" -f $d.slug, $d.delta, $d.file)
  if ($ShowDiff) {
    $lm = if ($d.localMid.Length -gt 220) { $d.localMid.Substring(0, 220) + '...' } else { $d.localMid }
    $vm = if ($d.liveMid.Length  -gt 220) { $d.liveMid.Substring(0, 220)  + '...' } else { $d.liveMid }
    Write-Output ("           first difference at char {0}" -f $d.prefix)
    Write-Output ("           local: [" + $lm + "]")
    Write-Output ("           live : [" + $vm + "]")
  }
}
if ($drift.Count) {
  Write-Output ''
  Write-Output '  Republishing from local would OVERWRITE the live body. Decide per tool: bring the change back into'
  Write-Output '  the local source, or record it with -Accept <slug> and say why. -ShowDiff prints what differs.'
}
# BLIND anywhere means the run cannot claim a clean sweep, even if everything it DID reach matched.
if ($blind.Count) { Write-GuardComplete -Name 'ghost-drift' -Summary ("clean={0} drift={1} blind={2}" -f $clean.Count, $drift.Count, $blind.Count); exit 3 }
Write-GuardComplete -Name 'ghost-drift' -Summary ("clean={0} drift={1}" -f $clean.Count, $drift.Count)
exit $(if ($drift.Count) { 1 } else { 0 })
