# site-endpoints.ps1 - THE one place the public feed/Worker URL is written down.
#
# WHY THIS EXISTS (2026-08-08). The smp-feed Worker's address was hardcoded in 11 source files (14 times)
# AND baked into 542 built recipe cards plus the board page. That address is a `workers.dev` subdomain -
# `ancient-snow-93df` - and Cloudflare assigns ONE PER ACCOUNT. So the day the Worker moves to a different
# Cloudflare account (in progress: the estate is consolidating onto admin@thriftycrew.com), every one of
# those references points at a Worker that is no longer there.
#
# The widgets degrade rather than error (each recipe card falls back to its baked-in baseline cost, and the
# board holds its last published prices), so the failure is QUIET - which is exactly the kind that sits for
# weeks. This file makes the source side a one-line change.
#
# THE PERMANENT FIX IS A CUSTOM DOMAIN, not this file. Point the Worker at feed.thriftycrew.com and the URL
# stops depending on which account owns it - that item has been pending since 2026-07-08, blocked precisely
# because the domain and the Worker lived in different Cloudflare accounts. The consolidation unblocks it.
# When that lands, change ONE line here, rebuild, republish. Until then this at least removes the hunt.
#
# Dot-source:  . (Join-Path $repoRoot 'lib\site-endpoints.ps1')
# Self-test:   powershell -File lib\site-endpoints.ps1 -SelfTest
param([switch]$SelfTest)

# The Worker's public base. Change this ONE value on a Cloudflare account move or a custom-domain cutover.
$script:TC_FEED_BASE = 'https://smp-feed.ancient-snow-93df.workers.dev'

function Get-FeedBase { return $script:TC_FEED_BASE }
function Get-FeedUrl  { return ($script:TC_FEED_BASE + '/smp-feed.json') }
function Get-WorkerUrl { param([string]$Path)
  if (-not $Path.StartsWith('/')) { $Path = '/' + $Path }
  return ($script:TC_FEED_BASE + $Path)
}

if ($SelfTest) {
  $f = 0
  function T($m, $c, $g) { if ($c) { Write-Output ("ok    " + $m) } else { Write-Output ("FAIL  " + $m + "   got: " + $g); $script:f++ } }
  T 'the base carries no trailing slash (callers concatenate a rooted path)' (-not (Get-FeedBase).EndsWith('/')) (Get-FeedBase)
  T 'the feed url is the base + /smp-feed.json' ((Get-FeedUrl) -eq ((Get-FeedBase) + '/smp-feed.json')) (Get-FeedUrl)
  T 'Get-WorkerUrl tolerates a path with or without a leading slash' `
    ((Get-WorkerUrl '/alert') -eq (Get-WorkerUrl 'alert')) "$(Get-WorkerUrl '/alert') vs $(Get-WorkerUrl 'alert')"
  T 'it is an https absolute url' ((Get-FeedBase) -match '^https://[a-z0-9.-]+$') (Get-FeedBase)
  if ($f -eq 0) { Write-Output 'SELF-TEST PASS'; exit 0 } else { Write-Output "SELF-TEST FAIL: $f case(s)"; exit 1 }
}
