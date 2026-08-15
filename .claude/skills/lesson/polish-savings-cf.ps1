<#
  polish-savings-cf.ps1  -  Applies status color-coding to the Savings Tracker via the
  Sheets API (xlsx CF doesn't survive conversion). Re-run after any full re-upload.
  Green = On track / Reached ; Amber = Behind. Range: 'My Goals'!J12:J21.
#>
$ErrorActionPreference = "Stop"
. "C:\Codex\ThriftyCrew\.claude\skills\lesson\google-token.ps1"
$at = Get-GoogleAccessToken
$id = "16Hq0OurkTlDD9mJxw_hSwR1zVAMPv4JylQLjFdiX18c"
# gid changes every time the sheet is re-uploaded in place -- always resolve by tab name
$meta = Invoke-RestMethod -Uri "https://sheets.googleapis.com/v4/spreadsheets/$id`?fields=sheets(properties(sheetId,title))" -Headers @{Authorization="Bearer $at"} -TimeoutSec 30
$gid = ($meta.sheets | Where-Object { $_.properties.title -eq "My Goals" }).properties.sheetId

# clear existing CF on the column first (idempotent-ish: delete up to 6 rules at index 0), ignore errors
$del = '{"requests":[' + (( 0..5 | ForEach-Object { '{"deleteConditionalFormatRule":{"sheetId":' + $gid + ',"index":0}}' }) -join ',') + ']}'
try { Invoke-RestMethod -Uri "https://sheets.googleapis.com/v4/spreadsheets/$id`:batchUpdate" -Method Post -Headers @{Authorization="Bearer $at"} -ContentType "application/json" -Body $del -TimeoutSec 30 | Out-Null } catch {}

$body = @"
{
  "requests":[
    {"addConditionalFormatRule":{"index":0,"rule":{
      "ranges":[{"sheetId":$gid,"startRowIndex":11,"endRowIndex":21,"startColumnIndex":9,"endColumnIndex":10}],
      "booleanRule":{"condition":{"type":"TEXT_CONTAINS","values":[{"userEnteredValue":"On track"}]},
        "format":{"textFormat":{"bold":true,"foregroundColor":{"red":0.118,"green":0.498,"blue":0.235}}}}}}},
    {"addConditionalFormatRule":{"index":1,"rule":{
      "ranges":[{"sheetId":$gid,"startRowIndex":11,"endRowIndex":21,"startColumnIndex":9,"endColumnIndex":10}],
      "booleanRule":{"condition":{"type":"TEXT_CONTAINS","values":[{"userEnteredValue":"Reached"}]},
        "format":{"textFormat":{"bold":true,"foregroundColor":{"red":0.118,"green":0.498,"blue":0.235}}}}}}},
    {"addConditionalFormatRule":{"index":2,"rule":{
      "ranges":[{"sheetId":$gid,"startRowIndex":11,"endRowIndex":21,"startColumnIndex":9,"endColumnIndex":10}],
      "booleanRule":{"condition":{"type":"TEXT_CONTAINS","values":[{"userEnteredValue":"Behind"}]},
        "format":{"textFormat":{"bold":true,"foregroundColor":{"red":0.718,"green":0.475,"blue":0.122}}}}}}}
  ]
}
"@
$r = Invoke-RestMethod -Uri "https://sheets.googleapis.com/v4/spreadsheets/$id`:batchUpdate" -Method Post -Headers @{Authorization="Bearer $at"} -ContentType "application/json" -Body $body -TimeoutSec 30
Write-Host "Conditional formatting applied (green=On track/Reached, amber=Behind)." -ForegroundColor Green
