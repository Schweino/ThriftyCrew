<#
  publish-retry-until-live.ps1 - fires from a Scheduled Task every 20 min and retries the board publish until
  Ghost's admin API accepts it, then DELETES its own task so it stops.

  WHY: 2026-07-15/16 Ghost's admin API began returning "503 first byte timeout" on the board upsert while the
  public site, the admin API READ (200 in 0.3s) and a 168 KB page publish all stayed healthy - i.e. Ghost times
  out PROCESSING the ~1.6 MB lexical card. The board sits right at that ceiling (it accepted 1716 KB earlier the
  same day). Nothing local can force it; it just needs a healthy window. The committed fixes waiting to go live
  include the price-mode fix that pulls Fareway's marked-up DELIVERY prices off the board (a4f11df).

  In-session background loops die with the session; this survives. The 06:30 nightly is the backstop.
  Remove manually with:  schtasks /Delete /TN "TC-BoardPublishRetry" /F
#>
$ErrorActionPreference = 'Continue'
Set-Location 'C:\Codex\income\grocery'
$log   = 'C:\Codex\income\grocery\out\publish-retry.log'
$stamp = (Get-Date -Format 'yyyy-MM-dd HH:mm')

$out = & powershell -ExecutionPolicy Bypass -File publish-deals-page.ps1 2>&1

# CURRENT counts as success too (2026-07-30): publish-deals-page now short-circuits its Ghost upsert when the
# page it built is byte-identical to the live one. That means the board IS live and this task's job is done.
# Without this branch the task would never delete itself - it would keep retrying every 20 minutes until
# something in the board happened to change.
if ($out -match 'PUBLISHED omaha-grocery-prices' -or $out -match 'CURRENT omaha-grocery-prices') {
  Add-Content $log ("{0}  SUCCESS - board is live (published, or already identical to what we would publish). Retry task removing itself." -f $stamp)
  & schtasks /Delete /TN "TC-BoardPublishRetry" /F | Out-Null
  exit 0
}
$why = if ($out -match '503') { '503 (Ghost admin still timing out on the big payload)' } else { 'publish did not confirm' }
Add-Content $log ("{0}  not yet: {1}" -f $stamp, $why)
exit 1
