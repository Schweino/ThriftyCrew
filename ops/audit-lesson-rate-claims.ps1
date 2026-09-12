<#
  audit-lesson-rate-claims.ps1 - does any published lesson state a RATE OF RETURN without what Brad's
  ruling says has to sit next to it?

  BRAD'S RULING, 2026-09-12, backlog I112, verbatim:
    "A lesson may show a projected rate of return only when it carries, next to the number: the source
     and the period it covers, whether it is nominal or after inflation, and that fees are not included
     (or the fee assumed). Prefer a historical figure stated as history over a forward projection, and
     pair any nominal figure with its after-inflation figure. No rate may be lifted from a course or
     chart that does not name its source. Illustrations that are pure arithmetic (penny doubling, a
     stated made-up rate labelled as an example) are fine and need none of this. Existing lessons that
     quote a rate get checked against this rule the next time they are edited."

  WHY THIS EXISTS. A course worked here in September 2026 demonstrates compounding at 9%, at 5% and 10%,
  and at 2% against 8%, and runs one chart to $579,471 at 65 in two separate lectures. Not one of those
  carries a date, a source, a fee assumption or an inflation adjustment, and the same course separately
  teaches that fees are what decides long-term wealth. Lifting any of them into a lesson puts an
  unsourceable number on a live paid page about somebody's retirement, which is the estate's standing
  rule ("no fabricated numbers", "understating is exactly as wrong as overstating") landing on the one
  kind of claim a reader is most likely to act on.

  THE HABIT IT REPLACES. The ruling is a writing rule, and a rule in a file is not a block. The four
  things it demands are each readable in the prose, so they can be checked at push time instead of
  remembered: a claim paragraph either carries all four, or it says it is an illustration, or it is a
  finding.

  A RATCHET, NOT A GATE, and the ruling itself asks for that: existing lessons get checked "the next
  time they are edited", so a bar at zero would be red on day one over copy Brad deliberately did not
  order a sweep of. The high-water mark may only go DOWN. What it buys is that a NEW unqualified rate
  cannot be added to a lesson without somebody saying so.

  SCOPE OF A CLEAN REPORT: UNSOUND, in both directions, and it must be read that way.
    * It finds the spellings it knows. A rate of return phrased without any of the return words or any
      of the per-year words below is invisible to it, so a clean report is not a proof that no lesson
      quotes a rate.
    * It reads a PARAGRAPH, joining a list's items into one, so a qualifier belonging to a neighbouring
      bullet can exempt a claim that did not earn it.
    * A paragraph that discusses BORROWING is excluded whole (see $LRC_DEBT_RX) because a credit-card
      or student-loan rate is not a rate of return and the ruling does not reach it. A paragraph that
      genuinely does both therefore escapes.
    * It cannot judge whether a named source is a real source, only that one is named.
  So a reported finding is worth reading and a silent run proves nothing. The prose rule in
  .claude\rules\site-and-publish.md and the drafting step in .claude\skills\lesson\SKILL.md are the
  parts that reach copy this cannot see.

  Usage:
    .\audit-lesson-rate-claims.ps1            scan, report, ratchet against ops\lesson-rate-claims-baseline.json; writes nothing
    .\audit-lesson-rate-claims.ps1 -Tighten   the same, and record a believable FALL as the new high-water mark
    .\audit-lesson-rate-claims.ps1 -Accept    record the CURRENT count as the new high-water mark, whatever it is
    .\audit-lesson-rate-claims.ps1 -SelfTest  frozen fixtures cut from the real lessons, plus this script's live path run against a temp tree

  Exit: 0 = at or under the baseline. 2 = MORE unqualified rate claims than the baseline, or -Tighten
  refused an implausible fall. 3 = could not evaluate (nothing reached the scan).
#>
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop
param([switch]$SelfTest, [switch]$Accept, [switch]$Tighten, [string]$Root = '', [string]$BaselineFile = '')
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $repo 'lib\ratchet.ps1')    # Test-RatchetMove: a fall clears a plausibility bar before -Tighten records it
. (Join-Path $repo 'lib\lf-write.ps1')   # Write-TcLfFile: the baseline is tracked and stored eol=lf

# ---------------------------------------------------------------------------------------------------
# The question, as pure functions over text, so the fixtures drive exactly the rule the live scan runs.
# SINGLE-QUOTED throughout: in a double-quoted PowerShell string the escape character is a BACKTICK, so
# a \ class or a `n inside one does not mean what it reads as.
# ---------------------------------------------------------------------------------------------------

# A number that is a rate at all.
$script:LRC_PCT_RX = '(?<!\w)(\d{1,3}(?:\.\d+)?)\s?%'

# EARNING, not holding and not spending. Bare "interest" is deliberately absent: a credit card charges
# interest too, and including it made a borrowing paragraph read as a return claim.
$script:LRC_RETURN_RX = '(?i)\b(return|returns|returned|grow|grows|grew|growth|gain|gains|earn|earns|earned|earning|compound|compounds|compounded|compounding|yield|yields|annualized|annualised)\b'

# A RATE, not a share. This is the test that separates "a 7% average annual return" from "keep 30% of
# what you earn" and from "the employer adds 50% of that" - both of which carry a return word and
# neither of which is a rate of anything per year. "a month" is deliberately NOT here.
$script:LRC_PERIOD_RX = '(?i)(\baverage\b|\baveraging\b|\bannual\b|\bannually\b|\bannualized\b|\bannualised\b|\ba year\b|\bper year\b|\byearly\b|\beach year\b|\bevery year\b|\ba yr\b)'

# Borrowing is out of scope: the ruling is about a rate of RETURN.
$script:LRC_DEBT_RX = '(?i)\b(credit card|credit cards|APR|borrow|borrows|borrowed|borrowing|loan|loans|debt|debts|mortgage|owe|owes|owed|minimum payment|payday)\b'

# THE EXEMPTION, and it is narrower than a disclaimer. The ruling exempts "a stated made-up rate
# labelled as an example" - a number the lesson invented for the arithmetic. It does NOT exempt a
# real-world claim that merely adds "past returns are not a promise": that sentence is true of a
# sourceless 10% and does nothing to source it, which is the whole defect. So a hedge is not a label.
$script:LRC_EXAMPLE_RX = '(?i)(\billustrative\b|\billustration\b|\bhypothetical\b|\bfor example\b|\ban example\b|\bas an example\b|\bassume\b|\bassumed\b|\bassuming\b|let.?s say|\bsuppose\b|\bpretend\b|\bimagine\b|\bmade[- ]up\b|\bmake[- ]believe\b|Rule of 72|\bpenny\b|\bsay you\b|\bsay your\b|\bpick a rate\b)'

# The four things the ruling wants beside the number.
$script:LRC_SOURCE_RX = '(?i)(\(source\b|\bsource:|\bsourced from\b|\baccording to\b|\bdata from\b|\bas measured by\b|\bas reported by\b|\bfigures from\b|\]\(https?://|S&P Dow Jones|\bIbbotson\b|\bMorningstar\b|\bDamodaran\b|NYU Stern|Federal Reserve|\bFRED\b|\bMSCI\b|\bCRSP\b|\bVanguard\b|\bSchwab\b|\bFidelity\b|officialdata\.org|\bper the [A-Z])'
$script:LRC_PERIODCOVERED_RX = '(?i)(\bsince (?:18|19|20)\d{2}\b|\bfrom (?:18|19|20)\d{2}\b|(?:18|19|20)\d{2}\s*(?:-|–|—|to)\s*(?:18|19|20)\d{2}|\bover the (?:last|past) ~?\d+ years\b|\b(?:last|past) ~?\d+ years\b|\b\d+[- ]year (?:period|average|history|window|stretch|record)\b)'
$script:LRC_INFLATION_RX = '(?i)(after inflation|before inflation|inflation[- ]adjusted|\breal return|\breal returns|\bin real terms\b|\bnominal\b|in today.?s dollars|purchasing power)'
$script:LRC_FEE_RX = '(?i)(\bfee\b|\bfees\b|expense ratio|expense ratios|\bnet of\b|\bgross of\b|\bbefore costs\b|\bafter costs\b|\bbefore fees\b|\bafter fees\b|costs are not included|fees are not included)'

function Get-LessonProseBlocks {
  <# A markdown file as PARAGRAPHS - runs of non-blank lines joined with a space, each carrying the line
     its first line sat on. A paragraph is the unit because "next to the number" is a prose idea, not a
     character count, and because a nominal figure and its after-inflation twin belong in one sentence
     and must count as ONE claim rather than two findings. #>
  param([string]$Text)
  $blocks = New-Object System.Collections.Generic.List[object]
  if ($null -eq $Text -or $Text.Length -eq 0) { return $blocks }
  $lines = $Text -split '\r?\n'
  $cur = New-Object System.Collections.Generic.List[string]
  $start = 1
  for ($i = 0; $i -lt $lines.Count; $i++) {
    $ln = [string]$lines[$i]
    if ($ln.Trim().Length -eq 0) {
      if ($cur.Count -gt 0) { $blocks.Add([pscustomobject]@{ Line = $start; Text = ($cur -join ' ') }); $cur.Clear() }
      continue
    }
    if ($cur.Count -eq 0) { $start = $i + 1 }
    $cur.Add($ln)
  }
  if ($cur.Count -gt 0) { $blocks.Add([pscustomobject]@{ Line = $start; Text = ($cur -join ' ') }) }
  return $blocks
}

function Test-LessonRateClaim {
  <# Is this paragraph making a rate-of-return claim at all? Three conditions, and all three are needed:
     a percentage, an EARNING word, and a PER-YEAR word. Anything about borrowing is excluded. #>
  param([string]$Block)
  if ($Block -notmatch $script:LRC_PCT_RX) { return $false }
  if ($Block -notmatch $script:LRC_RETURN_RX) { return $false }
  if ($Block -notmatch $script:LRC_PERIOD_RX) { return $false }
  if ($Block -match $script:LRC_DEBT_RX) { return $false }
  return $true
}

function Get-LessonRateGaps {
  <# Which of the ruling's four requirements this claim paragraph does NOT carry. An empty list means the
     paragraph satisfies the rule; an exempt illustration never reaches here. #>
  param([string]$Block)
  # A PLAIN ARRAY, never a List[T]: under PS 5.1 wrapping a generic List in @() throws "Argument types
  # do not match" at the CALLER, which is the lucky version of [[ps-list-object-array-wrap-throws]].
  $missing = @()
  if ($Block -notmatch $script:LRC_SOURCE_RX) { $missing += 'source' }
  if ($Block -notmatch $script:LRC_PERIODCOVERED_RX) { $missing += 'period' }
  if ($Block -notmatch $script:LRC_INFLATION_RX) { $missing += 'nominal-or-real' }
  if ($Block -notmatch $script:LRC_FEE_RX) { $missing += 'fees' }
  return ,$missing
}

function Find-LessonRateClaims {
  <# $Docs is a map of display path -> full file text. Returns the denominators beside the findings,
     because a finding count with no scanned count cannot tell "nothing wrong" from "nothing read". #>
  param([hashtable]$Docs)
  $findings = @()
  $paras = 0; $claims = 0; $exempt = 0; $ok = 0
  foreach ($path in (@($Docs.Keys) | Sort-Object)) {
    $blocks = Get-LessonProseBlocks ([string]$Docs[$path])
    foreach ($b in $blocks) {
      $paras++
      if (-not (Test-LessonRateClaim $b.Text)) { continue }
      $claims++
      if ($b.Text -match $script:LRC_EXAMPLE_RX) { $exempt++; continue }
      $gaps = Get-LessonRateGaps $b.Text
      if (@($gaps).Count -eq 0) { $ok++; continue }
      $rates = @()
      foreach ($m in [regex]::Matches($b.Text, $script:LRC_PCT_RX)) { $rates += ($m.Groups[1].Value + '%') }
      $findings += [pscustomobject]@{
        Key     = ($path + ':' + $b.Line)
        File    = $path
        Line    = $b.Line
        Rates   = (@($rates) -join ' ')
        Missing = (@($gaps) -join ', ')
      }
    }
  }
  return [pscustomobject]@{
    paragraphs = $paras; claims = $claims; illustrations = $exempt; qualified = $ok
    findings = @($findings)
  }
}

if ($SelfTest) {
  $bad = 0
  function Assert-Case([string]$n, [bool]$ok, [string]$got) {
    if ($ok) { Write-Output ('  ok    ' + $n) } else { Write-Output ('  X     ' + $n + '   got: ' + $got); $script:bad++ }
  }
  # FROZEN FIXTURES, every one cut from a real published paragraph as it stood on 2026-09-12. Each line is
  # its OWN single-quoted variable: a fixture assembled as `F 'a' + 'b'` passes THREE positional arguments
  # and the case then runs against a fragment, and inside an array literal the comma binds tighter than the
  # plus. Inner apostrophes are doubled.
  $sourceless = 'Some of those companies will have a bad year. But you are not betting on any single one. Historically, large-company U.S. stocks as a group have returned about 10% a year on average since 1928 with dividends reinvested, or closer to 7% a year after inflation is taken out.'
  $r1 = Find-LessonRateClaims @{ 'lesson-30.md' = $sourceless }
  $f1 = @($r1.findings)
  Assert-Case 'MUST FIRE  the real lesson-30 sentence: a historical rate with no source and no fee note is a finding' `
    ($f1.Count -eq 1 -and $r1.claims -eq 1) ("claims=$($r1.claims) findings=$($f1.Count)")
  $got1 = if ($f1.Count) { [string]$f1[0].Missing } else { '<no finding>' }
  Assert-Case 'MUST FIRE  and it names WHICH of the four are missing - source and fees, not period or inflation, both of which that sentence does carry' `
    ($f1.Count -eq 1 -and $f1[0].Missing -eq 'source, fees') $got1
  Assert-Case 'the nominal figure and its after-inflation twin are ONE claim, not two findings, because the ruling wants them paired in one place' `
    ($r1.claims -eq 1) ("claims=$($r1.claims)")

  # MUST NOT FIRE: a made-up rate LABELLED as an example is exactly what the ruling exempts (lesson-27).
  $assumed = '1. **Your kid starts now.** Use their current age, $20/month, an assumed 7% average annual return (explain it is illustrative, not guaranteed), and set the end age to 60. Write down the result.'
  $r2 = Find-LessonRateClaims @{ 'lesson-27.md' = $assumed }
  Assert-Case 'MUST NOT FIRE  an assumed rate labelled illustrative is exempt, so this is not just "find every percentage"' `
    ((@($r2.findings)).Count -eq 0 -and $r2.illustrations -eq 1) ("findings=$((@($r2.findings)).Count) illustrations=$($r2.illustrations)")

  # MUST NOT FIRE: pure arithmetic. The Rule of 72 block states rates to divide by, not rates to expect.
  $rule72 = 'At 6% then 72 divided by 6 = 12 years to double. At 8% then 72 divided by 8 = 9 years to double. At 10% then 72 divided by 10 = 7.2 years to double. Using the Rule of 72, an annual rate of return predicts the doubling on average.'
  $r3 = Find-LessonRateClaims @{ 'lesson-28.md' = $rule72 }
  Assert-Case 'MUST NOT FIRE  the Rule of 72 arithmetic is an illustration and needs none of the four' `
    ((@($r3.findings)).Count -eq 0) ("findings=$((@($r3.findings)).Count)")

  # MUST NOT FIRE: a SHARE of income is not a rate. This is the discriminator most likely to rot, and it
  # is the shape 4 of the 18 percentage-carrying lessons actually have.
  $share = 'This matters for how you frame it. "Pay yourself first" sounds good. "You only get to spend 90% of what you earn" sounds like punishment. Same math, totally different energy.'
  $r4 = Find-LessonRateClaims @{ 'lesson-09.md' = $share }
  Assert-Case 'MUST NOT FIRE  a share of income (90% of what you earn) carries a return word and is not a rate claim' `
    ($r4.claims -eq 0) ("claims=$($r4.claims)")

  $match = 'The employer match is, without exaggeration, free money. It is the closest thing to an instant 50% or 100% return that exists in legitimate personal finance.'
  $r5 = Find-LessonRateClaims @{ 'lesson-31.md' = $match }
  Assert-Case 'MUST NOT FIRE  an employer match stated as an instant 50% return is arithmetic, not a rate per year' `
    ($r5.claims -eq 0) ("claims=$($r5.claims)")

  # MUST NOT FIRE: a BORROWING rate. This paragraph has a return word, a percentage and "per year".
  $cc = 'Because while that balance sits there, it earns them interest. And a typical credit card charges somewhere between 20% and 30% interest per year on whatever balance is left.'
  $r6 = Find-LessonRateClaims @{ 'lesson-33.md' = $cc }
  Assert-Case 'MUST NOT FIRE  a credit-card rate per year is not a rate of return, so the debt exclusion holds' `
    ($r6.claims -eq 0) ("claims=$($r6.claims)")

  # MUST FIRE, and this is the distinction the whole detector turns on: a HEDGE is not an example label.
  # The real substack line says "that is history, not a promise" and names no source at all, so the
  # disclaimer is true and the claim is still unsourced.
  $hedged = 'Historically, including the past 40 years, the S&P 500 has returned roughly 10% a year on average. Emphasis on average: some years it jumps 25%, some years it drops 20%. (Again, that is history, not a promise. Future returns could be lower.)'
  $r7 = Find-LessonRateClaims @{ 'basics-of-investing.md' = $hedged }
  $f7 = @($r7.findings)
  Assert-Case 'MUST FIRE  "that is history, not a promise" is a hedge, not a label saying the rate was made up, so the claim still owes its source' `
    ($f7.Count -eq 1) ("findings=$($f7.Count) illustrations=$($r7.illustrations)")
  $got7 = if ($f7.Count) { [string]$f7[0].Missing } else { '<no finding>' }
  Assert-Case 'MUST FIRE  and the hedged claim is missing source, nominal-or-real and fees while its period IS stated' `
    ($f7.Count -eq 1 -and $f7[0].Missing -eq 'source, nominal-or-real, fees') $got7

  # CLEAN TWIN: the rule is SATISFIABLE, and compliant copy still passes. A positive assertion - the thing
  # a tightening of any of the four patterns would most likely break on its way past.
  $qualified = 'Over 1928 to 2025, large-company U.S. stocks returned about 10% a year on average in nominal terms, or about 7% a year after inflation (source: NYU Stern, Damodaran historical returns). Those figures are before fees, and a fund charging 0.5% a year takes its cut out of them.'
  $r8 = Find-LessonRateClaims @{ 'lesson-future.md' = $qualified }
  Assert-Case 'CLEAN TWIN  a paragraph carrying all four - source, period, nominal-or-real and fees - is a CLAIM and NOT a finding' `
    ($r8.claims -eq 1 -and (@($r8.findings)).Count -eq 0 -and $r8.qualified -eq 1) `
    ("claims=$($r8.claims) findings=$((@($r8.findings)).Count) qualified=$($r8.qualified) missing=$(if ((@($r8.findings)).Count) { @($r8.findings)[0].Missing })")

  # The denominator is reported, not just the finding count.
  $multi = @{ 'a.md' = $sourceless; 'b.md' = $assumed; 'c.md' = $qualified }
  $r9 = Find-LessonRateClaims $multi
  Assert-Case 'a rate is printed with its denominator: paragraphs scanned, claims found, illustrations and qualified claims all reported' `
    ($r9.paragraphs -eq 3 -and $r9.claims -eq 3 -and $r9.illustrations -eq 1 -and $r9.qualified -eq 1 -and (@($r9.findings)).Count -eq 1) `
    ("paras=$($r9.paragraphs) claims=$($r9.claims) illus=$($r9.illustrations) qualified=$($r9.qualified) findings=$((@($r9.findings)).Count)")

  # An empty corpus must read as zero-scanned, so the live path can tell "nothing found" from "nothing read".
  $r10 = Find-LessonRateClaims @{}
  Assert-Case 'an empty corpus scans zero paragraphs and finds nothing, which the live path reports as BLIND rather than clean' `
    ($r10.paragraphs -eq 0 -and (@($r10.findings)).Count -eq 0) ("paras=$($r10.paragraphs)")
  # PS 5.1: @($null).Count is 1, so an empty finding set must not score 1.
  Assert-Case 'an empty finding set counts 0, not the PS 5.1 @($null) 1' ((@($r10.findings)).Count -eq 0) ([string](@($r10.findings)).Count)

  # A paragraph is the unit, and two claim paragraphs in one file are two findings.
  $twoPara = $sourceless + "`n`n" + $hedged
  $r11 = Find-LessonRateClaims @{ 'two.md' = $twoPara }
  Assert-Case 'two claim paragraphs in one file are two findings, each carrying its own line number' `
    ((@($r11.findings)).Count -eq 2 -and @($r11.findings)[1].Line -eq 3) `
    ("findings=$((@($r11.findings)).Count) lines=$((@($r11.findings) | ForEach-Object { $_.Line }) -join ',')")

  # ---- THE LIVE PATH, DRIVEN. These run THIS script as a child against a one-file temp tree and a temp
  # baseline, so they exercise the code a gate runs rather than a copy of it. A plain run must leave the
  # tracked baseline byte-identical: run-gates runs every static audit with no arguments on every pre-push,
  # and a rewrite there dirties the checkout being pushed without riding the push.
  # ONE DIRECTORY PER RUN, removed in finally, because concurrent pushes run this suite in one %TEMP%.
  $wt = Join-Path $env:TEMP ('lrc-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Path $wt -ErrorAction Stop | Out-Null
  try {
    $fxTree = Join-Path $wt 'tree'
    $fxContent = Join-Path $fxTree 'content\lessons'
    New-Item -ItemType Directory -Path $fxContent -Force -ErrorAction Stop | Out-Null
    # Exactly ONE finding in the fixture tree: the sourceless historical rate.
    [IO.File]::WriteAllText((Join-Path $fxContent 'lesson-fx.md'), $sourceless, (New-Object Text.UTF8Encoding($false)))
    $blFx = Join-Path $wt 'baseline.json'
    $seedDoc = [ordered]@{ note = 'fixture note (backlog I112)'; generated = '2026-01-01T00:00:00'; findings = 2; names = @('lesson-30.md:1', 'retired-claim.md:9') }
    $null = Write-TcLfFile $blFx ($seedDoc | ConvertTo-Json -Depth 3)
    $seedB64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($blFx))
    $o1 = & powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Root $fxTree -BaselineFile $blFx
    $rc1 = $LASTEXITCODE
    $o1 = @($o1)
    $same1 = [string]::Equals($seedB64, [Convert]::ToBase64String([IO.File]::ReadAllBytes($blFx)), [StringComparison]::Ordinal)
    Assert-Case 'a FALL (1 finding, baseline 2) without -Tighten is spoken and NOT written, so a pre-push gate run leaves its checkout clean' `
      ($rc1 -eq 0 -and $same1 -and (($o1 -join "`n") -match 'CAN tighten')) ("rc=$rc1 baselineUnchanged=$same1 out=" + (($o1 | Select-Object -Last 3) -join ' | '))
    $null = & powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Root $fxTree -BaselineFile $blFx -Tighten
    $rc2 = $LASTEXITCODE
    $b2 = [IO.File]::ReadAllBytes($blFx)
    $cr2 = 0; foreach ($x in $b2) { if ($x -eq 13) { $cr2++ } }
    $bom2 = ($b2.Length -ge 3 -and $b2[0] -eq 0xEF -and $b2[1] -eq 0xBB -and $b2[2] -eq 0xBF)
    $doc2 = $null
    if ($bom2) { $doc2 = [Text.Encoding]::UTF8.GetString($b2, 3, $b2.Length - 3) | ConvertFrom-Json }
    Assert-Case '-Tighten records the fall in the bytes git stores: no CR, the BOM, one trailing LF, and the note the file already carried' `
      ($rc2 -eq 0 -and $cr2 -eq 0 -and $bom2 -and $b2[-1] -eq 10 -and $null -ne $doc2 -and [int]$doc2.findings -eq 1 -and [string]$doc2.note -eq 'fixture note (backlog I112)') `
      ("rc=$rc2 cr=$cr2 bom=$bom2 findings=$(if ($doc2) { $doc2.findings }) note=$(if ($doc2) { $doc2.note })")
    $blRise = Join-Path $wt 'baseline-rise.json'
    $null = Write-TcLfFile $blRise ([ordered]@{ note = 'fixture'; generated = '2026-01-01T00:00:00'; findings = 0; names = @() } | ConvertTo-Json -Depth 3)
    $o3 = & powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Root $fxTree -BaselineFile $blRise
    $rc3 = $LASTEXITCODE
    Assert-Case 'CLEAN TWIN  a count that ROSE still fails with exit 2, so not writing on a fall did not disarm the ratchet' `
      ($rc3 -eq 2) ("rc=$rc3 out=" + ((@($o3) | Select-Object -Last 2) -join ' | '))
    # A tree with no content\ at all is BLIND, never a confident clean: the boards are gitignored here and
    # the estate's standing trap is a walk that reached nothing and reported zero findings.
    $emptyTree = Join-Path $wt 'empty'
    New-Item -ItemType Directory -Path $emptyTree -ErrorAction Stop | Out-Null
    $o4 = & powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Root $emptyTree -BaselineFile $blFx
    $rc4 = $LASTEXITCODE
    Assert-Case 'MUST FIRE  a tree with no content markdown exits 3 BLIND and says so, never 0 with a clean count' `
      ($rc4 -eq 3 -and ((@($o4) -join "`n") -match 'BLIND')) ("rc=$rc4 out=" + ((@($o4) | Select-Object -Last 2) -join ' | '))
  } finally {
    Remove-Item -LiteralPath $wt -Recurse -Force -ErrorAction SilentlyContinue
  }

  if ($bad -eq 0) {
    Write-Output 'LESSON-RATE-CLAIMS SELF-TEST PASS'
    Write-GuardComplete -Name 'lesson-rate-claims' -Summary 'selftest ok'
    exit 0
  }
  Write-Output ("LESSON-RATE-CLAIMS SELF-TEST FAILED ($bad)")
  Write-GuardComplete -Name 'lesson-rate-claims' -Summary "selftest failed=$bad"
  exit 2
}

# ---- live scan ----
if (-not $Root) { $Root = $repo }
$contentRoot = Join-Path $Root 'content'
$docs = @{}
if (Test-Path -LiteralPath $contentRoot) {
  # WALK content\ WHOLE rather than naming the lesson directories: naming them is how a new publishing
  # channel goes unscanned the day somebody adds one, and the substack mirror is maintained alongside the
  # lessons (both were edited in the same commits in September 2026), so a rate lands in two places at once.
  # The archive is skipped because it is a record of what WAS published, not copy anybody will edit.
  $skipNames = @{ '_archive-substack-era' = $true; 'workbooks' = $true }
  $stack = New-Object System.Collections.Generic.Stack[string]
  $stack.Push($contentRoot)
  while ($stack.Count) {
    $dir = $stack.Pop()
    try {
      foreach ($sub in [IO.Directory]::EnumerateDirectories($dir)) {
        if ($skipNames.ContainsKey((Split-Path $sub -Leaf).ToLower())) { continue }
        $stack.Push($sub)
      }
      foreach ($ff in [IO.Directory]::EnumerateFiles($dir)) {
        if ($ff -notmatch '\.md$') { continue }
        # The DISPLAY path is relative to the root, never the full path: this runs from a linked worktree
        # on every push, where every full path carries \.claude\worktrees\.
        $rel = $ff.Substring($Root.Length).TrimStart('\', '/')
        try { $docs[$rel] = [IO.File]::ReadAllText($ff) } catch { }
      }
    } catch { }
  }
}
if ($docs.Count -eq 0) {
  Write-Output 'lesson-rate-claims: BLIND - no markdown under content\ reached the scan, so a clean result would prove nothing'
  Exit-Guard -Name 'lesson-rate-claims' -Summary 'blind' -Code 3
}
$res = Find-LessonRateClaims $docs
$fnd = @($res.findings)
$n = $fnd.Count
Write-Output ("lesson-rate-claims: read {0} file(s), {1} paragraph(s); {2} rate-of-return claim(s), of which {3} labelled as an illustration and {4} fully qualified; {5} carry a rate without what Brad's 2026-09-12 ruling wants beside it" -f $docs.Count, $res.paragraphs, $res.claims, $res.illustrations, $res.qualified, $n)
foreach ($f in ($fnd | Sort-Object File, Line)) {
  Write-Output ('  RATE UNQUALIFIED  ' + $f.File + ':' + $f.Line + '  ' + $f.Rates + '  missing: ' + $f.Missing)
}
Write-Output '  (the ruling: existing lessons that quote a rate get checked the next time they are EDITED, so these are a worklist and not a regression. A pure-arithmetic illustration labelled as an example needs none of the four.)'

$blF = if ($BaselineFile) { $BaselineFile } else { Join-Path $here 'lesson-rate-claims-baseline.json' }
$blDir = Split-Path $blF -Parent
if ($blDir -and -not (Test-Path -LiteralPath $blDir)) { New-Item -ItemType Directory -Force $blDir | Out-Null }
$base = $null; $blDoc = $null
if (Test-Path -LiteralPath $blF) { try { $blDoc = Get-Content $blF -Raw | ConvertFrom-Json; $base = [int]$blDoc.findings } catch { $base = $null } }
$script:LRC_NOTE = 'High-water mark for the unqualified rate-of-return ratchet (backlog I112, Brad''s ruling 2026-09-12). This number may only go DOWN. A run above it means a NEW rate was published without its source, its period, its nominal-or-real basis and its fee statement.'
function Write-LrcBaseline([int]$Count) {
  $note = if ($blDoc -and $blDoc.note) { [string]$blDoc.note } else { $script:LRC_NOTE }
  $names = @($fnd | Sort-Object File, Line | ForEach-Object { $_.Key })
  $json = [ordered]@{ note = $note; generated = (Get-Date).ToString('s'); findings = $Count; names = $names } | ConvertTo-Json -Depth 3
  return (Write-TcLfFile $blF $json)
}
if ($Accept -or $null -eq $base) {
  $null = Write-LrcBaseline $n
  Write-Output ("  baseline written: $n unqualified claim(s). From here the number may only go DOWN.")
  Exit-Guard -Name 'lesson-rate-claims' -Summary "findings=$n baseline=$n" -Code 0
}
if ($n -gt $base) {
  Write-Output ("lesson-rate-claims: RATCHET BROKEN - $n unqualified rate claim(s) now, baseline $base. A lesson now states a rate of return without the source, the period, the nominal-or-real basis or the fee statement Brad's ruling requires beside it. Either add those four next to the number, or label the rate as a made-up example if that is what it is.")
  Exit-Guard -Name 'lesson-rate-claims' -Summary "findings=$n baseline=$base" -Code 2
}
if ($n -lt $base) {
  $move = Test-RatchetMove -Name 'lesson-rate-claims' -Count $n -Baseline $base
  if ($move.Verdict -eq 'implausible') {
    Write-Output ('  ' + $move.Message + ' (-Accept is this script''s -AcceptDrop.)')
    if ($Tighten) { Exit-Guard -Name 'lesson-rate-claims' -Summary "findings=$n baseline=$base refused-to-lower" -Code 2 }
  } elseif ($Tighten) {
    $null = Write-LrcBaseline $n
    Write-Output ("  ratchet tightened: $n claim(s), was $base. New baseline written - commit it, or it protects only this checkout.")
  } else {
    Write-Output ("  ratchet CAN tighten: $n claim(s), baseline $base. NOT written: this is a pre-push gate, and a rewrite here dirties the checkout being pushed without riding the push. Record it with -Tighten and commit ops\lesson-rate-claims-baseline.json.")
  }
}
Write-Output ("lesson-rate-claims: $n unqualified claim(s) against a baseline of $base - the known worklist, not a regression.")
Exit-Guard -Name 'lesson-rate-claims' -Summary "findings=$n baseline=$base" -Code 0
