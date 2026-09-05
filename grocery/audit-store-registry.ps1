<#
  audit-store-registry.ps1 - drift guard for the canonical store registry (stores.json).

  THE BUG CLASS THIS CATCHES: a store is added to the board but a script's hardcoded store list is
  missed, so that store silently drops out of ONE surface while every other surface carries it.
  Real instances: build-store-guide excluded Fareway 07-12..07-26; publish-store-guide's and
  publish-deals-page's coverage GATES never checked Fareway; build-trend-pages' visible footer
  named only 6 stores.

  CHECKS
    1. stores.json parses; names + orders + regular_prefixes unique.
    2. The newest out\comparison-*.json store set EQUALS the registry set (both directions).
    3. Every out\regular\<prefix>-regular-*.json prefix is a registered regular_prefix.
    4. Every store in ad-schedule.json is registered.
    5. CODE SCAN: every non-comment STATEMENT in a live grocery .ps1 that names >= 3 registry stores
       must name ALL of them, unless it matches an entry in stores.json allowed_subsets.
       (Names are matched with both ' and the &#39; entity so site-copy strings are scanned too.)

       STATEMENT-scoped, not line-scoped (2026-08-30, queue 2026-08-22-2c3e88). It used to read one
       LINE at a time, so a complete 7-store map wrapped across two source lines reported each half as
       missing the other half's stores. Two live maps were shaped exactly that way -
       derive-not-carried.ps1's $STORE_PREFIX and price-table-lib.ps1's $script:PT_SLUG - and they
       produced FOUR of the fourteen code findings, purely from where the author pressed Enter. The
       count grew every time a line wrapped, and a drift guard that is permanently red on correct code
       teaches its reader to ignore it (the same reasoning as the escaped-quote fix below).
       A flagged line is now widened to the smallest multi-line hashtable or array literal that
       ENCLOSES it before the verdict. Deliberately only literals: widening to the enclosing block or
       script would let any file that mentions all 7 stores anywhere excuse every hardcoded list in it.
    6. ORPHANED EXEMPTIONS: every allowed_subsets entry must still resolve - its file must exist and its
       `contains` needle must still appear in that file. The register that silences check 5 was itself
       unaudited until 2026-09-05, and four of its thirty entries had already gone dead (queue 2026-09-05-17ebe3).

  Exit 0 = clean, 2 = drift found (advisory in the daily pipeline: alert, don't block).
  Params: -Alert (send-alert on drift, de-duped by signature), -SelfTest (frozen fixtures in %TEMP%)
#>
param([switch]$Alert, [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\guard-contract.ps1')
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
# Alerts go out through Send-Alert (alert-lib.ps1), never as `powershell -File send-alert.ps1 -Body $long`:
# Windows refuses to start a process whose command line passes 32767 chars, so an oversized body did not
# arrive truncated - it did not arrive at all, and the launch error read like the CHECK had crashed. Three
# consecutive guard-blind days went unpaged that way on 2026-08-03/04/05. See alert-lib.ps1.
. (Join-Path $root 'alert-lib.ps1')
$OutDir = Join-Path $root 'out'
$issues = New-Object System.Collections.Generic.List[string]

# ---- 1. registry sanity ----
$reg = Get-Content (Join-Path $root 'stores.json') -Raw | ConvertFrom-Json
$names = @($reg.stores | Sort-Object { [int]$_.order } | ForEach-Object { [string]$_.name })
foreach ($grp in @('name','order','regular_prefix')) {
  $dup = @($reg.stores | Group-Object $grp | Where-Object { $_.Count -gt 1 })
  foreach ($d in $dup) { $issues.Add("registry: duplicate $grp '" + $d.Name + "'") }
}

# ---- 2. newest comparison vs registry ----
$cmpF = Get-ChildItem (Join-Path $OutDir 'comparison-*.json') -EA SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
if ($cmpF) {
  $doc = Get-Content $cmpF.FullName -Raw | ConvertFrom-Json
  $seen = @{}
  foreach ($r in $doc.comparison) { foreach ($st in $r.stores) { $seen[[string]$st.store] = $true } }
  foreach ($s in $seen.Keys)  { if ($names -notcontains $s) { $issues.Add("board: store '$s' is on the board but NOT in stores.json") } }
  foreach ($s in $names)      { if (-not $seen.ContainsKey($s)) { $issues.Add("board: registered store '$s' has ZERO cells on the newest board ($($cmpF.Name))") } }
}

# ---- 3. out\regular prefixes ----
# PROMOTED prefixes count too (2026-08-30). Not every file under out\regular is a store PULL: the Recipe
# Hunter promotion lane writes hunter-<store>-regular-<date>.json from adjudicated ingredient rulings, and
# live builds READ them (input-usage.json: hunter-walmart uses=5, last_used the 2026-08-26 build). They
# paged here daily for two weeks as unregistered strays, which is how a producer nobody registered starts
# looking like litter someone should delete - and deleting them would have dropped adjudicated cells.
# Registered in stores.json promoted_prefixes, with the producer named, rather than special-cased here.
$prefixes = @($reg.stores | ForEach-Object { [string]$_.regular_prefix }) +
            @($reg.promoted_prefixes | ForEach-Object { [string]$_.prefix })
foreach ($f in (Get-ChildItem (Join-Path $OutDir 'regular\*-regular-*.json') -EA SilentlyContinue)) {
  $p = $f.BaseName -replace '-regular-.*$',''
  if ($prefixes -notcontains $p) { $issues.Add("out\regular: file prefix '$p' ($($f.Name)) is not a registered regular_prefix or promoted_prefix") }
}

# ---- 4. ad-schedule ----
$schedF = Join-Path $root 'ad-schedule.json'
if (Test-Path $schedF) {
  $sched = Get-Content $schedF -Raw | ConvertFrom-Json
  foreach ($s in $sched.stores) { $sn = [string]$s.store; if ($sn -and ($names -notcontains $sn)) { $issues.Add("ad-schedule.json: store '$sn' is not in stores.json") } }
}

# ---- 5. code scan (live scripts only; archive/, out/, brands/ excluded) ----
function Get-StoreNamesIn([string]$text, [string[]]$Names) {
  # Returns @{ hit = <int>; missing = @(...) } for one chunk of source.
  # The PowerShell-escaped form ("Baker''s" inside a single-quoted string) has to be in here: this
  # scanner reads .ps1 source, so '' is the MOST likely way a store name appears, and it was the one
  # variant missing. test-auditors.ps1 seeds all 7 stores into a fixture on one line, five of them
  # plainly and Baker's/Sam's Club escaped - so the guard reported "names 5 store(s) but is missing
  # Baker's, Sam's Club" against a line that names every store. A drift guard that is permanently red
  # on correct code teaches people to ignore it, which is worse than not having it.
  $hit = 0; $missing = @()
  foreach ($n in $Names) {
    $variants = @($n, ($n -replace "'", "''"), ($n -replace "'", '&#39;'), ($n -replace "'", '&rsquo;'))
    $found = $false
    foreach ($v in $variants) { if ($text.IndexOf($v, [StringComparison]::Ordinal) -ge 0) { $found = $true; break } }
    if ($found) { $hit++ } else { $missing += $n }
  }
  return @{ hit = $hit; missing = $missing }
}

function Get-StoreListDrift {
  <#
    .SYNOPSIS Store-list drift findings for ONE .ps1 file, statement-scoped.
    .DESCRIPTION Separated out on 2026-08-30 so the frozen fixtures below can drive the real scanner
                 instead of a copy of it - a check whose test exercises a paraphrase of the code is the
                 two-copies-of-a-rule trap, and this file is a guard.
  #>
  param([string]$Path, [string]$FileLabel, [string[]]$Names, $Subsets)
  $found = New-Object System.Collections.Generic.List[string]

  # The multi-line LITERALS in this file, smallest first. A hashtable or array spelled across several
  # lines is ONE store list no matter where the newlines fall; anything larger (a block, a function, the
  # script) is not, and widening to it would excuse real drift.
  $tk = $null; $pe = $null
  $units = @()
  try {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tk, [ref]$pe)
    if ($ast) {
      $units = @($ast.FindAll({ param($n)
          ($n -is [System.Management.Automation.Language.HashtableAst]) -or
          ($n -is [System.Management.Automation.Language.ArrayExpressionAst]) -or
          ($n -is [System.Management.Automation.Language.ArrayLiteralAst]) }, $true) |
        Where-Object { $_.Extent.EndLineNumber -gt $_.Extent.StartLineNumber })
    }
  } catch { $units = @() }   # an unparseable file falls back to the old line scan; it never goes silent

  $reported = @{}
  $ln = 0; $inBlock = $false
  foreach ($line in [IO.File]::ReadAllLines($Path)) {
    $ln++
    $t = $line.TrimStart()
    if ($inBlock) { if ($t -match '#>') { $inBlock = $false }; continue }   # block-comment prose
    if ($t.StartsWith('<#')) { if ($t -notmatch '#>') { $inBlock = $true }; continue }
    if ($t.StartsWith('#')) { continue }                       # pure comment lines are prose, not behavior
    $idx = $line.IndexOf(' # '); $code = if ($idx -ge 0) { $line.Substring(0, $idx) } else { $line }
    $r = Get-StoreNamesIn $code $Names
    if ($r.hit -lt 3 -or $r.missing.Count -eq 0) { continue }

    # WIDEN to the smallest enclosing multi-line literal, then re-ask. This is the whole fix: the two
    # halves of one wrapped map now answer as the map.
    $scopeText = $code; $scopeLine = $ln
    $u = @($units | Where-Object { $ln -ge $_.Extent.StartLineNumber -and $ln -le $_.Extent.EndLineNumber } |
           Sort-Object { $_.Extent.EndLineNumber - $_.Extent.StartLineNumber } | Select-Object -First 1)
    if ($u.Count -gt 0) {
      $scopeText = $u[0].Extent.Text
      $scopeLine = $u[0].Extent.StartLineNumber
      $r = Get-StoreNamesIn $scopeText $Names
      if ($r.hit -lt 3 -or $r.missing.Count -eq 0) { continue }   # the complete map: not drift, never was
      if ($reported.ContainsKey($scopeLine)) { continue }         # one finding per statement, not per line
    }

    # MATCH AGAINST BOTH the widened statement AND the original line. Every allowed_subsets entry written
    # before 2026-08-30 was authored against a LINE, and a hashtable's AST extent starts at '@{' - so an
    # entry whose `contains` includes the assignment prefix ("$hostOf = @{") is not a substring of the
    # widened text. Widening the scope must not quietly invalidate a documented subset; it only ever adds
    # a second place to match.
    $allowed = $false
    foreach ($as in $Subsets) {
      if ($FileLabel -ne [string]$as.file) { continue }
      $needle = [string]$as.contains
      if (($scopeText.IndexOf($needle, [StringComparison]::Ordinal) -ge 0) -or
          ($code.IndexOf($needle, [StringComparison]::Ordinal) -ge 0)) { $allowed = $true; break }
    }
    if ($allowed) { continue }
    $reported[$scopeLine] = $true
    $msg = ("code: {0}:{1} names {2} store(s) but is missing {3}" -f $FileLabel, $scopeLine, $r.hit, ($r.missing -join ', '))
    # UNREGISTERED-FIXTURE HINT (2026-09-03, queue 2026-09-03-494974). A code-scanning guard cannot tell a
    # policy list from test data that happens to name stores, so every must-fire and clean-twin fixture
    # written for it becomes a finding against itself. allowed_subsets is the register for that, it is
    # maintained by hand, and it therefore lags each new fixture by exactly one alert - this was the fifth
    # instance of the shape. So when a finding sits inside a STRING LITERAL in a test- or measure- file,
    # say so and hand over the entry to paste. The finding still COUNTS and is never suppressed: this only
    # appends guidance, so the issue count is identical with and without it.
    $isLiteral = ($u.Count -gt 0 -and (
                    $u[0] -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
                    $u[0] -is [System.Management.Automation.Language.ExpandableStringExpressionAst])) -or
                 ($code -match "=\s*['""]")
    if ($isLiteral -and $FileLabel -match '^(test|measure)-') {
      $msg += ("`n        HINT: this looks like an UNREGISTERED FIXTURE, not a hardcoded store list - it sits inside a string literal in a $($Matches[1])- file. If the subset is legitimate (the region under test does not branch on store), register it rather than editing the fixture; a frozen fixture edited to quiet a different guard is how a watcher goes blind. Paste into stores.json allowed_subsets:" +
               "`n          { `"file`": `"$FileLabel`", `"contains`": `"<a stable substring from INSIDE the literal, not the assignment prefix>`", `"reason`": `"<why this subset proves the contract for all 7 - name the region under test and show it never branches on store>`" }")
    }
    [void]$found.Add($msg)
  }
  return $found
}

# ---- 6. ORPHANED EXEMPTIONS (2026-09-05, queue 2026-09-05-17ebe3) --------------------------------------
# allowed_subsets is a PERMANENT exemption register that nothing audited. An entry outlives the deletion of
# the file it names and the rewrite of the literal it points at, and then it is one of two things: dead
# weight, or - if a later edit makes its needle a substring of something broader - a blanket silencer over a
# genuinely hardcoded roster. That is [[rules-that-silently-disarm]] aimed at the register instead of the rule.
# MEASURED on 2026-09-05: FOUR of the thirty entries were already dead, two of them naming scripts that were
# retired on 2026-08-22, and nothing anywhere said so. An exemption is a standing decision, and a standing
# decision that no longer applies to anything has to be able to say so out loud.
# The residual hazard this CANNOT see is the opposite one: a needle that still matches, but now matches a
# broader literal than the one it was written for. That is what the 'reason' field is for - name the region
# under test and why the subset is legitimate, so a reviewer can tell.
function Get-OrphanedExemptions {
  <#
    .SYNOPSIS  allowed_subsets entries that can no longer match the thing they were written to exempt.
    .DESCRIPTION Separated out so -SelfTest drives the real resolver rather than a paraphrase of it; this
                 file is a guard, and a guard whose test exercises a copy of its logic tests the copy.
  #>
  param($Subsets, [string]$Dir)
  $found = New-Object System.Collections.Generic.List[string]
  foreach ($as in @($Subsets)) {
    $file = [string]$as.file
    $needle = [string]$as.contains
    if (-not $file) { [void]$found.Add("allowed_subsets: an entry names no 'file' - it can never match and can never be reviewed"); continue }
    $p = Join-Path $Dir $file
    if (-not (Test-Path $p)) { [void]$found.Add("ORPHANED EXEMPTION (file gone): allowed_subsets exempts a line in '$file', which no longer exists - delete the entry"); continue }
    # An EMPTY needle is worse than a dead one: IndexOf('') is 0, so the entry would silence every subset in
    # that file forever. Refuse to treat it as a documented subset.
    if (-not $needle) { [void]$found.Add("ORPHANED EXEMPTION (empty needle): the entry for '$file' has no 'contains', so it would silence EVERY store-list subset in that file"); continue }
    if ([IO.File]::ReadAllText($p).IndexOf($needle, [StringComparison]::Ordinal) -lt 0) {
      [void]$found.Add("ORPHANED EXEMPTION (needle absent): the allowed_subsets entry for '$file' matches nothing there any more - its 'contains' is: " + $needle)
    }
  }
  return $found
}

if ($SelfTest) {
  # FROZEN FIXTURES, written from the real failing shape and its real clean twin. Never regenerated from
  # the live tree: the wrapped map this encodes would be reformatted one day and the test would pass by
  # finding nothing.
  $fail = 0
  $fx = Join-Path $env:TEMP ('asr-selftest-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $fx -Force | Out-Null
  $fxNames = @('Hy-Vee','Aldi','Family Fare','Fareway',"Baker's","Sam's Club",'Walmart')
  try {
    # CLEAN TWIN: derive-not-carried.ps1's real $STORE_PREFIX map, verbatim, all seven stores, wrapped
    # across two lines. Line-scoped this produced two findings; statement-scoped it must produce none.
    $twin = Join-Path $fx 'twin.ps1'
    Set-Content $twin -Encoding UTF8 -Value @(
      '$STORE_PREFIX = [ordered]@{',
      "  'Aldi' = 'aldi-regular'; ""Baker's"" = 'bakers-regular'; 'Family Fare' = 'family-fare-regular'",
      "  'Fareway' = 'fareway-regular'; 'Hy-Vee' = 'hyvee-regular'; ""Sam's Club"" = 'sams-regular'; 'Walmart' = 'walmart-regular'",
      '}')
    $tw = @(Get-StoreListDrift -Path $twin -FileLabel 'twin.ps1' -Names $fxNames -Subsets @())
    if ($tw.Count -ne 0) { Write-Output ("FAIL  a complete 7-store map wrapped across 2 lines still reports drift: " + ($tw -join ' | ')); $fail++ }
    else { Write-Output 'ok    a complete 7-store map wrapped across lines is silent' }

    # MUST FIRE: the founding bug class. A one-line list that genuinely omits a store.
    $bad = Join-Path $fx 'bad.ps1'
    Set-Content $bad -Encoding UTF8 -Value "`$STORES = @('Hy-Vee', 'Aldi', 'Family Fare', 'Fareway', ""Baker's"")"
    $bd = @(Get-StoreListDrift -Path $bad -FileLabel 'bad.ps1' -Names $fxNames -Subsets @())
    if ($bd.Count -ne 1 -or $bd[0] -notmatch "Sam's Club" -or $bd[0] -notmatch 'Walmart') {
      Write-Output ("FAIL  a one-line list missing 2 stores was not caught: " + ($bd -join ' | ')); $fail++
    } else { Write-Output 'ok    a one-line list missing Sam''s Club and Walmart still fires' }

    # MUST FIRE ACROSS LINES TOO: widening must not become a blanket excuse. A wrapped map that really
    # is missing a store has to stay a finding, reported once at the statement's first line.
    $badWrap = Join-Path $fx 'badwrap.ps1'
    Set-Content $badWrap -Encoding UTF8 -Value @(
      '$MAP = @{',
      "  'Hy-Vee' = 1; 'Aldi' = 2; 'Family Fare' = 3",
      "  'Fareway' = 4; ""Baker's"" = 5; ""Sam's Club"" = 6",
      '}')
    $bw = @(Get-StoreListDrift -Path $badWrap -FileLabel 'badwrap.ps1' -Names $fxNames -Subsets @())
    if ($bw.Count -ne 1 -or $bw[0] -notmatch 'Walmart' -or $bw[0] -notmatch 'badwrap\.ps1:1') {
      Write-Output ("FAIL  a wrapped map genuinely missing Walmart was not reported once at its first line: " + ($bw -join ' | ')); $fail++
    } else { Write-Output 'ok    a wrapped map missing Walmart fires once, at the statement start' }

    # An allowed_subsets entry still silences a deliberate subset.
    $al = @(Get-StoreListDrift -Path $bad -FileLabel 'bad.ps1' -Names $fxNames -Subsets @(@{ file = 'bad.ps1'; contains = '$STORES = @(' }))
    if ($al.Count -ne 0) { Write-Output ("FAIL  an allowed_subsets entry did not silence its line: " + ($al -join ' | ')); $fail++ }
    else { Write-Output 'ok    allowed_subsets still silences a documented subset' }

    # ---- ORPHANED EXEMPTIONS (2026-09-05, queue 2026-09-05-17ebe3) -------------------------------------
    # FOUNDING BUG, frozen: on 2026-09-05 four of the thirty live allowed_subsets entries could not match
    # anything - local-watchdog.ps1 and import-browser-batch.ps1 had been retired on 2026-08-22, and the
    # needles '$EVERYDAY_ONLY_STORES' (compare-deals.ps1) and 'The weekly Wednesday grocery browser refresh
    # did not run' (check-ad-cycles.ps1) had been edited out of the files they name. The register that
    # silences this guard was never itself checked, so a permanent exemption could rot for months in silence.
    # MUST FIRE on both shapes, because they fail for different reasons and only one of them is visible on disk.
    $orphFile = Join-Path $fx 'real.ps1'
    Set-Content $orphFile -Encoding UTF8 -Value "`$STORES = @('Hy-Vee', 'Aldi')   # the needle below lives here"
    $orph = @(Get-OrphanedExemptions @(
      @{ file = 'gone-forever.ps1'; contains = 'anything' },
      @{ file = 'real.ps1'; contains = 'a needle that was edited out of the file' }
    ) $fx)
    if ($orph.Count -ne 2 -or ($orph -join ' | ') -notmatch 'file gone.*gone-forever\.ps1' -or ($orph -join ' | ') -notmatch 'needle absent.*real\.ps1') {
      Write-Output ("FAIL  a deleted file and an absent needle were not both reported as orphaned exemptions: " + ($orph -join ' | ')); $fail++
    } else { Write-Output 'ok    an exemption naming a deleted file, and one whose needle is gone, both fire' }

    # CLEAN TWIN: an entry whose file exists AND whose needle is present must stay silent - otherwise the
    # check would report every legitimate exemption in the register and be turned off within a day.
    $orphOk = @(Get-OrphanedExemptions @(@{ file = 'real.ps1'; contains = "`$STORES = @('Hy-Vee'" }) $fx)
    if ($orphOk.Count -ne 0) { Write-Output ("FAIL  a live exemption whose needle is present was reported orphaned: " + ($orphOk -join ' | ')); $fail++ }
    else { Write-Output 'ok    an exemption whose file exists and whose needle is present stays silent' }

    # An entry with an EMPTY needle would silence every store-list subset in its file (IndexOf('') is 0).
    $orphEmpty = @(Get-OrphanedExemptions @(@{ file = 'real.ps1'; contains = '' }) $fx)
    if ($orphEmpty.Count -ne 1 -or ($orphEmpty -join ' ') -notmatch 'empty needle') {
      Write-Output ("FAIL  an empty 'contains' was not reported as a blanket silencer: " + ($orphEmpty -join ' | ')); $fail++
    } else { Write-Output 'ok    an exemption with an empty needle is reported, not honoured' }
  } finally { Remove-Item $fx -Recurse -Force -ErrorAction SilentlyContinue }
  Write-Output ("SELFTEST " + $(if ($fail) { "FAILED ($fail)" } else { 'PASSED' }))
  exit $(if ($fail) { 1 } else { 0 })
}

$subsets = @($reg.allowed_subsets)
$scanFiles = Get-ChildItem (Join-Path $root '*.ps1') | Where-Object { $_.Name -ne 'audit-store-registry.ps1' }
foreach ($f in $scanFiles) {
  foreach ($finding in (Get-StoreListDrift -Path $f.FullName -FileLabel $f.Name -Names $names -Subsets $subsets)) { $issues.Add($finding) }
}
# The register that silences check 5 gets checked too. Run it AFTER the scan, so a reader sees the subsets
# that fired first and the exemptions that can no longer fire at all second.
foreach ($finding in (Get-OrphanedExemptions $subsets $root)) { $issues.Add($finding) }

# ---- report ----
if ($issues.Count -eq 0) { Write-Output ("store-registry: OK  " + $names.Count + " stores; board, files, schedule and live scripts all agree"); Write-GuardComplete -Name 'store-registry'; exit 0 }
Write-Output ("store-registry: " + $issues.Count + " drift issue(s):")
$issues | ForEach-Object { Write-Output ("  " + $_) }
if ($Alert) {
  $sig = (($issues | Sort-Object) -join ';')
  $sigF = Join-Path $OutDir 'store-registry-alert.sig'
  $prev = if (Test-Path $sigF) { (Get-Content $sigF -Raw).Trim() } else { '' }
  $sigH = [BitConverter]::ToString([Security.Cryptography.MD5]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($sig))) -replace '-',''
  if ($sigH -ne $prev) {
    try {
      Send-Alert -Subject ("Grocery: store-registry drift - " + $issues.Count + " issue(s)") -Body ("audit-store-registry.ps1 found hardcoded store lists or data out of lockstep with stores.json: " + (($issues | Select-Object -First 12) -join ' | ') + ". Fix the listed script/data or document a legitimate subset in stores.json allowed_subsets.") | Out-Null
      if ($LASTEXITCODE -eq 0) { Set-Content $sigF -Value $sigH -Encoding ASCII }
    } catch {}
  }
}
Write-GuardComplete -Name 'store-registry'; exit 2
