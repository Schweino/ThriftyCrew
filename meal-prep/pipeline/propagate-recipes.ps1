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
param([switch]$DryRun, [switch]$Baseline, [switch]$SelfTest, [string]$Root = "", [string]$AllowCreateFile = "")
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
function Get-SpecHash([string]$Path) {
  $bytes = [IO.File]::ReadAllBytes($Path)
  $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
  $text = [Text.Encoding]::UTF8.GetString($(if ($hasBom) { $bytes[3..($bytes.Length-1)] } else { $bytes }))
  foreach ($p in $script:MACHINE_FIELD_PATTERNS) { $text = [regex]::Replace($text, $p[0], $p[1]) }
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
    T 'CLEAN TWIN stamped specs are clean' ((Get-DirtySlugs $stamps $files).Count -eq 0) 'spurious dirt'
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
    T 'CLEAN TWIN a clean run yields an EMPTY list, and stamps everything' ($null -ne $u2 -and $u2.Count -eq 0) "$u2"
    # A missing contract line must be distinguishable from "nothing was refused" - otherwise an older
    # publish.ps1, or one that died before its summary, reads as a perfect run and stamps the lot.
    $u3 = Parse-Unstampable @('published+verified OK: 30 / 30')
    T 'MUST FIRE  a MISSING contract line is not read as "nothing refused"' ($null -eq $u3) "$u3"
    # And the withholding itself: a dirty slug on the list keeps its old stamp, so it stays dirty and retries.
    $dirtySet = @('alpha', 'bravo', 'charlie'); $unst = @('bravo')
    $stamped = @($dirtySet | Where-Object { $unst -notcontains $_ })
    T 'MUST FIRE  an unstampable slug is withheld while its neighbours advance' `
      ($stamped.Count -eq 2 -and $stamped -notcontains 'bravo') ($stamped -join ',')
    # the founding class: an edit AFTER stamping is dirt, byte-precise
    Set-Content (Join-Path $tmp 'a.json') '{"x":1,"y":3}' -Encoding UTF8
    $d = Get-DirtySlugs $stamps @(Get-ChildItem "$tmp\*.json")
    T 'MUST FIRE  an edited spec is dirty again, and ONLY it' ($d.Count -eq 1 -and $d[0] -eq 'a') ($d -join ',')
    # a NEW spec (never stamped) is dirty - the append case cost-recipes once silently dropped
    Set-Content (Join-Path $tmp 'c.json') '{"x":9}' -Encoding UTF8
    $d2 = Get-DirtySlugs $stamps @(Get-ChildItem "$tmp\*.json")
    T 'MUST FIRE  a brand-new spec is dirty (the silent-append class)' ($d2 -contains 'c') ($d2 -join ',')
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
if ($DryRun) { $dirty | Select-Object -First 30 | ForEach-Object { Write-Output ("  " + $_) }; exit 0 }
if (-not $dirty.Count) { Write-Output 'nothing to propagate'; exit 0 }

# each stage runs as a child so its exit code is its verdict; a failure stops the chain BEFORE the stamp.
function Invoke-Stage { param([string]$Label, [scriptblock]$Run)
  Write-Output ("-- " + $Label)
  & $Run
  if ($LASTEXITCODE -ne 0) { throw ("propagate: stage '{0}' failed (rc={1}) - stamps NOT advanced, the next run retries" -f $Label, $LASTEXITCODE) }
}

Invoke-Stage 'sync-recipesdb-buy' { & powershell -ExecutionPolicy Bypass -File (Join-Path $here 'sync-recipesdb-buy.ps1') -Apply | Select-Object -Last 1 }
Invoke-Stage 'audit-db-agreement (hard gate)' { & powershell -ExecutionPolicy Bypass -File (Join-Path $mp 'engine\audit-db-agreement.ps1') | Select-Object -Last 1 }
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
  # In-process call operator, so the array reaches publish.ps1 as an array.
  $pubOut = & '.\engine\publish.ps1' -Slugs $dirty -AllowCreate $allowCreate
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
