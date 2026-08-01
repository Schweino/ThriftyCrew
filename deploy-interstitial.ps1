# deploy-interstitial.ps1 - build + gate the join-interstitial payload for codeinjection_foot.
#
# WHAT CHANGED 2026-08-01: this used to attempt the settings PUT with the Ghost Admin API key. That key
# is READ-ONLY for /settings/ and returns 403 (re-probed and confirmed the same day), so the "deploy"
# half never worked and the script's success path was unreachable. It now does the parts it CAN do
# correctly - build, minify, and gate the payload against the live value - and hands you an exact,
# pre-checked block to paste through a logged-in owner browser session, which is the only route that
# writes settings.
#
# It also MINIFIES. income\join-interstitial.html is the source of truth and carries the rationale in
# comments; codeinjection_foot has under a thousand spare characters, so comments must not ship. Same
# split the page builders use: readable in the repo, compact on the wire.
#
#   .\deploy-interstitial.ps1              build + gate, write out\interstitial-deploy.html
#   .\deploy-interstitial.ps1 -ShowPayload also print the payload
param([switch]$ShowPayload)
$ErrorActionPreference='Stop'
$root='C:\Codex\income'
. (Join-Path $root 'lib\ghost-lib.ps1')
. (Join-Path $root 'lib\design-tokens.ps1')

$srcFile = Join-Path $root 'join-interstitial.html'
$src = [IO.File]::ReadAllText($srcFile)

# strip the source-only rationale header, keep the marker the splice keys on
$i = $src.IndexOf('-->')
if($i -lt 0){ throw 'source is missing its leading comment block' }
$payload = '<!-- tc-join-interstitial v3 (2026-08-01) :: source of truth = income/join-interstitial.html -->' + $src.Substring($i+3)
$min = Compress-TcAsset $payload
$min = (($min -split "`n" | ForEach-Object { $_.TrimEnd() } | Where-Object { $_ -ne '' }) -join "`n").Trim()

# ---- GATES. Minification is a text transform on live conversion machinery, so every load-bearing token
# is asserted present afterwards. A prompt that silently loses its frequency cap would show on every
# page view; one that loses its paid-member check would nag the people already paying.
$must = @(
  '<!-- tc-join-interstitial','<!-- /tc-join-interstitial -->',
  'id="tcji-ov"','class="tcji-join"','data-tcji="join"','data-tcji="no"','tcji-big','tcji-free',
  'tc_ji_until','tc_ji_count','tc_ji_sess','tc_seen','tc_ji_defer',
  'tc-mode-open','tc:mode','if(waiting) return',
  'free-dinners.json','m.paid===true','portal/signup',
  'c>=3?168:(c===2?48:24)','join_crew_click','Escape',
  'overflow:auto','margin:auto'
)
$missing = @($must | Where-Object { -not $min.Contains($_) })
if($missing.Count){ throw ("minification dropped load-bearing tokens: " + ($missing -join ', ')) }

# ---- BUDGET. Ghost rejects an over-length settings value with a 422; nothing is lost, but the deploy
# silently does not happen. Measure against the LIVE foot before anyone pastes anything.
$jwt = Get-GhostJWT -Key (Get-GhostKey)
$s = Invoke-GhostApi -Uri 'https://map-to-success.ghost.io/ghost/api/admin/settings/' -Headers @{Authorization="Ghost $jwt";'Accept-Version'='v5.0'}
$foot = ($s.settings | Where-Object { $_.key -eq 'codeinjection_foot' }).value
$A='<!-- tc-join-interstitial'; $B='<!-- /tc-join-interstitial -->'
$si=$foot.IndexOf($A); $ei=$foot.IndexOf($B)
if($si -lt 0 -or $ei -lt $si){ throw 'live foot has no interstitial block between the markers' }
if(([regex]::Matches($foot,[regex]::Escape($A))).Count -ne 1){ throw 'interstitial start marker is not unique in the live foot' }
$projected = $foot.Substring(0,$si) + $min + $foot.Substring($ei+$B.Length)
Write-Output ("live foot       : {0} chars" -f $foot.Length)
Write-Output ("current block   : {0} chars" -f ($ei-$si+$B.Length))
Write-Output ("new payload     : {0} chars  (source {1}, minified {2:P0} smaller)" -f $min.Length, $src.Length, (1-($min.Length/$src.Length)))
Write-Output ("projected foot  : {0} of 65535   FREE AFTER: {1}" -f $projected.Length, (65535-$projected.Length))
if($projected.Length -gt 65535){ throw ("OVER BUDGET by " + ($projected.Length-65535) + " chars - Ghost would 422 this. Trim before deploying.") }

# nothing outside the block may move: the two Google Ads conversions and the Meta pixel live in the same field
foreach($keep in @('AW-18314028055/L3pzCL3vos4cEJfI55xE','AW-18314028055/WbmmCMDvos4cEJfI55xE','Meta Pixel')){
  if(-not $projected.Contains($keep)){ throw ("the projected foot lost '" + $keep + "' - the splice is wrong, do not deploy") }
}
Write-Output ("gates           : {0} load-bearing tokens present, both Ads conversions + Meta pixel intact" -f $must.Count)

$outDir = Join-Path $root 'out'
if(-not (Test-Path $outDir)){ New-Item -ItemType Directory -Force $outDir | Out-Null }
$outFile = Join-Path $outDir 'interstitial-deploy.html'
[IO.File]::WriteAllText($outFile, $min, (New-Object Text.UTF8Encoding($false)))
Write-Output ("payload written : {0}" -f $outFile)
Write-Output ''
Write-Output 'TO DEPLOY (the Admin API key is read-only for /settings/ and returns 403):'
Write-Output '  1. open a Chrome tab logged in as owner at map-to-success.ghost.io/ghost'
Write-Output '  2. GET  /ghost/api/admin/settings/ with credentials:"include"'
Write-Output '  3. splice the new payload between the two tc-join-interstitial markers'
Write-Output '  4. PUT  /ghost/api/admin/settings/ with {settings:[{key:"codeinjection_foot",value:<spliced>}]}'
Write-Output '  5. re-fetch the public homepage and confirm the v3 marker, both Ads conversion labels,'
Write-Output '     and that the block appears exactly once'
if($ShowPayload){ Write-Output ''; Write-Output $min }
exit 0   # explicit: without it the script exited 255 on success, which any caller would read as a failure
