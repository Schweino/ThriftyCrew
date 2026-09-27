<#
  test-hyvee-flyer-link.ps1 -SelfTest - fixtures for hyvee-flyer-link-lib.ps1 (design/PLAN-flyer-line-product-link-2026-09-26.md,
  section 5 step 1). Hermetic: no network, no board, no temp files. The last line is the verdict.
  The price bar is EQUAL TO THE CENT, so the at-bar case is $4.98 against $4.98 and the past-bar case is one cent off.
#>
[CmdletBinding()]
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
if (-not $SelfTest) { Write-Output 'test-hyvee-flyer-link: run with -SelfTest'; exit 3 }

. (Join-Path $root 'pu-lib.ps1')
. (Join-Path $root 'hyvee-flyer-link-lib.ps1')

$script:fail = 0; $script:ran = 0
function Assert-Case([string]$Name, [scriptblock]$Body) {
  $script:ran++
  try { $ok = & $Body } catch { $ok = $false; Write-Output ('  threw: ' + $_.Exception.Message) }
  if ($ok -eq $true) { Write-Output ('ok   ' + $Name) } else { $script:fail++; Write-Output ('FAIL ' + $Name) }
}
function New-Cand([string]$Id, [string]$Name, [double]$Price, [bool]$OnSale = $true, [int]$Mult = 1, [string]$Identity = 'admitted', [string]$SizeField = '') {
  [pscustomobject]@{ product_id = $Id; name = $Name; size_field = $SizeField; read_ok = $true; on_sale = $OnSale; price = $Price; price_multiple = $Mult; identity = $Identity }
}

$simplyText = 'Simply juice, 46 or 52 fl. oz., $4.98'
$simply = ConvertFrom-TcFlyerLine $simplyText
$cell52 = 4.98 / 52

# ---- the parser ----------------------------------------------------------------------------------------------------
Assert-Case 'CLEAN TWIN  the founding line parses: price 498 cents, one item, two stated sizes 46 and 52 fl oz' {
  ($simply.ok) -and ($simply.total_cents -eq 498) -and ($simply.qty_n -eq 1) -and (@($simply.sizes).Count -eq 2) -and ((@($simply.sizes | ForEach-Object { $_.qty }) -join ',') -eq '46,52')
}
Assert-Case 'CLEAN TWIN  a multibuy reads as N for the total (2/ $5.00 is 2 for 500 cents)' {
  $l = ConvertFrom-TcFlyerLine 'Hy-Vee graham crackers, 14.4 oz., 2/ $5.00'
  ($l.qty_n -eq 2) -and ($l.total_cents -eq 500)
}
Assert-Case 'CLEAN TWIN  a range reads as a range (9.3 to 16 oz) and a per-pound price is never read as a size' {
  $l = ConvertFrom-TcFlyerLine 'Hormel Black Label bacon, 9.3 to 16 oz., $4.99'
  $p = ConvertFrom-TcFlyerLine 'Hy-Vee Midwest Pork bone-in assorted chops, $3.99 lb.'
  (@($l.ranges).Count -eq 1) -and ($l.ranges[0].lo -eq 9.3) -and ($p.per_lb) -and (@($p.sizes).Count -eq 0)
}
Assert-Case 'CLEAN TWIN  a lower-case alternative inherits the brand (All ... or laundry detergent -> all + laundry + detergent)' {
  $l = ConvertFrom-TcFlyerLine 'All Mighty Pacs 60 ct. or laundry detergent 118 fl. oz., $16.99'
  (@($l.alternatives).Count -eq 2) -and ((@($l.alternatives[1]) -join ' ') -eq 'all laundry detergent')
}
Assert-Case 'MUST NOT FIRE  a line whose price does not parse is never linked' {
  $l = ConvertFrom-TcFlyerLine 'Hy-Vee aluminum foil, 50 or 75 sq. ft.'
  $r = Resolve-TcFlyerLink -Line $l -Candidates @(New-Cand '1' 'Hy-Vee Aluminum Foil 75 sq ft' 4.49) -CellPerUnit (4.49 / 75) -Unit 'sq_ft'
  (-not $l.ok) -and ($r.linked -eq '')
}

# ---- the matching rule -----------------------------------------------------------------------------------------------
Assert-Case 'MUST FIRE  the "46 or 52 fl. oz." line links ONLY the product at the cell''s own size (52), never the 46' {
  $c = @((New-Cand '46' 'Simply Orange Juice Pulp Free 46 fl oz' 4.98), (New-Cand '52' 'Simply Orange Juice Pulp Free 52 fl oz' 4.98))
  $r = Resolve-TcFlyerLink -Line $simply -Candidates $c -CellPerUnit $cell52 -Unit 'floz'
  $r.linked -eq '52'
}
Assert-Case 'CLEAN TWIN  the same two candidates against a 46 fl oz cell link the 46' {
  $c = @((New-Cand '46' 'Simply Orange Juice Pulp Free 46 fl oz' 4.98), (New-Cand '52' 'Simply Orange Juice Pulp Free 52 fl oz' 4.98))
  (Resolve-TcFlyerLink -Line $simply -Candidates $c -CellPerUnit (4.98 / 46) -Unit 'floz').linked -eq '46'
}
Assert-Case 'MUST FIRE  AT the price bar: $4.98 read against a $4.98 line (equal to the cent) links' {
  (Resolve-TcFlyerLink -Line $simply -Candidates @(New-Cand '52' 'Simply Orange Juice 52 fl oz' 4.98) -CellPerUnit $cell52 -Unit 'floz').linked -eq '52'
}
Assert-Case 'MUST NOT FIRE  one cent PAST the price bar: $4.99 against a $4.98 line is not linked' {
  $r = Resolve-TcFlyerLink -Line $simply -Candidates @(New-Cand '52' 'Simply Orange Juice 52 fl oz' 4.99) -CellPerUnit $cell52 -Unit 'floz'
  ($r.linked -eq '') -and ($r.rows[0].reason -like 'price differs*')
}
Assert-Case 'MUST NOT FIRE  a candidate one cent UNDER the line ($4.97) is not linked either' {
  $r = Resolve-TcFlyerLink -Line $simply -Candidates @(New-Cand '52' 'Simply Orange Juice 52 fl oz' 4.97) -CellPerUnit $cell52 -Unit 'floz'
  ($r.linked -eq '') -and ($r.rows[0].reason -like 'price differs*')
}
Assert-Case 'MUST NOT FIRE  a candidate at the exact price whose read says onSale false is not linked' {
  $r = Resolve-TcFlyerLink -Line $simply -Candidates @(New-Cand '52' 'Simply Orange Juice 52 fl oz' 4.98 $false) -CellPerUnit $cell52 -Unit 'floz'
  ($r.linked -eq '') -and ($r.rows[0].reason -like '*onSale false*')
}
Assert-Case 'MUST NOT FIRE  a candidate whose name drops a family word (juice, no Simply) is not linked' {
  $r = Resolve-TcFlyerLink -Line $simply -Candidates @(New-Cand '52' 'Tropicana Orange Juice 52 fl oz' 4.98) -CellPerUnit $cell52 -Unit 'floz'
  ($r.linked -eq '') -and ($r.rows[0].reason -like 'a family word is missing*')
}
Assert-Case 'MUST NOT FIRE  a candidate the commodity''s own rule refuses is not linked' {
  (Resolve-TcFlyerLink -Line $simply -Candidates @(New-Cand '52' 'Simply Juice Drink 52 fl oz' 4.98 $true 1 'refused') -CellPerUnit $cell52 -Unit 'floz').linked -eq ''
}
Assert-Case 'MUST NOT FIRE  an identity that could not look is not a proof' {
  (Resolve-TcFlyerLink -Line $simply -Candidates @(New-Cand '52' 'Simply Juice 52 fl oz' 4.98 $true 1 'could-not-look') -CellPerUnit $cell52 -Unit 'floz').linked -eq ''
}
Assert-Case 'MUST NOT FIRE  a size outside the line''s stated set (89 fl oz) is not linked' {
  $r = Resolve-TcFlyerLink -Line $simply -Candidates @(New-Cand '89' 'Simply Orange Juice 89 fl oz' 4.98) -CellPerUnit $cell52 -Unit 'floz'
  ($r.linked -eq '') -and ($r.rows[0].reason -like 'size outside the line*')
}
Assert-Case 'MUST NOT FIRE  two different products at the cell''s size are ambiguous and not linked' {
  $c = @((New-Cand 'a' 'Simply Orange Juice 52 fl oz' 4.98), (New-Cand 'b' 'Simply Lemonade Juice 52 fl oz' 4.98))
  $r = Resolve-TcFlyerLink -Line $simply -Candidates $c -CellPerUnit $cell52 -Unit 'floz'
  ($r.linked -eq '') -and ($r.reason -like 'ambiguous*')
}
Assert-Case 'MUST NOT FIRE  the size field alone is untrusted when it is not one plain measure (12 fl oz Cans)' {
  $l = ConvertFrom-TcFlyerLine '7UP soda, 12 pk. 12 fl. oz., $5.99'
  (Resolve-TcFlyerLink -Line $l -Candidates @(New-Cand 's' '7UP Soda' 5.99 $true 1 'admitted' '12 fl oz Cans') -CellPerUnit (5.99 / 144) -Unit 'floz').linked -eq ''
}
Assert-Case 'CLEAN TWIN  a single-size line with one exact candidate still links' {
  $l = ConvertFrom-TcFlyerLine 'Hy-Vee BBQ sauce, 18 oz., $2.19'
  (Resolve-TcFlyerLink -Line $l -Candidates @(New-Cand '7' 'Hy-Vee Original BBQ Sauce 18 oz' 2.19) -CellPerUnit (2.19 / 18) -Unit 'oz').linked -eq '7'
}
Assert-Case 'CLEAN TWIN  a plain size field is read when the name states no size (75 sq ft)' {
  $l = ConvertFrom-TcFlyerLine 'Hy-Vee aluminum foil, 50 or 75 sq. ft., $4.49'
  (Resolve-TcFlyerLink -Line $l -Candidates @(New-Cand 'f' 'Hy-Vee Aluminum Foil' 4.49 $true 1 'admitted' '75 sq ft') -CellPerUnit (4.49 / 75) -Unit 'sq_ft').linked -eq 'f'
}
Assert-Case 'CLEAN TWIN  a multibuy line links a read of 2.50 each (2/ $5.00)' {
  $l = ConvertFrom-TcFlyerLine 'Hy-Vee hummus, 8 oz., 2/ $5.00'
  (Resolve-TcFlyerLink -Line $l -Candidates @(New-Cand 'h' 'Hy-Vee Classic Hummus 8 oz' 2.50) -CellPerUnit (2.50 / 8) -Unit 'oz').linked -eq 'h'
}
Assert-Case 'CLEAN TWIN  a multibuy line links a read carrying priceMultiple 2 at $5.00' {
  $l = ConvertFrom-TcFlyerLine 'Hy-Vee hummus, 8 oz., 2/ $5.00'
  (Resolve-TcFlyerLink -Line $l -Candidates @(New-Cand 'h' 'Hy-Vee Classic Hummus 8 oz' 5.00 $true 2) -CellPerUnit (2.50 / 8) -Unit 'oz').linked -eq 'h'
}
Assert-Case 'MUST NOT FIRE  a Hy-Vee line never links another brand at the same price' {
  $l = ConvertFrom-TcFlyerLine 'Hy-Vee frosting, 16 oz., $1.88'
  (Resolve-TcFlyerLink -Line $l -Candidates @(New-Cand 'b' 'Betty Crocker Frosting 16 oz' 1.88) -CellPerUnit (1.88 / 16) -Unit 'oz').linked -eq ''
}

# ---- variant 2a: the abbreviation map (Brad 2026-09-26, "Both loosenings") -----------------------------------------------
$thighText = 'Fresh chicken thighs, 100% natural, value pack No antibiotics ever., $1.88 lb.'
$thigh = ConvertFrom-TcFlyerLine $thighText
Assert-Case 'MUST FIRE  variant 2 links "Hy-Vee Ckn Thighs Fam Pk" to a chicken thighs line (ckn -> chicken, the founding miss)' {
  (Resolve-TcFlyerLink -Line $thigh -Candidates @(New-Cand '31783' 'Hy-Vee Ckn Thighs Fam Pk' 1.88 $true 1 'silent' '1 lb') -CellPerUnit 1.88 -Unit 'lb' -Variant 2).linked -eq '31783'
}
Assert-Case 'CLEAN TWIN  variant 1 is unchanged: the same Ckn candidate is not linked, a family word is missing' {
  $r = Resolve-TcFlyerLink -Line $thigh -Candidates @(New-Cand '31783' 'Hy-Vee Ckn Thighs Fam Pk' 1.88 $true 1 'silent' '1 lb') -CellPerUnit 1.88 -Unit 'lb'
  ($r.linked -eq '') -and ($r.rows[0].reason -like 'a family word is missing*chicken*')
}
Assert-Case 'MUST NOT FIRE  an abbreviation the map does not hold is not expanded (Chx is not chicken)' {
  (Resolve-TcFlyerLink -Line $thigh -Candidates @(New-Cand 'x' 'Hy-Vee Chx Thighs Fam Pk' 1.88 $true 1 'silent' '1 lb') -CellPerUnit 1.88 -Unit 'lb' -Variant 2).linked -eq ''
}
Assert-Case 'MUST NOT FIRE  expanding an abbreviation never supplies a DROPPED brand word (Ckn Wings, no Hy-Vee)' {
  $l = ConvertFrom-TcFlyerLine 'Hy-Vee fresh chicken wings, 100% natural, value pack, $2.99 lb.'
  $r = Resolve-TcFlyerLink -Line $l -Candidates @(New-Cand 'w' 'Ckn Wings Fam Pk' 2.99 $true 1 'admitted' '1 lb') -CellPerUnit 2.99 -Unit 'lb' -Variant 2
  ($r.linked -eq '') -and ($r.rows[0].reason -like '*hyvee*')
}
Assert-Case 'MUST FIRE  every map entry has the shape of an abbreviation (initials, or an ordered subsequence of the word)' {
  $bad = @($script:HfAbbrev.Keys | Where-Object { -not (Test-TcFlyerAbbrevShape $_ ([string[]]$script:HfAbbrev[$_].words)) -or -not $script:HfAbbrev[$_].cite })
  ($script:HfAbbrev.Count -ge 30) -and ($bad.Count -eq 0)
}
Assert-Case 'MUST NOT FIRE  a guessed expansion fails the shape test (ckn -> turkey, bc -> bob evans, cn -> chicken)' {
  (-not (Test-TcFlyerAbbrevShape 'ckn' @('turkey'))) -and (-not (Test-TcFlyerAbbrevShape 'bc' @('bob', 'evans'))) -and (-not (Test-TcFlyerAbbrevShape 'ckn' @('ckn'))) -and (Test-TcFlyerAbbrevShape 'ckn' @('chicken'))
}

# ---- variant 2b: same-price sets -----------------------------------------------------------------------------------------
$bbq = ConvertFrom-TcFlyerLine 'Hy-Vee BBQ sauce, 18 oz., $2.19'
$bbqCell = 2.19 / 18
function New-BbqSet { @((New-Cand '3963369' 'Hy-Vee Hickory BBQ Sauce' 2.19 $true 1 'admitted' '18 oz'), (New-Cand '3963368' 'Hy-Vee Honey BBQ Sauce' 2.19 $true 1 'admitted' '18 oz'), (New-Cand '3963370' 'Hy-Vee Swt & Spicy BBQ Sauce' 2.19 $true 1 'admitted' '18 oz')) }
Assert-Case 'MUST FIRE  variant 2 links a same-price set of three flavours, reporting the lowest id and all three members' {
  $s = New-BbqSet
  $r = Resolve-TcFlyerLink -Line $bbq -Candidates $s -CellPerUnit $bbqCell -Unit 'oz' -Variant 2
  ($r.linked -eq '3963368') -and ((@($r.linked_set) -join ',') -eq '3963368,3963369,3963370') -and ($r.reason -like 'set:*')
}
Assert-Case 'CLEAN TWIN  variant 1 is unchanged: the same three flavours are ambiguous and not linked' {
  $s = New-BbqSet
  $r = Resolve-TcFlyerLink -Line $bbq -Candidates $s -CellPerUnit $bbqCell -Unit 'oz'
  ($r.linked -eq '') -and ($r.reason -like 'ambiguous*')
}
Assert-Case 'MUST NOT FIRE  a same-price set with ONE off-price member at the cell''s size ($2.49 against $2.19) is not linked' {
  $s = New-BbqSet; $s += New-Cand '9' 'Hy-Vee Original BBQ Sauce' 2.49 $true 1 'admitted' '18 oz'
  $r = Resolve-TcFlyerLink -Line $bbq -Candidates $s -CellPerUnit $bbqCell -Unit 'oz' -Variant 2
  ($r.linked -eq '') -and ($r.reason -like 'set refused*(9)')
}
Assert-Case 'MUST NOT FIRE  a set member whose read says onSale false at the line price refuses the set' {
  $s = New-BbqSet; $s += New-Cand '9' 'Hy-Vee Original BBQ Sauce' 2.19 $false 1 'admitted' '18 oz'
  (Resolve-TcFlyerLink -Line $bbq -Candidates $s -CellPerUnit $bbqCell -Unit 'oz' -Variant 2).linked -eq ''
}
Assert-Case 'MUST NOT FIRE  a set member with no in-window read refuses the set (unread is not proven)' {
  $s = New-BbqSet; $u = New-Cand '9' 'Hy-Vee Original BBQ Sauce' 2.19 $true 1 'admitted' '18 oz'; $u.read_ok = $false; $s += $u
  (Resolve-TcFlyerLink -Line $bbq -Candidates $s -CellPerUnit $bbqCell -Unit 'oz' -Variant 2).linked -eq ''
}
Assert-Case 'CLEAN TWIN  an off-price product at ANOTHER size (28 oz) or of another brand does not refuse the set' {
  $s = New-BbqSet; $s += New-Cand '9' 'Hy-Vee Original BBQ Sauce' 3.49 $true 1 'admitted' '28 oz'; $s += New-Cand '10' 'Sweet Baby Rays BBQ Sauce' 2.99 $true 1 'admitted' '18 oz'
  (@((Resolve-TcFlyerLink -Line $bbq -Candidates $s -CellPerUnit $bbqCell -Unit 'oz' -Variant 2).linked_set)).Count -eq 3
}
Assert-Case 'MUST FIRE  an unknown variant is refused, never read as variant 1' {
  $a = $false; try { [void](Resolve-TcFlyerLink -Line $bbq -Candidates (New-BbqSet) -CellPerUnit $bbqCell -Unit 'oz' -Variant 3) } catch { $a = $true }
  $a
}

# ---- the off switch --------------------------------------------------------------------------------------------------
Assert-Case 'MUST FIRE  the off switch: no flyer_link key reads off, "off" reads off, "shadow" reads shadow' {
  $none = [pscustomobject]@{ stores = @([pscustomobject]@{ name = 'Hy-Vee' }) }
  $off = [pscustomobject]@{ stores = @([pscustomobject]@{ name = 'Hy-Vee'; flyer_link = 'off' }) }
  $sh = [pscustomobject]@{ stores = @([pscustomobject]@{ name = 'Hy-Vee'; flyer_link = 'shadow' }) }
  ((Get-TcFlyerLinkMode $none) -eq 'off') -and ((Get-TcFlyerLinkMode $off) -eq 'off') -and ((Get-TcFlyerLinkMode $sh) -eq 'shadow')
}
Assert-Case 'MUST FIRE  "live" is refused until Brad rules, and an unknown value is refused' {
  $live = [pscustomobject]@{ stores = @([pscustomobject]@{ name = 'Hy-Vee'; flyer_link = 'live' }) }
  $odd = [pscustomobject]@{ stores = @([pscustomobject]@{ name = 'Hy-Vee'; flyer_link = 'on' }) }
  $a = $false; $b = $false
  try { [void](Get-TcFlyerLinkMode $live) } catch { $a = $true }
  try { [void](Get-TcFlyerLinkMode $odd) } catch { $b = $true }
  $a -and $b
}

$expected = 37
if ($script:ran -ne $expected) { $script:fail++; Write-Output ('FAIL case count: ran ' + $script:ran + ', the suite lists ' + $expected) }
if ($script:fail -eq 0) { Write-Output ('test-hyvee-flyer-link self-test pass (' + $script:ran + ' cases)'); exit 0 }
Write-Output ('test-hyvee-flyer-link SELF-TEST FAIL: ' + $script:fail + ' of ' + $script:ran); exit 1
