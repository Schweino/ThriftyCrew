<#
  build-debt-calculator.ps1  -  Thrifty Crew "Debt Payoff Date Calculator".
  Fully parameterized by $N (debt rows). Tabs: Start Here, Calculator, Engine (hidden,
  360-month snowball/avalanche simulation with rollover).
#>
$ErrorActionPreference = "Stop"
Import-Module ImportExcel
Add-Type -AssemblyName System.Drawing
function Col($hex) { [System.Drawing.ColorTranslator]::FromHtml("#$hex") }
function ColL([int]$n){ $s=""; while($n -gt 0){ $m=($n-1)%26; $s=[char](65+$m)+$s; $n=[int](($n-$m-1)/26) }; return $s }

$NAVY="16263F"; $GOLD="E2A43C"; $GOLD_TEXT="8A6D1F"; $LIGHT="F7F9FC"; $BORDER="E2E8F0"
$INK="1A202C"; $MUTE="5A6572"
$FONT="Calibri"
$MONEY='$#,##0;($#,##0);"-"'
$PCTNUM='0.0"%"'
$DATEOUT='mmm yyyy'
$N=18; $M=360

# derived column letters
$afL=@{}; $capL=@{}; $casL=@{}; $balL=@{}
for($d=1;$d -le $N;$d++){ $afL[$d]=ColL(1+$d); $capL[$d]=ColL(1+$N+$d); $casL[$d]=ColL(1+2*$N+$d); $balL[$d]=ColL(1+3*$N+$d) }
$afFirst=ColL(2); $afLast=ColL(1+$N)
$capFirst=ColL(2+$N); $capLast=ColL(1+2*$N)
$balFirst=ColL(2+3*$N); $balLast=ColL(1+4*$N)
$AP=ColL(2+4*$N); $AQ=ColL(3+4*$N); $AR=ColL(4+4*$N); $AS=ColL(5+4*$N); $AT=ColL(6+4*$N); $AU=ColL(7+4*$N); $AV=ColL(8+4*$N); $AX=ColL(10+4*$N)
$dLast=10+$N; $msgRow=$dLast+2; $noteRow=$dLast+4

$outPath="C:\Codex\income\Simple-Money-Playbook-Debt-Payoff-Calculator.xlsx"
if(Test-Path $outPath){ Remove-Item $outPath -Force }
$pkg=New-Object OfficeOpenXml.ExcelPackage

function SetFont($rng,[int]$size=11,[bool]$bold=$false,[bool]$italic=$false,[string]$hex=$INK){ $rng.Style.Font.Name=$FONT; $rng.Style.Font.Size=$size; $rng.Style.Font.Bold=$bold; $rng.Style.Font.Italic=$italic; $rng.Style.Font.Color.SetColor((Col $hex)) }
function SetFill($rng,[string]$hex){ $rng.Style.Fill.PatternType=[OfficeOpenXml.Style.ExcelFillStyle]::Solid; $rng.Style.Fill.BackgroundColor.SetColor((Col $hex)) }
function BorderAll($rng,[string]$hex=$BORDER){ foreach($s in @($rng.Style.Border.Top,$rng.Style.Border.Bottom,$rng.Style.Border.Left,$rng.Style.Border.Right)){ $s.Style=[OfficeOpenXml.Style.ExcelBorderStyle]::Thin; $s.Color.SetColor((Col $hex)) } }
function BorderBottom($rng,[string]$hex=$BORDER){ $rng.Style.Border.Bottom.Style=[OfficeOpenXml.Style.ExcelBorderStyle]::Thin; $rng.Style.Border.Bottom.Color.SetColor((Col $hex)) }
function StyleInput($cell){ SetFont $cell 11 $true $false "FFFFFF"; SetFill $cell "2F6BB0"; BorderAll $cell "255488" }
function Center($rng){ $rng.Style.HorizontalAlignment=[OfficeOpenXml.Style.ExcelHorizontalAlignment]::Center }
function VCenter($rng){ $rng.Style.VerticalAlignment=[OfficeOpenXml.Style.ExcelVerticalAlignment]::Center }
function Band($ws,[int]$row,[string]$c1,[string]$c2,[string]$text,[int]$size,[string]$fontHex,[string]$fillHex,[int]$h=24){ $rng=$ws.Cells["$c1${row}:$c2$row"]; $rng.Merge=$true; $ws.Cells["$c1$row"].Value=$text; SetFont $rng $size $true $false $fontHex; SetFill $rng $fillHex; VCenter $rng; $rng.Style.Indent=1; $ws.Row($row).Height=$h }

# ===================== START HERE =====================
$ws=$pkg.Workbook.Worksheets.Add("Start Here")
$ws.View.ShowGridLines=$false
$ws.Column(1).Width=3; $ws.Column(2).Width=94; $ws.Column(3).Width=3
$ws.Cells["B2:B3"].Merge=$true; $ws.Cells["B2"].Value="Thrifty Crew"; SetFont $ws.Cells["B2:B3"] 20 $true $false $NAVY; VCenter $ws.Cells["B2:B3"]
$ws.Cells["B4"].Value="Debt Payoff Date Calculator"; SetFont $ws.Cells["B4"] 13 $true $false $GOLD_TEXT
$sh=@(
  @(6,"Make this yours first","h"),
  @(7,"This copy is view-only. Go to File -> Make a copy to save your own editable version, then fill in your own debts.","b"),
  @(9,"What it does","h"),
  @(10,"List every debt with its balance, interest rate, and minimum payment, then add whatever extra you can pay each month. It simulates paying them off month by month and tells you the exact date you'll be debt-free and the total interest you'll pay.","b"),
  @(12,"Avalanche vs. Snowball","h"),
  @(13,"Type either method in the blue Method cell. Avalanche attacks the highest interest rate first (usually the least interest paid). Snowball attacks the smallest balance first (fastest first win). Switch between them and watch the date and interest change.","b"),
  @(15,"How to use it","h"),
  @(16,"1. Make your own copy. 2. Fill the blue cells on the 'Calculator' tab: your debts, and your extra monthly payment. 3. Everything else, including the chart and your debt-free date, updates itself.","b"),
  @(18,"About the numbers","n"),
  @(19,"This assumes you keep paying the same total each month (as a debt is cleared, its payment rolls onto the next one). Interest is estimated monthly from the rate you enter. Educational only, not financial advice; for decisions about your own money, talk to a qualified professional.","n"),
  @(21,"More free lessons + recipes: thriftycrew.com","n")
)
foreach($i in $sh){ $r=$i[0]; $t=$i[1]; $k=$i[2]; $ws.Cells["B$r"].Value=$t; $rng=$ws.Cells["B$r"]
  if($k -eq "h"){ SetFont $rng 13 $true $false $NAVY; $ws.Row($r).Height=20 }
  elseif($k -eq "n"){ SetFont $rng 10 $false $true $MUTE; $rng.Style.WrapText=$true; $ws.Row($r).Height=34 }
  else { SetFont $rng 11 $false $false "2D3748"; $rng.Style.WrapText=$true; $ws.Row($r).Height=36 }
  $rng.Style.VerticalAlignment=[OfficeOpenXml.Style.ExcelVerticalAlignment]::Top }

# ===================== CALCULATOR =====================
$ws=$pkg.Workbook.Worksheets.Add("Calculator")
$ws.View.ShowGridLines=$false
$ws.Column(1).Width=3; $ws.Column(2).Width=24; $ws.Column(3).Width=15; $ws.Column(4).Width=11; $ws.Column(5).Width=17; $ws.Column(6).Width=13; $ws.Column(7).Width=15; $ws.Column(8).Width=3
foreach($ci in 9..17){ $ws.Column($ci).Width=9 }
$ws.Column(10).Hidden=$true  # J = hidden priority-key helper

Band $ws 1 "B" "Q" "Debt Payoff Date Calculator" 18 "FFFFFF" $NAVY 32
$rng=$ws.Cells["B2:Q2"]; $rng.Merge=$true; $ws.Cells["B2"].Value="List your debts, add whatever extra you can pay, and see the exact month you'll be free. Switch Avalanche/Snowball to compare."
SetFont $rng 10 $false $true $MUTE; $rng.Style.WrapText=$true; $ws.Row(2).Height=22

Band $ws 4 "B" "C" "The plan" 12 "FFFFFF" $GOLD 22
Band $ws 4 "E" "G" "Your payoff" 12 "FFFFFF" $NAVY 22
$ws.Cells["B5"].Value="Method"; SetFont $ws.Cells["B5"] 11 $false $false $INK
$ws.Cells["C5"].Value="Avalanche"; StyleInput $ws.Cells["C5"]; Center $ws.Cells["C5"]
$ws.Cells["B6"].Value="Extra monthly payment"; SetFont $ws.Cells["B6"] 11 $false $false $INK
$ws.Cells["C6"].Value=250; StyleInput $ws.Cells["C6"]; $ws.Cells["C6"].Style.Numberformat.Format=$MONEY
try { $v=$ws.DataValidations.AddListValidation("C5"); $v.Formula.Values.Add("Avalanche"); $v.Formula.Values.Add("Snowball"); $v.ShowErrorMessage=$false } catch {}

$res=@(@(5,"Debt-free date",('IF(SUM(C11:C'+$dLast+')=0,"-",IF(Engine!$'+$AX+'$1=0,"30+ yrs",EDATE(TODAY(),Engine!$'+$AX+'$1)))'),$DATEOUT,16,$GOLD_TEXT),
       @(6,"Time to freedom",('IF(SUM(C11:C'+$dLast+')=0,"-",IF(Engine!$'+$AX+'$1=0,">360 mo",Engine!$'+$AX+'$1&" mo"))'),"",12,$NAVY),
       @(7,"Total interest you'll pay",('SUM(Engine!$'+$AT+'$4:$'+$AT+'$363)'),$MONEY,12,$NAVY),
       @(8,"Total you'll pay",('SUM(C11:C'+$dLast+')+SUM(Engine!$'+$AT+'$4:$'+$AT+'$363)'),$MONEY,12,$NAVY))
foreach($x in $res){ $r=$x[0]; $lab=$ws.Cells["E${r}:F$r"]; $lab.Merge=$true; $ws.Cells["E$r"].Value=$x[1]; SetFont $ws.Cells["E$r"] 11 $false $false $INK; VCenter $lab
  $ws.Cells["G$r"].Formula=$x[2]; SetFont $ws.Cells["G$r"] $x[4] $true $false $x[5]; if($x[3]){ $ws.Cells["G$r"].Style.Numberformat.Format=$x[3] }; $ws.Cells["G$r"].Style.HorizontalAlignment=[OfficeOpenXml.Style.ExcelHorizontalAlignment]::Right; BorderBottom $ws.Cells["E${r}:G$r"] }

# debt table
$ws.Cells["B10"].Value="Debt"; $ws.Cells["C10"].Value="Balance"; $ws.Cells["D10"].Value="APR %"; $ws.Cells["E10"].Value="Min payment"; $ws.Cells["F10"].Value="Priority"; $ws.Cells["G10"].Value="Paid off by"
foreach($c in @("B","C","D","E","F","G")){ $cell=$ws.Cells["${c}10"]; SetFont $cell 10 $true $false "FFFFFF"; SetFill $cell $NAVY; Center $cell; VCenter $cell; $cell.Style.WrapText=$true }
$ws.Row(10).Height=26
for($d=1;$d -le $N;$d++){ $r=10+$d; $bal=$balL[$d]
  foreach($c in @("B","C","D","E")){ StyleInput $ws.Cells["$c$r"] }
  $ws.Cells["C$r"].Style.Numberformat.Format=$MONEY; $ws.Cells["D$r"].Style.Numberformat.Format=$PCTNUM; Center $ws.Cells["D$r"]; $ws.Cells["E$r"].Style.Numberformat.Format=$MONEY
  $ws.Cells["F$r"].Formula='IF(B'+$r+'="","",RANK(J'+$r+',$J$11:$J$'+$dLast+',1))'; Center $ws.Cells["F$r"]; SetFont $ws.Cells["F$r"] 11 $true $false $INK; BorderAll $ws.Cells["F$r"]
  $ws.Cells["G$r"].Formula='IF(B'+$r+'="","",IF(MINIFS(Engine!$A$4:$A$363,Engine!$'+$bal+'$4:$'+$bal+'$363,"<=0.01")=0,"30+ yrs",EDATE(TODAY(),MINIFS(Engine!$A$4:$A$363,Engine!$'+$bal+'$4:$'+$bal+'$363,"<=0.01"))))'; $ws.Cells["G$r"].Style.Numberformat.Format=$DATEOUT; Center $ws.Cells["G$r"]; BorderAll $ws.Cells["G$r"]
  $ws.Cells["J$r"].Formula='IF(B'+$r+'="",1000000000+ROW()*0.000001,IF($C$5="Snowball",C'+$r+',-D'+$r+')+ROW()*0.000001)'
  $ws.Row($r).Height=20 }
# example debts (users replace with their own) so the tool demos itself on open
$ws.Cells["B11"].Value="Credit Card"; $ws.Cells["C11"].Value=4800; $ws.Cells["D11"].Value=22.9; $ws.Cells["E11"].Value=120
$ws.Cells["B12"].Value="Car Loan";    $ws.Cells["C12"].Value=9500; $ws.Cells["D12"].Value=6.5;  $ws.Cells["E12"].Value=210
$ws.Cells["B13"].Value="Student Loan"; $ws.Cells["C13"].Value=14000; $ws.Cells["D13"].Value=5.2; $ws.Cells["E13"].Value=150

$rng=$ws.Cells["B${msgRow}:G$($msgRow+1)"]; $rng.Merge=$true
$msg='IF(SUM(C11:C'+$dLast+')=0,"Add your debts above to see your debt-free date.",IF(Engine!$'+$AX+'$1=0,"With this plan the debt is not cleared within 30 years. Increase your extra payment to see a date.","You will be debt-free in "&Engine!$'+$AX+'$1&" months, by "&TEXT(EDATE(TODAY(),Engine!$'+$AX+'$1),"mmm yyyy")&", after paying $"&TEXT(SUM(Engine!$'+$AT+'$4:$'+$AT+'$363),"#,##0")&" in interest. Switch the method above to compare."))'
$ws.Cells["B$msgRow"].Formula=$msg; SetFont $ws.Cells["B$msgRow"] 12 $true $false $NAVY; $rng.Style.WrapText=$true; VCenter $rng
$rng=$ws.Cells["B${noteRow}:G$noteRow"]; $rng.Merge=$true; $ws.Cells["B$noteRow"].Value="Priority shows the order this method pays your debts. Illustration only, not financial advice. thriftycrew.com"
SetFont $rng 9 $false $true $MUTE; $rng.Style.WrapText=$true

# ===================== ENGINE =====================
$ws=$pkg.Workbook.Worksheets.Add("Engine")
$ws.View.ShowGridLines=$false
$ws.Cells["A1"].Value="Simulation engine (do not edit)"; SetFont $ws.Cells["A1"] 10 $false $true $MUTE
$ws.Cells["${AX}1"].Formula='MINIFS($A$4:$A$363,$'+$AS+'$4:$'+$AS+'$363,"<=0.01")'; SetFont $ws.Cells["${AX}1"] 9 $true $false $NAVY
$ws.Cells["A3"].Value=0
for($d=1;$d -le $N;$d++){ $calcR=10+$d
  $ws.Cells["$($capL[$d])2"].Formula='IF(Calculator!$B$'+$calcR+'="",9999,Calculator!$F$'+$calcR+')'
  $ws.Cells["$($balL[$d])3"].Formula='Calculator!$C$'+$calcR }
$ws.Cells["${AP}3"].Formula='SUM('+$afFirst+'3:'+$afLast+'3)'; $ws.Cells["${AQ}3"].Formula='SUM('+$capFirst+'3:'+$capLast+'3)'; $ws.Cells["${AR}3"].Value=0
$ws.Cells["${AS}3"].Formula='SUM('+$balFirst+'3:'+$balLast+'3)'; $ws.Cells["${AT}3"].Value=0
$ws.Cells["${AU}3"].Formula='IF(A3<=IF($'+$AX+'$1=0,999,$'+$AX+'$1),'+$AS+'3,NA())'; $ws.Cells["${AV}3"].Formula='IF(A3<=IF($'+$AX+'$1=0,999,$'+$AX+'$1),A3,NA())'
for($r=4;$r -le (3+$M);$r++){
  $ws.Cells["A$r"].Value=($r-3)
  for($d=1;$d -le $N;$d++){ $calcR=10+$d; $pv=$balL[$d]+($r-1)
    $ws.Cells[$r,(1+$d)].Formula=$pv+'*(1+Calculator!$D$'+$calcR+'/100/12)'
    $ws.Cells[$r,(1+$N+$d)].Formula='MAX(0,'+$afL[$d]+$r+'-Calculator!$E$'+$calcR+')'
    $ws.Cells[$r,(1+2*$N+$d)].Formula='MAX(0,MIN('+$capL[$d]+$r+','+$AR+$r+'-SUMPRODUCT(($'+$capFirst+'$2:$'+$capLast+'$2<'+$capL[$d]+'$2)*($'+$capFirst+$r+':$'+$capLast+$r+'))))'
    $ws.Cells[$r,(1+3*$N+$d)].Formula=$capL[$d]+$r+'-'+$casL[$d]+$r }
  $ws.Cells["${AP}$r"].Formula='SUM('+$afFirst+$r+':'+$afLast+$r+')'
  $ws.Cells["${AQ}$r"].Formula='SUM('+$capFirst+$r+':'+$capLast+$r+')'
  $ws.Cells["${AR}$r"].Formula='MAX(0,(SUM(Calculator!$E$11:$E$'+$dLast+')+Calculator!$C$6)-'+$AP+$r+'+'+$AQ+$r+')'
  $ws.Cells["${AS}$r"].Formula='SUM('+$balFirst+$r+':'+$balLast+$r+')'
  $ws.Cells["${AT}$r"].Formula=$AP+$r+'-'+$AS+($r-1)
  $ws.Cells["${AU}$r"].Formula='IF(A'+$r+'<=IF($'+$AX+'$1=0,999,$'+$AX+'$1),'+$AS+$r+',NA())'
  $ws.Cells["${AV}$r"].Formula='IF(A'+$r+'<=IF($'+$AX+'$1=0,999,$'+$AX+'$1),A'+$r+',NA())'
}
$ws.Hidden=[OfficeOpenXml.eWorkSheetHidden]::Hidden

$pkg.Workbook.FullCalcOnLoad=$true
$pkg.SaveAs($outPath)
Write-Host "SAVED: $outPath ($N debts, $M months)" -ForegroundColor Green
Write-Host ("cols: cap=$capFirst..$capLast bal=$balFirst..$balLast helpers AP=$AP AS=$AS AT=$AT AU=$AU AV=$AV AX=$AX ; debt rows 11..$dLast") -ForegroundColor DarkGray

