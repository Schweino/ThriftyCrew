<#
  polish-debt.ps1  -  Adds the declining-balance payoff chart to the Debt Calculator via
  the Sheets API (area chart, total balance to zero). Sources the hidden Engine tab.
  Re-run after any re-upload.
#>
$ErrorActionPreference = "Stop"
. "C:\Codex\ThriftyCrew\.claude\skills\lesson\google-token.ps1"
$at = Get-GoogleAccessToken
$id = "1JCruYNQmg6-7f51JG3iKn_KEDWZH1ucdudqR3I_kcq8"
$H = @{ Authorization = "Bearer $at" }

$meta = Invoke-RestMethod -Uri "https://sheets.googleapis.com/v4/spreadsheets/$id`?fields=sheets(properties(sheetId,title),charts(chartId))" -Headers $H -TimeoutSec 30
$calcGid = ($meta.sheets | Where-Object { $_.properties.title -eq "Calculator" }).properties.sheetId
$engGid  = ($meta.sheets | Where-Object { $_.properties.title -eq "Engine" }).properties.sheetId

$existing=@(); foreach($s in $meta.sheets){ if($s.charts){ foreach($c in $s.charts){ $existing += $c.chartId } } }
if($existing.Count -gt 0){ $del=($existing|%{'{"deleteEmbeddedObject":{"objectId":'+$_+'}}'}) -join ','; try { Invoke-RestMethod -Uri "https://sheets.googleapis.com/v4/spreadsheets/$id`:batchUpdate" -Method Post -Headers $H -ContentType "application/json" -Body ('{"requests":['+$del+']}') -TimeoutSec 30 | Out-Null } catch {} }

$body = @"
{
  "requests":[
    {"addChart":{"chart":{
      "spec":{
        "title":"Watch your debt disappear",
        "subtitle":"The month it hits zero is your freedom date",
        "titleTextFormat":{"fontFamily":"Georgia","bold":true},
        "basicChart":{
          "chartType":"AREA","legendPosition":"NO_LEGEND","headerCount":0,
          "axis":[
            {"position":"BOTTOM_AXIS","title":"Months from now"},
            {"position":"LEFT_AXIS","title":"Total balance owed"}
          ],
          "domains":[
            {"domain":{"sourceRange":{"sources":[{"sheetId":$engGid,"startRowIndex":2,"endRowIndex":363,"startColumnIndex":79,"endColumnIndex":80}]}}}
          ],
          "series":[
            {"series":{"sourceRange":{"sources":[{"sheetId":$engGid,"startRowIndex":2,"endRowIndex":363,"startColumnIndex":78,"endColumnIndex":79}]}},"targetAxis":"LEFT_AXIS","color":{"red":0.753,"green":0.224,"blue":0.169}}
          ]
        }
      },
      "position":{"overlayPosition":{
        "anchorCell":{"sheetId":$calcGid,"rowIndex":3,"columnIndex":8},
        "offsetXPixels":6,"offsetYPixels":0,"widthPixels":660,"heightPixels":410
      }}
    }}}
  ]
}
"@
Invoke-RestMethod -Uri "https://sheets.googleapis.com/v4/spreadsheets/$id`:batchUpdate" -Method Post -Headers $H -ContentType "application/json" -Body $body -TimeoutSec 30 | Out-Null
Write-Host "Debt payoff chart added (declining red area to zero)." -ForegroundColor Green
