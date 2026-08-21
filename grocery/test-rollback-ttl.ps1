<#
  test-rollback-ttl.ps1 - the frozen fixtures for the rollback TTL ledger.

  THE FOUNDING BUG THIS MUST BE ABLE TO FAIL ON: an anchor that moves. A rollback is re-observed on
  every capture that covers its term, so if first_seen is re-stamped on each sighting the 30-day TTL
  never expires and the board publishes a rollback price forever while reading as governed. The
  must-fire fixture below re-observes the same rollback eleven days later and asserts the window did
  NOT move.

  Run: test-rollback-ttl.ps1        (exit 0 clean, 1 on any failure)
#>
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $root 'rollback-ttl-lib.ps1')
. (Join-Path (Split-Path $root -Parent) 'lib\guard-contract.ps1')

$fail = 0
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("rbttl-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
function Ok($m) { Write-Output "ok    $m" }
function Bad($m) { Write-Output "FAIL  $m"; $script:fail++ }

# 1. first sighting anchors the window at today + 30
$a = Get-RollbackWindow -Store 'Walmart' -ItemId '10450114' -Price 4.87 -Today '2026-08-21' -Root $tmp
if ($a.ad_from -eq '2026-08-21' -and $a.ad_to -eq '2026-09-20' -and $a.is_new) { Ok "first sighting anchors 2026-08-21 .. 2026-09-20 (30d)" }
else { Bad "first sighting produced $($a.ad_from)..$($a.ad_to) is_new=$($a.is_new)" }

# 2. MUST FIRE: the same rollback seen 11 days later must NOT move its anchor.
$b = Get-RollbackWindow -Store 'Walmart' -ItemId '10450114' -Price 4.87 -Today '2026-09-01' -Root $tmp
if ($b.ad_from -eq '2026-08-21' -and $b.ad_to -eq '2026-09-20') { Ok "re-sighting held the anchor (last_seen $($b.last_seen), expiry unchanged)" }
else { Bad "RE-SIGHTING MOVED THE ANCHOR to $($b.ad_from)..$($b.ad_to) - a 30-day TTL that re-anchors never expires" }
if ($b.last_seen -eq '2026-09-01') { Ok 'last_seen advanced while first_seen stood' } else { Bad "last_seen did not advance ($($b.last_seen))" }

# 3. a CHANGED rolled-back price is a different promotion and re-anchors
$c = Get-RollbackWindow -Store 'Walmart' -ItemId '10450114' -Price 3.99 -Today '2026-09-05' -Root $tmp
if ($c.ad_from -eq '2026-09-05' -and $c.ad_to -eq '2026-10-05' -and $c.is_new) { Ok 'a new rolled-back price re-anchors and earns a fresh 30 days' }
else { Bad "price change did not re-anchor ($($c.ad_from)..$($c.ad_to))" }

# 4. WHICH STORES MAY BE GIVEN A TTL AT ALL.
# Updated 2026-08-21 after Brad's ruling: "if product page shows a sale price, but it doesn't match a
# weekly or monthly ad, give it a 30 day TTL" - for FAREWAY. It had been excluded here on the earlier
# understanding that it published its own dates; the browser probe proved it does not for most items
# (itemPromotions empty, promotionGroupId null, on_sale_ind.retailer false).
# The refusals that remain are the ones that matter: a store which DOES publish a window must never
# be handed a guess instead. Baker's states expirationDate per item and Family Fare finish_date per
# offer, and replacing either with 30 days would swap a fact for something worse.
# Hy-Vee and Aldi are refused for a different reason - no ruling has been made for them yet, and a
# TTL nobody chose is not a default, it is an invention.
$allowed = @('Walmart', "Sam's Club", 'Fareway')
$refused = @("Baker's", 'Family Fare', 'Hy-Vee', 'Aldi')
$bad = @()
foreach ($s in $allowed) { if ($null -eq (Get-RollbackWindow -Store $s -ItemId "ok-$s" -Price 1.00 -Today '2026-08-21' -Root $tmp)) { $bad += "$s was REFUSED a TTL but should get one" } }
foreach ($s in $refused) { if ($null -ne (Get-RollbackWindow -Store $s -ItemId "no-$s" -Price 1.00 -Today '2026-08-21' -Root $tmp)) { $bad += "$s was GIVEN a TTL - it publishes its own dates, or none has been ruled for it" } }
if ($bad.Count) { foreach ($m in $bad) { Bad $m } } else { Ok 'Walmart, Sam''s and Fareway get a TTL; every store that publishes its own dates is refused one' }

# 5. no item id means no honest anchor, so no window
$n = Get-RollbackWindow -Store 'Walmart' -ItemId '' -Price 4.87 -Today '2026-08-21' -Root $tmp
if ($null -eq $n) { Ok 'a row with no item id gets no window rather than a name-keyed guess' } else { Bad 'an id-less row was given a window' }

# 6. it survives a round trip to disk with first_seen intact
[void](Save-RollbackLedger $tmp)
$script:RbLedger = $null   # force a reload from the file
$d = Get-RollbackWindow -Store 'Walmart' -ItemId '10450114' -Price 3.99 -Today '2026-10-01' -Root $tmp
if ($d.ad_from -eq '2026-09-05') { Ok 'anchor survived the round trip to disk' }
else { Bad "anchor did not survive persistence (got $($d.ad_from))" }

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Output ("ROLLBACK-TTL " + $(if ($fail) { "FAILED ($fail)" } else { 'PASSED' }))
Write-GuardComplete -Name 'rollback-ttl' -Summary "failed=$fail"
exit $(if ($fail) { 1 } else { 0 })
