<#
  test-match-worklist.ps1 - the matching lane's fixtures (plan-2026-09-22-9 b96f21, plan-2026-09-22-10 2dae07).

  THE BAR, written in the plan BEFORE the classifier existed: over the 24 frozen labels below (the 21 actionable
  coverage gaps of coverage-gaps.json 2026-09-22 08:21 and the 3 semantic rows of semantic-findings.json the same
  day, each hand-labelled by the plan-9 reviewer), 0 WRONG decisions among the keys the classifier decides, with
  decided-of-24 printed beside it. A decision is wrong when it is release/widen/confirm/ad-line and differs from the
  label; 'unknown' labels (packaging the name cannot settle) are wrong for ANY decision. Undecided is never wrong,
  and is counted, so abstention cannot hide (.claude/rules/measurement.md).
  HONEST LIMIT: the rules were written with these 24 in view, so this is an IN-SAMPLE measurement, not a held-out
  one. The lane therefore decides only coverage and semantic keys, and a wrong release still has to pass
  apply-coverage-batch's gates (theft, crowns, suppression list) before it can move anything.

  Every temp path is per run; nothing here writes a tracked file.
#>
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $root 'match-worklist-lib.ps1')
$script:n = 0; $script:bad = 0
function _MT([string]$label, [bool]$ok, [string]$got = '') { $script:n++; if ($ok) { Write-Output ('  ok   ' + $label) } else { Write-Output ('  FAIL ' + $label + $(if ($got) { '  got: ' + $got } else { '' })); $script:bad++ } }
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('tmw-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmp -ErrorAction Stop | Out-Null
try {
  # frozen commodity identities (id + label as commodities.json held them on 2026-09-22)
  $L = [ordered]@{ 'fresh-ginger' = 'Ginger Root'; 'apples' = 'Apples'; 'frosting' = 'Frosting'; 'cherries' = 'Cherries (fresh)'; 'queso' = 'Queso / Cheese Dip'; 'salsa' = 'Salsa'; 'canned-peaches' = 'Canned Peaches'; 'apple-juice' = 'Apple Juice'; 'grape-juice' = 'Grape Juice'; 'tater-tots' = 'Tater Tots'; 'frozen-fries' = 'Frozen French Fries'; 'facial-tissues' = 'Facial Tissues'; 'lotion' = 'Body Lotion'; 'tomato-paste' = 'Tomato Paste'; 'garlic' = 'Garlic (fresh)'; 'canned-pasta' = 'Canned Pasta (Ravioli / SpaghettiOs)'; 'frozen-meatballs' = 'Frozen Meatballs'; 'chili-beans' = 'Chili Beans (in sauce)'; 'canned-chili' = 'Canned Chili'; 'canned-mixed-vegetables' = 'Canned Mixed Vegetables'; 'frozen-vegetables' = 'Frozen Mixed Vegetables'; 'mandarin-oranges' = 'Canned Mandarin Oranges'; 'fruit-cups' = 'Fruit Cups'; 'canned-pears' = 'Canned Pears'; 'gochujang' = 'Gochujang (Korean Chili Paste)'; 'mac-and-cheese' = 'Macaroni & Cheese (boxed)'; 'cheese-tortellini' = 'Cheese Tortellini'; 'frozen-lasagna' = 'Frozen Lasagna'; 'sun-dried-tomatoes' = 'Sun-Dried Tomatoes'; 'turkey-lunchmeat' = 'Turkey (deli / sliced)'; 'jumbo-pasta-shells' = 'Jumbo Pasta Shells / Manicotti'; 'shrimp' = 'Shrimp (frozen, raw)'; 'butternut-squash' = 'Butternut Squash'; 'coconut' = 'Whole Coconut'; 'canned-butter-beans' = 'Canned Butter Beans'; 'frozen-lima-beans' = 'Frozen Lima Beans'; 'ready-to-serve-long-grain-wild-rice-pouch' = 'Ready-to-Serve Long Grain & Wild Rice Pouch'; 'frozen-waffles' = 'Frozen Waffles'; 'shredded-cheese' = 'Shredded / Block Cheese' }
  $C = @{}; foreach ($k in $L.Keys) { $C[$k] = [pscustomobject]@{ id = $k; label = $L[$k] } }
  # kind | target | claimer | name | LABEL (the reviewer's, plan-9 evidence row 3 and 4)
  $cases = @(
    @('coverage', 'fresh-ginger', 'apples', 'Ginger Gold Apple', 'confirm'),
    @('coverage', 'frosting', 'cherries', 'Betty Crocker Rich and Creamy Cherry Frosting', 'release'),
    @('coverage', 'queso', '', 'Hy-Vee party cheese or cheese dip, .50 off with digital coupon, $2.99', 'ad-line'),
    @('coverage', 'queso', 'salsa', 'Tostitos Medium Con Queso Salsa Dip', 'release'),
    @('coverage', 'canned-peaches', '', 'Fareway 12 Pack Yellow Cling Diced Peaches in 100% Juice', 'unknown'),
    @('coverage', 'apple-juice', 'grape-juice', 'Old Orchard Organic 100% apple or grape juice, 64 fl. oz., 2/ $7.00', 'ad-line'),
    @('coverage', 'apple-juice', '', 'Old Orchard 100% Juice, Apple, Value Size', 'widen'),
    @('coverage', 'tater-tots', 'frozen-fries', 'Alexia fries, tots or onion rings, 13.5 to 28 oz., $5.89', 'ad-line'),
    @('coverage', 'facial-tissues', 'lotion', 'Puffs Facial Tissue Plus Lotion', 'release'),
    @('coverage', 'tomato-paste', 'garlic', 'Hunt''s Tomato Paste with Basil Garlic and Oregano', 'release'),
    @('coverage', 'canned-pasta', 'frozen-meatballs', 'Chef Boyardee Mini Spaghetti Rings & Meatballs', 'release'),
    @('coverage', 'chili-beans', 'canned-chili', 'Hy-Vee Chili With Beans', 'confirm'),
    @('coverage', 'canned-mixed-vegetables', 'frozen-vegetables', 'Birds Eye Steamfresh Mixed Vegetables', 'confirm'),
    @('coverage', 'mandarin-oranges', 'fruit-cups', 'Hy-Vee Mandarin Oranges in 100% Juice 4-4 oz Bowls', 'confirm'),
    @('coverage', 'canned-pears', '', 'Fareway Diced No Sugar Added Pears', 'unknown'),
    @('coverage', 'gochujang', 'mac-and-cheese', 'Hy-Vee Korean Gochujang Sauce', 'release'),
    @('coverage', 'cheese-tortellini', 'frozen-lasagna', 'Louisa Four Cheese Tortellini', 'release'),
    @('coverage', 'sun-dried-tomatoes', 'turkey-lunchmeat', 'Mezzetta Sun-Dried Tomatoes', 'release'),
    @('coverage', 'jumbo-pasta-shells', 'shrimp', 'Kroger Wild Caught Jumbo Raw Gulf Shrimp Shell-On BIG DEAL!', 'confirm'),
    @('coverage', 'butternut-squash', 'coconut', 'Pictsweet Farms Vegetables for Roasting Halved Brussels Sprouts, Butternut Squash & Onions - 18 oz', 'release'),
    @('coverage', 'canned-butter-beans', 'frozen-lima-beans', 'Fareway Large Butter Beans', 'unknown'),
    @('semantic', 'ready-to-serve-long-grain-wild-rice-pouch', '', 'Long Grain Wild Ready TO Serve Rice', 'widen'),
    @('semantic', 'frozen-waffles', '', 'Eggo Frozen Pancakes, Buttermilk 14.8 Oz', 'confirm'),
    @('semantic', 'shredded-cheese', '', 'Happy Farms Shredded Mild Cheddar', 'widen')
  )
  $decided = 0; $wrong = New-Object System.Collections.Generic.List[string]; $rowsOut = New-Object System.Collections.Generic.List[string]
  foreach ($cs in $cases) {
    $t = if ($cs[1]) { $C[$cs[1]] } else { $null }; $cl = if ($cs[2]) { $C[$cs[2]] } else { $null }
    $r = Get-MatchClassification -Kind $cs[0] -Name $cs[3] -Target $t -Claimer $cl
    [void]$rowsOut.Add(('    ' + $r.decision.PadRight(9) + ' label=' + $cs[4].PadRight(8) + ' ' + $cs[3]))
    if ($r.decision -ne 'undecided') { $decided++; if ($r.decision -ne $cs[4]) { [void]$wrong.Add($cs[3] + ' -> ' + $r.decision + ' (label ' + $cs[4] + ')') } }
  }
  $rowsOut | ForEach-Object { Write-Output $_ }
  _MT ('BAR (written before the build): 0 wrong decisions over the 24 frozen labels; decided ' + $decided + ' of 24, wrong ' + $wrong.Count + ' of ' + $decided) ($wrong.Count -eq 0) ($wrong -join ' ; ')
  _MT ('COVERAGE is printed with its denominator and is not zero (an all-abstain classifier would pass the bar by deciding nothing): decided ' + $decided + ' of 24') ($decided -gt 0) ([string]$decided)

  # THE CONTESTED BAR (queue 2026-09-23-5aa22a, weekly lane plan-2026-09-25-8). Same bar as above, written before the
  # labels: 0 wrong decisions among the keys the classifier decides, decided-of-N printed. The set: every NEW-CONTESTED
  # name ad-cycle-log.txt printed from 2026-09-01 to 2026-09-25 (139 distinct) whose chain the soundness sweep could
  # recompute on 2026-09-25 from the feeds on disk (41) and whose chain has ONE other commodity, and that the classifier
  # then DECIDES (11 of the 41; 17 undecided, 12 ad-line, 1 multi, 98 not in today's feeds). Each label is the lane's
  # reading of the product. 'none' = the food is neither commodity, so any decision is wrong.
  # contested key: -Claimer is the WINNER (array order picked it), -Target the one other commodity.
  $K = @{}; foreach ($kv in @(@('rotisserie-chicken', 'Rotisserie Chicken'), @('lemon-pepper-seasoning', 'Lemon Pepper Seasoning'), @('lemons', 'Lemons'), @('tea-bags', 'Tea Bags'), @('cinnamon-stick', 'Cinnamon Sticks'), @('ground-cinnamon', 'Ground Cinnamon'), @('adobo-seasoning', 'Adobo seasoning'), @('saffron', 'Saffron'), @('rice', 'White Rice'), @('bananas', 'Bananas'), @('oatmeal', 'Oats / Oatmeal'), @('block-cheese', 'Block Cheese'), @('oranges', 'Oranges'), @('honey', 'Honey'), @('potato-chips', 'Potato Chips'))) { $K[$kv[0]] = [pscustomobject]@{ id = $kv[0]; label = $kv[1] } }
  foreach ($kid in 'apples', 'frosting', 'garlic', 'tomato-paste', 'coconut') { $K[$kid] = $C[$kid] }   # never $k: names are case-insensitive, so it IS $K
  # winner | other | name | LABEL
  $ccases = @(
    @('rotisserie-chicken', 'lemon-pepper-seasoning', '(Hot) Freshness Guaranteed Lemon Pepper Rotisserie Whole Chicken, 2.25 lb', 'confirm'),
    @('lemons', 'frosting', 'Betty Crocker Rich and Creamy Lemon Frosting', 'release'),
    @('tea-bags', 'cinnamon-stick', 'Bigelow Cinnamon Stick Black Tea', 'confirm'),
    @('garlic', 'tomato-paste', 'Hunt''s Tomato Paste with Basil Garlic and Oregano', 'release'),
    @('apples', 'ground-cinnamon', 'Bakers Corner Fried Apples IN Cinnamon 22 OZ', 'none'),
    @('adobo-seasoning', 'saffron', 'Goya Adobo All Purpose Seasoning with Saffron 16.5 oz', 'confirm'),
    @('adobo-seasoning', 'saffron', 'Goya Adobo All Purpose Seasoning with Saffron 16.5oz', 'confirm'),
    @('rice', 'coconut', 'Ben''s Original Rice, Coconut Jasmine 8.5 Oz', 'none'),
    @('bananas', 'oatmeal', 'Quaker Protein Banana Nut Instant Oatmeal 6 Ea', 'release'),
    @('block-cheese', 'oranges', 'Kroger Orange Rind Muenster Block Cheese', 'confirm'),
    @('honey', 'potato-chips', 'Lay''s Honey Barbecue Potato Chips', 'release')
  )
  $cDecided = 0; $cWrong = New-Object System.Collections.Generic.List[string]; $cRelOk = 0; $cRelN = 0
  foreach ($cs in $ccases) {
    $r = Get-MatchClassification -Kind 'contested' -Name $cs[2] -Target $K[$cs[1]] -Claimer $K[$cs[0]]
    Write-Output ('    ' + $r.decision.PadRight(9) + ' label=' + $cs[3].PadRight(8) + ' ' + $cs[2])
    if ($r.decision -ne 'undecided') { $cDecided++; if ($r.decision -ne $cs[3]) { [void]$cWrong.Add($cs[2] + ' -> ' + $r.decision + ' (label ' + $cs[3] + ')') } }
    if ($cs[3] -eq 'release') { $cRelN++; if ($r.decision -eq 'release') { $cRelOk++ } }
  }
  Write-Output ('    contested bar: decided ' + $cDecided + ' of ' + $ccases.Count + ', wrong ' + $cWrong.Count + ' of ' + $cDecided + $(if ($cWrong.Count) { ': ' + ($cWrong -join ' ; ') } else { '' }))
  # The gate: a kind may DECIDE only when its labelled bar holds. Read the resolver's own list, never a copy of it.
  function Test-ContestedMayDecide([string[]]$Kinds, [int]$WrongCount) { return (-not ($Kinds -contains 'contested')) -or ($WrongCount -eq 0) }
  $rsSrc = [IO.File]::ReadAllText((Join-Path $root 'resolve-match-worklist.ps1'))
  $dkM = [regex]::Match($rsSrc, '(?m)^\$DecidingKinds\s*=\s*@\(([^)]*)\)')
  $liveKinds = @([regex]::Matches($dkM.Groups[1].Value, "'([a-z-]+)'") | ForEach-Object { $_.Groups[1].Value })
  _MT ('MUST FIRE  contested added to the deciding kinds is refused while its labelled bar has a wrong decision (Bakers Corner Fried Apples IN Cinnamon confirmed to fresh apples): wrong ' + $cWrong.Count + ' of ' + $cDecided) (-not (Test-ContestedMayDecide @('coverage', 'semantic', 'contested') $cWrong.Count)) ($cWrong -join ' ; ')
  _MT ('CLEAN TWIN  the resolver as shipped passes the same gate (its deciding kinds read from its source: ' + ($liveKinds -join ',') + ')') ($dkM.Success -and $liveKinds.Count -ge 1 -and (Test-ContestedMayDecide $liveKinds $cWrong.Count)) ($liveKinds -join ',')
  _MT ('CLEAN TWIN  the contested release reading is right on every labelled release: ' + $cRelOk + ' of ' + $cRelN) ($cRelN -eq 4 -and $cRelOk -eq $cRelN) ([string]$cRelOk)

  # MUST FIRE / CLEAN TWIN on single rows
  $r = Get-MatchClassification -Kind 'coverage' -Name 'Mezzetta Sun-Dried Tomatoes' -Target $C['sun-dried-tomatoes'] -Claimer $C['turkey-lunchmeat']
  _MT 'MUST FIRE  Mezzetta Sun-Dried Tomatoes claimed by turkey-lunchmeat is release (never confirm)' ($r.decision -eq 'release' -and $r.pattern) ($r.decision + ' ' + $r.pattern)
  $r = Get-MatchClassification -Kind 'semantic' -Name 'Eggo Frozen Pancakes, Buttermilk 14.8 Oz' -Target $C['frozen-waffles'] -Claimer $null
  _MT 'MUST FIRE  Eggo Frozen Pancakes is NOT a widening of frozen-waffles' ($r.decision -ne 'widen') $r.decision
  $r = Get-MatchClassification -Kind 'coverage' -Name 'Ginger Gold Apple' -Target $C['fresh-ginger'] -Claimer $C['apples']
  _MT 'CLEAN TWIN  Ginger Gold Apple claimed by apples is confirm' ($r.decision -eq 'confirm') $r.decision
  $r = Get-MatchClassification -Kind 'coverage' -Name 'Hy-Vee Chili With Beans' -Target $C['chili-beans'] -Claimer $C['canned-chili']
  _MT 'MUST NOT FIRE  Hy-Vee Chili With Beans (a right claim by canned-chili) is never released' ($r.decision -ne 'release') $r.decision
  $r = Get-MatchClassification -Kind 'coverage' -Name 'Old Orchard Organic 100% apple or grape juice, 64 fl. oz., 2/ $7.00' -Target $C['apple-juice'] -Claimer $C['grape-juice']
  _MT 'MUST FIRE  an ad line naming two products (apple or grape juice) is ad-line and carries no pattern to apply' ($r.decision -eq 'ad-line' -and -not $r.pattern) $r.decision
  _MT 'MUST NOT FIRE  two SIZES of one product (3 or 4 ct) is not an ad line' (-not (Test-MwlAdLine 'Hagen novelties, 3 or 4 ct')) ''
  $r = Get-MatchClassification -Kind 'coverage' -Name 'Kroger Wild Caught Jumbo Raw Gulf Shrimp Shell-On BIG DEAL!' -Target $C['jumbo-pasta-shells'] -Claimer $C['shrimp']
  _MT 'MUST NOT FIRE  Shell-On shrimp is never released to jumbo-pasta-shells (a hyphenated word stays whole)' ($r.decision -ne 'release') $r.decision
  $r = Get-MatchClassification -Kind 'coverage' -Name 'Hunt''s Tomato Paste with Basil Garlic and Oregano' -Target $C['tomato-paste'] -Claimer $C['garlic']
  _MT 'MECHANISM  a release derives the narrowest exclude the name supports (the head phrase, not the bare word)' ($r.pattern -eq '\btomato\w*\s+paste') $r.pattern
  _MT 'MECHANISM  that pattern matches the product it releases' ([regex]::IsMatch('Hunt''s Tomato Paste with Basil Garlic and Oregano', $r.pattern, 'IgnoreCase')) $r.pattern

  # plan-2026-09-25-16 d493dd: the claimer's own word leading the name blocks a rule release. FROZEN from
  # match-worklist.json 2026-09-25 08:23: 'Krinos Tahini Ground Sesame Seeds' @ Fareway was decided RELEASE to
  # toasted-sesame-seeds, which would have taken Fareway's tahini cell (0.5619/oz, that exact row) off tahini.
  $ts = [pscustomobject]@{ id = 'toasted-sesame-seeds'; label = 'Toasted Sesame Seeds' }; $th = [pscustomobject]@{ id = 'tahini'; label = 'Tahini' }
  $r = Get-MatchClassification -Kind 'coverage' -Name 'Krinos Tahini Ground Sesame Seeds' -Target $ts -Claimer $th
  _MT 'MUST FIRE  Krinos Tahini Ground Sesame Seeds (claimer tahini, target toasted-sesame-seeds) is NOT release' ($r.decision -ne 'release' -and [string]$r.why -like '*tahini*') ($r.decision + ' ' + $r.why)
  $ob = [pscustomobject]@{ id = 'oranges'; label = 'Oranges' }; $bk = [pscustomobject]@{ id = 'block-cheese'; label = 'Block Cheese' }
  $r = Get-MatchClassification -Kind 'coverage' -Name 'Kroger Orange Rind Muenster Block Cheese' -Target $ob -Claimer $bk
  _MT 'CLEAN TWIN  Kroger Orange Rind Muenster Block Cheese claimed by block-cheese against oranges keeps its decision: confirm' ($r.decision -eq 'confirm') $r.decision
  $r = Get-MatchClassification -Kind 'coverage' -Name 'Betty Crocker Rich and Creamy Cherry Frosting' -Target $C['frosting'] -Claimer $C['cherries']
  _MT 'CLEAN TWIN  a claimer word AS the head''s modifier (Cherry Frosting, claimer cherries) still releases' ($r.decision -eq 'release') $r.decision
  $r = Get-MatchClassification -Kind 'band' -Name 'Litehouse Herb, Freeze Dried Basil' -Target $null -Claimer ([pscustomobject]@{ id = 'dried-basil'; label = 'Dried Basil' })
  _MT 'CLEAN TWIN  the band branch keeps its answer for Litehouse Herb, Freeze Dried Basil (undecided, never release)' ($r.decision -eq 'undecided') $r.decision

  # plan-2026-09-25-16 3ba362: a brand ampersand is not a noun list. FROZEN from match-worklist.json 2026-09-25 08:23:
  # the semantic finding 'Arm & Hammer Liquid Laundry Clean Burst' (laundry-detergent @ Family Fare) abstained as 'the
  # name lists several foods'. With the token index a conjunction is a list only when BOTH neighbours name a commodity.
  $ixComs = @($C.Values) + @([pscustomobject]@{ id = 'laundry-detergent'; label = 'Laundry Detergent' }, [pscustomobject]@{ id = 'onions'; label = 'Onions' }, [pscustomobject]@{ id = 'broccoli'; label = 'Broccoli' })
  $ix = Get-MwlTokenIndex $ixComs
  $h = Get-MwlHead 'Arm & Hammer Liquid Laundry Clean Burst' $ix
  _MT 'MUST FIRE  Arm & Hammer Liquid Laundry Clean Burst with the token index is NOT a noun list (arm, hammer name no commodity)' (-not $h.list) ([string]$h.list)
  $r = Get-MatchClassification -Kind 'semantic' -Name 'Arm & Hammer Liquid Laundry Clean Burst' -Target ([pscustomobject]@{ id = 'laundry-detergent'; label = 'Laundry Detergent' }) -Claimer $null -Index $ix
  _MT 'MUST FIRE  the classifier no longer abstains on Arm & Hammer as a list of foods' ([string]$r.why -notlike '*lists several foods*') $r.why
  $h = Get-MwlHead 'Arm & Hammer Liquid Laundry Clean Burst'
  _MT 'MECHANISM  without -Index the old reading stands (list, abstain), so a caller that passes no index is unchanged' ($h.list) ([string]$h.list)
  $h = Get-MwlHead 'Pictsweet Farms Vegetables for Roasting Halved Brussels Sprouts, Butternut Squash & Onions - 18 oz' $ix
  _MT 'CLEAN TWIN  Pictsweet Brussels Sprouts, Butternut Squash & Onions is still a list with the index' ($h.list) ([string]$h.list)
  $h = Get-MwlHead 'Hy-Vee Broccoli & Onions' $ix
  _MT 'CLEAN TWIN  Broccoli & Onions (both neighbours name a commodity, no comma) is still a list with the index' ($h.list) ([string]$h.list)
  $h = Get-MwlHead 'Betty Crocker Rich and Creamy Cherry Frosting' $ix
  _MT 'MUST NOT FIRE  Rich and Creamy (two adjectives) is still not a list with the index' (-not $h.list) ([string]$h.list)
  # the surface rule 3ba362 adds to hot-sauce, frozen: bounded, never a bare 'pepper sauce'
  $hs = @('\b(?:cayenne|red\s+devil|louisiana)\b.{0,40}\bpepper\s+sauce\b', '\bpepper\s+sauce\b.{0,40}\b(?:cayenne|red\s+devil)\b')
  $hsHit = { param($nm) @($hs | Where-Object { [regex]::IsMatch($nm, $_, 'IgnoreCase') }).Count -gt 0 }
  _MT 'MUST FIRE  the hot-sauce include admits Trappey''s Pepper Sauce, Cayenne, Red Devil 12 Fl Oz' (& $hsHit 'Trappey''s Pepper Sauce, Cayenne, Red Devil 12 Fl Oz') ''
  _MT 'MUST NOT FIRE  the hot-sauce include does not admit Mae Ploy Sweet Chili Sauce' (-not (& $hsHit 'Mae Ploy Sweet Chili Sauce')) ''
  _MT 'MUST NOT FIRE  the hot-sauce include does not admit a bare Black Pepper Sauce' (-not (& $hsHit 'Kroger Black Pepper Sauce')) ''

  # plan-2026-09-25-16 d493dd: one worklist key per ACTIONABLE VERDICT, not one per gap
  $kd = Join-Path $tmp 'keying'; New-Item -ItemType Directory -Path $kd -Force | Out-Null
  $kg = @(
    [pscustomobject]@{ commodity = 'canned-mixed-vegetables'; store = 'Hy-Vee'; candidate = 'Birds Eye Steamfresh Mixed Vegetables'; reason = 'CLAIMED-BY'; detail = "first-match-wins gave this name to 'frozen-vegetables'"; actionable = $true
      verdicts = @([pscustomobject]@{ candidate = 'Birds Eye Steamfresh Mixed Vegetables'; reason = 'WITHHELD'; detail = "first-match-wins gave this name to 'frozen-vegetables', and the provenance contract withheld that row there"; actionable = $false },
                   [pscustomobject]@{ candidate = 'That''s Smart! Mixed Vegetables With Carrots, Corn, Peas & Green Beans'; reason = 'CLAIMED-BY'; detail = "first-match-wins gave this name to 'frozen-vegetables'"; actionable = $true }) },
    [pscustomobject]@{ commodity = 'kalamata-olives'; store = 'Sam''s Club'; candidate = 'Krinos Kalamata Pitted Olives, 35.27 oz.'; reason = 'RULE-INVISIBLE'; detail = 'no include of any commodity matched this name'; actionable = $true
      verdicts = @([pscustomobject]@{ candidate = 'Krinos Kalamata Pitted Olives, 35.27 oz.'; reason = 'RULE-INVISIBLE'; detail = 'no include of any commodity matched this name'; actionable = $true }) },
    [pscustomobject]@{ commodity = 'yellow-bell-pepper'; store = 'Family Fare'; candidate = 'Yellow Bell Pepper'; reason = 'PRICED'; detail = 'the engine priced this row'; actionable = $true
      verdicts = @([pscustomobject]@{ candidate = 'Yellow Bell Pepper'; reason = 'PRICED'; detail = 'the engine priced this row'; actionable = $true }) })
  [IO.File]::WriteAllText((Join-Path $kd 'coverage-gaps.json'), (([pscustomobject]@{ gaps = $kg }) | ConvertTo-Json -Depth 6))
  $kf = Read-MatchFindings -OutDir $kd -GroceryDir $kd
  $kk = @($kf.rows | ForEach-Object { [string]$_.key })
  _MT 'MUST FIRE  the canned-mixed-vegetables|Hy-Vee gap keys its ACTIONABLE name (That''s Smart!), claimer frozen-vegetables, not its withheld head' (($kk -contains 'coverage|canned-mixed-vegetables|Hy-Vee|That''s Smart! Mixed Vegetables With Carrots, Corn, Peas & Green Beans') -and -not ($kk -contains 'coverage|canned-mixed-vegetables|Hy-Vee|Birds Eye Steamfresh Mixed Vegetables') -and @($kf.rows | Where-Object { $_.claimer -eq 'frozen-vegetables' }).Count -eq 1) ($kk -join ' ; ')
  _MT 'CLEAN TWIN  an undecided RULE-INVISIBLE name (Krinos Kalamata Pitted Olives) still yields its worklist key' ($kk -contains 'coverage|kalamata-olives|Sam''s Club|Krinos Kalamata Pitted Olives, 35.27 oz.') ($kk -join ' ; ')
  _MT 'MUST NOT FIRE  a PRICED verdict is not a matching finding and gets no key' (-not ($kk -contains 'coverage|yellow-bell-pepper|Family Fare|Yellow Bell Pepper') -and $kk.Count -eq 2) ($kk -join ' ; ')
  # the recurrences this item closes (2026-08-31-ad3b81 .. 2026-09-07-0e9482): their queue bodies in
  # out\archive\triage-queue.archived-2026-09-17.json name only commodity @ store, never the candidate, so the frozen
  # rows carry that pair and a placeholder candidate, in the pre-verdicts gap shape those days wrote. The assertion is
  # the property that matters: every actionable gap of that shape is keyed, none silently unkeyed.
  $old = @('garlic-bread|Hy-Vee','aji-amarillo-paste|Walmart','yukon-gold-potatoes|Fareway','coleslaw-mix|Hy-Vee','pomegranates|Walmart','coleslaw-mix|Walmart','cooked-jasmine-rice|Walmart','block-cheese|Family Fare','coleslaw-mix|Aldi','red-potatoes|Fareway','pecorino-romano|Fareway','cinnamon-stick|Aldi','baked-beans|Hy-Vee','anaheim-peppers|Fareway','quinoa-uncooked|Hy-Vee','couscous|Hy-Vee','sea-salt|Hy-Vee')
  $og = @($old | ForEach-Object { $p = $_ -split '\|'; [pscustomobject]@{ commodity = $p[0]; store = $p[1]; candidate = ('candidate not recorded in the queue body (' + $_ + ')'); reason = 'RULE-INVISIBLE'; detail = 'no include matched'; actionable = $true } })
  [IO.File]::WriteAllText((Join-Path $kd 'coverage-gaps.json'), (([pscustomobject]@{ gaps = $og }) | ConvertTo-Json -Depth 6))
  $of = Read-MatchFindings -OutDir $kd -GroceryDir $kd
  $miss = @($old | Where-Object { $pp = $_ -split '\|'; -not @($of.rows | Where-Object { $_.commodity -eq $pp[0] -and $_.store -eq $pp[1] }).Count })
  _MT ('MUST FIRE  the 17 frozen recurrence gaps (ad3b81, 4a481e, 995502, 39933e, 0e9482) in the old gap shape are every one keyed: missing ' + $miss.Count + ' of ' + $old.Count) ($miss.Count -eq 0 -and $old.Count -eq 17) ($miss -join ' ; ')

  # the worklist: first_seen, the ledger filter, one page per key
  $f1 = @([pscustomobject]@{ key = 'coverage|queso|Fareway|X'; kind = 'coverage'; commodity = 'queso'; claimer = 'salsa'; store = 'Fareway'; name = 'X' })
  $d1 = Merge-MatchWorklist -Findings $f1 -Previous @() -Verdicts @{} -Today '2026-09-22'
  $p1 = Get-MatchPageRows -Worklist $d1 -Kind 'coverage' -Today '2026-09-22'
  _MT 'MUST FIRE  a NEW undecided key pages on its first_seen day' (@($p1).Count -eq 1) ([string]@($p1).Count)
  $d2 = Merge-MatchWorklist -Findings $f1 -Previous $d1 -Verdicts @{} -Today '2026-09-23'
  $p2 = Get-MatchPageRows -Worklist $d2 -Kind 'coverage' -Today '2026-09-23'
  _MT 'MUST NOT FIRE  the same undecided key the next day does not page again (it paged exactly once)' (@($p2).Count -eq 0 -and [string]$d2[0].first_seen -eq '2026-09-22') ([string]@($p2).Count)
  $vd = @{ 'coverage|queso|Fareway|X' = [pscustomobject]@{ key = 'coverage|queso|Fareway|X'; verdict = 'confirm' } }
  $d3 = Merge-MatchWorklist -Findings $f1 -Previous @() -Verdicts $vd -Today '2026-09-24'
  _MT 'MUST NOT FIRE  a key decided yesterday that the detector reports again today is not on the worklist and cannot page' (@($d3).Count -eq 0) ([string]@($d3).Count)
  $d4 = Merge-MatchWorklist -Findings @() -Previous $d1 -Verdicts @{} -Today '2026-09-23' -BlindKinds @('coverage')
  _MT 'CLEAN TWIN  a BLIND detector keeps yesterday''s key (not forgotten, not re-paged)' (@($d4).Count -eq 1 -and -not $d4[0].new) ([string]@($d4).Count)
  $d5 = Merge-MatchWorklist -Findings @() -Previous $d1 -Verdicts @{} -Today '2026-09-23'
  _MT 'MECHANISM  a key the detector no longer reports (and which ran) drops off the worklist' (@($d5).Count -eq 0) ([string]@($d5).Count)

  # end to end over a temp tree: the resolver decides, writes the ledger, never touches the rule file
  $od = Join-Path $tmp 'out'; New-Item -ItemType Directory -Path (Join-Path $od 'audit') -Force | Out-Null
  $gaps = @(
    [pscustomobject]@{ commodity = 'fresh-ginger'; store = 'Fareway'; candidate = 'Ginger Gold Apple'; reason = 'CLAIMED-BY'; detail = "first-match-wins gave this name to 'apples'"; actionable = $true },
    [pscustomobject]@{ commodity = 'sun-dried-tomatoes'; store = 'Fareway'; candidate = 'Mezzetta Sun-Dried Tomatoes'; reason = 'CLAIMED-BY'; detail = "first-match-wins gave this name to 'turkey-lunchmeat'"; actionable = $true },
    [pscustomobject]@{ commodity = 'lemons'; store = 'Walmart'; candidate = 'q'; reason = 'BASIS-NULL'; detail = ''; actionable = $false })
  [IO.File]::WriteAllText((Join-Path $od 'coverage-gaps.json'), (([pscustomobject]@{ gaps = $gaps }) | ConvertTo-Json -Depth 4))
  $nc = @([pscustomobject]@{ name = 'Simple Truth Organic Whole Kernel Super Sweet Corn'; chain = 'canned-corn (oz) > frozen-corn (oz)'; winner = 'canned-corn'; form = $false; verdict = 'size 15 oz = 0.1193/oz'; cell = ''; crown = $false })
  [IO.File]::WriteAllText((Join-Path $od 'audit\soundness-report.json'), (([pscustomobject]@{ new_contested = $nc }) | ConvertTo-Json -Depth 4))
  $comF = Join-Path $tmp 'commodities.json'
  $comObjs = @($C.Values) + @([pscustomobject]@{ id = 'canned-corn'; label = 'Canned Corn' }, [pscustomobject]@{ id = 'frozen-corn'; label = 'Frozen Corn' })
  [IO.File]::WriteAllText($comF, ($comObjs | ConvertTo-Json -Depth 3))
  $comHash = (Get-FileHash -LiteralPath $comF).Hash
  $vf = Join-Path $tmp 'match-verdicts.json'
  $rs = Join-Path $root 'resolve-match-worklist.ps1'
  $o1 = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $rs -OutDir $od -GroceryDir $tmp -VerdictFile $vf -CommoditiesFile $comF -Today '2026-09-22'); $rc1 = $LASTEXITCODE
  _MT 'MECHANISM  the resolver runs and prints its marker' ($rc1 -eq 0 -and (@($o1 | Where-Object { $_ -like 'MATCH-WORKLIST-COMPLETE*' }).Count -eq 1)) (($o1 | Select-Object -Last 2) -join ' / ')
  $v1 = Read-MatchVerdicts $vf
  _MT 'CLEAN TWIN  Ginger Gold Apple (confirm) lands in match-verdicts.json' ($v1.ContainsKey('coverage|fresh-ginger|Fareway|Ginger Gold Apple') -and [string]$v1['coverage|fresh-ginger|Fareway|Ginger Gold Apple'].verdict -eq 'confirm') ([string]$v1.Count)
  $wl1 = Read-MatchWorklist (Join-Path $od 'match-worklist.json')
  $mz = @($wl1 | Where-Object { $_.name -eq 'Mezzetta Sun-Dried Tomatoes' })[0]
  _MT 'MUST FIRE  the Mezzetta release waits on the worklist with its pattern, for the weekly batch' ($mz -and [string]$mz.decision -eq 'release' -and [string]$mz.pattern) ([string]$mz.decision)
  _MT 'MECHANISM  the resolver judged the release against the CLAIMER''s own words (its reason names turkey-lunchmeat; a shadowed claimer reads ''and ''s own words'')' ([string]$mz.why -like '*turkey-lunchmeat*') ([string]$mz.why)
  $cn = @($wl1 | Where-Object { $_.kind -eq 'contested' })[0]
  _MT 'MECHANISM  a contested arrival joins the worklist docket-only (decision undecided, suggestion kept)' ($cn -and [string]$cn.decision -eq 'undecided') ([string]$cn.decision)
  _MT 'MUST NOT FIRE  the lane never edits a rule: the commodity file is byte-identical after the run' ((Get-FileHash -LiteralPath $comF).Hash -eq $comHash) ''
  # -Decide one contested name; the soundness audit then reads it as reviewed, and the baseline is untouched
  $ck = 'contested|canned-corn||Simple Truth Organic Whole Kernel Super Sweet Corn'
  $o2 = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $rs -OutDir $od -GroceryDir $tmp -VerdictFile $vf -CommoditiesFile $comF -Today '2026-09-22' -Decide $ck -Verdict confirm -Reason 'Kroger 15 oz can; canned-corn is right (plan-2026-09-22-2)'); $rc2 = $LASTEXITCODE
  $base = [pscustomobject]@{ contested = @('Already Reviewed Name') }
  $rev = Get-ReviewedContested -Baseline $base -VerdictFile $vf
  _MT 'CLEAN TWIN  a confirmed contested name is REVIEWED for audit-match-soundness (and the baseline''s own list still is)' ($rc2 -eq 0 -and $rev.ContainsKey('Simple Truth Organic Whole Kernel Super Sweet Corn') -and $rev.ContainsKey('Already Reviewed Name')) (($o2 -join ' ') + ' rc=' + $rc2)
  $o3 = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $rs -OutDir $od -GroceryDir $tmp -VerdictFile $vf -CommoditiesFile $comF -Today '2026-09-23'); $wl3 = Read-MatchWorklist (Join-Path $od 'match-worklist.json')
  _MT 'MUST NOT FIRE  the next run no longer carries the decided contested name' (@($wl3 | Where-Object { $_.kind -eq 'contested' }).Count -eq 0) ([string]@($wl3).Count)
  $kn = Get-LaneKnownContested -WorklistFile (Join-Path $od 'match-worklist.json') -VerdictFile $vf -Today '2026-09-23'
  $cc = @([pscustomobject]@{ Label = 'NEW CONTESTED'; Text = 'NEW-CONTESTED Simple Truth Organic Whole Kernel Super Sweet Corn | chain: x' }, [pscustomobject]@{ Label = 'NEW CONTESTED'; Text = 'NEW-CONTESTED Brand New Arrival | chain: y' }, [pscustomobject]@{ Label = 'CONTESTED CROWN'; Text = 'NEW-CONTESTED Simple Truth Organic Whole Kernel Super Sweet Corn | chain: x | holds a CROWN: z' })
  $sel = Select-UnknownContestedConditions $cc $kn
  _MT 'MUST FIRE  an arrival the lane does not know still pages; a known one does not; a CONTESTED CROWN line is never filtered' (@($sel).Count -eq 2 -and @($sel | Where-Object { $_.Text -like '*Brand New Arrival*' }).Count -eq 1 -and @($sel | Where-Object { $_.Label -eq 'CONTESTED CROWN' }).Count -eq 1) ([string]@($sel).Count)
  $o4 = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $rs -OutDir (Join-Path $tmp 'nothing-here') -GroceryDir (Join-Path $tmp 'nothing-here') -VerdictFile $vf -CommoditiesFile $comF -Today '2026-09-23'); $rc4 = $LASTEXITCODE
  _MT 'MUST FIRE  with every detector file missing the resolver exits 3 (could not evaluate), never 0' ($rc4 -eq 3) ([string]$rc4)
  # band rows outside the backlog (plan-2026-09-25-7, queue 2026-09-23-57b66b): the open file joins the docket
  $bdir = Join-Path $tmp 'band'; $bod = Join-Path $bdir 'out'; New-Item -ItemType Directory -Path $bod -Force | Out-Null
  [IO.File]::WriteAllText((Join-Path $bdir 'band-refusals-backlog.json'), '{ "recorded": "2026-09-22", "keys": [ "bay-leaves|Sam''s Club|Member''s Mark Whole Bay Leaves, 2 oz." ] }')
  [IO.File]::WriteAllText((Join-Path $bod 'band-refusals-open.json'), '{ "rows": [ { "key": "apple-juice|Baker''s|Evolution Fresh Cold Pressed Organic Apple Juice - 50 Fl Oz", "first_seen": "2026-09-23", "unit_price": 0.1998, "band_ref": 0.0387 } ] }')
  $bf = Read-MatchFindings -OutDir $bod -GroceryDir $bdir
  $bj = @($bf.rows | Where-Object { $_.key -eq 'band|apple-juice|Baker''s|Evolution Fresh Cold Pressed Organic Apple Juice - 50 Fl Oz' })
  _MT 'MUST FIRE  a band row outside the backlog (the Evolution Fresh juice paged 2026-09-23..25) joins the worklist as kind band from band-refusals-open.json' ($bj.Count -eq 1 -and [string]$bj[0].claimer -eq 'apple-juice' -and [string]$bj[0].evidence -like '*first seen 2026-09-23*') ([string]$bj.Count)
  _MT 'CLEAN TWIN  the backlog''s own band row is still read beside it, and band is not blind' (@($bf.rows | Where-Object { $_.kind -eq 'band' }).Count -eq 2 -and -not (@($bf.blind) -contains 'band')) ([string]@($bf.rows).Count)
} catch {
  _MT ('the suite threw: ' + $_.Exception.Message) $false
} finally {
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Output ('test-match-worklist self-test ' + $(if ($script:bad -eq 0) { 'pass' } else { 'FAIL' }) + ': ' + ($script:n - $script:bad) + ' of ' + $script:n + ' case(s)')
exit $(if ($script:bad -eq 0) { 0 } else { 1 })
