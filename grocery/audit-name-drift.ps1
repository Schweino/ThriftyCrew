<#
  audit-name-drift.ps1 - catches "right price, WRONG product" links that the price-only audit-links.ps1
  misses (e.g. board = fresh "Freshness Guaranteed" chicken breast $2.48/lb, but the link points at the
  frozen Great Value 8 lb bag at a similar per-lb price). The board records the EXACT product name it
  priced (comparison stores[].item); this flags any link whose stored product name shares NONE of that
  board item's distinctive (non-commodity) words. Output: printed review list + out\name-drift.json.
  Expect some false positives (equivalent product, different brand/word-order) - it is a REVIEW signal, not
  an auto-fix: eyeball each, and for a genuinely wrong product re-resolve it by the board item name.
#>
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$out  = Join-Path $root 'out'
$cmp  = (Get-ChildItem (Join-Path $out 'comparison-*.json') | Sort-Object Name -Descending | Select-Object -First 1)
$c    = (Get-Content $cmp.FullName -Raw | ConvertFrom-Json).comparison
$purls = (Get-Content (Join-Path $root 'product-urls.json') -Raw | ConvertFrom-Json).items
# commodity + generic words that appear in both names, so are NOT distinctive of the specific product
$stop = 'boneless|skinless|chicken|breast|breasts|thigh|thighs|drumstick|drumsticks|ground|beef|turkey|pork|bacon|fresh|frozen|large|whole|family|pack|natural|all|lean|value|brand|each|lb|lbs|oz|count|ct|bag|tray|organic|cage|free|grade|sweet|original|classic|the|and|with|for|from|our|certified|the|of|per|shredded|cheese|milk|eggs|butter|sour|cream|juice|orange|apple|apples|banana|bananas|potato|potatoes|russet|onion|onions|bread|coffee|sugar|brown|tomato|tomatoes|sauce|paste|beans|kidney|garbanzo|cannellini|olives|pineapple|chunks|strawberries|blueberries|grapes|avocado|avocados|watermelon|corn|cabbage|carrots|ginger|honey|mustard|dijon|vinegar|balsamic|white|red|wine|soy|hoisin|sesame|oil|tahini|paprika|curry|powder|cornstarch|starch|rotini|pasta|marinara|spinach|peas|green|hominy|tomatillos|cashews|peanut|maple|syrup|yogurt|greek|cottage|provolone|cheddar|colby|jack|mozzarella|fries|crumbs|loin|chop|chops|thick|cut|roll|spread|soft|low|fat|pint|package|bowl'
$flags = @(); $examined = 0; $exByStore = @{}
foreach ($it in $c) {
  $id = [string]$it.id
  if (-not $purls.$id) { continue }
  foreach ($s in $it.stores) {
    $store = [string]$s.store; $item = [string]$s.item
    if (-not $item) { continue }
    $lnk = $purls.$id.$store
    if (-not $lnk -or -not $lnk.url) { continue }
    $examined++; if (-not $exByStore.ContainsKey($store)) { $exByStore[$store] = 0 }; $exByStore[$store]++
    $lname = ([string]$lnk.name).ToLower()
    # FORM FLIP AND COUNT MISMATCH ARE INDEPENDENT OF THE TOKEN TEST, so compute them BEFORE the token bail-out.
    # The old order checked distinctive tokens first and `continue`d when there were none - and a board item named
    # with nothing BUT commodity words has none, because those words are all in $stop. That is exactly how Aldi's
    # FRESH blueberries stayed linked to "Season's Choice FROZEN Blueberries": the board item is literally
    # "Blueberries", so $btoks came back empty, the cell was skipped before the form check could fire, the wrong
    # link went unflagged, generate-board-overrides trusted it as ground truth and pinned the board to it, and the
    # page published Aldi fresh blueberries at the FROZEN price (16c/oz) with a CHEAPEST flag on it. The most
    # generic product names are the ones a token test can say least about, so they must not be the ones it skips.
    # NB the second clause needs "and the board item is not itself frozen": a product legitimately called
    # "Fresh Frozen" (Our Family's frozen veg / peas) contains BOTH words, so fresh->frozen fired on a link whose
    # name was byte-identical to the board item. A flag on an identical name is pure noise, and noise here has a
    # cost - generate-board-overrides refuses to pin any cell name-drift flags, so a false flag silently blocks a
    # legitimate price correction.
    $formFlip = ((($lname -match 'frozen|canned|dried') -and ($item.ToLower() -notmatch 'frozen|canned|dried')) -or (($item.ToLower() -match 'fresh') -and ($item.ToLower() -notmatch 'frozen|canned') -and ($lname -match 'frozen|canned')))
    # COUNT MISMATCH: when the board item and the link BOTH declare a pack count and the counts differ, they are
    # different products however similar the words are - the token test cannot see this at all (Hy-Vee's own
    # "Chewy Granola Bars Variety Pack 18Ct" vs a "Quaker Chewy ... 8 ct" link share "chewy"/"granola"/"bars", so
    # ONE shared word passed it). Same class as the Hy-Vee orange-juice 64oz-vs-gallon bug. Only fires when both
    # sides state a count, so a bare "Bananas" never trips it.
    function CountOf([string]$t) { $m = [regex]::Match(([string]$t).ToLower(), '(\d+)\s*(?:ct\b|count\b|pk\b|pack\b)'); if ($m.Success) { return [int]$m.Groups[1].Value } return 0 }
    $bCount = CountOf $item
    $lCount = CountOf ($lname + ' ' + [string]$lnk.size)
    $countMismatch = ($bCount -gt 0 -and $lCount -gt 0 -and $bCount -ne $lCount)
    $btoks = @(($item.ToLower() -replace '[^a-z0-9 ]',' ' -split '\s+') | Where-Object { $_ -and $_.Length -gt 3 -and $_ -notmatch ('^(' + $stop + ')$') })
    $hit = $false; foreach ($t in $btoks) { if ($lname -match [regex]::Escape($t)) { $hit = $true; break } }
    # no distinctive tokens = the token test has NO opinion; it must not read as "clean" (that was the bug above)
    if ($btoks.Count -eq 0) { $hit = $true }
    if ((-not $hit) -or $formFlip -or $countMismatch) {
      $reason = if ($formFlip) { 'form-flip' } elseif ($countMismatch) { 'count-mismatch' } else { 'name-drift' }
      $flags += [pscustomobject]@{ id=$id; store=$store; reason=$reason; board_item=$item; link_name=[string]$lnk.name; link_price=$lnk.price }
    }
  }
}
([ordered]@{ generated=(Get-Date -Format 'yyyy-MM-dd'); count=$flags.Count; examined=$examined; examined_by_store=$exByStore; flags=$flags } | ConvertTo-Json -Depth 5) | Set-Content (Join-Path $out 'name-drift.json') -Encoding UTF8
Write-Output ("name/form-drift suspects: " + $flags.Count + " of $examined cells tested (REVIEW - some are just brand differences)")
$flags | Sort-Object reason, store, id | ForEach-Object { Write-Output ("  [{0}] {1,-14} {2}`n     BOARD: {3}`n     LINK : {4}" -f $_.reason, $_.store, $_.id, $_.board_item, $_.link_name) }
if ($examined -eq 0) {
  Write-Output 'name-drift: BLIND - examined ZERO cells (product-urls.json has no id/store matching this board; check .items). The count=0 name-drift.json just written is blind, not clean: build-deals-page link suppression, guard 3, and tile-integrity WRONG-PRODUCT all read it as clean.'
  exit 3
}
