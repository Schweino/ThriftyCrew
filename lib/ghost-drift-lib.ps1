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
  # SECOND PLATFORM-NEUTRAL FOLD: LINE ENDINGS (2026-09-07, queue 2026-09-07-e7286e).
  # Two tools reported drift of exactly +159 and +286 bytes - one CR per line, 145 and 272 of them, plus a
  # 14-byte cost delta. Both were last published on 2026-09-03 from a CRLF working copy, three days before
  # the estate-wide eol=lf attribute (39ad18d3d) turned every source LF. So every byte-exact comparison
  # against something published under the old regime now reads as drift by exactly its own line count, and
  # the first difference lands at the first newline - which is why the reported excerpts looked identical.
  # (The same regime change blinded grocery\test-capture-builders.ps1 the same morning, from the other side.)
  # A line ending is a property of the checkout that wrote the file, not a change to what a reader sees.
  # THE FOLD STAYS NARROW: an extra SPACE, a copy edit, a foreign host and a changed path all still fire -
  # each has its own must-fire case below, and one of them is a copy edit inside a CRLF body, so the fold
  # cannot hide an edit behind a line ending.
  return $Text.Replace('__GHOST_URL__/', '/').Replace($script:GD_SITE + '/', '/').Replace("`r`n", "`n")
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

# ---- RECIPE CARDS: the ledger already exists, it just never pointed at LIVE ---------------------------
# meal-prep\engine\publish.ps1 writes db\published-hashes.json, one SHA1 per slug over exactly
#   body + \0 + head + \0 + name + \0 + desc
# and uses it as a CHANGE GATE - "skip republishing this slug, the bytes are unchanged". That answers "did we
# publish this?", never "does live still hold it". So an edit made in Ghost admin, or a partial PUT, moves
# live away from the ledger and nothing in the estate can see it. Recomputing the same hash from what the
# Admin API returns turns that existing ledger into a drift check over all 542 cards for free.
#
# It is stable BETWEEN republishes, which is what makes it usable: a card's prices are baked at build time,
# so live bytes do not drift on their own as the board moves. The hash only advances when publish.ps1
# verifies a successful publish, so a mismatch means live changed WITHOUT us.
#
# Duplicated deliberately rather than imported: publish.ps1 is the estate's publisher and is not worth
# editing for an audit's convenience. The self-test extracts publish.ps1's own Get-ContentHash and asserts
# the two agree on the same input, so the copy cannot silently drift from the original.
# ---- THE RECIPE NODE (2026-09-07, backlog I44) ------------------------------------------------------
# The claim now lives on the Recipe node too, because that is the node Google reads for a recipe rich
# result. These three functions are PURE so the fixtures drive them; the live path only composes them.
$LDJSON_RX = '<script type="application/ld\+json">\s*([\s\S]*?)\s*</script>'

function Get-TcRecipeNodeClaim {
  <# $true when the head's Recipe node carries the paywall claim, $false when it does not, and $null
     when the head has no Recipe node at all.

     THREE ANSWERS, NOT TWO. "no Recipe node" is not "not claimed" - a head that lost its Recipe block
     is a different failure and must not read as a tidy negative. #>
  param([string]$Head)
  foreach ($m in [regex]::Matches([string]$Head, $LDJSON_RX)) {
    $doc = $null
    try { $doc = $m.Groups[1].Value | ConvertFrom-Json } catch { continue }
    if ($null -eq $doc) { continue }
    if ([string]$doc.'@type' -ne 'Recipe') { continue }
    return [bool]($doc.PSObject.Properties['isAccessibleForFree'] -and ($doc.isAccessibleForFree -eq $false))
  }
  return $null
}

function Set-TcRecipeNodeClaim {
  <# Returns the head with the Recipe node's claim set (Paid) or cleared. Any other ld+json block is
     returned byte-for-byte: this must never touch the Article block, which the caller owns.

     PARSED RATHER THAN REGEXED because hasPart is a nested object, and stripping a nested object out
     of pretty-printed JSON by pattern means balancing braces in text - which is how a head field ends
     up truncated. #>
  param([string]$Head, [bool]$Paid)
  $out = [string]$Head
  foreach ($m in [regex]::Matches([string]$Head, $LDJSON_RX)) {
    $payload = $m.Groups[1].Value
    $doc = $null
    try { $doc = $payload | ConvertFrom-Json } catch { continue }
    if ($null -eq $doc -or [string]$doc.'@type' -ne 'Recipe') { continue }
    if ($Paid) {
      if ($doc.PSObject.Properties['isAccessibleForFree']) { $doc.isAccessibleForFree = $false }
      else { $doc | Add-Member -NotePropertyName isAccessibleForFree -NotePropertyValue $false }
      $hp = [pscustomobject]@{ '@type' = 'WebPageElement'; isAccessibleForFree = $false; cssSelector = '.gh-content' }
      if ($doc.PSObject.Properties['hasPart']) { $doc.hasPart = $hp }
      else { $doc | Add-Member -NotePropertyName hasPart -NotePropertyValue $hp }
    } else {
      foreach ($k in @('isAccessibleForFree', 'hasPart')) {
        if ($doc.PSObject.Properties[$k]) { $doc.PSObject.Properties.Remove($k) }
      }
    }
    $new = $doc | ConvertTo-Json -Depth 12
    $out = $out.Replace($m.Value, ("<script type=`"application/ld+json`">`n" + $new + "`n</script>"))
  }
  return $out
}

function Get-PublishedContentHash { param([string]$Body, [string]$Head, [string]$Name, [string]$Desc)
  $s = $Body + "`0" + $Head + "`0" + $Name + "`0" + $Desc
  $sha = [System.Security.Cryptography.SHA1]::Create()
  return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($s))) -replace '-', '')
}

# ---- OUR OWN transformation, the second one (2026-08-31) ----------------------------------------
# Get-CanonicalBody above undoes what the PLATFORM does to a body. This undoes what WE do to it.
#
# publish.ps1 splits a built body at <!--TC-PAYWALL--> into html|paywall|html so Ghost has somewhere
# to cut a paid post. The sentinel is a SPLIT POINT, not content, so it is not stored in either half -
# and every reader that reassembled the halves by concatenation got the body back 17 bytes short.
#
# MEASURED 2026-08-31, and it had gone unnoticed because it fails the safe-looking way. On that day
# audit-ghost-drift reported 577 of 577 recipes drifted, 0 matching - and publish.ps1's pre-flight,
# which reads the same reassembly, was REFUSING every recipe update as a hand-edit it must not
# overwrite. Neither was drift. Both were this. A guard that indicts everything indicts nothing, and
# the only way past it was -Force, which is the guard turned off.
#
# The inverse is exact, not approximate: publish.ps1 writes preview + SENTINEL + rest, so replaying
# the sentinel at the paywall child rebuilds the byte-identical body. Proved on six live posts - five
# unchanged ones came back byte-identical, and the sixth was the one card genuinely rebuilt that hour,
# which is the control: this fold must still SEE a real change.
$script:GD_PAYWALL_SENTINEL = '<!--TC-PAYWALL-->'

function Join-GhostLexicalBody { param($Root)
  <# Reassemble a live lexical root into the body we published, in document order.
     The exact inverse of publish.ps1's paywall split. An unsplit post has one html child and no
     paywall child, so it rejoins to itself and this is a no-op for the 16 tool posts. #>
  $out = ''
  if ($null -eq $Root) { return $out }
  foreach ($c in $Root.children) {
    $t = [string]$c.type
    if ($t -eq 'html') { if ($c.html) { $out += [string]$c.html } }
    elseif ($t -eq 'paywall') { $out += $script:GD_PAYWALL_SENTINEL }
  }
  return $out
}

function Test-LivePageStale {
  <# Is a live page old enough that its AGE is the finding, not its byte delta?
     Pure and parameterised so the fixture can drive it: the live-age reader beside it is network-bound,
     and a rule whose only test is a live API call is a rule with no test. StaleDays is the caller's, so
     moving the threshold is a visible edit rather than a constant buried in a format string. #>
  param($UpdatedAt, [int]$StaleDays = 14, $Now = $null)
  if ($null -eq $Now) { $Now = Get-Date }
  # AN UNREADABLE TIMESTAMP IS NOT FRESH. Returning stale=$false with no blind flag would make a page whose
  # age cannot be read indistinguishable from one published this morning - blind is not clean.
  if ($null -eq $UpdatedAt) { return [pscustomobject]@{ stale = $false; blind = $true; days = -1 } }
  $d = [int][math]::Floor((([datetime]$Now) - ([datetime]$UpdatedAt)).TotalDays)
  return [pscustomobject]@{ stale = ($d -gt $StaleDays); blind = $false; days = $d }
}

function Get-GhostPostUpdatedAt { param([string]$Api, [string]$Key, [string]$Slug)
  <# WHEN was this page last published (2026-09-07, queue 2026-09-07-e7286e).
     ghost-drift reported "sams-club-worth-it live is -35173 byte(s)" and nothing else. That page had been
     live with 2026-07-08 prices for FIFTY-EIGHT DAYS on a money page, and the word "drift" carries no age -
     it reads the same at one hour and at two months. Nothing in the daily chain publishes a tool page, so
     a stale one has no other watcher: audit-surface-staleness compares LOCAL files to the manifest and
     stays green. The age is the finding.
     Returns $null rather than throwing, because an unreadable timestamp must not turn a real drift finding
     into a crash - callers print the drift either way and simply say nothing about its age. #>
  try {
    $jwt = Get-GhostJWT -Key $Key
    $p = (Invoke-RestMethod -Uri "$Api/ghost/api/admin/posts/slug/$Slug/?fields=id,slug,updated_at" `
          -Headers @{ Authorization = "Ghost $jwt"; 'Accept-Version' = 'v5.0' } -TimeoutSec 45).posts[0]
    if (-not $p -or -not $p.updated_at) { return $null }
    return [datetime]$p.updated_at
  } catch { return $null }
}

function Get-GhostCardBody { param([string]$Api, [string]$Key, [string]$Slug)
  <# The live html card body, concatenated in document order. A tool post is one card, but do not assume it -
     returns $null when there is no card at all, which callers must treat as BLIND, never as clean. #>
  $jwt = Get-GhostJWT -Key $Key
  $p = (Invoke-RestMethod -Uri "$Api/ghost/api/admin/posts/slug/$Slug/?formats=lexical&fields=id,slug,lexical" `
        -Headers @{ Authorization = "Ghost $jwt"; 'Accept-Version' = 'v5.0' } -TimeoutSec 45).posts[0]
  if (-not $p -or -not $p.lexical) { return $null }
  $lex = $p.lexical | ConvertFrom-Json
  $html = Join-GhostLexicalBody -Root $lex.root
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

  # ---- LINE ENDINGS ARE THE CHECKOUT, NOT THE CONTENT (2026-09-07, queue 2026-09-07-e7286e) -------------
  # cheap-dinners-right-now and whats-for-dinner-tonight were reported as drifted by +159 and +286 bytes:
  # one CR per line from a 2026-09-03 publish out of a CRLF working copy, three days before the eol=lf
  # attribute turned the sources LF. The first difference landed at the first newline, so the printed
  # excerpts looked identical and the finding was unreadable.
  $lfBody   = "<p>line one</p>`n<p>line two</p>`n<p>line three</p>"
  $crlfBody = $lfBody.Replace("`n", "`r`n")
  T 'CLEAN TWIN  the same body published from a CRLF checkout is NOT drift' `
    (Compare-ToolBody $lfBody $crlfBody).same 'a line ending is being reported as a content change'
  T 'CLEAN TWIN  and it folds in the other direction too (a CRLF local against an LF live)' `
    (Compare-ToolBody $crlfBody $lfBody).same 'the fold is one-directional'
  # MUST FIRE: the fold must not become a place to hide an edit. Same CRLF live body, one word changed.
  $crlfEdited = $crlfBody.Replace('line two', 'line five')
  $rCr = Compare-ToolBody $lfBody $crlfEdited
  T 'MUST FIRE  a copy edit INSIDE a CRLF body is still drift' (-not $rCr.same) 'the CR fold swallowed a real edit'
  T 'MUST FIRE  and the differing region is still isolated to the words that changed' `
    ($rCr.localMid -eq 'two' -and $rCr.liveMid -eq 'five') "[$($rCr.localMid)|$($rCr.liveMid)]"
  # MUST FIRE: a lone CR is not a line ending pair and is not folded - only CRLF is.
  T 'MUST FIRE  a bare CR that is not part of a CRLF pair is still drift' `
    (-not (Compare-ToolBody "<p>a`nb</p>" "<p>a`r`n`rb</p>").same) 'folded a stray carriage return'

  # ---- A LIVE PAGE'S AGE IS ITS OWN FINDING (2026-09-07, queue 2026-09-07-e7286e) -----------------------
  # sams-club-worth-it was reported only as "live is -35173 byte(s)". It had been serving 2026-07-08 prices
  # for 58 days on a money page, and nothing else could see it: no daily stage publishes a tool source, and
  # audit-surface-staleness compares LOCAL files to the manifest so it stayed green throughout. `Now` is a
  # parameter because a fixture pinned to the wall clock stops testing the day it is written.
  $sNow = [datetime]'2026-09-07T12:00:00'
  T 'MUST FIRE  the founding page: 2026-07-11 against 2026-09-07 is 58 days and reads STALE' `
    ((Test-LivePageStale -UpdatedAt ([datetime]'2026-07-11T09:07:32') -StaleDays 14 -Now $sNow).stale -and
     (Test-LivePageStale -UpdatedAt ([datetime]'2026-07-11T09:07:32') -StaleDays 14 -Now $sNow).days -eq 58) `
    ([string](Test-LivePageStale -UpdatedAt ([datetime]'2026-07-11T09:07:32') -StaleDays 14 -Now $sNow).days)
  T 'MUST NOT FIRE  the two CR-drifted tools, published 2026-09-03, are 3 days old and are NOT stale' `
    (-not (Test-LivePageStale -UpdatedAt ([datetime]'2026-09-03T21:29:18') -StaleDays 14 -Now $sNow).stale) `
    ([string](Test-LivePageStale -UpdatedAt ([datetime]'2026-09-03T21:29:18') -StaleDays 14 -Now $sNow).days)
  T 'MUST NOT FIRE  exactly at the threshold is not past it (14 days is not > 14)' `
    (-not (Test-LivePageStale -UpdatedAt $sNow.AddDays(-14) -StaleDays 14 -Now $sNow).stale) 'off-by-one at the bound'
  T 'MUST FIRE  one day past the threshold is stale' `
    ((Test-LivePageStale -UpdatedAt $sNow.AddDays(-15) -StaleDays 14 -Now $sNow).stale) 'the threshold never fires'
  T 'MUST FIRE  an unreadable updated_at is BLIND, never fresh' `
    ((Test-LivePageStale -UpdatedAt $null -StaleDays 14 -Now $sNow).blind -and
     -not (Test-LivePageStale -UpdatedAt $null -StaleDays 14 -Now $sNow).stale) 'an unknown age read as fresh'

  $allow = @([pscustomobject]@{ slug = 'my-crew'; live_hash = 'AAAA1111BBBB2222' })
  T 'a reviewed drift is silenced' (Test-Allowlisted $allow 'my-crew' 'AAAA1111BBBB2222') 'still cried'
  T 'MUST FIRE  a DIFFERENT drift on the same slug still fires' `
    (-not (Test-Allowlisted $allow 'my-crew' 'CCCC3333DDDD4444')) 'slug-wide silence: the next drift would be invisible'
  T 'MUST FIRE  the same hash on another slug is not silenced' `
    (-not (Test-Allowlisted $allow 'my-staples' 'AAAA1111BBBB2222')) 'hash matched across pages'
  T 'a body hash is stable and 16 chars' ((Get-BodyHash 'abc') -eq (Get-BodyHash 'abc') -and (Get-BodyHash 'abc').Length -eq 16) (Get-BodyHash 'abc')
  T 'different bodies hash differently' ((Get-BodyHash 'abc') -ne (Get-BodyHash 'abd')) 'collision'

  # ---- the recipe-card hash must agree with the PUBLISHER's own definition ----
  # This is the "two copies of a rule" guard: Get-PublishedContentHash restates publish.ps1's recipe rather
  # than importing it, so the only thing keeping them honest is this case. It reads publish.ps1's actual
  # function text, runs it, and asserts both produce the same digest for the same four fields. Change the
  # hash in either place and this goes red instead of the audit quietly reporting 542 false drifts.
  # DERIVED, NOT HARDCODED (2026-08-08). This was the literal C:\Codex\ThriftyCrew\... path, so the case passed on
  # Brad's box and failed everywhere else - on the runner the checkout is D:\a\SimpleMoneyPlaybook\..., the
  # file was "not found", and gates run #2 went red over a path rather than a hash disagreement. publish.ps1
  # IS tracked, so the repo-relative path is the honest one.
  $pub = Join-Path (Split-Path $PSScriptRoot -Parent) 'meal-prep\engine\publish.ps1'
  if (Test-Path $pub) {
    $src = [IO.File]::ReadAllText($pub)
    $m = [regex]::Match($src, '(?m)^function Get-ContentHash.*$')
    if (-not $m.Success) {
      Write-Output 'FAIL  could not find Get-ContentHash in publish.ps1 - the agreement fixture is now blind'; $f++
    } else {
      Invoke-Expression $m.Value    # defines Get-ContentHash exactly as the publisher has it
      $b = '<div>body</div>'; $h = '<script>head</script>'; $n = 'Some Recipe'; $d = '610 calories, $3.58 each'
      $mine = Get-PublishedContentHash -Body $b -Head $h -Name $n -Desc $d
      $theirs = Get-ContentHash ($b + "`0" + $h + "`0" + $n + "`0" + $d)
      T 'the card hash matches publish.ps1''s own Get-ContentHash on the same input' ($mine -eq $theirs) "$mine vs $theirs"
      T 'that digest is a 40-char SHA1' ($mine.Length -eq 40) $mine
      T 'MUST FIRE  a changed field changes the digest' `
        ($mine -ne (Get-PublishedContentHash -Body $b -Head $h -Name $n -Desc ($d + ' '))) 'digest ignored a field change'
    }
  } else { Write-Output 'FAIL  publish.ps1 not found - cannot prove the card hash still matches the publisher'; $f++ }

  # ---- THE PAYWALL SPLIT MUST SURVIVE THE ROUND TRIP (2026-08-31) ----
  # Everything above compares two bodies. These prove we can still RECOVER the body we published from
  # what Ghost stores, now that publish.ps1 cuts it in two. Without them the reassembly can go back to
  # plain concatenation and every case here stays green while the audit reports 100% drift - which is
  # exactly the state this replaced: 577 of 577 recipes "drifted", 0 matching, and the publisher
  # refusing every update as a hand-edit.
  $PWS   = $script:GD_PAYWALL_SENTINEL
  $pvw   = '<p>' + ('preview text ' * 20) + '</p>'
  $rest  = '<h2>What This Batch Costs</h2><p>' + ('the costed half ' * 20) + '</p>'
  $full  = $pvw + $PWS + $rest
  function MkRoot($kids) { return [pscustomobject]@{ children = $kids } }
  $rootSplit = MkRoot @(
    [pscustomobject]@{ type = 'html'; html = $pvw },
    [pscustomobject]@{ type = 'paywall' },
    [pscustomobject]@{ type = 'html'; html = $rest })
  $rootFlat  = MkRoot @([pscustomobject]@{ type = 'html'; html = $pvw })

  T 'a split body rejoins BYTE-IDENTICAL to what was published' `
    ((Join-GhostLexicalBody -Root $rootSplit) -eq $full) (Join-GhostLexicalBody -Root $rootSplit)
  T 'an UNSPLIT post rejoins to itself (the 16 tool posts are unaffected)' `
    ((Join-GhostLexicalBody -Root $rootFlat) -eq $pvw) (Join-GhostLexicalBody -Root $rootFlat)
  T 'MUST FIRE  no sentinel is FABRICATED when there is no paywall child' `
    (-not (Join-GhostLexicalBody -Root $rootFlat).Contains($PWS)) 'invented a split point that was never published'
  T 'MUST FIRE  plain concatenation is NOT the body (the defect this replaced)' `
    (($pvw + $rest) -ne $full) 'the sentinel costs nothing, so nothing would have been wrong'
  T 'MUST FIRE  an edit BEHIND the paywall is still seen' `
    ((Join-GhostLexicalBody -Root (MkRoot @(
        [pscustomobject]@{ type = 'html'; html = $pvw },
        [pscustomobject]@{ type = 'paywall' },
        [pscustomobject]@{ type = 'html'; html = ($rest + '<p>hand edit</p>') }))) -ne $full) `
    'folded a real change away - the guard would overwrite a hand edit'
  T 'MUST FIRE  an edit IN FRONT of the paywall is still seen' `
    ((Join-GhostLexicalBody -Root (MkRoot @(
        [pscustomobject]@{ type = 'html'; html = ($pvw + '!') },
        [pscustomobject]@{ type = 'paywall' },
        [pscustomobject]@{ type = 'html'; html = $rest }))) -ne $full) 'folded a real change away'
  T 'MUST FIRE  a null root is empty, never a false match' `
    ((Join-GhostLexicalBody -Root $null) -eq '') 'a body that could not be read must not compare equal'

  # ---- and the sentinel is ONE rule in TWO files, so pin them together ----
  # Same argument as the card-hash fixture above: publish.ps1 declares its own $PW literal. If either
  # side is edited alone the fold stops being an inverse, and the failure mode is silent 100% drift.
  $pubPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'meal-prep\engine\publish.ps1'
  if (Test-Path $pubPath) {
    $psrc = [IO.File]::ReadAllText($pubPath)
    $pat  = '(?m)^\s*\$' + 'PW = ' + "'" + '([^' + "'" + ']+)' + "'"
    $mp   = [regex]::Match($psrc, $pat)
    if (-not $mp.Success) {
      Write-Output 'FAIL  could not find publish.ps1''s own paywall sentinel - the inverse is now unpinned'; $f++
    } else {
      T 'the sentinel matches publish.ps1''s own $PW literal' ($mp.Groups[1].Value -eq $PWS) "$($mp.Groups[1].Value) vs $PWS"
    }
  } else { Write-Output 'FAIL  publish.ps1 not found - cannot pin the paywall sentinel'; $f++ }

  if ($f -eq 0) { Write-Output 'SELF-TEST PASS'; exit 0 } else { Write-Output "SELF-TEST FAIL: $f case(s)"; exit 1 }
}
