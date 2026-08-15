$ErrorActionPreference = "Stop"
. "C:\Codex\ThriftyCrew\.claude\skills\lesson\google-token.ps1"
$at = Get-GoogleAccessToken
$id = "1JCruYNQmg6-7f51JG3iKn_KEDWZH1ucdudqR3I_kcq8"
$H = @{ Authorization = "Bearer $at" }

function WriteVals($body){ Invoke-RestMethod -Uri "https://sheets.googleapis.com/v4/spreadsheets/$id/values:batchUpdate" -Method Post -Headers $H -ContentType "application/json" -Body $body -TimeoutSec 30 | Out-Null }
function ReadOut($tag){
  $ranges = @("Calculator!G5","Calculator!G6","Calculator!G7","Calculator!G8","Calculator!F11","Calculator!F12","Calculator!G11","Calculator!G12")
  $q = ($ranges | ForEach-Object { "ranges=$([uri]::EscapeDataString($_))" }) -join "&"
  $r = Invoke-RestMethod -Uri "https://sheets.googleapis.com/v4/spreadsheets/$id/values:batchGet?$q&valueRenderOption=FORMATTED_VALUE" -Headers $H -TimeoutSec 30
  $labels=@("Debt-free date","Time","Total interest","Total paid","D1 priority","D2 priority","D1 paid by","D2 paid by")
  Write-Host "  [$tag]" -ForegroundColor Cyan
  for($i=0;$i -lt $ranges.Count;$i++){ $v=if($r.valueRanges[$i].values){$r.valueRanges[$i].values[0][0]}else{"-"}; Write-Host ("    {0,-15} {1}" -f $labels[$i],$v) }
}

# scenario: D1 $1000 @20% min$25 ; D2 $2000 @10% min$50 ; extra $100
WriteVals(@'
{"valueInputOption":"USER_ENTERED","data":[
  {"range":"Calculator!C6","values":[[100]]},
  {"range":"Calculator!B11:E11","values":[["Card A",1000,20,25]]},
  {"range":"Calculator!B12:E12","values":[["Card B",2000,10,50]]}
]}
'@)
WriteVals('{"valueInputOption":"USER_ENTERED","data":[{"range":"Calculator!C5","values":[["Avalanche"]]}]}')
Start-Sleep -Milliseconds 700
ReadOut "AVALANCHE (attack Card A 20% first)"
WriteVals('{"valueInputOption":"USER_ENTERED","data":[{"range":"Calculator!C5","values":[["Snowball"]]}]}')
Start-Sleep -Milliseconds 700
ReadOut "SNOWBALL (attack Card B smallest... actually Card A is smaller)"

# clear
WriteVals(@'
{"valueInputOption":"USER_ENTERED","data":[
  {"range":"Calculator!C5","values":[["Avalanche"]]},
  {"range":"Calculator!C6","values":[[100]]},
  {"range":"Calculator!B11:E12","values":[["","","",""],["","","",""]]}
]}
'@)
Write-Host "`nTest data cleared (method back to Avalanche, extra 100 default)." -ForegroundColor Green
