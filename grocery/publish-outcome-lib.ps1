<#
  publish-outcome-lib.ps1 - what check-ad-cycles does with publish-deals-page's answer, on both roads.
  Dot-sourced by check-ad-cycles.ps1 just before its ship branch. Moved out of that file on 2026-09-28
  (design/PLAN-deferpost-builds-board-2026-09-28.md W1) because the deferred road grew a build, and
  check-ad-cycles is held at its line mark by ops\audit-file-size-budget.ps1.

  Get-PublishHeldGate    which of publish-deals-page's rc-2 gates held it (fixtured in test-auditors units-03, u060)
  Invoke-DeferPostBuild  the -DeferPost road: build the board, then defer its post (fixtured in grocery\test-defer-post.ps1)

  Both call the CALLER's Log and Send-Alert, which check-ad-cycles defines; a fixture defines its own.
#>

# <<PUBLISH-HELD-GATE-BEGIN>>
# ONE EXIT CODE, FOUR GATES, AND THIS BRANCH NAMED THE FIRST OF THEM (2026-09-20, queue 2026-09-20-417020).
# publish-deals-page.ps1 exits 2 from FOUR separate hard gates: the coverage gate (its line 122, too few
# commodities / a thin store), store-coverage (216, a staple renders no tile for some store),
# match-soundness (224, a product MOVED or DROPPED commodity vs the reviewed baseline) and
# category-coverage (233, a commodity is in no category). Until today all four paged as
# "Grocery page HELD (coverage) ... a store's pull produced too few commodities. Check the store pulls."
# On 2026-09-20 12:15 the real hold was match-soundness, and a triage round opened on store pulls that
# were fine. Same class as the rc-1/rc-2 ship summary (2026-09-19-bb10f1) and the blind-vs-live
# test-auditors tally (2026-09-19-ae9df2): several verdicts share one code and one of them gets printed.
# THE GATE NAMES ITSELF ON STDOUT and the caller's verdict lines already hold that line - so read it instead of
# assuming. FAIL CLOSED: an rc 2 whose HELD line this reader does not recognise reports 'unnamed' and
# says so; it must never assert a gate it did not read.
function Get-PublishHeldGate([string[]]$VerdictLines) {
  $held = ''
  foreach ($l in @($VerdictLines)) { $s = ([string]$l).Trim(); if ($s -like 'HELD:*') { $held = $s; break } }
  $gate = 'unnamed'
  $why  = 'publish-deals-page returned 2 with a HELD line this reader does not recognise, or with none at all - read the publish-verdict lines in ad-cycle-log.txt before assuming which gate held it.'
  if     ($held -match '(?i)coverage gate failed')       { $gate = 'coverage';           $why = "a store's pull produced too few commodities, or a store is thin/missing. Check the store pulls." }
  elseif ($held -match '(?i)missing a store tile')       { $gate = 'store-coverage';     $why = 'a staple commodity rendered no tile for one of the seven stores (out\store-coverage-report.json). The board would hide a store; fix the render, do not force it.' }
  elseif ($held -match '(?i)commodity matching changed') { $gate = 'match-soundness';    $why = 'a product MOVED or DROPPED commodity against the reviewed baseline (out\audit\soundness-report.json). Read the moved/dropped list line by line, then run audit-match-soundness.ps1 -Accept AND COMMIT grocery\out\audit\match-baseline.json, which is a TRACKED file: an accept left uncommitted is undone by the next checkout and this gate holds the next build again.' }
  elseif ($held -match '(?i)not in exactly one category'){ $gate = 'category-coverage'; $why = 'a commodity is not filed in exactly one category (out\category-coverage-report.json), so it would render in no filter. File it in categories.json.' }
  elseif ($held -match '(?i)the board this post names') { $gate = 'board-not-served'; $why = 'the post would name a board.json version feed.thriftycrew.com does not serve yet, or the feed could not be read (the HELD line says which). Nothing was written to Ghost. Land the push that carries public\board.json, let the edge serve it, then publish - capture-run does exactly that on the daily road (grocery\feed-served-lib.ps1).' }
  [pscustomobject]@{ gate = $gate; why = $why; held = $held }
}
# <<PUBLISH-HELD-GATE-END>>

function Invoke-DeferPostBuild {
  <#
    THE POINTED-TO OBJECT HAS TO BE BUILT BEFORE IT SHIPS (2026-09-28, design/PLAN-deferpost-builds-board-2026-09-28.md W1).
    Until then the -DeferPost branch hashed whatever public\board.json was already on disk and built nothing, and
    publish-deals-page is the only road to build-deals-page, the only writer of that file. So capture-run committed and
    edge-verified YESTERDAY's board, then its deferred publish rebuilt today's, named a ?v= the edge did not serve, and held
    rc 2 (2026-09-23 and 2026-09-28; on 09-28 comparison-2026-09-28 moved the cheapest price on 24 of 577 commodities and
    the served board still read bacon 3.95). Every board readers got from 09-22 on was a hand republish.
    Now the build half of publish-deals-page runs first (-BuildOnly: every gate up to category-coverage and the build, no
    Ghost call), and board_sha256 hashes the board it just wrote. The post stays deferred to capture-run (og-51).
    W2: the build is byte-deterministic over one comparison (three builds over comparison-2026-09-28 gave one SHA-256), and
    capture-run's later publish picks the same default input, so it names this board; any input that moved in between is
    held by publish-deals-page's served check, a leak and never a wrong post. compare_file records the input the build USED.
    Returns Rc (the build's exit code) and Summary (lines for the caller's summary).
  #>
  param([string]$Root, [string]$OutDir, [string]$AsOf, [string]$Sig, [string]$SigFile, [object[]]$Flips = @(), [int]$GuardsRc = 0, [switch]$NoAlert)
  $sum = New-Object System.Collections.Generic.List[string]
  $dbSw = [Diagnostics.Stopwatch]::StartNew()
  $dbOut = & powershell -ExecutionPolicy Bypass -File (Join-Path $Root 'publish-deals-page.ps1') -BuildOnly
  $rc = $LASTEXITCODE
  $dbOut = @($dbOut)
  $dbSw.Stop()
  Log ("publish-deals-page -BuildOnly: {0} s (rc={1}) - the board build only, no Ghost call" -f [int]$dbSw.Elapsed.TotalSeconds, $rc)
  $dbStages = @($dbOut | Where-Object { $_ -match 'publish-deals-page timings' -or $_ -match '^\s{4}\S.*\ss$' })
  foreach ($dbS in $dbStages) { Log ('publish-stage: ' + ([string]$dbS).Trim()) }
  # ASSIGN, THEN WRAP, AND DROP NULLS ([[ps-null-count-is-one]]).
  $dbVerdictRaw = $dbOut | Where-Object { $_ -match '^(BUILT|ERROR|HELD|WARN|price-mode|name-drift)' }
  $dbVerdict = @($dbVerdictRaw | Where-Object { $null -ne $_ })
  foreach ($v in $dbVerdict) { Log ('publish-verdict: ' + ([string]$v).Trim()) }
  $dbBuiltSha = ''; $dbCompare = ''
  foreach ($v in $dbVerdict) { if (([string]$v).Trim() -match '^BUILT board\.json sha256=([0-9A-Fa-f]+) compare=(.*)$') { $dbBuiltSha = $Matches[1]; $dbCompare = $Matches[2].Trim() } }
  if ($rc -eq 0) {
    try {
      # board_sha256 + compare_file (2026-09-26, queue 2026-09-26-518fff): WHICH board this post would name, so a later run
      # can republish a held post once that exact board is on origin/main and at the edge (capture-run Get-HeldPostDecision).
      # Uppercase hex, as lib\git-blob-lib.ps1's Get-Sha256Hex prints. The file on disk is what the caller commits, so it is
      # what is hashed; the build's own BUILT line is the cross-check.
      $pdBoardSha = ''
      try {
        $pdBoardF = Join-Path (Split-Path $Root -Parent) 'public\board.json'
        if (Test-Path -LiteralPath $pdBoardF) { $pdH = [System.Security.Cryptography.SHA256]::Create(); try { $pdBoardSha = ([BitConverter]::ToString($pdH.ComputeHash([IO.File]::ReadAllBytes($pdBoardF))) -replace '-', '') } finally { $pdH.Dispose() } }
      } catch { $pdBoardSha = '' }
      if ($dbBuiltSha -and -not [string]::Equals($dbBuiltSha, $pdBoardSha, [StringComparison]::OrdinalIgnoreCase)) { Log ('WARN public\board.json changed between the build (' + $dbBuiltSha + ') and the deferral (' + $pdBoardSha + '); the deferral names the file on disk and publish-deals-page re-checks the edge before any Ghost write') }
      $pdCmpPath = $dbCompare
      if (-not $pdCmpPath) { $pdCmp = Get-ChildItem (Join-Path $OutDir 'comparison-*.json') -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1; $pdCmpPath = $(if ($pdCmp) { $pdCmp.FullName } else { '' }) }
      $pdDoc = [ordered]@{ date = $AsOf; sig = $Sig; sig_file = $SigFile; written = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss'); flips = @($Flips); guards_rc = $GuardsRc; board_sha256 = $pdBoardSha; compare_file = $pdCmpPath }
      [IO.File]::WriteAllText((Join-Path $OutDir 'post-deferred.json'), ($pdDoc | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))
      Log ('POST DEFERRED to the caller: the board was rebuilt (public\board.json sha256=' + $pdBoardSha + ') and its post publishes after that board is live (out\post-deferred.json)')
      $sum.Add('DEFERRED  board rebuilt; its post publishes after capture-run confirms board.json and smp-feed.json are live')
    } catch { Log ('post-deferred write threw: ' + $_.Exception.Message + ' - the post was NOT published and will not be by the caller either') }
  } elseif ($rc -eq 2) {
    # A publish gate held the build, so nothing is deferred and no road publishes a post for this board today. When the gate
    # stood after the build (store-coverage, match-soundness, category-coverage) public\board.json is already rewritten and
    # the caller commits it, exactly as the full publish's HELD road always did: the data ships, the post waits.
    $heldGate = Get-PublishHeldGate $dbVerdict
    Log ('BOARD BUILD HELD: the ' + $heldGate.gate + ' gate held it - no post deferred, the live post is NOT updated')
    $sum.Add('HELD      the ' + $heldGate.gate + ' gate held the board build - no post deferred, live post NOT updated')
    if (-not $NoAlert) {
      $heldLine = if ($heldGate.held) { $heldGate.held } else { '(publish-deals-page printed no HELD line)' }
      $heldBody = 'A refreshed board was held by the ' + $heldGate.gate + " gate on $AsOf while it was being built for the deferred post, so no post was deferred and the live post was NOT updated - nothing bad was published. " + $heldGate.why + " The gate's own line was: " + $heldLine
      try { Send-Alert -Subject ('Grocery page HELD (' + $heldGate.gate + ") - $AsOf") -Body $heldBody | Out-Null } catch { Log ('held-alert threw: ' + $_.Exception.Message) }
    }
  } else {
    if ($dbVerdict.Count -eq 0) { $dbTailRaw = $dbOut | Where-Object { $null -ne $_ } | Select-Object -Last 5; foreach ($tl in @($dbTailRaw | Where-Object { $null -ne $_ })) { Log ('publish-tail: ' + ([string]$tl).Trim()) } }
    Log ("BOARD BUILD ERROR (rc=$rc) - the board build failed, no post deferred; live post NOT updated")
    $sum.Add("ERROR     the board build failed (rc=$rc) - no post deferred, live post NOT updated; see ad-cycle-log.txt")
    if (-not $NoAlert) { try { Send-Alert -Subject "Grocery publish FAILED (rc=$rc) - $AsOf" -Body "publish-deals-page.ps1 -BuildOnly returned $rc on $AsOf (the board build failed), so no post was deferred and the live post was NOT updated with today's price change. Check ad-cycle-log.txt." | Out-Null } catch {} }
  }
  return [pscustomobject]@{ Rc = $rc; Summary = $sum.ToArray() }
}
