<#
  snapshot-tab.ps1 -FileId -TabName -OutPath
  Exports a single tab of a Google Sheet to PDF (landscape, fit-width, no gridlines)
  so it can be visually reviewed. Prints the saved path.
#>
param(
  [Parameter(Mandatory=$true)][string]$FileId,
  [Parameter(Mandatory=$true)][string]$TabName,
  [Parameter(Mandatory=$true)][string]$OutPath
)
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\google-token.ps1"
$at = Get-GoogleAccessToken
$H = @{ Authorization = "Bearer $at" }
$meta = Invoke-RestMethod -Uri "https://sheets.googleapis.com/v4/spreadsheets/$FileId`?fields=sheets(properties(sheetId,title))" -Headers $H -TimeoutSec 30
$gid = ($meta.sheets | Where-Object { $_.properties.title -eq $TabName }).properties.sheetId
if ($null -eq $gid) { throw "Tab '$TabName' not found" }
$url = "https://docs.google.com/spreadsheets/d/$FileId/export?format=pdf&gid=$gid&size=letter&portrait=false&fitw=true&sheetnames=false&printtitle=false&gridlines=false&fzr=false&top_margin=0.25&bottom_margin=0.25&left_margin=0.25&right_margin=0.25"
Invoke-WebRequest -Uri $url -Headers $H -OutFile $OutPath -UseBasicParsing -TimeoutSec 60
Write-Host ("Saved {0} ({1} bytes) gid={2}" -f $OutPath, (Get-Item $OutPath).Length, $gid) -ForegroundColor Green
