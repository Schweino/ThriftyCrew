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
function T([string]$label, [bool]$ok, [string]$got = '') {
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

# ---- CORPUS: the accessor must agree with match-lib on the LIVE rules ----------------------------
# Names are taken from the newest capture so this is the real corpus rather than three hand-written
# strings; if none is readable the case says so and counts as a failure to look, never as a pass.
$mlPath = Join-Path $here 'match-lib.ps1'
$cPath  = Join-Path $here 'commodities.json'
if ((Test-Path $mlPath) -and (Test-Path $cPath)) {
  . $mlPath
  $doc = Get-Content $cPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $names = New-Object System.Collections.Generic.List[string]
  $cap = Get-ChildItem (Join-Path $here 'out\regular\*-regular-*.json') -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1
  if ($cap) {
    try {
      foreach ($d in @((Get-Content $cap.FullName -Raw -Encoding UTF8 | ConvertFrom-Json).deals | Select-Object -First 150)) {
        if ($d.item) { $names.Add([string]$d.item) }
      }
    } catch { }
  }
  # a handful of names that exercise the global list specifically, whatever the capture happens to hold
  foreach ($n in @('Gerber Baby Food Banana', 'Coca-Cola Soda 12 pk', 'Kroger Disinfecting Wipes', 'Fresh Gala Apples')) { $names.Add($n) }
  if (@($names).Count -lt 10) {
    T 'corpus case COULD NOT LOOK: fewer than 10 probe names available (no readable capture)' $false
  } else {
    $dis = Test-TcCommodityRulesAgree -Doc $doc -Names @($names) -GlobalExclude (Get-TcGlobalExclude)
    T ("accessor agrees with match-lib over $(@($names).Count) live name(s) x $(@(Get-TcCommodityList -Doc $doc).Count) commodities") (@($dis).Count -eq 0) (($dis | Select-Object -First 3) -join ' ; ')
  }
} else {
  T 'corpus case COULD NOT LOOK: match-lib.ps1 or commodities.json missing' $false
}

if ($script:fails -eq 0) { Write-Output 'test-commodity-rules-lib self-test: PASS (0 failure(s))'; exit 0 }
Write-Output "test-commodity-rules-lib SELF-TEST FAIL: $script:fails failure(s)"
exit 1
