# board-pin.ps1 - one daily run judges and ships ONE board generation, and every consumer reads that one.
#
# THE RULING (Brad, 2026-10-02, D2 = A of design/PLAN-weekly-root-families-2026-10-02.md, Phase 5): "each daily run pins
# ONE board generation at its start, and every consumer (guards, the feed export, the post builder, the deals page) reads
# that pin instead of choosing 'the newest file' itself."
#
# THE FOUNDING DEFECT (queue 2026-09-30-1d4206, latent, 0 of 9 boards 2026-09-16..09-30). guards.ps1 and export-feed.ps1
# read the newest out\comparison-*.json; publish-deals-page, build-deals-page and five more consumers switch to
# out\verified-<week_of>.json whenever it exists and is at least as new as the comparison. Seven copies of one freshness
# rule, each applied at its own moment. On a verified day a guards quarantine rewrites the comparison, so the switch
# flips back to the raw board at publish time, and nothing said which board the post, the feed and the guards had seen.
#
# WHAT A GENERATION IS. A pair: the COMPARISON (what guards and the feed judge and price from) and the BOARD the post
# ships (that comparison, or the verified-<week_of>.json derived from it), each named by path and sha256. The verified
# switch is the rule the seven consumers apply today (exists, LastWriteTime -ge the comparison's), decided ONCE, here.
# Never week_of alone (.claude/rules/grocery.md gr-02): the comparison and its verified twin carry the same week_of.
#
# WHEN THE PIN IS TAKEN. The chain BUILDS its board mid-run, so "at its start" means at the start of its consumers: right
# after the last pre-consumer board writer (verify-apply's re-apply), before export-feed, guards and the post. The board
# exists before the pin names it (ops-and-gates og-51). The one in-run rewriter after that is apply-cell-quarantine;
# Step-TcBoardPin follows it, re-derives verified-<week_of>.json from the quarantined comparison when the pin ships the
# verified board (so the post carries the held cells too), rehashes both files and bumps the generation.
#
# HOW A CONSUMER KNOWS IT IS INSIDE A RUN. The chain sets $env:TC_BOARD_PIN to the pin file's path; its children inherit
# it. With no such variable Resolve-TcBoardPin returns the caller's own -Explicit value and touches nothing, so every
# consumer runs its legacy selection lines, which are left in place, unchanged, as the fallback. A consumer whose out
# directory is not the pin's (a sandbox, a self-test) is outside the run too: it is recorded as such and falls back.
# capture-run's deferred post runs after the chain process ended, so capture-run hands it the pin explicitly
# (Get-TcBoardPinForCaller), and only a pin taken since capture-run started.
#
# A HARD FAIL. Inside a run a consumer whose file no longer hashes to the pinned generation, or that was handed another
# comparison-/verified- file from the pinned directory, THROWS "BOARD-PIN MISMATCH". Every consumer runs under EAP=Stop,
# so it exits non-zero: guards holds the board, export-feed is a refused feed (the post is held), publish fails.
#
# THE RUN RECORD. Every pinned read appends one JSON row to <out>\logs\board-pin-reads.jsonl (gitignored, like the
# chain-stages log): run id, consumer, role, generation, sha. The chain ends each run with a run-end row carrying the
# recipe-costs.json sha. `powershell -File lib\board-pin.ps1 -Report -Days 14` reads Phase 5's bar off it: runs where the
# post, the feed and the guards name different generations, and runs where the feed's last export read a recipe-costs
# that is not the one top5-weekly left at the end of the run.
#
# SCOPE OF A CLEAN REPORT: UNSOUND. A consumer not wired to this lib (guards' delegated audits, recipe-overlay,
# build-sale-windows: each still picks the newest comparison itself) is outside it; inside a run they pick the pinned file
# only because the pin is the newest by construction. COMPLETE: a mismatch row is a real read of a different generation.
#
# NO param() BLOCK: dot-sourced into guards, export-feed, the post builders and capture-run, which run under EAP=Stop.
# Self-test: powershell -File lib\board-pin.ps1 -SelfTest   (reads $args, so the dot-source stays inert)
# gate-inputs: lib\board-pin.ps1, lib\atomic-write.ps1, lib\append-line.ps1, lib\json-io.ps1

if (-not (Get-Command Write-TcAtomicFile -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'atomic-write.ps1') }
if (-not (Get-Command Add-TcLine -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'append-line.ps1') }
if (-not (Get-Command Read-JsonFile -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'json-io.ps1') }

$script:TcBoardPinEnv = 'TC_BOARD_PIN'

function Get-TcBpFull([string]$Path) { if (-not $Path) { return '' }; return [IO.Path]::GetFullPath($Path).TrimEnd('\') }

function Get-TcBpSha([string]$Path) {
  if (-not $Path -or -not [IO.File]::Exists($Path)) { return '' }
  return [string](Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Get-TcBpRecordPath([string]$OutDir) { return (Join-Path $OutDir 'logs\board-pin-reads.jsonl') }

function Add-TcBpRow([string]$OutDir, $Row) {
  $lp = Get-TcBpRecordPath $OutDir
  $ld = Split-Path $lp -Parent
  if (-not [IO.Directory]::Exists($ld)) { [void](New-Item -ItemType Directory -Path $ld -Force -ErrorAction Stop) }
  [void](Add-TcLine -Path $lp -Text ($Row | ConvertTo-Json -Depth 6 -Compress))
}

function Select-TcPinBoardFiles([string]$OutDir) {
  <# The board this run judges and the board it ships, by the consumers' own rule, decided once. $null when the
     directory holds no comparison-<yyyy-MM-dd>.json. #>
  $cmp = Get-ChildItem -LiteralPath $OutDir -Filter 'comparison-*.json' -File -ErrorAction SilentlyContinue |
    Where-Object { $_.BaseName -match '^comparison-\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Descending | Select-Object -First 1
  if (-not $cmp) { return $null }
  $wk = ''
  try { $wk = [string](Read-JsonFile $cmp.FullName).week_of } catch { $wk = '' }
  $board = $cmp.FullName; $kind = 'comparison'
  if ($wk) {
    $vf = Join-Path $OutDir ('verified-' + $wk + '.json')
    if ([IO.File]::Exists($vf) -and ((Get-Item -LiteralPath $vf).LastWriteTime -ge $cmp.LastWriteTime)) { $board = $vf; $kind = 'verified' }
  }
  return [pscustomobject]@{ comparison = $cmp.FullName; board = $board; kind = $kind; week_of = $wk }
}

function ConvertTo-TcBpDoc($Pin) {
  return ([ordered]@{ schema = 1; run_id = $Pin.run_id; pinned_at = $Pin.pinned_at; pid = $Pin.pid; out_dir = $Pin.out_dir
    generation = $Pin.generation; week_of = $Pin.week_of
    comparison = [ordered]@{ path = $Pin.comparison.path; sha256 = $Pin.comparison.sha256 }
    board = [ordered]@{ path = $Pin.board.path; sha256 = $Pin.board.sha256; kind = $Pin.board.kind }
    history = @($Pin.history) } | ConvertTo-Json -Depth 8)
}

function New-TcBoardPin {
  <# Pins this run's generation 1 and returns it (with .path, the pin file). Throws when there is no board to pin. #>
  param([Parameter(Mandatory = $true)][string]$OutDir, [Parameter(Mandatory = $true)][string]$RunId, [string]$PinPath = '')
  $od = Get-TcBpFull $OutDir
  if (-not $PinPath) { $PinPath = Join-Path $od 'board-pin.json' }
  $sel = Select-TcPinBoardFiles $od
  if ($null -eq $sel) { throw ('board-pin: no comparison-<date>.json in ' + $od + ' to pin') }
  $cSha = Get-TcBpSha $sel.comparison
  $bSha = if ($sel.kind -eq 'verified') { Get-TcBpSha $sel.board } else { $cSha }
  $at = (Get-Date).ToString('s')
  $pin = [pscustomobject]@{ run_id = $RunId; pinned_at = $at; pid = $PID; out_dir = $od; generation = 1; week_of = $sel.week_of
    comparison = [pscustomobject]@{ path = $sel.comparison; sha256 = $cSha }
    board = [pscustomobject]@{ path = $sel.board; sha256 = $bSha; kind = $sel.kind }
    history = @([ordered]@{ generation = 1; at = $at; reason = 'pinned'; comparison_sha256 = $cSha; board_sha256 = $bSha; kind = $sel.kind }) }
  [void](Write-TcAtomicFile -Path $PinPath -Text (ConvertTo-TcBpDoc $pin) -NoBom)
  Add-TcBpRow $od ([ordered]@{ ts = $at; kind = 'pin'; run_id = $RunId; generation = 1; board_kind = $sel.kind
    comparison = (Split-Path $sel.comparison -Leaf); board = (Split-Path $sel.board -Leaf); comparison_sha256 = $cSha; board_sha256 = $bSha })
  $pin | Add-Member -NotePropertyName path -NotePropertyValue (Get-TcBpFull $PinPath)
  return $pin
}

function Get-TcActiveBoardPin {
  <# The pin of the run this process is part of, or $null outside one. Throws when the variable names a pin file that is
     missing or unreadable: the chain said there is a pin, and guessing would be choosing the newest file again. #>
  $p = [Environment]::GetEnvironmentVariable($script:TcBoardPinEnv)
  if (-not $p) { return $null }
  if (-not [IO.File]::Exists($p)) { throw ('BOARD-PIN MISSING: ' + $script:TcBoardPinEnv + ' names ' + $p + ', which does not exist') }
  $doc = Read-JsonFile $p
  $doc | Add-Member -NotePropertyName path -NotePropertyValue (Get-TcBpFull $p) -Force
  return $doc
}

function Resolve-TcBoardPin {
  <# The file this consumer must read. Outside a pinned run: $Explicit, unchanged (the caller then runs its own legacy
     selection when that is empty). Inside one: the pinned file for -Role (comparison | board), verified against the
     pinned sha256 and recorded, or a THROW. An -Explicit file is checked the same way when it is one of the pinned pair,
     refused when it is another comparison-/verified- file in the pinned directory, and passed through otherwise. #>
  param([string]$OutDir = '', [Parameter(Mandatory = $true)][ValidateSet('comparison', 'board')][string]$Role,
        [Parameter(Mandatory = $true)][string]$Consumer, [string]$Explicit = '', [string[]]$AlsoHash = @())
  $pin = Get-TcActiveBoardPin
  if ($null -eq $pin) { return $Explicit }
  $od = [string]$pin.out_dir
  if ($OutDir -and -not [string]::Equals((Get-TcBpFull $OutDir), $od, [StringComparison]::OrdinalIgnoreCase)) {
    Add-TcBpRow $od ([ordered]@{ ts = (Get-Date).ToString('s'); kind = 'outside'; run_id = $pin.run_id; consumer = $Consumer; out_dir = (Get-TcBpFull $OutDir) })
    return $Explicit
  }
  $want = if ($Role -eq 'board') { $pin.board } else { $pin.comparison }
  if ($Explicit) {
    $ex = Get-TcBpFull $Explicit
    if ([string]::Equals($ex, [string]$pin.board.path, [StringComparison]::OrdinalIgnoreCase)) { $want = $pin.board }
    elseif ([string]::Equals($ex, [string]$pin.comparison.path, [StringComparison]::OrdinalIgnoreCase)) { $want = $pin.comparison }
    elseif ([string]::Equals((Split-Path $ex -Parent), $od, [StringComparison]::OrdinalIgnoreCase) -and ((Split-Path $ex -Leaf) -match '^(comparison|verified)-\d{4}-\d{2}-\d{2}\.json$')) {
      $msg = ('BOARD-PIN MISMATCH: ' + $Consumer + ' was handed ' + (Split-Path $ex -Leaf) + ', which is not this run''s pinned generation ' + $pin.generation + ' (' + (Split-Path ([string]$pin.comparison.path) -Leaf) + ' / ' + (Split-Path ([string]$pin.board.path) -Leaf) + '). HARD FAIL: it would judge or ship a board the rest of the run did not.')
      Add-TcBpRow $od ([ordered]@{ ts = (Get-Date).ToString('s'); kind = 'read'; ok = $false; run_id = $pin.run_id; consumer = $Consumer; role = $Role; generation = [int]$pin.generation; file = (Split-Path $ex -Leaf); why = 'foreign file' })
      throw $msg
    }
    else { return $Explicit }
  }
  $path = [string]$want.path
  $sha = Get-TcBpSha $path
  $row = [ordered]@{ ts = (Get-Date).ToString('s'); kind = 'read'; ok = $true; run_id = $pin.run_id; consumer = $Consumer; role = $Role
    generation = [int]$pin.generation; file = (Split-Path $path -Leaf); sha256 = $sha }
  if (@($AlsoHash).Count) {
    $inp = [ordered]@{}
    foreach ($a in @($AlsoHash)) { if ($a) { $ap = if ([IO.Path]::IsPathRooted($a)) { $a } else { Join-Path $od $a }; $inp[(Split-Path $ap -Leaf)] = (Get-TcBpSha $ap) } }
    $row['inputs'] = $inp
  }
  if (-not [string]::Equals($sha, [string]$want.sha256, [StringComparison]::OrdinalIgnoreCase)) {
    $row.ok = $false; $row['pinned_sha256'] = [string]$want.sha256
    Add-TcBpRow $od $row
    throw ('BOARD-PIN MISMATCH: ' + $Consumer + ' would read ' + (Split-Path $path -Leaf) + ' at sha256 ' + $(if ($sha) { $sha.Substring(0, 12) } else { '(missing)' }) + ', but this run pinned generation ' + $pin.generation + ' at ' + ([string]$want.sha256).Substring(0, 12) + '. Something rewrote the board without advancing the pin (Step-TcBoardPin). HARD FAIL: this consumer would judge or ship a different board than the rest of the run.')
  }
  Add-TcBpRow $od $row
  return $path
}

function Step-TcBoardPin {
  <# After an in-run writer rewrote the pinned comparison (apply-cell-quarantine): when the pin ships the VERIFIED board,
     re-derive it from the rewritten comparison with verify-apply, so the post carries what the feed and guards see; then
     rehash both and bump the generation. Returns log lines. With no pin active it does nothing and says so.
     verify-apply failing falls back to shipping the rewritten comparison, which is what the consumers' own mtime rule
     did on such a day before the pin, and says so loudly. #>
  param([Parameter(Mandatory = $true)][string]$Reason, [string]$VerifyScript = '')
  $pin = Get-TcActiveBoardPin
  if ($null -eq $pin) { return @('board-pin: no pin active - nothing to advance (' + $Reason + ')') }
  $lines = New-Object Collections.ArrayList
  $kind = [string]$pin.board.kind
  $board = [string]$pin.board.path
  if ($kind -eq 'verified') {
    if (-not $VerifyScript) { $VerifyScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'grocery\verify-apply.ps1' }
    $vOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $VerifyScript -CompareFile ([string]$pin.comparison.path) -OutDir ([string]$pin.out_dir)
    $vRc = $LASTEXITCODE
    if ($vRc -eq 0 -and [IO.File]::Exists($board)) { [void]$lines.Add('board-pin: ' + (Split-Path $board -Leaf) + ' re-derived from the rewritten comparison (verify-apply exit 0), so the post carries the same cells as the feed') }
    else {
      $kind = 'comparison'; $board = [string]$pin.comparison.path
      [void]$lines.Add('board-pin: WARN verify-apply exited ' + $vRc + ' re-deriving the verified board after ' + $Reason + ' - this run now ships the rewritten COMPARISON (the consumers'' own rule did the same on such a day), so the post, the feed and guards still name one generation. Last line: ' + [string](@($vOut) | Select-Object -Last 1))
    }
  }
  $cSha = Get-TcBpSha ([string]$pin.comparison.path)
  $bSha = if ($kind -eq 'verified') { Get-TcBpSha $board } else { $cSha }
  $gen = [int]$pin.generation + 1
  $at = (Get-Date).ToString('s')
  $hist = @(@($pin.history) + @([ordered]@{ generation = $gen; at = $at; reason = $Reason; comparison_sha256 = $cSha; board_sha256 = $bSha; kind = $kind }))
  $np = [pscustomobject]@{ run_id = $pin.run_id; pinned_at = $pin.pinned_at; pid = $pin.pid; out_dir = $pin.out_dir; generation = $gen; week_of = $pin.week_of
    comparison = [pscustomobject]@{ path = [string]$pin.comparison.path; sha256 = $cSha }
    board = [pscustomobject]@{ path = $board; sha256 = $bSha; kind = $kind }; history = $hist }
  [void](Write-TcAtomicFile -Path ([string]$pin.path) -Text (ConvertTo-TcBpDoc $np) -NoBom)
  Add-TcBpRow ([string]$pin.out_dir) ([ordered]@{ ts = $at; kind = 'advance'; run_id = $pin.run_id; generation = $gen; reason = $Reason; board_kind = $kind; comparison_sha256 = $cSha; board_sha256 = $bSha })
  [void]$lines.Add('board-pin: generation ' + $gen + ' after ' + $Reason + ' (' + $kind + ' ' + (Split-Path $board -Leaf) + ')')
  return @($lines)
}

function Get-TcBoardPinForCaller {
  <# For a caller OUTSIDE the chain process (capture-run's deferred post): the pin file's path when that pin was taken
     at or after $Since, else ''. A pin from an earlier run is never handed on. #>
  param([Parameter(Mandatory = $true)][string]$OutDir, [Parameter(Mandatory = $true)][datetime]$Since)
  $p = Join-Path $OutDir 'board-pin.json'
  if (-not [IO.File]::Exists($p)) { return '' }
  try { $d = Read-JsonFile $p; if ([datetime]::Parse([string]$d.pinned_at) -ge $Since.AddSeconds(-1)) { return (Get-TcBpFull $p) } } catch { }
  return ''
}

function Get-TcBoardPinRuns {
  <# One row per run in the record: the last generation each consumer group read, whether they agree, and whether the
     feed's last export read the recipe-costs.json the run ended with. Groups: guards, feed (export-feed), post
     (publish-deals-page and build-deals-page). A mismatch row is a divergence whatever the generations say. #>
  param([Parameter(Mandatory = $true)][string]$RecordPath, [datetime]$Since = [datetime]::MinValue)
  $runs = [ordered]@{}
  if (-not [IO.File]::Exists($RecordPath)) { return @() }
  foreach ($ln in [IO.File]::ReadAllLines($RecordPath)) {
    if (-not $ln.Trim()) { continue }
    $r = $null; try { $r = $ln | ConvertFrom-Json } catch { continue }   # a line mid-append does not parse (append-line.ps1)
    if (-not $r.run_id) { continue }
    $k = [string]$r.run_id
    if (-not $runs.Contains($k)) { $runs[$k] = [pscustomobject]@{ run_id = $k; first = [string]$r.ts; guards = $null; feed = $null; post = $null; mismatch = 0; feed_recipe = $null; end_recipe = $null; ended = $false; generation = 0 } }
    $s = $runs[$k]
    switch ([string]$r.kind) {
      'read' {
        if (-not $r.ok) { $s.mismatch++ }
        $g = [int]$r.generation
        switch -Regex ([string]$r.consumer) {
          '^guards$' { $s.guards = $g }
          '^export-feed$' { $s.feed = $g; if ($r.inputs -and $r.inputs.PSObject.Properties['recipe-costs.json']) { $s.feed_recipe = [string]$r.inputs.'recipe-costs.json' } }
          '^(publish|build)-deals-page$' { $s.post = $g }
          default { }
        }
      }
      'run-end' { $s.ended = $true; $s.end_recipe = [string]$r.recipe_costs_sha256; $s.generation = [int]$r.generation }
      'pin' { $s.generation = [int]$r.generation }
      'advance' { $s.generation = [int]$r.generation }
      'outside' { }
      default { throw ('board-pin record: unknown row kind ' + [string]$r.kind) }
    }
  }
  $out = @()
  foreach ($s in $runs.Values) {
    if ($s.first -and ([datetime]::Parse($s.first) -lt $Since)) { continue }
    $gens = @(@($s.guards, $s.feed, $s.post) | Where-Object { $null -ne $_ } | Select-Object -Unique)
    $verdict = if ($s.mismatch -gt 0) { 'DIVERGED' } elseif ($gens.Count -gt 1) { 'DIVERGED' } elseif ($gens.Count -eq 0) { 'NO-READS' } else { 'CONSISTENT' }
    $recipe = if (-not $s.ended) { 'INCOMPLETE' } elseif (-not $s.feed_recipe) { 'NO-EXPORT' } elseif ([string]::Equals($s.feed_recipe, $s.end_recipe, [StringComparison]::OrdinalIgnoreCase)) { 'EQUAL' } else { 'BEHIND' }
    $out += [pscustomobject]@{ run_id = $s.run_id; first = $s.first; guards = $s.guards; feed = $s.feed; post = $s.post; mismatch = $s.mismatch; verdict = $verdict; recipe = $recipe }
  }
  return $out
}

function Write-TcBoardPinRunEnd {
  <# The chain's last word on the pin: a run-end row with the recipe-costs.json the run leaves behind, and one log line
     naming each consumer group's generation. Nothing when no pin is active. #>
  param([string]$OutDir = '')
  $pin = Get-TcActiveBoardPin
  if ($null -eq $pin) { return @('board-pin: no pin this run - every consumer chose its own board, as before the pin') }
  $od = [string]$pin.out_dir
  Add-TcBpRow $od ([ordered]@{ ts = (Get-Date).ToString('s'); kind = 'run-end'; run_id = $pin.run_id; generation = [int]$pin.generation; recipe_costs_sha256 = (Get-TcBpSha (Join-Path $od 'recipe-costs.json')) })
  $r = @(Get-TcBoardPinRuns -RecordPath (Get-TcBpRecordPath $od) | Where-Object { $_.run_id -eq [string]$pin.run_id }) | Select-Object -Last 1
  if ($null -eq $r) { return @('board-pin: the record holds no row for run ' + $pin.run_id) }
  return @('board-pin: run ' + $r.run_id + ' ' + $r.verdict + ' - guards g' + $r.guards + ', feed g' + $r.feed + ', post g' + $r.post + ' of ' + $pin.generation + ' generation(s); feed recipe fields ' + $r.recipe + ' against the recipe-costs.json the run ended with')
}

$__bpSelfTest = ($MyInvocation.InvocationName -ne '.') -and ($args -contains '-SelfTest')
$__bpReport = ($MyInvocation.InvocationName -ne '.') -and ($args -contains '-Report')
if ($__bpReport) {
  # Phase 5's bar, read off the record: powershell -File lib\board-pin.ps1 -Report -OutDir <the chain's out dir> [-Days 14]
  $ix = [array]::IndexOf($args, '-Days'); $days = if ($ix -ge 0) { [int]$args[$ix + 1] } else { 14 }
  $ix = [array]::IndexOf($args, '-OutDir'); if ($ix -lt 0) { Write-Output 'board-pin -Report: COULD NOT EVALUATE - -OutDir <the out directory the chain pins in: the grocery module''s out folder on the main checkout> is required'; exit 3 }; $od = [string]$args[$ix + 1]
  $rows = @(Get-TcBoardPinRuns -RecordPath (Get-TcBpRecordPath $od) -Since ((Get-Date).Date.AddDays(-$days)))
  foreach ($r in $rows) { Write-Output ('{0}  {1,-10} guards g{2} feed g{3} post g{4}  recipe {5}' -f $r.run_id, $r.verdict, $r.guards, $r.feed, $r.post, $r.recipe) }
  $div = @($rows | Where-Object { $_.verdict -eq 'DIVERGED' }).Count
  $eq = @($rows | Where-Object { $_.recipe -eq 'EQUAL' }).Count
  $graded = @($rows | Where-Object { $_.recipe -eq 'EQUAL' -or $_.recipe -eq 'BEHIND' }).Count
  Write-Output ('BOARD-PIN-REPORT runs={0} diverged={1} no_reads={2} recipe_equal={3} of {4} graded (incomplete or no export: {5}) window={6}d' -f $rows.Count, $div, @($rows | Where-Object { $_.verdict -eq 'NO-READS' }).Count, $eq, $graded, ($rows.Count - $graded), $days)
  exit 0
}
if ($__bpSelfTest) {
  $script:bpN = 0; $script:bpF = 0
  function BpT([string]$Label, [bool]$Ok, [string]$Got = '') {
    $script:bpN++
    if ($Ok) { Write-Output ('  PASS  ' + $Label) } else { $script:bpF++; Write-Output ('  FAIL  ' + $Label + $(if ($Got) { '   got: ' + $Got } else { '' })) }
  }
  $prevEnv = [Environment]::GetEnvironmentVariable($script:TcBoardPinEnv)
  $sb = Join-Path ([IO.Path]::GetTempPath()) ('bp-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
  [void](New-Item -ItemType Directory -Path $sb -ErrorAction Stop)
  try {
    $utf8 = New-Object Text.UTF8Encoding($false)
    $o = Join-Path $sb 'out'; [void](New-Item -ItemType Directory -Path $o -ErrorAction Stop)
    $cmpP = Join-Path $o 'comparison-2026-10-01.json'; $verP = Join-Path $o 'verified-2026-09-30.json'
    [IO.File]::WriteAllText($cmpP, '{"week_of":"2026-09-30","provenance_contract":"on","comparison":[{"id":"eggs","stores":[{"store":"Aldi","per_unit":0.21}]}]}', $utf8)
    [IO.File]::WriteAllText((Join-Path $o 'comparison-2026-09-29.json'), '{"week_of":"2026-09-23","comparison":[]}', $utf8)
    [IO.File]::WriteAllText($verP, '{"week_of":"2026-09-30","comparison":[{"id":"eggs","stores":[{"store":"Aldi","per_unit":0.21}]}]}', $utf8)
    # The legacy rule, verbatim from build-deals-page.ps1 lines 15-20 at 38f81c6b8 (the six other copies are the same
    # expression), evaluated over the same directory: the pin must choose what a hand run chooses.
    function Get-BpLegacyChoice([string]$OutDir) {
      $cmpF = (Get-ChildItem (Join-Path $OutDir 'comparison-*.json') | Sort-Object Name -Descending | Select-Object -First 1)
      $CompareFile = $cmpF.FullName
      try { $wk = (Read-JsonFile $cmpF.FullName).week_of; $verF = Join-Path $OutDir ("verified-" + $wk + ".json"); if ((Test-Path $verF) -and ((Get-Item $verF).LastWriteTime -ge $cmpF.LastWriteTime)) { $CompareFile = $verF } } catch {}
      return $CompareFile
    }
    $t0 = [datetime]'2026-10-01T08:00:00'
    $cases = @(@{ n = 'verified one second NEWER than the comparison'; v = 1.0; want = 'verified' }, @{ n = 'verified exactly AT the comparison''s mtime (the -ge bar)'; v = 0.0; want = 'verified' },
               @{ n = 'verified one tick (100 ns) PAST the bar, older than the comparison'; v = -0.0000001; want = 'comparison' }, @{ n = 'verified a day older'; v = -86400.0; want = 'comparison' })
    foreach ($c in $cases) {
      [IO.File]::SetLastWriteTime($cmpP, $t0); [IO.File]::SetLastWriteTime($verP, $t0.AddTicks([long]($c.v * 10000000)))
      $sel = Select-TcPinBoardFiles $o
      $legacy = Get-BpLegacyChoice $o
      BpT ('CLEAN TWIN  ' + $c.n + ': the pin ships the ' + $c.want + ' board, the same file the legacy rule picks') (($sel.kind -eq $c.want) -and [string]::Equals($sel.board, $legacy, [StringComparison]::OrdinalIgnoreCase)) ($sel.kind + ' ' + $sel.board + ' vs ' + $legacy)
    }
    [IO.File]::SetLastWriteTime($verP, $t0.AddSeconds(5))

    # ---- outside a run: nothing is read, nothing is written, the caller's value comes back unchanged
    [Environment]::SetEnvironmentVariable($script:TcBoardPinEnv, $null)
    $r0 = Resolve-TcBoardPin -OutDir $o -Role board -Consumer 'publish-deals-page' -Explicit ''
    $r1 = Resolve-TcBoardPin -OutDir $o -Role comparison -Consumer 'guards' -Explicit 'C:\x\comparison-2026-01-01.json'
    BpT 'CLEAN TWIN  no TC_BOARD_PIN: Resolve returns the caller''s own value ('''' and a path, unchanged) and writes no record' (([string]$r0 -eq '') -and ($r1 -eq 'C:\x\comparison-2026-01-01.json') -and -not [IO.File]::Exists((Get-TcBpRecordPath $o))) ('[' + $r0 + '] [' + $r1 + ']')
    $s0 = @(Step-TcBoardPin -Reason 'quarantine')
    BpT 'CLEAN TWIN  no TC_BOARD_PIN: Step-TcBoardPin advances nothing and says so' ($s0.Count -eq 1 -and $s0[0] -match 'no pin active') ($s0 -join ' | ')

    # ---- a pinned run
    $pin = New-TcBoardPin -OutDir $o -RunId 'fx-run-1'
    [Environment]::SetEnvironmentVariable($script:TcBoardPinEnv, $pin.path)
    BpT 'MUST FIRE  the pin names the newest strict comparison and its verified twin, generation 1' (($pin.generation -eq 1) -and ((Split-Path $pin.comparison.path -Leaf) -eq 'comparison-2026-10-01.json') -and ($pin.board.kind -eq 'verified')) ($pin | ConvertTo-Json -Depth 4 -Compress)
    [IO.File]::WriteAllText((Join-Path $o 'recipe-costs.json'), '{"recipes":[{"slug":"a"}]}', $utf8)
    $g1 = Resolve-TcBoardPin -OutDir $o -Role comparison -Consumer 'guards'
    $f1 = Resolve-TcBoardPin -OutDir $o -Role comparison -Consumer 'export-feed' -AlsoHash @('recipe-costs.json')
    $p1 = Resolve-TcBoardPin -OutDir $o -Role board -Consumer 'publish-deals-page' -Explicit ''
    $b1 = Resolve-TcBoardPin -OutDir $o -Role board -Consumer 'build-deals-page' -Explicit $p1
    BpT 'MUST FIRE  inside the run guards and the feed read the pinned comparison, the post and the page the pinned verified board' (($g1 -eq $pin.comparison.path) -and ($f1 -eq $pin.comparison.path) -and ($p1 -eq $pin.board.path) -and ($b1 -eq $pin.board.path)) ($g1 + ' | ' + $p1)
    $hist = Join-Path $o 'verified-history.json'
    BpT 'MUST NOT FIRE  an explicit file outside the board set (verified-history.json, the history input) is passed through' ((Resolve-TcBoardPin -OutDir $o -Role board -Consumer 'update-history' -Explicit $hist) -eq $hist)
    $sbx = Join-Path $sb 'sandbox-out'
    BpT 'MUST NOT FIRE  a consumer in another out directory (a self-test sandbox) is outside the run: its own value comes back' ((Resolve-TcBoardPin -OutDir $sbx -Role comparison -Consumer 'export-feed' -Explicit '') -eq '')
    $thrown = ''
    try { [void](Resolve-TcBoardPin -OutDir $o -Role board -Consumer 'publish-store-guide' -Explicit (Join-Path $o 'comparison-2026-09-29.json')) } catch { $thrown = $_.Exception.Message }
    BpT 'MUST FIRE  handed ANOTHER comparison from the pinned directory, a consumer throws BOARD-PIN MISMATCH' ($thrown -match '^BOARD-PIN MISMATCH: publish-store-guide was handed comparison-2026-09-29\.json') $thrown

    # ---- the 1d4206 shape: the quarantine rewrites the comparison and nobody advances the pin
    [IO.File]::WriteAllText($cmpP, '{"week_of":"2026-09-30","provenance_contract":"on","quarantine":{"cells":[{"id":"eggs"}]},"comparison":[]}', $utf8)
    $thrown = ''
    try { [void](Resolve-TcBoardPin -OutDir $o -Role comparison -Consumer 'export-feed') } catch { $thrown = $_.Exception.Message }
    BpT 'MUST FIRE  the comparison rewritten after the pin (a quarantine) and NOT advanced: the next consumer throws, never reads it silently' ($thrown -match '^BOARD-PIN MISMATCH: export-feed would read comparison-2026-10-01\.json') $thrown
    # ...and advanced: verify-apply is a stub that derives the verified board from the comparison it is handed.
    $stub = Join-Path $sb 'verify-apply-stub.ps1'
    [IO.File]::WriteAllText($stub, "param([string]`$CompareFile, [string]`$OutDir)`r`n`$t = [IO.File]::ReadAllText(`$CompareFile)`r`n[IO.File]::WriteAllText((Join-Path `$OutDir 'verified-2026-09-30.json'), `$t.Replace('provenance_contract','derived'))`r`nexit 0`r`n", $utf8)
    $st = @(Step-TcBoardPin -Reason 'quarantine' -VerifyScript $stub)
    $pin2 = Get-TcActiveBoardPin
    $g2 = Resolve-TcBoardPin -OutDir $o -Role comparison -Consumer 'guards'
    $f2 = Resolve-TcBoardPin -OutDir $o -Role comparison -Consumer 'export-feed' -AlsoHash @('recipe-costs.json')
    $p2 = Resolve-TcBoardPin -OutDir $o -Role board -Consumer 'publish-deals-page'
    BpT 'MUST FIRE  advanced after the quarantine: generation 2, the verified board RE-DERIVED from the quarantined comparison, and every consumer reads it' (($pin2.generation -eq 2) -and ($pin2.board.kind -eq 'verified') -and ([IO.File]::ReadAllText($verP) -match 'quarantine') -and ($g2 -eq $pin2.comparison.path) -and ($p2 -eq $pin2.board.path)) (($st -join ' | ') + ' gen=' + $pin2.generation)
    $failStub = Join-Path $sb 'verify-apply-fails.ps1'
    [IO.File]::WriteAllText($failStub, "param([string]`$CompareFile, [string]`$OutDir)`r`nWrite-Output 'stub verify-apply: no verdict file'`r`nexit 1`r`n", $utf8)
    $st3 = @(Step-TcBoardPin -Reason 'reapply' -VerifyScript $failStub)
    $pin3 = Get-TcActiveBoardPin
    BpT 'CLEAN TWIN  verify-apply failing on the re-derive ships the rewritten comparison (the consumers'' own rule on that day) and says WARN' (($pin3.generation -eq 3) -and ($pin3.board.kind -eq 'comparison') -and ($pin3.board.path -eq $pin3.comparison.path) -and (($st3 -join ' ') -match 'WARN verify-apply exited 1')) ($st3 -join ' | ')
    $p3 = Resolve-TcBoardPin -OutDir $o -Role board -Consumer 'publish-deals-page'
    $g3 = Resolve-TcBoardPin -OutDir $o -Role comparison -Consumer 'guards'
    $f3 = Resolve-TcBoardPin -OutDir $o -Role comparison -Consumer 'export-feed' -AlsoHash @('recipe-costs.json')
    $end = @(Write-TcBoardPinRunEnd)
    BpT 'MUST FIRE  a run that logged a mismatch ends DIVERGED even though its last reads agree (g3), and its last export read the final recipe-costs (EQUAL)' (($end -join ' ') -match 'run fx-run-1 DIVERGED - guards g3, feed g3, post g3 of 3 generation\(s\); feed recipe fields EQUAL') ($end -join ' | ')

    # ---- the bar's arithmetic over a frozen record (one row per read), separate from the run above
    $rec = Join-Path $sb 'record.jsonl'
    $rows = @(
      '{"ts":"2026-10-03T08:01:00","kind":"pin","run_id":"A","generation":1}',
      '{"ts":"2026-10-03T08:02:00","kind":"read","ok":true,"run_id":"A","consumer":"export-feed","role":"comparison","generation":1,"inputs":{"recipe-costs.json":"R1"}}',
      '{"ts":"2026-10-03T08:03:00","kind":"read","ok":true,"run_id":"A","consumer":"guards","role":"comparison","generation":1}',
      '{"ts":"2026-10-03T08:04:00","kind":"advance","run_id":"A","generation":2}',
      '{"ts":"2026-10-03T08:05:00","kind":"read","ok":true,"run_id":"A","consumer":"guards","role":"comparison","generation":2}',
      '{"ts":"2026-10-03T08:06:00","kind":"read","ok":true,"run_id":"A","consumer":"publish-deals-page","role":"board","generation":2}',
      '{"ts":"2026-10-03T08:07:00","kind":"run-end","run_id":"A","generation":2,"recipe_costs_sha256":"R2"}',
      '{"ts":"2026-10-04T08:01:00","kind":"pin","run_id":"B","generation":1}',
      '{"ts":"2026-10-04T08:02:00","kind":"read","ok":true,"run_id":"B","consumer":"guards","role":"comparison","generation":1}',
      '{"ts":"2026-10-04T08:03:00","kind":"read","ok":true,"run_id":"B","consumer":"export-feed","role":"comparison","generation":1,"inputs":{"recipe-costs.json":"R3"}}',
      '{"ts":"2026-10-04T08:04:00","kind":"read","ok":true,"run_id":"B","consumer":"build-deals-page","role":"board","generation":1}',
      '{"ts":"2026-10-04T08:09:00","kind":"run-end","run_id":"B","generation":1,"recipe_costs_sha256":"R3"}',
      '{"ts":"2026-10-05T08:01:00","kind":"pin","run_id":"C","generation":1}')
    [IO.File]::WriteAllText($rec, (($rows -join "`r`n") + "`r`n{""ts"":""2026-10-05T08:02"), $utf8)
    $runs = @(Get-TcBoardPinRuns -RecordPath $rec)
    $ra = $runs | Where-Object { $_.run_id -eq 'A' }; $rb = $runs | Where-Object { $_.run_id -eq 'B' }; $rc = $runs | Where-Object { $_.run_id -eq 'C' }
    BpT 'MUST FIRE  run A: the feed read generation 1 and never re-read after the advance while guards and the post read 2 - DIVERGED, and its recipe-costs BEHIND the run''s end (c6bafd)' (($ra.verdict -eq 'DIVERGED') -and ($ra.recipe -eq 'BEHIND')) ($ra | ConvertTo-Json -Compress)
    BpT 'MUST NOT FIRE  run B: guards, the feed and the page all generation 1, recipe-costs equal at the end - CONSISTENT, EQUAL' (($rb.verdict -eq 'CONSISTENT') -and ($rb.recipe -eq 'EQUAL')) ($rb | ConvertTo-Json -Compress)
    BpT 'MUST NOT FIRE  run C (pinned, no read yet, no end) and a half-appended last line: NO-READS and INCOMPLETE, never a pass and never a throw' (($runs.Count -eq 3) -and ($rc.verdict -eq 'NO-READS') -and ($rc.recipe -eq 'INCOMPLETE')) ($rc | ConvertTo-Json -Compress)
    $since = Get-Date
    BpT 'MUST NOT FIRE  capture-run is handed only a pin taken since it started (a run starting after it gets nothing)' ((Get-TcBoardPinForCaller -OutDir $o -Since $since.AddDays(2)) -eq '')
    BpT 'CLEAN TWIN  ...and the run that took it gets this run''s pin file, for the deferred post' ((Get-TcBoardPinForCaller -OutDir $o -Since $since.AddMinutes(-5)) -eq $pin.path)
  } catch {
    BpT 'the suite ran to the end without throwing' $false $_.Exception.Message
  } finally {
    [Environment]::SetEnvironmentVariable($script:TcBoardPinEnv, $prevEnv)
    Remove-Item -LiteralPath $sb -Recurse -Force -ErrorAction SilentlyContinue
  }
  $want = 20
  if ($script:bpN -ne $want) { Write-Output ('  FAIL  the suite ran {0} case(s), expected {1}' -f $script:bpN, $want); $script:bpF++ }
  if ($script:bpF) { Write-Output ('board-pin self-test FAIL: {0} of {1}' -f $script:bpF, $script:bpN); exit 1 }
  Write-Output ('board-pin self-test PASS: {0} of {0} cases - led by a comparison rewritten after the pin being refused, never read' -f $script:bpN)
  exit 0
}
