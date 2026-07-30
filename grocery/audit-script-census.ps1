<#
  audit-script-census.ps1 - every .ps1 in this tree is either called by code, or NAMED here as a deliberate
  human entry point. Nothing is allowed to be merely unreachable.

  WHY (2026-07-30): of the 181 .ps1 under grocery\ (archive\ excluded), 69 were named by no other executable
  file in the repo, and 37 of those sat inside out\ - the pipeline's own OUTPUT directory, where every glob,
  grep and directory listing trips over them. One file in five was unreachable, and at that ratio a listing
  stops being information: promote-verdicts.ps1 (run by hand, writes exclude-provenance.json) looked exactly
  like drop-stale-overrides.ps1 (a finished 2026-07-14 one-shot that would clobber a backup if re-run).

  UNCALLED IS NOT DEAD. Seven of these are launched by hand from a scheduled-agent SKILL, and the SKILLs live
  in ~\.claude\scheduled-tasks\, outside this repo - they are unreferenced here BY CONSTRUCTION and always
  will be. familyfare-sweep.ps1 is launched by Windows Task Scheduler through the generic run-hidden.vbs, so
  its name appears nowhere either. That is why this is a RATCHET against a recorded set, never a hard zero:
  $KNOWN is the written statement of which uncalled scripts are uncalled on purpose, and WHY. Adding a line
  to it is a decision someone has to defend in a diff. That is the entire mechanism.

  TWO INVARIANTS
    1. SET   - no uncalled script outside out\ that is absent from $KNOWN.  (a new orphan appeared)
    2. COUNT - no more .ps1 under out\ than $OutBaseline.                   (a new one-off was dropped in
               the output directory; the number may only be lowered, by archiving them)

  Reference universe is EXECUTABLE files only (.ps1/.psm1/.js/.yml/.yaml/.vbs/.bat/.cmd). Prose is not a
  caller: a script named only in a README or an audit write-up is still unreachable, and counting that as a
  reference would make the whole census evaporate the day the write-up is archived. archive\ is excluded on
  BOTH sides - a reference from archive is a dead reference.

  Exit 0 = clean, 2 = a new orphan or a new out\ one-off, 3 = could not evaluate (never read that as "ok").
  Usage: audit-script-census.ps1 [-Root <dir>] [-ScanRoot <repo>] [-OutBaseline <n>]
#>
param(
  [string]$Root,                  # dir whose .ps1 are the population   (default: this script's dir)
  [string]$ScanRoot,              # dir whose exec files are searched    (default: the repo above $Root)
  [int]$OutBaseline = -1          # max .ps1 allowed under $Root\out\    (default: the frozen baseline below)
)
$ErrorActionPreference = 'Stop'
if (-not $Root)     { $Root     = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path } }
$Root = $Root.TrimEnd('\')
if (-not $ScanRoot) { $ScanRoot = Split-Path -Parent $Root }
$ScanRoot = $ScanRoot.TrimEnd('\')
# FROZEN 2026-07-30: measured count of .ps1 under grocery\out\. May only go DOWN (archive them).
if ($OutBaseline -lt 0) { $OutBaseline = 37 }

# FROZEN 2026-07-30 - the 25 scripts nothing in the repo calls, each with the reason it stays. An entry that
# stops being uncalled (wired in, or archived) prints a note telling you to delete the line; it never fails.
$KNOWN = [ordered]@{
  # -- launched by hand from a scheduled-agent SKILL under ~\.claude\scheduled-tasks\ (not in this repo)
  'build-aldi-regular.ps1'           = 'SKILL grocery-browser-stores-refresh step F2 - weekly Aldi capture builder'
  'build-pull-order.ps1'             = 'SKILL grocery-browser-stores-refresh - priority term order for the walled stores'
  'notify-desktop.ps1'               = 'SKILL grocery-browser-stores-refresh - operator toast during the browser run'
  'resolve-chips-hyvee.ps1'          = 'SKILL grocery-browser-stores-refresh - Hy-Vee link chips'
  'fareway-daily-due.ps1'            = 'SKILL grocery-fareway-daily-check - due gate'
  'select-fareway-shop.ps1'          = 'SKILL grocery-fareway-daily-check - Omaha store picker'
  'pull-fareway-ads.ps1'             = 'SKILL grocery-fareway-daily-check + browser-stores-refresh; stamped into ad-schedule.json'
  # -- launched by Windows Task Scheduler through the GENERIC run-hidden.vbs, so no file names it
  'familyfare-sweep.ps1'             = 'scheduled task "SMP Family Fare Term Sweep", every 3h via run-hidden.vbs'
  # -- human entry points, run when a specific failure or a specific job shows up
  'promote-verdicts.ps1'             = 'weekly by hand after audit-match-soundness; writes exclude-provenance.json'
  'audit-ff-missing-products.ps1'    = 'report half of the FF partial-pull pair; the -Apply half is heal-ff-missing-products.ps1'
  'triage-outofband.ps1'             = 'sub-diagnoses the OUT-OF-BAND bucket of triage-coverage-gaps.ps1'
  'triage-unpriced.ps1'              = 'sub-diagnoses the UNPRICED bucket of triage-coverage-gaps.ps1'
  'verify-no-regression.ps1'         = 'run before/after a commodity include edit - the first-match-wins theft check'
  'diag-ff.ps1'                      = 'Freshop term/match diagnostic, -Ids <id...>'
  'test-unitprice.ps1'               = 'per-unit math bench, run while editing pu-lib.ps1'
  'build-drift-chips.ps1'            = 'browser link pass - chips whose link points at the WRONG product (sibling of build-nolink-chips.ps1)'
  'transform-store-links.ps1'        = 'browser link pass - generic successor to archive\transform-bakers-links.ps1'
  'stamp-fareway-instore.ps1'        = 'stamps Fareway price_mode after a manual shelf verification'
  'recover-sams-quarantine.ps1'      = "recovers a quarantined Sam's capture"
  'get-tiers.ps1'                    = 'Ghost tier lookup, used while editing the join interstitial'
  # -- staples-500 per-batch pipeline (batch 1 of 10 done; run once per batch, by hand)
  'prime-batch-headless.ps1'         = 'staples-500 per-batch primer'
  'merge-candidates.ps1'             = 'staples-500 per-batch candidate merge'
  # -- member-tool data builds, on demand after a recipe/price change
  'build-freezer-data.ps1'           = 'data build for the freezer-math tool'
  'build-sams-data.ps1'              = "data build for the Sam's tool"
  'build-staples-data.ps1'           = 'data build for the my-staples watchlist'
  # -- brand-pricing pilot, parked pending Brad's scale decision
  'brands\make-config.ps1'           = 'brand-pricing pilot'
  'brands\gen-browser-cfg.ps1'       = 'brand-pricing pilot'
  'brands\pull-ff-brands-batch.ps1'  = 'brand-pricing pilot'
  'brands\assemble-board-brands.ps1' = 'brand-pricing pilot'
  'brands\regression-brands.ps1'     = 'brand-pricing pilot'
  # -- finished one-shots still in the tree on 2026-07-30. Both were verified to change ZERO records today
  # and both unconditionally rewrite live data plus a hardcoded 2026-07-14 backup name, so re-running one
  # DESTROYS that backup. Delete these two lines once they are in archive\one-off\.
}

# -Filter *.ps1 is the legacy 8.3 matcher and also matches .ps1xml, so the extension is re-checked exactly.
$all = @(Get-ChildItem -Path $Root -Filter *.ps1 -Recurse -File -ErrorAction SilentlyContinue |
         Where-Object { $_.Extension -eq '.ps1' -and $_.FullName -notmatch '\\archive\\' })
$pop  = @($all | Where-Object { $_.FullName.Substring($Root.Length + 1) -notmatch '^out\\' })
$inOut= @($all | Where-Object { $_.FullName.Substring($Root.Length + 1) -match  '^out\\' })

$exts = '.ps1','.psm1','.js','.yml','.yaml','.vbs','.bat','.cmd'
# THIS FILE MUST NOT BE A SOURCE. $KNOWN quotes 33 script names; counting it would make every one of them
# "referenced" and the census would report a clean zero forever - a gate that can never arm. (Same reason
# test-auditors.ps1 skips itself when it greps for the logger pattern.)
$self = $MyInvocation.MyCommand.Path
$src = @(Get-ChildItem -Path $ScanRoot -Recurse -File -ErrorAction SilentlyContinue |
         Where-Object { $exts -contains $_.Extension.ToLower() -and
                        $_.FullName -ne $self -and
                        $_.FullName -notmatch '\\archive\\' -and
                        $_.FullName -notmatch '\\node_modules\\' -and
                        $_.FullName -notmatch '\\\.git\\' })

# A check that examined NOTHING must say so. Every population script is itself a source file, so src can only
# be smaller than pop if the roots are wrong or the tree is not checked out - and "0 orphans" from that is a
# lie, not a pass. Exit 3 is this estate's could-not-evaluate code.
if ($all.Count -eq 0 -or $src.Count -lt $all.Count) {
  Write-Output ("script-census: BLIND - " + $all.Count + " script(s) under " + $Root + " against only " +
                $src.Count + " executable file(s) under " + $ScanRoot + ". Nothing was examined; this proves nothing.")
  exit 3
}

$text = @{}
foreach ($f in $src) {
  try { $t = Get-Content $f.FullName -Raw -ErrorAction Stop } catch { $t = '' }
  $text[$f.FullName] = ($t + '')   # [string]$null is $null, not '' - the + '' is load-bearing on a zero-byte file
}

$uncalled = New-Object System.Collections.ArrayList
foreach ($p in $pop) {
  $hit = $false
  foreach ($k in $text.Keys) {
    if ($k -eq $p.FullName) { continue }                                   # a script naming itself is not a caller
    if ($text[$k].IndexOf($p.Name, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $hit = $true; break }
  }
  if (-not $hit) { [void]$uncalled.Add($p.FullName.Substring($Root.Length + 1)) }
}

$new  = @($uncalled | Where-Object { -not $KNOWN.Contains($_) })
$gone = @($KNOWN.Keys | Where-Object { $uncalled -notcontains $_ })
$fail = New-Object System.Collections.ArrayList

Write-Output ("script-census: " + $pop.Count + " script(s) + " + $inOut.Count + " under out\, read against " +
              $src.Count + " executable file(s); " + $uncalled.Count + " uncalled, " + $KNOWN.Count + " recorded as deliberate")
if ($gone.Count -gt 5) { Write-Output ("  note    " + $gone.Count + " recorded entries are no longer uncalled here - drop their KNOWN lines") }
else { foreach ($g in $gone) { Write-Output ("  note    " + $g + " is called again (or archived) - drop its KNOWN line") } }
foreach ($n in $new)  { [void]$fail.Add("ORPHAN " + $n + " - no executable file in the repo names it") }
if ($inOut.Count -gt $OutBaseline) {
  [void]$fail.Add("out\ grew to " + $inOut.Count + " .ps1 (baseline " + $OutBaseline + ") - a one-off was written into the pipeline's OUTPUT directory")
} elseif ($inOut.Count -lt $OutBaseline) {
  Write-Output ("  note    out\ is down to " + $inOut.Count + " .ps1 - lower OutBaseline to hold the ground")
}

if ($fail.Count -eq 0) { Write-Output ("  ok      no unrecorded orphan; out\ holds " + $inOut.Count + " one-off(s), at or under baseline"); exit 0 }
foreach ($m in $fail) { Write-Output ("  FAIL    " + $m) }
Write-Output ("script-census FAIL: " + $fail.Count + " finding(s). Wire it in, move it to archive\one-off\, or record it in KNOWN with the reason it stays uncalled.")
exit 2
