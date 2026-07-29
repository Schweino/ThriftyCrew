<#
  weekly-post-capture.ps1 - the DETERMINISTIC tail of the weekly browser-stores refresh, wrapped in one
  orchestrator so the Wednesday agent spends its tokens on captures + judgment, not on shepherding a
  dozen script calls (2026-07-26 token-diet item; same conversion pattern as bakers-daily-scan.ps1).

  THREE PHASES, called by the agent at its natural pause points:

    -Phase compare  [-BakersFile x] [-SamsFile x] [-FarewayFile x]
        compare-deals (-MinStores 1 + the capture files) -> audit-coverage-gaps -> audit-sale-fallback
        -> update-history -> verify-prep.
        THEN THE AGENT JUDGES: verify-input entries (step H verdicts -> verify-verdicts-<today>.json),
        coverage-gap regex widenings, multibuy/BOGO extra-deals. Re-run -Phase compare after any fix
        that changes inputs (idempotent).

    -Phase publish
        verify-apply -> verify-apply (MinStores 1 -> verified-history, so the long tail keeps its history)
        -> update-history (banks the VERIFIED board, never the raw comparison) -> sanity-check (flags
        REPORTED) -> guards.ps1 (HARD gate: exit 2 = HELD - the SAME gate check-ad-cycles runs daily) ->
        publish-deals-page (self-gates on coverage; HELD is a real stop) -> resolve-worklist.
        THEN THE AGENT RESOLVES LINKS: browser re-resolve of url-worklist chips (step K2).

    -Phase links
        merge-product-urls -> resolve-worklist (re-flag) -> stamp-board-pu -> publish-deals-page ->
        audit-links + audit-name-drift (reported) -> push-data.

  Every step is stderr-tolerant but exit-code-strict (RunChild); failures print FAIL and exit 1 so the
  agent can react. Log: out\logs\weekly-post-capture-<yyyy-MM>.log
#>
param(
  [Parameter(Mandatory)][ValidateSet('compare','publish','links')][string]$Phase,
  [string]$BakersFile = '', [string]$SamsFile = '', [string]$FarewayFile = ''
)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$logDir = Join-Path $root 'out\logs'
New-Item -ItemType Directory -Force $logDir | Out-Null
$log = Join-Path $logDir ('weekly-post-capture-' + (Get-Date -Format 'yyyy-MM') + '.log')
# a locked log file must never kill the capture - see the note in check-ad-cycles.ps1 (2026-07-28)
function Log([string]$m){
  $line=(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')+'  ['+$Phase+'] '+$m
  for ($i = 0; $i -lt 5; $i++) { try { Add-Content -Path $log -Value $line -ErrorAction Stop; break } catch { Start-Sleep -Milliseconds 120 } }
  Write-Host $line
}
function RunChild([string]$file,[object[]]$childArgs,[int]$keep=2,[string]$tag='step',[switch]$NonFatal){
  $prev=$ErrorActionPreference; $ErrorActionPreference='Continue'
  try {
    $out = & powershell -ExecutionPolicy Bypass -File $file @childArgs 2>&1 | ForEach-Object { [string]$_ }
    $ec = $LASTEXITCODE
    @($out | Select-Object -Last $keep) | ForEach-Object { Log ($tag + ': ' + $_) }
    if($ec -ne 0 -and -not $NonFatal){ throw ("{0} exited {1}" -f (Split-Path $file -Leaf), $ec) }
    return [int]$ec
  } finally { $ErrorActionPreference = $prev }
}

try {
  switch ($Phase) {
    'compare' {
      $cmpArgs = @('-MinStores','1')
      if($BakersFile){ $cmpArgs += @('-BakersFile',$BakersFile) }
      if($SamsFile){ $cmpArgs += @('-SamsFile',$SamsFile) }
      if($FarewayFile){ $cmpArgs += @('-FarewayFile',$FarewayFile) }
      $null = RunChild (Join-Path $root 'compare-deals.ps1') $cmpArgs 3 'compare'
      $null = RunChild (Join-Path $root 'audit-coverage-gaps.ps1') @() 3 'coverage' -NonFatal
      $null = RunChild (Join-Path $root 'audit-sale-fallback.ps1') @() 3 'fallback' -NonFatal
      # NOTE: update-history deliberately does NOT run here. It used to, and that banked the week's "cheapest"
      # from the board BEFORE the semantic verify - so every wrong-product winner the verify pass exists to
      # catch set a RECORD LOW on its way out (strawberries $0.0833 from an applesauce, honey $0.1244 from hot
      # dog buns). It now runs in -Phase publish, after verify-apply. See grocery-engine-guards.
      $null = RunChild (Join-Path $root 'verify-prep.ps1') @() 2 'verify-prep'
      Log 'PHASE compare DONE. Agent: judge verify-input entries (write verify-verdicts), review coverage/fallback/multibuy flags, then -Phase publish.'
    }
    'publish' {
      $null = RunChild (Join-Path $root 'verify-apply.ps1') @() 2 'verify-apply'
      # Price history banks the VERIFIED board, never the raw comparison. Built at MinStores 1 into its own
      # file so the ~24 single-store long-tail commodities keep their history even though MinStores 2 keeps
      # them off the published page - that is the only reason history used to run against the raw board.
      $histFile = 'verified-history.json'
      $null = RunChild (Join-Path $root 'verify-apply.ps1') @('-MinStores','1','-OutFile',$histFile) 2 'verify-history'
      $null = RunChild (Join-Path $root 'update-history.ps1') @('-CompareFile',(Join-Path $root ('out\' + $histFile))) 1 'history'
      $null = RunChild (Join-Path $root 'sanity-check.ps1') @() 4 'sanity' -NonFatal
      $g = Join-Path $root ('out\guards-' + (Get-Date -Format 'yyyy-MM-dd') + '.json')
      if(Test-Path $g){ Log ('sanity flags file present: ' + $g + ' - REVIEW before trusting the board.') }
      # THE SAME GATE THE DAILY JOB USES (added 2026-07-29). guards.ps1 was wired into check-ad-cycles only, so
      # the WEEKLY path could publish a board the daily hard gate would refuse - and did. On 2026-07-29 this
      # run published cleanly, then guards.ps1 on the identical data reported four hard fails: three Aldi
      # multipack rows recording ONE unit as the whole pack, and a Sam's "brown rice" that was a Seeds of
      # Change quinoa microwave pouch at $3.76/lb. Later passes caught 4-gallon bin liners winning the
      # 13-GALLON kitchen-bag row and liquid cold brew crowning ground coffee. Two paths to publish must not
      # have two definitions of "safe".
      $gc = RunChild (Join-Path $root 'guards.ps1') @() 4 'guards' -NonFatal
      if($gc -eq 2){ Log 'publish HELD by guards.ps1 - a HARD invariant is violated (see the guards lines above). Fix the data, then re-run -Phase publish.'; exit 2 }
      if($gc -ne 0){ throw "guards.ps1 exited $gc" }
      $rc = RunChild (Join-Path $root 'publish-deals-page.ps1') @() 3 'publish' -NonFatal
      if($rc -eq 2){ Log 'publish HELD by coverage gate - fix the thin store, then re-run -Phase publish.'; exit 2 }
      if($rc -ne 0){ throw "publish-deals-page exited $rc" }
      $null = RunChild (Join-Path $root 'resolve-worklist.ps1') @() 2 'worklist'
      Log 'PHASE publish DONE. Agent: browser-resolve the url-worklist chips (per-store method memories), then -Phase links.'
    }
    'links' {
      $null = RunChild (Join-Path $root 'merge-product-urls.ps1') @() 2 'merge'
      $null = RunChild (Join-Path $root 'resolve-worklist.ps1') @() 2 'reflag'
      $null = RunChild (Join-Path $root 'stamp-board-pu.ps1') @() 2 'stamp'
      $rc = RunChild (Join-Path $root 'publish-deals-page.ps1') @() 3 'republish' -NonFatal
      if($rc -eq 2){ Log 'republish HELD by coverage gate (unusual at this stage) - investigate.'; exit 2 }
      if($rc -ne 0){ throw "publish-deals-page exited $rc" }
      $null = RunChild (Join-Path $root 'audit-links.ps1') @() 3 'audit-links' -NonFatal
      $null = RunChild (Join-Path $root 'audit-name-drift.ps1') @() 3 'name-drift' -NonFatal
      $null = RunChild (Join-Path $root 'push-data.ps1') @() 1 'push'
      Log 'PHASE links DONE. Agent: report audit-links/name-drift residue; re-resolve any form-flips and re-run -Phase links if needed.'
    }
  }
  exit 0
} catch {
  Log ('FAIL: ' + $_.Exception.Message)
  exit 1
}