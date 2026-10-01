# test-rescue-owed-lib.ps1 - fixtures for rescue-owed-lib.ps1 and its hook in capture-policy-lib's Get-CaptureWorklist.
# Hermetic: a temp out dir and a temp stores file per run; the one integration case reads the committed stores.json and
# commodity-search.json through capture-policy-lib, as the worklist itself does. Exit 0 only when every case passes;
# the last line is the verdict.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'capture-policy-lib.ps1')     # loads rescue-owed-lib.ps1 through its sibling-lib line
$script:fail = 0; $script:ran = 0
$script:scratch = Join-Path ([IO.Path]::GetTempPath()) ('rsq-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
function Assert-Case([string]$Name, [bool]$Ok, [string]$Got) {
  $script:ran++
  if ($Ok) { Write-Output ('  ok    ' + $Name) } else { Write-Output ('  FAIL  ' + $Name + ' (got: ' + $Got + ')'); $script:fail++ }
}
function New-RsqDir([string]$Name) {
  $d = Join-Path $script:scratch $Name
  New-Item -ItemType Directory -Path $d -ErrorAction Stop | Out-Null
  return $d
}
function Write-RsqFile([string]$Path, [string[]]$Lines) {
  [IO.File]::WriteAllText($Path, (($Lines -join "`n") + "`n"), (New-Object Text.UTF8Encoding($false)))
}
function Write-RsqRescue([string]$Dir, [string]$UrlKey, [string]$AsOf, [string[]]$Rows) {
  $hdr = @('# rescue worklist for X - the terms to search FIRST on the next browser pass',
           ('# generated ' + $AsOf + ' 08:41  as-of ' + $AsOf + '  board comparison-' + $AsOf),
           '# columns: term<TAB>commodityId<TAB>section<TAB>detail')
  Write-RsqFile (Join-Path $Dir ('rescue-terms-' + $UrlKey + '.txt')) (@($hdr) + @($Rows))
}
$T = "`t"
try {
  New-Item -ItemType Directory -Path $script:scratch -ErrorAction Stop | Out-Null
  $stores = Join-Path $script:scratch 'stores.json'
  Write-RsqFile $stores @('{"stores":[{"name":"Mart","urlkey":"mart","walled":true},{"name":"Open","urlkey":"open","walled":false}]}')
  $all = @([pscustomobject]@{ id = 'horseradish'; term = 'prepared horseradish' },
           [pscustomobject]@{ id = 'chicken-breast'; term = 'boneless skinless chicken breast' },
           [pscustomobject]@{ id = 'chicken-breast'; term = 'chicken breast' },
           [pscustomobject]@{ id = 'teriyaki-sauce'; term = 'teriyaki sauce' })
  $rows = @(('prepared horseradish' + $T + 'horseradish' + $T + 'DROPPED' + $T + 'gone from comparison'),
            ('boneless skinless chicken breast' + $T + 'chicken-breast' + $T + 'UNTRACEABLE' + $T + 'no capture on disk'))

  # MUST FIRE: the founding gap (2026-10-01). A current list (as-of exactly 1 day before today, AT the 1-day bar) names
  # a DROPPED and an UNTRACEABLE cell, and the worklist must lead with every catalogue term of both commodities.
  $d1 = New-RsqDir 'atbar'
  Write-RsqRescue $d1 'mart' '2026-10-01' $rows
  $r = Select-TcRescueTerms -Store 'Mart' -OutDir $d1 -Today '2026-10-02' -All $all -SkipIds @() -Room 10 -StoresFile $stores
  $got = (@($r.Terms) | ForEach-Object { $_.term }) -join ','
  Assert-Case 'MUST FIRE a list as-of 1 day before today (AT the 1-day bar) leads with all 3 terms of its 2 commodities' `
    ((@($r.Terms).Count -eq 3) -and (-not $r.Blind) -and ($got -match 'prepared horseradish') -and ($got -match '(^|,)chicken breast')) $got

  # MUST NOT FIRE: one step PAST the bar. A list as-of 2 days before today is stale: nothing leads, and it says why.
  $d2 = New-RsqDir 'pastbar'
  Write-RsqRescue $d2 'mart' '2026-09-30' $rows
  $r = Select-TcRescueTerms -Store 'Mart' -OutDir $d2 -Today '2026-10-02' -All $all -SkipIds @() -Room 10 -StoresFile $stores
  Assert-Case 'MUST NOT FIRE a list as-of 2 days before today (one step PAST the bar) leads nothing and reads blind' `
    ((@($r.Terms).Count -eq 0) -and $r.Blind -and ($r.Why -match 'as-of 2026-09-30')) ("terms=$(@($r.Terms).Count) blind=$($r.Blind) why=$($r.Why)")

  # MUST NOT FIRE: a list dated AFTER today (a clock or fixture slip) is not current either.
  $r = Select-TcRescueTerms -Store 'Mart' -OutDir $d1 -Today '2026-09-30' -All $all -SkipIds @() -Room 10 -StoresFile $stores
  Assert-Case 'MUST NOT FIRE a list as-of a day AFTER today leads nothing and reads blind' ((@($r.Terms).Count -eq 0) -and $r.Blind) ("terms=$(@($r.Terms).Count) blind=$($r.Blind)")

  # MUST NOT FIRE: a store that is not walled has no rescue list by design, and that is not a could-not-look.
  $r = Select-TcRescueTerms -Store 'Open' -OutDir $d1 -Today '2026-10-02' -All $all -SkipIds @() -Room 10 -StoresFile $stores
  Assert-Case 'MUST NOT FIRE a non-walled store leads nothing and is NOT blind' ((@($r.Terms).Count -eq 0) -and (-not $r.Blind)) ("blind=$($r.Blind) why=$($r.Why)")

  # MUST FIRE: a walled store whose list is missing is a could-not-look: blind, said, nothing invented.
  $d3 = New-RsqDir 'missing'
  $r = Select-TcRescueTerms -Store 'Mart' -OutDir $d3 -Today '2026-10-02' -All $all -SkipIds @() -Room 10 -StoresFile $stores
  Assert-Case 'MUST FIRE a walled store with no rescue file reads blind and leads nothing' ((@($r.Terms).Count -eq 0) -and $r.Blind -and ($r.Why -match 'no rescue-terms-mart')) $r.Why

  # CLEAN TWIN: the room is respected per COMMODITY. Room 2 takes horseradish (1 term), DEFERS chicken-breast (2 terms,
  # would make 3) whole rather than half-asking it, and still takes teriyaki (1 term) after it.
  $d4 = New-RsqDir 'room'
  Write-RsqRescue $d4 'mart' '2026-10-02' (@($rows) + @('teriyaki sauce' + $T + 'teriyaki-sauce' + $T + 'DROPPED' + $T + 'gone'))
  $r = Select-TcRescueTerms -Store 'Mart' -OutDir $d4 -Today '2026-10-02' -All $all -SkipIds @() -Room 2 -StoresFile $stores
  $got = (@($r.Terms) | ForEach-Object { $_.id }) -join ','
  Assert-Case 'CLEAN TWIN room 2: horseradish and teriyaki taken, chicken-breast (2 terms) deferred whole, never half-asked' `
    (($got -eq 'horseradish,teriyaki-sauce') -and ($r.Deferred -eq 1)) ("ids=$got deferred=$($r.Deferred)")

  # CLEAN TWIN: an id the price-flag verifications already lead with is not asked twice.
  $r = Select-TcRescueTerms -Store 'Mart' -OutDir $d1 -Today '2026-10-02' -All $all -SkipIds @('horseradish') -Room 10 -StoresFile $stores
  $got = (@($r.Terms) | ForEach-Object { $_.id } | Select-Object -Unique) -join ','
  Assert-Case 'CLEAN TWIN an id already led by the verifications (SkipIds) is not added again' ($got -eq 'chicken-breast') $got

  # MUST FIRE, through the real worklist: Get-CaptureWorklist + Write-CaptureWorklist for Walmart, with a current rescue
  # list naming horseradish, put "prepared horseradish" in `terms` with its commodity at the same index, and in rescue_terms.
  $d5 = New-RsqDir 'worklist'
  Write-RsqRescue $d5 'walmart' '2026-10-02' @('prepared horseradish' + $T + 'horseradish' + $T + 'DROPPED' + $T + 'gone')
  $wf = Write-CaptureWorklist -Store 'Walmart' -Today '2026-10-02' -OutDir $d5
  $wj = ConvertFrom-Json ([IO.File]::ReadAllText($wf))
  $ix = [array]::IndexOf(@($wj.terms), 'prepared horseradish')
  Assert-Case 'MUST FIRE the Walmart worklist file carries the rescue term in terms (commodity at the same index) and rescue_terms' `
    (($ix -ge 0) -and (@($wj.commodities)[$ix] -eq 'horseradish') -and (@($wj.rescue_terms) -contains 'prepared horseradish') -and ($wj.rescue_blind -eq $false)) `
    ("index=$ix rescue_terms=$(@($wj.rescue_terms) -join ',') why=$($wj.rescue_why)")
} catch {
  Write-Output ('  FAIL  unexpected error: ' + $_.Exception.Message); $script:fail++
} finally {
  if ($script:scratch -and (Test-Path -LiteralPath $script:scratch)) { Remove-Item -LiteralPath $script:scratch -Recurse -Force }
}
$want = 8
if ($script:ran -ne $want) { Write-Output ('  FAIL  ran ' + $script:ran + ' case(s), expected ' + $want); $script:fail++ }
if ($script:fail -eq 0) { Write-Output ('test-rescue-owed-lib self-test pass (' + $script:ran + ' cases)'); exit 0 }
Write-Output ('test-rescue-owed-lib self-test FAIL (' + $script:fail + ' of ' + $script:ran + ')'); exit 1
