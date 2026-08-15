$ErrorActionPreference = "Stop"
Import-Module ImportExcel

Add-Type -AssemblyName System.Drawing
function Col($hex) { [System.Drawing.ColorTranslator]::FromHtml("#$hex") }

$NAVY = "16263F"; $GOLD = "E2A43C"; $GOLD_TEXT = "8A6D1F"; $LIGHT = "F7F9FC"; $BORDER = "E2E8F0"
$GREEN = "1E7F3C"; $RED = "C0392B"
$FONT = "Calibri"
$MONEY_FMT = '$#,##0;($#,##0);"-"'
$PCT_FMT = '0.0%;(0.0%);"-"'
$NUM1_FMT = '0.0;-0.0;"-"'
$PCTNUM_FMT = '0.0"%";-0.0"%";"-"'

$outPath = "C:\Codex\ThriftyCrew\content\workbooks\Simple-Money-Playbook-Budget-Tracker.xlsx"
if (Test-Path $outPath) { Remove-Item $outPath -Force }
$pkg = New-Object OfficeOpenXml.ExcelPackage

function Set-Font($rng, [int]$size=11, [bool]$bold=$false, [bool]$italic=$false, [string]$hex="1A202C") {
  $rng.Style.Font.Name = $FONT
  $rng.Style.Font.Size = $size
  $rng.Style.Font.Bold = $bold
  $rng.Style.Font.Italic = $italic
  $rng.Style.Font.Color.SetColor((Col $hex))
}
function Set-Fill($rng, [string]$hex) {
  $rng.Style.Fill.PatternType = [OfficeOpenXml.Style.ExcelFillStyle]::Solid
  $rng.Style.Fill.BackgroundColor.SetColor((Col $hex))
}
function Set-BorderAll($rng, [string]$hex=$BORDER) {
  foreach ($side in @($rng.Style.Border.Top, $rng.Style.Border.Bottom, $rng.Style.Border.Left, $rng.Style.Border.Right)) {
    $side.Style = [OfficeOpenXml.Style.ExcelBorderStyle]::Thin
    $side.Color.SetColor((Col $hex))
  }
}
function Set-BorderBottom($rng, [string]$hex=$BORDER) {
  $rng.Style.Border.Bottom.Style = [OfficeOpenXml.Style.ExcelBorderStyle]::Thin
  $rng.Style.Border.Bottom.Color.SetColor((Col $hex))
}
function Style-Input($cell) {
  Set-Font $cell 11 $true $false "FFFFFF"
  Set-Fill $cell "2F6BB0"
  Set-BorderAll $cell "255488"
}
function Band($ws, [int]$row, [string]$col1, [string]$col2, [string]$text, [int]$size, [bool]$bold, [string]$fontHex, [string]$fillHex, [int]$height=26) {
  $rng = $ws.Cells["$col1${row}:$col2$row"]
  $rng.Merge = $true
  $ws.Cells["$col1$row"].Value = $text
  Set-Font $rng $size $bold $false $fontHex
  Set-Fill $rng $fillHex
  $rng.Style.VerticalAlignment = [OfficeOpenXml.Style.ExcelVerticalAlignment]::Center
  $rng.Style.Indent = 1
  $ws.Row($row).Height = $height
}

# ============================================================= READ ME
$ws = $pkg.Workbook.Worksheets.Add("Read Me")
$ws.View.ShowGridLines = $false
$widths = @{A=3;B=30;C=18;D=18;E=18;F=18;G=3}
foreach ($k in $widths.Keys) { $ws.Column(([int][char]$k - [int][char]'A') + 1).Width = $widths[$k] }

$ws.Cells["B2:F3"].Merge = $true
$ws.Cells["B2"].Value = "Thrifty Crew"
Set-Font $ws.Cells["B2:F3"] 20 $true $false $NAVY
$ws.Cells["B2:F3"].Style.VerticalAlignment = [OfficeOpenXml.Style.ExcelVerticalAlignment]::Center

$ws.Cells["B4:F4"].Merge = $true
$ws.Cells["B4"].Value = "Budget Tracker"
Set-Font $ws.Cells["B4:F4"] 13 $true $false $GOLD_TEXT

$lines = @(
  @(6, "Make this yours first", "h2"),
  @(7, "This copy is view-only. Go to File -> Make a copy to save your own editable version -- then fill in your own numbers.", "body"),
  @(9, "What's inside", "h2"),
  @(10, "Monthly Budget -- see where the money actually goes, split into Needs and Wants, and how big your 'gap' is (income minus expenses -- the number that actually matters).", "body"),
  @(12, "Paycheck Planner -- list every bill once with its due day, and it automatically sorts each one into whichever paycheck should cover it.", "body"),
  @(14, "Debt Payoff Tracker -- list what you owe in one place, see the total, and get a suggested order to attack it (highest interest rate first).", "body"),
  @(16, "How to use it", "h2"),
  @(17, "1. Make your own copy (File -> Make a copy).", "body"),
  @(18, "2. Fill in the blue cells -- those are yours to edit. Everything else calculates itself.", "body"),
  @(19, "3. Revisit it once a month. That's it -- the goal is awareness, not perfection.", "body"),
  @(21, "One idea to keep in mind", "h2"),
  @(22, "The goal isn't a perfect budget. It's seeing the gap between what comes in and what goes out, and making that gap a little bigger every month -- on purpose.", "body"),
  @(24, "This isn't financial advice -- it's a starting point for organizing your own numbers. For decisions about your own money, talk to a qualified professional.", "note"),
  @(26, "More free lessons + recipes: thriftycrew.com", "note")
)
foreach ($item in $lines) {
  $row = $item[0]; $text = $item[1]; $kind = $item[2]
  $rng = $ws.Cells["B${row}:F$row"]
  $rng.Merge = $true
  $ws.Cells["B$row"].Value = $text
  if ($kind -eq "h2") { Set-Font $rng 13 $true $false $NAVY; $ws.Row($row).Height = 20 }
  elseif ($kind -eq "note") { Set-Font $rng 10 $false $true "5A6572"; $rng.Style.WrapText = $true; $ws.Row($row).Height = 30 }
  else { Set-Font $rng 11 $false $false "2D3748"; $rng.Style.WrapText = $true; $ws.Row($row).Height = 34 }
  $rng.Style.VerticalAlignment = [OfficeOpenXml.Style.ExcelVerticalAlignment]::Top
}

# ============================================================= MONTHLY BUDGET
$ws = $pkg.Workbook.Worksheets.Add("Monthly Budget")
$ws.View.ShowGridLines = $false
$ws.Column(1).Width = 3; $ws.Column(2).Width = 30; $ws.Column(3).Width = 18
$ws.Column(4).Width = 4; $ws.Column(5).Width = 30; $ws.Column(6).Width = 18; $ws.Column(7).Width = 3

Band $ws 1 "B" "F" "Monthly Budget" 18 $true "FFFFFF" $NAVY 32
$ws.Cells["B2"].Value = "Month:"
Set-Font $ws.Cells["B2"] 11 $true $false "1A202C"
Style-Input $ws.Cells["C2"]
$ws.Cells["C2"].Style.HorizontalAlignment = [OfficeOpenXml.Style.ExcelHorizontalAlignment]::Center

# Income
Band $ws 4 "B" "C" "Income" 12 $true "FFFFFF" $GOLD 22
$incomeRows = @("Paycheck 1","Paycheck 2","Side income","Other income")
$r = 5
foreach ($label in $incomeRows) {
  $ws.Cells["B$r"].Value = $label
  Set-Font $ws.Cells["B$r"] 11 $false $false "1A202C"
  $ws.Cells["C$r"].Value = $null
  Style-Input $ws.Cells["C$r"]
  $ws.Cells["C$r"].Style.Numberformat.Format = $MONEY_FMT
  $r++
}
$incomeFirst = 5; $incomeLast = $r - 1
$ws.Cells["B$r"].Value = "Total Income"
Set-Font $ws.Cells["B$r"] 11 $true $false "1A202C"
$ws.Cells["C$r"].Formula = "SUM(C${incomeFirst}:C$incomeLast)"
Set-Font $ws.Cells["C$r"] 11 $true $false "1A202C"
$ws.Cells["C$r"].Style.Numberformat.Format = $MONEY_FMT
Set-BorderBottom $ws.Cells["C$r"]
$totalIncomeCell = "C$r"
$r += 2

# Needs
Band $ws $r "B" "C" "Needs (the must-pays)" 12 $true "FFFFFF" $NAVY 22
$r++
$needsStart = $r
$needsRows = @("Housing / rent","Utilities","Groceries","Transportation","Insurance","Debt minimum payments","Other needs")
foreach ($label in $needsRows) {
  $ws.Cells["B$r"].Value = $label
  Set-Font $ws.Cells["B$r"] 11 $false $false "1A202C"
  $ws.Cells["C$r"].Value = $null
  Style-Input $ws.Cells["C$r"]
  $ws.Cells["C$r"].Style.Numberformat.Format = $MONEY_FMT
  $r++
}
$needsFirst = $needsStart; $needsLast = $r - 1
$ws.Cells["B$r"].Value = "Total Needs"
Set-Font $ws.Cells["B$r"] 11 $true $false "1A202C"
$ws.Cells["C$r"].Formula = "SUM(C${needsFirst}:C$needsLast)"
Set-Font $ws.Cells["C$r"] 11 $true $false "1A202C"
$ws.Cells["C$r"].Style.Numberformat.Format = $MONEY_FMT
Set-BorderBottom $ws.Cells["C$r"]
$totalNeedsCell = "C$r"
$r += 2

# Wants
Band $ws $r "B" "C" "Wants (the nice-to-haves)" 12 $true "FFFFFF" $NAVY 22
$r++
$wantsStart = $r
$wantsRows = @("Dining out / takeout","Subscriptions","Entertainment","Shopping","Other wants")
foreach ($label in $wantsRows) {
  $ws.Cells["B$r"].Value = $label
  Set-Font $ws.Cells["B$r"] 11 $false $false "1A202C"
  $ws.Cells["C$r"].Value = $null
  Style-Input $ws.Cells["C$r"]
  $ws.Cells["C$r"].Style.Numberformat.Format = $MONEY_FMT
  $r++
}
$wantsFirst = $wantsStart; $wantsLast = $r - 1
$ws.Cells["B$r"].Value = "Total Wants"
Set-Font $ws.Cells["B$r"] 11 $true $false "1A202C"
$ws.Cells["C$r"].Formula = "SUM(C${wantsFirst}:C$wantsLast)"
Set-Font $ws.Cells["C$r"] 11 $true $false "1A202C"
$ws.Cells["C$r"].Style.Numberformat.Format = $MONEY_FMT
Set-BorderBottom $ws.Cells["C$r"]
$totalWantsCell = "C$r"

# Summary (right column)
$sr = 4
Band $ws $sr "E" "F" "The Bottom Line" 12 $true "FFFFFF" $GOLD 22
$sr++
$ws.Cells["E$sr"].Value = "Total Income"
Set-Font $ws.Cells["E$sr"] 11 $false $false "1A202C"
$ws.Cells["F$sr"].Formula = $totalIncomeCell
Set-Font $ws.Cells["F$sr"] 11 $true $false "1A202C"
$ws.Cells["F$sr"].Style.Numberformat.Format = $MONEY_FMT
$sr++
$ws.Cells["E$sr"].Value = "Total Expenses (Needs + Wants)"
Set-Font $ws.Cells["E$sr"] 11 $false $false "1A202C"
$ws.Cells["F$sr"].Formula = "$totalNeedsCell+$totalWantsCell"
Set-Font $ws.Cells["F$sr"] 11 $true $false "1A202C"
$ws.Cells["F$sr"].Style.Numberformat.Format = $MONEY_FMT
$totalExpensesCell = "F$sr"
$sr += 2

# The Gap (with live color + plain-English readout)
$ws.Cells["E$sr"].Value = "The Gap"
Set-Font $ws.Cells["E$sr"] 14 $true $false $NAVY
Set-Fill $ws.Cells["E$sr"] $LIGHT
$gapRow = $sr
$gapCell = "F$sr"
$ws.Cells["F$sr"].Formula = "$totalIncomeCell-$totalExpensesCell"
Set-Font $ws.Cells["F$sr"] 14 $true $false $NAVY
Set-Fill $ws.Cells["F$sr"] $LIGHT
$ws.Cells["F$sr"].Style.Numberformat.Format = $MONEY_FMT
try {
  $cfPos = $ws.ConditionalFormatting.AddGreaterThan([OfficeOpenXml.ExcelAddress]::new($gapCell))
  $cfPos.Formula = "0"; $cfPos.Style.Font.Color.Color = (Col $GREEN)
  $cfNeg = $ws.ConditionalFormatting.AddLessThan([OfficeOpenXml.ExcelAddress]::new($gapCell))
  $cfNeg.Formula = "0"; $cfNeg.Style.Font.Color.Color = (Col $RED)
  Write-Host "Gap value CF applied" -ForegroundColor DarkGray
} catch { Write-Host "Gap value CF skipped: $($_.Exception.Message)" -ForegroundColor Yellow }
$sr++
# Plain-English, reacts to the numbers
$rng = $ws.Cells["E${sr}:F$sr"]; $rng.Merge = $true
$gapAbs = '$F$' + $gapRow
$msg = 'IF(' + $totalIncomeCell + '=0,"Enter your income and expenses above to see where you stand.",IF(' + $gapCell + '>0,"You have $"&TEXT(' + $gapCell + ',"#,##0")&" left over each month. Put it to work: save or invest it.",IF(' + $gapCell + '=0,"You are breaking even. Trim one want and turn it into savings.","You are $"&TEXT(-' + $gapCell + ',"#,##0")&" over each month. Trim a want to close the gap.")))'
$ws.Cells["E$sr"].Formula = $msg
Set-Font $ws.Cells["E$sr"] 11 $true $false $NAVY
$rng.Style.WrapText = $true
$ws.Row($sr).Height = 34
try {
  $cfMsgPos = $ws.ConditionalFormatting.AddExpression([OfficeOpenXml.ExcelAddress]::new("E${sr}:F$sr"))
  $cfMsgPos.Formula = $gapAbs + '>0'; $cfMsgPos.Style.Font.Color.Color = (Col $GREEN)
  $cfMsgNeg = $ws.ConditionalFormatting.AddExpression([OfficeOpenXml.ExcelAddress]::new("E${sr}:F$sr"))
  $cfMsgNeg.Formula = $gapAbs + '<0'; $cfMsgNeg.Style.Font.Color.Color = (Col $RED)
  Write-Host "Gap message CF applied" -ForegroundColor DarkGray
} catch { Write-Host "Gap message CF skipped: $($_.Exception.Message)" -ForegroundColor Yellow }
$sr++
$rng = $ws.Cells["E${sr}:F$sr"]; $rng.Merge = $true
$ws.Cells["E$sr"].Value = "Income minus expenses -- the number that actually matters."
Set-Font $rng 10 $false $true "5A6572"
$rng.Style.WrapText = $true
$ws.Row($sr).Height = 22
$sr += 2

Band $ws $sr "E" "F" "Pay Yourself First" 12 $true "FFFFFF" $NAVY 22
$sr++
$ws.Cells["E$sr"].Value = "Target % of income to save"
Set-Font $ws.Cells["E$sr"] 11 $false $false "1A202C"
$ws.Cells["F$sr"].Value = 10
Style-Input $ws.Cells["F$sr"]
$ws.Cells["F$sr"].Style.Numberformat.Format = $PCTNUM_FMT
$ws.Cells["F$sr"].Style.HorizontalAlignment = [OfficeOpenXml.Style.ExcelHorizontalAlignment]::Center
$pyfPctCell = "F$sr"
$sr++
$ws.Cells["E$sr"].Value = "Suggested amount to move to savings"
Set-Font $ws.Cells["E$sr"] 11 $true $false "1A202C"
$ws.Cells["F$sr"].Formula = "$totalIncomeCell*$pyfPctCell/100"
Set-Font $ws.Cells["F$sr"] 11 $true $false "1A202C"
$ws.Cells["F$sr"].Style.Numberformat.Format = $MONEY_FMT
Set-BorderBottom $ws.Cells["F$sr"]
$sr += 2

Band $ws $sr "E" "F" "Needs vs. Wants Split" 12 $true "FFFFFF" $GOLD 22
$sr++
$ws.Cells["E$sr"].Value = "Needs as % of income"
Set-Font $ws.Cells["E$sr"] 11 $false $false "1A202C"
$ws.Cells["F$sr"].Formula = "IF($totalIncomeCell=0,0,$totalNeedsCell/$totalIncomeCell)"
Set-Font $ws.Cells["F$sr"] 11 $true $false "1A202C"
$ws.Cells["F$sr"].Style.Numberformat.Format = $PCT_FMT
$sr++
$ws.Cells["E$sr"].Value = "Wants as % of income"
Set-Font $ws.Cells["E$sr"] 11 $false $false "1A202C"
$ws.Cells["F$sr"].Formula = "IF($totalIncomeCell=0,0,$totalWantsCell/$totalIncomeCell)"
Set-Font $ws.Cells["F$sr"] 11 $true $false "1A202C"
$ws.Cells["F$sr"].Style.Numberformat.Format = $PCT_FMT
$sr += 2
$rng = $ws.Cells["E${sr}:F$sr"]; $rng.Merge = $true
$ws.Cells["E$sr"].Value = "A common target is roughly 50% needs / 30% wants / 20% savings -- a guide, not a rule."
Set-Font $rng 10 $false $true "5A6572"
$rng.Style.WrapText = $true
$ws.Row($sr).Height = 26

$ws.View.FreezePanes(2, 2)

# ============================================================= PAYCHECK PLANNER
$ws = $pkg.Workbook.Worksheets.Add("Paycheck Planner")
$ws.View.ShowGridLines = $false
$ws.Column(1).Width = 3; $ws.Column(2).Width = 22; $ws.Column(3).Width = 13; $ws.Column(4).Width = 11
$ws.Column(5).Width = 13; $ws.Column(6).Width = 3; $ws.Column(7).Width = 20; $ws.Column(8).Width = 13
$ws.Column(9).Width = 3; $ws.Column(10).Width = 20; $ws.Column(11).Width = 13; $ws.Column(12).Width = 3

Band $ws 1 "B" "K" "Paycheck Planner" 18 $true "FFFFFF" $NAVY 32
$rng = $ws.Cells["B2:K2"]; $rng.Merge = $true
$ws.Cells["B2"].Value = "List every bill once on the left with its due day. Set your two pay-days below -- every bill sorts itself into the paycheck that covers it."
Set-Font $rng 10 $false $true "5A6572"
$rng.Style.WrapText = $true
$ws.Row(2).Height = 26

$ws.Cells["B4"].Value = "Paycheck 1 pay-day (day of month)"
Set-Font $ws.Cells["B4"] 11 $true $false "1A202C"
$ws.Cells["C4"].Value = 1
Style-Input $ws.Cells["C4"]
$ws.Cells["C4"].Style.HorizontalAlignment = [OfficeOpenXml.Style.ExcelHorizontalAlignment]::Center
$p1Cell = "`$C`$4"

$ws.Cells["B5"].Value = "Paycheck 2 pay-day (day of month)"
Set-Font $ws.Cells["B5"] 11 $true $false "1A202C"
$ws.Cells["C5"].Value = 15
Style-Input $ws.Cells["C5"]
$ws.Cells["C5"].Style.HorizontalAlignment = [OfficeOpenXml.Style.ExcelHorizontalAlignment]::Center
$p2Cell = "`$C`$5"

$rng = $ws.Cells["B6:E6"]; $rng.Merge = $true
$ws.Cells["B6"].Value = "Bills due on/after Paycheck 1's day (and before Paycheck 2's day) go with Paycheck 1 -- everything else goes with Paycheck 2. Paid once a month? Set the two pay-days to how you split the month (for example the 1st and the 15th)."
Set-Font $rng 10 $false $true "5A6572"
$rng.Style.WrapText = $true
$ws.Row(6).Height = 44

# Master obligations list (left)
Band $ws 8 "B" "E" "All Obligations" 12 $true "FFFFFF" $GOLD 22
$obHeaders = @("Obligation","Amount","Due Day","Goes With")
for ($i = 0; $i -lt 4; $i++) {
  $col = [char]([int][char]'B' + $i)
  $cell = $ws.Cells["${col}9"]
  $cell.Value = $obHeaders[$i]
  Set-Font $cell 11 $true $false "FFFFFF"
  Set-Fill $cell $NAVY
  $cell.Style.HorizontalAlignment = [OfficeOpenXml.Style.ExcelHorizontalAlignment]::Center
  $cell.Style.WrapText = $true
}
$ws.Row(9).Height = 26

$obFirst = 10
$obN = 20
$obLast = $obFirst + $obN - 1
for ($i = 0; $i -lt $obN; $i++) {
  $row = $obFirst + $i
  $ws.Cells["B$row"].Value = $null
  Style-Input $ws.Cells["B$row"]
  foreach ($col in @("C","D")) {
    $ws.Cells["$col$row"].Value = $null
    Style-Input $ws.Cells["$col$row"]
  }
  $ws.Cells["C$row"].Style.Numberformat.Format = $MONEY_FMT
  $ws.Cells["D$row"].Style.HorizontalAlignment = [OfficeOpenXml.Style.ExcelHorizontalAlignment]::Center
  $ws.Cells["E$row"].Formula = "IF(B$row=`"`",`"`",IF(AND(D$row>=$p1Cell,D$row<$p2Cell),`"Paycheck 1`",`"Paycheck 2`"))"
  Set-Font $ws.Cells["E$row"] 11 $true $false "1A202C"
  $ws.Cells["E$row"].Style.HorizontalAlignment = [OfficeOpenXml.Style.ExcelHorizontalAlignment]::Center
  Set-BorderAll $ws.Cells["E$row"]
}
$obTotalRow = $obLast + 1
$ws.Cells["B$obTotalRow"].Value = "Total"
Set-Font $ws.Cells["B$obTotalRow"] 11 $true $false "1A202C"
Set-BorderBottom $ws.Cells["B$obTotalRow"]
$ws.Cells["C$obTotalRow"].Formula = "SUM(C${obFirst}:C$obLast)"
Set-Font $ws.Cells["C$obTotalRow"] 11 $true $false "1A202C"
$ws.Cells["C$obTotalRow"].Style.Numberformat.Format = $MONEY_FMT
Set-BorderBottom $ws.Cells["C$obTotalRow"]
Set-BorderBottom $ws.Cells["D$obTotalRow"]
Set-BorderBottom $ws.Cells["E$obTotalRow"]

$fmtSpillLast = $obFirst + $obN + 3

# Paycheck 1 block (right, columns G-H)
Band $ws 8 "G" "H" "Paycheck 1" 12 $true "FFFFFF" $NAVY 22
$ws.Cells["G9"].Value = "Income this paycheck"
Set-Font $ws.Cells["G9"] 11 $false $false "1A202C"
$ws.Cells["H9"].Value = $null
Style-Input $ws.Cells["H9"]
$ws.Cells["H9"].Style.Numberformat.Format = $MONEY_FMT
$ws.Cells["G10"].Value = "Total bills"
Set-Font $ws.Cells["G10"] 11 $false $false "1A202C"
$ws.Cells["H10"].Formula = "SUMIF(`$E`$${obFirst}:`$E`$$obLast,`"Paycheck 1`",`$C`$${obFirst}:`$C`$$obLast)"
Set-Font $ws.Cells["H10"] 11 $true $false "1A202C"
$ws.Cells["H10"].Style.Numberformat.Format = $MONEY_FMT
$ws.Cells["G11"].Value = "Left Over"
Set-Font $ws.Cells["G11"] 14 $true $false $NAVY
Set-Fill $ws.Cells["G11"] $LIGHT
$ws.Cells["H11"].Formula = "H9-H10"
Set-Font $ws.Cells["H11"] 14 $true $false $NAVY
Set-Fill $ws.Cells["H11"] $LIGHT
$ws.Cells["H11"].Style.Numberformat.Format = $MONEY_FMT
$ws.Cells["G13"].Value = "Bill"
$ws.Cells["H13"].Value = "Amount"
foreach ($c in @("G13","H13")) {
  Set-Font $ws.Cells[$c] 11 $true $false "FFFFFF"
  Set-Fill $ws.Cells[$c] $GOLD
  $ws.Cells[$c].Style.HorizontalAlignment = [OfficeOpenXml.Style.ExcelHorizontalAlignment]::Center
}
$ws.Cells["G14"].Formula = "IFERROR(FILTER(B${obFirst}:C$obLast,E${obFirst}:E$obLast=`"Paycheck 1`"),`"`")"
Set-Font $ws.Cells["G14"] 11 $false $false "1A202C"
for ($rr = 14; $rr -le $fmtSpillLast; $rr++) { $ws.Cells["H$rr"].Style.Numberformat.Format = $MONEY_FMT }

# Paycheck 2 block (right, columns J-K)
Band $ws 8 "J" "K" "Paycheck 2" 12 $true "FFFFFF" $NAVY 22
$ws.Cells["J9"].Value = "Income this paycheck"
Set-Font $ws.Cells["J9"] 11 $false $false "1A202C"
$ws.Cells["K9"].Value = $null
Style-Input $ws.Cells["K9"]
$ws.Cells["K9"].Style.Numberformat.Format = $MONEY_FMT
$ws.Cells["J10"].Value = "Total bills"
Set-Font $ws.Cells["J10"] 11 $false $false "1A202C"
$ws.Cells["K10"].Formula = "SUMIF(`$E`$${obFirst}:`$E`$$obLast,`"Paycheck 2`",`$C`$${obFirst}:`$C`$$obLast)"
Set-Font $ws.Cells["K10"] 11 $true $false "1A202C"
$ws.Cells["K10"].Style.Numberformat.Format = $MONEY_FMT
$ws.Cells["J11"].Value = "Left Over"
Set-Font $ws.Cells["J11"] 14 $true $false $NAVY
Set-Fill $ws.Cells["J11"] $LIGHT
$ws.Cells["K11"].Formula = "K9-K10"
Set-Font $ws.Cells["K11"] 14 $true $false $NAVY
Set-Fill $ws.Cells["K11"] $LIGHT
$ws.Cells["K11"].Style.Numberformat.Format = $MONEY_FMT
$ws.Cells["J13"].Value = "Bill"
$ws.Cells["K13"].Value = "Amount"
foreach ($c in @("J13","K13")) {
  Set-Font $ws.Cells[$c] 11 $true $false "FFFFFF"
  Set-Fill $ws.Cells[$c] $GOLD
  $ws.Cells[$c].Style.HorizontalAlignment = [OfficeOpenXml.Style.ExcelHorizontalAlignment]::Center
}
$ws.Cells["J14"].Formula = "IFERROR(FILTER(B${obFirst}:C$obLast,E${obFirst}:E$obLast=`"Paycheck 2`"),`"`")"
Set-Font $ws.Cells["J14"] 11 $false $false "1A202C"
for ($rr = 14; $rr -le $fmtSpillLast; $rr++) { $ws.Cells["K$rr"].Style.Numberformat.Format = $MONEY_FMT }

$noteRow2 = $obFirst + $obN + 5
$rng = $ws.Cells["B${noteRow2}:K$noteRow2"]; $rng.Merge = $true
$ws.Cells["B$noteRow2"].Value = "Change either pay-day above and every bill + both totals re-sort automatically. Built for Google Sheets (FILTER works natively there)."
Set-Font $rng 10 $false $true "5A6572"
$rng.Style.WrapText = $true
$ws.Row($noteRow2).Height = 26

$ws.View.FreezePanes(3, 2)

# ============================================================= DEBT PAYOFF TRACKER
$ws = $pkg.Workbook.Worksheets.Add("Debt Payoff Tracker")
$ws.View.ShowGridLines = $false
$ws.Column(1).Width = 3; $ws.Column(2).Width = 26; $ws.Column(3).Width = 16; $ws.Column(4).Width = 16
$ws.Column(5).Width = 16; $ws.Column(6).Width = 16; $ws.Column(7).Width = 14; $ws.Column(8).Width = 3

Band $ws 1 "B" "G" "Debt Payoff Tracker" 18 $true "FFFFFF" $NAVY 32
$rng = $ws.Cells["B2:G2"]; $rng.Merge = $true
$ws.Cells["B2"].Value = "List every debt below. 'Attack order' ranks them by interest rate -- highest first (the 'avalanche' method, usually the fastest path out)."
Set-Font $rng 10 $false $true "5A6572"
$rng.Style.WrapText = $true
$ws.Row(2).Height = 26

$headers = @("Debt Name","Balance","Min. Payment","Interest Rate (%)","Extra Payment","Attack Order")
$hdrRow = 4
for ($i = 0; $i -lt $headers.Length; $i++) {
  $col = [char]([int][char]'B' + $i)
  $cell = $ws.Cells["$col$hdrRow"]
  $cell.Value = $headers[$i]
  Set-Font $cell 12 $true $false "FFFFFF"
  Set-Fill $cell $NAVY
  $cell.Style.HorizontalAlignment = [OfficeOpenXml.Style.ExcelHorizontalAlignment]::Center
  $cell.Style.VerticalAlignment = [OfficeOpenXml.Style.ExcelVerticalAlignment]::Center
  $cell.Style.WrapText = $true
}
$ws.Row($hdrRow).Height = 30

$dataFirst = $hdrRow + 1
$nRows = 15
$dataLast = $dataFirst + $nRows - 1
for ($i = 0; $i -lt $nRows; $i++) {
  $row = $dataFirst + $i
  $ws.Cells["B$row"].Value = $null
  Style-Input $ws.Cells["B$row"]
  foreach ($col in @("C","D","E","F")) {
    $ws.Cells["$col$row"].Value = $null
    Style-Input $ws.Cells["$col$row"]
  }
  $ws.Cells["C$row"].Style.Numberformat.Format = $MONEY_FMT
  $ws.Cells["D$row"].Style.Numberformat.Format = $MONEY_FMT
  $ws.Cells["E$row"].Style.Numberformat.Format = $PCTNUM_FMT
  $ws.Cells["E$row"].Style.HorizontalAlignment = [OfficeOpenXml.Style.ExcelHorizontalAlignment]::Center
  $ws.Cells["F$row"].Style.Numberformat.Format = $MONEY_FMT
  $ws.Cells["G$row"].Formula = "IF(B$row=`"`",`"`",RANK(E$row,`$E`$$dataFirst`:`$E`$$dataLast))"
  Set-Font $ws.Cells["G$row"] 11 $true $false "1A202C"
  $ws.Cells["G$row"].Style.HorizontalAlignment = [OfficeOpenXml.Style.ExcelHorizontalAlignment]::Center
  Set-BorderAll $ws.Cells["G$row"]
}

$totalRow = $dataLast + 1
$ws.Cells["B$totalRow"].Value = "Total"
Set-Font $ws.Cells["B$totalRow"] 11 $true $false "1A202C"
Set-BorderBottom $ws.Cells["B$totalRow"]
foreach ($col in @("C","D","F")) {
  $ws.Cells["$col$totalRow"].Formula = "SUM($col${dataFirst}:$col$dataLast)"
  Set-Font $ws.Cells["$col$totalRow"] 11 $true $false "1A202C"
  $ws.Cells["$col$totalRow"].Style.Numberformat.Format = $MONEY_FMT
  Set-BorderBottom $ws.Cells["$col$totalRow"]
}
Set-BorderBottom $ws.Cells["E$totalRow"]
Set-BorderBottom $ws.Cells["G$totalRow"]

$noteRow = $totalRow + 2
$rng = $ws.Cells["B${noteRow}:G$noteRow"]; $rng.Merge = $true
$ws.Cells["B$noteRow"].Value = "Prefer quick wins instead? Ignore the Attack Order column and pay off your smallest balance first (the 'snowball' method) -- either way works if you stick with it."
Set-Font $rng 10 $false $true "5A6572"
$rng.Style.WrapText = $true
$ws.Row($noteRow).Height = 26

$ws.View.FreezePanes(5, 2)

$pkg.Workbook.FullCalcOnLoad = $true
$pkg.SaveAs($outPath)
Write-Host "SAVED: $outPath" -ForegroundColor Green

# Dump every formula's raw text for manual verification
$pkg2 = Open-ExcelPackage -Path $outPath
foreach ($sheet in $pkg2.Workbook.Worksheets) {
  $dim = $sheet.Dimension
  if ($null -eq $dim) { continue }
  Write-Host ("--- {0}  (rows {1}) ---" -f $sheet.Name, $dim.End.Row) -ForegroundColor Cyan
  for ($rr = $dim.Start.Row; $rr -le $dim.End.Row; $rr++) {
    for ($cc = $dim.Start.Column; $cc -le $dim.End.Column; $cc++) {
      $f = $sheet.Cells[$rr, $cc].Formula
      if ($f) { Write-Host ("{0}!{1}{2} = {3}" -f $sheet.Name, [char](64+$cc), $rr, $f) }
    }
  }
}
Close-ExcelPackage $pkg2 -NoSave
