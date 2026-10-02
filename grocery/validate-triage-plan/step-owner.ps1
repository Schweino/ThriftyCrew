<#
  grocery\validate-triage-plan\step-owner.ps1 - a PIECE of grocery\validate-triage-plan.ps1, dot-sourced by it (the
  host-plus-pieces shape ops\audit-file-size-budget.ps1 judges per piece).

  A RULED STEP OWNS ITS FAMILY (2026-10-02, Brad's ruling D3 A, design/PLAN-weekly-root-families-2026-10-02.md
  Phase 1). Triage minted 81 residual items in 15 days against a weekly lane that works about 4 a week, and most were
  symptoms of steps ruled 2026-09-10 and never built. So a residual whose root family a ruled, unbuilt step already
  owns is recorded against it as leaves_open_followup "step:<plan>#<step label>" and counted there (the census's RULED
  STEPS line), never minted. The owner must RESOLVE like any other: the plan exists, its Status reads RULED or under
  way (ops/plan_citation.py's rule), the step heading exists and does not read [DONE. A finished or unruled step owns
  nothing, so that residual is live work for the queue. The rule is grocery\ruled-step-lib.ps1 Test-StepOwner; this
  piece loads it and holds the host's cases for it in Invoke-StepOwnerSelfTest, which the host's -SelfTest calls and
  counts in its own tally. Nothing here runs at load time.
#>
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'ruled-step-lib.ps1')   # Test-StepOwner

function Invoke-StepOwnerSelfTest {
  # runs in the host's -SelfTest, adding to its $script:ran and $script:fail. $Closed is the host's closed-plan fixture;
  # the host's watch and queue-id owner cases, run just before this, are the CLEAN TWINS of these three.
  param($Closed)
  $sRoot = Join-Path $env:TEMP ('vtp-step-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
  New-Item -ItemType Directory -Path (Join-Path $sRoot 'design') -ErrorAction Stop | Out-Null
  try {
    $body = "`n`n## 2. Steps`n`n### 8. Ruling 2, the row contract`n`ntext`n"
    [IO.File]::WriteAllText((Join-Path $sRoot 'design\PLAN-step-ruled.md'), ('# PLAN: fixture' + "`n`n**Status: RULED 2026-09-10, not started.**" + $body))
    [IO.File]::WriteAllText((Join-Path $sRoot 'design\PLAN-step-done.md'), ('# PLAN: fixture' + "`n`n**Status: DONE 2026-09-30.**" + $body))
    [IO.File]::WriteAllText((Join-Path $sRoot 'design\PLAN-step-proposed.md'), ('# PLAN: fixture' + "`n`n**Status: PROPOSED 2026-10-02.**" + $body))
    # the stub answers what ops/plan_citation.py --plan-state would (its own self-test fixtures that answer)
    $stub = { param($full) switch -Regex ($full) { 'step-ruled' { 'under-way' } 'step-done' { 'finished' } 'step-proposed' { 'not-yet' } default { 'missing' } } }
    foreach ($c in @(
        @{ label = 'MUST NOT FIRE at close, a residual owned by a step of a RULED plan passes'; owner = 'step:design/PLAN-step-ruled.md#8'; rc = 0; match = '' },
        @{ label = 'MUST FIRE at close, a residual owned by a step of a DONE plan is refused'; owner = 'step:design/PLAN-step-done.md#8'; rc = 2; match = 'refused - its Status reads DONE' },
        @{ label = 'MUST FIRE at close, a residual owned by a step of a PROPOSED plan is refused'; owner = 'step:design/PLAN-step-proposed.md#8'; rc = 2; match = 'refused - its Status reads PROPOSED' })) {
      $script:ran++
      $d = $Closed | ConvertTo-Json -Depth 9 | ConvertFrom-Json
      $d.items[0] | Add-Member -NotePropertyName leaves_open_followup -NotePropertyValue $c.owner -Force
      $r = Test-Plan $d @() $env:TEMP -Closing -QueueIds @('2026-09-10-aaaaaa') -RepoRoot $sRoot -StepStateOf $stub
      $txt = ($r.problems -join ' | ')
      if ($r.rc -eq $c.rc -and ((-not $c.match) -or ($txt -match $c.match))) { Write-Output ('ok    ' + $c.label) }
      else { Write-Output ('FAIL  ' + $c.label + '  rc=' + $r.rc + ' want ' + $c.rc + '; problems: ' + $txt); $script:fail++ }
    }
  } finally { Remove-Item -LiteralPath $sRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
