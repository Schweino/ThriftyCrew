$ErrorActionPreference = "Stop"
. "C:\Codex\ThriftyCrew\.claude\skills\lesson\google-token.ps1"
$at = Get-GoogleAccessToken
$id = "16Hq0OurkTlDD9mJxw_hSwR1zVAMPv4JylQLjFdiX18c"
$H = @{ Authorization = "Bearer $at" }

# 1. write sample data
$writeBody = @'
{
  "valueInputOption":"USER_ENTERED",
  "data":[
    {"range":"'My Goals'!B12:F12","values":[["Emergency Fund",5000,1500,"2026-12-31",300]]},
    {"range":"'My Goals'!B13:F13","values":[["Vacation",3000,3000,"2026-10-01",0]]}
  ]
}
'@
Invoke-RestMethod -Uri "https://sheets.googleapis.com/v4/spreadsheets/$id/values:batchUpdate" -Method Post -Headers $H -ContentType "application/json" -Body $writeBody -TimeoutSec 30 | Out-Null
Start-Sleep -Milliseconds 500

# 2. read computed outputs (what the user sees)
$ranges = @("'My Goals'!H12","'My Goals'!I12","'My Goals'!J12","'My Goals'!K12","'My Goals'!H13","'My Goals'!J13","'My Goals'!K13","'My Goals'!B6","'My Goals'!E6","'My Goals'!G6","'My Goals'!B8")
$q = ($ranges | ForEach-Object { "ranges=$([uri]::EscapeDataString($_))" }) -join "&"
$r = Invoke-RestMethod -Uri "https://sheets.googleapis.com/v4/spreadsheets/$id/values:batchGet?$q&valueRenderOption=FORMATTED_VALUE" -Headers $H -TimeoutSec 30
Write-Host "=== FUNCTIONAL TEST (Emergency Fund: 5000 target/1500 saved/Dec 2026/300 plan ; Vacation: 3000/3000) ===" -ForegroundColor Cyan
$labels = @("Row12 Progress%","Row12 Need/mo","Row12 Status","Row12 FinishBy","Row13 Progress%","Row13 Status","Row13 FinishBy","Summary TotalSaved","Summary YouSetAside","Summary OnPace","Summary Message")
for($i=0;$i -lt $ranges.Count;$i++){
  $v = if($r.valueRanges[$i].values){ $r.valueRanges[$i].values[0][0] } else { "(blank)" }
  Write-Host ("  {0,-22} => {1}" -f $labels[$i], $v)
}

# 3. clear the sample data so the template ships blank
$clearBody = @'
{
  "valueInputOption":"USER_ENTERED",
  "data":[
    {"range":"'My Goals'!B12:F12","values":[["","","","",""]]},
    {"range":"'My Goals'!B13:F13","values":[["","","","",""]]}
  ]
}
'@
Invoke-RestMethod -Uri "https://sheets.googleapis.com/v4/spreadsheets/$id/values:batchUpdate" -Method Post -Headers $H -ContentType "application/json" -Body $clearBody -TimeoutSec 30 | Out-Null
Write-Host "`nSample data cleared -- template is blank again." -ForegroundColor Green