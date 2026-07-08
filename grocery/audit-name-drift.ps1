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
$flags = @()
foreach ($it in $c) {
  $id = [string]$it.id
  if (-not $purls.$id) { continue }
  foreach ($s in $it.stores) {
    $store = [string]$s.store; $item = [string]$s.item
    if (-not $item) { continue }
    $lnk = $purls.$id.$store
    if (-not $lnk -or -not $lnk.url) { continue }
    $lname = ([string]$lnk.name).ToLower()
    $btoks = @(($item.ToLower() -replace '[^a-z0-9 ]',' ' -split '\s+') | Where-Object { $_ -and $_.Length -gt 3 -and $_ -notmatch ('^(' + $stop + ')$') })
    if ($btoks.Count -eq 0) { continue }
    $hit = $false; foreach ($t in $btoks) { if ($lname -match [regex]::Escape($t)) { $hit = $true; break } }
    # form flip is a strong signal even if a token matches
    $formFlip = ((($lname -match 'frozen|canned|dried') -and ($item.ToLower() -notmatch 'frozen|canned|dried')) -or ((($item.ToLower() -match 'fresh') -and ($lname -match 'frozen|canned'))))
    if ((-not $hit) -or $formFlip) {
      $flags += [pscustomobject]@{ id=$id; store=$store; reason=$(if ($formFlip){'form-flip'}else{'name-drift'}); board_item=$item; link_name=[string]$lnk.name; link_price=$lnk.price }
    }
  }
}
([ordered]@{ generated=(Get-Date -Format 'yyyy-MM-dd'); count=$flags.Count; flags=$flags } | ConvertTo-Json -Depth 5) | Set-Content (Join-Path $out 'name-drift.json') -Encoding UTF8
Write-Output ("name/form-drift suspects: " + $flags.Count + " (REVIEW - some are just brand differences)")
$flags | Sort-Object reason, store, id | ForEach-Object { Write-Output ("  [{0}] {1,-14} {2}`n     BOARD: {3}`n     LINK : {4}" -f $_.reason, $_.store, $_.id, $_.board_item, $_.link_name) }
