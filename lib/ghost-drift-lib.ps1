# ghost-drift-lib.ps1 - THE comparison between a live Ghost html card and the local source it came from.
#
# WHY A LIB (2026-08-08). Two callers need this exact answer: grocery\audit-ghost-drift.ps1 sweeping all
# sixteen tools, and publish-tool-post.ps1 refusing to blind-overwrite a live body it never looked at. This
# estate has already paid for the alternative - a shared-lib fix that shipped nothing because every caller
# kept its own inline copy. One definition, two dot-sources.
#
# NO param() BLOCK, DELIBERATELY. In PS 5.1 a dot-sourced script's param() block runs in the CALLER's scope,
# so a [switch]$SelfTest here would silently reset a caller's own -SelfTest to $false. That exact bug shipped
# in lib\guard-contract.ps1 the same day and disarmed nine guards' self-tests; see the note there.
$__gdSelfTest = ($MyInvocation.InvocationName -ne '.') -and ($args -contains '-SelfTest')

function Get-BodyHash { param($Text)
  if ([string]::IsNullOrEmpty($Text)) { return '' }
  return [BitConverter]::ToString((New-Object Security.Cryptography.SHA256Managed).ComputeHash(
    [Text.Encoding]::UTF8.GetBytes($Text))).Replace('-', '').Substring(0, 16)
}

$script:GD_SITE = 'https://www.thriftycrew.com'

function Get-CanonicalBody { param($Text)
  <# Undo the ONE transformation the platform performs, so a comparison measures OUR changes and not Ghost's.

     MEASURED 2026-08-08, after this got it wrong in production. Ghost stores a site-relative URL as an
     internal __GHOST_URL__ placeholder and expands it to the absolute site URL when the Admin API reads the
     post back. So a local file containing href="/my-staples/" can NEVER read back equal, no matter how many
     times it is republished - proved by republishing my-crew and cheapest-protein and watching the byte
     delta come back identical (+513 and +27) with a fresh updated_at.

     That is also why only those two looked drifted: they are the only two of the sixteen tools that contain
     relative internal hrefs at all (20 and 1; the other fourteen have none). The first version of this lib
     asserted the opposite in a must-fire fixture - that absolute-vs-relative IS drift and normalizing it
     would hide a real finding. There was no real finding. Platform round-trip, not drift.

     Scope is deliberately ONE rule, applied to both sides. This cannot distinguish Ghost's expansion from a
     human editing a link to absolute in Ghost admin - the API returns the same bytes either way, so no
     comparison could. Everything else still compares byte for byte. #>
  if ([string]::IsNullOrEmpty($Text)) { return $Text }
  return $Text.Replace('__GHOST_URL__/', '/').Replace($script:GD_SITE + '/', '/')
}

function Compare-ToolBody { param($Local, $Live)
  <# Pure: no files, no network, so fixtures can drive it. Returns the verdict plus the first differing
     region, found by trimming the common prefix and suffix - that is what makes the output actionable
     ("this paragraph changed") instead of just "512 bytes different".

     Bytes, after Get-CanonicalBody undoes the platform's own URL rewrite on BOTH sides. No other
     normalizing: rendered-text or whitespace-insensitive comparison would hide exactly the edits worth
     catching.

     The params are UNTYPED on purpose. Declared [string], PS 5.1 coerces a $null argument to '' before the
     body runs, so the blind check below could never fire and an absent live body read as ordinary drift
     instead of could-not-evaluate. A must-fire fixture is the only reason that is not still in here. #>
  if ([string]::IsNullOrEmpty($Local) -or [string]::IsNullOrEmpty($Live)) { return [pscustomobject]@{ same = $false; blind = $true } }
  $Local = Get-CanonicalBody $Local
  $Live  = Get-CanonicalBody $Live
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
  <# Keyed to slug + the hash of the live body it was reviewed against, NOT to the slug. Silencing by slug
     would switch the check off for that page forever, so the NEXT, different drift on my-crew would be
     invisible - the estate's contested-flag lesson. Change the live body and it speaks up again. #>
  foreach ($a in @($Allow)) { if ($a.slug -eq $Slug -and $a.live_hash -eq $LiveHash) { return $true } }
  return $false
}

function Get-GhostCardBody { param([string]$Api, [string]$Key, [string]$Slug)
  <# The live html card body, concatenated in document order. A tool post is one card, but do not assume it -
     returns $null when there is no card at all, which callers must treat as BLIND, never as clean. #>
  $jwt = Get-GhostJWT -Key $Key
  $p = (Invoke-RestMethod -Uri "$Api/ghost/api/admin/posts/slug/$Slug/?formats=lexical&fields=id,slug,lexical" `
        -Headers @{ Authorization = "Ghost $jwt"; 'Accept-Version' = 'v5.0' } -TimeoutSec 45).posts[0]
  if (-not $p -or -not $p.lexical) { return $null }
  $lex = $p.lexical | ConvertFrom-Json
  $html = ''
  foreach ($c in $lex.root.children) { if ($c.type -eq 'html' -and $c.html) { $html += [string]$c.html } }
  if (-not $html) { return $null }
  return $html
}

if ($__gdSelfTest) {
  $f = 0
  function T($m, $c, $g) { if ($c) { Write-Output ("ok    " + $m) } else { Write-Output ("FAIL  " + $m + "   got: " + $g); $script:f++ } }

  T 'identical bodies are clean' (Compare-ToolBody 'abc' 'abc').same 'reported drift'

  # FROZEN FIXTURE, the cheapest-protein shape. This is Ghost expanding its own stored placeholder on read,
  # NOT drift - proved by republishing from local and watching the identical +27 come straight back with a
  # fresh updated_at. The first version of this lib asserted the reverse and reported two false findings.
  $lo = '<p>Want dinners? <a href="/whats-for-dinner-tonight/">tonight</a></p>'
  $lv = '<p>Want dinners? <a href="https://www.thriftycrew.com/whats-for-dinner-tonight/">tonight</a></p>'
  T 'the platform URL round-trip is NOT drift (republishing can never clear it)' (Compare-ToolBody $lo $lv).same 'false positive is back'
  T '__GHOST_URL__ is folded the same way' `
    (Compare-ToolBody '<a href="/x/">x</a>' '<a href="__GHOST_URL__/x/">x</a>').same 'placeholder not handled'

  # ...and the normalization must stay NARROW. Only the site host is folded; everything else still differs.
  $r = Compare-ToolBody '<p>Cheapest protein this week</p>' '<p>Cheapest protein last week</p>'
  T 'MUST FIRE  a real copy edit is still drift'  (-not $r.same) 'normalized a real change away'
  T 'the differing region is isolated, not the whole file' ($r.localMid -eq 'this' -and $r.liveMid -eq 'last') "[$($r.localMid)|$($r.liveMid)]"
  T 'MUST FIRE  a link to a DIFFERENT host is still drift' `
    (-not (Compare-ToolBody '<a href="/x/">x</a>' '<a href="https://evil.example.com/x/">x</a>').same) 'folded a foreign host'
  T 'MUST FIRE  a changed PATH on the site host is still drift' `
    (-not (Compare-ToolBody '<a href="/x/">x</a>' '<a href="https://www.thriftycrew.com/y/">x</a>').same) 'folded a path change'
  T 'MUST FIRE  whitespace is not normalized (an edit is an edit)' `
    (-not (Compare-ToolBody '<p>a b</p>' '<p>a  b</p>').same) 'whitespace-insensitive comparison'
  T 'MUST FIRE  a missing live body is BLIND, never clean' (Compare-ToolBody 'abc' $null).blind 'treated absent as clean'
  T 'MUST FIRE  an empty live body is BLIND too ([string] would coerce $null to this)' (Compare-ToolBody 'abc' '').blind 'treated empty as drift'

  $allow = @([pscustomobject]@{ slug = 'my-crew'; live_hash = 'AAAA1111BBBB2222' })
  T 'a reviewed drift is silenced' (Test-Allowlisted $allow 'my-crew' 'AAAA1111BBBB2222') 'still cried'
  T 'MUST FIRE  a DIFFERENT drift on the same slug still fires' `
    (-not (Test-Allowlisted $allow 'my-crew' 'CCCC3333DDDD4444')) 'slug-wide silence: the next drift would be invisible'
  T 'MUST FIRE  the same hash on another slug is not silenced' `
    (-not (Test-Allowlisted $allow 'my-staples' 'AAAA1111BBBB2222')) 'hash matched across pages'
  T 'a body hash is stable and 16 chars' ((Get-BodyHash 'abc') -eq (Get-BodyHash 'abc') -and (Get-BodyHash 'abc').Length -eq 16) (Get-BodyHash 'abc')
  T 'different bodies hash differently' ((Get-BodyHash 'abc') -ne (Get-BodyHash 'abd')) 'collision'

  if ($f -eq 0) { Write-Output 'SELF-TEST PASS'; exit 0 } else { Write-Output "SELF-TEST FAIL: $f case(s)"; exit 1 }
}
