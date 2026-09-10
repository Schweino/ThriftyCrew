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

function Get-ChainVerdictInputHashes {
  # Returns an ORDERED map of repo-relative path -> sha256, with 'absent' for a file that is not there.
  # 'absent' is a value, not a skip: a pins file that disappears between the guard run and the publish
  # is exactly the change this is here to notice.
  param([string]$Repo)
  $map = [ordered]@{}
  foreach ($p in (Get-ChainVerdictInputPaths -Repo $Repo)) {
    $rel = $p.Replace($Repo, '').TrimStart('\', '/')
    if (Test-Path -LiteralPath $p) {
      try { $map[$rel] = (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLower() }
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
    [string]$WrittenBy = 'check-ad-cycles'
  )
  $hashes = Get-ChainVerdictInputHashes -Repo $Repo
  $doc = [ordered]@{
    date            = $Date
    written         = (Get-Date).ToString('s')
    written_by      = $WrittenBy
    guards_rc       = $GuardsRc
    guards_blocked  = [bool]($GuardsRc -ne 0)
    inputs_fingerprint = (Get-ChainVerdictFingerprint -Repo $Repo -Hashes $hashes)
    inputs          = $hashes
    note            = 'Written after guards ran. Readers must go through lib\chain-verdict-lib.ps1: a verdict for another day, or one whose inputs_fingerprint no longer matches the tree, is treated as ABSENT and never ships public\** or meal-prep\**.'
  }
  $path = Join-Path $OutDir 'chain-verdict.json'
  # -Encoding utf8 under PS 5.1 emits a BOM; every reader here goes through Read-JsonFile, which
  # handles it, and audit-json-encoding pins the estate's expectation for this file.
  ($doc | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $path -Encoding UTF8
  return $path
}

function Read-ChainVerdictStatus {
  # The ONLY reader. Returns a status a publisher can act on without re-deriving the rules:
  #   PASS         guards passed, today, over the tree as it stands now  -> the only status that ships
  #   BLOCKED      guards failed, today, over the tree as it stands now
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
  $now = Get-ChainVerdictFingerprint -Repo $Repo
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
  if ($recorded -ne $now) {
    $res.status = 'STALE-INPUTS'
    $res.why = ('the chain verdict scored inputs ' + $recorded + ' but the tree is now ' + $now +
                ' - guards have not seen this board')
    return $res
  }
  if ([bool]$v.guards_blocked) {
    $res.status = 'BLOCKED'; $res.why = "guards BLOCKED today's board"; $res.guards_blocked = $true
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
