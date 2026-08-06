<#
  test-gate-count.ps1 - self-test for the GATE-COUNT block in .github/workflows/daily.yml.

  Extracts the shipped PowerShell between the >>> / <<< GATE-COUNT sentinels out of the YAML and executes
  exactly those lines against fixture responses, so the test reaches the REAL expression rather than a copy
  of it. Same construction as test-log-sidecar-recovery.ps1 and test-proof-freshness.ps1.

  FOUNDING BUG (2026-08-06, case 2 below - this case MUST fire).
    The gate read `$recent = @(Invoke-RestMethod ...)` and then `if ($recent.Count -gt 0) { stand down }`.
    In Windows PowerShell 5.1 Invoke-RestMethod emits a deserialized JSON array as ONE pipeline object
    instead of enumerating it, so @( ) around the CALL yields a 1-element array holding the array - Count 1
    for an empty response just as much as for a full one. The gate therefore stood down unconditionally.
    Measured: daily.yml runs #22 (2026-07-24) through #34 (2026-08-05) all completed in 0.1-0.4 minutes with
    every real step skipped. Thirteen consecutive days where the cloud backup did not exist, all reported
    green, because standing down is a success.

    The tell is subtle on purpose: @($var) where $var already holds the array DOES unroll correctly, so the
    same-looking expression is right in one place and wrong in the other.

  CLEAN TWIN (case 3 - this case MUST NOT fire).
    A real bot commit inside the window must still stand the backup down, or every day becomes a doubled
    ~78-billed-minute run against a 2,000 min/mo free cap. A fix that pages here has broken the feature.

  Exit 0 = all cases pass. Exit 1 = a case failed.
#>
$ErrorActionPreference = 'Stop'
$yml = Join-Path (Split-Path $PSScriptRoot -Parent) '.github\workflows\daily.yml'
if (-not (Test-Path $yml)) { Write-Host ("FAIL: cannot find " + $yml); exit 1 }
$all = Get-Content $yml
$a = ($all | Select-String -Pattern '# >>> GATE-COUNT' | Select-Object -First 1).LineNumber
$b = ($all | Select-String -Pattern '# <<< GATE-COUNT' | Select-Object -First 1).LineNumber
if (-not $a -or -not $b -or $b -le $a) { Write-Host 'FAIL: GATE-COUNT sentinels not found in daily.yml'; exit 1 }
# the YAML indents the run: block; strip the common leading whitespace so it parses as PowerShell
$lines = $all[$a..($b - 2)]
$indent = ($lines | Where-Object { $_.Trim() } | ForEach-Object { $_.Length - $_.TrimStart().Length } | Measure-Object -Minimum).Minimum
$block = (($lines | ForEach-Object { if ($_.Length -ge $indent) { $_.Substring($indent) } else { $_ } }) -join "`r`n")

$fails = @()
function Check($name, $cond, $detail) {
  if ($cond) { Write-Host ("  ok   " + $name) } else { Write-Host ("  FAIL " + $name + " :: " + $detail); $script:fails += $name }
}
function CountFor($resp) {
  # run the SHIPPED block with $resp bound, and hand back what it computed into $commitCount
  $sb = [scriptblock]::Create($block + "`r`n" + '$commitCount')
  return (& $sb)
}
# fixtures mirror what Invoke-RestMethod actually hands back, measured against the live API on 2026-08-06
$commit = [pscustomobject]@{ sha = 'deadbee'; commit = [pscustomobject]@{ author = [pscustomobject]@{ date = '2026-08-06T14:00:00Z' } } }

# ---- CASE 1: the API threw and the catch left $resp $null -> fail OPEN (run the backup).
$resp = $null
Check 'case 1 API error fails open (count 0 -> the backup runs)' ((CountFor $null) -eq 0) ('got ' + (CountFor $null))

# ---- CASE 2: FOUNDING BUG. Empty JSON array = no bot commit in the window. MUST count 0 so the backup runs.
$empty = New-Object System.Object[] 0
Check 'case 2 founding bug: empty response counts 0, backup RUNS' ((CountFor $empty) -eq 0) ('got ' + (CountFor $empty) + ' - the gate would stand down with no bot commit')

# ---- CASE 3: CLEAN TWIN. A real bot commit landed -> must still stand down.
$one = [System.Object[]]@($commit)
Check 'case 3 clean twin: a real bot commit still stands the backup down' ((CountFor $one) -ge 1) ('got ' + (CountFor $one))
$three = [System.Object[]]@($commit, $commit, $commit)
Check 'case 3b several commits also stand down' ((CountFor $three) -ge 1) ('got ' + (CountFor $three))

# ---- CASE 4: a non-commit payload (API error object shaped like {message,...}) must not pass as a commit.
$errObj = [pscustomobject]@{ message = 'Bad credentials'; documentation_url = 'https://docs.github.com' }
Check 'case 4 an API error object does not count as a commit' ((CountFor $errObj) -eq 0) ('got ' + (CountFor $errObj))

# ---- CASE 5: the founding FORM must never come back. Wrapping the CALL is wrong everywhere in 5.1.
#      Comment lines are excluded on purpose: the fix's own comment quotes the broken form to explain it,
#      and a test that cannot tell code from prose would force the explanation to be deleted.
$codeOnly = (Get-Content $yml | Where-Object { $_.TrimStart() -notlike '#*' }) -join "`n"
Check 'case 5 daily.yml never wraps the CALL in @( )' (-not ($codeOnly -match '@\(\s*Invoke-RestMethod')) 'a non-comment line wraps the call - assign to a variable first, then count'

if ($fails.Count -eq 0) { Write-Host 'GATE-COUNT: all cases pass.'; exit 0 }
Write-Host ("GATE-COUNT: " + $fails.Count + " case(s) FAILED: " + ($fails -join ', ')); exit 1
