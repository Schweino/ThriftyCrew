# ingredient-resolutions.ps1
# ---------------------------------------------------------------------------------------------------
# Remembers what an ingredient string resolved to, so the mapper stops re-deriving stable answers and
# the commodity-registrar is never asked the same question twice.
#
# IDENTITY ONLY - NEVER PRICE. This caches "shaved beef steak -> shaved-beef-steak, bid exists" and
# nothing else. Prices come from the board and change weekly; caching one would be how a stale number
# reaches a card. The `bid_exists` flag is a fact about the WIRING (is there a row in
# db\ingredients.json), not about the amount, and it is what lets the mapper hold a recipe BEFORE the
# writer is paid rather than after the auditor catches it - the R3 shift-left in the efficiency plan.
#
#   .\ingredient-resolutions.ps1 -Record -Term 'shaved beef steak' -ItemId shaved-beef-steak [-BidExists] [-Evidence '...'] [-By mapper]
#   .\ingredient-resolutions.ps1 -Query -Term 'shaved beef steak'         exit 3 when a prior ruling exists
#   .\ingredient-resolutions.ps1 -Invalidate -ItemId x    (a registrar ruling changed a commodity id)
#   .\ingredient-resolutions.ps1 -SelfTest
# ---------------------------------------------------------------------------------------------------
param(
  [switch]$Record, [switch]$Query, [switch]$Invalidate, [switch]$List, [switch]$SelfTest,
  [string]$Term = '', [string]$ItemId = '', [string]$Evidence = '', [string]$By = '',
  [switch]$BidExists, [string]$Store = '', [switch]$Json
)
$ErrorActionPreference = 'Stop'
$runRecord=[bool]$Record; $runQuery=[bool]$Query; $runInv=[bool]$Invalidate; $runSelfTest=[bool]$SelfTest; $runJson=[bool]$Json; $runBid=[bool]$BidExists

$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$mp   = Split-Path -Parent $here
$repo = Split-Path -Parent $mp
. (Join-Path $repo 'lib\guard-contract.ps1')
if (-not $Store) { $Store = Join-Path $mp 'db\ingredient-resolutions.json' }

function Get-TermKey {
  param([string]$T)
  if (-not $T) { return '' }
  # Normalise the incidental, keep the meaningful. "2 lbs Shaved Beef Steak," and "shaved beef steak"
  # are the same question; "beef steak" is NOT, so no word is ever dropped.
  $t = $T.ToLower().Trim()
  $t = $t -replace '[^a-z0-9 ]', ' '
  $t = $t -replace '\s+', ' '
  return $t.Trim()
}
function Read-Store { param([string]$P)
  if (-not (Test-Path $P)) { return @() }
  try { $d = Get-Content $P -Raw -Encoding utf8 | ConvertFrom-Json } catch { return @() }
  if ($d -and ($d.PSObject.Properties.Name -contains 'resolutions')) { return @($d.resolutions) }
  return @() }

# ---------------------------------------------------------------------------------------------------
# THE WRITE LOCK (added 2026-08-24, PLAN-recipe-hunter-v3 D9's phase-1 obligation: "any single-file
# ledger written by a lane whose cap exceeds 1 takes the source-domains named-mutex pattern, with a
# concurrent-writers fixture PER LEDGER").
#
# This ledger is a read-modify-write of one JSON file, and until today its only writer was one mapper
# agent at a time. The v3 daemon runs the MAP LANE AT CAP 2 and holds the pen itself, so two mapper
# completions can land a -Record at the same moment: both read the same rows, both add their own, and
# the last one wins - the other resolution is simply gone, and the next mapper re-derives an answer
# this ledger exists to have already given. The measured cost of skipping exactly this on
# source-domains was 2,293 outcomes recorded as 65, a 97% loss.
#
# A NAMED SYSTEM MUTEX, not a lock file: the OS releases it if a writer dies, so a crashed lane cannot
# wedge the ledger for every future run. The WHOLE read-modify-write happens inside it - locking only
# the write would still lose the row that was read before the lock was taken.
# ---------------------------------------------------------------------------------------------------
$script:LOCK_TIMEOUT_MS = 15000

function Invoke-Locked {
  param([scriptblock]$Body, [string]$Path)
  # Named after the store, so a scratch store in a fixture cannot block the live one.
  $key = 'Global\tc-ingredient-resolutions-' + ([Math]::Abs($Path.ToLower().GetHashCode())).ToString()
  $mx = New-Object System.Threading.Mutex($false, $key)
  $held = $false
  try {
    try { $held = $mx.WaitOne($script:LOCK_TIMEOUT_MS) }
    catch [System.Threading.AbandonedMutexException] { $held = $true }   # a dead writer, not a wedge
    if (-not $held) {
      # Could-not-write is never a silent pass: say so and exit non-zero so the caller sees it.
      Write-Output ("ingredient-resolutions: could not take the write lock within {0} ms - resolution NOT recorded" -f $script:LOCK_TIMEOUT_MS)
      exit 2
    }
    & $Body
  } finally {
    if ($held) { $mx.ReleaseMutex() | Out-Null }
    $mx.Dispose()
  }
}

if ($runSelfTest) {
  $bad=0
  function T([string]$n,[bool]$ok,[string]$got){ if($ok){Write-Output ("  ok    "+$n)}else{Write-Output ("  X     "+$n+"   got: "+$got); $script:bad++} }
  T 'case and punctuation are normalised away' ((Get-TermKey '  Shaved Beef Steak, ') -eq 'shaved beef steak') (Get-TermKey '  Shaved Beef Steak, ')
  T 'MUST FIRE  a DIFFERENT ingredient does not collide with a shorter one' ((Get-TermKey 'beef steak') -ne (Get-TermKey 'shaved beef steak')) 'collided'
  T 'internal whitespace collapses' ((Get-TermKey 'sour    cream') -eq 'sour cream') (Get-TermKey 'sour    cream')
  T 'an empty term keys to empty rather than throwing' ((Get-TermKey '') -eq '') 'threw'
  $tmp = Join-Path $env:TEMP ('ir-' + [guid]::NewGuid().ToString('N') + '.json')
  try {
    ([pscustomobject]@{ resolutions=@([pscustomobject]@{key='sumac';item_id='sumac';bid_exists=$false}) } | ConvertTo-Json -Depth 5) | Set-Content $tmp -Encoding utf8
    $b = @(Read-Store $tmp)
    T 'the store round-trips' ($b.Count -eq 1 -and $b[0].key -eq 'sumac') ([string]$b.Count)
    T 'MUST FIRE  bid_exists=false survives the round-trip as FALSE, not as absent' ($b[0].bid_exists -eq $false) ([string]$b[0].bid_exists)
    T 'a missing store reads as empty' ((@(Read-Store (Join-Path $env:TEMP 'nope-ir.json'))).Count -eq 0) 'not empty'

    # MUST FIRE: CONCURRENT WRITERS DO NOT LOSE ROWS (added 2026-08-24, D9's phase-1 obligation).
    #
    # The v3 daemon runs the MAP LANE AT CAP 2 and holds the pen itself, so two mapper completions can
    # land a -Record at the same instant. Without the mutex both read the same rows, both add their
    # own, and the last write wins - the measured cost of exactly this on source-domains was 2,293
    # outcomes recorded as 65, a 97% loss.
    #
    # A FIXTURE THAT CANNOT LOSE A ROW PROVES NOTHING, and the first build of this one could not.
    # MEASURED 2026-08-24: four Start-Job children each spawning their own powershell.exe passed
    # WITH THE LOCK NEUTERED, because process startup costs ~1 s and the read-modify-write costs
    # ~2 ms - the four writers never overlapped, so there was no race to lose. Two things fix that,
    # and both are needed:
    #   1. A START BARRIER. Every child is handed the same UTC instant and spins until it arrives, so
    #      they enter the critical section together instead of a second apart.
    #   2. A STORE BIG ENOUGH TO BE SLOW. The scratch store is seeded with 400 rows, which puts the
    #      read-modify-write in the tens of milliseconds - wide enough for four barriered writers to
    #      sit inside it at once.
    # With both, the neutered run loses rows every time and the locked run loses none. Four writers
    # and not two on purpose: the PS 5.1 collection traps say a fixture over a collection uses at
    # least three elements, and losing one of four is unmistakable where losing one of two reads as a
    # coin flip.
    $ctmp = Join-Path $env:TEMP ('ir-conc-' + [guid]::NewGuid().ToString('N') + '.json')
    $seed = @(1..400 | ForEach-Object {
      [pscustomobject]@{ key="seed $_"; term="seed $_"; item_id="seed-$_"; bid_exists=$true
                         evidence='a row that must survive four concurrent writers'; by='fixture'
                         at='2026-08-24T00:00:00' } })
    ([pscustomobject]@{ count=$seed.Count; resolutions=$seed } | ConvertTo-Json -Depth 6) | Set-Content $ctmp -Encoding utf8
    $barrier = (Get-Date).ToUniversalTime().AddSeconds(4).ToString('o')
    $jobs = @()
    foreach ($i in 1..4) {
      $jobs += Start-Job -ScriptBlock {
        param($script, $store, $n, $go)
        $t = [datetime]::Parse($go, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
        while ((Get-Date).ToUniversalTime() -lt $t) { Start-Sleep -Milliseconds 2 }
        & powershell -NoProfile -ExecutionPolicy Bypass -File $script -Record -Term ("conc term $n") -ItemId ("conc-$n") -BidExists -By 'fixture' -Store $store | Out-Null
      } -ArgumentList $PSCommandPath, $ctmp, $i, $barrier
    }
    $jobs | Wait-Job -Timeout 180 | Out-Null
    $jobs | Remove-Job -Force -ErrorAction SilentlyContinue
    $got = @(Read-Store $ctmp)
    $conc = @(@($got | Where-Object { [string]$_.key -like 'conc term *' } | ForEach-Object { [string]$_.key }) | Sort-Object)
    $seedKept = @($got | Where-Object { [string]$_.key -like 'seed *' }).Count
    Remove-Item $ctmp -Force -ErrorAction SilentlyContinue
    T 'MUST FIRE  4 barriered concurrent -Record calls all land (the map lane writes 2-wide and the daemon holds the pen)' `
      (@($conc).Count -eq 4 -and ($conc -join ',') -eq 'conc term 1,conc term 2,conc term 3,conc term 4') `
      ("kept " + @($conc).Count + " of 4: " + ($conc -join ','))
    T 'MUST FIRE  and not one of the 400 rows already in the ledger was dropped on the way' `
      ($seedKept -eq 400) ("kept $seedKept of 400")
  } finally { if (Test-Path $tmp) { Remove-Item $tmp -Force } }
  # ---- AN UNWRITABLE STORE MUST NOT REPORT SUCCESS (2026-08-31) ----
  # Save-Rows used to let a failed Set-Content fall through, so -Invalidate printed "invalidated N
  # row(s)" and exited 0 while the ledger on disk was untouched, and the only trace was a raw error on
  # stderr. Driven as a real child process because the exit code IS the finding, and because the
  # leaked stderr is what killed run-gates.
  $missing = Join-Path $tmp 'no-such-dir\ledger.json'
  $errF = [IO.Path]::GetTempFileName(); $outF = [IO.Path]::GetTempFileName()
  $pi = Start-Process -FilePath 'powershell' -Wait -PassThru -NoNewWindow `
        -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$PSCommandPath,
                        '-Invalidate','-ItemId','apples','-Store',$missing) `
        -RedirectStandardError $errF -RedirectStandardOutput $outF
  # COALESCED TO '' BEFORE ANY .Trim(), and the neuter is why. Get-Content -Raw on an EMPTY file
  # returns $null, and an empty stdout is exactly what the DEFECT produces - so the diagnostic
  # argument threw "You cannot call a method on a null-valued expression" on the one run where these
  # cases were supposed to go red. The suite died at this line and printed no failures at all: a test
  # whose FAILURE path crashes reports nothing, which is indistinguishable from a test that passed.
  $sOut = [string](Get-Content $outF -Raw); if ($null -eq $sOut) { $sOut = '' }
  $sErr = [string](Get-Content $errF -Raw); if ($null -eq $sErr) { $sErr = '' }
  Remove-Item $errF, $outF -Force -ErrorAction SilentlyContinue
  # NAMED HONESTLY: the first two held BEFORE this fix too (the throw was already terminating), so they
  # are the standing contract, not the proof. The two below them are the ones that discriminate.
  T '-Invalidate on an unwritable store exits non-zero' ($pi.ExitCode -ne 0) ("exit " + $pi.ExitCode)
  T '...and does NOT claim it invalidated anything' (-not ($sOut -match 'invalidated \d+ row')) $sOut
  T '...and says it could not write, on STDOUT where a caller reads it' ($sOut -match 'COULD NOT WRITE') $sOut
  T 'MUST FIRE  ...and leaks NOTHING to stderr (one noisy child kills ops\run-gates.ps1)' `
    ([string]::IsNullOrWhiteSpace($sErr)) $sErr

  if ($bad -gt 0) { Write-Output ("ingredient-resolutions SELF-TEST FAIL ({0})" -f $bad); exit 2 }
  Write-Output 'ingredient-resolutions SELF-TEST PASS'
  Write-GuardComplete -Name 'ingredient-resolutions' -Summary 'selftest pass'; exit 0
}

$rows = @(Read-Store $Store)

function Save-Rows { param($R)
  $doc = [pscustomobject]@{
    _doc='Ingredient string -> commodity id, plus whether a bid is wired. Consulted by the mapper before it reasons and before it asks the commodity-registrar. IDENTITY ONLY - never a price.'
    _rule='Invalidated by any registrar ruling that changes a commodity id. bid_exists is a fact about db\ingredients.json wiring, refreshed by the mapper, and is what lets a recipe hold at `mapped` instead of dying at the audit.'
    updated=(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'); count=@($R).Count; resolutions=@($R) }
  $t = $Store + '.tmp'
  # NO -ErrorAction HERE, DELIBERATELY, and it was measured rather than assumed. $ErrorActionPreference
  # is 'Stop' at the top of this file, so a failed Set-Content is ALREADY terminating: an unwritable
  # store has always exited non-zero and has never written a half-file or claimed success. The first
  # cut of the 2026-08-31 fix added -ErrorAction Stop to both lines and a comment saying it stopped a
  # silent fall-through; running all four combinations against an unwritable store proved the flags
  # change nothing at all. Dead code that reads like a second safeguard teaches the next reader that
  # two things defend this when only one does, so it is gone. What was actually wrong is below.
  ($doc | ConvertTo-Json -Depth 6) | Set-Content -Path $t -Encoding utf8
  Move-Item -Path $t -Destination $Store -Force }

if ($runRecord) {
  $k = Get-TermKey $Term
  if (-not $k) { Write-Output 'ingredient-resolutions: -Record needs -Term'; exit 1 }
  # RE-READ INSIDE THE LOCK. $rows above was read before the mutex was taken, and using it here would
  # keep the exact race the mutex exists to close - a writer that merges into a snapshot older than
  # its own turn drops whatever landed in between.
  try {
    Invoke-Locked -Path $Store -Body {
      $fresh = @(Read-Store $Store)
      $keep = @($fresh | Where-Object { [string]$_.key -ne $k })
      $row = [pscustomobject]@{ key=$k; term=$Term; item_id=$ItemId; bid_exists=$runBid; evidence=$Evidence; by=$By; at=(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss') }
      Save-Rows @($keep + $row)
    }
  } catch {
    # THE REAL DEFECT (2026-08-31): the failure was always LOUD, but it was loud in the wrong channel.
    # An unwritable store threw an unhandled .NET error straight onto STDERR, so the exit code was
    # right and the message was unreadable to every caller that reads stdout - and rebid-ingredient's
    # Invoke-MemoryInvalidation deliberately does NOT redirect a child's stderr, because doing so
    # under EAP=Stop is itself a terminating throw. Worse, ops\run-gates.ps1 runs each self-test as a
    # native child under EAP=Stop, so that one leaked line was a TERMINATING error for the gate: the
    # whole suite died on it and reported nothing about the other 152 self-tests, all of which passed.
    # One noisy negative fixture blinded the change-time gate completely.
    Write-Output ("ingredient-resolutions: COULD NOT WRITE the store at {0} - {1}" -f $Store, $_.Exception.Message)
    exit 1
  }
  Write-Output ("ingredient-resolutions: {0} -> {1}{2}" -f $k, $(if($ItemId){$ItemId}else{'(null)'}), $(if($runBid){' [bid wired]'}else{' [NO BID - recipe must hold at mapped]'}))
  exit 0
}
if ($runInv) {
  if (-not $ItemId) { Write-Output 'ingredient-resolutions: -Invalidate needs -ItemId'; exit 1 }
  $script:invalidated = 0
  try {
    Invoke-Locked -Path $Store -Body {
      $fresh = @(Read-Store $Store)
      $keep = @($fresh | Where-Object { [string]$_.item_id -ne $ItemId })
      $script:invalidated = @($fresh).Count - @($keep).Count
      Save-Rows $keep
    }
  } catch {
    # Same as the -Record path above: a clean line on stdout instead of a raw error on stderr.
    Write-Output ("ingredient-resolutions: COULD NOT WRITE the store at {0} - {1}" -f $Store, $_.Exception.Message)
    exit 1
  }
  Write-Output ("ingredient-resolutions: invalidated {0} row(s) for item_id '{1}'" -f $script:invalidated, $ItemId)
  exit 0
}
if ($runQuery) {
  $k = Get-TermKey $Term
  $r = @($rows | Where-Object { [string]$_.key -eq $k })[0]
  if (-not $r) { if($runJson){ '{"found":false}' } else { Write-Output ("ingredient-resolutions: no prior resolution for '{0}'" -f $k) }; exit 0 }
  if ($runJson) { ($r | ConvertTo-Json -Depth 4); exit 3 }
  Write-Output ("ingredient-resolutions: '{0}' -> {1}  bid_exists={2}  (by {3} on {4})" -f $r.key, $(if($r.item_id){$r.item_id}else{'(null)'}), $r.bid_exists, $r.by, $r.at)
  if ($r.evidence) { Write-Output ("  evidence: " + $r.evidence) }
  exit 3
}
if ($runJson) { ([pscustomobject]@{ count=@($rows).Count; resolutions=@($rows) } | ConvertTo-Json -Depth 6); exit 0 }
Write-Output ("ingredient-resolutions: {0} resolution(s)" -f @($rows).Count)
foreach ($r in @($rows | Sort-Object key)) { Write-Output ("  {0,-34} {1,-28} {2}" -f $r.key, $(if($r.item_id){$r.item_id}else{'(null)'}), $(if($r.bid_exists){'bid'}else{'NO BID'})) }
exit 0
