# test-link-identity-lib.ps1 - fixtures for link-identity-lib.ps1 (design/PLAN-link-rides-with-price-2026-09-27.md L1).
# Hermetic: no board, no capture files. Exit 0 only when every case passes; last line is the verdict.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'link-identity-lib.ps1')
$script:fail = 0; $script:ran = 0
function Assert-Case([string]$Name, [bool]$Ok, [string]$Got) {
  $script:ran++
  if ($Ok) { Write-Output ('  ok    ' + $Name) } else { Write-Output ('  FAIL  ' + $Name + ' (got: ' + $Got + ')'); $script:fail++ }
}
try {
  # MUST FIRE: the founding gap. Walmart rows carry item_id and no link_url (459 of 459 on 2026-09-27).
  $wm = [pscustomobject]@{ item = 'Great Value Whole Milk'; item_id = '10450114'; link_url = '' }
  $u = Get-TcRowUrl 'Walmart' $wm
  Assert-Case 'MUST FIRE Walmart row with item_id and empty link_url gets /ip/<id>' ($u -eq 'https://www.walmart.com/ip/10450114') $u
  $s = Get-TcLinkSource $u $true
  Assert-Case 'MUST FIRE that row is link_source=row' ($s -eq 'row') $s

  # MUST NOT FIRE: a flyer line has no capture row, so no URL may be invented for it.
  $u = Get-TcRowUrl 'Hy-Vee' $null
  Assert-Case 'MUST NOT FIRE flyer line (no capture row) gets no link' ($null -eq $u) ([string]$u)
  $s = Get-TcLinkSource ([string]$u) $false
  Assert-Case 'MUST NOT FIRE flyer line is link_source=ad' ($s -eq 'ad') $s

  # CLEAN TWIN: a Fareway storefront SALE row keeps its product link (keyed on source, never type=sale).
  $fw = [pscustomobject]@{ item = 'Fareway Butter'; type = 'sale'; link_url = 'https://shop.fareway.com/product/123' }
  $u = Get-TcRowUrl 'Fareway' $fw
  Assert-Case 'CLEAN TWIN Fareway storefront sale row keeps its observed link' ($u -eq 'https://shop.fareway.com/product/123') $u

  # MUST FIRE: a storefront row with no identity is a capture defect, not an ad.
  $bare = [pscustomobject]@{ item = 'Aldi Eggs'; link_url = '' }
  $u = Get-TcRowUrl 'Aldi' $bare
  $s = Get-TcLinkSource ([string]$u) $true
  Assert-Case 'MUST FIRE storefront row with no identity is link_source=none' (($null -eq $u) -and ($s -eq 'none')) ([string]$u + '/' + $s)

  # MUST NOT FIRE: Family Fare canonical_url is taken verbatim, a product_id alone never builds one.
  $ff = [pscustomobject]@{ item = 'Eggs'; product_id = '555' }
  $u = Get-TcRowUrl 'Family Fare' $ff
  Assert-Case 'MUST NOT FIRE Family Fare product_id alone builds no URL' ($null -eq $u) ([string]$u)

  # Sam's alphanumeric id: refused unless the shape is proven; CLEAN TWIN numeric id always builds.
  $sm = [pscustomobject]@{ item = 'MM Eggs'; sams_item_id = 'P03012345' }
  $u = Get-TcRowUrl "Sam's Club" $sm $false
  Assert-Case "MUST NOT FIRE Sam's alphanumeric id with the shape unproven" ($null -eq $u) ([string]$u)
  $u = Get-TcRowUrl "Sam's Club" $sm $true
  Assert-Case "MUST FIRE Sam's alphanumeric id with the shape proven" ($u -eq 'https://www.samsclub.com/ip/P03012345') ([string]$u)
  $u = Get-TcRowUrl "Sam's Club" ([pscustomobject]@{ item = 'x'; item_id = '98765' }) $false
  Assert-Case "CLEAN TWIN Sam's numeric id builds without the shape proof" ($u -eq 'https://www.samsclub.com/ip/98765') ([string]$u)

  # Hy-Vee product_id builds the aisles-online URL.
  $u = Get-TcRowUrl 'Hy-Vee' ([pscustomobject]@{ item = 'Hy-Vee 2% Milk, 1 gal'; product_id = '42' })
  Assert-Case 'MUST FIRE Hy-Vee product_id builds the aisles-online URL' ($u -eq 'https://www.hy-vee.com/aisles-online/p/42/hy-vee-2-milk-1-gal') ([string]$u)

  # Get-TcLinkOwed (L5): a priced tile with no link is an owed re-read, read off the newest board.
  $script:scratch = Join-Path ([IO.Path]::GetTempPath()) ('tlil-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Path $script:scratch -ErrorAction Stop | Out-Null
  $board = '{"comparison":[' +
    '{"id":"eggs","stores":[{"store":"Aldi","per_unit":0.2,"link_source":"none"},{"store":"Walmart","per_unit":0.2,"link_source":"row","link":"https://www.walmart.com/ip/1"}]},' +
    '{"id":"milk","stores":[{"store":"Aldi","per_unit":3.1,"link_source":"row","link":"https://www.aldi.us/x"}]},' +
    '{"id":"bread","stores":[{"store":"Aldi","per_unit":null,"link_source":"none"},{"store":"Family Fare","per_unit":1.5,"link_source":"none"}]}]}'
  [IO.File]::WriteAllText((Join-Path $script:scratch 'comparison-2026-09-27.json'), $board)
  [IO.File]::WriteAllText((Join-Path $script:scratch 'comparison-2026-09-20.json'), '{"comparison":[{"id":"milk","stores":[{"store":"Aldi","per_unit":3,"link_source":"none"}]}]}')
  $lo = Get-TcLinkOwed -OutDir $script:scratch -Store 'Aldi'
  $ids = @($lo.Ids)
  Assert-Case 'MUST FIRE a priced Aldi tile with link_source=none is owed a re-read (newest board only)' (($ids.Count -eq 1) -and ($ids[0] -eq 'eggs') -and (-not $lo.Blind)) ($ids -join ',')
  Assert-Case 'MUST NOT FIRE an unpriced tile is owed nothing, and another store''s none tile is not Aldi''s' (-not ($ids -contains 'bread')) ($ids -join ',')
  $lo = Get-TcLinkOwed -OutDir $script:scratch -Store 'Walmart'
  Assert-Case 'MUST NOT FIRE a store whose tiles all carry row links owes nothing and is not blind' ((@($lo.Ids).Count -eq 0) -and (-not $lo.Blind)) ([string]$lo.Why)
  Remove-Item -LiteralPath (Join-Path $script:scratch 'comparison-2026-09-27.json'), (Join-Path $script:scratch 'comparison-2026-09-20.json') -ErrorAction Stop
  [IO.File]::WriteAllText((Join-Path $script:scratch 'comparison-2026-09-27.json'), '{"comparison":[{"id":"eggs","stores":[{"store":"Aldi","per_unit":0.2}]}]}')
  $lo = Get-TcLinkOwed -OutDir $script:scratch -Store 'Aldi'
  Assert-Case 'MUST FIRE a board built before link_source existed is BLIND, never a clean zero' ([bool]$lo.Blind) ([string]$lo.Why)
} catch {
  Write-Output ('  FAIL  unexpected error: ' + $_.Exception.Message); $script:fail++
} finally {
  if ($script:scratch -and (Test-Path -LiteralPath $script:scratch)) { Remove-Item -LiteralPath $script:scratch -Recurse -Force }
}
$want = 15
if ($script:ran -ne $want) { Write-Output ('  FAIL  ran ' + $script:ran + ' case(s), expected ' + $want); $script:fail++ }
if ($script:fail -eq 0) { Write-Output ('test-link-identity-lib self-test pass (' + $script:ran + ' cases)'); exit 0 }
Write-Output ('test-link-identity-lib self-test FAIL (' + $script:fail + ' of ' + $script:ran + ')'); exit 1
