<#
  stamp-ad-as-of.ps1 - give every weekly-ad row the date its flyer was actually read.

  WHY (2026-08-31). guards' freshness check reports, for two stores:

      Baker's  108 rows | NO as_of ON ANY ROW - freshness cannot be measured, only file age
      Fareway  244 rows | NO as_of ON ANY ROW - freshness cannot be measured, only file age
      <-- NOT price-verified today: this store CAN discount, so it may be publishing regular prices

  Both are real ad prices and both stores really can discount, so "we cannot tell how old this price
  is" is the worst answer to have about them. Sam's Club, whose rows come from a browser pull, stamps
  as_of per row and reports 118 of 118 dated; these two are vision-read from flyer JPGs by an agent,
  and that agent never wrote the field.

  IT IS NOT A TAUTOLOGY, WHICH IS THE ONLY REASON THIS IS ALLOWED TO EXIST. The date is not invented
  and it is not the filename: every one of these documents already carries a DOC-LEVEL `captured` -
  the day the flyer pages were read - beside ad_from/ad_to. bakers-deals-2026-08-26.json says
  captured 2026-08-26; fareway-deals-2026-08-30.json says captured 2026-08-30 for an ad running
  08-31..09-05, so the capture date and the ad window are genuinely different facts. All this does is
  move a date the document already states onto the rows that came from it, so the freshness check can
  read it the same way it reads Sam's.

  AND IT REFUSES RATHER THAN GUESSES. A file with no `captured` is left alone and reported: stamping
  such a file from its filename WOULD be the tautology - a freshness number derived from the only
  thing the guard could already see - and would silence a real question with a circular answer.

  TEXT SURGERY, NOT RESERIALIZE. These files are written by an agent; Baker's is CRLF and Fareway is
  LF, both indent-2 with no trailing newline. Round-tripping either through ConvertTo-Json would
  rewrite every line of a file whose diff someone has to review. So the bytes of each row object are
  edited and the whole file is re-parsed afterwards, with the row count and every other field proved
  unchanged.

  Usage:
    .\stamp-ad-as-of.ps1              dry run - reports what it would stamp, writes nothing
    .\stamp-ad-as-of.ps1 -Apply
    .\stamp-ad-as-of.ps1 -SelfTest
#>
param([switch]$Apply, [switch]$SelfTest, [string]$Root = '')

$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

function Get-AdDealFiles {
  param([string]$OutDir)
  $out = @()
  foreach ($sub in @('bakers', 'fareway', 'sams')) {
    $d = Join-Path $OutDir $sub
    if (-not (Test-Path $d)) { continue }
    $out += @(Get-ChildItem (Join-Path $d ($sub + '-deals-*.json')) -File -ErrorAction SilentlyContinue |
              Where-Object { $_.BaseName -match '\d{4}-\d{2}-\d{2}$' })
  }
  return @($out)
}

function Add-RowAsOf {
  <#
    Insert "as_of": "<date>" into every deals row that lacks one. Returns a hashtable:
      text     the new file text (unchanged when nothing to do)
      stamped  how many rows gained the field
      skipped  how many already had it
    Pure string work so the self-test can drive it without touching disk.
  #>
  param([string]$Text, [string]$Captured)
  $i = $Text.IndexOf('"deals"')
  if ($i -lt 0) { return @{ text = $Text; stamped = 0; skipped = 0 } }
  $b = $Text.IndexOf('[', $i)
  if ($b -lt 0) { return @{ text = $Text; stamped = 0; skipped = 0 } }

  $spans = @()
  $depth = 0; $start = -1; $j = $b + 1
  while ($j -lt $Text.Length) {
    $ch = $Text[$j]
    if ($ch -eq '"') {
      $j++
      while ($j -lt $Text.Length -and $Text[$j] -ne '"') { if ($Text[$j] -eq '\') { $j++ }; $j++ }
    }
    elseif ($ch -eq '{') { if ($depth -eq 0) { $start = $j }; $depth++ }
    elseif ($ch -eq '}') {
      $depth--
      if ($depth -eq 0) { $spans += ,@($start, $j) }
    }
    elseif ($ch -eq ']' -and $depth -eq 0) { break }
    $j++
  }

  $stamped = 0; $skipped = 0
  $out = $Text
  # LAST TO FIRST, so every earlier offset stays valid.
  for ($k = $spans.Count - 1; $k -ge 0; $k--) {
    $s0 = $spans[$k][0]; $e0 = $spans[$k][1]
    $block = $out.Substring($s0, $e0 - $s0 + 1)
    if ($block -match '"as_of"\s*:') { $skipped++; continue }
    # indentation of this row's own fields, read from the row rather than assumed
    $im = [regex]::Match($block, '(\r?\n)(\s+)"')
    $nl = if ($im.Success) { $im.Groups[1].Value } else { "`n" }
    $ind = if ($im.Success) { $im.Groups[2].Value } else { '    ' }
    $lastQuote = $block.LastIndexOf('"', $block.Length - 1)
    $ins = ',' + $nl + $ind + '"as_of": "' + $Captured + '"'
    $out = $out.Substring(0, $s0 + $lastQuote + 1) + $ins + $out.Substring($s0 + $lastQuote + 1)
    $stamped++
  }
  return @{ text = $out; stamped = $stamped; skipped = $skipped }
}

# ---------------------------------------------------------------------------------------------------
if ($SelfTest) {
  $bad = 0
  function T([string]$n, [bool]$ok, [string]$got) {
    if ($ok) { Write-Output ('  ok    ' + $n) } else { Write-Output ('  X     ' + $n + '   got: ' + $got); $script:bad++ }
  }
  $doc = @'
{
  "store": "Baker's",
  "captured": "2026-08-26",
  "deals": [
    {
      "store": "Baker's",
      "item": "Thing One",
      "ad_price": "$1.99"
    },
    {
      "store": "Baker's",
      "item": "Thing Two",
      "ad_price": "$2.99",
      "as_of": "2026-08-20"
    }
  ]
}
'@
  $r = Add-RowAsOf -Text $doc -Captured '2026-08-26'
  T 'a row with no as_of is stamped' ($r.stamped -eq 1) ([string]$r.stamped)
  T 'MUST NOT FIRE  a row that already has one is left alone' ($r.skipped -eq 1) ([string]$r.skipped)
  $o = $r.text | ConvertFrom-Json
  T '...and the result still parses' ($null -ne $o) 'unparseable'
  T '...with the same row count' (@($o.deals).Count -eq 2) ([string]@($o.deals).Count)
  T '...the stamped row carries the CAPTURED date' ([string]$o.deals[0].as_of -eq '2026-08-26') ([string]$o.deals[0].as_of)
  T 'MUST NOT FIRE  the pre-dated row keeps ITS date, not the capture date' ([string]$o.deals[1].as_of -eq '2026-08-20') ([string]$o.deals[1].as_of)
  T '...and no other field moved' (([string]$o.deals[0].item -eq 'Thing One') -and ([string]$o.deals[0].ad_price -eq '$1.99')) 'a field changed'

  $again = Add-RowAsOf -Text $r.text -Captured '2026-08-26'
  T 'IDEMPOTENT  a second pass stamps nothing' ($again.stamped -eq 0 -and $again.text -eq $r.text) ([string]$again.stamped)

  $none = Add-RowAsOf -Text '{"store":"X"}' -Captured '2026-08-26'
  T 'MUST NOT FIRE  a document with no deals array is untouched' ($none.stamped -eq 0 -and $none.text -eq '{"store":"X"}') 'changed'

  if ($bad -eq 0) { Write-Output 'stamp-ad-as-of SELF-TEST PASS'; exit 0 }
  Write-Output ("stamp-ad-as-of SELF-TEST FAIL: {0} case(s)" -f $bad); exit 1
}

# ---------------------------------------------------------------------------------------------------
$outDir = if ($Root) { $Root } else { Join-Path $here 'out' }
$files = @(Get-AdDealFiles -OutDir $outDir)
$totalStamped = 0; $refused = @(); $touched = 0

foreach ($f in ($files | Sort-Object FullName)) {
  $raw = [IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8)
  $txt = $raw -replace '^\xEF\xBB\xBF', ''
  $doc = $null
  try { $doc = $txt | ConvertFrom-Json } catch { $refused += ("{0}: does not parse" -f $f.Name); continue }
  $rows = @($doc.deals)
  if (-not $rows.Count) { continue }
  $undated = @($rows | Where-Object { -not $_.as_of }).Count
  if ($undated -eq 0) { continue }

  $cap = ''
  if ($doc.PSObject.Properties['captured'] -and $doc.captured) { $cap = ([string]$doc.captured).Trim() }
  if ($cap -notmatch '^\d{4}-\d{2}-\d{2}$') {
    # UNKNOWN IS NOT A PASS. Deriving the date from the filename would be a freshness number made of
    # the only thing the guard could already see.
    $refused += ("{0}: {1} undated row(s) but the document states no usable `captured` date, so there is nothing honest to stamp them with" -f $f.Name, $undated)
    continue
  }

  $res = Add-RowAsOf -Text $txt -Captured $cap
  if ($res.stamped -le 0) { continue }

  # PROVE IT before writing: re-parse, same row count, and every other field byte-identical.
  $newDoc = $null
  try { $newDoc = $res.text | ConvertFrom-Json } catch { $refused += ("{0}: the edit did not re-parse - nothing written" -f $f.Name); continue }
  if (@($newDoc.deals).Count -ne $rows.Count) {
    $refused += ("{0}: row count would go {1} -> {2} - nothing written" -f $f.Name, $rows.Count, @($newDoc.deals).Count); continue
  }
  $sBefore = @($rows    | ForEach-Object { $_ | Select-Object -Property * -ExcludeProperty as_of | ConvertTo-Json -Depth 8 -Compress })
  $sAfter  = @($newDoc.deals | ForEach-Object { $_ | Select-Object -Property * -ExcludeProperty as_of | ConvertTo-Json -Depth 8 -Compress })
  if (($sBefore -join "`n") -ne ($sAfter -join "`n")) {
    $refused += ("{0}: COLLATERAL - a field other than as_of would change. Nothing written." -f $f.Name); continue
  }

  Write-Output ("  {0,-34} {1} row(s) stamped as_of {2}{3}" -f $f.Name, $res.stamped, $cap,
                $(if ($res.skipped) { " ($($res.skipped) already dated)" } else { '' }))
  $totalStamped += $res.stamped; $touched++
  if ($Apply) {
    [IO.File]::WriteAllText($f.FullName, $res.text, (New-Object System.Text.UTF8Encoding($false)))
  }
}

foreach ($r in $refused) { Write-Output ("  REFUSED  " + $r) }

if (-not $touched -and -not $refused.Count) { Write-Output 'stamp-ad-as-of: every ad row already carries an as_of' }
if (-not $Apply -and $touched) { Write-Output '  DRY RUN - nothing written. Re-run with -Apply.' }

# ONLY A CURRENT FILE FAILING IS A FAILURE. Ten July documents predate the `captured` field and can
# never gain one; exiting non-zero over them would make this red forever and therefore ignored, which
# is the cry-wolf failure the guards in this tree keep documenting. The file the ENGINE prices from is
# the newest per store, so that is the one whose refusal matters.
$currentRefused = @()
foreach ($sub in @('bakers', 'fareway', 'sams')) {
  $d = Join-Path $outDir $sub
  if (-not (Test-Path $d)) { continue }
  $newest = Get-ChildItem (Join-Path $d ($sub + '-deals-*.json')) -File -ErrorAction SilentlyContinue |
            Where-Object { $_.BaseName -match '\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Descending | Select-Object -First 1
  if (-not $newest) { continue }
  foreach ($r in $refused) { if ($r.StartsWith($newest.Name + ':')) { $currentRefused += $r } }
}
if ($currentRefused.Count) {
  Write-Output ("  CURRENT FILE REFUSED - this is the one the engine prices from: " + ($currentRefused -join ' | '))
}
Write-Output ("STAMP-AD-AS-OF-COMPLETE files={0} stamped={1} refused={2} current-refused={3}" -f $touched, $totalStamped, $refused.Count, $currentRefused.Count)
exit $(if ($currentRefused.Count) { 1 } else { 0 })
