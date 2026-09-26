<#
  test-board-mojibake-scope.ps1 -SelfTest - audit-board-mojibake.ps1 names every mangled cell in the QUARANTINE-CELL
  protocol when its ratchet breaks (queue 2026-09-22-6e6a3b, Brad 2026-09-21: one bad item must not hold the board),
  and affirms no scope when a finding cannot be named as a cell. Each case runs the real audit as a child with -Board
  and -OutDir at a per-run fixture tree and reads its output through the same Get-TcChildQuarantineScope guards.ps1
  uses. The founding shape is 2026-09-02's jarred-gravy / Hy-Vee "Campbell's" with its apostrophe decoded as cp1252.
#>
# The self-test runs audit-board-mojibake.ps1 (and what it loads) over a board and baseline it writes in temp.
# gate-inputs: grocery\audit-board-mojibake.ps1, grocery\cell-quarantine-lib.ps1
[CmdletBinding()]
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
if (-not $SelfTest) { Write-Output 'test-board-mojibake-scope: run with -SelfTest'; exit 3 }
. (Join-Path $PSScriptRoot 'cell-quarantine-lib.ps1')
$script:bad = 0; $script:n = 0
function Bmc([string]$label, [bool]$ok, [string]$got) { $script:n++; if ($ok) { Write-Output ('ok    ' + $label) } else { Write-Output ('FAIL  ' + $label + ' :: ' + $got); $script:bad++ } }
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('bms-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
$audit = Join-Path $PSScriptRoot 'audit-board-mojibake.ps1'
$utf8 = New-Object Text.UTF8Encoding($false)
# Built from codepoints so no re-encoding of this file can alter the fixture: a right single quote read as cp1252.
$mangled = 'Campbell' + [char]0x00E2 + [char]0x20AC + [char]0x2122 + 's Turkey Gravy, 10.5 oz Can'
$cleanNm = 'Campbell' + [char]0x2019 + 's Turkey Gravy, 10.5 oz Can'
function Invoke-Bm([string]$name, [string]$gravyName, [string]$gravyStore, [int]$mark) {
  $r = Join-Path $tmp $name
  New-Item -ItemType Directory -Path $r -Force -ErrorAction Stop | Out-Null
  $doc = [ordered]@{ comparison = @(
    [ordered]@{ id = 'jarred-gravy'; stores = @(
      [ordered]@{ store = $gravyStore; item = $gravyName; per_unit = 0.1419 },
      [ordered]@{ store = "Baker's"; item = 'Heinz HomeStyle Turkey Gravy, Jar'; per_unit = 0.1662 }) },
    [ordered]@{ id = 'pickled-jalapenos'; stores = @(
      [ordered]@{ store = 'Walmart'; item = 'Great Value Sliced Jalapenos, 12 oz'; per_unit = 0.0983 }) }) }
  $bp = Join-Path $r 'comparison-2026-09-26.json'
  [IO.File]::WriteAllText($bp, ($doc | ConvertTo-Json -Depth 6), $utf8)
  [IO.File]::WriteAllText((Join-Path $r 'board-mojibake-baseline.json'), ('{"count":' + $mark + '}'), $utf8)
  $o = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $audit -Board $bp -OutDir $r -Quiet)
  return [pscustomobject]@{ rc = $LASTEXITCODE; out = $o; text = ($o -join ' / ') }
}
try {
  New-Item -ItemType Directory -Path $tmp -ErrorAction Stop | Out-Null
  # MUST FIRE: one mangled name over a mark of 0 breaks the ratchet and holds ONE cell, jarred-gravy / Hy-Vee, as a selection.
  $r = Invoke-Bm 'fire' $mangled 'Hy-Vee' 0
  $sc = Get-TcChildQuarantineScope $r.out
  $cells = @(); if ($sc) { $cells = @($sc.cells) }
  Bmc 'MUST FIRE  a mangled name past the mark (1 against 0) exits 2 and is named for guards as jarred-gravy / Hy-Vee [selection], scope complete' (($r.rc -eq 2) -and ($null -ne $sc) -and ($cells.Count -eq 1) -and ([string]$cells[0].id -eq 'jarred-gravy') -and ([string]$cells[0].store -eq 'Hy-Vee') -and ([string]$cells[0].kind -eq 'selection')) ('rc=' + $r.rc + ' ' + $r.text)
  # CLEAN TWIN: the same broken ratchet when the mangled row names no store still fails (exit 2, RATCHET BROKEN) and
  # affirms no scope, so guards holds the board exactly as before this change.
  $r = Invoke-Bm 'nostore' $mangled '' 0
  $sc = Get-TcChildQuarantineScope $r.out
  Bmc 'CLEAN TWIN  a mangled name with no store still exits 2 and prints RATCHET BROKEN, with no scope affirmed' (($r.rc -eq 2) -and ($null -eq $sc) -and ($r.text -match 'RATCHET BROKEN')) ('rc=' + $r.rc + ' ' + $r.text)
  # BAR: the same one mangled name exactly AT the mark (1 of 1) is the known backlog: exit 1, no quarantine line.
  $r = Invoke-Bm 'atbar' $mangled 'Hy-Vee' 1
  Bmc 'BAR  one mangled name exactly AT the mark (1 of 1) exits 1 and prints no QUARANTINE line' (($r.rc -eq 1) -and (@($r.out | Where-Object { $_ -match '^QUARANTINE-' }).Count -eq 0)) ('rc=' + $r.rc + ' ' + $r.text)
  # MUST NOT FIRE: a real curly apostrophe is no finding: exit 0 and no quarantine line.
  $r = Invoke-Bm 'clean' $cleanNm 'Hy-Vee' 0
  Bmc 'MUST NOT FIRE  a correctly encoded name is no finding (exit 0) and prints no QUARANTINE line' (($r.rc -eq 0) -and (@($r.out | Where-Object { $_ -match '^QUARANTINE-' }).Count -eq 0)) ('rc=' + $r.rc + ' ' + $r.text)
} catch { Write-Output ('FAIL  a case threw: ' + $_.Exception.Message); $script:bad++ }
finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue } }
Write-Output ('test-board-mojibake-scope self-test ' + $(if ($script:bad -eq 0 -and $script:n -eq 4) { 'pass' } else { 'FAIL' }) + ': ' + ($script:n - $script:bad) + ' of ' + $script:n + ' case(s) passed (4 expected)')
exit $(if ($script:bad -eq 0 -and $script:n -eq 4) { 0 } else { 1 })
