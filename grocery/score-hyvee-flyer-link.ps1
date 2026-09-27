<#
  score-hyvee-flyer-link.ps1 - score the Hy-Vee flyer-line linker against its labelled answer set
  (design/PLAN-flyer-line-product-link-2026-09-26.md sections 3 and 4). Reads; writes only -CasesOut.

  THE BAR, written in the plan before any run and not changed here:
    wrong_links == 0 and links_made >= 20 (links over the 53 Hy-Vee lines), and
    0 wrong-price verdicts on replay for linked lines whose label says the link is right.
  Arms: 'A-no-link' (today: every line unlinked) and 'linker-v1' (hyvee-flyer-link-lib.ps1). One row per (line, arm) in
  -CasesOut; every total printed is derived from those rows. A label is a product id, a SET of ids that each prove the
  line equally (the same flyer price on several flavours), or NO-MATCH (no single product proves it). A link is WRONG
  when its id is not in the label's ids, or the label is NO-MATCH.
  The replay runs flag-verify-lib's Resolve-TcRereadVerdict, unchanged, on the linked candidate's in-window read.
  A SET link (variant 2, linked_set on the line row) is correct only when EVERY member is in the label's ids, and every
  member is replayed; one wrong-price among them counts the line as a false wrong-price.
  -Append appends only the -Arm rows to -CasesOut (the A-no-link rows are already there from the first run), and the
  totals are still derived from this run's rows.
  Last line: FLYER-LINK-SCORE-COMPLETE ...
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$Links,
  [Parameter(Mandatory)][string]$Gold,
  [Parameter(Mandatory)][string]$CasesOut,
  [string]$Arm = 'linker-v1',
  [switch]$Append
)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
. (Join-Path (Split-Path $root -Parent) 'lib\json-io.ps1')
. (Join-Path $root 'pu-lib.ps1')
. (Join-Path $root 'match-lib.ps1')
. (Join-Path $root 'global-exclude-lib.ps1')
. (Join-Path $root 'flag-verify-lib.ps1')

function Read-Jsonl([string]$Path) {
  $o = New-Object System.Collections.Generic.List[object]
  foreach ($ln in [IO.File]::ReadAllLines((Resolve-Path $Path).Path, [Text.Encoding]::UTF8)) { if ($ln.Trim()) { $o.Add(($ln | ConvertFrom-Json)) } }
  return $o.ToArray()
}
$all = Read-Jsonl $Links
$lineRows = @($all | Where-Object { $_.kind -eq 'line' })
$candRows = @($all | Where-Object { $_.kind -eq 'candidate' })
$goldBy = @{}
foreach ($g in (Read-Jsonl $Gold)) { $goldBy[[string]$g.commodity + '|' + [string]$g.line] = $g }
$commodities = Read-JsonFile (Join-Path $root 'commodities.json')
$judge = New-TcIdentityJudge -Commodities $commodities -GlobalExclude ([string[]]@(Get-TcGlobalExclude))

$out = New-Object System.Text.StringBuilder
$rows = New-Object System.Collections.Generic.List[object]
$unlabelled = 0
foreach ($L in $lineRows) {
  $k = [string]$L.commodity + '|' + [string]$L.line
  if (-not $goldBy.ContainsKey($k)) { $unlabelled++; continue }
  $g = $goldBy[$k]
  $ids = @(@($g.product_ids) | ForEach-Object { [string]$_ } | Where-Object { $_ })
  $noMatch = ([string]$g.label -eq 'NO-MATCH')
  foreach ($armName in @('A-no-link', $Arm)) {
    $linked = if ($armName -eq 'A-no-link') { '' } else { [string]$L.linked }
    $set = @()
    if ($linked) { $set = @(@($L.linked_set) | ForEach-Object { [string]$_ } | Where-Object { $_ }); if ($set.Count -eq 0) { $set = @($linked) } }
    $cell = ''
    if ($linked) { $outside = @($set | Where-Object { $ids -notcontains $_ }); $cell = if ((-not $noMatch) -and ($outside.Count -eq 0)) { 'correct link' } else { 'WRONG LINK' } }
    else { $cell = if ($noMatch) { 'correct abstain' } else { 'abstain' } }
    $verdict = ''; $vreason = ''
    foreach ($member in $set) {
      $c = @($candRows | Where-Object { [string]$_.commodity -eq [string]$L.commodity -and [string]$_.line -eq [string]$L.line -and [string]$_.product_id -eq $member }) | Select-Object -First 1
      $pm = [int]$c.price_multiple; if ($pm -lt 1) { $pm = 1 }
      $claim = [pscustomobject]@{ row_type = 'sale'; item = [string]$L.line; per_unit = [double]$L.cell_per_unit; size = ''; ad = [string]$L.line; ad_from = [string]$L.ad_from; ad_to = [string]$L.ad_to; as_of = '' }
      $answer = [pscustomobject]@{ item = [string]$c.name; current_price = ('{0:0.00}' -f ([double]$c.price / $pm)); ad_price = ''; size = [string]$c.size_field; as_of = [string]$c.read_day }
      $idn = Test-TcStoreNameIdentity $judge ([string]$L.commodity) @([string]$c.name)
      $v = Resolve-TcRereadVerdict -Claim $claim -Answer $answer -Unit ([string]$L.unit) -Identity $idn
      if ($verdict -ne 'wrong-price') { $verdict = [string]$v.verdict; $vreason = [string]$v.reason }
    }
    $r = [pscustomobject][ordered]@{ arm = $armName; commodity = [string]$L.commodity; line = [string]$L.line; label = [string]$g.label; label_ids = $ids
      linked = $(if ($linked) { $linked } else { 'none' }); linked_set = @($set); reason = $(if ($armName -eq 'A-no-link') { 'no linker (today: unverifiable, published)' } else { [string]$L.reason })
      cell = $cell; replay_verdict = $verdict; replay_reason = $vreason; source = 'score-hyvee-flyer-link.ps1 over ' + (Split-Path $Links -Leaf) + ' and ' + (Split-Path $Gold -Leaf) }
    $rows.Add($r)
    if ($Append -and $armName -eq 'A-no-link') { continue }
    [void]$out.Append(($r | ConvertTo-Json -Compress -Depth 4)).Append("`n")
  }
}
if ($Append) { [IO.File]::AppendAllText($CasesOut, $out.ToString(), (New-Object Text.UTF8Encoding($false))) }
else { [IO.File]::WriteAllText($CasesOut, $out.ToString(), (New-Object Text.UTF8Encoding($false))) }

$verdictLine = ''
foreach ($armName in @('A-no-link', $Arm)) {
  $ar = @($rows | Where-Object { $_.arm -eq $armName })
  $made = @($ar | Where-Object { $_.linked -ne 'none' }).Count
  $wrong = @($ar | Where-Object { $_.cell -eq 'WRONG LINK' }).Count
  $fwp = @($ar | Where-Object { $_.cell -eq 'correct link' -and $_.replay_verdict -eq 'wrong-price' }).Count
  $abst = @($ar | Where-Object { $_.cell -eq 'abstain' }).Count
  $cabst = @($ar | Where-Object { $_.cell -eq 'correct abstain' }).Count
  $pass = ($wrong -eq 0 -and $made -ge 20 -and $fwp -eq 0)
  Write-Output ('arm ' + $armName + ': lines ' + $ar.Count + ', links made ' + $made + ' of ' + $ar.Count + ', wrong links ' + $wrong + ' of ' + $made + ', false wrong-price ' + $fwp + ', abstain on a labelled product ' + $abst + ', correct abstain ' + $cabst + ' -> bar ' + $(if ($pass) { 'MET' } else { 'MISSED' }))
  $verdictLine = 'arm=' + $armName + ' lines=' + $ar.Count + ' links=' + $made + ' wrong=' + $wrong + ' false_wrong_price=' + $fwp + ' bar=' + $(if ($pass) { 'met' } else { 'missed' })
}
Write-Output ('unlabelled lines skipped: ' + $unlabelled)
Write-Output ('FLYER-LINK-SCORE-COMPLETE ' + $verdictLine)
exit 0
