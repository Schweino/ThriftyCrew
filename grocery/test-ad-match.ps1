<#
  test-ad-match.ps1 - frozen fixtures for ad-match-lib.ps1 (Find-AdForCell).

  THE FOUNDING BUG (2026-08-22): Find-AdForCell returned the FIRST ad row sharing one distinctive
  word and the cell's dollar figure, so "Hy-Vee Shredded Cheddar Cheese 8 oz $1.99" inherited the
  window of an earlier "Hy-Vee Cottage Cheese 24 oz $1.99" line - a cell carrying another product's
  sale dates. MUST-FIRE below. The clean twins pin what must keep working: the terse butter line
  that this library was written for, and the two-word rule for rows with no price match.

  Runs the REAL loader (Import-AdRows) over a synthetic out\ tree in TEMP, so the fixture exercises
  the same tokenising and indexing the engine uses. -LibPath lets a reviewer point it at an older
  copy of the lib to watch the must-fire case fail.

  Run: test-ad-match.ps1        (exit 0 clean, 1 on any failure)
#>
param([string]$LibPath = '')
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $LibPath) { $LibPath = Join-Path $root 'ad-match-lib.ps1' }
. $LibPath
$fail = 0
function Ok($m) { Write-Output "ok    $m" }
function Bad($m) { Write-Output "FAIL  $m"; $script:fail++ }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('admatch-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
try {
  # ORDER IS THE FIXTURE: the wrong-product line comes FIRST, with the same dollar figure.
  $ads = @{ today = '2026-08-21'; deals = @(
    @{ store='Hy-Vee'; item='Hy-Vee Cottage Cheese, 24 oz.';        ad_price='$1.99'; ad_from='2026-08-17'; ad_to='2026-08-23' },
    @{ store='Hy-Vee'; item='Hy-Vee Sour Cream, 16 oz.';             ad_price='$1.99'; ad_from='2026-08-17'; ad_to='2026-08-23' },
    @{ store='Hy-Vee'; item='Hy-Vee shredded cheese, 8 oz.';        ad_price='$1.99'; ad_from='2026-08-21'; ad_to='2026-08-23' },
    @{ store='Hy-Vee'; item='Hy-Vee butter, 16 oz.';                ad_price='$2.48'; ad_from='2026-08-21'; ad_to='2026-08-23' },
    @{ store='Hy-Vee'; item='Land O Lakes Butter Quarters, 16 oz.'; ad_price='$4.99'; ad_from='2026-08-17'; ad_to='2026-08-23' },
    @{ store='Hy-Vee'; item='Tyson boneless chicken breast';        ad_price='$2.39'; ad_from='2026-08-17'; ad_to='2026-08-23' },
    @{ store='Fareway'; item='Fareway shredded cheese 8 oz';        ad_price='$1.99'; ad_from='2026-08-17'; ad_to='2026-08-22' }
  ) }
  [IO.File]::WriteAllText((Join-Path $tmp 'ads-2026-08-21.json'), ($ads | ConvertTo-Json -Depth 4))
  $idx = Import-AdRows -OutDir $tmp -BoardDate '2026-08-21'

  # 1. MUST-FIRE: the cheddar cell must NOT take the cottage-cheese window (first same-price line)...
  $h = Find-AdForCell -Index $idx -Store 'Hy-Vee' -Item 'Hy-Vee Shredded Cheddar Cheese 8 oz' -PriceText '$1.99'
  if ($h -and $h.text -match 'shredded cheese' -and $h.from -eq '2026-08-21') { Ok "shredded cheddar took the SHREDDED CHEESE line (08-21..08-23), not cottage cheese: '$($h.text)'" }
  elseif ($h) { Bad "shredded cheddar inherited ANOTHER product's window: '$($h.text)' $($h.from)..$($h.to)" }
  else { Bad 'shredded cheddar matched nothing - it must still match "Hy-Vee shredded cheese, 8 oz., $1.99"' }

  # 2. ...and must still match the terse shredded line when it is the ONLY candidate (the ask, verbatim)
  $only = @{ today = '2026-08-21'; deals = @(@{ store='Hy-Vee'; item='Hy-Vee shredded cheese, 8 oz.'; ad_price='$1.99'; ad_from='2026-08-21'; ad_to='2026-08-23' }) }
  $t2 = Join-Path $tmp 'only'; New-Item -ItemType Directory -Path $t2 -Force | Out-Null
  [IO.File]::WriteAllText((Join-Path $t2 'ads-2026-08-21.json'), ($only | ConvertTo-Json -Depth 4))
  $i2 = Import-AdRows -OutDir $t2 -BoardDate '2026-08-21'
  $h2 = Find-AdForCell -Index $i2 -Store 'Hy-Vee' -Item 'Hy-Vee Shredded Cheddar 8 oz' -PriceText '$1.99'
  if ($h2 -and $h2.from -eq '2026-08-21') { Ok '"Hy-Vee Shredded Cheddar 8 oz $1.99" still matches "Hy-Vee shredded cheese, 8 oz., $1.99"' } else { Bad 'the terse shredded-cheese line no longer matches its cell' }
  # and with ONLY the cottage-cheese line on offer, the cheddar cell takes nothing rather than the wrong window
  $cot = @{ today = '2026-08-21'; deals = @(@{ store='Hy-Vee'; item='Hy-Vee Cottage Cheese, 24 oz.'; ad_price='$1.99'; ad_from='2026-08-17'; ad_to='2026-08-23' }) }
  $t3 = Join-Path $tmp 'cot'; New-Item -ItemType Directory -Path $t3 -Force | Out-Null
  [IO.File]::WriteAllText((Join-Path $t3 'ads-2026-08-21.json'), ($cot | ConvertTo-Json -Depth 4))
  $i3 = Import-AdRows -OutDir $t3 -BoardDate '2026-08-21'
  $h3 = Find-AdForCell -Index $i3 -Store 'Hy-Vee' -Item 'Hy-Vee Shredded Cheddar Cheese 8 oz' -PriceText '$1.99'
  if ($null -eq $h3) { Ok 'MUST-FIRE: with only the cottage-cheese line available, the cheddar cell takes NO window (1 of 2 ad tokens shared is not enough for a 3-token cell)' }
  else { Bad "the cheddar cell borrowed the cottage-cheese window: '$($h3.text)'" }

  # 3. CLEAN TWIN: the founding butter case - a 5-token cell against a 1-token ad line, matched on price + the one word
  $b = Find-AdForCell -Index $idx -Store 'Hy-Vee' -Item 'Hy-Vee Sweet Cream Salted Butter Quarters' -PriceText '$2.48'
  if ($b -and $b.text -match 'Hy-Vee butter' -and $b.from -eq '2026-08-21') { Ok 'the butter that started this library still traces to "Hy-Vee butter, 16 oz., $2.48"' } else { Bad "butter lost its ad: $(if ($b) { $b.text } else { '<null>' })" }
  # and when the price points at the OTHER butter line, the brand/size words carry it there
  $b2 = Find-AdForCell -Index $idx -Store 'Hy-Vee' -Item 'Land O Lakes Salted Butter Quarters 16 oz' -PriceText '$4.99'
  if ($b2 -and $b2.text -match 'Land O Lakes') { Ok 'brand words steer a same-category cell to ITS line (Land O Lakes at $4.99)' } else { Bad "brand cell went to $(if ($b2) { $b2.text } else { '<null>' })" }

  # 4. CLEAN TWIN: the two-shared-words rule for a cell whose price matches no line
  $c = Find-AdForCell -Index $idx -Store 'Hy-Vee' -Item 'Tyson Boneless Skinless Chicken Breast' -PriceText '$2.99'
  if ($c -and $c.text -match 'chicken breast') { Ok 'no price match + two shared words still traces (chicken breast)' } else { Bad 'the two-word rule stopped working' }
  # one shared word and no price match is NOT a trace (never was)
  $d = Find-AdForCell -Index $idx -Store 'Hy-Vee' -Item 'Hy-Vee Chicken Noodle Soup' -PriceText '$0.99'
  if ($null -eq $d) { Ok 'one shared word with no price match traces nothing' } else { Bad "a single word borrowed a window: $($d.text)" }

  # 5. stores are kept apart: the Fareway shredded line never answers a Hy-Vee cell
  $f = Find-AdForCell -Index $idx -Store 'Fareway' -Item 'Hy-Vee Shredded Cheddar Cheese 8 oz' -PriceText '$1.99'
  if ($f -and $f.text -match 'Fareway') { Ok 'store index is honoured (Fareway cell -> Fareway line)' } else { Bad 'store isolation broke' }
} finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }

Write-Output ("AD-MATCH " + $(if ($fail) { "FAILED ($fail)" } else { 'PASSED' }))
exit $(if ($fail) { 1 } else { 0 })
