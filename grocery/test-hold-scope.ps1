<#
  test-hold-scope.ps1 -SelfTest - fixtures for hold-scope-lib.ps1 (queue 2026-09-21-d16398), then the LIVE contract over
  this tree's guards.ps1 and its delegates.
#>
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
if (-not $SelfTest) { Write-Output 'test-hold-scope: run with -SelfTest'; exit 3 }
. (Join-Path $PSScriptRoot 'hold-scope-lib.ps1')
$script:bad = 0; $script:n = 0
function Hc([string]$label, [bool]$ok) { $script:n++; if ($ok) { Write-Output ('ok    ' + $label) } else { Write-Output ('FAIL  ' + $label); $script:bad++ } }
try {
  $g = "foreach (`$g in @(`n  @{ f='audit-a.ps1'; n='a'; k='a' },`n  @{ f='audit-b.ps1'; n='b'; k='b' })) { }"
  $files = @{
    'audit-a.ps1' = "<#`n  HOLD SCOPE: cell - names its cells`n#>`nWrite-Output 'QUARANTINE-SCOPE complete cells=1 stores=0'"
    'audit-b.ps1' = "# audit-b`n# HOLD SCOPE: board - not taught yet`n"
  }
  $rd = { param($f) if ($files.ContainsKey($f)) { $files[$f] } else { $null } }
  $r = Test-TcHoldScopeContract -GuardsText $g -ReadDelegate $rd -Mark 1
  Hc 'MUST NOT FIRE  a cell-scoped delegate that prints the complete line and a board one with a reason pass' ($r.findings.Count -eq 0 -and $r.delegates -eq 2 -and $r.board -eq 1)
  $files['audit-b.ps1'] = "# audit-b`nWrite-Output 'nothing'"
  $r = Test-TcHoldScopeContract -GuardsText $g -ReadDelegate $rd -Mark 1
  Hc 'MUST FIRE  a delegate with no HOLD SCOPE declaration is a finding' (@($r.findings | Where-Object { $_ -match 'audit-b.ps1: no HOLD SCOPE' }).Count -eq 1)
  $files['audit-b.ps1'] = "# HOLD SCOPE: cell - claims cells`nWrite-Output 'done'"
  $r = Test-TcHoldScopeContract -GuardsText $g -ReadDelegate $rd -Mark 1
  Hc 'MUST FIRE  a delegate declaring cell scope that never prints QUARANTINE-SCOPE complete is a finding' (@($r.findings | Where-Object { $_ -match 'never prints' }).Count -eq 1)
  $files['audit-b.ps1'] = "# HOLD SCOPE: board`n"
  $r = Test-TcHoldScopeContract -GuardsText $g -ReadDelegate $rd -Mark 1
  Hc 'MUST FIRE  board scope with no reason is a finding' (@($r.findings | Where-Object { $_ -match 'no reason' }).Count -eq 1)
  $files['audit-a.ps1'] = "# HOLD SCOPE: board - regressed`n"; $files['audit-b.ps1'] = "# HOLD SCOPE: board - not taught`n"
  $r = Test-TcHoldScopeContract -GuardsText $g -ReadDelegate $rd -Mark 1
  Hc 'MUST FIRE  board-scoped delegates one PAST the mark (2 against 1) is a finding' (@($r.findings | Where-Object { $_ -match 'rose to 2 against a mark of 1' }).Count -eq 1)
  $r = Test-TcHoldScopeContract -GuardsText $g -ReadDelegate $rd -Mark 2
  Hc 'BAR  board-scoped delegates exactly AT the mark (2 of 2) pass' ($r.findings.Count -eq 0)
  $r = Test-TcHoldScopeContract -GuardsText 'no table here' -ReadDelegate $rd
  Hc 'MUST FIRE  a guards text with no delegation table is a finding, never a clean pass over nothing' ($r.findings.Count -eq 1 -and $r.delegates -eq 0)
  # LIVE: this tree's guards.ps1 and every delegate it names
  $gl = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'guards.ps1'))
  $live = Test-TcHoldScopeContract -GuardsText $gl -ReadDelegate { param($f) $p = Join-Path $PSScriptRoot $f; if (Test-Path -LiteralPath $p) { [IO.File]::ReadAllText($p) } else { $null } }
  Hc ('CLEAN TWIN  the live tree: ' + $live.delegates + ' delegates, ' + $live.board + ' board-scoped against a mark of ' + $live.mark + ', findings ' + $live.findings.Count) ($live.delegates -ge 13 -and $live.findings.Count -eq 0)
  foreach ($x in $live.findings) { Write-Output ('      ' + $x) }
} catch { Write-Output ('FAIL  a case threw: ' + $_.Exception.Message); $script:bad++ }
Write-Output ('test-hold-scope self-test ' + $(if ($script:bad -eq 0 -and $script:n -eq 8) { 'pass' } else { 'FAIL' }) + ': ' + ($script:n - $script:bad) + ' of ' + $script:n + ' case(s) passed (8 expected)')
exit $(if ($script:bad -eq 0 -and $script:n -eq 8) { 0 } else { 1 })
