<#
  review-adjudication-lib.ps1 - review intake as a packet, with automatic adjudication.
  Step 11 of design/PLAN-zero-alert-days-remainder-2026-09-24.md (ruled 2026-09-10, carried verbatim there), and Phase 4
  of design/PLAN-weekly-root-families-2026-10-02.md (family 3, which folds in queue item 2026-09-30-dc03c3).

  WHAT THE RULING SAYS (verbatim): "The five bucket-1 types write to `grocery/out/review-packet.json` instead of calling
  send-alert. Daily triage works the packet the way it works Class C items today." "Automatic adjudication runs first:
  a flag that is the footprint of an earlier ruling (09-10's donuts +74% was the previous day's exclude working); an
  acknowledged flag still inside its expiry; a move a committed routing artifact already predicted." "Only a crown
  change, or a move beyond the commodity's band, on a live cell that adjudication could not explain, pages."
  Bar, verbatim: "those five types page on at most 4 of 14 days, while the packet carries every row the alerts used to.
  The census checks row-count parity."

  HOW IT IS WIRED. The emitters do not change (four of the five live in check-ad-cycles.ps1). send-alert.ps1 calls
  Invoke-ReviewPacketRoute once it knows the alert's registry class: a REVIEW-class alert whose registry entry is one of
  the five types becomes ONE packet row (one condition, one row: a same-day repeat or a still-open earlier row absorbs,
  exactly as Get-QueueAction absorbs into a queue item), and is neither queued nor mailed. A row with a line that pages
  (an unexplained crown change, or an engine-stated out-of-band move, on a live cell) still writes its packet row AND
  then queues exactly as a review alert did before this step. Every failure here (the lib will not load, the packet
  cannot be read, the lock is not taken) falls back to the queue path: an alert this lib could not record is never lost.

  NOTHING IS DROPPED. An adjudicated line keeps its row and carries the evidence that explained it
  (reliability-craft/MAP.md section 5: "a silenced symptom and a fixed cause look identical from the alert's side").

  THE BAND VERDICT IS THE ENGINE'S, READ OFF THE LINE (no hard-coded bands, grocery rule gr-10). This lib never computes
  a band: a line is out of band only when the emitter says so (OUT-OF-BAND, BAND-DROPPED). A SANITY flag is a published
  cell, so the engine's band admitted it; it is a crown statement (the cheapest moved, or the cheapest is an outlier).

  SCOPE OF A CLEAN REPORT: UNSOUND. Adjudication matches the line shapes this file parses (flag lines, ' - ' rows); a
  line in any other shape is carried unexplained, never explained, so an unknown shape can only cost a reader, never
  hide a page. The ruling-footprint evidence reads committed catalog diffs and known-wrong rulings only; a ruling that
  lives anywhere else (category-excludes.json) explains nothing.

  The packet is GITIGNORED, beside the triage queue it replaces for these five types and for the same reason
  (.gitignore: the queue is machine-local by design). It follows the queue: from a linked worktree it is the MAIN
  checkout's grocery/out/review-packet.json. grocery/out/review-intake.jsonl is the parity ledger: one line per
  five-type send, appended BEFORE adjudication or the packet write, so the census can count what the alert path carried.

  Self-test:   powershell -File grocery\review-adjudication-lib.ps1 -SelfTest
  Close a row: powershell -File grocery\review-adjudication-lib.ps1 -CloseRow <rp-id> -Disposition <confirmed|false-alarm|superseded|by-design|wont-fix> -Notes "<what was established>"
#>
# gate-inputs: grocery\review-adjudication-lib.ps1, grocery\send-alert.ps1, grocery\alert-lib.ps1, grocery\mute-lib.ps1, grocery\alert-registry-lib.ps1, lib\*.ps1
$__ralSelfTest = ($MyInvocation.InvocationName -ne '.') -and ($args -contains '-SelfTest')
$__ralArgs = @($args)
$script:RalDir = $PSScriptRoot

# The five types, keyed by REGISTRY ENTRY ID (never by subject wording, which an emitter may reword). The soundness
# family is every review-class entry whose lineage_parent is match-soundness; those named here are the ones that exist.
$script:ReviewPacketEntryTypes = @{
  'match-soundness' = 'matching-soundness'; 'match-soundness-rule-edit-in-progress' = 'matching-soundness'
  'match-soundness-rule-change-unreviewed' = 'matching-soundness'; 'match-soundness-moved-no-rule-change' = 'matching-soundness'
  'match-soundness-new-contested' = 'matching-soundness'; 'match-soundness-matcher-drift' = 'matching-soundness'
  'new-price-flags' = 'new-price-flags'; 'semantic-sweep' = 'semantic-sweep'; 'stores-dropped' = 'stores-dropped'; 'wrong-department' = 'wrong-department'
}
$script:ReviewPacketTypes = @('matching-soundness', 'new-price-flags', 'semantic-sweep', 'stores-dropped', 'wrong-department')
# Page-class entries of the same lineage: the census counts their days as the five types paging (the crown page).
$script:ReviewPacketPageEntries = @('match-soundness-contested-crown')
# HOW FAR BACK A RULING'S FOOTPRINT REACHES: 2 days, today and yesterday. The founding case is a 1-day lag (the 09-09
# exclude, the 09-10 donuts +74% flag). First plausible value, not a sweep; 1 would miss a ruling committed after the
# morning chain, and every extra day widens what a real wrong price on a recently edited commodity can hide behind.
$script:RulingFootprintDays = 2
# A ROUTING ARTIFACT PREDICTS FOR 14 DAYS from the date in its file name (two board weeks, so a prediction outlives one
# rebuild that has not landed it yet). First plausible value, not a sweep.
$script:RoutingPredictionDays = 14
$script:ReviewPacketAbsorbDays = 14   # the queue's own absorb window (send-alert.ps1 Get-QueueAction)
$script:ReviewPacketKeepDays = 30     # the queue's own resolved-history window
# An open row makes the daily run DUE on its own once it has waited this long: the weekly lane's cadence, so the
# 2026-09-20 ruling (a review item does not set the daily pace) still holds for packet rows.
$script:ReviewPacketDueDays = 7
# The bar's window (step 11 status note in the remainder plan): opens the day after the build, 14 days, at most 4.
$script:ReviewPacketBarOpens = '2026-10-03'
$script:ReviewPacketBarDays = 14
$script:ReviewPacketBarMaxPageDays = 4

function Get-ReviewPacketType {
  <# Pure. Which of the five packet types this alert is, or '' when it is not one (and so routes exactly as before).
     Only a REVIEW-class alert is ever a packet type: an entry promoted to page leaves the packet by itself. #>
  param($Registry, [string]$EntryId, [string]$Class)
  if ($Class -ne 'review' -or -not $EntryId) { return '' }
  if ($script:ReviewPacketEntryTypes.ContainsKey($EntryId)) { return [string]$script:ReviewPacketEntryTypes[$EntryId] }
  try {
    foreach ($e in @($Registry.entries)) {
      if (-not $e -or -not [string]::Equals([string]$e.id, $EntryId, [StringComparison]::Ordinal)) { continue }
      if ($e.PSObject.Properties['lineage_parent'] -and [string]$e.lineage_parent -eq 'match-soundness') { return 'matching-soundness' }
    }
  } catch { }
  return ''
}

function ConvertTo-RalSlug([string]$s) { return ((([string]$s).ToLower() -replace '[^a-z0-9]+', '-').Trim('-')) }

function Get-ReviewPacketLines {
  <# Pure. An alert body -> one object per finding line: text, kind, name, commodity, store, flag_key, crown, live,
     out_of_band. Flag lines (SANITY|..., the review-flag alert) and ' - ' rows (soundness, worklist alerts) are parsed;
     prose, pointers and the graded footer are not lines. LabelToId maps a commodity LABEL (what a SANITY line carries)
     to its id; an unmapped label keeps its slug. #>
  param([string]$Body, [string]$PacketType, $LabelToId = @{})
  $out = [System.Collections.Generic.List[object]]::new()
  foreach ($raw in @(([string]$Body) -split "`r?`n")) {
    $t = ([string]$raw).Trim()
    if (-not $t) { continue }
    $o = [pscustomobject]@{ text = $t; kind = ''; name = ''; commodity = ''; store = ''; flag_key = ''; crown = $false; live = $false; out_of_band = $false }
    $fm = [regex]::Match($t, '^(SANITY|MULTIBUY|MATCHBLIND|BASIS|PACKBASIS)\|')
    if ($fm.Success) {
      $p = @($t -split '\|')
      $o.kind = $fm.Groups[1].Value
      $o.flag_key = (@($p | Select-Object -First 3) -join '|')
      switch ($o.kind) {
        'SANITY' {
          $o.name = [string]$p[1]
          $o.commodity = if ($LabelToId -and $LabelToId.ContainsKey([string]$p[1])) { [string]$LabelToId[[string]$p[1]] } else { ConvertTo-RalSlug $p[1] }
          $o.crown = $true; $o.live = $true   # "the SANITY lines still published": the cheapest moved, or it is an outlier
        }
        'MULTIBUY' { $o.store = [string]$p[1]; $o.name = [string]$p[2]; $o.commodity = ConvertTo-RalSlug $p[2] }   # refused, not published
        'MATCHBLIND' { $o.commodity = [string]$p[1] }                                                         # left off the board
        'BASIS' { $o.commodity = [string]$p[1]; $o.store = [string]$p[2]; $o.live = $true }
        'PACKBASIS' { $o.commodity = [string]$p[1]; $o.store = [string]$p[2]; $o.live = $true; $o.crown = $true }  # "cheapest only because"
        default { throw ('review packet: unknown flag kind ' + $o.kind) }
      }
    } elseif ($t -match '^-\s+(.+)$') {
      $rest = $Matches[1]
      $o.kind = 'row'
      $seg = @($rest -split '\s\|\s')
      $o.name = (([string]$seg[0]) -replace '^(NEW-CONTESTED|CROWN-BY-CONTEST|MOVED|DROPPED)\s+', '' -replace '^\[[A-Z]+\]\s+', '').Trim()
      $cm = [regex]::Match($rest, '(?<c>[a-z0-9]+(?:-[a-z0-9]+)*) @ (?<s>[A-Za-z''][A-Za-z'' -]*?)(?=\s*(?:\$?\d|\||\(|$))')
      if ($cm.Success) { $o.commodity = $cm.Groups['c'].Value; $o.store = $cm.Groups['s'].Value.Trim() }
      else {
        $ch = [regex]::Match($rest, 'chain:\s*(?<c>[a-z0-9]+(?:-[a-z0-9]+)*)')
        if ($ch.Success) { $o.commodity = $ch.Groups['c'].Value }
      }
      $o.crown = ($rest -match 'holds a CROWN|CROWN-BY-CONTEST')
      $o.out_of_band = ($rest -match 'OUT-OF-BAND|BAND-DROPPED|beyond (?:its|the) band')
      # a crown is on the live board by definition; an aisle row is a LIVE cell in the wrong department; an
      # out-of-band row was refused by the band, so it is not on the board
      $o.live = ($o.crown -or $PacketType -eq 'wrong-department') -and -not ($o.out_of_band -and -not $o.crown)
    } else { continue }
    [void]$out.Add($o)
  }
  return ,($out.ToArray())
}

# ---- THE THREE ADJUDICATIONS. Pure; each returns whether it explained the line AND the evidence it used. ----------
function Test-RulingFootprint {
  <# A flag that is the footprint of an earlier ruling: a ruling (a committed catalog change, or a known-wrong entry)
     on this line's commodity inside the footprint window. A ruling naming a store explains only that store's line. #>
  param($Line, $Rulings)
  $r = [pscustomobject]@{ explained = $false; by = 'ruling-footprint'; evidence = $null }
  if (-not $Line.commodity) { return $r }
  foreach ($g in @($Rulings)) {
    if (-not $g -or -not [string]::Equals([string]$g.commodity, [string]$Line.commodity, [StringComparison]::Ordinal)) { continue }
    if ($g.store -and $Line.store -and -not [string]::Equals([string]$g.store, [string]$Line.store, [StringComparison]::OrdinalIgnoreCase)) { continue }
    $r.explained = $true
    $r.evidence = [pscustomobject]@{ ruling = [string]$g.kind; commodity = [string]$g.commodity; store = [string]$g.store; ref = [string]$g.ref; date = [string]$g.date }
    return $r
  }
  return $r
}

function Test-AcknowledgedFlag {
  <# An acknowledged flag still inside its expiry (out\review-ack.json). Same rule as check-ad-cycles.ps1's ack loader:
     an ack is open while expires >= today, and one with no expires or an unparseable one is EXPIRED. #>
  param($Line, $Acks, [string]$Today)
  $r = [pscustomobject]@{ explained = $false; by = 'acknowledged'; evidence = $null }
  $td = [datetime]$Today
  foreach ($a in @($Acks)) {
    if (-not $a -or -not [string]$a.key) { continue }
    $exp = $null
    try { $exp = [datetime]([string]$a.expires) } catch { $exp = $null }
    if ($null -eq $exp -or $exp.Date -lt $td.Date) { continue }
    $k = [string]$a.key
    $hit = ($Line.flag_key -and [string]::Equals([string]$Line.flag_key, $k, [StringComparison]::Ordinal)) -or ([string]$Line.text).StartsWith($k + '|', [StringComparison]::Ordinal)
    if (-not $hit) { continue }
    $r.explained = $true
    $r.evidence = [pscustomobject]@{ key = $k; expires = $exp.ToString('yyyy-MM-dd'); reason = [string]$a.reason }
    return $r
  }
  return $r
}

function Test-RoutingPrediction {
  <# A move a committed routing artifact already predicted: a cell effect on this commodity (and store, when both name
     one), or a routing change naming this exact product. #>
  param($Line, $Predictions)
  $r = [pscustomobject]@{ explained = $false; by = 'routing-prediction'; evidence = $null }
  foreach ($p in @($Predictions)) {
    if (-not $p) { continue }
    $hit = $false
    if ($p.kind -eq 'cell' -and $Line.commodity -and [string]::Equals([string]$p.commodity, [string]$Line.commodity, [StringComparison]::Ordinal)) {
      $hit = (-not $Line.store) -or (-not $p.store) -or [string]::Equals([string]$p.store, [string]$Line.store, [StringComparison]::OrdinalIgnoreCase)
    } elseif ($p.kind -eq 'name' -and $Line.name -and [string]::Equals(([string]$p.name).Trim(), ([string]$Line.name).Trim(), [StringComparison]::OrdinalIgnoreCase)) { $hit = $true }
    if (-not $hit) { continue }
    $r.explained = $true
    $r.evidence = [pscustomobject]@{ artifact = [string]$p.artifact; kind = [string]$p.kind; commodity = [string]$p.commodity; store = [string]$p.store; name = [string]$p.name }
    return $r
  }
  return $r
}

function Get-LineAdjudication {
  <# Pure. The three adjudications in the ruling's order; the first that explains wins. pages = a live crown change or
     an out-of-band move that none explained. #>
  param($Line, $Evidence, [string]$Today)
  $tests = @(
    (Test-RulingFootprint $Line $Evidence.rulings),
    (Test-AcknowledgedFlag $Line $Evidence.acks $Today),
    (Test-RoutingPrediction $Line $Evidence.predictions))
  $win = @($tests | Where-Object { $_.explained } | Select-Object -First 1)
  $a = [pscustomobject]@{ explained = $false; by = ''; evidence = $null; pages = $false }
  if ($win.Count) { $a.explained = $true; $a.by = $win[0].by; $a.evidence = $win[0].evidence }
  $a.pages = ([bool]$Line.live -and ([bool]$Line.crown -or [bool]$Line.out_of_band) -and -not $a.explained)
  return $a
}

function Get-ReviewPacketDecision {
  <# Pure. Lines + evidence -> the row's verdict: status paged (a line pages, so it queues as today), adjudicated (every
     line explained), or open (a reader owes a look). A body with no parseable line is open and marked unparsed. #>
  param($Lines, $Evidence, [string]$Today)
  $ls = [System.Collections.Generic.List[object]]::new()
  $nx = 0; $np = 0
  foreach ($l in @($Lines)) {
    if (-not $l) { continue }
    $a = Get-LineAdjudication $l $Evidence $Today
    if ($a.explained) { $nx++ }
    if ($a.pages) { $np++ }
    $l | Add-Member -NotePropertyName adjudication -NotePropertyValue $a -Force
    [void]$ls.Add($l)
  }
  $d = [pscustomobject]@{ lines = $ls.ToArray(); n = $ls.Count; explained = $nx; unexplained = ($ls.Count - $nx); paging = $np; pages = ($np -gt 0); status = 'open'; unparsed = ($ls.Count -eq 0) }
  if ($d.pages) { $d.status = 'paged' } elseif ($d.n -gt 0 -and $d.unexplained -eq 0) { $d.status = 'adjudicated' }
  return $d
}

# ---- EVIDENCE (the impure half; every reader degrades to an EMPTY list and a note, which explains nothing) ---------
function Select-RulingsInWindow {
  <# Pure. Rulings dated inside the footprint window ending Today (Days days, Today included). #>
  param($Rulings, [string]$Today, [int]$Days = $script:RulingFootprintDays)
  $end = ([datetime]$Today).Date; $start = $end.AddDays(-($Days - 1))
  return @(@($Rulings) | Where-Object { $_ -and $(try { $d = ([datetime]([string]$_.date)).Date; $d -ge $start -and $d -le $end } catch { $false }) })
}

function ConvertFrom-ZeroContextLog {
  <# Pure. `git log --format=@@C %h %cs -U0 -p` text -> one record per commit: hash, date, the NEW-side line numbers its
     hunks touch (a pure deletion touches the line it was removed before). #>
  param([string[]]$LogLines)
  $recs = [System.Collections.Generic.List[object]]::new()
  $cur = $null
  foreach ($ln in @($LogLines)) {
    $s = [string]$ln
    if ($s.StartsWith('@@C ', [StringComparison]::Ordinal)) {
      $pp = @($s.Substring(4).Trim() -split '\s+')
      $cur = [pscustomobject]@{ commit = [string]$pp[0]; date = [string]$pp[1]; lines = [System.Collections.Generic.List[int]]::new() }
      [void]$recs.Add($cur); continue
    }
    $h = [regex]::Match($s, '^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@')
    if ($h.Success -and $cur) {
      $st = [int]$h.Groups[1].Value; $cnt = if ($h.Groups[2].Success) { [int]$h.Groups[2].Value } else { 1 }
      if ($cnt -eq 0) { [void]$cur.lines.Add([Math]::Max(1, $st)) } else { for ($k = 0; $k -lt $cnt; $k++) { [void]$cur.lines.Add($st + $k) } }
    }
  }
  return $recs.ToArray()
}

function Get-CommodityIdAtLines {
  <# Pure. The catalog's text at one commit + 1-based line numbers -> the distinct commodity ids those lines sit in
     (the nearest "id" line at or above each). #>
  param([string[]]$FileLines, [int[]]$LineNumbers)
  $ids = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  $want = @($LineNumbers | Sort-Object -Unique)
  if (-not $want.Count) { return @() }
  $last = ''; $wi = 0
  for ($i = 0; $i -lt $FileLines.Count -and $wi -lt $want.Count; $i++) {
    $m = [regex]::Match([string]$FileLines[$i], '^\s*"id"\s*:\s*"([^"]+)"')
    if ($m.Success) { $last = $m.Groups[1].Value }
    while ($wi -lt $want.Count -and $want[$wi] -eq ($i + 1)) { if ($last) { [void]$ids.Add($last) }; $wi++ }
  }
  return @($ids)
}

function Get-ReviewRulingEvidence {
  param([string]$RepoRoot, [string]$Today)
  $notes = [System.Collections.Generic.List[string]]::new()
  $rul = [System.Collections.Generic.List[object]]::new()
  $gd = Join-Path $RepoRoot 'grocery'
  try {
    $kwF = Join-Path $gd 'known-wrong.json'
    if (Test-Path -LiteralPath $kwF) {
      $kw = Get-Content -LiteralPath $kwF -Raw -Encoding UTF8 | ConvertFrom-Json
      foreach ($e in @($kw.entries)) { if ($e -and $e.commodity -and $e.ruled_on) { [void]$rul.Add([pscustomobject]@{ kind = 'known-wrong'; commodity = [string]$e.commodity; store = [string]$e.store; ref = [string]$e.key; date = [string]$e.ruled_on }) } }
    }
  } catch { [void]$notes.Add('known-wrong.json unreadable: ' + $_.Exception.Message) }
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try {
    $since = ([datetime]$Today).Date.AddDays(-($script:RulingFootprintDays - 1)).ToString('yyyy-MM-dd') + ' 00:00'
    $until = ([datetime]$Today).Date.ToString('yyyy-MM-dd') + ' 23:59:59'
    $log = @(& git -C $RepoRoot log ('--since=' + $since) ('--until=' + $until) '--format=@@C %h %cs' -U0 -p -- grocery/commodities.json 2>$null)
    if ($LASTEXITCODE -ne 0) { [void]$notes.Add('git log of the catalog failed, so no catalog ruling explains anything') }
    else {
      foreach ($c in (ConvertFrom-ZeroContextLog $log)) {
        $txt = @(& git -C $RepoRoot show ($c.commit + ':grocery/commodities.json') 2>$null)
        if ($LASTEXITCODE -ne 0 -or -not $txt.Count) { [void]$notes.Add('catalog at ' + $c.commit + ' unreadable'); continue }
        foreach ($id in (Get-CommodityIdAtLines $txt ($c.lines.ToArray()))) { [void]$rul.Add([pscustomobject]@{ kind = 'catalog-change'; commodity = $id; store = ''; ref = $c.commit; date = $c.date }) }
      }
    }
  } catch { [void]$notes.Add('catalog rulings unreadable: ' + $_.Exception.Message) } finally { $ErrorActionPreference = $prev }
  $inWin = Select-RulingsInWindow ($rul.ToArray()) $Today
  return [pscustomobject]@{ rulings = @($inWin); notes = $notes.ToArray() }
}

function Get-RoutingPredictionsFromObject {
  <# Pure. Walks one routing artifact: every object carrying commodity+store (a cell effect) or name+after (a routing
     change) is a prediction. Artifacts differ in shape (cell_effects, routing_changes, items.<id>.changes). #>
  param($Obj, [string]$Artifact, [int]$Depth = 0)
  $out = [System.Collections.Generic.List[object]]::new()
  if ($null -eq $Obj -or $Depth -gt 8) { return @() }
  if ($Obj -is [string] -or $Obj -is [ValueType]) { return @() }
  if ($Obj -is [System.Collections.IEnumerable] -and -not ($Obj -is [System.Management.Automation.PSCustomObject])) {
    foreach ($x in $Obj) { foreach ($p in (Get-RoutingPredictionsFromObject $x $Artifact ($Depth + 1))) { [void]$out.Add($p) } }
    return $out.ToArray()
  }
  $props = @($Obj.PSObject.Properties | Where-Object { $_.MemberType -eq 'NoteProperty' })
  $has = @{}; foreach ($pp in $props) { $has[$pp.Name] = $true }
  if ($has['commodity'] -and $has['store'] -and ($Obj.commodity -is [string])) { [void]$out.Add([pscustomobject]@{ artifact = $Artifact; kind = 'cell'; commodity = [string]$Obj.commodity; store = [string]$Obj.store; name = '' }) }
  elseif ($has['name'] -and $has['after'] -and ($Obj.name -is [string])) { [void]$out.Add([pscustomobject]@{ artifact = $Artifact; kind = 'name'; commodity = [string]$Obj.after; store = ''; name = [string]$Obj.name }) }
  foreach ($pp in $props) { if ($pp.Value -and -not ($pp.Value -is [string])) { foreach ($p in (Get-RoutingPredictionsFromObject $pp.Value $Artifact ($Depth + 1))) { [void]$out.Add($p) } } }
  return $out.ToArray()
}

function Get-ReviewPredictionEvidence {
  <# COMMITTED routing artifacts only: tracked by git and unmodified in the checkout, dated in their file name inside
     the prediction window. An uncommitted artifact predicts nothing. #>
  param([string]$RepoRoot, [string]$Today)
  $notes = [System.Collections.Generic.List[string]]::new()
  $preds = [System.Collections.Generic.List[object]]::new()
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try {
    $tracked = @(& git -C $RepoRoot ls-files -- 'grocery/triage-plans/*.routing.json' 2>$null)
    if ($LASTEXITCODE -ne 0) { [void]$notes.Add('git ls-files failed, so no routing artifact predicts anything'); return [pscustomobject]@{ predictions = @(); notes = $notes.ToArray() } }
    $dirty = @(& git -C $RepoRoot status --porcelain -- 'grocery/triage-plans' 2>$null | ForEach-Object { ([string]$_).Substring(3).Trim() })
    $end = ([datetime]$Today).Date; $start = $end.AddDays(-($script:RoutingPredictionDays - 1))
    foreach ($rel in $tracked) {
      if ($dirty -contains $rel) { continue }
      $dm = [regex]::Match($rel, 'plan-(\d{4}-\d{2}-\d{2})')
      if (-not $dm.Success) { continue }
      $d = [datetime]$dm.Groups[1].Value
      if ($d -lt $start -or $d -gt $end) { continue }
      try {
        $j = Get-Content -LiteralPath (Join-Path $RepoRoot $rel) -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($p in (Get-RoutingPredictionsFromObject $j $rel)) { [void]$preds.Add($p) }
      } catch { [void]$notes.Add($rel + ' unreadable') }
    }
  } finally { $ErrorActionPreference = $prev }
  return [pscustomobject]@{ predictions = $preds.ToArray(); notes = $notes.ToArray() }
}

function Get-ReviewAdjudicationEvidence {
  <# Everything adjudication may cite, read from the checkout whose queue this alert writes. Never throws. #>
  param([string]$RepoRoot, [string]$Today, [switch]$NeedLabels)
  $ev = [pscustomobject]@{ rulings = @(); acks = @(); predictions = @(); label_to_id = @{}; notes = @() }
  $notes = [System.Collections.Generic.List[string]]::new()
  try { $r = Get-ReviewRulingEvidence $RepoRoot $Today; $ev.rulings = @($r.rulings); foreach ($n in $r.notes) { [void]$notes.Add($n) } } catch { [void]$notes.Add('rulings: ' + $_.Exception.Message) }
  try {
    $af = Join-Path $RepoRoot 'grocery\out\review-ack.json'
    if (Test-Path -LiteralPath $af) { $ev.acks = @((Get-Content -LiteralPath $af -Raw -Encoding UTF8 | ConvertFrom-Json).acks) }
  } catch { [void]$notes.Add('review-ack.json unreadable: ' + $_.Exception.Message) }
  try { $p = Get-ReviewPredictionEvidence $RepoRoot $Today; $ev.predictions = @($p.predictions); foreach ($n in $p.notes) { [void]$notes.Add($n) } } catch { [void]$notes.Add('predictions: ' + $_.Exception.Message) }
  if ($NeedLabels) {
    try {
      $cf = Join-Path $RepoRoot 'grocery\commodities.json'
      if (Test-Path -LiteralPath $cf) {
        $map = @{}
        foreach ($m in [regex]::Matches([IO.File]::ReadAllText($cf), '"id"\s*:\s*"([^"]+)"\s*,\s*"label"\s*:\s*"([^"]+)"')) { $map[$m.Groups[2].Value] = $m.Groups[1].Value }
        $ev.label_to_id = $map
      }
    } catch { [void]$notes.Add('catalog labels unreadable: ' + $_.Exception.Message) }
  }
  $ev.notes = $notes.ToArray()
  return $ev
}

# ---- THE PACKET ------------------------------------------------------------------------------------------------
function New-ReviewPacketDoc {
  return [pscustomobject]@{
    readme = 'Review intake packet (step 11 of design/PLAN-zero-alert-days-remainder-2026-09-24.md). Written by send-alert.ps1 through grocery\review-adjudication-lib.ps1 for the five review types instead of a triage-queue item: one row per condition, each line carrying its adjudication and the evidence it used. A paged row also queued. Worked daily by triage as Class C/D (triage-due.ps1 lists it); close a row with: powershell -File grocery\review-adjudication-lib.ps1 -CloseRow <id> -Disposition <confirmed|false-alarm|superseded|by-design|wont-fix> -Notes "<what was established>". Gitignored and machine-local, like the queue.'
    rows = @()
  }
}

function Add-ReviewPacketObservation {
  <# Pure. One send -> the packet with ONE row for its condition. A still-unworked row of the same type key from today or
     the last 14 days absorbs it (count, observations, newest lines); a worked row never absorbs, so a fix that did not
     hold is a new row. Rows worked or adjudicated more than 30 days ago age out; an open row never does. #>
  param($Packet, [string]$TypeKey, [string]$PacketType, [string]$EntryId, [string]$Subject, [string]$Emitter, $Decision, [string]$Today, [string]$Now, [string]$NewId)
  $rows = [System.Collections.Generic.List[object]]::new()
  foreach ($x in @($Packet.rows)) { if ($x) { [void]$rows.Add($x) } }
  $obs = [pscustomobject]@{ date = $Today; ts = $Now; lines = $Decision.n; explained = $Decision.explained; pages = [bool]$Decision.pages }
  $target = $null
  $td = [datetime]$Today
  foreach ($x in $rows) {
    if ([string]$x.type_key -ne $TypeKey -or [string]$x.status -eq 'worked') { continue }
    $age = 999; try { $age = [int]($td - [datetime]([string]$x.date)).TotalDays } catch { }
    if ($age -lt 0 -or $age -gt $script:ReviewPacketAbsorbDays) { continue }
    $target = $x
  }
  $action = 'new'
  if ($target) {
    $action = 'absorb'
    $target.count = [int]$target.count + 1
    $target.last_seen = $Now
    $o2 = @(@($target.observations) + $obs); if ($o2.Count -gt 60) { $o2 = @($o2[($o2.Count - 60)..($o2.Count - 1)]) }
    $target.observations = $o2
    $target.lines = $Decision.lines
    # a row that ever paged stays paged until worked: the page is the news, and a quieter repeat does not unsay it
    if ([string]$target.status -ne 'paged') { $target.status = $Decision.status }
    $target.unparsed = [bool]$Decision.unparsed
  } else {
    $target = [pscustomobject]@{
      id = $NewId; date = $Today; ts = $Now; last_seen = $Now; type = $PacketType; entry_id = $EntryId; type_key = $TypeKey
      subject = $Subject; emitter = $Emitter; status = $Decision.status; count = 1; unparsed = [bool]$Decision.unparsed
      lines = $Decision.lines; observations = @($obs); disposition = $null; notes = $null; worked_ts = $null
    }
    [void]$rows.Add($target)
  }
  $cut = $td.AddDays(-$script:ReviewPacketKeepDays)
  $kept = @($rows | Where-Object { $_.status -eq 'open' -or $_.status -eq 'paged' -or $(try { ([datetime]([string]$_.last_seen)) -ge $cut } catch { $true }) })
  $Packet.rows = $kept
  return [pscustomobject]@{ packet = $Packet; row = $target; action = $action }
}

function Read-ReviewPacket {
  <# The packet document, a fresh one when the file does not exist; THROWS when it exists but reads back empty or
     unparseable, so a garbled read can never be overwritten with a near-empty packet. #>
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return (New-ReviewPacketDoc) }
  $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
  $doc = $null
  if ($raw -and $raw.Trim()) { $doc = $raw | ConvertFrom-Json }
  if (-not $doc -or -not $doc.PSObject.Properties['rows']) { throw ('review packet exists but read back empty or without rows - refusing to overwrite ' + $Path) }
  return $doc
}

function Invoke-ReviewPacketLocked {
  <# Read-modify-write of the packet under the triage-queue mutex (the same writers, so the same lock, never nested
     with the queue write: send-alert takes it again only after this returns). A lock not taken THROWS. #>
  param([string]$Path, [string]$MutexName, [int]$TimeoutMs, [scriptblock]$Change)
  $mx = $null; $held = $false
  try {
    $mx = New-Object System.Threading.Mutex($false, $MutexName)
    try { $held = $mx.WaitOne($TimeoutMs) } catch [System.Threading.AbandonedMutexException] { $held = $true }
    if (-not $held) { throw ('review packet lock ' + $MutexName + ' not acquired in ' + $TimeoutMs + ' ms') }
    $doc = Read-ReviewPacket $Path
    $res = & $Change $doc
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [void](Write-TcAtomicFile -Path $Path -Text ($doc | ConvertTo-Json -Depth 12))
    return $res
  } finally {
    if ($held) { try { $mx.ReleaseMutex() } catch { } }
    if ($mx) { try { $mx.Dispose() } catch { } }
  }
}

function Invoke-ReviewPacketRoute {
  <# Called by send-alert.ps1 once the class is known. applies=$false: not a packet type, nothing touched. written:
     the row is durable. pages: a line pages, so send-alert goes on to queue it as before. Throws only on a lib that
     cannot load; every other failure returns written=$false with the reason, and send-alert queues as before. #>
  param($Registry, [string]$EntryId, [string]$Class, [string]$TypeKey, [string]$Subject, [string]$Body, [string]$Emitter,
        [string]$QueueFile, [string]$MutexName, [int]$LockTimeoutMs, [string]$Today)
  $r = [pscustomobject]@{ applies = $false; written = $false; pages = $false; row_id = ''; action = ''; type = ''; out = ''; log = ''; summary = '' }
  $ptype = Get-ReviewPacketType $Registry $EntryId $Class
  if (-not $ptype) { return $r }
  $r.applies = $true; $r.type = $ptype
  $libDir = Join-Path (Split-Path -Parent $script:RalDir) 'lib'
  . (Join-Path $libDir 'atomic-write.ps1')
  . (Join-Path $libDir 'append-line.ps1')
  $gDir = Split-Path -Parent $QueueFile
  $repo = Split-Path -Parent $gDir
  $packetPath = Join-Path $gDir 'out\review-packet.json'
  $intakePath = Join-Path $gDir 'out\review-intake.jsonl'
  $now = (Get-Date).ToString('s')
  $lines0 = Get-ReviewPacketLines $Body $ptype
  # THE PARITY LEDGER FIRST: what the alert path would have carried, written before anything here can lose it.
  try {
    if (-not (Test-Path -LiteralPath (Split-Path -Parent $intakePath))) { New-Item -ItemType Directory -Force -Path (Split-Path -Parent $intakePath) | Out-Null }
    [void](Add-TcLine -Path $intakePath -Text (([pscustomobject]@{ date = $Today; ts = $now; type = $ptype; entry_id = $EntryId; type_key = $TypeKey; lines = @($lines0).Count }) | ConvertTo-Json -Compress))
  } catch { $r.log = ('REVIEW PACKET intake ledger not written (' + $_.Exception.Message + ') - the census will read this send as a parity break. ') }
  try {
    $needLabels = [bool](@($lines0 | Where-Object { $_.kind -eq 'SANITY' }).Count)
    $ev = Get-ReviewAdjudicationEvidence -RepoRoot $repo -Today $Today -NeedLabels:$needLabels
    $lines = if ($needLabels) { Get-ReviewPacketLines $Body $ptype $ev.label_to_id } else { $lines0 }
    $dec = Get-ReviewPacketDecision $lines $ev $Today
    $newId = 'rp-' + $Today + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6)
    $res = Invoke-ReviewPacketLocked -Path $packetPath -MutexName $MutexName -TimeoutMs $LockTimeoutMs -Change {
      param($doc)
      Add-ReviewPacketObservation $doc $TypeKey $ptype $EntryId $Subject $Emitter $dec $Today $now $newId
    }
    $r.written = $true; $r.pages = [bool]$dec.pages; $r.row_id = [string]$res.row.id; $r.action = $res.action
    $by = (@($dec.lines | Where-Object { $_.adjudication.explained } | Group-Object { $_.adjudication.by } | ForEach-Object { $_.Name + '=' + $_.Count }) -join ' ')
    $r.summary = ('review packet row ' + $r.row_id + ' (' + $res.action + '): ' + $dec.n + ' line(s), ' + $dec.explained + ' explained by adjudication' + $(if ($by) { ' (' + $by + ')' } else { '' }) + ', ' + $dec.paging + ' paging' + $(if ($dec.unparsed) { ', NO PARSEABLE LINE (a reader owes a look)' } else { '' }) + $(if (@($ev.notes).Count) { '; evidence notes: ' + (@($ev.notes) -join '; ') } else { '' }))
    if ($dec.pages) {
      $r.log += ('REVIEW PACKET PAGES ' + $ptype + " '" + $Subject + "' - " + $r.summary + ' - an unexplained crown change or out-of-band move on a live cell, so it ALSO queues as before')
      $r.out = ('alert written to the review packet as ' + $r.row_id + ' and PAGES: ' + $dec.paging + ' unexplained crown or out-of-band line(s) on a live cell')
    } else {
      $r.log += ('REVIEW PACKET ' + $ptype + " '" + $Subject + "' - " + $r.summary + ' - not queued, not emailed (step 11)')
      $r.out = ('alert written to the REVIEW PACKET as ' + $r.row_id + ' (' + $res.action + ', status ' + [string]$res.row.status + ') - not queued, not emailed (step 11)')
    }
  } catch {
    $r.written = $false
    $r.log += ('REVIEW PACKET NOT WRITTEN for ' + $ptype + " '" + $Subject + "' (" + $_.Exception.Message + ') - it queues exactly as before, never lost')
  }
  return $r
}

function Close-ReviewPacketRow {
  param([string]$PacketFile, [string]$Id, [string]$Disposition, [string]$Notes, [string]$MutexName = 'Global\smp-grocery-triage-queue')
  switch ($Disposition) {
    { $_ -in @('confirmed', 'false-alarm', 'superseded', 'by-design', 'wont-fix') } { }
    default { throw ('unknown disposition: ' + $Disposition + ' (confirmed|false-alarm|superseded|by-design|wont-fix)') }
  }
  if (-not ([string]$Notes).Trim()) { throw 'a close needs -Notes saying what was established' }
  $libDir = Join-Path (Split-Path -Parent $script:RalDir) 'lib'
  . (Join-Path $libDir 'atomic-write.ps1')
  return (Invoke-ReviewPacketLocked -Path $PacketFile -MutexName $MutexName -TimeoutMs 10000 -Change {
    param($doc)
    $hit = @($doc.rows | Where-Object { [string]$_.id -eq $Id })
    if ($hit.Count -ne 1) { throw ('no packet row ' + $Id) }
    $hit[0].status = 'worked'; $hit[0].disposition = $Disposition; $hit[0].notes = $Notes; $hit[0].worked_ts = (Get-Date).ToString('s')
    $hit[0]
  })
}

# ---- WHAT TRIAGE OWES (triage-due.ps1) AND WHAT THE CENSUS COUNTS (audit-alert-census.ps1). Pure. -------------------
function Get-ReviewPacketWork {
  <# Open and paged-but-unworked rows are Class C/D work; adjudicated rows are counted with what explained them. The
     packet makes the run DUE on its own only when an unworked row has waited ReviewPacketDueDays. #>
  param($Packet, [datetime]$Now)
  $open = @(@($Packet.rows) | Where-Object { $_ -and ($_.status -eq 'open' -or $_.status -eq 'paged') })
  $adj = @(@($Packet.rows) | Where-Object { $_ -and $_.status -eq 'adjudicated' -and $(try { ($Now - [datetime]([string]$_.last_seen)).TotalDays -le 1 } catch { $false }) })
  $oldest = 0
  foreach ($o in $open) { try { $a = [int]($Now.Date - ([datetime]([string]$o.date)).Date).TotalDays; if ($a -gt $oldest) { $oldest = $a } } catch { } }
  $by = @{}
  foreach ($a in $adj) { foreach ($l in @($a.lines)) { if ($l.adjudication -and $l.adjudication.explained) { $k = [string]$l.adjudication.by; if ($by.ContainsKey($k)) { $by[$k]++ } else { $by[$k] = 1 } } } }
  return [pscustomobject]@{ open = $open; adjudicated = $adj; adjudicated_by = $by; oldest_days = $oldest; due = ($open.Count -gt 0 -and $oldest -ge $script:ReviewPacketDueDays) }
}

function Get-ReviewPacketParity {
  <# Per type over the window: rows the alert path carried (intake ledger sends and lines) against rows the packet
     holds (observations and their lines). Equal is parity; anything else is a break, named per type. #>
  param($IntakeRows, $Packet, [datetime]$Today, [int]$WindowDays = $script:ReviewPacketBarDays, [string]$Opens = $script:ReviewPacketBarOpens)
  $start = $Today.Date.AddDays(-($WindowDays - 1))
  if ($Opens) { $o = [datetime]$Opens; if ($o -gt $start) { $start = $o } }
  $sK = $start.ToString('yyyy-MM-dd'); $eK = $Today.ToString('yyyy-MM-dd')
  $inWin = { param($d) ([string]::CompareOrdinal([string]$d, $sK) -ge 0 -and [string]::CompareOrdinal([string]$d, $eK) -le 0) }
  $rows = [System.Collections.Generic.List[object]]::new()
  foreach ($t in $script:ReviewPacketTypes) {
    $ir = @(@($IntakeRows) | Where-Object { $_ -and [string]$_.type -eq $t -and (& $inWin $_.date) })
    $po = @(foreach ($pr in @($Packet.rows)) { if ($pr -and [string]$pr.type -eq $t) { foreach ($ob in @($pr.observations)) { if ($ob -and (& $inWin $ob.date)) { $ob } } } })
    $il = 0; foreach ($x in $ir) { $il += [int]$x.lines }
    $pl = 0; foreach ($x in $po) { $pl += [int]$x.lines }
    [void]$rows.Add([pscustomobject]@{ type = $t; intake_rows = $ir.Count; packet_rows = $po.Count; intake_lines = $il; packet_lines = $pl; ok = ($ir.Count -eq $po.Count -and $il -eq $pl) })
  }
  $broken = @($rows | Where-Object { -not $_.ok })
  return [pscustomobject]@{ start = $sK; end = $eK; rows = $rows.ToArray(); broken = $broken; parity = ($broken.Count -eq 0) }
}

function Get-ReviewPacketPageDays {
  <# The distinct days in the window on which any of the five types (or the soundness crown page of the same lineage)
     put an item in the triage queue: a new id that day, or a recurrence dated that day. EntryOf maps a queue type key
     to its registry entry id. #>
  param($QueueItems, [scriptblock]$EntryOf, [datetime]$Today, [int]$WindowDays = $script:ReviewPacketBarDays, [string]$Opens = $script:ReviewPacketBarOpens)
  $start = $Today.Date.AddDays(-($WindowDays - 1))
  if ($Opens) { $o = [datetime]$Opens; if ($o -gt $start) { $start = $o } }
  $sK = $start.ToString('yyyy-MM-dd'); $eK = $Today.ToString('yyyy-MM-dd')
  $days = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  foreach ($it in @($QueueItems)) {
    if (-not $it) { continue }
    $eid = [string](& $EntryOf ([string]$it.type))
    if (-not ($script:ReviewPacketEntryTypes.ContainsKey($eid) -or $script:ReviewPacketPageEntries -contains $eid)) { continue }
    $ds = @([string]$it.date) + @(@($it.recurrences) | Where-Object { $_ } | ForEach-Object { [string]$_.date })
    foreach ($d in $ds) { if ($d -and [string]::CompareOrdinal($d, $sK) -ge 0 -and [string]::CompareOrdinal($d, $eK) -le 0) { [void]$days.Add($d) } }
  }
  $span = [int]($Today.Date - $start).TotalDays + 1
  if ($span -lt 0) { $span = 0 }
  return [pscustomobject]@{ start = $sK; end = $eK; days = $days.Count; span = $span; max = $script:ReviewPacketBarMaxPageDays; met = ($days.Count -le $script:ReviewPacketBarMaxPageDays) }
}

# ---- CLOSE A ROW (run as a script, never when dot-sourced) ------------------------------------------------------
if (($MyInvocation.InvocationName -ne '.') -and ($__ralArgs -contains '-CloseRow')) {
  $ErrorActionPreference = 'Stop'
  $cv = @{}
  for ($i = 0; $i -lt $__ralArgs.Count - 1; $i++) { if ([string]$__ralArgs[$i] -match '^-(CloseRow|Disposition|Notes|PacketFile)$' -and -not ([string]$__ralArgs[$i + 1]).StartsWith('-')) { $cv[$Matches[1]] = [string]$__ralArgs[$i + 1] } }
  if (-not $cv['CloseRow']) { throw 'usage: -CloseRow <rp-id> -Disposition <confirmed|false-alarm|superseded|by-design|wont-fix> -Notes "<what was established>"' }
  $pf = $cv['PacketFile']
  if (-not $pf) {
    $pf = Join-Path $script:RalDir 'out\review-packet.json'
    try { . (Join-Path (Split-Path -Parent $script:RalDir) 'lib\main-checkout.ps1'); $qr = Resolve-TcMainQueueFile -Dir $script:RalDir -LocalQueue (Join-Path $script:RalDir 'triage-queue.json'); $pf = Join-Path (Split-Path -Parent $qr.path) 'out\review-packet.json' } catch { }
  }
  $row = Close-ReviewPacketRow -PacketFile $pf -Id $cv['CloseRow'] -Disposition $cv['Disposition'] -Notes $cv['Notes']
  Write-Output ('closed review packet row ' + $row.id + ' as ' + $row.disposition + ' in ' + $pf)
  exit 0
}

if ($__ralSelfTest) {
  $ErrorActionPreference = 'Stop'
  $script:ralFail = 0; $script:ralRan = 0
  function RaT([string]$label, [bool]$cond, [string]$detail = '') {
    $script:ralRan++
    if ($cond) { Write-Output ('ok    ' + $label) } else { Write-Output ('FAIL  ' + $label + '  - ' + $detail); $script:ralFail++ }
  }
  $td = '2026-09-10'
  $noEv = [pscustomobject]@{ rulings = @(); acks = @(); predictions = @(); label_to_id = @{}; notes = @() }
  try {
    # ---- the founding case of adjudication 1: 09-10's donuts +74% was the previous day's exclude working ----
    $donut = 'SANITY|Donuts|wow|cheapest moved up 74% vs last week ($0.33 -> $0.58)'
    $dl = Get-ReviewPacketLines $donut 'new-price-flags' @{ 'Donuts' = 'donuts' }
    RaT 'a SANITY flag line parses to its commodity id through the label map, as a live crown statement' ($dl.Count -eq 1 -and $dl[0].commodity -eq 'donuts' -and $dl[0].crown -and $dl[0].live -and $dl[0].flag_key -eq 'SANITY|Donuts|wow') ("n=" + $dl.Count)
    $evR = [pscustomobject]@{ rulings = @([pscustomobject]@{ kind = 'catalog-change'; commodity = 'donuts'; store = ''; ref = 'a3952ca0f'; date = '2026-09-09' }); acks = @(); predictions = @(); label_to_id = @{}; notes = @() }
    $d1 = Get-ReviewPacketDecision $dl $evR $td
    RaT 'MUST FIRE donuts +74% the day after an exclude is explained as the footprint of that ruling, and does not page' ($d1.status -eq 'adjudicated' -and -not $d1.pages -and $d1.lines[0].adjudication.by -eq 'ruling-footprint') ("status=" + $d1.status)
    RaT 'MUST FIRE and the row carries the evidence it used: the ruling kind and the commit' ($d1.lines[0].adjudication.evidence.ref -eq 'a3952ca0f' -and $d1.lines[0].adjudication.evidence.ruling -eq 'catalog-change') ''
    $d2 = Get-ReviewPacketDecision (Get-ReviewPacketLines $donut 'new-price-flags' @{ 'Donuts' = 'donuts' }) $noEv $td
    RaT 'MUST NOT FIRE adjudication stays silent on an unexplained crown change: the same line with no ruling still pages' ($d2.pages -and $d2.status -eq 'paged' -and -not $d2.lines[0].adjudication.explained) ("status=" + $d2.status)
    # the footprint window (rule og-06): yesterday is AT the 2-day bar and inside it; the day before is one step past it
    $wr = @([pscustomobject]@{ commodity = 'x'; date = '2026-09-09' }, [pscustomobject]@{ commodity = 'y'; date = '2026-09-08' })
    $win = Select-RulingsInWindow $wr $td 2; $win = @($win)
    RaT 'MUST FIRE a ruling dated exactly at the 2-day bar (yesterday) is inside the footprint window' (@($win | Where-Object { $_.commodity -eq 'x' }).Count -eq 1) ''
    RaT 'MUST NOT FIRE a ruling one day past the 2-day bar explains nothing' (@($win | Where-Object { $_.commodity -eq 'y' }).Count -eq 0) ''
    $evS = [pscustomobject]@{ rulings = @([pscustomobject]@{ kind = 'known-wrong'; commodity = 'lemons'; store = 'Family Fare'; ref = 'lemons|FamilyFare|x'; date = '2026-09-10' }); acks = @(); predictions = @(); label_to_id = @{}; notes = @() }
    $aisle = '- 8 Ct Lemon Bars | lemons @ Walmart | lane: undecided - bakery'
    RaT 'MUST NOT FIRE a store-scoped ruling does not explain the same commodity at another store' (-not (Get-ReviewPacketDecision (Get-ReviewPacketLines $aisle 'wrong-department') $evS $td).lines[0].adjudication.explained) ''
    # ---- adjudication 2: an acknowledged flag still inside its expiry ----
    $curry = 'SANITY|Curry Powder|outlier|Sam''s Club $0.50 is 60% below runner-up Walmart $1.25 - verify the price/size parse'
    $ackIn = [pscustomobject]@{ rulings = @(); predictions = @(); label_to_id = @{}; notes = @(); acks = @([pscustomobject]@{ key = 'SANITY|Curry Powder|outlier'; reason = 'warehouse jar vs a shaker; both reproduce'; expires = '2026-09-10' }) }
    $da = Get-ReviewPacketDecision (Get-ReviewPacketLines $curry 'new-price-flags') $ackIn $td
    RaT 'MUST FIRE an acknowledged flag whose expiry is today (at the bar) is explained by the ack and does not page' ($da.status -eq 'adjudicated' -and $da.lines[0].adjudication.by -eq 'acknowledged' -and $da.lines[0].adjudication.evidence.expires -eq '2026-09-10') ("status=" + $da.status)
    $ackOut = [pscustomobject]@{ rulings = @(); predictions = @(); label_to_id = @{}; notes = @(); acks = @([pscustomobject]@{ key = 'SANITY|Curry Powder|outlier'; reason = 'x'; expires = '2026-09-09' }) }
    $de = Get-ReviewPacketDecision (Get-ReviewPacketLines $curry 'new-price-flags') $ackOut $td
    RaT 'CLEAN TWIN an acknowledgement that expired yesterday (one step past the bar) does not adjudicate: the flag pages again' ($de.pages -and $de.status -eq 'paged' -and $de.lines[0].adjudication.by -eq '') ("status=" + $de.status)
    $ackBad = [pscustomobject]@{ rulings = @(); predictions = @(); label_to_id = @{}; notes = @(); acks = @([pscustomobject]@{ key = 'SANITY|Curry Powder|outlier'; reason = 'x'; expires = 'whenever' }) }
    RaT 'MUST NOT FIRE an ack with an unreadable expiry is expired, never open forever' ((Get-ReviewPacketDecision (Get-ReviewPacketLines $curry 'new-price-flags') $ackBad $td).pages) ''
    # ---- adjudication 3: a move a committed routing artifact predicted (plan-2026-09-29-4's carrots @ Aldi) ----
    $art = '{ "items": { "2026-09-29-754693": { "changes": [ { "name": "Specially Selected Carrots Sweet Potatoes 16 OZ", "before": "carrots", "after": "" } ], "cell_effects": [ { "commodity": "carrots", "store": "Aldi", "before": 0.29, "after": 0.995 } ] } } }' | ConvertFrom-Json
    $preds = Get-RoutingPredictionsFromObject $art 'grocery/triage-plans/plan-2026-09-29-4.routing.json'
    RaT 'the routing artifact walk finds the cell effect and the routing change inside items.<id>' (@($preds | Where-Object { $_.kind -eq 'cell' -and $_.commodity -eq 'carrots' }).Count -eq 1 -and @($preds | Where-Object { $_.kind -eq 'name' }).Count -eq 1) ("n=" + @($preds).Count)
    $evP = [pscustomobject]@{ rulings = @(); acks = @(); predictions = $preds; label_to_id = @{}; notes = @() }
    $crownLine = ' - CROWN-BY-CONTEST Our Family Whole Carrots 32 Oz | cell carrots @ Aldi 0.995/lb | claimed by: carrots'
    $dp = Get-ReviewPacketDecision (Get-ReviewPacketLines $crownLine 'matching-soundness') $evP $td
    RaT 'MUST FIRE a crown move on carrots @ Aldi that the committed routing artifact predicted is explained and does not page' ($dp.status -eq 'adjudicated' -and $dp.lines[0].adjudication.by -eq 'routing-prediction' -and $dp.lines[0].adjudication.evidence.artifact -match 'plan-2026-09-29-4') ("status=" + $dp.status)
    $dpx = Get-ReviewPacketDecision (Get-ReviewPacketLines ' - CROWN-BY-CONTEST Some Carrots | cell carrots @ Walmart 1.13/lb | claimed by: carrots' 'matching-soundness') $evP $td
    RaT 'MUST NOT FIRE the same artifact does not explain a crown move at a store it made no prediction for' ($dpx.pages -and -not $dpx.lines[0].adjudication.explained) ''
    # ---- the line shapes, and what pages ----
    $nc = Get-ReviewPacketLines ' - NEW-CONTESTED Specially Selected Pepperoni Marinara 8 OZ | chain: pasta-sauce (oz) > pepperoni (oz) | engine: OUT-OF-BAND' 'matching-soundness'
    RaT 'MUST NOT FIRE a new contested arrival the band refused is out of band but NOT live, so it does not page' ($nc[0].out_of_band -and -not $nc[0].live -and -not (Get-ReviewPacketDecision $nc $noEv $td).pages -and $nc[0].commodity -eq 'pasta-sauce') ''
    $sw = Get-ReviewPacketLines "The embedding sweep found...`n- Prairie Fresh Pork Spareribs | baby-back-ribs @ Walmart | lane: undecided - head noun`nDetails: grocery/out/semantic-findings.json." 'semantic-sweep'
    RaT 'a semantic-sweep row is one line with its commodity and store, and prose around it is not a line' ($sw.Count -eq 1 -and $sw[0].commodity -eq 'baby-back-ribs' -and $sw[0].store -eq 'Walmart') ("n=" + $sw.Count)
    RaT 'MUST NOT FIRE an unexplained semantic-sweep row is open work for a reader, never a page' ((Get-ReviewPacketDecision $sw $noEv $td).status -eq 'open') ''
    $sd = Get-ReviewPacketLines "- Member's Mark Brussels Sprouts | brussels-sprouts @ Sam's Club | lane: release - x" 'stores-dropped'
    RaT 'a store name with an apostrophe parses whole' ($sd[0].store -eq "Sam's Club") ("store=" + $sd[0].store)
    $un = Get-ReviewPacketDecision (Get-ReviewPacketLines 'The matching worklist could not be read, so every current gap is listed: a @ B [X]; c @ D [Y]' 'stores-dropped') $noEv $td
    RaT 'MUST FIRE a body with no parseable line is an OPEN row marked unparsed, never adjudicated away' ($un.status -eq 'open' -and $un.unparsed -and -not $un.pages) ("status=" + $un.status)
    # ---- the catalog diff evidence: which commodity a zero-context hunk sits in ----
    $zl = Get-ReviewPacketLines 'x' 'new-price-flags'
    RaT 'MUST NOT FIRE a body of prose alone yields no line' ($zl.Count -eq 0) ''
    $log = @('@@C a3952ca0f 2026-09-09', 'diff --git a/x b/x', '@@ -10,0 +11 @@', '+  "\\bglazed\\b",', '@@C 5d1968736 2026-09-10', '@@ -3,2 +3,0 @@')
    $zr = ConvertFrom-ZeroContextLog $log
    RaT 'a zero-context log yields each commit with the new-side lines its hunks touch' ($zr.Count -eq 2 -and @($zr[0].lines) -contains 11 -and @($zr[1].lines) -contains 3) ("n=" + $zr.Count)
    $cat = @('[', '  {', '    "id": "bagels",', '    "exclude": [', '      "x"', '    ]', '  },', '  {', '    "id": "donuts",', '    "label": "Donuts",', '    "exclude": [', '      "\\bglazed\\b"', '    ]')
    RaT 'MUST FIRE a hunk inside the donuts entry is attributed to donuts, not to the entry above it' ((@(Get-CommodityIdAtLines $cat @(12)) -join ',') -eq 'donuts') ((Get-CommodityIdAtLines $cat @(12)) -join ',')
    # ---- the packet: one condition, one row (dc03c3), and parity ----
    $pk = New-ReviewPacketDoc
    $a1 = Add-ReviewPacketObservation $pk 'grocery matching soundness new contested' 'matching-soundness' 'match-soundness-new-contested' 'S' '' $d2 $td ($td + 'T08:19:41') 'rp-a'
    $a2 = Add-ReviewPacketObservation $a1.packet 'grocery matching soundness new contested' 'matching-soundness' 'match-soundness-new-contested' 'S' '' $d1 $td ($td + 'T08:19:43') 'rp-b'
    RaT 'MUST FIRE the dc03c3 shape, one condition sent twice two seconds apart, is ONE packet row with count 2, not two' (@($a2.packet.rows).Count -eq 1 -and [int]$a2.row.count -eq 2 -and $a2.action -eq 'absorb') ("rows=" + @($a2.packet.rows).Count)
    RaT 'and a row that paged stays paged when a quieter repeat absorbs into it' ($a2.row.status -eq 'paged') ("status=" + $a2.row.status)
    $a2.row.status = 'worked'
    $a3 = Add-ReviewPacketObservation $a2.packet 'grocery matching soundness new contested' 'matching-soundness' 'match-soundness-new-contested' 'S' '' $d2 '2026-09-11' '2026-09-11T08:00:00' 'rp-c'
    RaT 'CLEAN TWIN a worked row does not absorb: the same condition after a close is a new row (a fix that did not hold is news)' (@($a3.packet.rows).Count -eq 2 -and $a3.action -eq 'new') ("rows=" + @($a3.packet.rows).Count)
    $intake = @([pscustomobject]@{ date = '2026-09-10'; type = 'matching-soundness'; lines = 1 }, [pscustomobject]@{ date = '2026-09-10'; type = 'matching-soundness'; lines = 1 }, [pscustomobject]@{ date = '2026-09-11'; type = 'matching-soundness'; lines = 1 })
    $par = Get-ReviewPacketParity $intake $a3.packet ([datetime]'2026-09-11') 14 ''
    RaT 'MUST NOT FIRE three sends and three packet observations of one type read as parity' ($par.parity -and @($par.rows | Where-Object { $_.type -eq 'matching-soundness' })[0].packet_rows -eq 3) ("broken=" + @($par.broken).Count)
    $par2 = Get-ReviewPacketParity (@($intake) + [pscustomobject]@{ date = '2026-09-11'; type = 'new-price-flags'; lines = 4 }) $a3.packet ([datetime]'2026-09-11') 14 ''
    RaT 'MUST FIRE a send the packet does not hold breaks parity, named by its type' (-not $par2.parity -and @($par2.broken | Where-Object { $_.type -eq 'new-price-flags' }).Count -eq 1) ''
    $qi = @([pscustomobject]@{ type = 'k-flags'; date = '2026-09-03'; recurrences = @([pscustomobject]@{ date = '2026-09-05' }) }, [pscustomobject]@{ type = 'k-page'; date = '2026-09-06' }, [pscustomobject]@{ type = 'k-crown'; date = '2026-09-07' })
    $eo = { param($k) switch ($k) { 'k-flags' { 'new-price-flags' } 'k-crown' { 'match-soundness-contested-crown' } default { 'held' } } }
    $pd = Get-ReviewPacketPageDays $qi $eo ([datetime]'2026-09-10') 14 ''
    RaT 'the page-day count takes the five types and the crown page, new ids and recurrences, and no other type' ($pd.days -eq 3 -and $pd.met) ("days=" + $pd.days)
    $wk = Get-ReviewPacketWork $a3.packet ([datetime]'2026-09-18')
    RaT 'MUST FIRE an unworked row 7 days old (at the due bar) makes the packet due on its own' ($wk.due -and $wk.oldest_days -eq 7) ("oldest=" + $wk.oldest_days)
    RaT 'MUST NOT FIRE the same row at 6 days (one step short of the bar) is listed but not due' (-not (Get-ReviewPacketWork $a3.packet ([datetime]'2026-09-17')).due) ''
    RaT 'CLEAN TWIN a page-class entry is not a packet type, and a review entry of the five is' ((Get-ReviewPacketType $null 'match-soundness-contested-crown' 'page') -ne 'matching-soundness' -and (Get-ReviewPacketType $null 'new-price-flags' 'review') -eq 'new-price-flags') ''
    RaT 'MUST NOT FIRE a five-type entry whose class is no longer review leaves the packet by itself' ((Get-ReviewPacketType $null 'stores-dropped' 'page').Length -eq 0) ''
    $lreg = [pscustomobject]@{ entries = @([pscustomobject]@{ id = 'match-soundness-new-thing'; lineage_parent = 'match-soundness' }) }
    RaT 'a future review split of match-soundness joins the matching-soundness packet type through its lineage' ((Get-ReviewPacketType $lreg 'match-soundness-new-thing' 'review') -eq 'matching-soundness') ''

    # ---- END TO END in a temp tree: the REAL send-alert.ps1 and alert-lib.ps1 against a frozen registry. Mute ON. ----
    $sb = Join-Path $env:TEMP ('ral-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $sbG = Join-Path $sb 'grocery'; $sbL = Join-Path $sb 'lib'
    New-Item -ItemType Directory -Force -Path $sbG, $sbL, (Join-Path $sbG 'out') -ErrorAction Stop | Out-Null
    $u8 = New-Object Text.UTF8Encoding($false)
    try {
      foreach ($n in @('send-alert.ps1', 'alert-lib.ps1', 'alert-registry-lib.ps1', 'mute-lib.ps1', 'review-adjudication-lib.ps1')) { Copy-Item -LiteralPath (Join-Path $script:RalDir $n) -Destination (Join-Path $sbG $n) }
      foreach ($lf in @(Get-ChildItem -LiteralPath (Join-Path (Split-Path -Parent $script:RalDir) 'lib') -Filter '*.ps1' -File)) { Copy-Item -LiteralPath $lf.FullName -Destination (Join-Path $sbL $lf.Name) }
      $reg = '{ "readme": "frozen fixture", "entries": [' +
        '{ "id": "held", "match": "exact", "key": "grocery page held coverage", "class": "page", "condition": "1 board-or-feed-wrong-or-held", "emitter": "x", "resolver": "unassigned:2026-09-22" },' +
        '{ "id": "new-price-flags", "match": "exact", "key": "grocery new price flag s", "class": "review", "condition": "review intake", "emitter": "x", "resolver": "lane:grocery/verify-price-flags.ps1" },' +
        '{ "id": "paywall-leak", "match": "exact", "key": "paywall leak paid recipe s served free", "class": "review", "condition": "review", "emitter": "x", "resolver": "unassigned:2026-09-22" },' +
        '{ "id": "match-soundness-new-contested", "match": "exact", "key": "grocery matching soundness new contested", "class": "review", "condition": "review intake", "emitter": "x", "resolver": "lane:grocery/resolve-match-worklist.ps1" },' +
        '{ "id": "match-soundness-contested-crown", "match": "exact", "key": "grocery matching soundness contested crown", "class": "page", "condition": "4 live-cell-moved-unexplained", "emitter": "x", "resolver": "lane:grocery/resolve-match-worklist.ps1" },' +
        '{ "id": "match-soundness-digest", "match": "exact", "key": "grocery matching soundness condition s need action", "class": "page", "condition": "4 live-cell-moved-unexplained", "emitter": "x", "resolver": "lane:grocery/resolve-match-worklist.ps1" } ] }'
      [IO.File]::WriteAllText((Join-Path $sbG 'alert-registry.json'), $reg, $u8)
      [IO.File]::WriteAllText((Join-Path $sbG 'alerts-muted.json'), '{ "muted": true, "since": "2026-09-10", "until": null }', $u8)
      [IO.File]::WriteAllText((Join-Path $sbG 'out\review-ack.json'), ('{ "acks": [ { "key": "SANITY|Curry Powder|outlier", "reason": "fixture", "expires": "' + (Get-Date).AddDays(3).ToString('yyyy-MM-dd') + '" } ] }'), $u8)
      $sbQ = Join-Path $sbG 'triage-queue.json'; $sbP = Join-Path $sbG 'out\review-packet.json'; $sbI = Join-Path $sbG 'out\review-intake.jsonl'
      . (Join-Path (Split-Path -Parent $script:RalDir) 'lib\mutex-hold.ps1')
      $mxN = New-TcFixtureMutexName 'ral-selftest-queue'
      function _Send([string]$subj, [string]$body) {
        $bf = Join-Path $sb ('b-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.txt')
        [IO.File]::WriteAllText($bf, $body, $u8)
        # the sandbox's own send-alert, driven as a child on purpose (the end-to-end case); the body travels by -BodyFile,
        # never the command line, so test-auditors u011's 32,767-character defect cannot occur here
        $saSandbox = Join-Path $sbG 'send-alert.ps1'
        $o = & powershell -NoProfile -ExecutionPolicy Bypass -File $saSandbox -Subject $subj -BodyFile $bf -QueueMutexName $mxN
        return [pscustomobject]@{ rc = $LASTEXITCODE; out = ((@($o) | ForEach-Object { [string]$_ }) -join ' | ') }
      }
      function _Q { if (Test-Path -LiteralPath $sbQ) { return @((Get-Content -LiteralPath $sbQ -Raw -Encoding UTF8 | ConvertFrom-Json).items) }; return @() }
      function _P { if (Test-Path -LiteralPath $sbP) { return @((Get-Content -LiteralPath $sbP -Raw -Encoding UTF8 | ConvertFrom-Json).rows) }; return @() }
      $flagBody = "1 NEW price flag(s) on 2026-09-10 (the SANITY lines still published; verify they are real).`n`n" + $curry + "`n`n0 other flag(s) were already reported."
      $e1 = _Send 'Grocery: 1 NEW price flag(s) - 2026-09-10' $flagBody
      $p1 = @(_P); $q1 = @(_Q)
      RaT 'MUST FIRE end to end: an acknowledged new price flag becomes ONE adjudicated packet row, and NO queue item' ($e1.rc -eq 0 -and $p1.Count -eq 1 -and [string]$p1[0].status -eq 'adjudicated' -and $q1.Count -eq 0 -and $e1.out -match 'REVIEW PACKET') ("rc=" + $e1.rc + " rows=" + $p1.Count + " queue=" + $q1.Count + " out=" + $e1.out)
      RaT 'and the packet row names the ack it used' ([string]$p1[0].lines[0].adjudication.evidence.key -eq 'SANITY|Curry Powder|outlier') ''
      $e2 = _Send 'Grocery: 1 NEW price flag(s) - 2026-09-10' ("1 NEW price flag(s).`n`nSANITY|Donuts|wow|cheapest moved up 74% vs last week (`$0.33 -> `$0.58)")
      $p2 = @(_P); $q2 = @(_Q)
      RaT 'MUST NOT FIRE end to end: an unexplained crown change still queues its item as before, beside its packet row' ($e2.rc -eq 0 -and $q2.Count -eq 1 -and [string]$q2[0].type -eq 'grocery new price flag s' -and $e2.out -match 'queued as REVIEW' -and $p2.Count -eq 1 -and [string]$p2[0].status -eq 'paged') ("queue=" + $q2.Count + " rows=" + $p2.Count + " out=" + $e2.out)
      RaT 'and that queue item names its packet row' ([string]$q2[0].body -match [regex]::Escape([string]$p2[0].id)) ''
      $e3 = _Send 'Grocery page HELD (coverage) - 2026-09-10' 'Frozen fixture body: Hy-Vee canned-mushrooms, 3 rows, enough store and number evidence that the body is not thin.'
      $q3 = @(_Q)
      RaT 'CLEAN TWIN a non-review alert routes exactly as before: one queue item, the mail leg, no packet row' ($q3.Count -eq 2 -and $e3.out -match 'alert MUTED' -and @(_P).Count -eq 1) ("queue=" + $q3.Count + " out=" + $e3.out)
      $e4 = _Send 'Paywall leak: 2 paid recipe(s) served free' 'Frozen fixture body: two paid recipes, Hy-Vee 3 rows, enough evidence that the body is not thin at all.'
      RaT 'CLEAN TWIN a review alert that is not one of the five still queues as REVIEW, not mailed, no packet row' (@(_Q).Count -eq 3 -and $e4.out -match 'queued as REVIEW' -and @(_P).Count -eq 1) ("out=" + $e4.out)
      # dc03c3 through the real Send-AlertConditions: one soundness condition, one packet row; the roll-up adds none
      . (Join-Path $sbG 'alert-lib.ps1')
      $cxN = ' - NEW-CONTESTED Barissimo Chai Cookie Coffee 12 OZ | chain: coffee (oz) > cookies (oz) | engine: size 12 oz = 0.4908/oz'
      $cx = Send-AlertConditions -SubjectPrefix 'Grocery matching soundness' -Conditions @([pscustomobject]@{ Label = 'NEW CONTESTED'; Text = $cxN.Trim().Substring(2) }) -ReportPointer 'Full report: grocery\out\audit\soundness-report.json.' -SenderArgs @('-QueueMutexName', $mxN)
      $pS = @(@(_P) | Where-Object { [string]$_.type -eq 'matching-soundness' })
      $qS = @(@(_Q) | Where-Object { [string]$_.type -like 'grocery matching soundness*' })
      RaT 'MUST FIRE dc03c3 one soundness condition through Send-AlertConditions writes exactly ONE packet row and no queue item, roll-up or otherwise' ($pS.Count -eq 1 -and $qS.Count -eq 0 -and $cx.digest_rc -eq -1) ("rows=" + $pS.Count + " queue=" + $qS.Count + " digest_rc=" + $cx.digest_rc)
      $intakeN = @([IO.File]::ReadAllLines($sbI) | Where-Object { $_.Trim() }).Count
      RaT 'and the intake ledger holds one line per five-type send (3), the parity the census reads' ($intakeN -eq 3) ("intake=" + $intakeN)
      $pc = (Get-Content -LiteralPath $sbP -Raw -Encoding UTF8 | ConvertFrom-Json)
      $parE = Get-ReviewPacketParity (@([IO.File]::ReadAllLines($sbI) | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })) $pc (Get-Date).Date 14 ''
      RaT 'MUST NOT FIRE the end-to-end run reads as parity: every send the alert path carried is in the packet' ($parE.parity) ((@($parE.broken | ForEach-Object { $_.type + ' ' + $_.intake_rows + '/' + $_.packet_rows })) -join ', ')
      $cl = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $sbG 'review-adjudication-lib.ps1') -CloseRow ([string]$pS[0].id) -Disposition 'confirmed' -Notes 'fixture close' -PacketFile $sbP
      RaT 'CLEAN TWIN a packet row closes through -CloseRow with its disposition' ($LASTEXITCODE -eq 0 -and [string](@(@(_P) | Where-Object { [string]$_.id -eq [string]$pS[0].id })[0].status) -eq 'worked') ((@($cl) -join ' '))
    } finally {
      try { Stop-TcMutexHold } catch { }
      Remove-Item -LiteralPath $sb -Recurse -Force -ErrorAction SilentlyContinue
    }
  } catch {
    $script:ralFail++
    Write-Output ('FAIL  the self-test threw: ' + $_.Exception.Message + ' at line ' + $_.InvocationInfo.ScriptLineNumber)
  }
  if ($script:ralRan -lt 42) { $script:ralFail++; Write-Output ('FAIL  only ' + $script:ralRan + ' of 42 cases ran') }
  Write-Output ''
  if ($script:ralFail -gt 0) { Write-Output ('review-adjudication-lib SELF-TEST FAIL: ' + $script:ralFail + ' of ' + $script:ralRan + ' case(s)'); exit 1 }
  Write-Output ('review-adjudication-lib SELF-TEST PASS: ' + $script:ralRan + ' cases - led by donuts +74% explained as the previous day''s ruling, an ack inside its expiry, a routing-predicted crown move, an unexplained crown that still pages, and dc03c3 as one packet row')
  exit 0
}
