$ErrorActionPreference = "Stop"
. "C:\Codex\ThriftyCrew\.claude\skills\lesson\google-token.ps1"
$at = Get-GoogleAccessToken
$id = "16Hq0OurkTlDD9mJxw_hSwR1zVAMPv4JylQLjFdiX18c"
$H = @{ Authorization = "Bearer $at" }

# gid for My Goals
$meta = Invoke-RestMethod -Uri "https://sheets.googleapis.com/v4/spreadsheets/$id`?fields=sheets(properties(sheetId,title))" -Headers $H -TimeoutSec 30
$gid = ($meta.sheets | Where-Object { $_.properties.title -eq "My Goals" }).properties.sheetId
Write-Host "My Goals gid=$gid"

# varied sample data to showcase states
$writeBody = @'
{
  "valueInputOption":"USER_ENTERED",
  "data":[
    {"range":"'My Goals'!B12:F12","values":[["Emergency Fund",5000,3500,"2026-12-31",500]]},
    {"range":"'My Goals'!B13:F13","values":[["New Car",8000,1000,"2027-06-01",200]]},
    {"range":"'My Goals'!B14:F14","values":[["Holiday Gifts",1200,1200,"2026-12-01",0]]},
    {"range":"'My Goals'!B15:F15","values":[["Vacation",3000,900,"2027-03-01",250]]}
  ]
}
'@
Invoke-RestMethod -Uri "https://sheets.googleapis.com/v4/spreadsheets/$id/values:batchUpdate" -Method Post -Headers $H -ContentType "application/json" -Body $writeBody -TimeoutSec 30 | Out-Null
Start-Sleep -Milliseconds 800

$pdf = "C:\Users\Owner\AppData\Local\Temp\claude\C--Codex\f3644374-5e4d-4c5e-a7e6-7ac3b89873f9\scratchpad\savings-snapshot.pdf"
$url = "https://docs.google.com/spreadsheets/d/$id/export?format=pdf&gid=$gid&size=letter&portrait=false&fitw=true&sheetnames=false&printtitle=false&gridlines=false&fzr=false&top_margin=0.25&bottom_margin=0.25&left_margin=0.25&right_margin=0.25"
Invoke-WebRequest -Uri $url -Headers $H -OutFile $pdf -UseBasicParsing -TimeoutSec 60
Write-Host "PDF saved: $pdf  ($((Get-Item $pdf).Length) bytes)"

# clear sample
$clearBody = @'
{
  "valueInputOption":"USER_ENTERED",
  "data":[
    {"range":"'My Goals'!B12:F15","values":[["","","","",""],["","","","",""],["","","","",""],["","","","",""]]}
  ]
}
'@
Invoke-RestMethod -Uri "https://sheets.googleapis.com/v4/spreadsheets/$id/values:batchUpdate" -Method Post -Headers $H -ContentType "application/json" -Body $clearBody -TimeoutSec 30 | Out-Null
Write-Host "Sample cleared." -ForegroundColor Green