<#
  apply-category-excludes.ps1 - bake the category-exclude LIBRARY (category-excludes.json) into every
  commodity's own exclude list, by category. This is how NEW commodities are born with the guardrails instead of
  earning them after a wrong match ships (the blueberries-as-Bai-beverage class). Idempotent - safe to re-run
  any time; it only ever ADDS patterns that are missing, never removes or reorders what a commodity already has.

  THE WORKFLOW FOR NEW ITEMS: register the commodity in commodities.json + its category in categories.json,
  then run THIS, then compare-deals. audit-food-category.ps1 (same library) hard-fails the publish if a
  wrong-class product still slips through some other way.

  After running, ALWAYS re-run compare-deals and diff the board (diff-board.ps1 out\vetbase.json <new>) - an
  exclude that drops a store's only match turns a priced cell into "no price", and that must be a reviewed
  correction, not a surprise.
#>
param([switch]$WhatIf, [string]$Root = '')
$ErrorActionPreference = 'Stop'
# -Root exists ONLY so test-auditors can point this script at a frozen fixture tree and prove the drift
# detector still detects drift. Live behaviour is byte-identical: with no -Root it is $PSScriptRoot, as before.
# PowerShell variable names are CASE-INSENSITIVE, so $Root and $root are the SAME variable - this one line
# both honours an explicit -Root and defaults it. Do not "tidy" it into two names; they cannot be two names.
if (-not $root) { $root = $PSScriptRoot }
$lib = Get-Content (Join-Path $root 'category-excludes.json') -Raw | ConvertFrom-Json
$cat = @{}
foreach ($c in (Get-Content (Join-Path $root 'categories.json') -Raw | ConvertFrom-Json).categories) {
  foreach ($id in @($c.commodities)) { $cat[[string]$id] = [string]$c.label }
}
$commods = Get-Content (Join-Path $root 'commodities.json') -Raw -Encoding UTF8 | ConvertFrom-Json

$added = 0; $touched = 0
foreach ($cm in $commods) {
  $label = $cat[[string]$cm.id]
  if (-not $label) { continue }
  $classes = $null
  foreach ($a in $lib.apply) { if ($label -match [string]$a.categories) { $classes = @($a.classes); break } }
  if (-not $classes) { continue }
  $have = @($cm.exclude)
  $new = @()
  foreach ($cl in $classes) {
    $ex = [string]$lib.exempt.$cl
    if ($ex -and ([string]$cm.id -match $ex)) { continue }
    foreach ($pat in @($lib.classes.$cl)) { if (($have -notcontains $pat) -and ($new -notcontains $pat)) { $new += $pat } }
  }
  if ($new.Count) { $cm.exclude = @($have + $new); $added += $new.Count; $touched++ }
}
Write-Output ("category-exclude library: +$added patterns across $touched commodities")
if ($WhatIf) { Write-Output 'WhatIf: commodities.json not written'; return }
# WRITE IT BACK IN THE ENCODING THE FILE IS PINNED TO (2026-09-02, triage plan-2026-09-02-2 item 1527d2).
# commodities.json expresses every non-ASCII character as a JSON \uXXXX escape and carries no BOM. That is
# not a preference: audit-json-encoding.ps1 lists it in ASCII_PINNED and a single non-ASCII byte is a hard
# finding there, because the 2026-08-31 mojibake pass proved that a corrupted character CLASS goes on
# matching the plain spelling while silently losing the accented one.
# ConvertTo-Json emits those characters LITERALLY (the \uXXXX escapes decode on read and never come back)
# and Set-Content -Encoding UTF8 prepends a BOM, so the plain one-line write this used to be turned even a
# NO-OP bake into 84 non-ASCII bytes plus a BOM. Measured on a scratch copy of the live tree 2026-09-02:
# "+0 patterns across 0 commodities" still rewrote the file into a PINNED finding for ops\run-gates.ps1.
# The 2026-08-31 pass fixed this script's READ (-Encoding UTF8, above) and left its WRITE, so the guard and
# the sanctioned tool that violates it have been shipping side by side ever since.
# test-auditors.ps1 case (ce1) runs this script over a fixture whose rule carries ñ and fails if the
# output stops being pure ASCII or grows a BOM.
function Write-AsciiPinnedJson {
  param([Parameter(Mandatory)][string]$Json, [Parameter(Mandatory)][string]$Path)
  $sb = New-Object System.Text.StringBuilder
  foreach ($ch in $Json.ToCharArray()) {
    if ([int]$ch -gt 127) { [void]$sb.AppendFormat('\u{0:x4}', [int]$ch) } else { [void]$sb.Append($ch) }
  }
  # Set-Content terminated the file with a newline and the stored file has always carried one; WriteAllText
  # does not, and a missing terminator is a whole-line diff on the last line for no reason.
  [void]$sb.Append("`r`n")
  [IO.File]::WriteAllText($Path, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
}
Write-AsciiPinnedJson -Json ($commods | ConvertTo-Json -Depth 6) -Path (Join-Path $root 'commodities.json')
$null = Get-Content (Join-Path $root 'commodities.json') -Raw -Encoding UTF8 | ConvertFrom-Json   # validate round-trip
Write-Output 'commodities.json updated (JSON validated)'
