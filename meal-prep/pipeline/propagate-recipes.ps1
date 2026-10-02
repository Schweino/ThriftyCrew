# propagate-recipes.ps1 - ONE command that carries a spec change through every derived copy, or fails loudly.
#
# WHY THIS EXISTS (2026-08-08 architecture review). db\recipes is the master, and it feeds a chain of
# derived copies - recipes-db.json, planner-data, built cards, the live Ghost posts - each refreshed by a
# separate script that a human (or an agent) had to REMEMBER to run in the right order. Every derived copy
# someone forgot became an incident with its own name in the memory files: the og descriptions frozen at
# post creation (~140 pages quoting a wrong price), the R300 cost stamp that sat 10 days across 405 rows,
# and the repair-stops-at-source-of-truth class, twice. The publish step's content-hash gate already proved
# the cure at the last hop; this applies it to the whole chain.
#
# HOW IT DECIDES WHAT IS DIRTY. A SHA1 of each spec with its two DAILY-REANCHORED machine fields masked
# (see Get-SpecHash - stat.cost_ps / head.costPerServing move every day and are propagated by the
# reanchor loop, not by this runner), compared to pipeline\propagate-stamps.json.
# The stamp for a slug is rewritten ONLY after every stage has succeeded for it - a failing run leaves the
# slug dirty, so the next run retries it (the checkpoint-before-durable lesson: a watermark committed
# before the work it certifies turns a failure into silently skipped work).
#
# THE CHAIN (existing, gated scripts - this runner adds ordering + dirt tracking, not new logic):
#   1. sync-recipesdb-buy -Apply     carry label classes into recipes-db.json
#   2. audit-db-agreement            HARD GATE - the two masters must agree before anything renders
#   3. gen-planner-data              the Meal Plan Builder feed
#   4. build-cards -Slugs <dirty>    render only what moved
#   5. publish -Slugs <dirty>        content-hash gated, so unchanged cards cost one skipped GET
#
# Usage:  .\propagate-recipes.ps1            propagate everything dirty
#         .\propagate-recipes.ps1 -DryRun    list dirty slugs, run nothing
#         .\propagate-recipes.ps1 -Baseline  stamp the current state WITHOUT running (first arming only,
#                                            on a catalog independently verified in sync - as on 2026-08-08)
#         .\propagate-recipes.ps1 -SelfTest
# -AllowCreate passes THROUGH to engine\publish.ps1 and names the only slugs allowed to be born as live
# paid posts. It exists because `dirty` is the wrong authority for creation: propagate carries every dirty
# spec by design, which is right for republishing and dangerous for creating. On 2026-08-16 the dirty set
# was 49, of which 21 had never been published - including three recipes rejected hours earlier. Without
# this, a 9-recipe wave publish would have minted 21 live pages nobody audited.
#
# IT IS A FILE PATH, NOT AN ARRAY, ON PURPOSE. wave-publish invokes this script with `powershell -File`,
# which marshals a [string[]] into ONE comma-joined string - the same trap that made a 2-recipe wave open a
# ledger row listing a single slug. An array parameter here would silently collapse the create-authority
# list to one unmatched name and refuse every legitimate create. A newline-delimited file crosses the
# process boundary intact.
#
# -SlugsFile, -MaxUnnamed and -AllowCatalogue are the SCOPE GUARD (2026-09-19). propagate still carries the
# whole dirty set - the 2026-08-15 decision in design\PLAN-recipe-hunter-v2.1-2026-08-15.md section 4 stands,
# and nothing here scopes it - but it no longer does so SILENTLY. A dirty slug the caller did not name (in
# -SlugsFile or -AllowCreateFile, both newline files for the -File reason above) is "unnamed", and a live
# run with more than -MaxUnnamed of them is REFUSED before any stage runs, printing every one, unless the
# caller passes -AllowCatalogue. See Test-PropagateScope below for why.
# The self-test copies lib\*.ps1 into a sandbox, runs the allergen gate on a temp card against allergens.json, reads the reanchor patterns as text, and its -DryRun child reads the stamps:
# gate-inputs: lib\*.ps1, meal-prep\lib\allergen-lib.ps1, meal-prep\db\allergens.json, meal-prep\pipeline\audit-allergen-line.ps1, meal-prep\pipeline\propagate-stamps.json
# gate-inputs-text: meal-prep\pipeline\reanchor-machine-fields.ps1, meal-prep\engine\publish.ps1, grocery\check-ad-cycles.ps1
param([switch]$DryRun, [switch]$Full, [switch]$Baseline, [switch]$SelfTest, [string]$Root = "", [string]$AllowCreateFile = "",
      [string]$SlugsFile = "", [int]$MaxUnnamed = 0, [switch]$AllowCatalogue, [switch]$Drain, [int]$DrainMax = 150)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$mp   = if ($Root) { $Root } else { Split-Path -Parent $here }
$stampPath = Join-Path $here 'propagate-stamps.json'
# Test-GuardComplete, for the feed-coverage gate below. guard-contract.ps1 declares no param() block
# precisely so dot-sourcing it cannot reset this script's own -SelfTest switch (PS 5.1 runs a dot-sourced
# param block in the CALLER's scope); its own self-test pins that.
. (Join-Path (Split-Path $mp -Parent) 'lib\guard-contract.ps1')

# ---- MACHINE FIELDS ARE NOT DIRT (2026-08-20) -------------------------------------------------------
# stat.cost_ps and head.costPerServing are re-anchored by the DAILY chain (reanchor-all, Brad-approved
# unattended 2026-08-07), and the token architecture means no derived copy bakes them: {{cost_ps}}
# renders as a live-price placeholder, recipes-db does not carry the two fields at all, and the reanchor
# loop republishes any card whose bytes actually move. So a daily re-cost is fully propagated by a
# DIFFERENT, older mechanism - and hashing raw spec bytes made this stamp file count it as dirt anyway.
# Measured 2026-08-20: 465 of 574 specs "dirty", of which 458 differed ONLY in these two fields. A gate
# reading 465 when 7 need work is a gate someone learns to scroll past - the Walmart fullpull watch
# failed exactly that way the same morning.
#
# So the stamp hashes the spec with the two machine fields MASKED, using the SAME two patterns
# reanchor-machine-fields.ps1 re-anchors with (the -SelfTest pins them against that file's source, so
# the two cannot drift apart silently). Everything else - prose, ingredients, canon names, the deeper
# cost_batch/cost_first_run family that only moves on a real re-cost - still dirties the stamp, because
# nothing else re-publishes those.
#
# A BOM flip still dirties: the hash covers a has-BOM marker plus the masked text, because BOM churn is
# real content this estate has shipped bugs over, and masking must never widen beyond the two fields.
$script:MACHINE_FIELD_PATTERNS = @(
  @('("cost_ps":\s*")[^"]*(")',                 '${1}MASKED${2}'),
  @('("costPerServing":\s*)[0-9]+(?:\.[0-9]+)?', '${1}0')
)

# UNRENDERED AUTHORED FIELDS - A SEPARATE LIST, AND THE SEPARATION IS THE POINT (2026-09-07, E6).
# MACHINE_FIELD_PATTERNS above is pinned VERBATIM against reanchor-machine-fields.ps1 because those
# are the fields reanchor REWRITES every day. These are not machine-written; they are authored, and
# they simply never reach a reader. Putting them in that list made the source pin fail, correctly -
# it would have put two meanings under one name.
#
# WHY THEY ARE MASKED AT ALL. This hash decides what gets REPUBLISHED. Nothing in meal-prep\engine or
# any builder reads fact_claims or price_claims - only the two audits do - so a card whose
# declaration changed produces identical output, and republishing it spends a Ghost write on a live
# paid site for a change no reader can see.
#
# fact_claims has had this problem since E6 shipped and it has never bitten, because no spec had ever
# declared one. The day somebody began clearing the 332 undeclared claims, every card they touched
# would have republished. Found on the first real declaration: a mechanism whose cost appears the
# first time anybody actually uses it.
$script:UNRENDERED_FIELD_PATTERNS = @(
  @('("fact_claims":\s*\[)[\s\S]*?(\])',  '${1}MASKED${2}'),
  @('("price_claims":\s*\[)[\s\S]*?(\])', '${1}MASKED${2}')
)
function Get-SpecHash([string]$Path) {
  $bytes = [IO.File]::ReadAllBytes($Path)
  $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
  $text = [Text.Encoding]::UTF8.GetString($(if ($hasBom) { $bytes[3..($bytes.Length-1)] } else { $bytes }))
  foreach ($p in $script:MACHINE_FIELD_PATTERNS) { $text = [regex]::Replace($text, $p[0], $p[1]) }
  foreach ($p in $script:UNRENDERED_FIELD_PATTERNS) { $text = [regex]::Replace($text, $p[0], $p[1]) }
  $payload = [Text.Encoding]::UTF8.GetBytes($(if ($hasBom) { 'BOM:' + $text } else { $text }))
  $sha = [System.Security.Cryptography.SHA1]::Create()
  return ([BitConverter]::ToString($sha.ComputeHash($payload)) -replace '-', '')
}
function Get-DirtySlugs { param([hashtable]$Stamps, $Files)
  $d = New-Object System.Collections.Generic.List[string]
  foreach ($f in $Files) {
    $h = Get-SpecHash $f.FullName
    if (-not $Stamps.ContainsKey($f.BaseName) -or $Stamps[$f.BaseName] -ne $h) { $d.Add($f.BaseName) }
  }
  return $d
}

# ---- THE SCOPE GUARD: A CATALOGUE REPUBLISH IS A DECISION, NEVER A SIDE EFFECT (2026-09-19) -------------
# Measured at 372d8cc47: 447 of 584 specs dirty, carrying renderer and spec changes Brad has not approved
# shipping (the allergen line on every card, backlog I172, which is his step; the related-recipes footer;
# I44's paywall claim; cost bars; the "healthy" wording, two of them live titles). propagate-recipes would
# have PUT 446 live paid pages on the next run of EITHER road: a hand run after one spec edit, or the E4 of
# ANY wave, where wave-publish only printed a NOTE about the collateral and the one check between it and
# Ghost was an agent reviewing a 446-call queue. The 2026-08-15 decision (keep propagate whole-dirty) was
# about a 359-recipe carry that shipped a real, wanted fix; it never said an unrelated catalogue change
# may ride a two-recipe wave unasked.
# So: a dirty slug nobody named is counted, and a live run over more than $Max of them is refused before
# the first stage, with the list, unless the caller says -AllowCatalogue. It does NOT scope the carry: with
# consent it still carries everything dirty, so there is still one rule for what "dirty" means.
# THE BAR: -MaxUnnamed defaults to 0, the strictest value, chosen as a policy and not from a sweep - no other
# value was tried. A positive value lets that much unnamed drift ride; nothing measured says what size is safe.
# WHAT IT DOES WHEN THE PRODUCER STOPS: nothing dirty means nothing unnamed, so it is silent, as it should be.
# -SlugsFile NARROWS (2026-09-26, design\ready-for-brad\propagate-backlog-2026-09-26.md defect 1). Until then it
# only authorised: naming 63 of 70 dirty slugs was refused, and the only ways past (-MaxUnnamed 7,
# -AllowCatalogue) carried all 70, three held recipes included. With -Narrow (set by -SlugsFile, and ONLY by it)
# and no -AllowCatalogue, the run carries exactly Dirty intersected with Named; the unnamed are left dirty and
# unstamped, listed, never refused and never carried. -AllowCreateFile alone does NOT narrow, so a wave (which
# names only its own slugs through it) is still refused over foreign dirt, exactly as before.
function Test-PropagateScope {
  param($Dirty, $Named, [int]$Max = 0, [bool]$AllowCatalogue = $false, [bool]$Narrow = $false)
  $namedSet = @{}
  foreach ($n in @($Named)) { if ($n) { $namedSet[[string]$n] = $true } }
  $unnamed = @(@($Dirty) | Where-Object { $_ -and -not $namedSet.ContainsKey([string]$_) })
  $narrowed = $Narrow -and (-not $AllowCatalogue)
  $carry = if ($narrowed) { @(@($Dirty) | Where-Object { $_ -and $namedSet.ContainsKey([string]$_) }) } else { @(@($Dirty) | Where-Object { $_ }) }
  $refuse = (-not $narrowed) -and ($unnamed.Count -gt $Max) -and (-not $AllowCatalogue)
  return [pscustomobject]@{ Refuse = $refuse; Unnamed = $unnamed; Named = $namedSet.Count; Max = $Max; Consented = $AllowCatalogue; Narrowed = $narrowed; Carry = $carry }
}
function Read-SlugFile([string]$Path, [string]$Label) {
  if (-not $Path) { return @() }
  if (-not (Test-Path -LiteralPath $Path)) { throw "propagate: $Label named $Path but it does not exist - refusing, because an unreadable scope is not an empty one" }
  return @(Get-Content -LiteralPath $Path -Encoding UTF8 | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

# ---- -Drain: THE SCHEDULED DRAIN NAMES ITS OWN SCOPE, AND IT IS THE NARROW ONE (2026-10-02, triage 2026-09-30-9b9cf1) ----
# THE GAP. Nothing called this script on a schedule, so its queue drained only when a person ran it: 33 specs sat
# dirty 75.5h past the 72h health-heartbeat's QUEUE STUCK tolerates, an alarm with no repair lane. The daily chain
# (grocery\check-ad-cycles.ps1, after the re-anchor loop) now runs `-Drain`. -Drain does not add a scope rule: it
# NAMES the dirty set minus db\held-recipes.json in a per-run slug file and hands that to the existing -SlugsFile
# narrowing, so every stage and gate below runs exactly as for a hand run. A held spec is not named, so it is left
# dirty, unbuilt and unstamped (publish would refuse it anyway; leaving it out also keeps it off the build).
# It refuses -SlugsFile, -AllowCreateFile and -AllowCatalogue (it never creates a post and never widens), and it
# refuses outright over -DrainMax named specs. THE BAR: 150, the same sanity cap the chain's re-anchor republish
# uses (check-ad-cycles $CAP) for "a human should look before this many live pages are rewritten unattended";
# chosen as policy, not from a sweep; no other value was tried. The founding backlog was 33; 2026-09-19 was 447.
# WHEN THE PRODUCER STOPS: nothing dirty names nothing and the run prints 'nothing to propagate'. A held list it
# cannot parse THROWS (fails closed): an unreadable hold is not an empty one, and this run is unattended.
function Read-HeldSlugs([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return @() }
  $hd = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
  return @(@($hd.held) | Where-Object { $_ -and $_.slug } | ForEach-Object { [string]$_.slug })
}
function Get-DrainScope {
  param($Dirty, $Held, [int]$Max)
  $heldSet = @{}
  foreach ($h in @($Held)) { if ($h) { $heldSet[[string]$h] = $true } }
  $named = @(@($Dirty) | Where-Object { $_ -and -not $heldSet.ContainsKey([string]$_) })
  $kept = @(@($Dirty) | Where-Object { $_ -and $heldSet.ContainsKey([string]$_) })
  return [pscustomobject]@{ Named = $named; Held = $kept; Max = $Max; Refuse = ($named.Count -gt $Max) }
}

# ---- THE ALLERGEN LINE, CHECKED ON THE CARD THAT SHIPS (2026-09-18) ------------------------------------
# Brad's I144 ruling: no card publishes with a missing or wrong 'Contains' line. audit-allergen-line answers
# that for a BUILT card, so it has to run where the card exists and before anything sends it: here, after
# build-cards has rendered every dirty slug into db\built and before engine\publish.ps1 reads those bytes.
# It was wired into wave-publish's P5 until this date, where no card of the wave had been built yet - so it
# could never have passed a real wave, and it was only ever green because P5 could not refuse at all
# (wave-publish.ps1, above Invoke-Gate). Here it covers every slug publish is about to send: a wave's new
# recipes, the collateral dirty specs propagate carries with it, and a plain recost that never saw a wave.
#
# The publish call is a PARAMETER so the self-test can hand in a stub and prove the order on the real
# function: a refused card throws BEFORE the publish block is ever invoked, so no Ghost call can follow
# it. The throw is the refusal; it propagates out of this script before any stamp is advanced, exactly as
# a failing stage does, so the refused slugs stay dirty and are retried.
# IN-PROCESS, never `powershell -File`: -Slugs is [string[]] and the -File path passes only the first
# element (the feed-covers-published note below records the measured case).
function Invoke-GatedPublish {
  param([string[]]$Slugs, [string]$RecipesDir, [string]$BuiltDir, [scriptblock]$Publish)
  $alOut = & (Join-Path $here 'audit-allergen-line.ps1') -Slugs $Slugs -RecipesDir $RecipesDir -BuiltDir $BuiltDir
  $alRc = $LASTEXITCODE
  $alLines = @($alOut | ForEach-Object { [string]$_ })
  if ($alRc -ne 0 -or -not (Test-GuardComplete -Output $alLines -Name 'audit-allergen-line')) {
    $why = if ($alRc -ne 0) { "exited $alRc" } else { 'exited 0 without AUDIT-ALLERGEN-LINE-COMPLETE, so it did not finish' }
    throw ("propagate: allergen-line gate REFUSED before publish ({0}) - nothing was sent, stamps NOT advanced.`n{1}" -f $why, (@($alLines | Select-Object -Last 30) -join "`n"))
  }
  Write-Host ('   allergen-line gate: ' + (@($alLines | Where-Object { $_ -match '^audit-allergen-line: examined' }) -join ''))
  return (& $Publish)
}

if ($SelfTest) {
  $f = 0
  function T($m, $c, $g) { if ($c) { Write-Output ("ok    " + $m) } else { Write-Output ("FAIL  " + $m + "   got: " + $g); $script:f++ } }
  $tmp = Join-Path $env:TEMP ("propagate-selftest-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Force $tmp | Out-Null
  try {
    Set-Content (Join-Path $tmp 'a.json') '{"x":1}' -Encoding UTF8
    Set-Content (Join-Path $tmp 'b.json') '{"x":2}' -Encoding UTF8
    $files = @(Get-ChildItem "$tmp\*.json")
    $stamps = @{}
    T 'MUST FIRE  with no stamps, every spec is dirty' ((Get-DirtySlugs $stamps $files).Count -eq 2) 'missed'
    foreach ($x in $files) { $stamps[$x.BaseName] = Get-SpecHash $x.FullName }
    T 'MUST NOT FIRE stamped specs are clean' ((Get-DirtySlugs $stamps $files).Count -eq 0) 'spurious dirt'
    # ---- MACHINE-FIELD MASKING (the 465-dirty founding case, 2026-08-20) ----
    Set-Content (Join-Path $tmp 'm.json') '{"stat":{"cost_ps":"3.99"},"head":{"costPerServing":3.99},"prose":"hello"}' -Encoding UTF8
    $h1 = Get-SpecHash (Join-Path $tmp 'm.json')
    Set-Content (Join-Path $tmp 'm.json') '{"stat":{"cost_ps":"4.12"},"head":{"costPerServing":4.12},"prose":"hello"}' -Encoding UTF8
    T 'MUST FIRE  a daily re-cost of the two machine fields does NOT dirty the stamp' ($h1 -eq (Get-SpecHash (Join-Path $tmp 'm.json'))) 'hash moved'
    Set-Content (Join-Path $tmp 'm.json') '{"stat":{"cost_ps":"4.12"},"head":{"costPerServing":4.12},"prose":"edited"}' -Encoding UTF8
    T 'CLEAN TWIN a prose edit still dirties it' ($h1 -ne (Get-SpecHash (Join-Path $tmp 'm.json'))) 'prose edit invisible'
    Set-Content (Join-Path $tmp 'm2.json') '{"cost_batch":34.06,"x":1}' -Encoding UTF8
    $h2 = Get-SpecHash (Join-Path $tmp 'm2.json')
    Set-Content (Join-Path $tmp 'm2.json') '{"cost_batch":41.20,"x":1}' -Encoding UTF8
    T 'CLEAN TWIN the deeper cost_batch family is NOT masked - a real re-cost still dirties' ($h2 -ne (Get-SpecHash (Join-Path $tmp 'm2.json'))) 'cost_batch masked too'
    # A BOM flip is content. Write the same bytes with and without one.
    [IO.File]::WriteAllBytes((Join-Path $tmp 'b.json2'), [Text.Encoding]::UTF8.GetBytes('{"x":1}'))
    [IO.File]::WriteAllBytes((Join-Path $tmp 'b2.json2'), (@(0xEF,0xBB,0xBF) + [Text.Encoding]::UTF8.GetBytes('{"x":1}')))
    T 'CLEAN TWIN a BOM flip still dirties (masking never widens beyond the two fields)' ((Get-SpecHash (Join-Path $tmp 'b.json2')) -ne (Get-SpecHash (Join-Path $tmp 'b2.json2'))) 'BOM invisible'
    # THE DECLARATIONS ARE MASKED, AND A PROSE EDIT BESIDE THEM STILL IS NOT (2026-09-07, E6).
    Set-Content (Join-Path $tmp 'd1.json') '{"prose":"same","price_claims":[{"cheaper":"a","dearer":"b"}]}' -Encoding UTF8
    $hd1 = Get-SpecHash (Join-Path $tmp 'd1.json')
    Set-Content (Join-Path $tmp 'd1.json') '{"prose":"same","price_claims":[{"cheaper":"x","dearer":"y"},{"cheaper":"p","dearer":"q"}]}' -Encoding UTF8
    T 'MUST NOT FIRE  declaring a price claim does NOT dirty the spec - it never reaches a reader, and republishing for it spends a Ghost write for nothing' `
      ($hd1 -eq (Get-SpecHash (Join-Path $tmp 'd1.json'))) 'a declaration would have republished the card'
    Set-Content (Join-Path $tmp 'd2.json') '{"prose":"same","fact_claims":["a"]}' -Encoding UTF8
    $hd2 = Get-SpecHash (Join-Path $tmp 'd2.json')
    Set-Content (Join-Path $tmp 'd2.json') '{"prose":"same","fact_claims":["a","b"]}' -Encoding UTF8
    T 'MUST NOT FIRE  fact_claims is the same - it has been unmasked since E6 shipped and would have bitten the first person to clear the backlog' `
      ($hd2 -eq (Get-SpecHash (Join-Path $tmp 'd2.json'))) 'declaring a fact claim would have republished the card'
    Set-Content (Join-Path $tmp 'd3.json') '{"prose":"one","price_claims":[{"cheaper":"a","dearer":"b"}]}' -Encoding UTF8
    $hd3 = Get-SpecHash (Join-Path $tmp 'd3.json')
    Set-Content (Join-Path $tmp 'd3.json') '{"prose":"TWO","price_claims":[{"cheaper":"a","dearer":"b"}]}' -Encoding UTF8
    T 'MUST FIRE  CLEAN TWIN - a PROSE edit next to a declaration still dirties, so the mask never widens past the fields it names' `
      ($hd3 -ne (Get-SpecHash (Join-Path $tmp 'd3.json'))) 'a prose edit went invisible'
    Remove-Item (Join-Path $tmp 'd1.json'), (Join-Path $tmp 'd2.json'), (Join-Path $tmp 'd3.json') -Force -ErrorAction SilentlyContinue

    # SOURCE PIN: the mask must be the SAME two patterns reanchor-machine-fields re-anchors with. If that
    # file's patterns change, this fails until the mask follows - the drift can never be silent.
    $raSrc = [IO.File]::ReadAllText((Join-Path $here 'reanchor-machine-fields.ps1'))
    $pinOk = $true
    foreach ($p in $script:MACHINE_FIELD_PATTERNS) { if (-not $raSrc.Contains($p[0])) { $pinOk = $false } }
    T 'SOURCE PIN the masked patterns are reanchor-machine-fields'' own two, verbatim' $pinOk 'patterns drifted from reanchor-machine-fields.ps1'
    # the mask fixtures must not leak into the later whole-directory dirty tests
    Remove-Item (Join-Path $tmp 'm.json'), (Join-Path $tmp 'm2.json') -Force

    # ---- CREATE AUTHORITY. `dirty` is the wrong authority for CREATING a live post: propagate carries
    # every dirty spec by design, and on 2026-08-16 that set was 49, of which 21 had never been published
    # and would have been POSTed into existence - three of them recipes rejected hours earlier. The
    # allowlist crosses the process boundary as a FILE because wave-publish calls this script with
    # `powershell -File`, which would marshal a [string[]] into one comma-joined string.
    $allowPath = Join-Path $tmp 'allow.txt'
    Set-Content $allowPath "alpha`nbravo`n`n  charlie  " -Encoding UTF8
    $parsedAllow = @(Get-Content $allowPath | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    T 'MUST FIRE  the create allowlist survives the file round-trip as MANY slugs, not one string' `
      ($parsedAllow.Count -eq 3) $parsedAllow.Count
    T 'CLEAN TWIN blank lines are dropped and surrounding whitespace trimmed' `
      ($parsedAllow -contains 'charlie' -and $parsedAllow -notcontains '') ($parsedAllow -join '|')
    # An allowlist naming a file that is not there is a broken contract, not an empty allowlist. Treating
    # it as empty would refuse every create and read as "nothing to publish" instead of a wiring bug.
    $threw = $false
    try {
      $missing = Join-Path $tmp 'nope.txt'
      if (-not (Test-Path $missing)) { throw "propagate: -AllowCreateFile named $missing but it does not exist" }
    } catch { $threw = $true }
    T 'MUST FIRE  a named-but-missing allowlist file throws rather than silently allowing nothing' $threw 'silent'

    # ---- STAMP WITHHOLDING. publish.ps1 prints "published+verified OK" whether or not individual slugs
    # failed or were refused, so gating on that line alone stamped EVERYTHING clean - including 21 refused
    # creates, three of them recipes rejected hours earlier. One loud refusal, then propagate-clean forever.
    # The PUBLISH-UNSTAMPABLE contract line names who must not be stamped.
    function Parse-Unstampable([string[]]$Lines) {
      $l = @($Lines | Where-Object { $_ -match '^PUBLISH-UNSTAMPABLE:' } | Select-Object -First 1)
      if (-not $l.Count) { return $null }   # null means CONTRACT MISSING, which is not the same as empty
      # `,` ON THE RETURN, deliberately. `return @()` unwraps an EMPTY array to $null on the way out, which
      # would collide with the missing-contract sentinel above - a clean publish would then read as
      # "publish.ps1 never emitted the line" and throw. Same unwrap family as a one-element array losing
      # its .Count. The comma operator returns the array itself.
      return , @(([string]$l[0] -replace '^PUBLISH-UNSTAMPABLE:', '').Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }
    $u1 = Parse-Unstampable @('published+verified OK: 9 / 30', 'PUBLISH-UNSTAMPABLE: alpha,bravo')
    T 'MUST FIRE  refused and failed slugs are parsed out of the contract line' ($u1.Count -eq 2 -and $u1 -contains 'bravo') ($u1 -join '|')
    $u2 = Parse-Unstampable @('published+verified OK: 30 / 30', 'PUBLISH-UNSTAMPABLE: ')
    T 'MUST NOT FIRE a clean run yields an EMPTY list, and stamps everything' ($null -ne $u2 -and $u2.Count -eq 0) "$u2"
    # A missing contract line must be distinguishable from "nothing was refused" - otherwise an older
    # publish.ps1, or one that died before its summary, reads as a perfect run and stamps the lot.
    $u3 = Parse-Unstampable @('published+verified OK: 30 / 30')
    T 'MUST FIRE  a MISSING contract line is not read as "nothing refused"' ($null -eq $u3) "$u3"
    # And the withholding itself: a dirty slug on the list keeps its old stamp, so it stays dirty and retries.
    $dirtySet = @('alpha', 'bravo', 'charlie'); $unst = @('bravo')
    $stamped = @($dirtySet | Where-Object { $unst -notcontains $_ })
    T 'MUST FIRE  an unstampable slug is withheld while its neighbours advance' `
      ($stamped.Count -eq 2 -and $stamped -notcontains 'bravo') ($stamped -join ',')
    # ---- EVERY REFUSAL publish.ps1 KEEPS IS ON ITS UNSTAMPABLE LINE (2026-09-26, defect 2). refusedHeld and
    # refusedCarriage were missing, so a held recipe was refused and then stamped clean. The rule is read off
    # publish's OWN source: every list its tally line initialises to @() must be summed into $unstampable,
    # except $ok/$skipped (counters) and $orphaned (a card with no spec has no stamp to withhold).
    function Get-UnstampableGaps([string]$Src) {
      $init = [regex]::Match($Src, '(?m)^\$ok=0;[^\r\n]*')
      $sum = [regex]::Match($Src, '(?m)^\$unstampable = [^\r\n]*')
      if (-not $init.Success -or -not $sum.Success) { return , @('CONTRACT-UNREADABLE') }
      $lists = @([regex]::Matches($init.Value, '\$(\w+)=@\(\)') | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -ne 'orphaned' })
      return , @($lists | Where-Object { $sum.Value -notmatch ('@\(\$' + $_ + '\)') })
    }
    $initFx = '$ok=0; $skipped=0; $failed=@(); $refusedCreate=@(); $refusedCarriage=@(); $refusedHeld=@(); $orphaned=@(); $staged=@(); $rolloutHeld=@()'
    $oldSum = '$unstampable = @(@($failed) + @($refusedCreate) + @($staged) + @($rolloutHeld) | Sort-Object -Unique)'
    $newSum = '$unstampable = @(@($failed) + @($refusedCreate) + @($refusedHeld) + @($refusedCarriage) + @($staged) + @($rolloutHeld) | Sort-Object -Unique)'
    $gOld = Get-UnstampableGaps ($initFx + "`n" + $oldSum)
    T 'MUST FIRE  the pre-2026-09-26 unstampable line (no refusedHeld, no refusedCarriage) is caught, naming both' `
      ((($gOld | Sort-Object) -join ',') -eq 'refusedCarriage,refusedHeld') ($gOld -join ',')
    $gNew = Get-UnstampableGaps ($initFx + "`n" + $newSum)
    T 'MUST NOT FIRE a line summing every refusal list is clean, and $orphaned is not demanded' ($gNew.Count -eq 0) ($gNew -join ',')
    $gLive = Get-UnstampableGaps ([IO.File]::ReadAllText((Join-Path $mp 'engine\publish.ps1')))
    T 'MUST NOT FIRE the REAL engine\publish.ps1 sums every refusal list it keeps into PUBLISH-UNSTAMPABLE' ($gLive.Count -eq 0) ($gLive -join ',')
    # the founding class: an edit AFTER stamping is dirt, byte-precise
    Set-Content (Join-Path $tmp 'a.json') '{"x":1,"y":3}' -Encoding UTF8
    $d = Get-DirtySlugs $stamps @(Get-ChildItem "$tmp\*.json")
    T 'MUST FIRE  an edited spec is dirty again, and ONLY it' ($d.Count -eq 1 -and $d[0] -eq 'a') ($d -join ',')
    # a NEW spec (never stamped) is dirty - the append case cost-recipes once silently dropped
    Set-Content (Join-Path $tmp 'c.json') '{"x":9}' -Encoding UTF8
    $d2 = Get-DirtySlugs $stamps @(Get-ChildItem "$tmp\*.json")
    T 'MUST FIRE  a brand-new spec is dirty (the silent-append class)' ($d2 -contains 'c') ($d2 -join ',')

    # ---- THE ALLERGEN GATE SITS BETWEEN THE BUILT CARD AND THE PUBLISH (2026-09-18) ----------------
    # Driven through the REAL Invoke-GatedPublish and the REAL audit-allergen-line.ps1 over files in a
    # sandbox, with a STUB publish that only records that it was called - never engine\publish.ps1 and
    # never Ghost. The expected line comes from the live table through the one Format-TcAllergenLine, the
    # way build-card2 renders it, over two ingredients audit-allergen-line's own self-test pins in that
    # table (Worcestershire: fish, Oyster Sauce: shellfish).
    . (Join-Path $mp 'lib\allergen-lib.ps1')
    $alRec = Join-Path $tmp 'al-recipes'; $alBuilt = Join-Path $tmp 'al-built'
    New-Item -ItemType Directory -Force $alRec, $alBuilt | Out-Null
    $alSlug = 'al-drill-slug'
    Set-Content -LiteralPath (Join-Path $alRec ($alSlug + '.json')) -Encoding UTF8 -Value `
      '{"slug":"al-drill-slug","scaler":{"ing":[{"item":"Worcestershire Sauce","grams":30},{"item":"Oyster Sauce","grams":40}]}}'
    $alTable = (Get-TcAllergenTable -Path (Join-Path $mp 'db\allergens.json')).Items
    $alSpecIng = @([pscustomobject]@{ item = 'Worcestershire Sauce'; grams = 30 }, [pscustomobject]@{ item = 'Oyster Sauce'; grams = 40 })
    $alRight = Format-TcAllergenLine (Get-TcRecipeAllergens $alSpecIng $alTable) $alSlug
    # the stale line: rendered before the Worcestershire was added, so it omits the fish
    $alStale = Format-TcAllergenLine (Get-TcRecipeAllergens @($alSpecIng | Where-Object { $_.item -ne 'Worcestershire Sauce' }) $alTable) $alSlug
    $alCard = Join-Path $alBuilt ($alSlug + '.body.html')
    $script:alPublished = 0
    $alStub = { $script:alPublished++; 'published+verified OK: 1 / 1'; 'PUBLISH-UNSTAMPABLE: ' }
    # UNTYPED on purpose: a [string] parameter turns $null into '' and the no-card case would write an empty
    # card and test 'missing' instead (it did, on the first run of these cases).
    function AlRun($CardHtml) {
      if ($null -eq $CardHtml) { Remove-Item -LiteralPath $alCard -Force -ErrorAction SilentlyContinue }
      else { Set-Content -LiteralPath $alCard -Encoding UTF8 -Value $CardHtml }
      $script:alPublished = 0
      $threw = ''; $out = $null
      try { $out = Invoke-GatedPublish -Slugs @($alSlug) -RecipesDir $alRec -BuiltDir $alBuilt -Publish $alStub } catch { $threw = $_.Exception.Message }
      return [pscustomobject]@{ Threw = $threw; Out = @($out); Published = $script:alPublished }
    }
    $r = AlRun ('<ul class="smp-ing"><li>x</li></ul><!--TC-PAYWALL-->')
    T 'MUST FIRE  a built card with NO allergen line is refused BEFORE publish, and publish is never called' `
      ($r.Threw -match 'allergen-line gate REFUSED before publish' -and $r.Threw -match 'missing' -and $r.Published -eq 0) ("threw='" + $r.Threw.Split("`n")[0] + "' published=" + $r.Published)
    $r = AlRun ('<ul class="smp-ing"><li>x</li></ul>' + $alStale + '<!--TC-PAYWALL-->')
    T 'MUST FIRE  a built card whose line is WRONG (stale, omits the anchovy) is refused before publish' `
      ($r.Threw -match 'REFUSED before publish' -and $r.Threw -match 'disagrees' -and $r.Published -eq 0) ("threw='" + $r.Threw.Split("`n")[0] + "' published=" + $r.Published)
    $r = AlRun $null
    T 'MUST FIRE  a dirty slug with NO built card is refused before publish, never skipped' `
      ($r.Threw -match 'REFUSED before publish' -and $r.Threw -match 'no-card' -and $r.Published -eq 0) ("threw='" + $r.Threw.Split("`n")[0] + "' published=" + $r.Published)
    $r = AlRun ('<ul class="smp-ing"><li>x</li></ul>' + $alRight + '<!--TC-PAYWALL-->')
    T 'CLEAN TWIN a card carrying exactly its derived line passes the gate and REACHES the (stub) publish, whose output comes back' `
      ($r.Threw -eq '' -and $r.Published -eq 1 -and (@($r.Out) -join '|') -match 'published\+verified OK') ("threw='" + $r.Threw + "' published=" + $r.Published + " out=" + (@($r.Out) -join '|'))

    # ORDER, on the live path: publish.ps1 is reached ONLY through Invoke-GatedPublish, and that call comes
    # after build-cards. Needles by concatenation so this block cannot match itself.
    $pSrc = [IO.File]::ReadAllText($PSCommandPath)
    $pubCall = "& '.\engine\" + "publish.ps1'"
    $iB = $pSrc.IndexOf("& '.\engine\build-" + "cards.ps1' -Slugs `$dirty")
    $iG = $pSrc.IndexOf('$pubOut = Invoke-Gated' + 'Publish')
    $iP = $pSrc.IndexOf($pubCall)
    T 'MUST FIRE  the live publish runs only inside the gated call, after build-cards' `
      (($iB -ge 0) -and ($iG -gt $iB) -and ($iP -gt $iG) -and ([regex]::Matches($pSrc, [regex]::Escape($pubCall)).Count -eq 1)) `
      ("build@{0} gated@{1} publish@{2} publishCalls={3}" -f $iB, $iG, $iP, [regex]::Matches($pSrc, [regex]::Escape($pubCall)).Count)

    # ---- THE SCOPE GUARD (2026-09-19). The founding case: a two-recipe wave whose E4 would have carried
    # 445 unnamed dirty specs to live pages. Scaled down to 2 named and 3 unnamed; the rule is the same.
    $wave = @('wave-one', 'wave-two'); $foreign = @('other-a', 'other-b', 'other-c')
    $sc = Test-PropagateScope -Dirty ($wave + $foreign) -Named $wave -Max 0 -AllowCatalogue $false
    T 'MUST FIRE  a run whose dirty set exceeds the slugs its caller named is REFUSED, and the refusal lists exactly the unnamed ones' `
      ($sc.Refuse -and $sc.Unnamed.Count -eq 3 -and (($sc.Unnamed | Sort-Object) -join ',') -eq 'other-a,other-b,other-c') ("refuse=" + $sc.Refuse + " unnamed=" + ($sc.Unnamed -join ','))
    $sc = Test-PropagateScope -Dirty $wave -Named $wave -Max 0 -AllowCatalogue $false
    T 'CLEAN TWIN a wave naming its own slugs is NOT refused, and what it carries is exactly those slugs' `
      ((-not $sc.Refuse) -and $sc.Unnamed.Count -eq 0 -and $sc.Named -eq 2) ("refuse=" + $sc.Refuse + " unnamed=" + ($sc.Unnamed -join ','))
    $sc = Test-PropagateScope -Dirty @('wave-one') -Named $wave -Max 0 -AllowCatalogue $false
    T 'MUST NOT FIRE a named slug that is not dirty is no reason to refuse (a resume where one slug already shipped)' ((-not $sc.Refuse) -and $sc.Unnamed.Count -eq 0) ("refuse=" + $sc.Refuse)
    $sc = Test-PropagateScope -Dirty ($wave + @('other-a', 'other-b')) -Named $wave -Max 2 -AllowCatalogue $false
    T 'MUST NOT FIRE AT the bar: 2 unnamed with -MaxUnnamed 2 is allowed' ((-not $sc.Refuse) -and $sc.Unnamed.Count -eq 2) ("refuse=" + $sc.Refuse + " unnamed=" + $sc.Unnamed.Count)
    $sc = Test-PropagateScope -Dirty ($wave + $foreign) -Named $wave -Max 2 -AllowCatalogue $false
    T 'MUST FIRE  one step PAST the bar: 3 unnamed with -MaxUnnamed 2 is refused' ($sc.Refuse -and $sc.Unnamed.Count -eq 3) ("refuse=" + $sc.Refuse + " unnamed=" + $sc.Unnamed.Count)
    $sc = Test-PropagateScope -Dirty ($wave + $foreign) -Named $wave -Max 0 -AllowCatalogue $true
    T 'CLEAN TWIN -AllowCatalogue carries the unnamed slugs, and still counts them so the run can say so' ((-not $sc.Refuse) -and $sc.Unnamed.Count -eq 3) ("refuse=" + $sc.Refuse + " unnamed=" + $sc.Unnamed.Count)
    $sc = Test-PropagateScope -Dirty @() -Named @() -Max 0 -AllowCatalogue $false
    T 'MUST NOT FIRE nothing dirty is nothing unnamed' ((-not $sc.Refuse) -and $sc.Unnamed.Count -eq 0) ("refuse=" + $sc.Refuse + " unnamed=" + $sc.Unnamed.Count)
    # ---- -SlugsFile NARROWS (2026-09-26, defect 1). The founding case: 70 dirty, 63 named, 7 not - the run must
    # carry exactly the 63 and leave the 7 dirty, never refuse and never carry them. Scaled to 2 named of 5.
    $sc = Test-PropagateScope -Dirty ($wave + $foreign) -Named $wave -Max 0 -AllowCatalogue $false -Narrow $true
    T 'MUST FIRE  a -SlugsFile run NARROWS: it carries exactly the named dirty slugs, is not refused, and lists the unnamed as left dirty' `
      ((-not $sc.Refuse) -and $sc.Narrowed -and ((@($sc.Carry) | Sort-Object) -join ',') -eq 'wave-one,wave-two' -and $sc.Unnamed.Count -eq 3) ("refuse=" + $sc.Refuse + " carry=" + (@($sc.Carry) -join ',') + " unnamed=" + $sc.Unnamed.Count)
    $sc = Test-PropagateScope -Dirty @('wave-one', 'other-a') -Named ($wave + @('clean-x')) -Max 0 -AllowCatalogue $false -Narrow $true
    T 'MUST NOT FIRE a named slug that is NOT dirty is never carried (narrowing is an intersection, not the named list)' `
      ((@($sc.Carry) -join ',') -eq 'wave-one') ("carry=" + (@($sc.Carry) -join ','))
    $sc = Test-PropagateScope -Dirty ($wave + $foreign) -Named $wave -Max 0 -AllowCatalogue $true -Narrow $true
    T 'CLEAN TWIN -AllowCatalogue with -SlugsFile still carries the whole dirty set (consent is not narrowed)' `
      ((-not $sc.Narrowed) -and @($sc.Carry).Count -eq 5) ("narrowed=" + $sc.Narrowed + " carry=" + @($sc.Carry).Count)
    $sc = Test-PropagateScope -Dirty ($wave + $foreign) -Named $wave -Max 0 -AllowCatalogue $false -Narrow $false
    T 'CLEAN TWIN names from -AllowCreateFile alone (the wave road) do NOT narrow: foreign dirt is still REFUSED' `
      ($sc.Refuse -and (-not $sc.Narrowed)) ("refuse=" + $sc.Refuse + " narrowed=" + $sc.Narrowed)
    $threw = $false
    try { $null = Read-SlugFile (Join-Path $tmp 'no-such-scope.txt') '-SlugsFile' } catch { $threw = $true }
    T 'MUST FIRE  a -SlugsFile that is not there throws rather than naming nothing' $threw 'silent'

    # THE WIRING, END TO END ACROSS THE -File BOUNDARY, through -DryRun only (it exits before every stage, so
    # this child can never sync, render or send anything whatever the guard does). -Root points the specs at a
    # sandbox with no stamps, so all three are dirty; the sandbox carries the whole lib\ this script loads.
    $sbx = Join-Path $tmp 'scope-sbx'; $sbxMp = Join-Path $sbx 'mp'
    New-Item -ItemType Directory -Force (Join-Path $sbxMp 'db\recipes'), (Join-Path $sbx 'lib') | Out-Null
    Copy-Item (Join-Path (Split-Path $mp -Parent) 'lib\*.ps1') (Join-Path $sbx 'lib')
    foreach ($s in @('wave-one', 'wave-two', 'other-a')) { Set-Content (Join-Path $sbxMp ("db\recipes\{0}.json" -f $s)) ('{"slug":"' + $s + '"}') -Encoding UTF8 }
    $scopeFile = Join-Path $tmp 'scope.txt'
    Set-Content $scopeFile "wave-one`nwave-two" -Encoding UTF8
    $dr = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Root $sbxMp -DryRun -SlugsFile $scopeFile)
    $drLine = @($dr | Where-Object { $_ -match '^propagate scope:' }) -join ''
    $drList = @($dr | Where-Object { $_ -match '^  \S' -and $_ -notmatch 'left dirty' } | ForEach-Object { $_.Trim() })
    T 'MUST FIRE  through the real -File call, a two-slug -SlugsFile NARROWS to TWO slugs and names the third as left dirty' `
      ($drLine -match '^propagate scope: NARROWED by -SlugsFile - carrying 2 of 3 dirty' -and (($drList | Sort-Object) -join ',') -eq 'wave-one,wave-two' -and (@($dr) -join '|') -match 'left dirty \(not named\): other-a') ("line='" + $drLine + "' list=" + ($drList -join ',') + " rc=" + $LASTEXITCODE)
    $allowOnly = Join-Path $tmp 'allow-only.txt'
    Set-Content $allowOnly "wave-one`nwave-two" -Encoding UTF8
    $dr2 = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Root $sbxMp -DryRun -AllowCreateFile $allowOnly)
    $drLine2 = @($dr2 | Where-Object { $_ -match '^propagate scope:' }) -join ''
    T 'CLEAN TWIN through the real -File call, -AllowCreateFile alone still reports the third dirty spec as refusable' `
      ($drLine2 -match '^propagate scope: 1 of 3 dirty' -and $drLine2 -match 'REFUSES without -AllowCatalogue') ("line='" + $drLine2 + "' rc=" + $LASTEXITCODE)
    # THE ORDER, on the live path: the refusal exits before the first stage runs. Needles by concatenation.
    # The needle is the whole refusal BLOCK up to its exit, not the condition: the scope line above it spells
    # the same condition inside a subexpression, and the first version of this pin matched that and SURVIVED
    # the mutant that turned the real refusal off.
    $mScope = [regex]::Match($pSrc, '(?m)^if \(\$scope\.Refuse\) \{\s*\r?\n\s*Write-Output \("PROPAGATE-SCOPE-' + 'REFUSED[^\r\n]*[\s\S]*?\r?\n\s*exit 2\s*\r?\n\}')
    $iScope = if ($mScope.Success) { $mScope.Index } else { -1 }
    $iStage = $pSrc.IndexOf("Invoke-Stage 'sync-" + "recipesdb-buy'")
    $iCalc = $pSrc.IndexOf('$scope = Test-Propagate' + 'Scope')
    T 'MUST FIRE  the live scope check is computed from Test-PropagateScope and refuses BEFORE the first stage' `
      (($iCalc -ge 0) -and ($iScope -gt $iCalc) -and ($iStage -gt $iScope)) ("calc@{0} refuse@{1} firstStage@{2}" -f $iCalc, $iScope, $iStage)

    # ---- -Drain, THE SCHEDULED DRAIN (2026-10-02, triage 2026-09-30-9b9cf1). Founding row: 33 specs dirty 75.5h
    # with no caller; 7 of them were in db\held-recipes.json, so the drain must name 26 and leave those 7. ----
    $ds = Get-DrainScope -Dirty @('stuck-a', 'stuck-b', 'held-h') -Held @('held-h', 'held-not-dirty') -Max 150
    T 'MUST FIRE  -Drain names every dirty spec past tolerance that is not held (the stuck queue is drained)' `
      (((@($ds.Named) | Sort-Object) -join ',') -eq 'stuck-a,stuck-b' -and (-not $ds.Refuse)) ("named=" + (@($ds.Named) -join ',') + " refuse=" + $ds.Refuse)
    T 'CLEAN TWIN a HELD dirty spec stays put: not named, reported as held, and a held spec that is not dirty is not invented' `
      ((@($ds.Held) -join ',') -eq 'held-h' -and (@($ds.Named) -notcontains 'held-h')) ("held=" + (@($ds.Held) -join ','))
    $ds = Get-DrainScope -Dirty @() -Held @('held-h') -Max 150
    T 'MUST NOT FIRE an empty dirty set names nothing and is not refused' ((@($ds.Named).Count -eq 0) -and (-not $ds.Refuse)) ("named=" + @($ds.Named).Count)
    $ds = Get-DrainScope -Dirty @('a', 'b') -Held @() -Max 2
    T 'MUST NOT FIRE exactly AT the -DrainMax bar (2 named, bar 2) the drain runs' (-not $ds.Refuse) 'refused at the bar'
    $ds = Get-DrainScope -Dirty @('a', 'b', 'c') -Held @() -Max 2
    T 'MUST FIRE  one step PAST the -DrainMax bar (3 named, bar 2) the drain is refused' $ds.Refuse 'ran past the bar'
    Set-Content (Join-Path $sbxMp 'db\held-recipes.json') '{"held":[{"slug":"other-a","reason":"selftest hold"}]}' -Encoding UTF8
    $dd = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Root $sbxMp -DryRun -Drain)
    $ddRc = $LASTEXITCODE
    $ddLine = @($dd | Where-Object { $_ -match '^propagate scope:' }) -join ''
    $ddList = @($dd | Where-Object { $_ -match '^  \S' -and $_ -notmatch 'left dirty|held, not drained' } | ForEach-Object { $_.Trim() })
    T 'MUST FIRE  through the real -File call, -Drain NARROWS to the two unheld dirty specs and leaves the held one dirty' `
      ($ddRc -eq 0 -and $ddLine -match '^propagate scope: NARROWED by -SlugsFile - carrying 2 of 3 dirty' -and (($ddList | Sort-Object) -join ',') -eq 'wave-one,wave-two' -and (@($dd) -join '|') -match 'held, not drained: other-a') ("line='" + $ddLine + "' list=" + ($ddList -join ',') + " rc=" + $ddRc)
    $dx = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Root $sbxMp -Drain -SlugsFile $scopeFile)
    $dxRc = $LASTEXITCODE
    T 'MUST FIRE  -Drain with a caller scope is refused before any stage (it never widens or merges scopes)' `
      ($dxRc -eq 2 -and (@($dx) -join '|') -match ('PROPAGATE-DRAIN-' + 'REFUSED') -and (@($dx) -join '|') -notmatch '^-- |\|-- ') ("rc=" + $dxRc)
    Set-Content (Join-Path $sbxMp 'db\held-recipes.json') '{"held":[' -Encoding UTF8
    $eapWas = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $dz = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Root $sbxMp -DryRun -Drain 2>$null); $dzRc = $LASTEXITCODE }
    finally { $ErrorActionPreference = $eapWas }
    T 'MUST FIRE  an unparseable held list makes -Drain fail closed (non-zero, nothing listed)' `
      ($dzRc -ne 0 -and (@($dz) -join '|') -notmatch 'propagate scope:') ("rc=" + $dzRc)
    # THE CALLER EXISTS: the daily chain runs -Drain. Red on a revert of the chain step. Needle by concatenation.
    $chainSrc = Get-Content (Join-Path (Split-Path $mp -Parent) 'grocery\check-ad-cycles.ps1') -Raw -Encoding UTF8
    T 'MUST FIRE  grocery\check-ad-cycles.ps1 calls propagate-recipes.ps1 -Drain (the queue has an automated caller)' `
      ($chainSrc -match ("propagate-recipes\.ps1'\)\s+-" + 'Drain')) 'no -Drain call in the daily chain'
  } finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
  if ($f -eq 0) { Write-Output 'SELF-TEST PASS'; exit 0 } else { Write-Output "SELF-TEST FAIL: $f case(s)"; exit 1 }
}

# ---- live -----------------------------------------------------------------------------------------------
$files = @(Get-ChildItem (Join-Path $mp 'db\recipes\*.json'))
$stamps = @{}
if (Test-Path $stampPath) {
  $o = Get-Content $stampPath -Raw -Encoding UTF8 | ConvertFrom-Json
  foreach ($p in $o.PSObject.Properties) { $stamps[$p.Name] = [string]$p.Value }
}

if ($Baseline) {
  foreach ($x in $files) { $stamps[$x.BaseName] = Get-SpecHash $x.FullName }
  ($stamps | ConvertTo-Json -Depth 3) | Out-File $stampPath -Encoding utf8
  Write-Output ("propagate baseline stamped for {0} spec(s) - use this ONLY on a catalog independently verified in sync" -f $files.Count)
  exit 0
}

$dirty = @(Get-DirtySlugs $stamps $files)
Write-Output ("propagate: {0} dirty spec(s) of {1}" -f $dirty.Count, $files.Count)
if ($Drain) {
  if ($SlugsFile -or $AllowCreateFile -or $AllowCatalogue) {
    Write-Output 'PROPAGATE-DRAIN-REFUSED: -Drain names its own scope and takes no -SlugsFile, -AllowCreateFile or -AllowCatalogue. Nothing ran and no stamp moved.'
    exit 2
  }
  $heldNow = Read-HeldSlugs (Join-Path $mp 'db\held-recipes.json')
  $ds = Get-DrainScope -Dirty $dirty -Held $heldNow -Max $DrainMax
  $ds.Held | ForEach-Object { Write-Output ('  held, not drained: ' + $_) }
  if ($ds.Refuse) {
    Write-Output ("PROPAGATE-DRAIN-REFUSED: {0} dirty spec(s) to drain, over the unattended bar of {1}. Nothing ran and no stamp moved; review them, then run with -SlugsFile." -f $ds.Named.Count, $ds.Max)
    exit 2
  }
  $SlugsFile = Join-Path $env:TEMP ('propagate-drain-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.txt')
  [IO.File]::WriteAllText($SlugsFile, ((@($ds.Named) -join "`n") + "`n"), (New-Object Text.UTF8Encoding($false)))
  Write-Output ("propagate drain: naming {0} dirty spec(s), {1} held left dirty, in {2}" -f $ds.Named.Count, $ds.Held.Count, $SlugsFile)
}
$scopeA = Read-SlugFile $SlugsFile '-SlugsFile'; $scopeB = Read-SlugFile $AllowCreateFile '-AllowCreateFile'
$scopeNamed = @(@($scopeA) + @($scopeB) | Where-Object { $_ })
$scope = Test-PropagateScope -Dirty $dirty -Named $scopeNamed -Max $MaxUnnamed -AllowCatalogue ([bool]$AllowCatalogue) -Narrow ([bool]$SlugsFile)
if ($scope.Narrowed) {
  Write-Output ("propagate scope: NARROWED by -SlugsFile - carrying {0} of {1} dirty spec(s); {2} unnamed left dirty and unstamped" -f $scope.Carry.Count, $dirty.Count, $scope.Unnamed.Count)
  $scope.Unnamed | ForEach-Object { Write-Output ('  left dirty (not named): ' + $_) }
}
else {
  Write-Output ("propagate scope: {0} of {1} dirty spec(s) were not named by the caller (bar {2}){3}" -f $scope.Unnamed.Count, $dirty.Count, $MaxUnnamed, $(if ($scope.Refuse) { ' - a live run REFUSES without -AllowCatalogue' } elseif ($AllowCatalogue -and $scope.Unnamed.Count) { ' - carried on -AllowCatalogue' } else { '' }))
}
# FROM HERE ON $dirty IS WHAT THIS RUN CARRIES: every stage, the publish and the stamp loop read it, so a
# narrowed run can neither build, send nor stamp a slug its caller did not name.
$dirty = @($scope.Carry)
# -DryRun's WHOLE JOB is to answer "what would this publish?", and it capped the list at 30 with no
# remainder line - so a 91-slug set printed 30 names ending at 'h' and looked complete. The count on the
# line above is right, but a reader checking the list against it has to notice a number they were not
# shown. -Full prints every one; the default keeps the short list and now NAMES what it withheld.
if ($DryRun) {
  $show = if ($Full) { $dirty.Count } else { 30 }
  $dirty | Select-Object -First $show | ForEach-Object { Write-Output ("  " + $_) }
  if ($dirty.Count -gt $show) { Write-Output ("  ... and {0} more not listed - re-run with -Full" -f ($dirty.Count - $show)) }
  exit 0
}
if (-not $dirty.Count) { Write-Output 'nothing to propagate'; exit 0 }
# THE SCOPE GUARD, before the first stage: nothing has been synced, rendered, sent or stamped when it refuses.
if ($scope.Refuse) {
  Write-Output ("PROPAGATE-SCOPE-REFUSED: {0} dirty spec(s) the caller did not name would be REPUBLISHED to live pages, over the bar of {1}. Nothing ran and no stamp moved." -f $scope.Unnamed.Count, $MaxUnnamed)
  Write-Output '  Name them in -SlugsFile, or pass -AllowCatalogue if republishing all of them is the decision. The unnamed slugs:'
  $scope.Unnamed | ForEach-Object { Write-Output ('    ' + $_) }
  exit 2
}

# each stage runs as a child so its exit code is its verdict; a failure stops the chain BEFORE the stamp.
function Invoke-Stage { param([string]$Label, [scriptblock]$Run)
  Write-Output ("-- " + $Label)
  & $Run
  if ($LASTEXITCODE -ne 0) { throw ("propagate: stage '{0}' failed (rc={1}) - stamps NOT advanced, the next run retries" -f $Label, $LASTEXITCODE) }
}

Invoke-Stage 'sync-recipesdb-buy' { & powershell -ExecutionPolicy Bypass -File (Join-Path $here 'sync-recipesdb-buy.ps1') -Apply | Select-Object -Last 1 }
Invoke-Stage 'audit-db-agreement (hard gate)' { & powershell -ExecutionPolicy Bypass -File (Join-Path $mp 'engine\audit-db-agreement.ps1') | Select-Object -Last 1 }
# BEFORE ANY CARD RENDERS, because the cost line pluralises a package label in front of a paying
# reader: "Buy {n} {label}s". Wired here on 2026-08-29 and not only into wave-publish, because the
# seven pages that shipped "Buy 2 8ozes", "Buy 4 8 bunses" and "Buy 2 Great Value 12 ozes" did NOT
# come through a wave - they came through this chain, on a plain recost of already-live recipes. A
# gate that only guards new waves would have watched every one of them go out.
Invoke-Stage 'audit-buy-label-plurals (hard gate)' { & powershell -ExecutionPolicy Bypass -File (Join-Path $here 'audit-buy-label-plurals.ps1') | Select-Object -Last 1 }
Invoke-Stage 'gen-planner-data' { & powershell -ExecutionPolicy Bypass -File (Join-Path $mp 'gen-planner-data.ps1') | Select-Object -Last 1 }
# -Slugs IN-PROCESS for build/publish (engine\README: `powershell -File` marshals an array as one string)
Write-Output '-- build-cards (dirty slugs)'
Push-Location $mp
try {
  & '.\engine\build-cards.ps1' -Slugs $dirty | Select-Object -Last 1
  if ($LASTEXITCODE -ne 0 -and $null -ne $LASTEXITCODE) { throw 'propagate: build-cards failed - stamps NOT advanced' }
} finally { Pop-Location }

# HARD GATE, BEFORE PUBLISH. Every card fetches its live prices from smp-feed at view time, so a recipe can
# publish perfectly and still render an empty cost section to the reader - which is exactly what happened on
# 2026-08-15, and was found at post-publish review rather than here. This asks the only question that
# matters to a reader (can the feed this card fetches actually price this recipe?) while the answer is still
# free to act on. It runs on the ALREADY-BUILT cards, so it reads the exact bid list the browser will.
Invoke-Stage 'feed-covers-published (hard gate)' {
  # IN-PROCESS, NEVER `powershell -File`. -Slugs is [string[]] and the -File path passes only the FIRST
  # element (measured 2026-08-15), so this hard gate was checking ONE dirty slug and reporting the whole
  # set clean - a 517-spec propagate verified one recipe. The gate built to stop the 2026-08-15 empty-cost
  # failure was itself blind for the same structural reason the estate has now paid for five times.
  $fcOut = & (Join-Path $here 'feed-covers-published.ps1') -Slugs $dirty
  $fcRc = $LASTEXITCODE
  $fcOut | ForEach-Object { Write-Output $_ }
  # COMPLETION AND VERDICT ARE DIFFERENT QUESTIONS (lib\guard-contract.ps1). A guard that died mid-run
  # exits non-zero with no marker and must not be read as "found nothing"; one that finished and found
  # nothing exits 0 WITH the marker.
  if (-not (Test-GuardComplete -Output $fcOut -Name 'FEEDCOV')) { $global:LASTEXITCODE = 2; return }
  $global:LASTEXITCODE = $fcRc
}

Push-Location $mp
try {
  Write-Output '-- publish (dirty slugs; hash-gated)'
  $allowCreate = @()
  if ($AllowCreateFile) {
    if (-not (Test-Path $AllowCreateFile)) { throw "propagate: -AllowCreateFile named $AllowCreateFile but it does not exist - refusing to publish with unknown create authority" }
    $allowCreate = @(Get-Content $AllowCreateFile | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    Write-Output ("   create authority: {0} slug(s) may be created; any other new slug is refused" -f $allowCreate.Count)
  }
  else { Write-Output '   create authority: NONE - every slug with no live post will be refused' }
  # In-process call operator, so the array reaches publish.ps1 as an array. Through Invoke-GatedPublish,
  # which refuses (throws) before this block runs if any dirty slug's built card lacks its allergen line.
  $pubOut = Invoke-GatedPublish -Slugs $dirty -RecipesDir (Join-Path $mp 'db\recipes') -BuiltDir (Join-Path $mp 'db\built') `
    -Publish { & '.\engine\publish.ps1' -Slugs $dirty -AllowCreate $allowCreate }
  $pubOut | Select-Object -Last 2
  if (@($pubOut | Where-Object { $_ -match 'published\+verified OK' }).Count -eq 0) { throw 'propagate: publish did not report its verified-OK line - stamps NOT advanced' }
  # A STAMP IS A CLAIM THAT THE SPEC IS LIVE AS WRITTEN. publish.ps1 prints its verified-OK line whether or
  # not individual slugs failed or were refused, so gating on that line alone stamped everything clean -
  # including 21 refused creates, three of them rejected recipes. They would have been propagate-clean
  # forever after one loud refusal. Its PUBLISH-UNSTAMPABLE line names exactly who must not be stamped.
  $unstampLine = @($pubOut | Where-Object { $_ -match '^PUBLISH-UNSTAMPABLE:' } | Select-Object -First 1)
  if (-not $unstampLine.Count) { throw 'propagate: publish did not emit its PUBLISH-UNSTAMPABLE line - refusing to stamp, because a missing contract line is indistinguishable from "nothing was refused"' }
  $script:unstampable = @(([string]$unstampLine[0] -replace '^PUBLISH-UNSTAMPABLE:', '').Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
} finally { Pop-Location }

# stamps advance ONLY here, after every stage above succeeded - and never for a slug publish did not land.
$withheld = @()
foreach ($x in $files) {
  if ($dirty -notcontains $x.BaseName) { continue }
  if ($script:unstampable -contains $x.BaseName) { $withheld += $x.BaseName; continue }
  $stamps[$x.BaseName] = Get-SpecHash $x.FullName
}
($stamps | ConvertTo-Json -Depth 3) | Out-File $stampPath -Encoding utf8
if ($withheld.Count) {
  Write-Output ("propagate: STAMPS WITHHELD from {0} spec(s) that did not publish - they stay dirty and will be retried: {1}" -f $withheld.Count, ($withheld -join ', '))
}
Write-Output ("propagate COMPLETE: {0} spec(s) carried through recipes-db, planner, cards and publish; {1} stamp(s) advanced" -f $dirty.Count, ($dirty.Count - $withheld.Count))
exit 0
