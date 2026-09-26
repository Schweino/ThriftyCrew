# trend-publish-key.ps1 - WHEN a price-tracker page must be republished: when what it SHOWS changed, never when the
# ad week did (2026-09-26, Brad's D3 in design\PLAN-board-clock-2026-09-26.md).
#
# WHY. publish-deals-page and publish-trend-pages gated the tracker on the newest week_of in price-history.json.
# week_of is the AD SET's date, and update-history banks every daily rebuild under it, so a price that moved on
# Thursday re-banked under Wednesday's week and the gate said "already published for this week": the 20 /<id>-price-omaha/
# pages showed the first build of each ad week until the next ad dropped, and /omaha-price-tracker/, which rides the
# same branch, read updated 2026-09-05 on 2026-09-25 (grocery/triage-plans/plan-2026-09-25-6.json item 30, residual
# 2026-09-25-22b1e8). Two keys replace it, one per question, each in ONE place so the two gates cannot drift - the
# spot this replaces already records one such drift ("EXACT same week derivation ... A PATH THAT DOES NOT EXIST"):
#
#   Get-TcTrendInputKey   'sha1:<hex>' of price-history.json's bytes: did ANY tracked price move since the last full,
#                         clean publish? publish-deals-page skips the builds when it equals the stamp.
#   Get-TcTrendPageHash   'sha1:<hex>' of what ONE page renders (fragment, title, excerpt, meta): publish-trend-pages
#                         upserts a page only when this differs from the hash it recorded for that slug.
#
# NO param() BLOCK, DELIBERATELY - dot-sourced under PS 5.1 a param() block runs in the CALLER's scope and would reset
# the caller's own -SelfTest. Same rule as lib\append-line.ps1.
# Self-test:   powershell -File lib\trend-publish-key.ps1 -SelfTest
# WHAT THE SELF-TEST READS: strings in memory, and one file it writes to a per-run temp directory.
# gate-inputs: lib\trend-publish-key.ps1

$__tpkSelfTest = ($MyInvocation.InvocationName -ne '.') -and ($args -contains '-SelfTest')

function Get-TcSha1Hex([byte[]]$Bytes) {
  $sha = [Security.Cryptography.SHA1]::Create()
  try { return (([BitConverter]::ToString($sha.ComputeHash($Bytes))) -replace '-', '').ToLowerInvariant() } finally { $sha.Dispose() }
}

# '' when the file is missing: an unknown input is never a key that could match a stamp.
function Get-TcTrendInputKey([string]$HistoryFile) {
  if (-not $HistoryFile -or -not [IO.File]::Exists($HistoryFile)) { return '' }
  return ('sha1:' + (Get-TcSha1Hex ([IO.File]::ReadAllBytes($HistoryFile))))
}

# Every field a reader sees on the page, joined by a separator no field can contain unescaped. The price is in the title
# fields and the excerpt as well as the fragment, so a change to any of them is a change to the page.
function Get-TcTrendPageHash([string]$Html, [string]$Title, [string]$Excerpt, [string]$MetaTitle, [string]$MetaDesc) {
  $sep = [string][char]0x1F
  $text = (@($Html, $Title, $Excerpt, $MetaTitle, $MetaDesc) | ForEach-Object { [string]$_ }) -join $sep
  return ('sha1:' + (Get-TcSha1Hex ([Text.Encoding]::UTF8.GetBytes($text))))
}

if ($__tpkSelfTest) {
  $ErrorActionPreference = 'Stop'
  $script:tpkCases = 0; $script:tpkFailed = 0
  function Test-TpkCase([string]$Label, [bool]$Ok, [string]$Got) {
    $script:tpkCases++
    if ($Ok) { Write-Output ('  ok    ' + $Label) } else { $script:tpkFailed++; Write-Output ('  FAIL  ' + $Label + '   got: ' + $Got) }
  }
  $dir = Join-Path $env:TEMP ('tpk-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
  try {
    New-Item -ItemType Directory -Path $dir -ErrorAction Stop | Out-Null
    $h = Join-Path $dir 'price-history.json'
    # THE FOUNDING SHAPE: the same week_of, a different price. The old gate compared the week and saw no change.
    [IO.File]::WriteAllText($h, '{"commodities":[{"id":"eggs","history":[{"week_of":"2026-09-23","cheapest_price":2.49}]}]}', (New-Object Text.UTF8Encoding($false)))
    $k1 = Get-TcTrendInputKey $h
    [IO.File]::WriteAllText($h, '{"commodities":[{"id":"eggs","history":[{"week_of":"2026-09-23","cheapest_price":2.19}]}]}', (New-Object Text.UTF8Encoding($false)))
    $k2 = Get-TcTrendInputKey $h
    Test-TpkCase 'MUST FIRE  a price that moved under the SAME week_of changes the input key (the week gate saw nothing)' ($k1 -and $k2 -and $k1 -ne $k2) "$k1 vs $k2"
    Test-TpkCase 'CLEAN TWIN  the same bytes give the same key, so a day with no price move still skips the builds' ((Get-TcTrendInputKey $h) -eq $k2) 'differs'
    Test-TpkCase 'MUST NOT FIRE  a missing history file gives an empty key, which can never equal a stamp' ((Get-TcTrendInputKey (Join-Path $dir 'nope.json')) -eq '') 'not empty'
    $p1 = Get-TcTrendPageHash '<p>$2.49</p>' 'Eggs Price in Omaha This Week' 'This week: $2.49' 'mt' 'md'
    $p2 = Get-TcTrendPageHash '<p>$2.49</p>' 'Eggs Price in Omaha This Week' 'This week: $2.19' 'mt' 'md'
    Test-TpkCase 'MUST FIRE  a page whose excerpt price moved (fragment unchanged) is a changed page' ($p1 -ne $p2) 'same'
    Test-TpkCase 'CLEAN TWIN  an identical page hashes identically, so it is not republished' ($p1 -eq (Get-TcTrendPageHash '<p>$2.49</p>' 'Eggs Price in Omaha This Week' 'This week: $2.49' 'mt' 'md')) 'differs'
    Test-TpkCase 'MUST FIRE  moving text between two fields is a different page (the fields are separated, not concatenated)' ((Get-TcTrendPageHash 'ab' 'c' '' '' '') -ne (Get-TcTrendPageHash 'a' 'bc' '' '' '')) 'same'
  } catch {
    Test-TpkCase 'the self-test ran to its end with no unexpected error' $false ($_.Exception.Message + ' line ' + $_.InvocationInfo.ScriptLineNumber)
  } finally {
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
  }
  $want = 6
  if ($script:tpkCases -ne $want) { Write-Output ('  FAIL  the suite ran ' + $script:tpkCases + ' case(s), not the ' + $want + ' it lists'); $script:tpkFailed++ }
  if ($script:tpkFailed) { Write-Output ('trend-publish-key SELF-TEST FAIL (' + $script:tpkFailed + ' of ' + $script:tpkCases + ')'); exit 1 }
  Write-Output ('trend-publish-key SELF-TEST PASS (' + $script:tpkCases + ' cases)')
  exit 0
}
