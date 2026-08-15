<#
  build-savings-tracker.ps1  -  Thrifty Crew "Savings Goal Tracker" (elite suite).
  Shares the budget tracker's design language. Outputs a native-Sheets-ready xlsx
  (SPARKLINE bars + Google-only funcs evaluate on convert, like FILTER did).
#>
$ErrorActionPreference = "Stop"
Import-Module ImportExcel
Add-Type -AssemblyName System.Drawing
function Col($hex) { [System.Drawing.ColorTranslator]::FromHtml("#$hex") }

$NAVY="16263F"; $GOLD="E2A43C"; $GOLD_TEXT="8A6D1F"; $LIGHT="F7F9FC"; $BORDER="E2E8F0"
$GREEN="1E7F3C"; $AMBER="B7791F"; $INK="1A202C"; $MUTE="5A6572"
$FONT="Calibri"
$MONEY='$#,##0;($#,##0);"-"'
$PCT='0%'
$DATEIN='m/d/yyyy'
$DATEOUT='mmm yyyy'

$outPath = "C:\Codex\ThriftyCrew\content\workbooks\Simple-Money-Playbook-Savings-Goal-Tracker.xlsx"
if (Test-Path $outPath) { Remove-Item $outPath -Force }
$pkg = New-Object OfficeOpenXml.ExcelPackage

function SetFont($rng,[int]$size=11,[bool]$bold=$false,[bool]$italic=$false,[string]$hex=$INK){
  $rng.Style.Font.Name=$FONT; $rng.Style.Font.Size=$size; $rng.Style.Font.Bold=$bold; $rng.Style.Font.Italic=$italic; $rng.Style.Font.Color.SetColor((Col $hex))
}
function SetFill($rng,[string]$hex){ $rng.Style.Fill.PatternType=[OfficeOpenXml.Style.ExcelFillStyle]::Solid; $rng.Style.Fill.BackgroundColor.SetColor((Col $hex)) }
function BorderAll($rng,[string]$hex=$BORDER){ foreach($s in @($rng.Style.Border.Top,$rng.Style.Border.Bottom,$rng.Style.Border.Left,$rng.Style.Border.Right)){ $s.Style=[OfficeOpenXml.Style.ExcelBorderStyle]::Thin; $s.Color.SetColor((Col $hex)) } }
function BorderBottom($rng,[string]$hex=$BORDER){ $rng.Style.Border.Bottom.Style=[OfficeOpenXml.Style.ExcelBorderStyle]::Thin; $rng.Style.Border.Bottom.Color.SetColor((Col $hex)) }
function StyleInput($cell){ SetFont $cell 11 $true $false "FFFFFF"; SetFill $cell "2F6BB0"; BorderAll $cell "255488" }
function Center($rng){ $rng.Style.HorizontalAlignment=[OfficeOpenXml.Style.ExcelHorizontalAlignment]::Center }
function VCenter($rng){ $rng.Style.VerticalAlignment=[OfficeOpenXml.Style.ExcelVerticalAlignment]::Center }
function Band($ws,[int]$row,[string]$c1,[string]$c2,[string]$text,[int]$size,[string]$fontHex,[string]$fillHex,[int]$h=24){
  $rng=$ws.Cells["$c1${row}:$c2$row"]; $rng.Merge=$true; $ws.Cells["$c1$row"].Value=$text
  SetFont $rng $size $true $false $fontHex; SetFill $rng $fillHex; VCenter $rng; $rng.Style.Indent=1; $ws.Row($row).Height=$h
}

# ===================== START HERE =====================
$ws = $pkg.Workbook.Worksheets.Add("Start Here")
$ws.View.ShowGridLines=$false
$ws.Column(1).Width=3; $ws.Column(2).Width=94; $ws.Column(3).Width=3
$ws.Cells["B2:B3"].Merge=$true; $ws.Cells["B2"].Value="Thrifty Crew"; SetFont $ws.Cells["B2:B3"] 20 $true $false $NAVY; VCenter $ws.Cells["B2:B3"]
$ws.Cells["B4"].Value="Savings Goal Tracker"; SetFont $ws.Cells["B4"] 13 $true $false $GOLD_TEXT
$sh=@(
  @(6,"Make this yours first","h"),
  @(7,"This copy is view-only. Go to File -> Make a copy to save your own editable version -- then fill in your own goals.","b"),
  @(9,"How it works","h"),
  @(10,"Name each goal, what it costs, when you want it, and how much you can set aside each month. The tracker does the rest: how much you still need, whether you're on pace, and the month you'll actually get there.","b"),
  @(12,"How to use it","h"),
  @(13,"1. Make your own copy (File -> Make a copy).","b"),
  @(14,"2. Fill in the blue cells on the 'My Goals' tab -- those are yours. Everything else calculates itself.","b"),
  @(15,"3. Update 'Saved So Far' whenever you add to a goal, and watch the bar fill.","b"),
  @(17,"One idea to keep in mind","h"),
  @(18,"A goal with a date and a monthly number is a plan. A goal without them is a wish. This turns your wishes into plans -- one line at a time.","b"),
  @(20,"This isn't financial advice -- it's a starting point for organizing your own numbers. For decisions about your own money, talk to a qualified professional.","n"),
  @(22,"More free lessons + recipes: thriftycrew.com","n")
)
foreach($i in $sh){ $r=$i[0]; $t=$i[1]; $k=$i[2]; $rng=$ws.Cells["B$r"]; $ws.Cells["B$r"].Value=$t
  if($k -eq "h"){ SetFont $rng 13 $true $false $NAVY; $ws.Row($r).Height=20 }
  elseif($k -eq "n"){ SetFont $rng 10 $false $true $MUTE; $rng.Style.WrapText=$true; $ws.Row($r).Height=30 }
  else { SetFont $rng 11 $false $false "2D3748"; $rng.Style.WrapText=$true; $ws.Row($r).Height=32 }
  $rng.Style.VerticalAlignment=[OfficeOpenXml.Style.ExcelVerticalAlignment]::Top
}

# ===================== MY GOALS =====================
$ws = $pkg.Workbook.Worksheets.Add("My Goals")
$ws.View.ShowGridLines=$false
$w=@{A=3;B=26;C=13;D=13;E=13;F=12;G=16;H=8;I=14;J=13;K=13;L=3}
foreach($k in $w.Keys){ $ws.Column(([int][char]$k-[int][char]'A')+1).Width=$w[$k] }

Band $ws 1 "B" "K" "Savings Goal Tracker" 18 "FFFFFF" $NAVY 32
$rng=$ws.Cells["B2:K2"]; $rng.Merge=$true; $ws.Cells["B2"].Value="Name each goal, what it costs, and when you want it -- this shows you the monthly number to get there, and the month you'll arrive."
SetFont $rng 10 $false $true $MUTE; $rng.Style.WrapText=$true; $ws.Row(2).Height=24

# ---- Big Picture summary ----
Band $ws 4 "B" "K" "The Big Picture" 12 "FFFFFF" $GOLD 22
# data rows are 12..21; reference them
$dFirst=12; $dLast=21
$tSaved="SUM(D${dFirst}:D${dLast})"; $tTarget="SUM(C${dFirst}:C${dLast})"; $tPlan="SUM(F${dFirst}:F${dLast})"; $tNeed="SUM(I${dFirst}:I${dLast})"
$ws.Cells["B5"].Value="Saved so far"; SetFont $ws.Cells["B5"] 11 $false $false $MUTE
$ws.Cells["B6"].Formula=$tSaved; SetFont $ws.Cells["B6"] 20 $true $false $NAVY; $ws.Cells["B6"].Style.Numberformat.Format=$MONEY
$ws.Cells["C6"].Formula='"of $"&TEXT('+$tTarget+',"#,##0")'; SetFont $ws.Cells["C6"] 12 $false $true $MUTE; VCenter $ws.Cells["C6"]
$ws.Cells["E5"].Value="You're setting aside"; SetFont $ws.Cells["E5"] 11 $false $false $MUTE
$ws.Cells["E6"].Formula='IF('+$tPlan+'=0,"-",TEXT('+$tPlan+',"$#,##0")&" /mo")'; SetFont $ws.Cells["E6"] 14 $true $false $NAVY; VCenter $ws.Cells["E6"]
$ws.Cells["G5"].Value="To stay on pace"; SetFont $ws.Cells["G5"] 11 $false $false $MUTE
$ws.Cells["G6"].Formula='IF('+$tNeed+'=0,"-",TEXT('+$tNeed+',"$#,##0")&" /mo")'; SetFont $ws.Cells["G6"] 14 $true $false $NAVY; VCenter $ws.Cells["G6"]
# big overall progress bar
$ws.Cells["I5"].Value="Overall progress"; SetFont $ws.Cells["I5"] 11 $false $false $MUTE
$rng=$ws.Cells["I6:K6"]; $rng.Merge=$true
$ws.Cells["I6"].Formula='IF('+$tTarget+'=0,"",SPARKLINE(MIN(1,'+$tSaved+'/'+$tTarget+'),{"charttype","bar";"max",1;"empty","zero";"color1","#E2A43C";"color2","#EAEEF3"}))'
$ws.Row(6).Height=26
# dynamic encouragement line
$rng=$ws.Cells["B8:K8"]; $rng.Merge=$true
$ws.Cells["B8"].Formula='IF('+$tTarget+'=0,"Add your goals below to see the whole picture.","You are "&TEXT('+$tSaved+'/'+$tTarget+',"0%")&" of the way to $"&TEXT('+$tTarget+',"#,##0")&" in goals -- keep stacking.")'
SetFont $ws.Cells["B8"] 12 $true $false $NAVY; VCenter $rng; $ws.Row(8).Height=26

# ---- Goals table ----
Band $ws 10 "B" "K" "Your Goals" 12 "FFFFFF" $NAVY 22
$hdrs=@("Goal","Target $","Saved $","Target Date","Your $/mo","Progress","%","Need $/mo","On Track?","Finish By")
for($i=0;$i -lt $hdrs.Count;$i++){ $c=[char]([int][char]'B'+$i); $cell=$ws.Cells["${c}11"]; $cell.Value=$hdrs[$i]; SetFont $cell 10 $true $false "FFFFFF"; SetFill $cell $NAVY; Center $cell; VCenter $cell; $cell.Style.WrapText=$true }
$ws.Row(11).Height=28

for($r=$dFirst;$r -le $dLast;$r++){
  foreach($c in @("B","C","D","E","F")){ StyleInput $ws.Cells["$c$r"] }
  $ws.Cells["C$r"].Style.Numberformat.Format=$MONEY
  $ws.Cells["D$r"].Style.Numberformat.Format=$MONEY
  $ws.Cells["E$r"].Style.Numberformat.Format=$DATEIN; Center $ws.Cells["E$r"]
  $ws.Cells["F$r"].Style.Numberformat.Format=$MONEY
  # G progress bar
  $ws.Cells["G$r"].Formula='IF(OR(B'+$r+'="",C'+$r+'=0),"",SPARKLINE(MIN(1,D'+$r+'/C'+$r+'),{"charttype","bar";"max",1;"empty","zero";"color1","#E2A43C";"color2","#EAEEF3"}))'
  # H percent
  $ws.Cells["H$r"].Formula='IF(OR(B'+$r+'="",C'+$r+'=0),"",MIN(1,D'+$r+'/C'+$r+'))'; $ws.Cells["H$r"].Style.Numberformat.Format=$PCT; Center $ws.Cells["H$r"]; SetFont $ws.Cells["H$r"] 11 $true $false $INK
  # I need per month
  $ws.Cells["I$r"].Formula='IF(OR(B'+$r+'="",E'+$r+'="",C'+$r+'=0),"",IF(D'+$r+'>=C'+$r+',0,MAX(0,(C'+$r+'-D'+$r+')/MAX(1,(YEAR(E'+$r+')-YEAR(TODAY()))*12+(MONTH(E'+$r+')-MONTH(TODAY()))))))'
  $ws.Cells["I$r"].Style.Numberformat.Format=$MONEY
  # J status
  $ws.Cells["J$r"].Formula='IF(B'+$r+'="","",IF(D'+$r+'>=C'+$r+',"Reached",IF(E'+$r+'="","Add a date",IF(F'+$r+'<=0,"Add $/mo",IF(F'+$r+'>=I'+$r+',"On track","Behind")))))'
  SetFont $ws.Cells["J$r"] 11 $true $false $INK; Center $ws.Cells["J$r"]
  # K finish by
  $ws.Cells["K$r"].Formula='IF(B'+$r+'="","",IF(D'+$r+'>=C'+$r+',"Reached",IF(F'+$r+'<=0,"-",EDATE(TODAY(),CEILING((C'+$r+'-D'+$r+')/F'+$r+')))))'
  $ws.Cells["K$r"].Style.Numberformat.Format=$DATEOUT; Center $ws.Cells["K$r"]
  foreach($c in @("G","H","I","J","K")){ BorderAll $ws.Cells["$c$r"] }
  $ws.Row($r).Height=20
}

# status colors via CF (green on-track/reached, amber behind)
try {
  $rngJ=[OfficeOpenXml.ExcelAddress]::new("J$dFirst:J$dLast")
  $g=$ws.ConditionalFormatting.AddExpression($rngJ); $g.Formula='OR(ISNUMBER(SEARCH("track",$J'+$dFirst+')),ISNUMBER(SEARCH("Reached",$J'+$dFirst+')))'; $g.Style.Font.Color.Color=(Col $GREEN); $g.Style.Font.Bold=$true
  $a=$ws.ConditionalFormatting.AddExpression($rngJ); $a.Formula='ISNUMBER(SEARCH("Behind",$J'+$dFirst+'))'; $a.Style.Font.Color.Color=(Col $AMBER); $a.Style.Font.Bold=$true
  Write-Host "Status CF applied" -ForegroundColor DarkGray
} catch { Write-Host "Status CF skipped: $($_.Exception.Message)" -ForegroundColor Yellow }

# tip / disclaimer
$rng=$ws.Cells["B23:K23"]; $rng.Merge=$true
$ws.Cells["B23"].Value="Tip: give every goal a real target date -- that's what turns 'someday' into a monthly number. 'Need $/mo' is what it takes to hit the date; 'Your $/mo' is what you've planned."
SetFont $rng 10 $false $true $MUTE; $rng.Style.WrapText=$true; $ws.Row(23).Height=28
$rng=$ws.Cells["B25:K25"]; $rng.Merge=$true
$ws.Cells["B25"].Value="Not financial advice -- a tool for organizing your own numbers. thriftycrew.com"
SetFont $rng 9 $false $true $MUTE; $rng.Style.WrapText=$true; $ws.Row(25).Height=18

$ws.View.FreezePanes(12,2)

$pkg.Workbook.FullCalcOnLoad=$true
$pkg.SaveAs($outPath)
Write-Host "SAVED: $outPath" -ForegroundColor Green
$pkg2=Open-ExcelPackage -Path $outPath
foreach($s in $pkg2.Workbook.Worksheets){ $d=$s.Dimension; if(-not $d){continue}; Write-Host "--- $($s.Name) (rows $($d.End.Row)) ---" -ForegroundColor Cyan
  for($rr=$d.Start.Row;$rr -le $d.End.Row;$rr++){ for($cc=$d.Start.Column;$cc -le $d.End.Column;$cc++){ $f=$s.Cells[$rr,$cc].Formula; if($f){ Write-Host ("{0}!{1}{2} = {3}" -f $s.Name,[char](64+$cc),$rr,$f) } } } }
Close-ExcelPackage $pkg2 -NoSave

