<#
  polish-budget-cf.ps1  -  Applies green/red color to the budget tracker's Gap value
  via the Sheets API (xlsx CF doesn't survive conversion). Re-run after any re-upload.
#>
$ErrorActionPreference = "Stop"
. "C:\Codex\ThriftyCrew\.claude\skills\lesson\google-token.ps1"
$at = Get-GoogleAccessToken
$id = "1IUs-4JD-QFcncQL6wDA8MpYai5E0W8RI9Z0viJdN0Fw"
$H = @{ Authorization = "Bearer $at" }
$meta = Invoke-RestMethod -Uri "https://sheets.googleapis.com/v4/spreadsheets/$id`?fields=sheets(properties(sheetId,title))" -Headers $H -TimeoutSec 30
$gid = ($meta.sheets | Where-Object { $_.properties.title -eq "Monthly Budget" }).properties.sheetId

# Gap value is Monthly Budget!F8 -> rowIndex 7, colIndex 5. Green if >0, red if <0.
$del = '{"requests":[' + (( 0..3 | ForEach-Object { '{"deleteConditionalFormatRule":{"sheetId":' + $gid + ',"index":0}}' }) -join ',') + ']}'
try { Invoke-RestMethod -Uri "https://sheets.googleapis.com/v4/spreadsheets/$id`:batchUpdate" -Method Post -Headers $H -ContentType "application/json" -Body $del -TimeoutSec 30 | Out-Null } catch {}

$body = @"
{
  "requests":[
    {"addConditionalFormatRule":{"index":0,"rule":{
      "ranges":[{"sheetId":$gid,"startRowIndex":7,"endRowIndex":8,"startColumnIndex":5,"endColumnIndex":6}],
      "booleanRule":{"condition":{"type":"NUMBER_GREATER","values":[{"userEnteredValue":"0"}]},
        "format":{"textFormat":{"bold":true,"foregroundColor":{"red":0.118,"green":0.498,"blue":0.235}}}}}}},
    {"addConditionalFormatRule":{"index":1,"rule":{
      "ranges":[{"sheetId":$gid,"startRowIndex":7,"endRowIndex":8,"startColumnIndex":5,"endColumnIndex":6}],
      "booleanRule":{"condition":{"type":"NUMBER_LESS","values":[{"userEnteredValue":"0"}]},
        "format":{"textFormat":{"bold":true,"foregroundColor":{"red":0.753,"green":0.224,"blue":0.169}}}}}}}
  ]
}
"@
Invoke-RestMethod -Uri "https://sheets.googleapis.com/v4/spreadsheets/$id`:batchUpdate" -Method Post -Headers $H -ContentType "application/json" -Body $body -TimeoutSec 30 | Out-Null
Write-Host "Budget gap CF applied (green if positive, red if negative)." -ForegroundColor Green
