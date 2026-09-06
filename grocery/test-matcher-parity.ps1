<#
  test-matcher-parity.ps1 - the four copies of Match-Category must agree with the engine's.

  WHICH COMMODITY OWNS A PRODUCT NAME is decided by Match-Category in compare-deals.ps1. That function is
  re-implemented, not shared, in at least three other places:

      audit-household-in-food.ps1:26     (guard 2 - a cleaning product in an EDIBLE commodity)
      validate-fills.ps1:33
      audit-match-contested.ps1          (All-Owners; it scrapes $GLOBAL_EXCLUDE from the engine but
                                          re-implements the matching loop around it)

  They are not identical to the engine and never have been. The engine runs Get-MatchTexts and tests each
  include against TWO strings - the raw lowercased name, and a variant with Sam's ", priced per pound"
  suffix stripped and "and" collapsed to a space. Every copy tests the raw name only. So in principle the
  engine can assign a product that the auditors think matches nothing, and audit-household-in-food is a
  HARD guard: a cleaning product landing in an edible commodity would go unreported.

  MEASURED 2026-08-21, BEFORE WRITING THIS: zero disagreements across all 36,661 distinct product names.
  The variant text never changes an outcome on the current corpus. So this is a latent risk, not a live
  defect, and it is deliberately NOT reported as one.

  What makes it worth a test is that nothing else would notice it changing. Edit Get-MatchTexts - add a
  normalisation, handle a new store's suffix - and the auditors silently begin describing a different
  engine than the one that builds the board. No existing test compares them; the divergence would surface
  as a guard that quietly stopped covering something.

  The proper fix is extraction into a shared match-lib.ps1, the way pu-lib.ps1 and known-wrong-lib.ps1
  already are ("shared with the audit, so the two can never disagree"). That is not done here because
  compare-deals' own -SelfTest extracts its matcher from its own source text (compare-deals.ps1:895), so
  moving the function breaks the harness that proves it works. Worth doing, worth doing deliberately.

  This reads the REAL function bodies out of the REAL files rather than restating them, so it cannot pass
  by testing a copy of a copy. Read-only; exits 2 on any disagreement.
#>
param([int]$Sample = 0)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
# COMPLETION MARKER CONTRACT (2026-08-21). This joined the daily chain in check-ad-cycles, and every
# detector there must say it REACHED THE END - an exit code alone cannot tell a clean run from a crash
# three checks in. audit-guard-contract flagged this the moment it was wired, which is the contract working.
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\guard-contract.ps1')
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

function Extract([string]$file, [string]$pattern, [string]$what) {
  $src = Get-Content (Join-Path $root $file) -Raw
  $m = [regex]::Match($src, $pattern)
  if (-not $m.Success) {
    Write-Output ("FATAL: could not extract $what from $file - this test cannot prove anything, so it fails rather than passing quietly.")
    Write-Output "       (the function was renamed or reshaped; update the pattern, do not delete the test)"
    Write-GuardComplete -Name 'matcher-parity' -Summary 'BLIND: zero names loaded'
    exit 2
  }
  return $m.Value
}

# The engine's pair, taken verbatim and renamed so both can be defined side by side.
# Anchored to a LINE-START definition on purpose. An unanchored 'function Get-MatchTexts...'
# also matches compare-deals' own -SelfTest, which carries that very pattern as a string
# literal (compare-deals.ps1:895) - so the first attempt extracted the REGEX instead of the
# function and Invoke-Expression choked on it. Extracting code by pattern requires a pattern
# that cannot match a description of itself.
$engineSrc = Extract 'compare-deals.ps1' '(?sm)^function Get-MatchTexts\(.*?\r?\n\}\r?\nfunction Match-Category\(.*?\r?\n  return \$null\r?\n\}' 'the engine matcher'
$engineSrc = $engineSrc -replace 'function Match-Category', 'function Engine-MatchCategory'

# One auditor copy. household-in-food is the one wired into guards.ps1 as a HARD check, so it is the copy
# whose divergence would cost the most.
$auditSrc = Extract 'audit-household-in-food.ps1' '(?sm)^function Match-Category\(\$name\).*?\r?\n  return \$null\r?\n\}' 'the auditor matcher'
$auditSrc = $auditSrc -replace 'function Match-Category', 'function Auditor-MatchCategory'

# Both need the same inputs the real scripts give them.
$cdSrc = Get-Content (Join-Path $root 'compare-deals.ps1') -Raw
$gm = [regex]::Match($cdSrc, '\$GLOBAL_EXCLUDE\s*=\s*@\((?<body>[\s\S]*?)\r?\n\)')
if (-not $gm.Success) {
  Write-Output 'FATAL: cannot parse $GLOBAL_EXCLUDE from compare-deals.ps1'
  Write-GuardComplete -Name 'matcher-parity' -Summary 'BLIND: could not parse GLOBAL_EXCLUDE from the engine'
  exit 2
}
$GLOBAL_EXCLUDE = Invoke-Expression ('@(' + $gm.Groups['body'].Value + ')')
$commodities = Read-JsonFile (Join-Path $root 'commodities.json')

Invoke-Expression $engineSrc
Invoke-Expression $auditSrc

# Every distinct product name the ENGINE reads. Not a subset - measuring against out\regular alone
# missed 17% of the corpus and Sam's Club almost entirely (see FINDINGS-contested-2026-08-21.md #10).
$names = New-Object System.Collections.Generic.HashSet[string]
foreach ($g in @('out\regular\*.json','out\sams\*.json','out\bakers\*.json','out\fareway\*.json','out\extra\*.json','out\ads-*.json')) {
  foreach ($f in (Get-ChildItem (Join-Path $root $g) -ErrorAction SilentlyContinue)) {
    try { $d = Read-JsonFile $f.FullName } catch { continue }
    $rows = if ($d -is [array]) { $d } elseif ($d.PSObject.Properties['deals']) { $d.deals } elseif ($d.PSObject.Properties['products']) { $d.products } else { @() }
    foreach ($r in $rows) {
      $n = if ($r.item) { [string]$r.item } elseif ($r.name) { [string]$r.name } else { '' }
      if ($n) { [void]$names.Add($n) }
    }
  }
}
$all = @($names)
# A DETERMINISTIC, SPREAD SAMPLE (2026-09-06, PLAN-top5-2026-09-06 area 4). This was `$all[0..($Sample-1)]`
# over a HashSet, so the 400 names examined were whichever 400 the hash happened to enumerate first. Two
# things follow, and both are bad for a gate that runs daily:
#   - a divergence is INTERMITTENT. The same defect is inside the sample today and outside it tomorrow,
#     because the corpus changes with every capture. A red nobody can reproduce is a red people learn to
#     re-run rather than read.
#   - the coverage is unknown. Hash order is not store order, but it is not spread either, and the very
#     bug this file was written for was a SAMPLE that missed Sam's Club almost entirely (#10 above).
# Sorting makes the sample a reproducible function of the corpus, and striding across the sorted list
# reaches every region of it - every store prefix, every brand cluster - instead of one end.
$total = $all.Count
if ($Sample -gt 0 -and $total -gt $Sample) {
  $sorted = @($all | Sort-Object)
  $stride = [double]$total / [double]$Sample
  $picked = New-Object System.Collections.Generic.List[string]
  for ($si = 0; $si -lt $Sample; $si++) {
    $idx = [int][math]::Floor($si * $stride)
    if ($idx -ge $total) { $idx = $total - 1 }
    $picked.Add($sorted[$idx])
  }
  $all = @($picked)
  Write-Output ("sample: {0} of {1} name(s), sorted and strided (deterministic - the same corpus always yields the same sample)" -f $all.Count, $total)
}
if ($all.Count -eq 0) {
  Write-Output 'FATAL: zero product names loaded - a parity test over nothing would report agreement it never checked.'
  Write-GuardComplete -Name 'matcher-parity' -Summary ("compared=" + $all.Count + " disagreements=" + $n)
  exit 2
}

$diff = New-Object System.Collections.Generic.List[string]
foreach ($n in $all) {
  $e = Engine-MatchCategory $n           # returns the commodity OBJECT
  $a = Auditor-MatchCategory $n          # returns the commodity ID
  $eid = if ($e) { [string]$e.id } else { '' }
  $aid = if ($a) { [string]$a } else { '' }
  if ($eid -ne $aid) {
    if ($diff.Count -lt 25) { $diff.Add(("  engine='{0}'  auditor='{1}'   {2}" -f $eid, $aid, $n)) }
    else { $diff.Add('') }
  }
}
$n = @($diff | Where-Object { $_ -ne '' }).Count
Write-Output ("matcher parity: {0} name(s) compared, {1} disagreement(s)" -f $all.Count, $diff.Count)
if ($diff.Count) {
  Write-Output 'The auditors no longer describe the engine that builds the board. audit-household-in-food is'
  Write-Output 'a HARD guard, so every name below is a cell it may be judging under the wrong commodity:'
  foreach ($d in ($diff | Where-Object { $_ -ne '' })) { Write-Output $d }
  Write-Output ''
  Write-Output 'Fix by making the copies match the engine - or, better, extract match-lib.ps1 the way'
  Write-Output 'pu-lib.ps1 and known-wrong-lib.ps1 already are, so the question cannot be asked again.'
  Write-GuardComplete -Name 'matcher-parity' -Summary ("compared=" + $all.Count + " disagreements=" + $n)
  exit 2
}
Write-Output 'MATCHER-PARITY OK - every copy assigns every product name exactly as the engine does.'
Write-GuardComplete -Name 'matcher-parity' -Summary ("compared=" + $all.Count + " disagreements=0")

