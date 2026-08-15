<#
  create-sheet-from-xlsx.ps1  -  Uploads an xlsx to the Work Drive and converts it to a
  native Google Sheet. Prints id + webViewLink. Reusable for any tracker/tool.
    powershell -File create-sheet-from-xlsx.ps1 -XlsxPath "C:\...\file.xlsx" -Title "Nice Title"
#>
param(
  [Parameter(Mandatory=$true)][string]$XlsxPath,
  [Parameter(Mandatory=$true)][string]$Title
)
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\google-token.ps1"
$at = Get-GoogleAccessToken

$boundary = [guid]::NewGuid().ToString()
$metadata = @{ name = $Title; mimeType = "application/vnd.google-apps.spreadsheet" } | ConvertTo-Json -Compress
$fileBytes = [IO.File]::ReadAllBytes($XlsxPath)

$LF = "`r`n"
$bodyStart = (
  "--$boundary$LF" +
  "Content-Type: application/json; charset=UTF-8$LF$LF" +
  "$metadata$LF" +
  "--$boundary$LF" +
  "Content-Type: application/vnd.openxmlformats-officedocument.spreadsheetml.sheet$LF$LF"
)
$bodyEnd = "$LF--$boundary--$LF"
$bs = [Text.Encoding]::UTF8.GetBytes($bodyStart); $be = [Text.Encoding]::UTF8.GetBytes($bodyEnd)
$full = New-Object byte[] ($bs.Length + $fileBytes.Length + $be.Length)
[Array]::Copy($bs,0,$full,0,$bs.Length)
[Array]::Copy($fileBytes,0,$full,$bs.Length,$fileBytes.Length)
[Array]::Copy($be,0,$full,$bs.Length+$fileBytes.Length,$be.Length)

$resp = Invoke-RestMethod -Uri "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id,name,webViewLink" `
  -Method Post -Headers @{ Authorization = "Bearer $at" } -ContentType "multipart/related; boundary=$boundary" -Body $full -TimeoutSec 60
Write-Host "CREATED" -ForegroundColor Green
Write-Host ("ID:   {0}" -f $resp.id)
Write-Host ("Link: {0}" -f $resp.webViewLink)
