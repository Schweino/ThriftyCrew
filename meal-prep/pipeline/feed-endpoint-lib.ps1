# feed-endpoint-lib.ps1 - the shared reading of "which price feed will the cards actually fetch".
#
# ONE COPY ON PURPOSE. These four predicates were born inside wave-publish.ps1's P8 serveability gate on
# 2026-08-15. On 2026-08-23 wave-preaudit.ps1 needed the same answer, one stage earlier, so the auditor
# could see the endpoint verdict in its machine report instead of re-deriving it by hand. Two copies of
# "which feed do the cards read" is the exact shape P8 was built to catch one level down - the template
# gets repointed and the second copy keeps validating the old endpoint while reading perfectly green - so
# the functions moved here and both scripts dot-source them.
#
# NOTHING ABOUT THE RULES CHANGED IN THE MOVE. wave-publish.ps1 -SelfTest still owns the fixtures (the
# dead-V3-endpoint case, the history-comment case, the unreadable template, the commented-out URL) and it
# exercises these definitions through this file. If that self-test goes red, this extraction is wrong.
#
# Dot-source:  . (Join-Path $pipelineDir 'feed-endpoint-lib.ps1')
#
# THIS FILE DECLARES NO param() BLOCK, DELIBERATELY - see lib\guard-contract.ps1's header for the measured
# reason (in PS 5.1 a dot-sourced param() block binds in the CALLER's scope and silently resets its
# switches). It also runs nothing on load: it defines and returns.

# The URL the browser will actually fetch. Anchored to a line that is NOT a `//` comment, so a commented
# out or merely discussed URL can never be mistaken for the live one. Returns '' when there is no
# assignment at all, and '' must always REFUSE: could-not-look is never a clean bill (the P6 rule).
function Get-CardFeedUrl {
  param([string]$TemplateText)
  $m = [regex]::Match($TemplateText, "(?m)^(?!\s*//)\s*var\s+SMPFEED\s*=\s*'([^']+)'")
  if (-not $m.Success) { return '' }
  return $m.Groups[1].Value
}

# Exact match against the endpoints this estate genuinely produces. grocery\export-feed.ps1 writes
# smp-feed.json to grocery\out\ and public\, deployed via Cloudflare Pages; measured 2026-08-15,
# feed.thriftycrew.com serves it 200 and the www host 301s to the same asset. Anything else - including
# any V3 platform path - is a URL nobody here can regenerate, which is exactly how the dead endpoint went
# on answering 200 with frozen prices for a month.
$script:PRODUCIBLE_FEEDS = @(
  'https://feed.thriftycrew.com/smp-feed.json',
  'https://www.thriftycrew.com/smp-feed.json'
)
function Test-FeedUrlProducible {
  param([string]$Url, [string[]]$Allowlist)
  if (-not $Url) { return $false }
  return (@($Allowlist) -contains $Url)
}

# THE SECOND COPY. feed-covers-published.ps1 carries its own $FEED_URL literal for its -Live mode. Two
# copies of "which feed do the cards read" is the two-copies-of-a-rule shape: repoint the template again
# and that guard keeps validating the OLD endpoint while reading perfectly green. They must agree, and
# this is the only place that can notice they do not.
function Get-GuardFeedUrl {
  param([string]$GuardText)
  $m = [regex]::Match($GuardText, "(?m)^(?!\s*#)\s*\`$FEED_URL\s*=\s*'([^']+)'")
  if (-not $m.Success) { return '' }
  return $m.Groups[1].Value
}
