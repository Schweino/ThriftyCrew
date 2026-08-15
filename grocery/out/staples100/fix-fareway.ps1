$ErrorActionPreference = 'Stop'
$root = 'C:\Codex\ThriftyCrew\grocery'
$sf = Join-Path $root 'out\fareway\fareway-shop-verify.json'
$tmp = ConvertFrom-Json ([IO.File]::ReadAllText($sf)); $shop = @($tmp)
$haveIds = @{}; foreach ($s in $shop) { $haveIds[[string]$s.id] = $true }
$fw = Get-Content (Join-Path $root 'out\staples100\fareway-agent.json') -Raw | ConvertFrom-Json
$n = 0
foreach ($r in $fw) {
  if ($haveIds.ContainsKey([string]$r.id)) { continue }
  $size = [string]$r.size
  # size shape fixes for the engine: "24 each" -> "24 ct"; "12 x 12 fl oz" -> "12 pk 12 fl oz"
  $m = [regex]::Match($size, '^(\d+)\s+each$');                       if ($m.Success) { $size = $m.Groups[1].Value + ' ct' }
  $m = [regex]::Match($size, '^(\d+)\s*x\s*(\d+(?:\.\d+)?)\s*fl\s*oz$'); if ($m.Success) { $size = $m.Groups[1].Value + ' pk ' + $m.Groups[2].Value + ' fl oz' }
  if ([string]$r.id -eq 'sliced-cheese' -and $size -match '^24\s*ct$') { $size = '16 oz' }   # 24 slices = 16 oz pack
  $shop += ,([pscustomobject]@{ id = [string]$r.id; name = [string]$r.name; price = [string]$r.price; per = $(if ($size -eq 'lb') { 'pound' } else { '' }); orig = [string]$r.orig; unit = ''; size = $size; url = [string]$r.url })
  $n++
}
ConvertTo-Json @($shop) -Depth 4 | Set-Content $sf -Encoding UTF8
Write-Output ("fareway shop: +" + $n + " -> " + @($shop).Count + " rows")


