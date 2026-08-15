$ErrorActionPreference='Stop'
$root='C:\Codex\ThriftyCrew\grocery'
$commodities = Get-Content (Join-Path $root 'commodities.json') -Raw | ConvertFrom-Json
function WhoClaims([string]$name){
  $n = $name.ToLower()
  foreach($c in $commodities){
    $inc = $false
    foreach($p in $c.include){ if($n -match $p){ $inc=$true; break } }
    if(-not $inc){ continue }
    $exc = $false
    foreach($p in $c.exclude){ if($n -match $p){ $exc=$true; break } }
    if($exc){ continue }
    return $c.id
  }
  return '(nobody)'
}
foreach($t in @(
  'Hy-Vee Thyme',
  'Dynasty Premium Fish Sauce',
  'Lee Kum Kee Hoisin Sauce 8.5 oz',
  'Kikkoman Aji Mirin Sweet Cooking Rice Wine',
  'Krinos Imported Tahini 16 oz',
  'Thai Kitchen Gluten Free Red Curry Paste',
  'Morton & Bassett Harissa',
  'McCormick Gourmet Chinese Five Spice Blend, 1.75 oz',
  'Jiffy Corn Muffin Mix 8.5 oz',
  'La Costena Chipotle Peppers in Adobo Sauce',
  'Poblano Peppers',
  'Hidden Valley The Original Ranch Seasoning',
  'That''s Smart! Basil Leaves',
  'Hy-Vee Dill Weed'
)){
  Write-Output ("{0,-52} -> {1}" -f $t, (WhoClaims $t))
}
