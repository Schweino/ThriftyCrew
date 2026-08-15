$ErrorActionPreference = 'Stop'
$work = 'C:\Codex\ThriftyCrew\grocery\out\aldi-work-0715.txt'
$yesterdayPath = 'C:\Codex\ThriftyCrew\grocery\out\regular\aldi-regular-2026-07-14.json'
$outPath = 'C:\Codex\ThriftyCrew\grocery\out\regular\aldi-regular-2026-07-15.json'

function Norm([string]$s){
  if(-not $s){return ''}
  ($s.ToLower() -replace '[^a-z0-9]','')
}

# Parse fresh work rows: term|name|ad_price|size
$fresh = @()
$seenFresh = @{}
foreach($line in Get-Content $work){
  if(-not $line.Trim()){continue}
  $p = $line -split '\|'
  if($p.Count -lt 3){continue}
  $name = $p[1].Trim()
  $price = $p[2].Trim()
  $size = if($p.Count -ge 4){$p[3].Trim()}else{''}
  $key = Norm $name
  if($seenFresh.ContainsKey($key)){continue}  # first occurrence wins (fresh)
  $seenFresh[$key] = $true
  $fresh += [ordered]@{
    store = 'Aldi'
    item = $name
    ad_price = $price
    size = $size
    regular = $null
    source_ad = 'everyday shelf price'
    price_type = 'everyday'
  }
}

# Load yesterday deals, carry those not superseded by a fresh item of same name
$y = Get-Content $yesterdayPath -Raw | ConvertFrom-Json
$carry = @()
foreach($d in $y.deals){
  $key = Norm $d.item
  if($seenFresh.ContainsKey($key)){continue}   # fresh already has this exact product
  $seenFresh[$key] = $true                       # also dedup yesterday's internal dups
  $carry += [ordered]@{
    store = 'Aldi'
    item = $d.item
    ad_price = $d.ad_price
    size = $d.size
    regular = $null
    source_ad = if($d.PSObject.Properties['source_ad']){$d.source_ad}else{'everyday shelf price (carried 07-14)'}
    price_type = 'everyday'
  }
}

$all = @($fresh) + @($carry)

$obj = [ordered]@{
  store = 'Aldi'
  week_of = '2026-07-15'
  price_type = 'everyday'
  source = 'aldi.us OLA 42 Omaha; core re-pulled 07-15 + carried 07-14'
  deals = $all
}

$json = $obj | ConvertTo-Json -Depth 6
Set-Content -Path $outPath -Value $json -Encoding UTF8
Write-Output ("fresh={0} carried={1} total={2}" -f $fresh.Count, $carry.Count, $all.Count)
