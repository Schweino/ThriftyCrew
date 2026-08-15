<#
  update-tracker-sheet.ps1
  Replaces the content of the EXISTING budget-tracker Google Sheet (same file ID,
  so URL + sharing are untouched) with the freshly-built xlsx, re-converting to a
  native Google Sheet. Drive files.update (PATCH) multipart with the Google mimeType
  in metadata forces conversion + keeps it native.
#>
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\google-token.ps1"
$at = Get-GoogleAccessToken
$fileId = "1IUs-4JD-QFcncQL6wDA8MpYai5E0W8RI9Z0viJdN0Fw"
$xlsxPath = "C:\Codex\ThriftyCrew\Simple-Money-Playbook-Budget-Tracker.xlsx"

$boundary = [guid]::NewGuid().ToString()
$metadata = '{"mimeType":"application/vnd.google-apps.spreadsheet"}'
$fileBytes = [IO.File]::ReadAllBytes($xlsxPath)

$LF = "`r`n"
$bodyStart = (
  "--$boundary$LF" +
  "Content-Type: application/json; charset=UTF-8$LF$LF" +
  "$metadata$LF" +
  "--$boundary$LF" +
  "Content-Type: application/vnd.openxmlformats-officedocument.spreadsheetml.sheet$LF$LF"
)
$bodyEnd = "$LF--$boundary--$LF"
$bodyStartBytes = [Text.Encoding]::UTF8.GetBytes($bodyStart)
$bodyEndBytes = [Text.Encoding]::UTF8.GetBytes($bodyEnd)
$fullBody = New-Object byte[] ($bodyStartBytes.Length + $fileBytes.Length + $bodyEndBytes.Length)
[Array]::Copy($bodyStartBytes, 0, $fullBody, 0, $bodyStartBytes.Length)
[Array]::Copy($fileBytes, 0, $fullBody, $bodyStartBytes.Length, $fileBytes.Length)
[Array]::Copy($bodyEndBytes, 0, $fullBody, $bodyStartBytes.Length + $fileBytes.Length, $bodyEndBytes.Length)

$resp = Invoke-RestMethod -Uri "https://www.googleapis.com/upload/drive/v3/files/$fileId`?uploadType=multipart&fields=id,name,mimeType,modifiedTime" `
  -Method Patch `
  -Headers @{ Authorization = "Bearer $at" } `
  -ContentType "multipart/related; boundary=$boundary" `
  -Body $fullBody -TimeoutSec 60

Write-Host "UPDATED IN PLACE" -ForegroundColor Green
Write-Host ("  id={0}" -f $resp.id)
Write-Host ("  name={0}" -f $resp.name)
Write-Host ("  mimeType={0}" -f $resp.mimeType)
Write-Host ("  modifiedTime={0}" -f $resp.modifiedTime)

# Verify sharing survived
$share = Invoke-RestMethod -Uri "https://www.googleapis.com/drive/v3/files/$fileId`?fields=shared,permissions(type,role)" -Headers @{ Authorization = "Bearer $at" } -TimeoutSec 30
$anyone = $share.permissions | Where-Object { $_.type -eq 'anyone' }
Write-Host ("  sharing: shared={0}  anyone-with-link={1}" -f $share.shared, $(if($anyone){"role="+$anyone.role}else{"NONE"}))

# Try Sheets API to confirm the debt tab row count landed
try {
  $meta = Invoke-RestMethod -Uri "https://sheets.googleapis.com/v4/spreadsheets/$fileId`?fields=sheets(properties(title,gridProperties(rowCount)))" -Headers @{ Authorization = "Bearer $at" } -TimeoutSec 30
  Write-Host "  Sheets API tabs:" -ForegroundColor Cyan
  $meta.sheets | ForEach-Object { Write-Host ("    - {0} ({1} rows)" -f $_.properties.title, $_.properties.gridProperties.rowCount) }
} catch {
  Write-Host "  (Sheets API still unavailable on this project; Drive update succeeded regardless)" -ForegroundColor DarkGray
}
