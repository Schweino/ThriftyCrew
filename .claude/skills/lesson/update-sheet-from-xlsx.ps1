<#
  update-sheet-from-xlsx.ps1 -FileId -XlsxPath
  Replaces an existing Google Sheet's content in place (same id/URL/sharing) from an xlsx.
  Wipes any Sheets-API-applied polish (CF/charts) -- re-run the relevant polish scripts after.
#>
param(
  [Parameter(Mandatory=$true)][string]$FileId,
  [Parameter(Mandatory=$true)][string]$XlsxPath
)
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\google-token.ps1"
$at = Get-GoogleAccessToken
$boundary = [guid]::NewGuid().ToString()
$metadata = '{"mimeType":"application/vnd.google-apps.spreadsheet"}'
$fileBytes = [IO.File]::ReadAllBytes($XlsxPath)
$LF = "`r`n"
$bodyStart = "--$boundary$LF" + "Content-Type: application/json; charset=UTF-8$LF$LF" + "$metadata$LF" + "--$boundary$LF" + "Content-Type: application/vnd.openxmlformats-officedocument.spreadsheetml.sheet$LF$LF"
$bodyEnd = "$LF--$boundary--$LF"
$bs=[Text.Encoding]::UTF8.GetBytes($bodyStart); $be=[Text.Encoding]::UTF8.GetBytes($bodyEnd)
$full=New-Object byte[] ($bs.Length+$fileBytes.Length+$be.Length)
[Array]::Copy($bs,0,$full,0,$bs.Length); [Array]::Copy($fileBytes,0,$full,$bs.Length,$fileBytes.Length); [Array]::Copy($be,0,$full,$bs.Length+$fileBytes.Length,$be.Length)
$resp = Invoke-RestMethod -Uri "https://www.googleapis.com/upload/drive/v3/files/$FileId`?uploadType=multipart&fields=id,name,modifiedTime" -Method Patch -Headers @{Authorization="Bearer $at"} -ContentType "multipart/related; boundary=$boundary" -Body $full -TimeoutSec 60
Write-Host ("UPDATED {0}  ({1})" -f $resp.name, $resp.id) -ForegroundColor Green
