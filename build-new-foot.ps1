$ErrorActionPreference='Stop'
$foot=[IO.File]::ReadAllText('C:\Codex\income\site-backups\codeinjection-foot-BEFORE-homepage-copy-2026-07-13.html')
$reps=@(
 @('We price-check six grocery stores every morning','We price-check seven grocery stores every morning'),
 @('Every morning we check 90+ staples at six stores in Omaha','Every morning we check 300+ items at seven stores in Omaha'),
 @('Budget, savings, debt payoff, and &ldquo;where do you stand?&rdquo;','Budgets, savings goals, debt payoff, subscription audits, and more.')
)
$new=$foot
foreach($r in $reps){
  $before=$new
  $new=$new.Replace($r[0],$r[1])
  $changed = -not ($before -eq $new)
  Write-Output ("replace ["+$r[0].Substring(0,[Math]::Min(40,$r[0].Length))+"...] changed: "+$changed)
}
Write-Output ("--- checks ---")
Write-Output ("new length: "+$new.Length+"  (old "+$foot.Length+")")
Write-Output ("'six' count now: "+ ([regex]::Matches($new,'six')).Count)
Write-Output ("'90+ staples' present: "+ $new.Contains('90+ staples'))
Write-Output ("'seven grocery stores' present: "+ $new.Contains('seven grocery stores'))
Write-Output ("'300+ items at seven stores' present: "+ $new.Contains('300+ items at seven stores'))
Write-Output ("'subscription audits, and more' present: "+ $new.Contains('subscription audits, and more'))
Write-Output ("interstitial intact: "+ $new.Contains('tc-join-interstitial'))
Write-Output ("em-dash count: "+ ([regex]::Matches($new,[char]0x2014)).Count)
[IO.File]::WriteAllText('C:\Codex\income\site-backups\codeinjection-foot-AFTER-homepage-copy-2026-07-13.html', $new, (New-Object Text.UTF8Encoding($false)))
Write-Output "wrote proposed new foot -> site-backups\codeinjection-foot-AFTER-homepage-copy-2026-07-13.html"