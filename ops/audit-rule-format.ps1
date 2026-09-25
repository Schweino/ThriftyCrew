<#
  audit-rule-format.ps1 - an always-loaded rules file written in the channel-tagged shape stays in that shape.

  WHY (Brad, 2026-09-25, design\PLAN-rules-trim-2026-09-25.md: "Build the best and smartest way that also future
  proofs us"). Every rules file under .claude\rules loads into every session AND every spawned agent, and each call
  re-reads it: on the 2026-09-25 triage run the rules load cost about 1.86M of 9.28M cost_units, and
  ops-and-gates.md was 58% of it, because each incident had added a paragraph of history and nothing pushed back.
  The trim kept every rule's operative text and moved the history, word for word, to docs\rules-history\. This
  gate is what stops it growing back: the size of the files as a whole is held by ops\audit-always-loaded-bytes.ps1
  (W6.6), and this holds the SHAPE of each rule.

  FOR EACH FILE IN $Manifest (a file joins when it is converted; ops-and-gates.md is the first), every top-level
  bullet (a line starting `- **` and its indented continuation) must:
    1. end with a channel tag: `(channel: gate <path>[, <path>]; full: <id>)` or `(channel: judgement; full: <id>)`.
       `gate` means a push gate refuses a violation; `judgement` means only the text carries the rule;
    2. name only gate paths that exist in this checkout;
    3. name a history anchor `<a id="<id>"></a>` that exists in docs\rules-history\<file>, used by no other bullet;
    4. be at most $MaxBulletChars characters, tag included. The bar is the first plausible value, not the survivor of
       a sweep: the longest converted rule (the lock order) was 1,004 when this was written.
  And every anchor in the history file must be named by some bullet (5), so no rule is dropped from the loaded file
  while its account survives only in history.

  SCOPE OF A CLEAN REPORT: UNSOUND for meaning. It checks the shape, that a named gate EXISTS and that every rule's
  account has a home; it cannot tell whether the kept sentence still says what the full account says, or whether a
  tagged gate really enforces that rule. A finding is COMPLETE: each is a mechanical fact about the file (a missing
  tag, a missing path or anchor, a length over the bar).

  EXIT: 0 clean, 1 at least one finding, 3 could not evaluate (a manifest file or its history missing).
  Last line: RULE-FORMAT-COMPLETE.
#>
[CmdletBinding()]
param([switch]$SelfTest)

$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repo = Split-Path -Parent $here

$Manifest = @('ops-and-gates.md')
$MaxBulletChars = 1100

function Get-TcRuleBullets([string]$Text) {
  $out = New-Object System.Collections.Generic.List[string]
  $cur = $null
  foreach ($l in ($Text -replace "`r", '') -split "`n") {
    if ($l.StartsWith('- **')) { if ($null -ne $cur) { $out.Add($cur) }; $cur = $l; continue }
    if ($null -ne $cur -and $l.StartsWith('  ') -and $l.Trim()) { $cur += "`n" + $l; continue }
    if ($null -ne $cur) { $out.Add($cur); $cur = $null }
  }
  if ($null -ne $cur) { $out.Add($cur) }
  return ,$out.ToArray()
}

function Test-TcRuleFormat {
  param([string]$RulesText, [string]$HistoryText, [string]$Root, [string]$Name, [int]$Max = $script:MaxBulletChars)
  $find = New-Object System.Collections.Generic.List[string]
  $anchors = @{}
  foreach ($m in [regex]::Matches($HistoryText, '<a id="([a-z]+-\d+)"></a>')) { $anchors[$m.Groups[1].Value] = $false }
  $bullets = Get-TcRuleBullets $RulesText
  $n = 0
  foreach ($b in $bullets) {
    $n++
    $head = (($b -split "`n")[0]).Substring(0, [Math]::Min(70, (($b -split "`n")[0]).Length))
    $m = [regex]::Match($b, '\(channel: (?:gate (?<g>[^;]+)|(?<j>judgement)); full: (?<id>[a-z]+-\d+)\)\s*$')
    if (-not $m.Success) { $find.Add("$Name rule $n has no channel tag at its end: $head"); continue }
    if ($m.Groups['g'].Success) {
      foreach ($g in ($m.Groups['g'].Value -split ',')) {
        $p = $g.Trim()
        if (-not $p -or -not (Test-Path -LiteralPath (Join-Path $Root $p))) { $find.Add("$Name rule $n names gate '$p', which is not in this checkout: $head") }
      }
    }
    $id = $m.Groups['id'].Value
    if (-not $anchors.ContainsKey($id)) { $find.Add("$Name rule $n points at history anchor $id, which docs\rules-history\$Name does not carry: $head") }
    elseif ($anchors[$id]) { $find.Add("$Name rule $n reuses history anchor ${id}: $head") }
    else { $anchors[$id] = $true }
    if ($b.Length -gt $Max) { $find.Add("$Name rule $n is $($b.Length) characters, over the $Max bar: move its history to the anchor and keep the rule: $head") }
  }
  foreach ($k in @($anchors.Keys | Sort-Object)) {
    if (-not $anchors[$k]) { $find.Add("$Name history anchor $k is named by no rule: a rule was dropped from the loaded file") }
  }
  return [pscustomobject]@{ Findings = $find.ToArray(); Bullets = $n; Anchors = $anchors.Count }
}

if ($SelfTest) {
  $script:cases = 0; $script:fail = 0
  function _Case([string]$label, [bool]$ok, [string]$got) {
    $script:cases++
    if ($ok) { Write-Output "ok    $label" } else { Write-Output "FAIL  $label  got: $got"; $script:fail++ }
  }
  $root = Join-Path $env:TEMP ('arf-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Path (Join-Path $root 'ops') -ErrorAction Stop | Out-Null
  try {
    [IO.File]::WriteAllText((Join-Path $root 'ops\audit-x.ps1'), '#', (New-Object Text.UTF8Encoding($false)))
    $hist = '<a id="og-01"></a>' + "`n- **one**`n" + '<a id="og-02"></a>' + "`n- **two**`n"
    $good = "# head`n`n- **Rule one.** Do it.`n  (channel: gate ops/audit-x.ps1; full: og-01)`n- **Rule two.** Think. (channel: judgement; full: og-02)`n"
    $r = Test-TcRuleFormat $good $hist $root 'x.md'
    _Case 'CLEAN TWIN: two tagged rules, one gate that exists and one judgement, each on its own anchor, pass (2 rules, 2 anchors)' (($r.Findings.Count -eq 0) -and ($r.Bullets -eq 2)) (($r.Findings -join ' | ') + " bullets=$($r.Bullets)")
    $r = Test-TcRuleFormat ($good -replace ' \(channel: judgement; full: og-02\)', '') $hist $root 'x.md'
    _Case 'MUST FIRE: a rule with no channel tag is a finding' ((@($r.Findings | Where-Object { $_ -match 'no channel tag' })).Count -eq 1) ($r.Findings -join ' | ')
    $r = Test-TcRuleFormat ($good -replace 'audit-x', 'audit-gone') $hist $root 'x.md'
    _Case 'MUST FIRE: a gate tag naming a script that does not exist is a finding' ((@($r.Findings | Where-Object { $_ -match "names gate 'ops/audit-gone.ps1'" })).Count -eq 1) ($r.Findings -join ' | ')
    $r = Test-TcRuleFormat ($good -replace 'full: og-02', 'full: og-09') $hist $root 'x.md'
    _Case 'MUST FIRE: an anchor the history does not carry is a finding, and the orphaned og-02 is named as a dropped rule' (((@($r.Findings | Where-Object { $_ -match 'og-09, which' })).Count -eq 1) -and ((@($r.Findings | Where-Object { $_ -match 'og-02 is named by no rule' })).Count -eq 1)) ($r.Findings -join ' | ')
    $r = Test-TcRuleFormat ($good -replace 'full: og-02', 'full: og-01') $hist $root 'x.md'
    _Case 'MUST FIRE: two rules on one anchor is a finding' ((@($r.Findings | Where-Object { $_ -match 'reuses history anchor og-01' })).Count -eq 1) ($r.Findings -join ' | ')
    # BAR: the second rule is built to exactly the bar, then one character past it.
    $tail = ' (channel: judgement; full: og-02)'
    $pre = '- **Rule two.** '
    $atBar = $pre + ('y' * (60 - $pre.Length - $tail.Length)) + $tail
    $one = "- **R1.** (channel: gate ops/audit-x.ps1; full: og-01)`n"   # 54 characters, under the bar on its own
    $r = Test-TcRuleFormat ($one + $atBar + "`n") $hist $root 'x.md' -Max 60
    _Case 'BAR: a rule exactly AT the 60-character bar passes' ($r.Findings.Count -eq 0) (($r.Findings -join ' | ') + " len=$($atBar.Length)")
    $r = Test-TcRuleFormat ($one + $pre + 'y' + $atBar.Substring($pre.Length) + "`n") $hist $root 'x.md' -Max 60
    _Case 'BAR: a rule one character PAST the 60-character bar is a finding' ((@($r.Findings | Where-Object { $_ -match 'is 61 characters, over the 60 bar' })).Count -eq 1) ($r.Findings -join ' | ')
    $r = Test-TcRuleFormat ("# head`n- **Rule one.** Do it.`n  (channel: gate ops/audit-x.ps1, ops/audit-x.ps1; full: og-01)`n- **Rule two.** Think. (channel: judgement; full: og-02)`n") $hist $root 'x.md'
    _Case 'CLEAN TWIN: a rule may name two gates, comma separated, and a wrapped tag line still reads as the tag' ($r.Findings.Count -eq 0) ($r.Findings -join ' | ')
  } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
  if ($script:cases -ne 8) { Write-Output "FAIL  ran $($script:cases) case(s), expected 8"; $script:fail++ }
  if ($script:fail) { Write-Output ("RULE-FORMAT SELF-TEST FAILED ({0} of {1} case(s))" -f $script:fail, $script:cases); exit 1 }
  Write-Output ("RULE-FORMAT SELF-TEST PASSED ({0} case(s))" -f $script:cases)
  exit 0
}

$all = New-Object System.Collections.Generic.List[string]
$read = 0; $rules = 0
foreach ($name in $Manifest) {
  $rp = Join-Path $repo ('.claude\rules\' + $name)
  $hp = Join-Path $repo ('docs\rules-history\' + $name)
  if (-not (Test-Path -LiteralPath $rp) -or -not (Test-Path -LiteralPath $hp)) {
    Write-Output "audit-rule-format: COULD NOT EVALUATE - $name or its history file is missing ($rp, $hp)"
    Write-Output "RULE-FORMAT-COMPLETE files=$read rules=$rules findings=0 blind=1"
    exit 3
  }
  $res = Test-TcRuleFormat ([IO.File]::ReadAllText($rp)) ([IO.File]::ReadAllText($hp)) $repo $name
  $read++; $rules += $res.Bullets
  foreach ($f in $res.Findings) { $all.Add($f) }
}
foreach ($f in $all) { Write-Output "  FINDING  $f" }
if ($rules -eq 0) {
  Write-Output 'audit-rule-format: COULD NOT EVALUATE - the manifest files hold no rule bullets, so nothing was read'
  Write-Output "RULE-FORMAT-COMPLETE files=$read rules=0 findings=0 blind=1"
  exit 3
}
Write-Output ("audit-rule-format: {0} file(s), {1} rule(s), {2} finding(s)" -f $read, $rules, $all.Count)
Write-Output ("RULE-FORMAT-COMPLETE files={0} rules={1} findings={2}" -f $read, $rules, $all.Count)
if ($all.Count) { exit 1 }
exit 0
