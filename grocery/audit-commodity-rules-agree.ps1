<#
  audit-commodity-rules-agree.ps1 - the LIVE half of test-commodity-rules-lib.ps1's corpus case: does the exclude
  accessor (commodity-rules-lib.ps1) refuse exactly the names match-lib's matcher refuses, over today's capture pool?

  SCOPE OF A CLEAN REPORT: UNSOUND. It asks the question over the first 150 item names of the newest regular capture
  plus four probe names, against every commodity in commodities.json. A clean report means the two copies of the
  rule agree on THOSE names; a name shape absent from today's capture is out of its reach. A finding is COMPLETE: a
  disagreement is a name one copy refuses and the other admits, which is the defect itself.

  WHY IT IS HERE AND NOT AT PUSH TIME (2026-09-23). Until that day the push-time self-test read the newest live
  capture itself. That made it uncacheable (its input moved with no commit, so no source key could watch it) and it
  cost 322 s of every push. The repo's own rule is that the gate runs only what is hermetic and data-dependent audits
  run daily against real data. So the self-test now reads a frozen name list committed under
  grocery\regression-inputs, and THIS script asks the live question once a day in check-ad-cycles, paging through the
  registered types "grocery commodity rules: the accessor disagrees with the matcher" and "... could not evaluate".
  Both read the corpus through Get-TcRulesCaptureCorpus and Get-TcRulesProbeNames, one copy of the rule.

  -WriteFixture <path> writes today's live corpus as the frozen fixture (names, source file, its sha256, the date),
  which is how the committed one was made. It never writes unless asked.

  EXIT CODES (lib\guard-contract.ps1 vocabulary): 0 agree, 1 at least one disagreement, 3 could not evaluate (no
  readable capture, fewer than 10 names, or match-lib/commodities.json missing). Read the verdict LINE.

    grocery\audit-commodity-rules-agree.ps1                        the live question
    grocery\audit-commodity-rules-agree.ps1 -WriteFixture <path>   freeze today's corpus
    grocery\audit-commodity-rules-agree.ps1 -SelfTest              the corpus rule and the three verdicts
#>
[CmdletBinding()]
param([switch]$SelfTest, [string]$CaptureDir = '', [string]$WriteFixture = '')
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $here 'commodity-rules-lib.ps1')
. (Join-Path $here 'global-exclude-lib.ps1')

function Get-CraVerdict {
  <# Pure: the verdict for a corpus and its disagreements. Code 3 below 10 names (the bar the self-test always used),
     1 on any disagreement, else 0. #>
  param([string[]]$Names, $Disagreements)
  $n = @($Names).Count
  $d = @($Disagreements | Where-Object { $_ })
  if ($n -lt 10) { return [pscustomobject]@{ Code = 3; Line = ('COMMODITY-RULES-AGREE BLIND: only ' + $n + ' probe name(s) available (no readable capture); nothing was compared') } }
  if ($d.Count) { return [pscustomobject]@{ Code = 1; Line = ('COMMODITY-RULES-AGREE FAILED: ' + $d.Count + ' disagreement(s) between the accessor and match-lib over ' + $n + ' live name(s)') } }
  return [pscustomobject]@{ Code = 0; Line = ('COMMODITY-RULES-AGREE PASSED: the accessor agrees with match-lib over ' + $n + ' live name(s)') }
}

if ($SelfTest) {
  $script:fail = 0; $script:cases = 0; $script:expectedCases = 7
  function CraT([string]$m, [bool]$c, [string]$got = '') {
    $script:cases++
    if ($c) { Write-Output ('  ok    ' + $m) } else { Write-Output ('  FAIL  ' + $m + '   got: ' + $got); $script:fail++ }
  }
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ('tc-cra-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
  try {
    [void](New-Item -ItemType Directory -Path $tmp -ErrorAction Stop)
    $utf8 = New-Object Text.UTF8Encoding($false)
    $deals = @(); for ($i = 1; $i -le 160; $i++) { $deals += [pscustomobject]@{ item = ('Item ' + $i) } }
    [IO.File]::WriteAllText((Join-Path $tmp 'aldi-regular-2026-09-01.json'), (([pscustomobject]@{ deals = @([pscustomobject]@{ item = 'old' }) }) | ConvertTo-Json -Depth 4), $utf8)
    (Get-Item (Join-Path $tmp 'aldi-regular-2026-09-01.json')).LastWriteTime = (Get-Date).AddDays(-2)
    [IO.File]::WriteAllText((Join-Path $tmp 'hy-vee-regular-2026-09-02.json'), (([pscustomobject]@{ deals = $deals }) | ConvertTo-Json -Depth 4), $utf8)
    $corp = Get-TcRulesCaptureCorpus -CaptureDir $tmp
    CraT 'CLEAN TWIN  the corpus is the NEWEST capture by write time and its first 150 names, as the push-time case always read it' ($corp -and $corp.file -eq 'hy-vee-regular-2026-09-02.json' -and @($corp.names).Count -eq 150 -and $corp.names[149] -eq 'Item 150') ('file=' + $corp.file + ' n=' + @($corp.names).Count)
    $empty = Join-Path $tmp 'empty'; [void](New-Item -ItemType Directory -Path $empty)
    $none = Get-TcRulesCaptureCorpus -CaptureDir $empty
    CraT 'MUST FIRE  a directory with no capture yields no corpus, never an empty one' ($null -eq $none) ''
    $probes = Get-TcRulesProbeNames
    $v = Get-CraVerdict -Names @($probes) -Disagreements @()
    CraT 'MUST FIRE  AT THE BAR minus one: 4 probe names alone (below 10) is BLIND, exit 3' ($v.Code -eq 3) ('code=' + $v.Code)
    $ten = @(1..10 | ForEach-Object { 'n' + $_ })
    $v = Get-CraVerdict -Names $ten -Disagreements @()
    CraT 'MUST NOT FIRE  AT THE BAR: exactly 10 names with no disagreement passes, exit 0' ($v.Code -eq 0) ('code=' + $v.Code)
    $v = Get-CraVerdict -Names $ten -Disagreements @("apples :: 'x' accessor=True matcher=False")
    CraT 'MUST FIRE  one disagreement is a finding, exit 1' ($v.Code -eq 1) ('code=' + $v.Code)
    # The comparison itself, with a stand-in matcher that disagrees on purpose: the accessor refuses 'Apple Juice'
    # through \bjuice\b, the stand-in entry carries no excludes, so exactly one disagreement comes back.
    $doc = @([pscustomobject]@{ id = 'apples'; exclude = @('\bjuice\b'); relax_global = @() })
    $fakeEntries = New-Object System.Collections.Generic.List[object]
    $fakeEntries.Add([pscustomobject]@{ commodity = $doc[0]; exc = (New-Object System.Collections.Generic.List[object]); relax = @() })
    $fake = [pscustomobject]@{ entries = $fakeEntries; gex = (New-Object System.Collections.Generic.List[object]) }
    $dis = Test-TcCommodityRulesAgree -Doc $doc -Names @('Apple Juice', 'Gala Apples') -GlobalExclude @() -Matcher $fake
    CraT 'MUST FIRE  a matcher that admits what the accessor refuses is reported, once, naming the commodity and the name' (@($dis).Count -eq 1 -and $dis[0] -like "apples :: 'Apple Juice' accessor=True matcher=False") ($dis -join ' | ')
    $okEntries = New-Object System.Collections.Generic.List[object]
    $okExc = New-Object System.Collections.Generic.List[object]; $okExc.Add([regex]::new('\bjuice\b', 'IgnoreCase'))
    $okEntries.Add([pscustomobject]@{ commodity = $doc[0]; exc = $okExc; relax = @() })
    $okM = [pscustomobject]@{ entries = $okEntries; gex = (New-Object System.Collections.Generic.List[object]) }
    $dis2 = Test-TcCommodityRulesAgree -Doc $doc -Names @('Apple Juice', 'Gala Apples') -GlobalExclude @() -Matcher $okM
    CraT 'MUST NOT FIRE  a matcher carrying the same exclude agrees on both names' (@($dis2).Count -eq 0) ($dis2 -join ' | ')
  } catch {
    $script:cases++; $script:fail++; Write-Output ('  FAIL  a case threw: ' + $_.Exception.Message)
  } finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
  }
  if ($script:cases -ne $script:expectedCases) { Write-Output ('  FAIL  CASE COUNT  ran ' + $script:cases + ', the suite lists ' + $script:expectedCases); $script:fail++ }
  if ($script:fail) { Write-Output ('COMMODITY-RULES-AGREE SELF-TEST FAILED (' + $script:fail + ' of ' + $script:cases + ' case(s))'); exit 1 }
  Write-Output ('COMMODITY-RULES-AGREE SELF-TEST PASSED (' + $script:cases + ' case(s))')
  exit 0
}

# ------------------------------------------------------------------------------------------- live run
if (-not $CaptureDir) { $CaptureDir = Join-Path $here ('out' + '\regular') }
$mlPath = Join-Path $here 'match-lib.ps1'
$cPath = Join-Path $here 'commodities.json'
if (-not (Test-Path $mlPath) -or -not (Test-Path $cPath)) {
  Write-Output 'COMMODITY-RULES-AGREE BLIND: match-lib.ps1 or commodities.json is missing, so there is nothing to compare'
  Exit-Guard -Name 'commodity-rules-agree' -Summary 'blind=no-rules' -Code 3
}
. $mlPath
$corpus = Get-TcRulesCaptureCorpus -CaptureDir $CaptureDir
$probeNames = Get-TcRulesProbeNames
$names = New-Object System.Collections.Generic.List[string]
if ($corpus) { foreach ($n in $corpus.names) { $names.Add([string]$n) } }
foreach ($n in $probeNames) { $names.Add([string]$n) }
$source = if ($corpus) { $corpus.file } else { '(none readable)' }
Write-Output ('commodity-rules-agree: capture ' + $source + ' in ' + $CaptureDir + ', ' + $(if ($corpus) { @($corpus.names).Count } else { 0 }) + ' capture name(s) + ' + @($probeNames).Count + ' probe(s)')

if ($WriteFixture) {
  if (-not $corpus) { Write-Output 'COMMODITY-RULES-AGREE BLIND: -WriteFixture found no readable capture; nothing written'; Exit-Guard -Name 'commodity-rules-agree' -Summary 'blind=no-capture' -Code 3 }
  $sha = (Get-FileHash -LiteralPath $corpus.path -Algorithm SHA256).Hash.ToLowerInvariant()
  $fx = [ordered]@{
    readme = 'FROZEN corpus for test-commodity-rules-lib.ps1: the item names Get-TcRulesCaptureCorpus read from the newest regular capture on frozen_at, plus Get-TcRulesProbeNames. The push-time self-test compares the accessor with match-lib over exactly these names; the live question runs daily in audit-commodity-rules-agree.ps1. Refresh only by re-running that script with -WriteFixture.'
    frozen_at = (Get-Date).ToString('yyyy-MM-dd')
    source_file = $corpus.file
    source_sha256 = $sha
    capture_names = @($corpus.names)
    probe_names = @($probeNames)
  }
  $json = ($fx | ConvertTo-Json -Depth 4) -replace "`r`n", "`n"
  [IO.File]::WriteAllText($WriteFixture, $json + "`n", (New-Object Text.UTF8Encoding($false)))
  Write-Output ('commodity-rules-agree: wrote the frozen corpus to ' + $WriteFixture + ' (' + $names.Count + ' name(s), source sha256 ' + $sha.Substring(0, 12) + ')')
}

$doc = Get-Content $cPath -Raw -Encoding UTF8 | ConvertFrom-Json
$dis = @()
if ($names.Count -ge 10) {
  $disR = Test-TcCommodityRulesAgree -Doc $doc -Names $names.ToArray() -GlobalExclude (Get-TcGlobalExclude)
  $dis = @($disR)
}
foreach ($d in ($dis | Select-Object -First 25)) { Write-Output ('  disagree  ' + $d) }
$v = Get-CraVerdict -Names $names.ToArray() -Disagreements $dis
Write-Output $v.Line
$cc = @(Get-TcCommodityList -Doc $doc).Count
Exit-Guard -Name 'commodity-rules-agree' -Summary ('names={0} commodities={1} disagreements={2} source={3}' -f $names.Count, $cc, @($dis).Count, $source) -Code $v.Code
