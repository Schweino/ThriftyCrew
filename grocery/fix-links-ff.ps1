<#
  fix-links-ff.ps1 - drive Family Fare toward Brad's invariant: every priced tile has a link, that link opens
  the product the board named, and its price matches.

  Family Fare is the ONE store this can be done headlessly for: Freshop is a plain REST search (no session, no
  wall, no CAPTCHA). Every other store needs a warm browser pass.

  Handles all three faults audit-tile-integrity reports: NO-LINK, WRONG-PRODUCT, PRICE-MISMATCH,
  LINK-NO-PRICE, LINK-UNPRICEABLE.

  THE RULE THAT MAKES A LINK CORRECT: search for the BOARD ITEM'S OWN NAME and take the best name match.
  NOT the cheapest - resolve-familyfare-urls.ps1 picks cheapest, which is right for choosing a PRICE and wrong
  for choosing a LINK, and is why the board priced "Our Family Cottage Cheese 24 Oz" while its link opened
  "Daisy Low Fat 2%". Price and link disagreed by construction.

  REFUSES rather than guesses:
   * below the score threshold -> leave the existing link alone (a differently-wrong link is not progress)
   * no canonical_url on the candidate -> skip (NEVER build a store URL; I nearly shipped 4 404s doing that)
   * the matched product's per-unit disagrees with the board -> record it, do not link. If the link does not
     agree with the price, linking it just moves the lie somewhere a shopper will find it.

  PLAN / APPLY SPLIT - and why it exists. The first version searched Freshop in the dry run, then searched it
  AGAIN under -Apply. Two consequences, both bad:
    1. It doubled the request load against a store that rate-limits, and that is what tripped the wall: the dry
       run resolved 55, the apply run got 8 through and then every remaining search came back 400.
    2. Worse - REVIEW DID NOT BIND THE WRITE. I reviewed 55 resolutions and the tool wrote a different 8. A dry
       run whose output is not what -Apply writes is not a dry run, it is a rehearsal of a different show.
  So: the resolve pass writes out\ff-link-plan.json and -Apply consumes it with NO network calls. What you read
  in the plan is exactly what lands in product-urls.json. -Apply also re-checks each planned row against the
  CURRENT board and drops any row whose board name/price moved since the plan was written (free, local, and it
  stops a stale plan from overwriting a fresher board).

  THE CALL BUDGET IS DOCUMENTED - RESPECT IT. README's resolver table already said Freshop "400s after ~40
  calls". A dry run of 80 plus an apply run of 80 is ~160, so the wall was not bad luck, it was a limit this
  repo had already written down and I ignored. -MaxCalls caps a single run at 35 and the plan ACCUMULATES
  across runs: ids already resolved in the plan are skipped, so 3 paced batches build one complete plan that
  -Apply then writes in a single shot.

  Read-only unless -Apply.
#>
param([switch]$Apply, [double]$MinScore = 0.75, [string]$OutDir = "", [int]$MaxCalls = 35, [switch]$Fresh)
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
. (Join-Path $root 'pu-lib.ps1')

$viol = @((Get-Content (Join-Path $OutDir 'tile-integrity.json') -Raw | ConvertFrom-Json).rows) | Where-Object { $_.store -eq 'Family Fare' }
Write-Output ("Family Fare violations to work: " + $viol.Count)
$cmpF = (Get-ChildItem (Join-Path $OutDir 'comparison-*.json') | Sort-Object Name -Desc | Select-Object -First 1)
$cmp = (Get-Content $cmpF.FullName -Raw | ConvertFrom-Json).comparison
$cell = @{}
foreach ($r in $cmp) { foreach ($s in $r.stores) { if ($s.store -eq 'Family Fare') { $cell[[string]$r.id] = @{ item = [string]$s.item; pu = [double]$s.per_unit; unit = [string]$r.unit } } } }
$puPath = Join-Path $root 'product-urls.json'
$puDoc = Get-Content $puPath -Raw | ConvertFrom-Json

function Score([string]$board, [string]$cand) {
  $n = { param($x) (($x.ToLower() -replace '[^a-z0-9 ]', ' ') -replace '\s{2,}', ' ').Trim() }
  $b = @((& $n $board) -split ' ' | Where-Object { $_.Length -gt 2 })
  $c = (& $n $cand)
  if (-not $b.Count) { return 0 }
  $h = 0; foreach ($w in $b) { if ($c -match [regex]::Escape($w)) { $h++ } }
  return [math]::Round($h / $b.Count, 3)
}

$planPath = Join-Path $OutDir 'ff-link-plan.json'

# ---- APPLY MODE: consume the plan, touch no network. -------------------------------------------------------
if ($Apply) {
  if (-not (Test-Path $planPath)) { Write-Output 'No plan at out\ff-link-plan.json. Run without -Apply first to resolve one.'; exit 2 }
  $plan = Get-Content $planPath -Raw | ConvertFrom-Json
  $rows = @($plan.resolved)
  Write-Output ("plan: " + $rows.Count + " resolution(s) written " + $plan.generated)
  $wrote = 0; $dropped = @()
  foreach ($f in $rows) {
    # re-check against the CURRENT board: a plan is a snapshot, and the board may have rebuilt since.
    if (-not $cell.ContainsKey([string]$f.id)) { $dropped += ("  - " + $f.id + ": no longer a priced Family Fare tile"); continue }
    $now = $cell[[string]$f.id]
    if ($now.item -ne [string]$f.board) { $dropped += ("  - " + $f.id + ": board name moved since plan (`"" + $now.item + "`" now)"); continue }
    if ([math]::Abs([double]$now.pu - [double]$f.board_pu) -gt 0.0001) { $dropped += ("  - " + $f.id + ": board price moved since plan"); continue }
    if (-not $puDoc.items.($f.id)) { $puDoc.items | Add-Member -NotePropertyName $f.id -NotePropertyValue ([pscustomobject]@{}) }
    $e = $puDoc.items.($f.id).'Family Fare'
    if ($e) { $e.url = $f.url; $e.name = $f.name; $e.price = $f.price; $e.size = $f.size }
    else { $puDoc.items.($f.id) | Add-Member -NotePropertyName 'Family Fare' -NotePropertyValue ([pscustomobject]@{ url = $f.url; name = $f.name; price = $f.price; size = $f.size }) -Force }
    $wrote++
  }
  if ($dropped.Count) { Write-Output ''; Write-Output ("DROPPED (board moved since the plan was written): " + $dropped.Count); $dropped | ForEach-Object { Write-Output $_ } }
  ($puDoc | ConvertTo-Json -Depth 8) | Set-Content $puPath -Encoding UTF8
  Write-Output ''
  Write-Output ("APPLIED: " + $wrote + " Family Fare link(s) written from the plan (0 network calls)")
  exit 0
}

# ---- RESOLVE MODE: search, then write the plan. ------------------------------------------------------------
$fixed = @(); $refused = @(); $n = 0
# Carry forward what earlier batches already resolved, so 3 paced runs build ONE complete plan.
$done = @{}
if ((Test-Path $planPath) -and -not $Fresh) {
  $prev = Get-Content $planPath -Raw | ConvertFrom-Json
  foreach ($p in @($prev.resolved)) { $fixed += $p; $done[[string]$p.id] = $true }
  Write-Output ("carried forward from the existing plan: " + $fixed.Count + " resolution(s) (pass -Fresh to start over)")
}
$calls = 0
# CIRCUIT BREAKER. When Freshop walls us it answers 400 to everything - "Bananas" 400s just like a 60-char
# product title does, so a 400 is the wall, not a malformed query. Without this the run kept marching: 72 more
# ids x 3 retries = 216 requests fired at a store that had already said stop, which only deepens the ban and
# produces a plan full of fake "no match" rows. Trip after 5 consecutive failures and report honestly.
$consecFail = 0; $tripped = $false
foreach ($v in $viol) {
  if ($tripped) { $refused += [pscustomobject]@{ id = [string]$v.id; why = 'not attempted - circuit breaker tripped' }; continue }
  $id = [string]$v.id
  if ($done.ContainsKey($id)) { continue }                # already resolved by an earlier batch
  if ($calls -ge $MaxCalls) { $refused += [pscustomobject]@{ id = $id; why = 'not attempted - call budget for this run spent (re-run after a cooldown)' }; continue }
  if (-not $cell.ContainsKey($id)) { continue }
  $board = $cell[$id].item; $bpu = $cell[$id].pu; $unit = $cell[$id].unit
  $q = (($board -replace '[^A-Za-z0-9 ]', ' ') -replace '\s{2,}', ' ').Trim()
  $q = ($q -split ' ' | Select-Object -First 6) -join ' '
  $api = 'https://api.freshop.ncrcloud.com/1/products?app_key=family_fare&store_id=6401&limit=25&q=' + [uri]::EscapeDataString($q)
  $best = $null; $bs = 0; $err = ''
  $calls++
  # RETRY WITH BACKOFF, and never let a throttle masquerade as "no match". At 350ms Freshop started refusing
  # mid-run and seven consecutive ids came back "search failed" in alphabetical order - that is a rate limit,
  # not seven products Family Fare stopped selling. Recording those as "no match" would have been the exact
  # mistake this repo already wrote down for Aldi: a 403 is retried, never silently treated as absence.
  foreach ($attempt in 1..3) {
    try {
      $resp = Invoke-WebRequest -Uri $api -UseBasicParsing -TimeoutSec 25 -Headers @{'User-Agent' = 'Mozilla/5.0'; 'Accept' = 'application/json' }
      foreach ($it in (ConvertFrom-Json $resp.Content).items) {
        $s = Score $board ([string]$it.name)
        if ($s -gt $bs) { $bs = $s; $best = $it }
      }
      $err = ''
      break
    } catch {
      $err = $_.Exception.Message
      Start-Sleep -Milliseconds (1200 * $attempt)   # 1.2s, 2.4s
    }
  }
  if ($err) {
    $consecFail++
    $refused += [pscustomobject]@{ id = $id; why = ('search failed after 3 tries - LEFT ALONE, not recorded as absent: ' + $err.Substring(0, [math]::Min(60, $err.Length))) }
    if ($consecFail -ge 5) { $tripped = $true; Write-Output ''; Write-Output ("CIRCUIT BREAKER: 5 consecutive search failures - the store has walled us. Stopping at id " + $n + " of " + $viol.Count + " rather than hammering it.") }
    continue
  }
  $consecFail = 0
  Start-Sleep -Milliseconds 900   # Freshop pacing: concurrency 1, >=900ms (same rule the Aldi puller lives by)
  if (-not $best -or $bs -lt $MinScore) { $refused += [pscustomobject]@{ id = $id; why = ('no confident match (best ' + $bs + ')') }; continue }
  $curl = [string]$best.canonical_url
  if (-not $curl) { $refused += [pscustomobject]@{ id = $id; why = 'candidate has no canonical_url' }; continue }
  # the link's per-unit MUST agree with the board, or linking it just relocates the lie
  $sp = 0.0; [void][double]::TryParse((([string]$best.price) -replace '[^0-9.]', ''), [ref]$sp)
  $lpu = Get-LinkPerUnit -size ([string]$best.size) -unit $unit -price $sp -name ([string]$best.name)
  if ($null -eq $lpu -or $lpu -le 0) { $refused += [pscustomobject]@{ id = $id; why = ('match found but its size "' + [string]$best.size + '" gives no per-unit in ' + $unit) }; continue }
  $off = if ($bpu -gt 0) { [math]::Abs($lpu - $bpu) / $lpu } else { 1 }
  if ($off -gt 0.02 -and [math]::Abs($lpu - $bpu) -gt 0.005) {
    $refused += [pscustomobject]@{ id = $id; why = ('match found but per-unit disagrees: board $' + [math]::Round($bpu, 4) + ' vs link $' + [math]::Round($lpu, 4) + ' (' + [math]::Round($off * 100, 1) + '%)') }
    continue
  }
  $fixed += [pscustomobject]@{ id = $id; fault = [string]$v.fault; board = $board; board_pu = $bpu; name = [string]$best.name; url = $curl; price = ('$' + $sp); size = [string]$best.size; score = $bs }
  $n++
}
Write-Output ''
Write-Output ("  RESOLVED : " + $fixed.Count)
foreach ($f in ($fixed | Select-Object -First 12)) { Write-Output ("    + [" + $f.fault + "] " + $f.id.PadRight(22) + $f.name) }
Write-Output ("  REFUSED  : " + $refused.Count + "  (left exactly as they were)")
foreach ($r in ($refused | Select-Object -First 10)) { Write-Output ("    - " + $r.id.PadRight(22) + $r.why) }

# The plan IS the artifact under review. -Apply writes exactly these rows and nothing else.
$throttled = @($refused | Where-Object { $_.why -match 'search failed' }).Count
(@{
    generated = (Get-Date -Format 'yyyy-MM-dd HH:mm')
    board     = $cmpF.Name
    worked    = $viol.Count
    resolved  = $fixed
    refused   = $refused
  } | ConvertTo-Json -Depth 6) | Set-Content $planPath -Encoding UTF8
Write-Output ''
Write-Output ("plan written: out\ff-link-plan.json  (" + $fixed.Count + " resolution(s), " + $refused.Count + " refusal(s))")
if ($throttled -gt 0) {
  # A throttled id is UNKNOWN, not absent. Say so loudly: a run that got walled halfway is not a finished pass,
  # and quietly applying its partial output is how "review 55, write 8" happened in the first place.
  Write-Output ("WARNING: " + $throttled + " id(s) never got an answer (store refused). This plan is INCOMPLETE - re-run when the wall lifts.")
}
Write-Output 'Review the plan, then pass -Apply to write it verbatim (no re-searching).'
