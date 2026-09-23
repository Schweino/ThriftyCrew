<#
  resolve-match-worklist.ps1 - the matching lane's DAILY step (plan-2026-09-22-9 item 2026-09-21-b96f21).

  Reads the five matching detectors' findings (match-worklist-lib.ps1 says which), merges them into ONE worklist
  (grocery/out/match-worklist.json, first_seen kept per key), skips every key the ledger has decided
  (grocery/match-verdicts.json), and classifies the rest. It NEVER edits a rule: a release or a widening waits in
  the worklist for the weekly lane's apply-coverage-batch.ps1 -FromWorklist, which runs every gate a rule change owes.

  What it writes:
    out/match-worklist.json   every undecided key with its evidence, first_seen, and the classifier's reading
    match-verdicts.json       ONLY 'confirm' verdicts of a kind whose classifier met its bar (coverage, semantic):
                              the claim or refusal is right, so the key never comes back
  Kinds whose classifier has no labelled bar yet (aisle, contested, band) are DOCKET-ONLY: the classifier's reading
  is written as .suggestion and nothing is decided for them. A person or the weekly agent decides one key at a time:
    .\resolve-match-worklist.ps1 -Decide '<key>' -Verdict confirm -Reason 'why'
    .\resolve-match-worklist.ps1 -Decide '<key>' -Verdict release -Pattern '\bfrosting' -Reason 'why'
  A confirmed 'contested' key is REVIEWED for audit-match-soundness (Get-ReviewedContested), per name, so the lane
  never needs a whole-state -Accept.

  Marker: MATCH-WORKLIST-COMPLETE scanned=N decided=N undecided=N new=N blind=<kinds>. Exit 0; 3 when every
  detector file is missing (could not evaluate - never 'no findings').
#>
param(
  [string]$OutDir = '',
  [string]$VerdictFile = '',
  [string]$CommoditiesFile = '',
  # where band-refusals-backlog.json lives (the grocery dir); a fixture points it at a temp tree
  [string]$GroceryDir = '',
  [string]$Today = '',
  [string]$Decide = '',
  # moot: the question no longer exists on the current rules (a release whose exclude suppresses nothing); applied: a rule
  # shipped by hand through apply-coverage-batch for this key
  [ValidateSet('', 'confirm', 'release', 'widen', 'known-wrong', 'ad-line', 'moot', 'applied')][string]$Verdict = '',
  [string]$Pattern = '',
  [string]$Reason = '',
  [string]$By = 'resolve-match-worklist -Decide',
  # -Decide on a key no longer on the worklist: the commodity that CLAIMS the name (a coverage key's key names only its
  # target, so without this a release could not say where its exclude goes; found 2026-09-23)
  [string]$Claimer = '',
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if ($SelfTest) {
  # The suite is a file of its own (test-match-worklist.ps1) so the census finds its must-fires; this relays it.
  $out = @(& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'test-match-worklist.ps1'))
  $rc = $LASTEXITCODE
  $out | ForEach-Object { Write-Output $_ }
  Write-Output ('resolve-match-worklist self-test ' + $(if ($rc -eq 0) { 'pass' } else { 'FAIL' }) + ' (test-match-worklist exit ' + $rc + ')')
  exit $(if ($rc -eq 0) { 0 } else { 1 })
}
. (Join-Path $root 'match-worklist-lib.ps1')
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
if (-not $VerdictFile) { $VerdictFile = Join-Path $root 'match-verdicts.json' }
if (-not $CommoditiesFile) { $CommoditiesFile = Join-Path $root 'commodities.json' }
if (-not $Today) { $Today = (Get-Date).ToString('yyyy-MM-dd') }
$wlFile = Join-Path $OutDir 'match-worklist.json'

# Kinds whose classifier met the written bar (0 wrong decisions over the frozen labels in test-match-worklist.ps1).
# A kind not listed here is docket-only: suggested, never decided.
$DecidingKinds = @('coverage', 'semantic')

$verdicts = Read-MatchVerdicts $VerdictFile

if ($Decide) {
  if (-not $Verdict) { Write-Output 'resolve-match-worklist: -Decide needs -Verdict'; exit 1 }
  if (-not $Reason) { Write-Output 'resolve-match-worklist: -Decide needs -Reason (a verdict nobody can explain cannot be audited)'; exit 1 }
  if ($Verdict -in 'release', 'widen' -and -not $Pattern) { Write-Output ('resolve-match-worklist: a ' + $Verdict + ' needs -Pattern, the regex the weekly batch will apply'); exit 1 }
  if ($Pattern) { try { [void][regex]::new($Pattern, 'IgnoreCase') } catch { Write-Output ('resolve-match-worklist: -Pattern is not a valid regex: ' + $Pattern); exit 1 } }
  $wl = Read-MatchWorklist $wlFile
  $row = @($wl | Where-Object { [string]$_.key -eq $Decide })[0]
  if (-not $row) {
    # a key may be decided before it reaches the worklist (a hand review of a detector file); rebuild it from the key
    $p = $Decide -split '\|', 4
    if ($p.Count -lt 4) { Write-Output ('resolve-match-worklist: ' + $Decide + ' is not a kind|commodity|store|name key'); exit 1 }
    $prevV = if ($verdicts.ContainsKey($Decide)) { $verdicts[$Decide] } else { $null }
    $cl = if ($Claimer) { $Claimer } elseif ($prevV -and [string]$prevV.claimer) { [string]$prevV.claimer } elseif ($p[0] -in 'contested', 'aisle', 'band') { $p[1] } else { '' }
    $row = [pscustomobject]@{ kind = $p[0]; commodity = $p[1]; claimer = $cl; store = $p[2]; name = $p[3] }
  }
  if ($Verdict -eq 'release' -and -not [string]$row.claimer) { Write-Output ('resolve-match-worklist: a release needs the claiming commodity; pass -Claimer for ' + $Decide); exit 1 }
  $verdicts[$Decide] = New-MatchVerdict $Decide $row $Verdict $By $Reason $Pattern $Today
  Save-MatchVerdicts $VerdictFile $verdicts
  Write-Output ('resolve-match-worklist: recorded ' + $Verdict + ' for ' + $Decide)
  exit 0
}

$coms = @{}
$comsJson = Get-Content -LiteralPath $CommoditiesFile -Raw -Encoding UTF8 | ConvertFrom-Json   # assign, then iterate: @(ConvertFrom-Json) is ONE element under PS 5.1
foreach ($c in $comsJson) { if ($c.id) { $coms[[string]$c.id] = $c } }
$tokIndex = Get-MwlTokenIndex $comsJson
if (-not $GroceryDir) { $GroceryDir = $root }
$found = Read-MatchFindings -OutDir $OutDir -GroceryDir $GroceryDir
if (@($found.blind).Count -ge 5) {
  Write-Output ('match-worklist: BLIND - no detector file under ' + $OutDir + ' (coverage, semantic, aisle, contested, band); nothing was read and nothing is claimed')
  Write-Output 'MATCH-WORKLIST-COMPLETE scanned=0 decided=0 undecided=0 new=0 blind=all'
  exit 3
}
$prev = Read-MatchWorklist $wlFile
$rows = Merge-MatchWorklist -Findings $found.rows -Previous $prev -Verdicts $verdicts -Today $Today -BlindKinds $found.blind

$kept = New-Object System.Collections.Generic.List[object]
$newConfirms = 0; $decided = 0
foreach ($r in @($rows)) {
  $target = $null; $claimer = $null
  if ($r.kind -in 'coverage', 'semantic') { $target = $coms[[string]$r.commodity] }
  elseif ($r.kind -eq 'contested') { $others = @(([string]$r.commodity -split ',') | Where-Object { $_ }); if ($others.Count -eq 1) { $target = $coms[$others[0]] } }
  if ($r.claimer) { $claimer = $coms[[string]$r.claimer] }
  $cls = Get-MatchClassification -Kind $r.kind -Name $r.name -Target $target -Claimer $claimer -Index $tokIndex
  $deciding = $DecidingKinds -contains [string]$r.kind
  $row = [ordered]@{}; foreach ($pr in $r.PSObject.Properties) { $row[$pr.Name] = $pr.Value }
  $row['head'] = $cls.head; $row['why'] = $cls.why
  if ($deciding) {
    $row['decision'] = $cls.decision; $row['pattern'] = $cls.pattern
    if ($cls.decision -eq 'confirm') {
      $verdicts[[string]$r.key] = New-MatchVerdict ([string]$r.key) $r 'confirm' 'classifier' $cls.why '' $Today
      $newConfirms++; $decided++; continue
    }
    if ($cls.decision -in 'release', 'widen') { $decided++ }
  } else {
    $row['decision'] = 'undecided'; $row['suggestion'] = $cls.decision; $row['pattern'] = $cls.pattern
  }
  [void]$kept.Add([pscustomobject]$row)
}
if ($newConfirms -gt 0) { Save-MatchVerdicts $VerdictFile $verdicts }
$arr = $kept.ToArray()
$byKind = [ordered]@{}; foreach ($g in ($arr | Group-Object kind)) { $byKind[$g.Name] = $g.Count }
$byDecision = [ordered]@{}; foreach ($g in ($arr | Group-Object decision)) { $byDecision[$g.Name] = $g.Count }
$newN = @($arr | Where-Object { $_.new }).Count
$doc = [ordered]@{
  generated = (Get-Date).ToString('yyyy-MM-dd HH:mm'); today = $Today
  note = 'The matching lane''s worklist (plan-2026-09-22-9 b96f21). decision release/widen waits for apply-coverage-batch.ps1 -FromWorklist (weekly lane); ad-line waits for the per-product ingest split (Brad, Q-adline-two-products); undecided rows carry the classifier''s reading in why (and suggestion, for a docket-only kind). A decided key lives in match-verdicts.json and never returns here.'
  deciding_kinds = $DecidingKinds; blind = $found.blind; by_kind = $byKind; by_decision = $byDecision
  confirmed_today = $newConfirms; rows = $arr }
[IO.File]::WriteAllText($wlFile, (($doc | ConvertTo-Json -Depth 6) -replace "`r`n", "`n") + "`n", (New-Object Text.UTF8Encoding($false)))
$undec = @($arr | Where-Object { $_.decision -eq 'undecided' }).Count
Write-Output ('match-worklist: ' + $arr.Count + ' open key(s) [' + (@($byKind.Keys | ForEach-Object { $_ + '=' + $byKind[$_] }) -join ' ') + '], ' + $newConfirms + ' confirmed into the ledger today, ' + $newN + ' first seen today; decisions [' + (@($byDecision.Keys | ForEach-Object { $_ + '=' + $byDecision[$_] }) -join ' ') + ']')
if (@($found.blind).Count -gt 0) { Write-Output ('match-worklist: BLIND for ' + (@($found.blind) -join ', ') + ' - those detectors left no file, so their keys were kept as they were, not forgotten') }
Write-Output ('MATCH-WORKLIST-COMPLETE scanned=' + @($found.rows).Count + ' decided=' + $decided + ' undecided=' + $undec + ' new=' + $newN + ' blind=' + $(if (@($found.blind).Count) { (@($found.blind) -join ',') } else { 'none' }))
exit 0
