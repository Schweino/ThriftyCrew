$h = (Invoke-WebRequest -Uri 'https://www.thriftycrew.com/omaha-grocery-prices/' -UseBasicParsing -Headers @{'Cache-Control'='no-cache'}).Content
function Cell($label) {
  $m = [regex]::Match($h, [regex]::Escape($label) + '(?<s>[\s\S]{0,320})')
  if (-not $m.Success) { return "$label -> NOT FOUND" }
  $seg = ($m.Groups['s'].Value -replace '<[^>]+>',' ' -replace '\s+',' ').Trim()
  return ("{0,-24} {1}" -f $label, $seg.Substring(0, [Math]::Min(60, $seg.Length)))
}
foreach ($l in @('Gelatin (Jell-O)','Yeast (baking)','Toothbrushes','Yellow / Sweet Onions','Cod Fillets','Honey','Olive Oil')) { Write-Output (Cell $l) }
