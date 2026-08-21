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

# 4. a store that PUBLISHES its own window must never be handed a TTL
foreach ($s in @("Baker's", 'Family Fare', 'Hy-Vee', 'Fareway', 'Aldi')) {
  $r = Get-RollbackWindow -Store $s -ItemId 'x1' -Price 1.00 -Today '2026-08-21' -Root $tmp
  if ($null -ne $r) { Bad "$s was given a rollback TTL - it must use its own published dates"; break }
}
if ($fail -eq 0 -or $true) { if (-not (@("Baker's",'Family Fare','Hy-Vee','Fareway','Aldi') | Where-Object { $null -ne (Get-RollbackWindow -Store $_ -ItemId 'x1' -Price 1.0 -Today '2026-08-21' -Root $tmp) })) { Ok 'only Walmart and Sam''s get a TTL; every dated store is refused one' } }

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
