$h = (Invoke-WebRequest -Uri 'https://www.thriftycrew.com/omaha-grocery-prices/' -UseBasicParsing -Headers @{'Cache-Control'='no-cache'}).Content
function Row($label) {
  $m = [regex]::Match($h, [regex]::Escape($label) + '(?<s>[\s\S]{0,200})')
  if (-not $m.Success) { return ("{0,-24} NOT FOUND" -f $label) }
  $seg = ($m.Groups['s'].Value -replace '<[^>]+>',' ' -replace '\s+',' ').Trim()
  return ("{0,-24} {1}" -f $label, $seg.Substring(0, [Math]::Min(44, $seg.Length)))
}
foreach ($l in @('Bottled Water','Microwave Popcorn','Lemon Juice','White Vinegar','Spinach','Yeast (baking)','Sweet Corn','Cottage Cheese','Orange Juice','Peanut Butter','Coffee','Gelatin (Jell-O)')) { Write-Output (Row $l) }
