<#
  test-commodity-rules-lib.ps1 - the self-test for commodity-rules-lib.ps1.

  Two jobs. The FIXTURES pin the composition rule (own + global minus relaxed, de-duplicated by exact
  text). The CORPUS case proves the accessor agrees with match-lib - the estate's own rule for a rule
  that now exists twice, and the reason this file exists rather than a comment claiming agreement.

  Run: powershell -NoProfile -File test-commodity-rules-lib.ps1
       exit 0 pass, 1 fail. The last line is the verdict and names this suite.
#>
[CmdletBinding()]
param([switch]$SelfTest)   # accepted and ignored: run-gates passes it to every suite it discovers

$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$root = Split-Path $here -Parent
. (Join-Path $here 'commodity-rules-lib.ps1')
. (Join-Path $here 'global-exclude-lib.ps1')

$fails = 0
$script:ran = 0
$script:expectedCases = 6   # a literal list asserts how many ran (.claude/rules/ops-and-gates.md)
function T([string]$label, [bool]$ok, [string]$got = '') {
  $script:ran++
  if ($ok) { Write-Output "  ok    $label" }
  else { Write-Output ("  FAIL  $label" + $(if ($got) { "  got: $got" } else { '' })); $script:fails++ }
}
$script:fails = 0

# ---- FIXTURES: the composition rule -------------------------------------------------------------
$gex = @('baby\s+food', '\bsoda\b', '\bwipes\b')

# MUST FIRE: a global the commodity has NOT relaxed is part of its effective set, even though the
# commodity's own list never mentions it. This is the case the seventeen non-applying scripts get wrong.
$plain = [pscustomobject]@{ id = 'apples'; exclude = @('\bjuice\b'); relax_global = @() }
$eff = Get-TcCommodityExclude -Commodity $plain -GlobalExclude $gex
T 'an unrelaxed global joins the commodity''s own excludes' (@($eff).Count -eq 4 -and $eff -contains '\bwipes\b' -and $eff -contains '\bjuice\b') ("$($eff -join '|')")

# MUST NOT FIRE: a RELAXED global is absent - that is the whole point of relax_global, and a set that
# included it would make baby-wipes refuse the word wipes.
$wipes = [pscustomobject]@{ id = 'baby-wipes'; exclude = @('\bdiapers?\b'); relax_global = @('\bwipes\b') }
$effW = Get-TcCommodityExclude -Commodity $wipes -GlobalExclude $gex
T 'a relaxed global is NOT in the effective set' (($effW -notcontains '\bwipes\b') -and ($effW -contains '\bsoda\b')) ("$($effW -join '|')")

# CLEAN TWIN: the duplicate case this whole phase is about - a commodity that restates a global keeps
# exactly one copy, and the set is unchanged by the restatement.
$dupe = [pscustomobject]@{ id = 'apples-dupe'; exclude = @('\bjuice\b', '\bsoda\b'); relax_global = @() }
$effD = Get-TcCommodityExclude -Commodity $dupe -GlobalExclude $gex
$effP = Get-TcCommodityExclude -Commodity $plain -GlobalExclude $gex
T 'restating a global changes nothing: same set as the commodity that does not restate it' (((@($effD) | Sort-Object) -join '|') -eq ((@($effP) | Sort-Object) -join '|')) ("$($effD -join '|')")

# MUST FIRE: a document carrying its own global_exclude (the recipe board) uses it, not the shared list.
$docWithOwn = [pscustomobject]@{ global_exclude = @('\bpet\s+food\b'); commodities = @($plain) }
$effR = Get-TcCommodityExclude -Commodity $plain -Doc $docWithOwn
T 'a doc with its own global_exclude overrides the shared list' (($effR -contains '\bpet\s+food\b') -and ($effR -notcontains '\bsoda\b')) ("$($effR -join '|')")

# ---- CORPUS: the accessor must agree with match-lib on the LIVE rules, over a FROZEN name list --------------
# Until 2026-09-23 this case read the newest live capture itself: 322 s of every push, and uncacheable, because a
# capture moves with no commit. The names are now the corpus Get-TcRulesCaptureCorpus read on 2026-09-23 (the newest
# capture then, family-fare-regular-2026-09-22.json, 150 names) plus Get-TcRulesProbeNames, frozen in the fixture
# below. The RULES stay live (commodities.json, match-lib.ps1, global-exclude-lib.ps1), so a rule edit is still
# judged at push time. The live-name question runs daily: grocery\audit-commodity-rules-agree.ps1 in check-ad-cycles.
# gate-inputs: grocery\test-commodity-rules-lib.ps1, grocery\commodity-rules-lib.ps1, grocery\global-exclude-lib.ps1, grocery\match-lib.ps1, grocery\commodities.json, grocery\regression-inputs\commodity-rules-corpus-2026-09-23.json
$mlPath = Join-Path $here 'match-lib.ps1'
$cPath  = Join-Path $here 'commodities.json'
$fxPath = Join-Path $here 'regression-inputs\commodity-rules-corpus-2026-09-23.json'
$fxExpectedNames = 154   # 150 capture names + 4 probes, as frozen; a fixture that reads short is a failure, not a smaller corpus
if ((Test-Path $mlPath) -and (Test-Path $cPath) -and (Test-Path $fxPath)) {
  . $mlPath
  $doc = Get-Content $cPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $fx = [IO.File]::ReadAllText($fxPath) | ConvertFrom-Json
  $names = New-Object System.Collections.Generic.List[string]
  foreach ($n in $fx.capture_names) { if ($n) { $names.Add([string]$n) } }
  foreach ($n in $fx.probe_names) { $names.Add([string]$n) }
  # CLEAN TWIN: the frozen probes are still the probes the live audit asks, so the two halves ask one question.
  $liveProbes = Get-TcRulesProbeNames
  T 'CLEAN TWIN  the fixture''s probe names are exactly Get-TcRulesProbeNames, the list the daily live audit adds' ((@($fx.probe_names) -join '|') -eq (@($liveProbes) -join '|')) ((@($fx.probe_names) -join '|'))
  if ($names.Count -ne $fxExpectedNames) {
    T ("corpus case COULD NOT LOOK: the frozen fixture held $($names.Count) name(s), expected $fxExpectedNames") $false
  } else {
    $dis = Test-TcCommodityRulesAgree -Doc $doc -Names $names.ToArray() -GlobalExclude (Get-TcGlobalExclude)
    T ("accessor agrees with match-lib over $($names.Count) frozen name(s) x $(@(Get-TcCommodityList -Doc $doc).Count) commodities") (@($dis).Count -eq 0) (($dis | Select-Object -First 3) -join ' ; ')
  }
} else {
  T 'corpus case COULD NOT LOOK: match-lib.ps1, commodities.json or the frozen corpus fixture is missing' $false
}

if ($script:ran -ne $script:expectedCases) { Write-Output ("  FAIL  CASE COUNT  ran $($script:ran) case(s), the suite lists $($script:expectedCases)"); $script:fails++ }
if ($script:fails -eq 0) { Write-Output 'test-commodity-rules-lib self-test: PASS (0 failure(s))'; exit 0 }
Write-Output "test-commodity-rules-lib SELF-TEST FAIL: $script:fails failure(s)"
exit 1
