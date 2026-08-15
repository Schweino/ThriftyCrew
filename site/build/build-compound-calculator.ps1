<#
  build-compound-calculator.ps1  -  Thrifty Crew "Compound Interest Calculator".
  3 tabs: Start Here, Calculator (inputs + results + 2 insight lines; chart added via API),
  Growth Data (year-by-year table feeding the chart). Same design system as the suite.
#>
$ErrorActionPreference = "Stop"
Import-Module ImportExcel
Add-Type -AssemblyName System.Drawing
function Col($hex) { [System.Drawing.ColorTranslator]::FromHtml("#$hex") }

$NAVY="16263F"; $GOLD="E2A43C"; $GOLD_TEXT="8A6D1F"; $LIGHT="F7F9FC"; $BORDER="E2E8F0"
$INK="1A202C"; $MUTE="5A6572"
$FONT="Calibri"
$MONEY='$#,##0;($#,##0);"-"'
$NUM='0'
$PCTNUM='0.0"%"'

$outPath = "C:\Codex\ThriftyCrew\content\workbooks\Simple-Money-Playbook-Compound-Calculator.xlsx"
if (Test-Path $outPath) { Remove-Item $outPath -Force }
$pkg = New-Object OfficeOpenXml.ExcelPackage

function SetFont($rng,[int]$size=11,[bool]$bold=$false,[bool]$italic=$false,[string]$hex=$INK){ $rng.Style.Font.Name=$FONT; $rng.Style.Font.Size=$size; $rng.Style.Font.Bold=$bold; $rng.Style.Font.Italic=$italic; $rng.Style.Font.Color.SetColor((Col $hex)) }
function SetFill($rng,[string]$hex){ $rng.Style.Fill.PatternType=[OfficeOpenXml.Style.ExcelFillStyle]::Solid; $rng.Style.Fill.BackgroundColor.SetColor((Col $hex)) }
function BorderAll($rng,[string]$hex=$BORDER){ foreach($s in @($rng.Style.Border.Top,$rng.Style.Border.Bottom,$rng.Style.Border.Left,$rng.Style.Border.Right)){ $s.Style=[OfficeOpenXml.Style.ExcelBorderStyle]::Thin; $s.Color.SetColor((Col $hex)) } }
function BorderBottom($rng,[string]$hex=$BORDER){ $rng.Style.Border.Bottom.Style=[OfficeOpenXml.Style.ExcelBorderStyle]::Thin; $rng.Style.Border.Bottom.Color.SetColor((Col $hex)) }
function StyleInput($cell){ SetFont $cell 12 $true $false "FFFFFF"; SetFill $cell "2F6BB0"; BorderAll $cell "255488"; $cell.Style.HorizontalAlignment=[OfficeOpenXml.Style.ExcelHorizontalAlignment]::Center }
function Center($rng){ $rng.Style.HorizontalAlignment=[OfficeOpenXml.Style.ExcelHorizontalAlignment]::Center }
function VCenter($rng){ $rng.Style.VerticalAlignment=[OfficeOpenXml.Style.ExcelVerticalAlignment]::Center }
function Band($ws,[int]$row,[string]$c1,[string]$c2,[string]$text,[int]$size,[string]$fontHex,[string]$fillHex,[int]$h=24){ $rng=$ws.Cells["$c1${row}:$c2$row"]; $rng.Merge=$true; $ws.Cells["$c1$row"].Value=$text; SetFont $rng $size $true $false $fontHex; SetFill $rng $fillHex; VCenter $rng; $rng.Style.Indent=1; $ws.Row($row).Height=$h }

# ===================== START HERE =====================
$ws = $pkg.Workbook.Worksheets.Add("Start Here")
$ws.View.ShowGridLines=$false
$ws.Column(1).Width=3; $ws.Column(2).Width=94; $ws.Column(3).Width=3
$ws.Cells["B2:B3"].Merge=$true; $ws.Cells["B2"].Value="Thrifty Crew"; SetFont $ws.Cells["B2:B3"] 20 $true $false $NAVY; VCenter $ws.Cells["B2:B3"]
$ws.Cells["B4"].Value="Compound Interest Calculator"; SetFont $ws.Cells["B4"] 13 $true $false $GOLD_TEXT
$sh=@(
  @(6,"Make this yours first","h"),
  @(7,"This copy is view-only. Go to File -> Make a copy to save your own editable version, then change the blue cells to your own numbers.","b"),
  @(9,"What it shows","h"),
  @(10,"Put in a starting amount, a monthly contribution, a return rate, and a number of years. It shows what that could grow to, how much of it is money you added vs. growth on top, and the price of waiting five years to start.","b"),
  @(12,"How to use it","h"),
  @(13,"1. Make your own copy (File -> Make a copy).","b"),
  @(14,"2. On the 'Calculator' tab, change the four blue cells. Everything else, including the chart, updates itself.","b"),
  @(16,"The one idea","h"),
  @(17,"Time is the ingredient you cannot buy back. The chart makes it obvious: the earlier you start, the more the growth does the heavy lifting instead of you.","b"),
  @(19,"About the numbers","n"),
  @(20,"Returns are not guaranteed and real markets go up and down; this uses a single steady rate to illustrate the math of compounding. This is educational, not financial advice. For decisions about your own money, talk to a qualified professional.","n"),
  @(22,"More free lessons + recipes: thriftycrew.com","n")
)
foreach($i in $sh){ $r=$i[0]; $t=$i[1]; $k=$i[2]; $ws.Cells["B$r"].Value=$t; $rng=$ws.Cells["B$r"]
  if($k -eq "h"){ SetFont $rng 13 $true $false $NAVY; $ws.Row($r).Height=20 }
  elseif($k -eq "n"){ SetFont $rng 10 $false $true $MUTE; $rng.Style.WrapText=$true; $ws.Row($r).Height=32 }
  else { SetFont $rng 11 $false $false "2D3748"; $rng.Style.WrapText=$true; $ws.Row($r).Height=34 }
  $rng.Style.VerticalAlignment=[OfficeOpenXml.Style.ExcelVerticalAlignment]::Top }

# ===================== CALCULATOR =====================
$ws = $pkg.Workbook.Worksheets.Add("Calculator")
$ws.View.ShowGridLines=$false
$ws.Column(1).Width=3; $ws.Column(2).Width=26; $ws.Column(3).Width=15; $ws.Column(4).Width=3
$ws.Column(5).Width=26; $ws.Column(6).Width=16; $ws.Column(7).Width=3
foreach($ci in 8..15){ $ws.Column($ci).Width=9 }

Band $ws 1 "B" "O" "Compound Interest Calculator" 18 "FFFFFF" $NAVY 32
$rng=$ws.Cells["B2:O2"]; $rng.Merge=$true; $ws.Cells["B2"].Value="See what steady saving can become when growth compounds on top of growth, and what it costs to wait."
SetFont $rng 10 $false $true $MUTE; $rng.Style.WrapText=$true; $ws.Row(2).Height=22

# inputs
Band $ws 4 "B" "C" "What you'll put in" 12 "FFFFFF" $GOLD 22
$inp=@(@(5,"Starting amount",1000,$MONEY),@(6,"Monthly contribution",250,$MONEY),@(7,"Annual return %",7,$PCTNUM),@(8,"Years to grow",30,$NUM))
foreach($x in $inp){ $r=$x[0]; $ws.Cells["B$r"].Value=$x[1]; SetFont $ws.Cells["B$r"] 11 $false $false $INK; $ws.Cells["C$r"].Value=$x[2]; StyleInput $ws.Cells["C$r"]; $ws.Cells["C$r"].Style.Numberformat.Format=$x[3]; $ws.Row($r).Height=20 }

# results
Band $ws 4 "E" "F" "What it becomes" 12 "FFFFFF" $GOLD 22
$ws.Cells["E5"].Value="Future value"; SetFont $ws.Cells["E5"] 12 $true $false $NAVY
$ws.Cells["F5"].Formula="FV(C7/100/12,C8*12,-C6,-C5)"; SetFont $ws.Cells["F5"] 16 $true $false $GOLD_TEXT; $ws.Cells["F5"].Style.Numberformat.Format=$MONEY
$ws.Cells["E6"].Value="Total you put in"; SetFont $ws.Cells["E6"] 11 $false $false $INK
$ws.Cells["F6"].Formula="C5+C6*12*C8"; SetFont $ws.Cells["F6"] 11 $true $false $INK; $ws.Cells["F6"].Style.Numberformat.Format=$MONEY
$ws.Cells["E7"].Value="Growth on top"; SetFont $ws.Cells["E7"] 11 $false $false $INK
$ws.Cells["F7"].Formula="F5-F6"; SetFont $ws.Cells["F7"] 11 $true $false $GOLD_TEXT; $ws.Cells["F7"].Style.Numberformat.Format=$MONEY
BorderBottom $ws.Cells["E5:F5"]; BorderBottom $ws.Cells["E6:F6"]; BorderBottom $ws.Cells["E7:F7"]

# insight lines
$rng=$ws.Cells["B10:F11"]; $rng.Merge=$true
$ins1='IF(C8<=0,"Enter your numbers above to see the projection.","In "&C8&" years, putting in $"&TEXT(C6,"#,##0")&"/mo at "&C7&"% could grow to $"&TEXT(F5,"#,##0")&". Of that, $"&TEXT(F7,"#,##0")&" is growth you did not put in.")'
$ws.Cells["B10"].Formula=$ins1; SetFont $ws.Cells["B10"] 12 $true $false $NAVY; $rng.Style.WrapText=$true; VCenter $rng
$rng=$ws.Cells["B12:F13"]; $rng.Merge=$true
$ins2='IF(C8>5,"Wait 5 years to start and you would reach only $"&TEXT(FV(C7/100/12,(C8-5)*12,-C6,-C5),"#,##0")&". That 5-year delay costs about $"&TEXT(F5-FV(C7/100/12,(C8-5)*12,-C6,-C5),"#,##0")&".","Starting early is the whole game. Even a few years makes a real difference.")'
$ws.Cells["B12"].Formula=$ins2; SetFont $ws.Cells["B12"] 11 $false $true $GOLD_TEXT; $rng.Style.WrapText=$true; VCenter $rng

$rng=$ws.Cells["B15:F15"]; $rng.Merge=$true
$ws.Cells["B15"].Value="The chart to the right stacks what you put in (navy) and the growth on top (gold). Watch the gold overtake the navy the longer you stay in."
SetFont $rng 10 $false $true $MUTE; $rng.Style.WrapText=$true; $ws.Row(15).Height=40; VCenter $rng
$rng=$ws.Cells["B17:F17"]; $rng.Merge=$true
$ws.Cells["B17"].Value="Illustration only, not financial advice. Returns are not guaranteed. thriftycrew.com"
SetFont $rng 9 $false $true $MUTE; $rng.Style.WrapText=$true

# ===================== GROWTH DATA =====================
$ws = $pkg.Workbook.Worksheets.Add("Growth Data")
$ws.View.ShowGridLines=$false
$ws.Column(1).Width=3; $ws.Column(2).Width=10; $ws.Column(3).Width=16; $ws.Column(4).Width=16; $ws.Column(5).Width=16
Band $ws 1 "B" "E" "Growth Data (the numbers behind the chart)" 12 "FFFFFF" $NAVY 22
$hd=@("Year","Contributed","Growth","Balance")
for($i=0;$i -lt 4;$i++){ $c=[char]([int][char]'B'+$i); $cell=$ws.Cells["${c}3"]; $cell.Value=$hd[$i]; SetFont $cell 11 $true $false "FFFFFF"; SetFill $cell $NAVY; Center $cell }
$ws.Row(3).Height=22
$gFirst=4; $gLast=44
for($r=$gFirst;$r -le $gLast;$r++){
  $y=$r-$gFirst
  $ws.Cells["B$r"].Formula='IF('+$y+'<=Calculator!$C$8,'+$y+',NA())'; Center $ws.Cells["B$r"]
  $ws.Cells["C$r"].Formula='IF(ISNA(B'+$r+'),NA(),Calculator!$C$5+Calculator!$C$6*12*B'+$r+')'; $ws.Cells["C$r"].Style.Numberformat.Format=$MONEY
  $ws.Cells["E$r"].Formula='IF(ISNA(B'+$r+'),NA(),FV(Calculator!$C$7/100/12,B'+$r+'*12,-Calculator!$C$6,-Calculator!$C$5))'; $ws.Cells["E$r"].Style.Numberformat.Format=$MONEY
  $ws.Cells["D$r"].Formula='IF(ISNA(B'+$r+'),NA(),E'+$r+'-C'+$r+')'; $ws.Cells["D$r"].Style.Numberformat.Format=$MONEY
}
$ws.View.FreezePanes(4,2)

$pkg.Workbook.FullCalcOnLoad=$true
$pkg.SaveAs($outPath)
Write-Host "SAVED: $outPath" -ForegroundColor Green
$pkg2=Open-ExcelPackage -Path $outPath
foreach($s in $pkg2.Workbook.Worksheets){ $d=$s.Dimension; if(-not $d){continue}
  if($s.Name -eq "Growth Data"){ Write-Host "--- Growth Data sample ---" -ForegroundColor Cyan; foreach($rr in @(4,5,14,44)){ Write-Host ("  B{0}={1} | C{0}={2} | D{0}={3} | E{0}={4}" -f $rr,$s.Cells[$rr,2].Formula,$s.Cells[$rr,3].Formula,$s.Cells[$rr,4].Formula,$s.Cells[$rr,5].Formula) } ; continue }
  Write-Host "--- $($s.Name) ---" -ForegroundColor Cyan
  for($rr=$d.Start.Row;$rr -le $d.End.Row;$rr++){ for($cc=$d.Start.Column;$cc -le $d.End.Column;$cc++){ $f=$s.Cells[$rr,$cc].Formula; if($f){ Write-Host ("{0}!{1}{2} = {3}" -f $s.Name,[char](64+$cc),$rr,$f) } } } }
Close-ExcelPackage $pkg2 -NoSave

