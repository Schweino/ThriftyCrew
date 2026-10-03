# trial-ff-catalog-walk.ps1 - the PACED Family Fare catalog-walk trial (step 3b, R7.2) and its scorer.
# ---------------------------------------------------------------------------------------------------
# WHY. design\TRIAL-familyfare-catalog-walk-2026-09-10.md left two criteria at COULD NOT VERIFY: whether a search
# still works after a walk, and whether a full walk covers what the rotation buys. Brad ruled on 2026-10-03 (R7.2)
# to run a paced trial that answers both, then rule build or not. The rubric, the pacing and the steps are in
# design\TRIAL-familyfare-catalog-walk-paced-2026-10.md; this file is the instrument it names.
#
# THREE MODES.
#   -SelfTest                hermetic: frozen fixtures for the scorer and a fake server for the window logic.
#   -Window -Live -RunDir D  ONE live window against Freshop, then exit. Each call runs the next window the state in
#                            D says is due, or refuses (clock, gap, another Freshop caller, a recorded wall).
#   -Score -RunDir D         reads D's captured requests and raw bodies and writes D\verdict.json, one verdict per
#                            criterion with its denominator. Sends nothing.
# Family Fare capture is plain HTTP from PowerShell (pull-regular-familyfare.ps1's Get-FreshopItems), token-less,
# so the trial needs no browser and runs the same in a headless dispatch.
#
# WHERE IT WRITES. Only under -RunDir, which must sit OUTSIDE every git work tree (refused otherwise). Never a board,
# never grocery\out, never the cursor, the ledger or sale-windows.json.
#
# STOP RULES (enforced here, restated in the trial doc): the first 4xx ends the window; a 5xx or no response gets ONE
# retry after 30 s, and a second ends the window; a body that is not the API's JSON (an HTML page, a CAPTCHA, a
# challenge) or any 403 is a WALL: it stops the whole trial for good, is recorded as a verdict, and is never retried.
#
# SCOPE OF A CLEAN REPORT: the scorer is SOUND for what it reads (every verdict is computed from the captured rows and
# raw bodies, never from a count the runner kept) and INCOMPLETE as a build verdict: it scores this one night's
# windows, and whether Freshop behaves the same on another night is outside it.
#
#   .\trial-ff-catalog-walk.ps1 -SelfTest
#   .\trial-ff-catalog-walk.ps1 -Window -Live -RunDir "$env:LOCALAPPDATA\ThriftyCrew\trial-ff-walk\paced-2026-10"
#   .\trial-ff-catalog-walk.ps1 -Score -RunDir "$env:LOCALAPPDATA\ThriftyCrew\trial-ff-walk\paced-2026-10"
# Exit: 0 ran (read the FF-WALK-TRIAL-COMPLETE / FF-WALK-SCORE-COMPLETE line for what happened), 2 a WALL stopped
# the trial, 3 could not run (misuse, RunDir inside a repo, unreadable state or capture).
# ---------------------------------------------------------------------------------------------------
# The self-test reads only these libraries and writes only a per-run temp folder:
# gate-inputs: lib\json-io.ps1, lib\atomic-write.ps1, lib\append-line.ps1, lib\guard-contract.ps1
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop
param(
  [switch]$SelfTest,
  [switch]$Window,
  [switch]$Live,
  [switch]$Score,
  [string]$RunDir = '',
  [string]$EverydayFile = ''
)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repo = Split-Path -Parent $here
. (Join-Path $repo 'lib\json-io.ps1')
. (Join-Path $repo 'lib\atomic-write.ps1')
. (Join-Path $repo 'lib\append-line.ps1')
. (Join-Path $repo 'lib\guard-contract.ps1')

# ---- THE PLAN, IN NUMBERS (each one is restated with its reason in the trial doc) ---------------------------------
# First plausible values, none swept: the trial runs once.
$script:FfwCfg = @{
  Base          = 'https://api.freshop.ncrcloud.com/1'
  AppKey        = 'family_fare'
  StoreId       = '6401'
  DeptId        = '22585550'                     # the Sept trial's browse root; total is re-read, never assumed
  Fields        = 'id,name,size,price,base_price,unit_price,canonical_url'   # the builder's $FIELDS_RICH
  PageSize      = 100                            # the largest page a department browse honours (Sept: 200 and 500 clamp to 100)
  GapSec        = 5                              # end of one request to start of the next: at most 12 a minute
  RetrySec      = 30                             # the one retry on a 5xx or no response
  APages        = 30                             # window A walks this many distinct pages before its searches
  ASearches     = 20                             # the production per-window search ceiling (window_ceiling)
  WPagesMax     = 100                            # a later window walks at most this many pages
  MinGapMin     = 45                             # minutes from one window's end to the next one's start (hourly fires at :05)
  MaxWindows    = 6
  MaxRequests   = 450
  StartFrom     = 19                             # a window may START from 19:00 ...
  StartUntilMin = 270                            # ... until 04:30 (minutes after midnight), clear of the 06:30-17:15 tasks
  WSearchTerm   = 'milk gallon'                  # the Sept trial's follow-up search, so the two nights compare
  C1BarPct      = 99
  C3BarPct      = 95
}

# ---- PURE HELPERS ---------------------------------------------------------------------------------------------------
function Test-FfwInsideRepo {
  <# Is $Path inside any git work tree? Walks up looking for a .git entry (a linked worktree has a .git FILE). #>
  param([string]$Path)
  $p = [IO.Path]::GetFullPath($Path)
  while ($p) {
    if (Test-Path -LiteralPath (Join-Path $p '.git')) { return $true }
    $parent = [IO.Path]::GetDirectoryName($p)
    if (-not $parent -or [string]::Equals($parent, $p, [StringComparison]::OrdinalIgnoreCase)) { break }
    $p = $parent
  }
  return $false
}

function Get-FfwResponseClass {
  <# What did this one response say? ok | throttle | client-error | server-error | no-response | wall.
     A WALL is anything that is not the API answering: a 403, or a non-JSON body (an HTML page, a CAPTCHA, a
     challenge). The marker words are only read off a NON-JSON body, because "Challenge" is a butter brand and a
     product name must never stop the trial. #>
  param([int]$Status, [string]$Body)
  $isJson = $false
  $t = ([string]$Body).Trim()
  if ($t.StartsWith('{') -or $t.StartsWith('[')) { try { $null = $t | ConvertFrom-Json; $isJson = $true } catch { $isJson = $false } }
  if ($Status -eq 403) { return 'wall' }
  if ($t -and -not $isJson) {
    if ($t -match '(?i)captcha|challenge|are you a robot|access denied|perimeterx|cf-chl|verify you are human') { return 'wall' }
    if ($Status -eq 200) { return 'wall' }   # a 200 that is not the API's JSON: something else answered
  }
  if ($Status -eq 0) { return 'no-response' }
  if ($Status -ge 500) { return 'server-error' }
  if ($Status -ge 400) { if ($t -match '"error_code"\s*:\s*429') { return 'throttle' } else { return 'client-error' } }
  if ($Status -eq 200 -and $isJson) { return 'ok' }
  if ($Status -eq 200) { return 'wall' }   # an empty 200 is not an answer either
  return 'client-error'
}

function Test-FfwWindowAllowed {
  <# $null when a window may start now, else the reason it may not. Pure over the state and the clock. #>
  param($State, [datetime]$Now)
  $c = $script:FfwCfg
  if ($State.hard_stop) { return ('hard stop recorded: ' + [string]$State.hard_stop.reason) }
  if ($State.a_done -and [int]$State.total -gt 0 -and [int]$State.next_skip -ge [int]$State.total) { return 'trial complete: the walk reached total and window A ran' }
  $ran = @($State.windows).Count
  if ($ran -ge $c.MaxWindows) { return ("window cap reached: $ran of " + $c.MaxWindows) }
  if ([int]$State.requests -ge $c.MaxRequests) { return ("request cap reached: " + $State.requests + " of " + $c.MaxRequests) }
  $min = $Now.Hour * 60 + $Now.Minute
  $okClock = ($Now.Hour -ge $c.StartFrom) -or ($min -le $c.StartUntilMin)
  if (-not $okClock) { return ('outside the trial hours: ' + $Now.ToString('HH:mm') + ' (a window starts 19:00 to 04:30)') }
  if ($ran -gt 0) {
    $last = @($State.windows)[$ran - 1]
    $ended = [datetime]::Parse([string]$last.ended, [Globalization.CultureInfo]::InvariantCulture)
    $gap = ($Now - $ended).TotalMinutes
    if ($gap -lt $c.MinGapMin) { return ('too soon: ' + [int]$gap + ' min since the last window ended, the gap is ' + $c.MinGapMin) }
  }
  return $null
}

function Get-FfwSearchTerms {
  <# 20 terms spread evenly across the rotation's own term list (not its first 20, which all start with A). #>
  param([string[]]$All, [int]$Count)
  $distinct = New-Object 'System.Collections.Generic.List[string]'
  $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  foreach ($t in $All) { if ($t -and $seen.Add($t)) { $distinct.Add($t) } }
  $out = New-Object 'System.Collections.Generic.List[string]'
  if ($distinct.Count -eq 0) { return $out.ToArray() }
  for ($i = 0; $i -lt $Count; $i++) { $out.Add($distinct[[int][Math]::Floor($i * $distinct.Count / $Count)]) }
  return $out.ToArray()
}

function New-FfwState {
  return [pscustomobject]@{ created = (Get-Date).ToString('s'); windows = @(); next_skip = 0; total = 0; a_done = $false
    requests = 0; hard_stop = $null; search_terms = @(); page1_ids = @() }
}

# ---- ONE LIVE WINDOW (every outside effect goes through $Ctx, so the self-test drives it with a fake server) -------
function Invoke-FfwWindow {
  <# Runs the next window into $Ctx.RunDir and returns the window record. $Ctx carries: RunDir, State, Http
     (url -> @{status;body;ms}), Sleep (seconds), Clock (-> datetime), Terms (string[] for window A). #>
  param($Ctx)
  $c = $script:FfwCfg; $st = $Ctx.State
  $kind = if ($st.a_done) { 'W' } else { 'A' }
  $name = 'w' + (@($st.windows).Count + 1)
  $rec = [ordered]@{ name = $name; kind = $kind; started = (& $Ctx.Clock).ToString('s'); ended = ''; outcome = ''
    pages = 0; searches = 0; searches_ok = 0; requests = 0; skip_from = [int]$st.next_skip; skip_to = 0 }
  $raw = Join-Path $Ctx.RunDir 'raw'
  if (-not (Test-Path -LiteralPath $raw)) { New-Item -ItemType Directory -Force -Path $raw -ErrorAction Stop | Out-Null }
  $reqLog = Join-Path $Ctx.RunDir 'requests.jsonl'
  $script:FfwFirst = $true
  # A PAGE IS ONLY PROGRESS IF IT BRINGS NEW IDS (ff-price-lib.ps1 section 3; memory fail-open-reads-as-empty).
  # Freshop has answered its throttle as a 200 with an empty items array, and ignores page= and offset= by
  # returning page 1 again with a correct total. Both look like success, so the ids already read seed this set.
  $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  foreach ($old in (Read-FfwRequests $Ctx.RunDir)) {
    if ($old.class -ne 'ok' -or $old.phase -eq 'search') { continue }
    foreach ($it in @((Read-JsonFile (Join-Path $Ctx.RunDir ([string]$old.raw))).items)) { if ($it.id) { [void]$seen.Add([string]$it.id) } }
  }

  $send = {
    param([string]$Phase, [string]$Url, [int]$Skip, [string]$Term, [bool]$Check)
    if (-not $script:FfwFirst) { & $Ctx.Sleep $c.GapSec }
    $script:FfwFirst = $false
    $attempt = 0; $cls = ''; $resp = $null
    while ($true) {
      $attempt++
      $resp = & $Ctx.Http $Url
      $cls = Get-FfwResponseClass -Status ([int]$resp.status) -Body ([string]$resp.body)
      $st.requests = [int]$st.requests + 1; $rec.requests = [int]$rec.requests + 1
      $seq = [int]$st.requests
      $ext = if ($cls -eq 'wall' -or $cls -eq 'no-response') { 'txt' } else { 'json' }
      $rawName = ('{0}-{1:D3}.{2}' -f $name, $seq, $ext)
      [IO.File]::WriteAllText((Join-Path $raw $rawName), [string]$resp.body, (New-Object Text.UTF8Encoding($false)))
      $rows = 0; $total = 0; $ec = ''; $newIds = -1
      if ($cls -eq 'ok') {
        $j = ([string]$resp.body) | ConvertFrom-Json
        $rows = @($j.items).Count
        if ($j.PSObject.Properties['total']) { $total = [int]$j.total }
        if ($Phase -ne 'search') {
          $added = 0
          foreach ($it in @($j.items)) { if ($it.id -and $seen.Add([string]$it.id)) { $added++ } }
          if ($Check) { $newIds = $added }
        }
      }
      if ([string]$resp.body -match '"error_code"\s*:\s*(\d+)') { $ec = $Matches[1] }
      $row = [ordered]@{ seq = $seq; window = $name; win_kind = $kind; phase = $Phase; attempt = $attempt; skip = $Skip; term = $Term
        url = $Url; at = (& $Ctx.Clock).ToString('s'); ms = [int]$resp.ms; status = [int]$resp.status; error_code = $ec
        class = $cls; rows = $rows; new_ids = $newIds; total = $total; raw = ('raw/' + $rawName) }
      Add-TcLine -Path $reqLog -Text (([pscustomobject]$row) | ConvertTo-Json -Compress) | Out-Null
      if (($cls -eq 'server-error' -or $cls -eq 'no-response') -and $attempt -lt 2) { & $Ctx.Sleep $c.RetrySec; continue }
      break
    }
    return [pscustomobject]@{ cls = $cls; total = $total; rows = $rows; newIds = $newIds; seq = [int]$st.requests }
  }
  $browseUrl = { param([int]$s) ('{0}/products?app_key={1}&store_id={2}&department_id={3}&department_id_cascade=true&limit={4}&skip={5}&fields={6}' -f $c.Base, $c.AppKey, $c.StoreId, $c.DeptId, $c.PageSize, $s, $c.Fields) }
  $searchUrl = { param([string]$q) ('{0}/products?app_key={1}&store_id={2}&q={3}&limit=25&fields={4}' -f $c.Base, $c.AppKey, $c.StoreId, [uri]::EscapeDataString($q), $c.Fields) }
  $stopOn = { param($r) if ($r.cls -eq 'wall') { $st.hard_stop = [pscustomobject]@{ reason = 'wall'; seq = $r.seq; window = $name } } }

  # Page 1 opens every window: window A's first page, and a later window's ordering probe.
  $r = & $send 'probe' (& $browseUrl 0) 0 '' $false
  & $stopOn $r
  if ($r.cls -ne 'ok' -or [int]$r.rows -eq 0) {
    $rec.outcome = if ($r.cls -eq 'wall') { 'hard-stop-wall' } elseif ($r.cls -eq 'ok') { 'not-recovered:empty-200' } else { 'not-recovered:' + $r.cls }
  } else {
    if ($r.total -gt [int]$st.total) { $st.total = $r.total }
    if ($kind -eq 'A' -and [int]$st.next_skip -eq 0) { $rec.pages = 1; $st.next_skip = $c.PageSize }
    $cap = if ($kind -eq 'A') { $c.APages } else { $c.WPagesMax }
    $walkStop = ''
    while ([int]$rec.pages -lt $cap -and [int]$st.next_skip -lt [int]$st.total) {
      if ([int]$st.requests -ge $c.MaxRequests) { $walkStop = 'request-cap'; break }
      $r = & $send 'browse' (& $browseUrl ([int]$st.next_skip)) ([int]$st.next_skip) '' $true
      & $stopOn $r
      if ($r.cls -ne 'ok') { $walkStop = $r.cls; break }
      if ([int]$r.newIds -le 0) { $walkStop = 'no-progress'; break }   # an empty 200 or a repeated page: not an answer
      if ($r.total -gt [int]$st.total) { $st.total = $r.total }
      $rec.pages = [int]$rec.pages + 1; $st.next_skip = [int]$st.next_skip + $c.PageSize
    }
    $walked = ([int]$rec.pages -ge $cap) -or ([int]$st.next_skip -ge [int]$st.total)
    if ($walkStop -eq 'wall') { $rec.outcome = 'hard-stop-wall' }
    elseif ($walkStop -eq 'request-cap') { $rec.outcome = 'request-cap' }
    elseif ($kind -eq 'A' -and -not $walked) { $rec.outcome = 'a-walk-stopped:' + $walkStop }
    else {
      # The searches. Window A: the 20 rotation terms after a completed 30-page walk. A later window: ONE search
      # after its walk ends, whether a refusal or the page cap or the catalog's end ended it.
      $terms = if ($kind -eq 'A') { @($st.search_terms) } else { @($c.WSearchTerm) }
      $sStop = ''
      foreach ($t in $terms) {
        if ([int]$st.requests -ge $c.MaxRequests) { $sStop = 'request-cap'; break }
        $r = & $send 'search' (& $searchUrl $t) -1 $t $false
        & $stopOn $r
        $rec.searches = [int]$rec.searches + 1
        # An empty 200 is not counted as answered (it may be the throttle in disguise) but is not a 4xx, so the
        # searches go on; the scorer reports it apart.
        if ($r.cls -eq 'ok') { if ([int]$r.rows -gt 0) { $rec.searches_ok = [int]$rec.searches_ok + 1 } } else { $sStop = $r.cls; break }
      }
      if ($kind -eq 'A') { $st.a_done = $true }
      if ($sStop -eq 'wall') { $rec.outcome = 'hard-stop-wall' }
      elseif ($kind -eq 'A') { $rec.outcome = if ($sStop) { 'a-search-stopped:' + $sStop } else { 'a-complete' } }
      else { $rec.outcome = if ($walkStop) { 'browse-stopped:' + $walkStop } elseif ([int]$st.next_skip -ge [int]$st.total) { 'walk-finished' } else { 'window-page-cap' } }
    }
  }
  $rec.skip_to = [int]$st.next_skip
  $rec.ended = (& $Ctx.Clock).ToString('s')
  $st.windows = @(@($st.windows) + ,([pscustomobject]$rec))
  Write-TcAtomicFile -Path (Join-Path $Ctx.RunDir 'state.json') -Text ($st | ConvertTo-Json -Depth 6) -NoBom | Out-Null
  return [pscustomobject]$rec
}

# ---- THE SCORER ----------------------------------------------------------------------------------------------------
function Read-FfwRequests {
  param([string]$Dir)
  $p = Join-Path $Dir 'requests.jsonl'
  $rows = New-Object 'System.Collections.Generic.List[object]'
  if (-not (Test-Path -LiteralPath $p)) { return $rows.ToArray() }
  foreach ($ln in ((Read-TextFile $p) -split "`r?`n")) { if ($ln.Trim()) { $rows.Add(($ln | ConvertFrom-Json)) } }
  return $rows.ToArray()
}

function Get-FfwScore {
  <# One verdict per criterion, each with its numbers and the raw files it rests on. Pure over the inputs.
     Bars are compared as integers (found*100 >= bar*denominator), so an at-bar case is exact, never floating. #>
  param([object[]]$Requests, [string]$Dir, $Deals)
  $c = $script:FfwCfg
  $ids = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  $keys = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  $rowsRead = 0; $totalMax = 0; $page1 = @{}
  foreach ($q in $Requests) {
    if ($q.class -ne 'ok' -or $q.phase -eq 'search') { continue }
    if ([int]$q.total -gt $totalMax) { $totalMax = [int]$q.total }
    $j = Read-JsonFile (Join-Path $Dir ([string]$q.raw))
    $its = @($j.items)
    if ([int]$q.skip -eq 0) { $page1[[string]$q.window] = (@($its | ForEach-Object { [string]$_.id }) -join ',') }
    foreach ($it in $its) { $rowsRead++; if ($it.id) { [void]$ids.Add([string]$it.id) }; [void]$keys.Add(([string]$it.name + '|' + [string]$it.size)) }
  }
  # C1. Is the walk complete?
  $c1 = [ordered]@{ criterion = 'complete'; unique_ids = $ids.Count; total = $totalMax; rows_read = $rowsRead; bar_pct = $c.C1BarPct }
  if ($totalMax -le 0) { $c1.verdict = 'COULD NOT VERIFY'; $c1.why = 'no page answered with a total' }
  elseif ($ids.Count * 100 -ge $c.C1BarPct * $totalMax) { $c1.verdict = 'MET' }
  else { $c1.verdict = 'NOT MET' }
  $p1 = @($page1.Values); $p1First = if ($p1.Count) { [string]$p1[0] } else { '' }
  $c1.ordering_probe = ('page 1 identical in {0} of {1} window(s)' -f @($p1 | Where-Object { [string]::Equals([string]$_, $p1First, [StringComparison]::Ordinal) }).Count, $p1.Count)

  # C2. Does the rotation's search budget survive a 30-page walk in the same window?
  $c2 = [ordered]@{ criterion = 'follow-up search'; bar = ('{0} of {0} searches answered HTTP 200 after a {1}-page walk' -f $c.ASearches, $c.APages) }
  $aWins = @($Requests | Where-Object { $_.win_kind -eq 'A' } | ForEach-Object { [string]$_.window } | Select-Object -Unique)
  $qual = $null
  foreach ($w in $aWins) {
    $pg = @($Requests | Where-Object { $_.window -eq $w -and $_.phase -ne 'search' -and $_.class -eq 'ok' }).Count
    if ($pg -ge $c.APages) { $qual = $w; break }
  }
  if (-not $qual) { $c2.verdict = 'COULD NOT VERIFY'; $c2.why = ('no window A completed its {0}-page walk' -f $c.APages) }
  else {
    $srch = @($Requests | Where-Object { $_.window -eq $qual -and $_.phase -eq 'search' })
    $final = @($srch | Group-Object term | ForEach-Object { @($_.Group)[-1] })   # a retried search is judged on its last answer
    # ANSWERED means HTTP 200 WITH ROWS. The terms are ones that found rows for the rotation, and Freshop has
    # answered its throttle as an empty 200, so an empty answer is counted apart, never as answered.
    $ok = @($final | Where-Object { $_.class -eq 'ok' -and [int]$_.rows -gt 0 }).Count
    $empty = @($final | Where-Object { $_.class -eq 'ok' -and [int]$_.rows -eq 0 }).Count
    $refused = @($final | Where-Object { $_.class -eq 'throttle' -or $_.class -eq 'client-error' })
    $c2.window = $qual; $c2.answered = $ok; $c2.empty_200 = $empty; $c2.of = $c.ASearches
    $c2.evidence = @($final | ForEach-Object { [string]$_.raw })
    if ($ok -ge $c.ASearches) { $c2.verdict = 'MET' }
    elseif ($refused.Count) { $c2.verdict = 'NOT MET'; $c2.first_refusal = ('{0} ({1} {2})' -f $refused[0].raw, $refused[0].status, $refused[0].error_code) }
    else { $c2.verdict = 'COULD NOT VERIFY'; $c2.why = ('{0} of {1} answered with rows, {2} empty 200, none refused: an empty answer cannot be told from a disguised throttle, and a server error or a cap ends a window' -f $ok, $c.ASearches, $empty) }
  }
  # Secondary, reported and not barred: does a search still answer after the walk in a LATER window, above all
  # after a browse refusal? That separates "browse spends the search allowance" from "browse has its own".
  $wS = @($Requests | Where-Object { $_.win_kind -eq 'W' -and $_.phase -eq 'search' })
  $afterRefusal = 0; $afterRefusalOk = 0
  foreach ($s in $wS) {
    $prev = @($Requests | Where-Object { $_.window -eq $s.window -and $_.phase -eq 'browse' -and [int]$_.seq -lt [int]$s.seq } | Sort-Object { [int]$_.seq })
    if ($prev.Count -and @($prev)[-1].class -eq 'throttle') { $afterRefusal++; if ($s.class -eq 'ok' -and [int]$s.rows -gt 0) { $afterRefusalOk++ } }
  }
  $c2.later_windows = ('{0} of {1} post-walk search(es) answered with rows; {2} of {3} after a browse refusal' -f @($wS | Where-Object { $_.class -eq 'ok' -and [int]$_.rows -gt 0 }).Count, $wS.Count, $afterRefusalOk, $afterRefusal)
  $c2.shared_allowance = if ($afterRefusal -eq 0) { 'COULD NOT VERIFY (no browse refusal was followed by a search)' } elseif ($afterRefusalOk -eq $afterRefusal) { 'no: search answered after every browse refusal' } elseif ($afterRefusalOk -eq 0) { 'yes: search was refused after every browse refusal' } else { 'mixed' }

  # C3. Does the walk cover what the rotation buys? Population: everyday rows that carry a product id.
  $withId = @($Deals | Where-Object { $_.product_id })
  $found = @($withId | Where-Object { $ids.Contains([string]$_.product_id) }).Count
  $noId = @($Deals | Where-Object { -not $_.product_id })
  $noIdFound = @($noId | Where-Object { $keys.Contains(([string]$_.item + '|' + [string]$_.size)) }).Count
  $c3 = [ordered]@{ criterion = 'covers the rotation'; found_by_id = $found; of = $withId.Count; bar_pct = $c.C3BarPct
    rows_without_id = ('{0} of {1} found by name|size (not identity, reported only)' -f $noIdFound, $noId.Count) }
  $byTerm = @($withId | Where-Object { $_.found_by_term } | Group-Object found_by_term)
  $tAny = @($byTerm | Where-Object { @($_.Group | Where-Object { $ids.Contains([string]$_.product_id) }).Count -gt 0 }).Count
  $tAll = @($byTerm | Where-Object { @($_.Group | Where-Object { -not $ids.Contains([string]$_.product_id) }).Count -eq 0 }).Count
  $c3.per_term = ('{0} of {1} terms have a row in the walk; {2} have every row' -f $tAny, $byTerm.Count, $tAll)
  $c3.unfound_sample = @($withId | Where-Object { -not $ids.Contains([string]$_.product_id) } | Select-Object -First 10 | ForEach-Object { [string]$_.product_id + ' ' + [string]$_.item })
  if ($withId.Count -eq 0) { $c3.verdict = 'COULD NOT VERIFY'; $c3.why = 'no everyday row carries a product id' }
  elseif ($found * 100 -ge $c.C3BarPct * $withId.Count) { $c3.verdict = 'MET' }
  elseif ($c1.verdict -eq 'MET') { $c3.verdict = 'NOT MET' }
  else { $c3.verdict = 'COULD NOT VERIFY'; $c3.why = ('the walk is incomplete, so {0} of {1} is a lower bound' -f $found, $withId.Count) }
  return [pscustomobject]@{ c1 = [pscustomobject]$c1; c2 = [pscustomobject]$c2; c3 = [pscustomobject]$c3; requests = @($Requests).Count }
}

# =====================================================================================================================
if ($SelfTest) {
  $script:f = 0; $script:n = 0
  function T([string]$name, [bool]$ok, [string]$got) {
    $script:n++
    if ($ok) { Write-Output "  ok    $name" } else { $script:f++; Write-Output "  FAIL  $name  (got: $got)" }
  }
  $tmp = Join-Path $env:TEMP ('ffw-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Force -Path $tmp -ErrorAction Stop | Out-Null
  $script:fx = 0
  function New-FxDir { $script:fx++; $d = Join-Path $tmp ('d' + $script:fx); New-Item -ItemType Directory -Force -Path (Join-Path $d 'raw') -ErrorAction Stop | Out-Null; return $d }
  function New-PageBody([int]$From, [int]$Count, [int]$Total) {
    $items = New-Object 'System.Collections.Generic.List[object]'
    for ($i = $From; $i -lt $From + $Count; $i++) { $items.Add([pscustomobject]@{ id = [string]$i; name = ('Item ' + $i); size = '1 ct'; price = '1.00' }) }
    return ([pscustomobject]@{ total = $Total; items = $items.ToArray() } | ConvertTo-Json -Depth 4 -Compress)
  }
  # A frozen capture: window w1 (A) walks $Pages pages of a $Total catalog, then $SearchOk HTTP 200 searches (the
  # last $SearchEmpty of them with no rows) and $SearchRefused refused ones; ids in $Drop are left out of the pages.
  function New-FxCapture([string]$Dir, [int]$Total, [int]$Pages, [int]$SearchOk, [int]$SearchRefused, [int[]]$Drop = @(), [int]$SearchEmpty = 0) {
    $seq = 0; $lines = New-Object 'System.Collections.Generic.List[string]'
    for ($p = 0; $p -lt $Pages; $p++) {
      $seq++; $from = $p * 100; $cnt = [Math]::Min(100, $Total - $from)
      $body = New-PageBody $from $cnt $Total
      if ($Drop.Count) { $o = $body | ConvertFrom-Json; $o.items = @($o.items | Where-Object { $Drop -notcontains [int]$_.id }); $body = $o | ConvertTo-Json -Depth 4 -Compress }
      $rn = ('raw/w1-{0:D3}.json' -f $seq); [IO.File]::WriteAllText((Join-Path $Dir $rn), $body)
      $ph = if ($p -eq 0) { 'probe' } else { 'browse' }
      $lines.Add(([pscustomobject]@{ seq = $seq; window = 'w1'; win_kind = 'A'; phase = $ph; skip = $from; term = ''; class = 'ok'; status = 200; error_code = ''; total = $Total; raw = $rn } | ConvertTo-Json -Compress))
    }
    for ($s = 0; $s -lt ($SearchOk + $SearchRefused); $s++) {
      $seq++; $ok = $s -lt $SearchOk
      $rn = ('raw/w1-{0:D3}.json' -f $seq)
      $body = if ($ok) { '{"total":1,"items":[{"id":"x"}]}' } else { '{"error_code":429}' }
      [IO.File]::WriteAllText((Join-Path $Dir $rn), $body)
      $cls = if ($ok) { 'ok' } else { 'throttle' }; $sc = if ($ok) { 200 } else { 400 }; $ec = if ($ok) { '' } else { '429' }
      $rws = if ($ok -and $s -ge $SearchOk - $SearchEmpty) { 0 } elseif ($ok) { 1 } else { 0 }
      $lines.Add(([pscustomobject]@{ seq = $seq; window = 'w1'; win_kind = 'A'; phase = 'search'; skip = -1; term = ('t' + $s); class = $cls; status = $sc; error_code = $ec; rows = $rws; total = 0; raw = $rn } | ConvertTo-Json -Compress))
    }
    [IO.File]::WriteAllText((Join-Path $Dir 'requests.jsonl'), (($lines.ToArray()) -join "`n"))
  }
  # Everyday rows: $InCatalog ids from the catalog, $Missing ids that are not in it, all carrying a term.
  function New-FxDeals([int]$InCatalog, [int]$Missing) {
    $d = New-Object 'System.Collections.Generic.List[object]'
    for ($i = 0; $i -lt $InCatalog; $i++) { $d.Add([pscustomobject]@{ product_id = [string]($i * 7); item = ('Item ' + ($i * 7)); size = '1 ct'; found_by_term = ('term' + ($i % 4)) }) }
    for ($i = 0; $i -lt $Missing; $i++) { $d.Add([pscustomobject]@{ product_id = [string](900000 + $i); item = 'Gone'; size = '1 ct'; found_by_term = 'term-gone' }) }
    return $d.ToArray()
  }
  function Get-FxScore([string]$Dir, $Deals) { $rq = Read-FfwRequests $Dir; return (Get-FfwScore -Requests $rq -Dir $Dir -Deals $Deals) }

  try {
    # ---- the scorer -------------------------------------------------------------------------------------------------
    $d = New-FxDir; New-FxCapture $d 400 30 20 0
    $sc = Get-FxScore $d (New-FxDeals 20 0)
    T 'CLEAN TWIN  a complete walk, 20 of 20 searches and every rotation row found scores MET on all three' ((($sc.c1.verdict -eq 'MET') -and ($sc.c2.verdict -eq 'MET')) -and ($sc.c3.verdict -eq 'MET')) ("$($sc.c1.verdict)/$($sc.c2.verdict)/$($sc.c3.verdict)")
    T 'CLEAN TWIN  C1 counts every unique id against the total it read' ((([int]$sc.c1.unique_ids -eq 400) -and ([int]$sc.c1.total -eq 400))) ("$($sc.c1.unique_ids) of $($sc.c1.total)")

    $sc = Get-FxScore $d (New-FxDeals 18 2)
    T 'MUST FIRE  a complete walk missing rotation rows scores C3 NOT MET (18 of 20, one step past the 95% bar)' (($sc.c3.verdict -eq 'NOT MET') -and ([int]$sc.c3.found_by_id -eq 18)) ("$($sc.c3.verdict) $($sc.c3.found_by_id) of $($sc.c3.of)")
    T 'MUST FIRE  the missing rows name their term in the per-term count' (([string]$sc.c3.per_term) -match '^4 of 5 terms') ([string]$sc.c3.per_term)

    $sc = Get-FxScore $d (New-FxDeals 19 1)
    T 'AT BAR  19 of 20 rotation rows found is exactly the 95% bar and scores C3 MET' ($sc.c3.verdict -eq 'MET') ("$($sc.c3.verdict) $($sc.c3.found_by_id) of $($sc.c3.of)")

    $d = New-FxDir; New-FxCapture $d 400 30 19 1
    $sc = Get-FxScore $d (New-FxDeals 20 0)
    T 'MUST FIRE  19 answered and one refused (one step past the 20 of 20 bar) scores C2 NOT MET and names the refusal' (($sc.c2.verdict -eq 'NOT MET') -and (([string]$sc.c2.first_refusal) -match '429')) ("$($sc.c2.verdict) $($sc.c2.first_refusal)")

    $d = New-FxDir; New-FxCapture $d 4000 12 0 0
    $sc = Get-FxScore $d (New-FxDeals 20 0)
    T 'MUST FIRE  a window A that never finished its 30-page walk leaves C2 at COULD NOT VERIFY' ($sc.c2.verdict -eq 'COULD NOT VERIFY') ([string]$sc.c2.verdict)
    T 'MUST NOT FIRE  an incomplete walk whose rows still clear the C3 bar scores C3 MET (a lower bound can prove MET)' ((($sc.c1.verdict -eq 'NOT MET') -and ($sc.c3.verdict -eq 'MET'))) ("$($sc.c1.verdict)/$($sc.c3.verdict)")
    $sc = Get-FxScore $d (New-FxDeals 15 5)
    T 'MUST FIRE  an incomplete walk under the C3 bar is COULD NOT VERIFY with a lower bound, never NOT MET' (($sc.c3.verdict -eq 'COULD NOT VERIFY') -and (([string]$sc.c3.why) -match 'lower bound')) ("$($sc.c3.verdict) $($sc.c3.why)")

    $d = New-FxDir; New-FxCapture $d 400 30 20 0 @(396, 397, 398, 399)
    $sc = Get-FxScore $d (New-FxDeals 20 0)
    T 'AT BAR  396 unique ids of a 400 total is exactly the 99% bar and scores C1 MET' (($sc.c1.verdict -eq 'MET') -and ([int]$sc.c1.unique_ids -eq 396)) ("$($sc.c1.verdict) $($sc.c1.unique_ids)")
    $d = New-FxDir; New-FxCapture $d 400 30 20 0 @(395, 396, 397, 398, 399)
    $sc = Get-FxScore $d (New-FxDeals 20 0)
    T 'MUST FIRE  395 of 400 (one id past the 99% bar) scores C1 NOT MET' (($sc.c1.verdict -eq 'NOT MET') -and ([int]$sc.c1.unique_ids -eq 395)) ("$($sc.c1.verdict) $($sc.c1.unique_ids)")

    # ---- the response classes -----------------------------------------------------------------------------------------
    T 'MUST FIRE  an HTML CAPTCHA page is a wall' ((Get-FfwResponseClass -Status 200 -Body '<html><div id="px-captcha">') -eq 'wall') 'class'
    T 'MUST FIRE  a 403 is a wall whatever its body' ((Get-FfwResponseClass -Status 403 -Body '{"error_code":403}') -eq 'wall') 'class'
    T 'MUST FIRE  a 400 carrying error_code 429 is the throttle' ((Get-FfwResponseClass -Status 400 -Body '{"error_code":429}') -eq 'throttle') 'class'
    T 'MUST NOT FIRE  a JSON 200 holding a product called Challenge Butter is ok, not a wall' ((Get-FfwResponseClass -Status 200 -Body '{"total":1,"items":[{"name":"Challenge Butter"}]}') -eq 'ok') 'class'

    # ---- the window, against a fake server ---------------------------------------------------------------------------
    function New-FxCtx([string]$Dir, $State, [int]$Total, [int]$RefuseAt, [string]$WallAt, [int]$FlakeAt, [hashtable]$At = @{}) {
      $script:fxCalls = New-Object 'System.Collections.Generic.List[string]'
      $script:fxSleeps = New-Object 'System.Collections.Generic.List[int]'
      $script:fxClock = [datetime]'2026-10-05T20:05:00'
      $script:fxTotal = $Total; $script:fxRefuseAt = $RefuseAt; $script:fxWallAt = $WallAt; $script:fxFlakeAt = $FlakeAt; $script:fxAt = $At
      return [pscustomobject]@{ RunDir = $Dir; State = $State
        Clock = { $script:fxClock }
        Sleep = { param($s) $script:fxSleeps.Add([int]$s); $script:fxClock = $script:fxClock.AddSeconds($s) }
        Http  = { param($u)
          $script:fxCalls.Add($u); $k = $script:fxCalls.Count
          if ($script:fxAt.ContainsKey($k)) { return @{ status = 200; body = [string]$script:fxAt[$k]; ms = 5 } }
          if ($script:fxWallAt -and $k -eq [int]$script:fxWallAt) { return @{ status = 200; body = '<html>verify you are human</html>'; ms = 5 } }
          if ($script:fxFlakeAt -and $k -eq $script:fxFlakeAt) { return @{ status = 503; body = ''; ms = 5 } }
          if ($script:fxRefuseAt -and $k -ge $script:fxRefuseAt -and $u -notmatch '&q=') { return @{ status = 400; body = '{"error_code":429}'; ms = 5 } }
          if ($u -match '&q=') { return @{ status = 200; body = '{"total":1,"items":[{"id":"s1","name":"Milk","size":"1 gal"}]}'; ms = 5 } }
          $sk = 0; if ($u -match 'skip=(\d+)') { $sk = [int]$Matches[1] }
          return @{ status = 200; body = (New-PageBody $sk ([Math]::Min(100, $script:fxTotal - $sk)) $script:fxTotal); ms = 5 } } }
    }
    $d = New-FxDir; $st = New-FfwState; $st.search_terms = @(1..20 | ForEach-Object { 'term ' + $_ })
    $ctx = New-FxCtx $d $st 5000 0 '' 0
    $w = Invoke-FfwWindow $ctx
    $q = @($script:fxCalls | Where-Object { $_ -match '&q=' }).Count
    T 'CLEAN TWIN  window A walks 30 distinct pages, then sends the 20 searches, and records a-complete' ((($w.outcome -eq 'a-complete') -and ([int]$w.pages -eq 30)) -and ($q -eq 20) -and ([int]$st.next_skip -eq 3000) -and $st.a_done) ("$($w.outcome) pages=$($w.pages) q=$q next=$($st.next_skip)")
    T 'CLEAN TWIN  every request after the first waits the 5 s gap first (49 gaps for 50 requests)' ((@($script:fxSleeps | Where-Object { $_ -eq 5 }).Count -eq 49) -and ($script:fxCalls.Count -eq 50)) ("gaps=$(@($script:fxSleeps | Where-Object { $_ -eq 5 }).Count) calls=$($script:fxCalls.Count)")
    $rq = Read-FfwRequests $d
    T 'CLEAN TWIN  every request is kept as a row with its raw body on disk' ((@($rq).Count -eq 50) -and (Test-Path -LiteralPath (Join-Path $d ([string]@($rq)[49].raw)))) ("rows=$(@($rq).Count)")

    $endA = [datetime]::Parse([string]@($st.windows)[0].ended, [Globalization.CultureInfo]::InvariantCulture)
    T 'AT BAR  exactly 45 min after the last window ended, the gap bar, a window is allowed' ($null -eq (Test-FfwWindowAllowed -State $st -Now $endA.AddMinutes(45))) ([string](Test-FfwWindowAllowed -State $st -Now $endA.AddMinutes(45)))
    T 'MUST FIRE  44 min after (one minute short of the 45-min bar) is refused as too soon' ((([string](Test-FfwWindowAllowed -State $st -Now $endA.AddMinutes(44))) -match '^too soon')) ([string](Test-FfwWindowAllowed -State $st -Now $endA.AddMinutes(44)))
    $script:fxClock = $script:fxClock.AddMinutes(30)
    T 'MUST FIRE  a window 30 min after the last one ended is refused as too soon' ((([string](Test-FfwWindowAllowed -State $st -Now $script:fxClock)) -match '^too soon')) ([string](Test-FfwWindowAllowed -State $st -Now $script:fxClock))
    T 'MUST FIRE  a window at 10:00 is refused as outside the trial hours' ((([string](Test-FfwWindowAllowed -State $st -Now ([datetime]'2026-10-06T10:00:00'))) -match '^outside the trial hours')) 'clock'
    T 'MUST NOT FIRE  a window 61 min after the last one, at night, is allowed' ($null -eq (Test-FfwWindowAllowed -State $st -Now ([datetime]'2026-10-05T21:30:00'))) ([string](Test-FfwWindowAllowed -State $st -Now ([datetime]'2026-10-05T21:30:00')))

    # A later window refused at its 6th call: the walk stops at once and exactly one search follows.
    $ctx = New-FxCtx $d $st 5000 6 '' 0
    $w = Invoke-FfwWindow $ctx
    $browseAfter = 0; $seenRefusal = $false
    foreach ($u in $script:fxCalls) { if ($u -match '&q=') { continue }; if ($seenRefusal) { $browseAfter++ }; if ($u -match 'skip=' -and $script:fxCalls.IndexOf($u) -ge 5) { $seenRefusal = $true } }
    $q = @($script:fxCalls | Where-Object { $_ -match '&q=' }).Count
    T 'MUST FIRE  a browse 429 ends the walk at once: no browse after it, then exactly one search' ((($w.outcome -eq 'browse-stopped:throttle') -and ($script:fxCalls.Count -eq 7)) -and ($q -eq 1) -and ($browseAfter -eq 0)) ("$($w.outcome) calls=$($script:fxCalls.Count) q=$q")
    T 'CLEAN TWIN  the refused page is not counted: the walk resumes at the page that was refused' ([int]$st.next_skip -eq 3400) ([string]$st.next_skip)
    $sc = Get-FfwScore -Requests (Read-FfwRequests $d) -Dir $d -Deals (New-FxDeals 5 0)
    T 'CLEAN TWIN  the scorer reads the post-refusal search as evidence that search survives a browse refusal' (([string]$sc.c2.shared_allowance) -match '^no:') ([string]$sc.c2.shared_allowance)

    # A wall stops everything and is never retried.
    $d = New-FxDir; $st = New-FfwState; $st.search_terms = @('a', 'b')
    $ctx = New-FxCtx $d $st 5000 0 '3' 0
    $w = Invoke-FfwWindow $ctx
    T 'MUST FIRE  a CAPTCHA page stops the trial on that request: no further request, a hard stop recorded' ((($w.outcome -eq 'hard-stop-wall') -and ($script:fxCalls.Count -eq 3)) -and ($st.hard_stop.reason -eq 'wall')) ("$($w.outcome) calls=$($script:fxCalls.Count)")
    T 'MUST FIRE  after a wall every later window is refused' ((([string](Test-FfwWindowAllowed -State $st -Now ([datetime]'2026-10-06T01:00:00'))) -match '^hard stop')) 'refusal'

    # A 503 gets one retry after 30 s, and the walk carries on.
    $d = New-FxDir; $st = New-FfwState; $st.search_terms = @('a')
    $ctx = New-FxCtx $d $st 5000 0 '' 2
    $w = Invoke-FfwWindow $ctx
    T 'CLEAN TWIN  one 503 is retried once after 30 s and the window still completes' ((($w.outcome -eq 'a-complete') -and (@($script:fxSleeps | Where-Object { $_ -eq 30 }).Count -eq 1)) -and ([int]$w.pages -eq 30)) ("$($w.outcome) retries=$(@($script:fxSleeps | Where-Object { $_ -eq 30 }).Count)")

    # A page that brings no new ids is not progress: an empty 200 mid-walk, and an ignored skip= repeating page 1.
    $d = New-FxDir; $st = New-FfwState; $st.search_terms = @('a')
    $ctx = New-FxCtx $d $st 5000 0 '' 0 @{ 4 = '{"total":5000,"items":[]}' }
    $w = Invoke-FfwWindow $ctx
    T 'MUST FIRE  an empty 200 mid-walk stops window A as no-progress and is not counted as a page' ((($w.outcome -eq 'a-walk-stopped:no-progress') -and ([int]$w.pages -eq 3)) -and ([int]$st.next_skip -eq 300) -and ($script:fxCalls.Count -eq 4)) ("$($w.outcome) pages=$($w.pages) next=$($st.next_skip) calls=$($script:fxCalls.Count)")
    $d = New-FxDir; $st = New-FfwState; $st.search_terms = @('a')
    $ctx = New-FxCtx $d $st 5000 0 '' 0 @{ 3 = (New-PageBody 0 100 5000) }
    $w = Invoke-FfwWindow $ctx
    T 'MUST FIRE  a page repeating ids already read (an ignored skip=) stops the walk as no-progress' (($w.outcome -eq 'a-walk-stopped:no-progress') -and ([int]$st.next_skip -eq 200)) ("$($w.outcome) next=$($st.next_skip)")
    $d = New-FxDir; New-FxCapture $d 400 30 20 0 @() 1
    $sc = Get-FxScore $d (New-FxDeals 20 0)
    T 'MUST FIRE  19 searches with rows and one empty 200 is COULD NOT VERIFY, never MET (an empty answer may be the throttle)' ((($sc.c2.verdict -eq 'COULD NOT VERIFY') -and ([int]$sc.c2.answered -eq 19)) -and ([int]$sc.c2.empty_200 -eq 1)) ("$($sc.c2.verdict) answered=$($sc.c2.answered) empty=$($sc.c2.empty_200)")

    T 'MUST FIRE  a run folder inside a git work tree is refused' (Test-FfwInsideRepo (Join-Path $repo 'grocery\out')) 'inside'
    T 'MUST NOT FIRE  a temp folder outside every repo is accepted' (-not (Test-FfwInsideRepo $tmp)) 'outside'
  } catch { $script:f++; Write-Output ('  FAIL  threw: ' + $_.Exception.Message + ' at line ' + $_.InvocationInfo.ScriptLineNumber) }
  finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
  if ($script:n -ne 34) { $script:f++; Write-Output "  FAIL  ran $($script:n) of 34 cases" }
  if ($script:f) { Write-Output ("trial-ff-catalog-walk self-test FAIL: {0} check(s)" -f $script:f); exit 1 }
  Write-Output 'trial-ff-catalog-walk self-test pass: 34 cases (19 must-fire, 4 must-not-fire, 8 clean twin, 3 at-bar)'
  exit 0
}

# =====================================================================================================================
if (-not $RunDir) { $RunDir = Join-Path $env:LOCALAPPDATA 'ThriftyCrew\trial-ff-walk\paced-2026-10' }
if (Test-FfwInsideRepo $RunDir) { Exit-Guard -Name 'ff-walk-trial' -Code 3 -Summary ("refused: RunDir is inside a git work tree: $RunDir") }

if ($Score) {
  $rq = Read-FfwRequests $RunDir
  if (@($rq).Count -eq 0) { Exit-Guard -Name 'ff-walk-score' -Code 3 -Summary ("could not evaluate: no requests.jsonl rows under $RunDir") }
  if (-not $EverydayFile) {
    $ev = @(Get-ChildItem -LiteralPath (Join-Path $repo 'grocery\out\regular') -Filter 'family-fare-regular-*.json' -ErrorAction SilentlyContinue | Sort-Object Name)
    if ($ev.Count) { $EverydayFile = $ev[$ev.Count - 1].FullName }
  }
  if (-not $EverydayFile -or -not (Test-Path -LiteralPath $EverydayFile)) { Exit-Guard -Name 'ff-walk-score' -Code 3 -Summary 'could not evaluate: no Family Fare everyday file (pass -EverydayFile)' }
  $evDoc = Read-JsonFile $EverydayFile
  $deals = @($evDoc.deals)
  $res = Get-FfwScore -Requests $rq -Dir $RunDir -Deals $deals
  $out = [ordered]@{ scored_at = (Get-Date).ToString('s'); everyday_file = $EverydayFile
    everyday_sha256 = (Get-FileHash -LiteralPath $EverydayFile -Algorithm SHA256).Hash; everyday_rows = $deals.Count
    harness = 'grocery/trial-ff-catalog-walk.ps1'; harness_blob = ''; requests = $res.requests; c1 = $res.c1; c2 = $res.c2; c3 = $res.c3 }
  try { $out.harness_blob = [string](& git -C $repo hash-object (Join-Path $here 'trial-ff-catalog-walk.ps1')) } catch { }
  Write-TcAtomicFile -Path (Join-Path $RunDir 'verdict.json') -Text (([pscustomobject]$out) | ConvertTo-Json -Depth 6) -NoBom | Out-Null
  Write-Output ('C1 complete:            {0}  {1} unique ids of total {2} (bar {3}%); {4}' -f $res.c1.verdict, $res.c1.unique_ids, $res.c1.total, $res.c1.bar_pct, $res.c1.ordering_probe)
  Write-Output ('C2 follow-up search:    {0}  {1}' -f $res.c2.verdict, $(if ($res.c2.PSObject.Properties['answered']) { "$($res.c2.answered) of $($res.c2.of) answered after a 30-page walk in $($res.c2.window)" } else { [string]$res.c2.why }))
  Write-Output ('    later windows:      {0}; shared allowance: {1}' -f $res.c2.later_windows, $res.c2.shared_allowance)
  Write-Output ('C3 covers the rotation: {0}  {1} of {2} id-bearing everyday rows found (bar {3}%); {4}' -f $res.c3.verdict, $res.c3.found_by_id, $res.c3.of, $res.c3.bar_pct, $res.c3.per_term)
  Write-Output ('verdict: ' + (Join-Path $RunDir 'verdict.json'))
  Exit-Guard -Name 'ff-walk-score' -Code 0 -Summary ('requests={0} c1={1} c2={2} c3={3}' -f $res.requests, ($res.c1.verdict -replace ' ', '-'), ($res.c2.verdict -replace ' ', '-'), ($res.c3.verdict -replace ' ', '-'))
}

if ($Window) {
  if (-not $Live) { Exit-Guard -Name 'ff-walk-trial' -Code 3 -Summary 'refused: -Window sends live requests to Freshop and needs -Live as well' }
  New-Item -ItemType Directory -Force -Path $RunDir -ErrorAction Stop | Out-Null
  $stPath = Join-Path $RunDir 'state.json'
  $st = if (Test-Path -LiteralPath $stPath) { Read-JsonFile $stPath } else { New-FfwState }
  $why = Test-FfwWindowAllowed -State $st -Now (Get-Date)
  if ($why) {
    $code = if ($st.hard_stop) { 2 } else { 0 }
    Exit-Guard -Name 'ff-walk-trial' -Code $code -Summary ("skipped: $why")
  }
  # No other Freshop caller may run beside a window: the trial must neither starve the rotation nor be starved by it.
  $others = @(Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match 'pull-regular-familyfare|familyfare-sweep|probe-ingredient|hunt-daemon|capture-run\.ps1' -and $_.ProcessId -ne $PID })
  if ($others.Count) { Exit-Guard -Name 'ff-walk-trial' -Code 0 -Summary ("skipped: another Freshop caller is running (pid " + (($others | ForEach-Object { $_.ProcessId }) -join ',') + ')') }
  # Lock order 0: the capture-run mutex, zero wait, so no capture run can start a Family Fare pull mid-window.
  $mx = New-Object System.Threading.Mutex($false, 'Global\tc-capture-run')
  $held = $false
  try { $held = $mx.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $held = $true }
  if (-not $held) { $mx.Dispose(); Exit-Guard -Name 'ff-walk-trial' -Code 0 -Summary 'skipped: Global\tc-capture-run is held' }
  try {
    if (-not @($st.search_terms).Count) {
      # Terms that FOUND ROWS for the rotation (found_by_term on the newest everyday file), spread evenly, so an
      # empty answer is suspicious rather than expected. commodity-search.json's primary terms are the fallback.
      $all = @()
      $ev = @(Get-ChildItem -LiteralPath (Join-Path $repo 'grocery\out\regular') -Filter 'family-fare-regular-*.json' -ErrorAction SilentlyContinue | Sort-Object Name)
      if ($ev.Count) { $all = @(@((Read-JsonFile $ev[$ev.Count - 1].FullName).deals) | Where-Object { $_.found_by_term } | ForEach-Object { [string]$_.found_by_term } | Sort-Object -Unique) }
      if (-not $all.Count) {
        . (Join-Path $repo 'grocery\search-terms-lib.ps1')
        $pairs = Get-SearchTermPairs ((Read-JsonFile (Join-Path $repo 'grocery\commodity-search.json')).terms)
        $all = @($pairs | Where-Object { $_.primary } | ForEach-Object { [string]$_.term })
      }
      $picked = Get-FfwSearchTerms -All $all -Count $script:FfwCfg.ASearches
      $st.search_terms = @($picked)
    }
    $http = {
      param([string]$u)
      $sw = [Diagnostics.Stopwatch]::StartNew()
      try {
        $resp = Invoke-WebRequest -Uri $u -Headers @{ 'User-Agent' = 'Mozilla/5.0' } -UseBasicParsing -TimeoutSec 25
        return @{ status = [int]$resp.StatusCode; body = [string]$resp.Content; ms = [int]$sw.ElapsedMilliseconds }
      } catch {
        $sc = 0; try { if ($_.Exception.Response) { $sc = [int]$_.Exception.Response.StatusCode } } catch { }
        $b = ''; try { $b = [string]$_.ErrorDetails.Message } catch { }
        return @{ status = $sc; body = $b; ms = [int]$sw.ElapsedMilliseconds }
      }
    }
    $ctx = [pscustomobject]@{ RunDir = $RunDir; State = $st; Http = $http; Sleep = { param($s) Start-Sleep -Seconds $s }; Clock = { Get-Date } }
    $w = Invoke-FfwWindow $ctx
  } finally { $mx.ReleaseMutex(); $mx.Dispose() }
  $code = if ($st.hard_stop) { 2 } else { 0 }
  Exit-Guard -Name 'ff-walk-trial' -Code $code -Summary ('window={0} kind={1} outcome={2} pages={3} searches_ok={4}/{5} requests={6} next_skip={7} total={8}' -f $w.name, $w.kind, $w.outcome, $w.pages, $w.searches_ok, $w.searches, $w.requests, $st.next_skip, $st.total)
}

Write-Output 'trial-ff-catalog-walk: pass -SelfTest, -Score, or -Window -Live (see the header)'
exit 3
