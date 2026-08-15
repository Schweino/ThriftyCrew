# Split the 81-item 'pantry' category into 5 shopper-friendly sub-departments (display only; matching unaffected).
$ErrorActionPreference='Stop'
$root='C:\Codex\ThriftyCrew\grocery'; $path="$root\categories.json"
Copy-Item $path "$root\out\audit\categories.before-split.json" -Force
$doc=ConvertFrom-Json ([IO.File]::ReadAllText($path))
$cats=@($doc.categories)
$pantry=$cats|Where-Object{$_.key -eq 'pantry'}|Select-Object -First 1
$pset=@($pantry.commodities)

$buckets=[ordered]@{
  canned     = @{ label='Canned &amp; Soup';        order=6;  ids=@('baked-beans','canned-black-beans','canned-chili','canned-corn','canned-green-beans','canned-mushrooms','canned-peaches','canned-peas','canned-pineapple','canned-pinto-beans','refried-beans','diced-tomatoes','chicken-noodle-soup','cream-of-chicken-soup','cream-of-mushroom-soup','tomato-soup','applesauce','pickles','beef-broth','chicken-broth') }
  condiments = @{ label='Sauces &amp; Condiments';  order=7;  ids=@('alfredo-sauce','bbq-sauce','hot-sauce','ketchup','mustard','mayonnaise','italian-dressing','ranch-dressing','pasta-sauce','pizza-sauce','salsa','queso','relish','worcestershire','hummus') }
  baking     = @{ label='Baking &amp; Spices';      order=8;  ids=@('flour','sugar','brown-sugar','powdered-sugar','baking-powder','baking-soda','cocoa-powder','chocolate-chips','vanilla-extract','yeast','cake-mix','brownie-mix','frosting','marshmallows','black-pepper','salt','condensed-milk','evaporated-milk') }
  grains     = @{ label='Pasta, Rice &amp; Grains'; order=9;  ids=@('pasta','egg-noodles','lasagna-noodles','ramen','mac-and-cheese','rice','brown-rice','oatmeal','cereal','stuffing-mix','instant-mashed-potatoes','pancake-mix') }
  oils       = @{ label='Coffee, Oils &amp; Spreads';order=10; ids=@('olive-oil','vegetable-oil','coconut-oil','cooking-spray','apple-cider-vinegar','coffee','orange-juice','peanut-butter','jelly','honey','maple-syrup','almonds','peanuts','mixed-nuts','raisins','graham-crackers') }
}

# --- assert: buckets partition the pantry set EXACTLY (no missing, no extra, no dupe) ---
$all=@(); foreach($b in $buckets.Values){ $all += $b.ids }
$dupes=@($all | Group-Object | Where-Object{$_.Count -gt 1} | ForEach-Object{$_.Name})
$missing=@($pset | Where-Object{ $all -notcontains $_ })
$extra=@($all | Where-Object{ $pset -notcontains $_ })
if($dupes.Count -or $missing.Count -or $extra.Count){
  if($dupes.Count){ Write-Output ("DUPES: "+($dupes -join ', ')) }
  if($missing.Count){ Write-Output ("MISSING (in pantry, not bucketed): "+($missing -join ', ')) }
  if($extra.Count){ Write-Output ("EXTRA (bucketed, not in pantry): "+($extra -join ', ')) }
  throw "bucket partition mismatch - NOT writing"
}
Write-Output ("partition OK: "+$pset.Count+" pantry items -> "+$buckets.Count+" buckets ("+(@($buckets.Values|ForEach-Object{$_.ids.Count}) -join '+')+")")

# --- rebuild categories: drop pantry, add 5, bump the post-pantry orders (snacks..pet: 7-12 -> 11-16) ---
$bump=@{ snacks=11; frozen=12; household=13; personal=14; baby=15; pet=16 }
$new=New-Object System.Collections.Generic.List[object]
foreach($c in $cats){
  if($c.key -eq 'pantry'){ continue }
  if($bump.ContainsKey($c.key)){ $c.order=$bump[$c.key] }
  $new.Add($c)
}
foreach($k in $buckets.Keys){
  $b=$buckets[$k]
  $new.Add([pscustomobject]@{ key=$k; label=$b.label; order=$b.order; commodities=$b.ids })
}
$doc.categories = @($new | Sort-Object order)
[IO.File]::WriteAllText($path,(ConvertTo-Json $doc -Depth 8),(New-Object Text.UTF8Encoding($false)))
Write-Output "categories.json written. New order:"
foreach($c in $doc.categories){ Write-Output ("  {0,2}  {1,-12} {2,-24} {3,3} items" -f $c.order,$c.key,$c.label.Replace('&amp;','&'),@($c.commodities).Count) }
