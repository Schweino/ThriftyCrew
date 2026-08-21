<#
  prune-intermediates.ps1 - retention for the capture pipeline's LOCAL scratch.

  These files are gitignored working output, not records: compare-deals.ps1
  regenerates candidates-<date>.json on every run, so deleting an old one loses
  nothing that a re-run cannot rebuild. They were never pruned, and on
  2026-08-21 grocery\out held 408 MB of them growing ~19 MB a day.

  WHY IT IS SAFE TO KEEP ONLY THE NEWEST FEW. Every consumer of
  candidates-*.json takes the newest file and only the newest file:

      audit-capture-eviction.ps1 : Sort-Object Name -Descending | Select -First 1
      audit-coverage-gaps.ps1    : Sort-Object Name -Descending | Select -First 1
      audit-match-soundness.ps1  : Sort-Object Name -Descending | Select -First 1

  Nothing reads a history. -Keep defaults to 3 rather than 1 anyway, because a
  yesterday-vs-today diff is the first thing anyone wants when a number moves
  and it costs ~40 MB to have it.

  THIS FILE DELIBERATELY DOES NOT TOUCH:
    * out\<store>\ capture files  - they are the evidence the graph re-imports
      from, and graph\pipeline\state.py's supersede rule already bounds the
      DATABASE without needing the source files destroyed.
    * anything tracked by git      - see .gitignore; if it is tracked it is a
      record, and records are not scratch.

  Usage:
    powershell -File grocery\prune-intermediates.ps1 -DryRun
    powershell -File grocery\prune-intermediates.ps1 -Keep 3
#>
param(
  [int]$Keep = 3,
  [switch]$DryRun,
  [string]$OutDir
)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
if ($Keep -lt 1) { throw "-Keep must be at least 1: something has to read the newest file." }

$freed = 0L
$killed = 0
$kept = 0

# Only date-stamped candidates files. merge-candidates.ps1 writes an UNDATED
# candidates-500.json that is a different artifact with a different lifecycle,
# and the regex below deliberately does not match it.
$cands = @(Get-ChildItem (Join-Path $OutDir 'candidates-*.json') -ErrorAction SilentlyContinue |
           Where-Object { $_.BaseName -match '^candidates-\d{4}-\d{2}-\d{2}$' } |
           Sort-Object Name -Descending)

if ($cands.Count -eq 0) {
  Write-Output 'no dated candidates-*.json found; nothing to prune'
  exit 0
}

for ($i = 0; $i -lt $cands.Count; $i++) {
  $f = $cands[$i]
  if ($i -lt $Keep) {
    $kept++
    Write-Output ("  KEEP    {0,-34} {1,6:N0} MB" -f $f.Name, ($f.Length / 1MB))
    continue
  }
  $freed += $f.Length
  $killed++
  if (-not $DryRun) { Remove-Item $f.FullName -Force }
}

$verb = if ($DryRun) { 'WOULD DELETE' } else { 'deleted' }
Write-Output ""
Write-Output ("{0} {1} file(s), freeing {2:N0} MB; kept the newest {3}" -f `
              $verb, $killed, ($freed / 1MB), $kept)
if ($DryRun) { Write-Output "(dry run - nothing was removed)" }
exit 0
