<#
  build-share-image.ps1 - the weekly shareable "biggest price drops" graphic + og:image.

  WHY: the Reddit spike (1,182 board visitors in 30 days) came from ONE share. Reddit reposts data images
  every week; this gives it one every week, generated from the same verified data as the board. The image
  doubles as the board post's og:image, so every shared link previews THIS WEEK'S real numbers instead of a
  static logo (publish-deals-page appends ?w=<week> so scrapers re-fetch when the week changes).

  DATA: public\price-history.json (per-item per-store daily series). A "drop" = the item's cheapest
  cross-store per-unit TODAY vs its cheapest 7 days ago, largest percentage falls first. Only real,
  currently-verified prices - the same rule as everything else on the board.

  OUTPUT: public\share\omaha-drops.png (1200x630). GDI+ (same proven stack as the TikTok renderer).
#>
param([string]$OutPath = "")
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$pub = Join-Path (Split-Path $root -Parent) 'public'
if (-not $OutPath) { $OutPath = Join-Path $pub 'share\omaha-drops.png' }
New-Item -ItemType Directory -Force -Path (Split-Path $OutPath -Parent) | Out-Null

Add-Type -AssemblyName System.Drawing

$hist = Get-Content (Join-Path $pub 'price-history.json') -Raw | ConvertFrom-Json
$drops = New-Object System.Collections.Generic.List[object]
foreach ($p in $hist.PSObject.Properties) {
  $it = $p.Value
  $weeks = @($it.w)
  if ($weeks.Count -lt 2) { continue }
  $nowI = $weeks.Count - 1
  $thenI = [math]::Max(0, $weeks.Count - 8)
  # SAME-STORE drops ONLY. Comparing cross-store minimums lies the week coverage grows: adding Sam's bulk
  # rows made "cheapest yeast" fall 86% with no store cutting a cent. A drop we publish must be one store's
  # own price moving, both endpoints real. And a same-store move past 60% is almost always the tracked SKU
  # switching inside that store, not a price cut - skip those too. Honest beats dramatic.
  $bestPct = 0.0; $best = $null
  foreach ($sp in $it.s.PSObject.Properties) {
    $ser = @($sp.Value)
    if ($ser.Count -le $nowI) { continue }
    $vNow = $ser[$nowI]; $vThen = $ser[[math]::Min($thenI, $ser.Count - 1)]
    if (-not $vNow -or -not $vThen -or [double]$vNow -le 0 -or [double]$vThen -le 0) { continue }
    $pct = ([double]$vThen - [double]$vNow) / [double]$vThen
    if ($pct -gt 0.60) { continue }
    if ($pct -gt $bestPct) { $bestPct = $pct; $best = [pscustomobject]@{ label = [string]$it.l; unit = [string]$it.u; now = [double]$vNow; then = [double]$vThen; pct = $pct; store = $sp.Name } }
  }
  if ($null -eq $best -or $bestPct -le 0.10) { continue }
  $drops.Add($best)
}
$top = @($drops | Sort-Object pct -Descending | Select-Object -First 5)
if ($top.Count -lt 3) { Write-Output "share-image: only $($top.Count) drops this week - keeping the previous image"; exit 0 }

function FmtPU([double]$v, [string]$u) {
  $cent = [string][char]0x00A2
  if ($v -lt 1) { return ('{0}{1}/{2}' -f [math]::Round($v * 100), $cent, $u) }
  return ('${0:N2}/{1}' -f $v, $u)
}

$W = 1200; $H = 630
$bmp = New-Object System.Drawing.Bitmap($W, $H)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'ClearTypeGridFit'

$ink  = [System.Drawing.Color]::FromArgb(255, 16, 33, 62)      # brand navy
$gold = [System.Drawing.Color]::FromArgb(255, 201, 162, 39)    # brand gold
$grn  = [System.Drawing.Color]::FromArgb(255, 27, 118, 61)     # savings green
$wht  = [System.Drawing.Color]::White
$mut  = [System.Drawing.Color]::FromArgb(255, 176, 190, 210)

$g.Clear($ink)
$bGold = New-Object System.Drawing.SolidBrush($gold)
$bWht  = New-Object System.Drawing.SolidBrush($wht)
$bMut  = New-Object System.Drawing.SolidBrush($mut)
$bGrn  = New-Object System.Drawing.SolidBrush($grn)

$fH1 = New-Object System.Drawing.Font('Segoe UI', 44, [System.Drawing.FontStyle]::Bold)
$fH2 = New-Object System.Drawing.Font('Segoe UI', 20, [System.Drawing.FontStyle]::Regular)
$fIt = New-Object System.Drawing.Font('Segoe UI', 26, [System.Drawing.FontStyle]::Bold)
$fPr = New-Object System.Drawing.Font('Segoe UI', 26, [System.Drawing.FontStyle]::Bold)
$fSm = New-Object System.Drawing.Font('Segoe UI', 17, [System.Drawing.FontStyle]::Regular)
$fFt = New-Object System.Drawing.Font('Segoe UI', 21, [System.Drawing.FontStyle]::Bold)

$g.DrawString('OMAHA GROCERY PRICE DROPS', $fH1, $bGold, 56, 38)
$wk = (Get-Date -Format 'MMMM d, yyyy')
$g.DrawString(('Biggest drops in the cheapest tracked price  |  ' + $wk + '  |  7 stores checked every morning'), $fH2, $bMut, 60, 108)

$y = 168
foreach ($d in $top) {
  $pctTxt = ('-{0}%' -f [math]::Round($d.pct * 100))
  $g.FillRectangle($bGrn, 56, $y + 6, 118, 52)
  $szP = $g.MeasureString($pctTxt, $fPr)
  $g.DrawString($pctTxt, $fPr, $bWht, 56 + (118 - $szP.Width) / 2, $y + 8)
  $nm = $d.label; if ($nm.Length -gt 34) { $nm = $nm.Substring(0, 33) + [string][char]0x2026 }
  $g.DrawString($nm, $fIt, $bWht, 198, $y + 4)
  $line2 = ('cheapest option now ' + (FmtPU $d.now $d.unit) + ' at ' + $d.store + '   (was ' + (FmtPU $d.then $d.unit) + ' last week)')
  $g.DrawString($line2, $fSm, $bMut, 200, $y + 44)
  $y += 84
}

$g.FillRectangle($bGold, 0, $H - 54, $W, 54)
$bInk = New-Object System.Drawing.SolidBrush($ink)
$g.DrawString('Full board, free:  thriftycrew.com/omaha-grocery-prices', $fFt, $bInk, 56, $H - 46)

$g.Dispose()
$bmp.Save($OutPath, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
Write-Output ("share-image: " + $top.Count + " drops -> " + $OutPath)

