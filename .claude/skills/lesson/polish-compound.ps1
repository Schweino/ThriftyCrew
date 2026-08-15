<#
  polish-compound.ps1  -  Adds the stacked-area growth chart to the Compound Calculator
  via the Sheets API. Contributed (navy) + Growth (gold) stack to the balance line.
  Re-run after any re-upload (charts don't survive xlsx conversion; gids change).
#>
$ErrorActionPreference = "Stop"
. "C:\Codex\ThriftyCrew\.claude\skills\lesson\google-token.ps1"
$at = Get-GoogleAccessToken
$id = "1wGdOGWO-44nY0Krv7e62qb60IApj3uhcR6QJ7CMNxb0"
$H = @{ Authorization = "Bearer $at" }

$meta = Invoke-RestMethod -Uri "https://sheets.googleapis.com/v4/spreadsheets/$id`?fields=sheets(properties(sheetId,title),charts(chartId))" -Headers $H -TimeoutSec 30
$calcGid = ($meta.sheets | Where-Object { $_.properties.title -eq "Calculator" }).properties.sheetId
$dataGid = ($meta.sheets | Where-Object { $_.properties.title -eq "Growth Data" }).properties.sheetId

# remove any existing charts (idempotent re-run)
$existingCharts = @()
foreach($s in $meta.sheets){ if($s.charts){ foreach($c in $s.charts){ $existingCharts += $c.chartId } } }
if($existingCharts.Count -gt 0){
  $delReq = ($existingCharts | ForEach-Object { '{"deleteEmbeddedObject":{"objectId":' + $_ + '}}' }) -join ','
  try { Invoke-RestMethod -Uri "https://sheets.googleapis.com/v4/spreadsheets/$id`:batchUpdate" -Method Post -Headers $H -ContentType "application/json" -Body ('{"requests":[' + $delReq + ']}') -TimeoutSec 30 | Out-Null } catch {}
}

$body = @"
{
  "requests":[
    {"addChart":{"chart":{
      "spec":{
        "title":"How your money grows",
        "subtitle":"What you put in vs. the growth on top",
        "titleTextFormat":{"fontFamily":"Georgia","bold":true},
        "basicChart":{
          "chartType":"AREA","stackedType":"STACKED","legendPosition":"BOTTOM_LEGEND",
          "headerCount":1,
          "axis":[
            {"position":"BOTTOM_AXIS","title":"Years from now"},
            {"position":"LEFT_AXIS","title":"Balance"}
          ],
          "domains":[
            {"domain":{"sourceRange":{"sources":[{"sheetId":$dataGid,"startRowIndex":2,"endRowIndex":44,"startColumnIndex":1,"endColumnIndex":2}]}}}
          ],
          "series":[
            {"series":{"sourceRange":{"sources":[{"sheetId":$dataGid,"startRowIndex":2,"endRowIndex":44,"startColumnIndex":2,"endColumnIndex":3}]}},"targetAxis":"LEFT_AXIS","color":{"red":0.086,"green":0.149,"blue":0.247}},
            {"series":{"sourceRange":{"sources":[{"sheetId":$dataGid,"startRowIndex":2,"endRowIndex":44,"startColumnIndex":3,"endColumnIndex":4}]}},"targetAxis":"LEFT_AXIS","color":{"red":0.886,"green":0.643,"blue":0.235}}
          ]
        }
      },
      "position":{"overlayPosition":{
        "anchorCell":{"sheetId":$calcGid,"rowIndex":3,"columnIndex":7},
        "offsetXPixels":6,"offsetYPixels":0,"widthPixels":690,"heightPixels":410
      }}
    }}}
  ]
}
"@
Invoke-RestMethod -Uri "https://sheets.googleapis.com/v4/spreadsheets/$id`:batchUpdate" -Method Post -Headers $H -ContentType "application/json" -Body $body -TimeoutSec 30 | Out-Null
Write-Host "Growth chart added (stacked area: navy contributions + gold growth)." -ForegroundColor Green
