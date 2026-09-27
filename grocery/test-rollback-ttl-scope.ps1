<#
  test-rollback-ttl-scope.ps1 - a SCRATCH build never writes the live rollback ledger (2026-09-26).

  THE FOUNDING BUG: a paired scratch rebuild on 2026-09-26 ran compare-deals and build-sams-deals with -OutDir at a
  scratch folder, and the build still wrote the TRACKED grocery\rollback-first-seen.json, because every saver passed
  its own folder as the ledger root and -OutDir never moved it. The helper restored the file by hand; the ~07:00 bot
  commits tracked grocery files, so an unnoticed write ships.

  THE RULE (rollback-ttl-lib.ps1, WHICH LEDGER A BUILD WRITES): an explicit ledger root is used as given; no output
  folder or the live <grocery>\out is the chain's run and writes the live ledger; any other output folder is scratch
  and gets its own ledger under that folder, seeded from the live one.

  HOW: every case runs a real powershell.exe child against a SANDBOX copy of rollback-ttl-lib.ps1 and the whole lib\
  (ops-and-gates og-33), so "the live ledger" here is the sandbox's, and this suite cannot touch the real one. Each
  child is shaped like a real saver: a script with an -OutDir parameter that dot-sources the library at script scope,
  observes one rollback and saves, the way compare-deals does at its lines 92, 2732 and 3482.

  SCOPE OF A CLEAN REPORT: SOUND for the library rule and for any saver that dot-sources the library at script scope
  with its output folder in a variable named OutDir (compare-deals, build-sams-deals) or states its scope with
  Set-RollbackLedgerScope (import-walmart-batch). UNSOUND for a saver that writes the ledger file without the library.

  Run: powershell -NoProfile -File grocery\test-rollback-ttl-scope.ps1   (exit 0 clean, 1 on any failure)
#>
$ErrorActionPreference = 'Stop'
$g = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repoLib = Join-Path (Split-Path $g -Parent) 'lib'

$script:n = 0; $script:bad = 0
function Case([string]$What, [bool]$Cond, [string]$Detail = '') {
  $script:n++
  if ($Cond) { Write-Output ('  ok    ' + $What) }
  else { $script:bad++; Write-Output ('  FAIL  ' + $What + $(if ($Detail) { ' -> ' + $Detail } else { '' })) }
}
function Get-Hash([string]$Path) { if (Test-Path -LiteralPath $Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash } else { 'ABSENT' } }
function Read-Keys([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return @() }
  $d = ConvertFrom-Json ([IO.File]::ReadAllText($Path))
  return @(@($d.entries) | ForEach-Object { [string]$_.key })
}

$run = Join-Path ([IO.Path]::GetTempPath()) ('rbscope-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
[void](New-Item -ItemType Directory -Path $run -ErrorAction Stop)
try {
  # ---- the sandbox: <run>\sb\grocery\rollback-ttl-lib.ps1 and <run>\sb\lib\*, and a live ledger holding one entry ----
  $sbG = Join-Path $run 'sb\grocery'; $sbL = Join-Path $run 'sb\lib'
  [void](New-Item -ItemType Directory -Path $sbG -ErrorAction Stop); [void](New-Item -ItemType Directory -Path $sbL -ErrorAction Stop)
  Copy-Item -LiteralPath (Join-Path $g 'rollback-ttl-lib.ps1') -Destination $sbG -ErrorAction Stop
  Copy-Item -Path (Join-Path $repoLib '*') -Destination $sbL -Recurse -ErrorAction Stop
  $liveLedger = Join-Path $sbG 'rollback-first-seen.json'
  $seed = '{"updated":"2026-09-01T00:00:00","ttl_days":30,"note":"fixture","entries":[{"key":"Walmart|live1","store":"Walmart","item_id":"live1","price":4.0,"first_seen":"2026-09-01","last_seen":"2026-09-01","price_changed":0}]}'
  function Reset-Live { [IO.File]::WriteAllText($liveLedger, $seed, (New-Object Text.UTF8Encoding($false))) }

  # A saver shaped like compare-deals: -OutDir defaults to <grocery>\out, then the library is dot-sourced at script
  # scope, one rollback observed, the ledger saved against the script's own folder.
  $saver = Join-Path $sbG 'saver.ps1'
  $saverText = @'
param([string]$OutDir = '', [string]$LedgerRoot = '', [string]$Item = 'new1', [switch]$InFunction)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
if (-not $OutDir -and -not $InFunction) { $OutDir = Join-Path $root 'out' }
if ($InFunction) {
  # The library dot-sourced INSIDE a function: an $OutDir in the calling script's scope is NOT the loader's own.
  function Invoke-Inner { . (Join-Path $root 'rollback-ttl-lib.ps1'); [void](Get-RollbackWindow -Store 'Walmart' -ItemId $Item -Price 2.5 -Today '2026-09-26' -AsOf '2026-09-26' -Root $root); [void](Save-RollbackLedger $root) }
  Invoke-Inner
} else {
  . (Join-Path $root 'rollback-ttl-lib.ps1')
  [void](Get-RollbackWindow -Store 'Walmart' -ItemId $Item -Price 2.5 -Today '2026-09-26' -AsOf '2026-09-26' -Root $root)
  [void](Save-RollbackLedger $root)
}
Write-Output 'SAVER-DONE'
exit 0
'@
  [IO.File]::WriteAllText($saver, $saverText, (New-Object Text.UTF8Encoding($false)))
  function Invoke-Saver([string[]]$ArgList) {
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $saver @ArgList
    return [pscustomobject]@{ rc = $LASTEXITCODE; out = (@($out) -join ' | ') }
  }

  # ---- 1. MUST FIRE: a scratch -OutDir leaves the live ledger byte-identical, by hash ----
  Reset-Live; $h0 = Get-Hash $liveLedger
  $scr = Join-Path $run 'scratch1'
  $r1 = Invoke-Saver @('-OutDir', $scr)
  $h1 = Get-Hash $liveLedger
  Case 'MUST FIRE  a build with a SCRATCH -OutDir leaves the live ledger byte-identical (SHA256 before = after)' ($r1.rc -eq 0 -and $h0 -eq $h1) ("rc=$($r1.rc) before=$h0 after=$h1 out=$($r1.out)")
  $k1 = Read-Keys (Join-Path $scr 'rollback-first-seen.json')
  Case 'MUST FIRE  and its sighting is saved in <OutDir>\rollback-first-seen.json, SEEDED with the live entry so it dates rollbacks as the live build would' `
    (($k1 -contains 'Walmart|new1') -and ($k1 -contains 'Walmart|live1')) ('keys=' + ($k1 -join ','))
  Case 'MUST FIRE  the run says so: SCRATCH scope named on its output' ($r1.out -match 'SCRATCH scope') $r1.out

  # ---- 2. CLEAN TWIN: the chain-shaped run (no -OutDir, so <grocery>\out) still writes the LIVE ledger ----
  Reset-Live
  $r2 = Invoke-Saver @('-Item', 'chain1')
  $k2 = Read-Keys $liveLedger
  Case 'CLEAN TWIN a chain-shaped run with no -OutDir writes its sighting to the live ledger and keeps the live entry' `
    ($r2.rc -eq 0 -and ($k2 -contains 'Walmart|chain1') -and ($k2 -contains 'Walmart|live1') -and $r2.out -notmatch 'SCRATCH') ("rc=$($r2.rc) keys=" + ($k2 -join ',') + " out=$($r2.out)")

  # ---- 3. MUST NOT FIRE: -OutDir passed as the live output folder itself is the live run ----
  Reset-Live
  $r3 = Invoke-Saver @('-OutDir', (Join-Path $sbG 'out'), '-Item', 'chain2')
  $k3 = Read-Keys $liveLedger
  Case 'MUST NOT FIRE  -OutDir <grocery>\out spelled out is the live run: the live ledger is written, no scratch ledger made' `
    ($r3.rc -eq 0 -and ($k3 -contains 'Walmart|chain2') -and -not (Test-Path -LiteralPath (Join-Path $sbG 'out\rollback-first-seen.json'))) ("keys=" + ($k3 -join ','))

  # ---- 4. an explicit -LedgerRoot is used exactly as given, and is NOT seeded ----
  Reset-Live; $h4 = Get-Hash $liveLedger
  $led4 = Join-Path $run 'ledger4'; [void](New-Item -ItemType Directory -Path $led4 -ErrorAction Stop)
  $r4 = Invoke-Saver @('-OutDir', (Join-Path $run 'scratch4'), '-LedgerRoot', $led4, '-Item', 'x4')
  $k4 = Read-Keys (Join-Path $led4 'rollback-first-seen.json')
  Case 'MUST FIRE  an explicit -LedgerRoot takes the write and the live ledger is byte-identical' ($r4.rc -eq 0 -and ($k4 -contains 'Walmart|x4') -and $h4 -eq (Get-Hash $liveLedger)) ("keys=" + ($k4 -join ','))
  Case 'CLEAN TWIN an explicit ledger root is not seeded from the live one (build-sams-deals self-test depends on an empty temp ledger)' `
    ($k4.Count -eq 1 -and -not (Test-Path -LiteralPath (Join-Path $run 'scratch4\rollback-first-seen.json'))) ("keys=" + ($k4 -join ','))

  # ---- 5. an existing scratch ledger is kept, never re-seeded over ----
  $r5 = Invoke-Saver @('-OutDir', $scr, '-Item', 'new5')
  $k5 = Read-Keys (Join-Path $scr 'rollback-first-seen.json')
  Case 'CLEAN TWIN a second scratch run in the same -OutDir keeps the first run''s entry (no re-seed over it)' ($r5.rc -eq 0 -and ($k5 -contains 'Walmart|new1') -and ($k5 -contains 'Walmart|new5')) ("keys=" + ($k5 -join ','))

  # ---- 6. MUST NOT FIRE: an OutDir that is not the loader's own (a parent scope's) does not re-scope ----
  Reset-Live
  $r6 = Invoke-Saver @('-OutDir', (Join-Path $run 'scratch6'), '-InFunction', '-Item', 'fn6')
  $k6 = Read-Keys $liveLedger
  Case 'MUST NOT FIRE  a library loaded inside a function reads no OutDir from an enclosing scope (it writes the Root it was given)' `
    ($r6.rc -eq 0 -and ($k6 -contains 'Walmart|fn6')) ("rc=$($r6.rc) keys=" + ($k6 -join ',') + " out=$($r6.out)")

  # ---- 7. the pure rule, at its edges ----
  . (Join-Path $sbG 'rollback-ttl-lib.ps1')
  $live = Join-Path $run 'L'
  $a = Resolve-RollbackLedgerScope -LiveRoot $live -OutDir ((Join-Path $live 'out') + '\')
  Case 'MUST NOT FIRE  the live output folder with a trailing separator is still the live run' (-not $a.scratch) ($a | ConvertTo-Json -Compress)
  $b = Resolve-RollbackLedgerScope -LiveRoot $live -OutDir (Join-Path $live 'out\sub')
  Case 'MUST FIRE  a folder BELOW the live output folder is scratch (only the live folder itself is the live run)' ($b.scratch -and $b.root -like '*\out\sub') ($b | ConvertTo-Json -Compress)
  $c = Resolve-RollbackLedgerScope -LiveRoot $live -LedgerRoot $live
  Case 'MUST NOT FIRE  an explicit -LedgerRoot equal to the live folder is the live ledger, not scratch' (-not $c.scratch) ($c | ConvertTo-Json -Compress)

  # ---- 8. the real savers still carry the shape this suite models ----
  $cd = [IO.File]::ReadAllText((Join-Path $g 'compare-deals.ps1'))
  $iDefault = $cd.IndexOf('if (-not $OutDir)  { $OutDir  = Join-Path $root ' + "'out' }")
  $iLoad = $cd.IndexOf(". (Join-Path `$root 'rollback-ttl-lib.ps1')")
  Case 'CLEAN TWIN compare-deals assigns its -OutDir default BEFORE it dot-sources the library at script scope (what the load-time scope reads)' ($iDefault -ge 0 -and $iLoad -gt $iDefault) ("default=$iDefault load=$iLoad")
  $bs = [IO.File]::ReadAllText((Join-Path $g 'build-sams-deals.ps1'))
  Case 'CLEAN TWIN build-sams-deals states its scope with Set-RollbackLedgerScope from -OutDir and -LedgerRoot' ($bs -match 'Set-RollbackLedgerScope -LiveRoot \$root -OutDir \$OutDir -LedgerRoot \$LedgerRoot') ''
  $iw = [IO.File]::ReadAllText((Join-Path $g 'import-walmart-batch.ps1'))
  Case 'CLEAN TWIN import-walmart-batch scopes the ledger to its -OutRoot sandbox' ($iw -match 'if \(\$OutRoot\) \{ \[void\]\(Set-RollbackLedgerScope') ''
} catch {
  $script:bad++; Write-Output ('  FAIL  unexpected error: ' + $_.Exception.Message)
} finally {
  Remove-Item -LiteralPath $run -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:n -ne 15) { $script:bad++; Write-Output ('  FAIL  expected 15 cases, ran ' + $script:n) }
if ($script:bad -eq 0) { Write-Output ("test-rollback-ttl-scope: self-test pass ($($script:n) cases)"); exit 0 }
Write-Output ("test-rollback-ttl-scope: self-test FAIL ($($script:bad) of $($script:n))"); exit 1
