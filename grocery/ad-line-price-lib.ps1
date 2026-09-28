# ad-line-price-lib.ps1 - how a weekly-ad LINE is read for a price, in ONE place (split out 2026-09-28).
# Side-effect free: functions only, safe to dot-source from the engine (pricing-math-lib.ps1) and from
# guards.ps1 guard 10b (ad-line price provenance). Get-TcPerksPrice is the one reading of a Hy-Vee Perks
# line (queue 2026-09-28-b61b08), so the engine and the guard can never read two prices off one row.
# Get-AdLineLastMoney and Get-AdLineBasisMultiplier moved here verbatim from guards.ps1 (guard 10b).
# gate-inputs: grocery\ad-line-price-lib.ps1
function Get-TcPerksPrice([string]$t) {
  <# THE ONE READING OF A HY-VEE PERKS LINE (queue 2026-09-28-b61b08). Brad's decision (c), commit b3afe6953
     2026-07-27: a line quoting "$1.98 PERKS PRICES, NON-MEMBER PRICE $2.48" publishes the PERKS (member) price
     and the cell is gated 'Perks membership required'. Returns that price, or $null when the line quotes none.
     Get-ItemPrice prices with it AND guards.ps1 10b (ad-line provenance) checks against it, so the engine and
     the guard can no longer read two different prices off one row: on 2026-09-28 the guard read the LAST
     token ($2.48, the non-member price) and withheld Hy-Vee celery that the engine had priced per the ruling. #>
  $m = [regex]::Match(("" + $t), '(?i)\$\s*(\d+(?:\.\d{1,2})?)\s*perks\s*price')
  if ($m.Success) { return [double]$m.Groups[1].Value }
  return $null
}
function Get-AdLineLastMoney([string]$t) {
  # THE GLYPH RIDES AS \u00XX ESCAPES, NEVER A LITERAL - same rule as compare-deals' own cents branch.
  # "N cents OFF PER GALLON" is excluded here for the same reason it is excluded there: it is a fuel
  # reward, not a price, so it must not be able to satisfy this guard either.
  $rx = '(?:(\d+)\s*(?:/|for)\s*\$\s*(\d+(?:\.\d{1,2})?))|(?:\$\s*(\d+(?:\.\d{1,2})?))|(?:(\d+)\s*(?:\u00C2?\u00A2|cents?)(?!\s*OFF\s*PER\s*GALLON))'
  $last = $null
  foreach ($m in [regex]::Matches(("" + $t), $rx, [Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
    if ($m.Groups[1].Success) { $n = [double]$m.Groups[1].Value; if ($n -gt 0) { $last = [double]$m.Groups[2].Value / $n } }
    elseif ($m.Groups[3].Success) { $last = [double]$m.Groups[3].Value }
    elseif ($m.Groups[4].Success) { $last = [double]$m.Groups[4].Value / 100.0 }
  }
  return $last
}
function Get-AdLineBasisMultiplier([string]$basis) {
  # The engine's own basis string, read back. Anything not listed returns $null and the cell is SKIPPED.
  $b = ("" + $basis)
  if ($b -eq 'per-lb marker (converted to oz)') { return 16.0 }           # a per-lb RATE published per oz
  $m = [regex]::Match($b, '^per-(\d+(?:\.\d+)?)-pack$');      if ($m.Success) { return [double]$m.Groups[1].Value }
  $m = [regex]::Match($b, '^per-(\d+(?:\.\d+)?)-lb pkg$');    if ($m.Success) { return [double]$m.Groups[1].Value }
  $m = [regex]::Match($b, '^size\s+(\d+(?:\.\d+)?)\s');       if ($m.Success) { return [double]$m.Groups[1].Value }
  if ($b -eq 'per-each' -or $b -eq 'per-lb marker' -or $b -eq 'per-lb rate in size') { return 1.0 }
  if ($b -like 'per-package*' -or $b -like 'per-each (*') { return 1.0 }
  return $null
}
