# Round-1 rule fixes from the staples300 drop diagnostic (real store names vs authored rules).
$ErrorActionPreference = 'Stop'
$root = 'C:\Codex\ThriftyCrew\grocery'
$cf = Join-Path $root 'commodities.json'
$tmp = ConvertFrom-Json ([IO.File]::ReadAllText($cf)); $commods = @($tmp)
$byId = @{}; foreach ($c in $commods) { $byId[[string]$c.id] = $c }

function AddInc([string]$id, [string[]]$pats) { $c = $byId[$id]; if ($c) { foreach ($p in $pats) { if (@($c.include) -notcontains $p) { $c.include = @($c.include) + @($p) } } } }
function AddExc([string]$id, [string[]]$pats) { $c = $byId[$id]; if ($c) { foreach ($p in $pats) { if (@($c.exclude) -notcontains $p) { $c.exclude = @($c.exclude) + @($p) } } } }
function AddRelax([string]$id, [string[]]$pats) { $c = $byId[$id]; if (-not $c) { return }; if (-not $c.PSObject.Properties['relax_global']) { $c | Add-Member relax_global @() }; foreach ($p in $pats) { if (@($c.relax_global) -notcontains $p) { $c.relax_global = @($c.relax_global) + @($p) } } }
function RepExc([string]$id, [string]$old, [string]$new) { $c = $byId[$id]; if ($c) { $c.exclude = @($c.exclude | ForEach-Object { if ($_ -eq $old) { $new } else { $_ } }) } }
function SetBandMin([string]$id, [double]$v) { $c = $byId[$id]; if ($c) { $c.band_min = $v } }

# --- includes for real-world store naming ---
AddInc 'rotisserie-chicken'      @('roasted\s+whole\s+chicken', 'hot\s+whole\s+chicken')
AddInc 'canned-mushrooms'        @('pieces\s*(?:&|and)\s*stems')
AddInc 'instant-mashed-potatoes' @('\bidahoan\b', 'homestyle\s+(?:butter(?:y)?\s+)?mashed')
AddInc 'fruit-cups'              @('mandarin\s+oranges?\b.{0,30}juice', 'mixed\s+fruits?\b.{0,25}(?:cups?|variety)', 'fruit\s+bowls?')
AddInc 'disinfectant-spray'      @('disinfectant\b.{0,45}spray', 'antibacterial\s+spray')
AddInc 'frozen-fruit'            @('unsweetened\s+(?:whole\s+|sliced\s+)?(?:strawberries|berries|fruit)', 'cherry\s+berry\s+blend')
AddInc 'apple-juice'             @('apple\b.{0,15}100%\s*juice')
AddInc 'grape-juice'             @('(?:100%\s+)?juice,?\s+grape', 'grape\b.{0,15}100%\s*juice')
AddInc 'cranberry-juice'         @('cranberry\b.{0,15}100%\s*juice')
AddInc 'frozen-corn'             @('cut\s+(?:golden\s+)?corn', 'steamables?\b.{0,20}corn', 'super\s+sweet\s+corn', 'whole\s+kernel\s+golden\s+corn')
AddInc 'frozen-peas'             @('steamables?\b.{0,20}peas', 'sweet\s+green\s+peas', 'green\s+peas\b')
AddInc 'baby-back-ribs'          @('pork\s+loin\s+back\s+ribs', '\bback\s+ribs\b')
AddInc 'apple-cider-vinegar'     @('apple\s+cider\s+flavored\s+(?:distilled\s+)?vinegar')
AddInc 'gelatin'                 @('juicy\s+gels')
AddInc 'popsicles'               @('\bice\s+pops?\b', 'freeze\s+pops?', 'bomb\s+pops?', 'fun\s*pops')
AddInc 'egg-noodles'             @('egg\s+pasta')
AddInc 'fruit-snacks'            @('fruit\s+flavored\s+snacks', 'fruity\s+snacks')
AddInc 'iced-tea'                @('brewed\b.{0,20}tea', 'pure\s+leaf')
AddInc 'breakfast-sandwiches'    @('croissant\s+sandwich', 'biscuit\s+sandwich', 'sandwiches\b.{0,35}(?:sausage|egg)')
AddInc 'laundry-pods'            @('power\s+pacs?', 'power\s+paks?')
AddInc 'plastic-wrap'            @("cling\s*'?n'?\s*seal", 'food\s+wrap')
AddInc 'lotion'                  @('skin\s+moisturizer', 'healing\b.{0,30}moisturizer')
AddInc 'feminine-pads'           @('always\b.{0,25}pads?', 'maxi\b.{0,15}pads?')
AddInc 'baby-food'               @('baby\b.{0,25}pouches', 'organics\b.{0,35}pouches', 'happy\s*baby', 'beech-?nut')
AddInc 'bottled-water'           @('bottled\s+water')
AddInc 'frozen-vegetables'       @('vegetables\b.{0,12}mixed')
AddInc 'all-purpose-cleaner'     @('all\s+purpose\s+spray\s+cleaner', '\bspray\s+cleaner\b')
AddInc 'french-bread'            @('french\s+bakery\s+bread', 'bakery\s+bread\s+loaf')
AddInc 'chocolate-chips'         @('chocolate\s+baking\s+chips', 'baking\s+chips')
AddInc 'tomato-soup'             @('tomato\s+condensed\s+soup', 'condensed\s+tomato\s+soup')
AddInc 'frozen-broccoli'         @('cut\s+broccoli')
AddInc 'frozen-lasagna'          @('\blasagna\b')
AddInc 'pork-shoulder'           @('half\s+butt', 'butt\s+pork\s+roast')
AddInc 'brown-rice'              @('brown\s+basmati')
AddInc 'canned-peaches'          @('peach\s+slices', 'peaches\s+in\s+(?:heavy\s+|light\s+)?syrup')
AddInc 'sandwich-cookies'        @('sandwich\s+creme\s+cookies', 'creme\s+cookies')
AddInc 'protein-bars'            @('protein\b.{0,18}bars?')
AddInc 'toaster-pastries'        @('toaster\s+tarts?', 'pop-?ups')
AddInc 'sparkling-water'         @('belle\s+vie', 'sparkling\s+flavored\s+water')
AddInc 'coffee-pods'             @('coffee\s+cups\b')

# --- excludes: stop thefts + misgrabs ---
RepExc 'rice' 'cake' '\bcakes?\b'
AddExc 'butter'            @('popcorn')
AddExc 'strawberries'      @('pastr', '\bsnacks?\b', 'toaster', '\bwash\b', 'lotion', 'shampoo', 'body', 'creamer', 'gels')
AddExc 'ground-beef-8020'  @('\bpork\b')
AddExc 'cherries'          @('\bblend\b', 'pastr', 'toaster', 'frosted', '\bpops?\b', '\bgels\b')
AddExc 'frozen-corn'       @('\bdogs?\b')
AddExc 'milk'              @('formula', 'milk[\s-]?bones?')
AddExc 'whole-chicken'     @('roasted')
AddExc 'lasagna-noodles'   @('meat', 'italian-?style', 'family')
AddExc 'granola-bars'      @('\bfruity\b')
AddExc 'raspberries'       @('gels', 'creamer', '\bwash\b')
AddExc 'blackberries'      @('gels', '\bwash\b')
# lasagna-noodles include narrowed to noodles-only
$ln = $byId['lasagna-noodles']; if ($ln) { $ln.include = @('lasagna\s+noodles?') }

# --- relax_global for legit token-in-name cases ---
AddRelax 'coffee-creamer'      @('flavored')
AddRelax 'pudding-cups'        @('flavored')
AddRelax 'hot-cocoa'           @('flavored')
AddRelax 'fruit-snacks'        @('flavored')
AddRelax 'gelatin'             @('flavored')
AddRelax 'apple-cider-vinegar' @('flavored')
AddRelax 'sparkling-water'     @('flavored')
AddRelax 'cheese-crackers'     @('\bbaked\b', '\bbake\b')
AddRelax 'crackers'            @('\bbaked\b', '\bbake\b')
AddRelax 'pita-bread'          @('\bbaked\b', '\bbake\b')
AddRelax 'croissants'          @('\bbake\b', '\bbaked\b')
AddRelax 'muffins'             @('\bbake\b', '\bbaked\b')
AddRelax 'chocolate-chips'     @('\bbake\b', '\bbaked\b')
AddRelax 'frozen-lasagna'      @('\bsauce\b')
AddRelax 'baked-beans'         @('\bsauce\b')
AddRelax 'canned-salmon'       @('\bwater\b')
AddRelax 'body-wash'           @('\bwater\b')
AddRelax 'baby-wipes'          @('\bwater\b')
AddRelax 'toothpaste'          @('\bsoda\b')
AddRelax 'cat-litter'          @('\bsoda\b')
AddRelax 'canned-tuna'         @('\bwater\b')

# --- bands ---
SetBandMin 'shampoo' 0.05
SetBandMin 'conditioner' 0.05

ConvertTo-Json @($commods) -Depth 6 | Set-Content $cf -Encoding UTF8
Write-Output 'round-1 rule fixes applied'
