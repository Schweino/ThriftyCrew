$ErrorActionPreference='Stop'
$d = Get-Content 'C:\Codex\ThriftyCrew\grocery\out\brands\ff-brands.json' -Raw | ConvertFrom-Json
function R2($n){ [math]::Round([double]$n,2) }
function R3($n){ [math]::Round([double]$n,3) }

$swaps=@(); $drill=[ordered]@{}; $varieties=[ordered]@{}
foreach($it in $d.items){
  $rows=@($it.brands)
  if($it.type -eq 'variety'){
    $varieties[$it.id] = @($rows | Sort-Object per_unit | ForEach-Object { [ordered]@{ name=$_.brand; per=R3 $_.per_unit; size=$_.size; price=R2 $_.price } })
    continue
  }
  $store = $rows | Where-Object { $_.is_store_brand } | Sort-Object per_unit | Select-Object -First 1
  $names = @($rows | Where-Object { -not $_.is_store_brand } | Sort-Object per_unit)
  # full drilldown for a few showcase items
  if('peanut-butter','mayonnaise','ground-coffee' -contains $it.id){
    $drill[$it.id] = [ordered]@{ label=$it.label; unit=$it.unit; rows=@($rows | Sort-Object per_unit | ForEach-Object { [ordered]@{ brand=$_.brand; store=[bool]$_.is_store_brand; per=R3 $_.per_unit; size=$_.size; price=R2 $_.price } }) }
  }
  if(-not $store -or $names.Count -eq 0){ continue }
  $cheapName = $names[0]
  $save = [math]::Round((([double]$cheapName.per_unit - [double]$store.per_unit) / [double]$cheapName.per_unit) * 100, 0)
  $swaps += ,([ordered]@{
    id=$it.id; label=$it.label; unit=$it.unit
    store=[ordered]@{ brand=$store.brand; per=R3 $store.per_unit; size=$store.size; price=R2 $store.price }
    name =[ordered]@{ brand=$cheapName.brand; per=R3 $cheapName.per_unit; size=$cheapName.size; price=R2 $cheapName.price }
    savePct=$save
  })
}
$swaps = @($swaps | Sort-Object { -1 * $_.savePct })
$out = [ordered]@{ store=$d.store; generated=$d.generated; swaps=$swaps; drill=$drill; varieties=$varieties }
($out | ConvertTo-Json -Depth 9 -Compress) | Set-Content 'C:\Codex\ThriftyCrew\grocery\out\brands\pilot-view.json' -Encoding UTF8
Write-Output "wrote pilot-view.json"
Write-Output ("swaps: " + $swaps.Count + "  drill: " + $drill.Keys.Count + "  varieties: " + $varieties.Keys.Count)
foreach($s in $swaps){ Write-Output ("  {0,-22} store {1} ${2}/{5} vs {3} ${4}/{5}  = {6}%" -f $s.label, $s.store.brand, $s.store.per, $s.name.brand, $s.name.per, $s.unit, $s.savePct) }