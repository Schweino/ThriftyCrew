# chain-verdict-lib.ps1 - THE guard verdict, written once and read the same way by every publisher.
#
# WHY THIS EXISTS (2026-09-07). out\chain-verdict.json is the gate's answer as a VALUE: check-ad-cycles
# runs guards.ps1 and writes the rc there, and capture-run, push-data and the capture watchdog read it
# before staging public\** . Until today the only freshness test was the DATE, and a date is not a
# measurement of the thing that was measured:
#
#   THE OBSERVED HALF. guards blocked at 08:14 on 2026-09-07. The board was rebuilt and republished at
#   11:28 with guards passing, but nothing rewrote the verdict, so at 14:47 a hand-run push-data still
#   read guards_blocked=true and refused to stage public\** . That direction is merely annoying.
#
#   THE HALF THAT LOSES MONEY. Reverse it. Guards PASS at 08:14, someone edits commodities.json at 11:10
#   (b28788fa did exactly that on 09-06 and stopped the board three hours later), and a hand-run
#   push-data at 14:00 reads guards_blocked=false and SHIPS a board no gate has ever seen. Same date,
#   same file, a verdict about inputs that no longer exist. A stale PASS is the unwatched direction.
#
# So the verdict now carries an INPUT FINGERPRINT: the sha256 of every artifact guards.ps1 actually
# reads. A reader recomputes it, and a verdict whose inputs have moved is not a verdict - it is ABSENT.
# Fail closed in both directions: STALE never ships, exactly like a missing file.
#
# ONE IMPLEMENTATION, FOUR CALLERS. The estate has been bitten by a check that existed twice and drifted
# ([[notes-vs-bid-check-has-two-diverged-implementations]]), so the writer and every reader come through
# here. Get-ChainVerdictInputHashes is the single list of what a guard verdict is about.

# No Set-StrictMode here: this file is DOT-SOURCED, so a mode set here would follow the caller into
# code that never asked for it and fail it on an unrelated line.
. (Join-Path $PSScriptRoot 'atomic-write.ps1')   # Write-TcAtomicFile -Lf: a tracked file other processes read
$__cvLibRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $__cvLibRoot 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage

# The artifacts guards.ps1 reads. Derived by reading its Join-Path calls, not guessed: the board it
# scores, the recipe board, the pins that BEAT the engine, the links the factor check derives from,
# the rules that decide what a row even is, and the drift file guard 3 consults. If guards learns to
# read a new file, add it here - a fingerprint that omits an input is a fingerprint that says fresh
# when the answer has already changed.
function Get-ChainVerdictInputPaths {
  param([string]$Repo)
  $g = Join-Path $Repo 'grocery'
  $out = Join-Path $g 'out'
  $paths = [Collections.Generic.List[string]]::new()
  # the board guards scored: the NEWEST comparison-*.json, which is what compare-deals just wrote
  $board = @(Get-ChildItem -Path $out -Filter 'comparison-*.json' -File -ErrorAction SilentlyContinue |
             Sort-Object Name -Descending | Select-Object -First 1)
  if ($board.Count) { $paths.Add($board[0].FullName) }
  foreach ($rel in @('commodities.json', 'known-wrong.json', 'board-price-overrides.json',
                     'product-urls.json', 'out\recipe-board.json', 'out\name-drift.json')) {
    $paths.Add((Join-Path $g $rel))
  }
  return $paths.ToArray()
}

# THE HASH MEASURES CONTENT, NOT LINE ENDINGS (2026-09-28, queue 2026-09-27-f50b7a). Every input above is JSON, and
# git owns their line endings (eol=lf) while the chain's PS 5.1 writers leave some of them CRLF (product-urls.json held
# 25,892 CR bytes on 2026-09-28). Any git round-trip of a dirty input (stash, checkout, an autostash pull) rewrote those
# bytes LF with the content unchanged, the raw-byte fingerprint moved, and on 2026-09-27 the chain withheld a board
# guards had passed. In JSON a raw CR can only be whitespace between tokens (a CR inside a string must be escaped), so
# dropping every 0x0D byte cannot change the parsed value, and any real content change still moves the hash. A file
# with no CR hashes exactly as Get-FileHash does. The basis is recorded in the verdict and a reader on another basis
# reads STALE-INPUTS: fail closed, never a comparison across bases.
$script:ChainVerdictHashBasis = 'json-cr-stripped-v1'
function Get-ChainVerdictContentHash {
  param([Parameter(Mandatory = $true)][string]$Path)
  $b = [IO.File]::ReadAllBytes($Path)
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    $start = 0
    while ($start -lt $b.Length) {
      $i = [Array]::IndexOf([byte[]]$b, [byte]13, [int]$start)
      if ($i -lt 0) { $i = $b.Length }
      if ($i -gt $start) { [void]$sha.TransformBlock($b, $start, ($i - $start), $null, 0) }
      $start = $i + 1
    }
    [void]$sha.TransformFinalBlock((New-Object byte[] 0), 0, 0)
    return (($sha.Hash | ForEach-Object { $_.ToString('x2') }) -join '')
  } finally { $sha.Dispose() }
}

function Get-ChainVerdictInputHashes {
  # Returns an ORDERED map of repo-relative path -> sha256 of the CR-stripped content (basis above), with 'absent' for
  # a file that is not there. 'absent' is a value, not a skip: a pins file that disappears between the guard run and
  # the publish is exactly the change this is here to notice.
  param([string]$Repo)
  $map = [ordered]@{}
  foreach ($p in (Get-ChainVerdictInputPaths -Repo $Repo)) {
    $rel = $p.Replace($Repo, '').TrimStart('\', '/')
    if (Test-Path -LiteralPath $p) {
      try { $map[$rel] = Get-ChainVerdictContentHash -Path $p }
      catch { $map[$rel] = 'unreadable' }
    } else { $map[$rel] = 'absent' }
  }
  return $map
}

function Get-ChainVerdictFingerprint {
  # One short string over the whole map, so a reader compares ONE value and a human can eyeball it.
  param([string]$Repo, $Hashes)
  if (-not $Hashes) { $Hashes = Get-ChainVerdictInputHashes -Repo $Repo }
  $lines = @()
  foreach ($k in $Hashes.Keys) { $lines += ($k.ToLower() + '=' + [string]$Hashes[$k]) }
  $joined = ($lines -join "`n")
  $sha = [Security.Cryptography.SHA256]::Create()
  try { $b = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($joined)) } finally { $sha.Dispose() }
  return (($b | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 16)
}

function Write-ChainVerdict {
  # The ONLY writer. GuardsRc is an OBSERVED exit code - never a value someone decided was true.
  # Callers: check-ad-cycles (right after it runs guards) and refresh-chain-verdict.ps1 (which runs
  # guards itself for exactly this purpose). Both measure; neither describes.
  param(
    [Parameter(Mandatory = $true)][string]$Repo,
    [Parameter(Mandatory = $true)][string]$OutDir,
    [Parameter(Mandatory = $true)][string]$Date,
    [Parameter(Mandatory = $true)][int]$GuardsRc,
    [string]$WrittenBy = 'check-ad-cycles',
    [int]$Quarantined = 0,
    # THE FEED HALF (2026-09-23). grocery\export-feed.ps1 refuses (exit 3, nothing written) on a missing input or a
    # section that fell more than 10%, and the served smp-feed.json then stays yesterday's. A board shipped beside a
    # refused feed is the 2026-09-06 divergence (board and feed on different weeks) made on purpose, so the chain
    # records the refusal HERE, where every shipping reader already looks: '' = the feed was refreshed this run, any
    # other text = refused, and that text is the reason. check-ad-cycles always passes it. A caller that does not
    # (refresh-chain-verdict re-runs guards only, and never re-exports the feed) CARRIES FORWARD today's recorded
    # refusal, because re-measuring guards says nothing about the feed and must not launder a refusal into a pass.
    [AllowNull()][string]$FeedRefused = $null
  )
  if (-not $PSBoundParameters.ContainsKey('FeedRefused')) {
    $FeedRefused = ''
    try {
      $prevF = Join-Path $OutDir 'chain-verdict.json'
      if (Test-Path -LiteralPath $prevF) {
        $prev = Get-Content -LiteralPath $prevF -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([string]$prev.date -eq $Date -and $prev.PSObject.Properties['feed_refused'] -and [string]$prev.feed_refused) { $FeedRefused = [string]$prev.feed_refused }
      }
    } catch { $FeedRefused = 'the previous chain verdict could not be read to carry its feed state forward: ' + $_.Exception.Message }
  }
  if ($null -eq $FeedRefused) { $FeedRefused = '' }
  $hashes = Get-ChainVerdictInputHashes -Repo $Repo
  # THREE TIERS SINCE 2026-09-21 (grocery\cell-quarantine-lib.ps1): guards exits 0 (clean), 4 (QUARANTINED: some cells
  # held at their last verified price, verified on this board, publishable) or anything else (not publishable as it
  # stands). A quarantined board is neither clean nor held, so `verdict` names it and `guards_blocked` is false: the
  # served paths ship, and every reader that reports state says "quarantined", never "all clean".
  $verdictWord = 'hold'
  if ($GuardsRc -eq 0) { $verdictWord = 'pass' } elseif ($GuardsRc -eq 4) { $verdictWord = 'quarantine' }
  $doc = [ordered]@{
    date            = $Date
    written         = (Get-Date).ToString('s')
    written_by      = $WrittenBy
    guards_rc       = $GuardsRc
    guards_blocked  = [bool]($GuardsRc -ne 0 -and $GuardsRc -ne 4)
    verdict         = $verdictWord
    quarantined     = $Quarantined
    feed_refreshed  = [bool](-not $FeedRefused)
    feed_refused    = $FeedRefused
    inputs_hash_basis  = $script:ChainVerdictHashBasis
    inputs_fingerprint = (Get-ChainVerdictFingerprint -Repo $Repo -Hashes $hashes)
    inputs          = $hashes
    note            = 'Written after guards ran. Readers must go through lib\chain-verdict-lib.ps1: a verdict for another day, or one whose inputs_fingerprint no longer matches the tree, is treated as ABSENT and never ships public\** or meal-prep\**.'
  }
  $path = Join-Path $OutDir 'chain-verdict.json'
  # -Encoding utf8 under PS 5.1 emits a BOM; every reader here goes through Read-JsonFile, which
  # handles it, and audit-json-encoding pins the estate's expectation for this file.
  $null = ($doc | ConvertTo-Json -Depth 6) | Write-TcAtomicFile -Path $path -Lf
  return $path
}

function Read-ChainVerdictStatus {
  # The ONLY reader. Returns a status a publisher can act on without re-deriving the rules:
  #   PASS         guards passed, today, over the tree as it stands now  -> the only status that ships
  #   BLOCKED      guards failed, today, over the tree as it stands now
  #   FEED-REFUSED guards did not block, but export-feed refused today's feed (2026-09-23), so the board holds too
  #   STALE-INPUTS today's verdict, but the artifacts it scored have changed since
  #   OTHER-DAY    the newest verdict is for a different day
  #   ABSENT       no verdict file, or it could not be read
  # Everything except PASS is "do not ship the served paths". That is deliberate: the caller cannot
  # accidentally treat "I could not tell" as a pass, which is how a could-not-look settles a question.
  param([string]$Repo, [string]$OutDir, [string]$Today)
  if (-not $Today) { $Today = (Get-Date).ToString('yyyy-MM-dd') }
  $res = [pscustomobject]@{
    status = 'ABSENT'; why = 'no chain verdict for today was found'
    guards_blocked = $true; ship_ok = $false; date = ''; written = ''
    fingerprint_recorded = ''; fingerprint_now = ''
    moved = @()
  }
  $vf = Join-Path $OutDir 'chain-verdict.json'
  if (-not (Test-Path -LiteralPath $vf)) { return $res }
  $v = $null
  try { $v = Read-JsonFile $vf } catch {
    $res.why = ('chain-verdict unreadable: ' + $_.Exception.Message)
    return $res
  }
  $res.date = [string]$v.date
  if ($v.PSObject.Properties.Name -contains 'written') { $res.written = [string]$v.written }
  if ($res.date -ne $Today) {
    $res.status = 'OTHER-DAY'
    $res.why = ('the newest chain verdict is for ' + $res.date + ', not today')
    return $res
  }
  $nowHashes = Get-ChainVerdictInputHashes -Repo $Repo
  $now = Get-ChainVerdictFingerprint -Repo $Repo -Hashes $nowHashes
  $res.fingerprint_now = $now
  $recorded = ''
  if ($v.PSObject.Properties.Name -contains 'inputs_fingerprint') { $recorded = [string]$v.inputs_fingerprint }
  $res.fingerprint_recorded = $recorded
  if (-not $recorded) {
    # A verdict written before this library existed says nothing about what it measured. Treating it
    # as fresh would keep the exact hole this file closes, so it is stale by construction.
    $res.status = 'STALE-INPUTS'
    $res.why = 'the chain verdict records no input fingerprint, so nothing proves it is about this tree'
    return $res
  }
  # A verdict hashed on another basis (a raw-byte verdict from before 2026-09-28, or a future basis) is not comparable:
  # STALE, fail closed, exactly as a verdict with no fingerprint is.
  $basis = ''
  if ($v.PSObject.Properties['inputs_hash_basis']) { $basis = [string]$v.inputs_hash_basis }
  if (-not [string]::Equals($basis, [string]$script:ChainVerdictHashBasis, [StringComparison]::Ordinal)) {
    $res.status = 'STALE-INPUTS'
    $res.why = ('the chain verdict hashed its inputs on basis ''' + $basis + ''' and this reader on ''' +
                $script:ChainVerdictHashBasis + ''', so nothing proves it is about this tree')
    return $res
  }
  if ($recorded -ne $now) {
    # NAME WHAT MOVED (2026-09-28): the verdict stores the per-path map, so the withhold says which input changed after
    # guards ran. A path on one side only (a new newest comparison, say) counts as moved. Separators are written '/'.
    $movedL = [Collections.Generic.List[string]]::new()
    $recMap = @{}
    if ($v.PSObject.Properties['inputs'] -and $v.inputs) {
      foreach ($pp in $v.inputs.PSObject.Properties) { $recMap[[string]$pp.Name] = [string]$pp.Value }
    }
    foreach ($k in $nowHashes.Keys) {
      $ks = [string]$k
      if (-not $recMap.ContainsKey($ks) -or -not [string]::Equals($recMap[$ks], [string]$nowHashes[$k], [StringComparison]::Ordinal)) {
        $movedL.Add($ks.Replace('\', '/'))
      }
    }
    foreach ($k in $recMap.Keys) { if (-not $nowHashes.Contains($k)) { $movedL.Add(([string]$k).Replace('\', '/')) } }
    $res.moved = $movedL.ToArray()
    $movedTxt = 'no single path (the per-path map is missing or unreadable)'
    if ($movedL.Count) { $movedTxt = ($movedL.ToArray() -join ', ') }
    $res.status = 'STALE-INPUTS'
    $res.why = ('the chain verdict scored inputs ' + $recorded + ' but the tree is now ' + $now +
                ' - moved since guards ran: ' + $movedTxt + ' - guards have not seen this board')
    return $res
  }
  if ([bool]$v.guards_blocked) {
    $res.status = 'BLOCKED'; $res.why = "guards BLOCKED today's board"; $res.guards_blocked = $true
    return $res
  }
  # FEED-REFUSED does not ship (2026-09-23). Guards may have passed, so guards_blocked stays false (it answers the
  # guards question, and capture-watchdog / health-heartbeat read it as that), but export-feed refused today's feed
  # and the served smp-feed.json is yesterday's: shipping public\board.json beside it would put the board and the
  # 583 recipe pages on different weeks. A verdict written before this field existed has no feed_refreshed and reads
  # exactly as before.
  if ($v.PSObject.Properties['feed_refreshed'] -and -not [bool]$v.feed_refreshed) {
    $fr = ''; if ($v.PSObject.Properties['feed_refused']) { $fr = [string]$v.feed_refused }
    $res.status = 'FEED-REFUSED'; $res.guards_blocked = $false; $res.ship_ok = $false
    $res.why = ('export-feed refused today''s feed, so the served smp-feed.json is NOT current and the board does not ship beside it: ' + $fr)
    return $res
  }
  # QUARANTINE ships, under its own name (2026-09-21). guards_rc 4 is a board whose bad cells are held at their last
  # verified price and verified so on this board; readers key on ship_ok, and anything that reports the state reads
  # the status word, so a quarantined board is never described as a clean pass.
  if ($v.PSObject.Properties.Name -contains 'guards_rc' -and [int]$v.guards_rc -eq 4) {
    $nq = 0; if ($v.PSObject.Properties.Name -contains 'quarantined') { $nq = [int]$v.quarantined }
    $res.status = 'QUARANTINE'; $res.why = ("guards passed today's board with " + $nq + " cell(s) quarantined at their last verified price"); $res.guards_blocked = $false
    $res.ship_ok = $true
    return $res
  }
  if (-not ($v.PSObject.Properties.Name -contains 'guards_rc') -or [int]$v.guards_rc -ne 0) {
    # A verdict that says not-blocked with an rc that is neither 0 nor 4 is one nothing here knows how to read: held.
    $res.status = 'BLOCKED'; $res.why = ('the chain verdict records guards_rc ' + [string]$v.guards_rc + ', which is not a pass'); $res.guards_blocked = $true
    return $res
  }
  $res.status = 'PASS'; $res.why = "guards passed today's board"; $res.guards_blocked = $false
  $res.ship_ok = $true
  return $res
}

function Get-ChainVerdictDir {
  # WHERE THE VERDICT LIVES, owned HERE (2026-09-10, queue 2026-09-10-1fa212). A reader in another module
  # asks this library rather than spelling grocery's internals path itself, which is the coupling
  # ops\audit-cross-module-reach.ps1 ratchets. The location is this file's knowledge - the writer above
  # already takes it as an argument from the one caller that owns the directory - so this is the place
  # allowed to know it.
  param([Parameter(Mandatory = $true)][string]$Repo)
  return (Join-Path (Join-Path $Repo 'grocery') 'out')
}

function Read-ChainVerdictRecord {
  # THE VERDICT AS RECORDED, NOT A SHIP DECISION (2026-09-10, queues 2026-09-10-1fa212 and 2026-09-10-267ba6).
  # Returns the parsed chain-verdict.json (date, written, guards_rc, guards_blocked, ...) or $null when it is
  # absent or unreadable. Read-ChainVerdictStatus above stays the only reader that may decide whether served
  # paths SHIP. This answers the narrower question two readers need - what did guards say today - where the
  # fingerprint test is the wrong instrument: the relink tail rewrites product-urls.json after the verdict is
  # written, so on a green day that status reads STALE-INPUTS while guards really did pass and the hub really
  # was republished. Callers decide what an absent record means; both current callers treat it as held.
  param([Parameter(Mandatory = $true)][string]$Repo, [string]$OutDir = '')
  if (-not $OutDir) { $OutDir = Get-ChainVerdictDir -Repo $Repo }
  $vf = Join-Path $OutDir 'chain-verdict.json'
  if (-not (Test-Path -LiteralPath $vf)) { return $null }
  try { return (Read-JsonFile $vf) } catch { return $null }
}
function Invoke-ChainVerdictWithheldLane($Verdict, [string]$Kind, [string]$TodayS, [string]$LogPath) {
  <# capture-run.ps1 ONLY: books the failed lane for a board it withheld. Calls capture-run's Add-FailedLane,
     Set-FailedLanePaged and Send-Alert through the caller's scope, so it must be called from there. #>
  # A STALE VERDICT IS NOT A BLOCKED BOARD (2026-09-28, queue 2026-09-27-f50b7a). Guards may well have passed; what
  # withholds the board is that an input moved after they ran. Filed under guards-blocked it paged nothing of its own
  # and capture-watchdog's RUN RECORD fold named the wrong cause, so it books its own lane, names the moved paths, and
  # pages once as itself. BLOCKED, OTHER-DAY, ABSENT and FEED-REFUSED keep 'guards-blocked' exactly as before.
  $why = $Verdict.why
if ([string]$verdict.status -eq 'STALE-INPUTS') {
  Add-FailedLane 'verdict-stale'
  $vsMoved = @($verdict.moved)
  $vsWhat = 'the verdict fingerprint (no single path named)'
  if ($vsMoved.Count) { $vsWhat = ($vsMoved -join ', ') }
  Write-Output ('publish: verdict-stale - moved since guards ran: ' + $vsWhat)
  try {
    $vsSubj = 'Daily chain withheld its board: ' + $vsWhat + ' changed after guards ran - ' + $todayS
    Send-Alert -Subject $vsSubj -Body ("capture-run.ps1 [$Kind]: guards scored today's board, but by publish time an input it read had changed, so the served paths were NOT shipped and readers keep the last good board. Moved: " + $vsWhat + ". Verdict: " + $why + ". A foreign write to the production checkout mid-run (a session edit, a pull) is the usual cause; the next chain run re-scores it. Log: " + $LogPath) | Out-Null
    Set-FailedLanePaged 'verdict-stale' $vsSubj $LASTEXITCODE
  } catch { Write-Output ('verdict-stale alert threw: ' + $_.Exception.Message) }
} else {
  Add-FailedLane 'guards-blocked'
}
}
