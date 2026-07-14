# Can PowerShell call Hy-Vee's price GraphQL with NO browser session?
# If yes, the Hy-Vee everyday pull can run daily in the cloud like Family Fare's, instead of being a manual
# browser chore that goes stale between runs (which is exactly how the board ended up showing basePrice).
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$query = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(((Get-Content (Join-Path $root 'query-b64.txt') -Raw) -replace '\s','')))

$ep = 'https://www.hy-vee.com/aisles-online/api/graphql/two-legged/getProductDetailsWithPrice'
$H = @{
  'content-type'              = 'application/json'
  'x-operation-name'          = 'getProductDetailsWithPrice'
  'apollographql-client-name' = 'aisles-online-web'
  'User-Agent'                = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148 Safari/537.36'
}
$body = @{
  operationName = 'getProductDetailsWithPrice'
  query         = $query
  variables     = @{
    productId               = 31803
    storeId                 = 1465          # Omaha #01
    locationIds             = @('adcb2ae1-f440-4512-bfe8-9624832c72a9')
    pickupLocationHasLocker = $false
    retailItemEnabled       = $true
    targeted                = $false
    foodHealthScoreEnabled  = $false
  }
} | ConvertTo-Json -Depth 6 -Compress

try {
  $r = Invoke-RestMethod -Uri $ep -Method Post -Headers $H -Body $body -TimeoutSec 25
  $sp = @($r.data.storeProducts.storeProducts)[0]
  Write-Output 'HEADLESS CALL WORKS - no browser session needed.'
  Write-Output ''
  Write-Output ("  product size   : " + [string]$r.data.product.size)
  Write-Output ("  storeId        : " + [string]$sp.storeId + '   (1465 = Omaha #01)')
  Write-Output ("  onSale         : " + [string]$sp.onSale)
  Write-Output ("  price (CURRENT): $" + [string]$sp.price)
  Write-Output ("  basePrice (reg): $" + [string]$sp.basePrice)
  Write-Output ("  isWeighted     : " + [string]$sp.isWeighted)
  Write-Output ("  soldBy         : " + [string](@($r.data.product.item.retailItems)[0].soldByUnitOfMeasure.code))
  Write-Output ''
  Write-Output '  The board has been publishing basePrice. The true current price is `price`.'
} catch {
  Write-Output ('HEADLESS CALL FAILED: ' + $_.Exception.Message)
  if ($_.Exception.Response) {
    $sr = New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())
    Write-Output ('  body: ' + $sr.ReadToEnd().Substring(0, [Math]::Min(300, $sr.ReadToEnd().Length)))
  }
}
