<#
feed-export-lib.ps1 - how the daily chain runs grocery\export-feed.ps1 and what it does when the export refuses.

WHY (2026-09-23). Since a1493be0d export-feed.ps1 REFUSES (exit 3, nothing written) when an input file is missing or
a section fell more than 10% against the served feed. check-ad-cycles ran it as `& powershell -File export-feed.ps1 |
Out-Null` and logged "smp-feed exported" on the next statement, so a refusal left YESTERDAY's smp-feed.json served,
the log said it was fresh, and the board shipped beside it: the board and the 583 recipe pages that price off the feed
on different weeks, which is the 2026-09-06 incident made silently (F4, a stale feed nobody is told about).

WHAT IT DOES. Runs the export through Invoke-NativeScript (grocery\native-lib.ps1), so the EXIT CODE is read and a
stderr line under EAP=Stop cannot throw the answer away, and returns { rc, refreshed, why }. On any non-zero exit:
  - logs the refusal WITH its reason (export-feed's own `export-feed: REFUSED - ...` line, or the last line it printed),
  - pages once under the registered type `grocery smp feed export refused` (grocery\alert-registry.json; send-alert's
    once-per-type-per-day gate keeps a second refusal in the same run from paging twice),
  - and the caller passes .why to Write-ChainVerdict -FeedRefused, so the verdict records feed_refreshed=false and
    Read-ChainVerdictStatus reads FEED-REFUSED: capture-run and push-data then stage inputs only, and
    public\board.json does not ship beside a feed that was not refreshed.
The caller dot-sources native-lib.ps1 first and supplies Log and Send-Alert (check-ad-cycles defines both; its
-SelfTest stubs them).
#>

function Invoke-ChainFeedExport {
  param(
    [Parameter(Mandatory = $true)][string]$ScriptPath,
    # Which export this is, for the log line: 'daily' (the main export) or 'quarantine' (the re-export over a board
    # whose cells were quarantined).
    [Parameter(Mandatory = $true)][string]$Stage,
    [string]$AsOf = (Get-Date).ToString('yyyy-MM-dd'),
    [switch]$NoAlert
  )
  $out = [pscustomobject]@{ rc = -1; refreshed = $false; why = ''; paged = $false }
  $res = Invoke-NativeScript $ScriptPath
  $out.rc = [int]$res.ExitCode
  $lines = @($res.Lines)
  if ($out.rc -eq 0) {
    $out.refreshed = $true
    Log ('smp-feed exported (' + $Stage + ', export-feed exit 0)')
    return $out
  }
  $verdictLines = @($lines | Where-Object { [string]$_ -match '^export-feed: ' })
  if ($verdictLines.Count -gt 0) { $out.why = [string]$verdictLines[$verdictLines.Count - 1] }
  else {
    $last = ''; if ($lines.Count -gt 0) { $last = [string]$lines[$lines.Count - 1] }
    $out.why = ('export-feed exited ' + $out.rc + ' and printed no export-feed verdict line; its last line: ' + $last)
  }
  Log ('smp-feed NOT exported (' + $Stage + '): export-feed exited ' + $out.rc + ' - ' + $out.why +
       ' - the served smp-feed.json is still the previous one, and the chain verdict records feed_refreshed=false so public\board.json does not ship beside it')
  if (-not $NoAlert) {
    $body = ('grocery\export-feed.ps1 exited ' + $out.rc + ' during the ' + $Stage + ' export on ' + $AsOf + '.' + "`n`n" +
             $out.why + "`n`n" +
             'The served feed (public\smp-feed.json and grocery\out\smp-feed.json) was NOT rewritten, so it still carries the previous run''s prices. ' +
             'The chain verdict records feed_refreshed=false, so capture-run and push-data stage inputs only and today''s public\board.json does not ship beside the old feed, and the board post is held.' + "`n`n" +
             'Fix the input export-feed names (a missing file is usually a checkout that was not seeded or a producer that did not run; a section drop over 10% is a real fall to investigate, or pass -AcceptShrink ''<reason>'' when it is intended), then re-run grocery\check-ad-cycles.ps1.')
    try {
      Send-Alert -Subject ('Grocery: smp feed export refused - ' + $AsOf) -Body $body | Out-Null
      $out.paged = $true
    } catch { Log ('the feed-refusal page threw: ' + $_.Exception.Message) }
  }
  return $out
}

function Invoke-ChainReaderStep {
  <#
    THE SAME HOLE AT FOUR OTHER STEPS (2026-09-23, swept with the export above). check-ad-cycles ran these with
    `| Out-Null` and logged success on the next statement, and each one's output is something a reader sees:
      build-sale-windows.ps1    sale-windows.json, the sale end dates export-feed serves
      recipe-overlay.ps1        the recipe board's sale overlay, the recipe prices export-feed serves
      publish-deals-page.ps1    the board page republished after the consistency repair
      meal-prep\top5-weekly.ps1 the weekly cheapest-recipe rotation and recipe-costs.json
    A failure left yesterday's copy live under a line saying it was refreshed. This reads the exit code, logs the
    failure with the child's last line, and pages once per step per day under the registered PREFIX type
    `grocery chain step failed`. It does not hold the board: each of these leaves one surface a day old, which is
    a defect to fix and not a reason to withhold today's correct prices everywhere else (the export-feed refusal
    above is different, because the whole feed and the board it pairs with would disagree).
    Returns { rc, ok, why }.
  #>
  param(
    [Parameter(Mandatory = $true)][string]$ScriptPath,
    [string[]]$Arguments = @(),
    # What stays stale when this step fails, for the log line and the page.
    [Parameter(Mandatory = $true)][string]$Stale,
    [Parameter(Mandatory = $true)][string]$OkLog,
    [string]$AsOf = (Get-Date).ToString('yyyy-MM-dd'),
    [switch]$NoAlert
  )
  $name = Split-Path $ScriptPath -Leaf
  $out = [pscustomobject]@{ rc = -1; ok = $false; why = ''; paged = $false }
  $argv = @($ScriptPath) + @($Arguments)
  $res = Invoke-NativeScript @argv
  $out.rc = [int]$res.ExitCode
  if ($out.rc -eq 0) { $out.ok = $true; Log $OkLog; return $out }
  $lines = @($res.Lines)
  $last = ''; if ($lines.Count -gt 0) { $last = [string]$lines[$lines.Count - 1] }
  $out.why = ($name + ' exited ' + $out.rc + '; its last line: ' + $last)
  Log ($name + ' FAILED (exit ' + $out.rc + ') - ' + $Stale + ' is NOT refreshed and stays at its previous copy. Last line: ' + $last)
  if (-not $NoAlert) {
    $body = ($name + ' exited ' + $out.rc + ' in the daily chain on ' + $AsOf + ', so ' + $Stale + ' was NOT refreshed and readers see the previous copy.' + "`n`n" +
             'Its last line: ' + $last + "`n`n" + 'Until 2026-09-23 this step ran into Out-Null and logged success whatever it returned. Run the script by hand to see the full output, fix the cause, then re-run it.')
    try {
      Send-Alert -Subject ('Grocery: chain step failed - ' + $name + ' - ' + $AsOf) -Body $body | Out-Null
      $out.paged = $true
    } catch { Log ('the chain-step page threw: ' + $_.Exception.Message) }
  }
  return $out
}
