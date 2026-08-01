<#
  multipack-lib.ps1 - THE single copy of the multipack arithmetic (extracted 2026-07-23).

  Why one copy: guards.ps1 invariant 5 and build-walmart-deals.ps1's pre-filter must agree EXACTLY -
  a row the builder keeps but the guard rejects blocks the publish; a row the builder rejects but the
  guard would allow silently shrinks coverage. Two hand-maintained copies of the same math is the trap
  this repo already paid for once with pu-lib (185 cells silently unchecked). So both callers dot-source
  THIS file. The full design rationale (why arithmetic instead of a human, why fail-closed on truncated
  names, where the 60-char truncation really came from) lives in guards.ps1 above invariant 5 - read it
  there; this file is deliberately just the math.

  Test-MpClassify returns one of:
    'not-multipack' - name has no pack count >1, or the size itself shows a pack multiplier, or the size
                      carries no weight/volume unit (nothing to mis-price)
    'pack-total'    - the size arithmetically IS the pack total (name-weight x count within 3%) - correct row
    'allowlisted'   - a human reviewed this exact store|item in multipack-allowlist.json
    'reject'        - name declares a pack the size does not account for: the ReaLemon class
                      ("2 pk" in the name, size = ONE bottle). The guard hard-fails these; the builder
                      refuses to emit them.
#>

function Test-MpSizeIsPackTotal([string]$name, [double]$sizeVal) {
  if ($sizeVal -le 0) { return $false }
  $n = $name.ToLower()
  $packs = @()
  foreach ($m in [regex]::Matches($n, '(\d+)\s*(?:pk|pack)\b')) { $v = [int]$m.Groups[1].Value; if ($v -gt 1) { $packs += $v } }
  if (-not $packs.Count) { return $false }
  # a name can carry two counts ("(2 pack) Pearls Sliced Olives, 6 Pack of 6.5 oz Cans" = 2 x 6 x 6.5 = 78 oz),
  # so try each count AND their product.
  $cands = @($packs)
  if ($packs.Count -gt 1) { $prod = 1; foreach ($p in $packs) { $prod *= $p }; $cands += $prod }
  foreach ($wm in [regex]::Matches($n, '([\d.]+)\s*(?:fl\s?oz|oz|lb)\b')) {
    $w = 0.0; if (-not [double]::TryParse($wm.Groups[1].Value, [ref]$w)) { continue }
    foreach ($c in $cands) {
      $tot = $w * $c
      # 3% covers the stores' own rounding of a pack total (2 x 15 oz listed as 29.9, 12 x 15.5 as 186.4)
      if ($tot -gt 0 -and ([math]::Abs($tot - $sizeVal) / $tot) -le 0.03) { return $true }
    }
  }
  return $false
}

function Get-MpAllowKeys([string]$root) {
  $f = Join-Path $root 'multipack-allowlist.json'
  if (-not (Test-Path $f)) { return @() }
  return @((Get-Content $f -Raw | ConvertFrom-Json).allow | ForEach-Object { $_.store + '|' + $_.item })
}

function Test-MpClassify([string]$store, [string]$item, [string]$size, $allowKeys) {
  $name = [string]$item; $sz = [string]$size
  if (-not $name -or -not $sz) { return 'not-multipack' }
  $pn = [regex]::Match($name.ToLower(), '(\d+)\s*(?:pk\b|pack\b)')
  if (-not $pn.Success -or [int]$pn.Groups[1].Value -le 1) { return 'not-multipack' }
  $ps = [regex]::Match($sz.ToLower(), '(\d+)\s*(?:x|pk\b|pack\b|ct\b|count\b)')
  if ($ps.Success -and [int]$ps.Groups[1].Value -gt 1) { return 'not-multipack' }
  if ($sz -notmatch '[\d.]+\s*(fl\s?oz|oz|lb|gal|qt|l|ml|g)\b') { return 'not-multipack' }
  $sv = 0.0; [void][double]::TryParse(([regex]::Match($sz, '[\d.]+').Value), [ref]$sv)
  if (Test-MpSizeIsPackTotal $name $sv) { return 'pack-total' }
  if (@($allowKeys) -contains ($store + '|' + $name)) { return 'allowlisted' }
  return 'reject'
}

<#
  Get-MpRepairedSize - the REPAIR half of the same arithmetic (2026-08-01).

  Test-MpClassify says a row is wrong. This says what the row should have been, but ONLY when the name
  states the whole sum itself: a pack count N, a per-unit weight W, and a recorded size that IS that W.
  Then the size is one unit of an N-pack and the total is N x W - the store told us both numbers and only
  multiplied wrong. Founding case: Family Fare's own API returns "50.5 oz" for
  "Heinz Tomato Ketchup, 2 Pack 50.5 Oz" at $14.99. Taken at face value that is $0.2968/oz, nearly 2x
  every other Heinz on the same shelf ($0.1561 for the 64 oz, $0.155 for the 38 oz); as 101 oz it is
  $0.1484/oz, exactly where a bulk 2-pack belongs. The arithmetic decides, not a human.

  IT REFUSES EVERYTHING ELSE, and that is the whole design. "ReaLemon 100% Lemon Juice (2 pk)" with size
  "48 fl oz" - the bug guard 5 was built for - names NO per-unit weight, so there is nothing to multiply
  and this returns ''. That row must stay a hard fail and go to a human in multipack-allowlist.json.
  Inventing a total from a pack count alone would be guessing at the exact point the guard exists to stop
  guessing, and a 2x wrong price is the thing being prevented. Returns '' whenever it cannot be certain.
#>
function Get-MpRepairedSize([string]$name, [string]$size) {
  $n = ([string]$name).ToLower()
  $sz = ([string]$size)
  if (-not $n -or -not $sz) { return '' }
  $pn = [regex]::Match($n, '(\d+)\s*(?:pk\b|pack\b)')
  if (-not $pn.Success) { return '' }
  $count = [int]$pn.Groups[1].Value
  if ($count -le 1) { return '' }
  # exactly ONE pack count in the name. Two counts ("(2 pack) ... 6 Pack of 6.5 oz Cans") mean the total is
  # ambiguous between N, M and NxM - Test-MpSizeIsPackTotal may try all three to CONFIRM a size, but
  # choosing one to WRITE is a different act, and it is a guess.
  if (@([regex]::Matches($n, '(\d+)\s*(?:pk\b|pack\b)')).Count -ne 1) { return '' }
  $sm = [regex]::Match($sz, '(?i)^\s*([\d.]+)\s*(fl\s?oz|oz|lb|gal|qt|l|ml|g)\b')
  if (-not $sm.Success) { return '' }
  $sv = 0.0
  if (-not [double]::TryParse($sm.Groups[1].Value, [ref]$sv) -or $sv -le 0) { return '' }
  $unit = $sm.Groups[2].Value.ToLower() -replace '\s+', ' '
  # the name must state a per-unit weight EQUAL to the recorded size, in the same unit family. Equality is
  # the evidence that the size is one unit rather than something else we do not understand.
  $hit = $false
  foreach ($wm in [regex]::Matches($n, '([\d.]+)\s*(fl\s?oz|oz|lb)\b')) {
    $w = 0.0
    if (-not [double]::TryParse($wm.Groups[1].Value, [ref]$w) -or $w -le 0) { continue }
    $wu = $wm.Groups[2].Value.ToLower() -replace '\s+', ' '
    if ($wu -ne $unit) { continue }
    if ([math]::Abs($w - $sv) / $sv -le 0.001) { $hit = $true; break }
  }
  if (-not $hit) { return '' }
  # "N pk W unit" is the form pu-lib's pack-first multipack regex already resolves to N*W, so the repaired
  # string flows through the SAME per-unit math every other multipack uses. No new size grammar.
  return ('' + $count + ' pk ' + $sm.Groups[1].Value + ' ' + $unit)
}
