# audit-fixture-inputs.ps1 - a self-test's verdict may not depend on a file the harness did not freeze.
#
# WHY THIS EXISTS (2026-09-06, PLAN-top5-2026-09-06 area 4). A guard reads its RULINGS - an allowlist, a
# ledger, a channel-exception file - from a fixed path beside itself, and the harness drives it with a
# fixture BOARD but the live rulings. The verdict then rests on two inputs and only one of them is frozen,
# so an ordinary correct edit somewhere else turns a watcher red, or (worse) quietly changes what its clean
# twin was proving. Measured on the day this was written:
#
#   compare-deals.ps1        its -SelfTest asserted two specific ids were still in the SHIPPED
#                            instore-channel-allowlist.json - so a reviewer retiring either exception
#                            would have turned the PRICE ENGINE's own self-test red, for a correct call.
#   audit-semantic-identity  its -SelfTest header said "no GPU, no network, no data files" and then loaded
#                            the live known-wrong.json; its clean twin rested on the coconut-oil ruling
#                            still being in it.
#
# THE CLASS IS "an input a guard reads by default that the harness did not pin", and the repair is always
# the same: a -SomethingFile parameter defaulting to the live path, a frozen copy under regression-inputs\,
# and the live read KEPT where the author meant it - labelled, so a red is read as "live data changed"
# rather than "this watcher went blind".
#
# THREE WAYS A READ IS NOT A FINDING, and each is a declaration somebody made on purpose:
#   1. the path is under regression-inputs\      - it is frozen by construction
#   2. the line (or the comment above it) says LIVE-TWIN - the author WANTS a red on a machine where the
#      live data is broken. audit-price-mode, audit-food-category, audit-known-wrong and capture-evictions
#      all have deliberate live twins, and removing them would be the wrong repair.
#   3. the file is on the CONFIG allowlist below - a registry, not a ruling
#
# THE RATCHET IS BY NAME, NOT BY COUNT (see [[exit-code-first-tally-second]] and the daemon suite's
# --names-diff). A baseline of 12 that becomes a different 12 is a regression a count cannot see. A NEW
# name fails; a name that DISAPPEARS is the ratchet tightening and is reported so the baseline is trimmed.
#
#   ops\audit-fixture-inputs.ps1            scan the tree against ops\fixture-input-baseline.json
#   ops\audit-fixture-inputs.ps1 -Update    rewrite the baseline (a deliberate act, after a real repair)
#   ops\audit-fixture-inputs.ps1 -SelfTest  frozen must-fire fixtures + clean twins
# Exit 0 = no new dependency. 1 = a NEW one. 2 = self-test regression. 3 = BLIND (no self-tests found).
param([switch]$SelfTest, [switch]$Update)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $repo 'lib\json-io.ps1')
. (Join-Path $repo 'lib\selftest-lib.ps1')   # Get-SelfTestBlock: PowerShell's own parser, shared with audit-mustfire-census

# CONFIG, NOT RULINGS. A registry of stores or a search template is not a verdict anybody adjudicates, so
# a self-test reading one is not resting on a moving decision. Each line is defended in a diff.
$CONFIG_OK = @(
  'stores.json', 'commodity-search.json', 'responses.json', 'capture-policy.json',
  'twin-rules.json', 'prompt-backup-exempt.json', 'out-declared-families.json',
  'expected-automations.json', 'densities.json', 'unit-vocabulary.json'
)

# THE BLOCK EXTRACTOR IS SHARED (2026-09-06). opsudit-mustfire-census.ps1 needs the identical answer,
# and two copies of one rule is this estate's most reliable bug - opsudit-twin-drift.ps1 exists because
# of it. lib\selftest-lib.ps1 carries Get-SelfTestBlock, the account of the two hand-written scanners that
# got it wrong, and its own frozen fixtures for both of those shapes.

function Get-UnpinnedReads {
  <# Every read of a .json under a repo-root variable inside $Text, minus the three declarations.
     Returns the JSON leaf names, which is what the baseline is keyed on. #>
  param([string]$Text, [string[]]$ConfigOk = @())
  $out = New-Object System.Collections.ArrayList
  $lines = $Text -split "`r?`n"
  for ($i = 0; $i -lt $lines.Count; $i++) {
    $l = $lines[$i]
    $t = $l.TrimStart()
    if ($t.StartsWith('#')) { continue }
    # DECLARED LIVE, by the author, on the line itself or anywhere in the comment block directly above it.
    # THE WHOLE BLOCK, not just one line: on this estate the reason a live read is deliberate takes four or
    # five lines to state, and a marker that only counts on the last of them would make the author move the
    # label rather than write the reason.
    if ($l -match 'LIVE-TWIN') { continue }
    $declared = $false
    for ($j = $i - 1; $j -ge 0; $j--) {
      $prev = $lines[$j].TrimStart()
      if (-not $prev.StartsWith('#')) { break }
      if ($lines[$j] -match 'LIVE-TWIN') { $declared = $true; break }
    }
    if ($declared) { continue }
    foreach ($m in [regex]::Matches($l, "Join-Path\s+\`$(?:root|repo|PSScriptRoot|OutDir|OutDirectory)\s+'([^']*\.json)'")) {
      $rel = $m.Groups[1].Value
      if ($rel -match '(?i)regression-inputs') { continue }
      $leaf = ($rel -split '[\\/]')[-1]
      if ($ConfigOk -contains $leaf) { continue }
      [void]$out.Add($leaf)
    }
  }
  return ,@($out.ToArray() | Sort-Object -Unique)
}

if ($SelfTest) {
  $fail = 0
  function FiT([string]$m, [bool]$c) { if ($c) { Write-Output ('  PASS  ' + $m) } else { Write-Output ('  FAIL  ' + $m); $script:fail++ } }

  # MUST FIRE: the founding shape - a self-test loading the live ledger.
  $src = "if (`$SelfTest) {`n  `$blocks = Get-KnownWrongBlocks -Path (Join-Path `$root 'known-wrong.json')`n}`n"
  $b = Get-SelfTestBlock -Text $src
  FiT 'MUST FIRE: a -SelfTest that reads the live known-wrong.json is a finding' `
      ((Get-UnpinnedReads -Text $b).Count -eq 1)
  # CLEAN TWIN 1: the same read, frozen.
  $src2 = "if (`$SelfTest) {`n  `$b = Get-KnownWrongBlocks -Path (Join-Path `$root 'regression-inputs\guard-fixtures\known-wrong-fixture.json')`n}`n"
  FiT 'CLEAN TWIN: the same path under regression-inputs\ is frozen and silent' `
      ((Get-UnpinnedReads -Text (Get-SelfTestBlock -Text $src2)).Count -eq 0)
  # CLEAN TWIN 2: the same text in a comment.
  $src3 = "if (`$SelfTest) {`n  # once read (Join-Path `$root 'known-wrong.json') and that was the bug`n}`n"
  FiT 'CLEAN TWIN: the same path in a comment is not a read' `
      ((Get-UnpinnedReads -Text (Get-SelfTestBlock -Text $src3)).Count -eq 0)
  # CLEAN TWIN 3: parameterised, with the live path only as the default - and DECLARED live.
  $src4 = "if (`$SelfTest) {`n  # LIVE-TWIN: the shipped ledger must still load`n  `$l = Get-KnownWrongBlocks -Path (Join-Path `$root 'known-wrong.json')`n}`n"
  FiT 'CLEAN TWIN: a read the author DECLARED as a LIVE-TWIN is not a finding' `
      ((Get-UnpinnedReads -Text (Get-SelfTestBlock -Text $src4)).Count -eq 0)
  # CLEAN TWIN 4: config is not a ruling.
  $src5 = "if (`$SelfTest) {`n  `$s = Read-JsonFile (Join-Path `$root 'stores.json')`n}`n"
  FiT 'CLEAN TWIN: a config registry is not a ruling anybody adjudicates' `
      ((Get-UnpinnedReads -Text (Get-SelfTestBlock -Text $src5) -ConfigOk $CONFIG_OK).Count -eq 0)
  # MUST FIRE: the block extractor must not stop at the first nested brace, or it reads three cases of forty.
  $src6 = "if (`$SelfTest) {`n  foreach (`$x in 1..3) { `$y = `$x }`n  `$z = Read-JsonFile (Join-Path `$root 'known-wrong.json')`n}`n"
  FiT 'MUST FIRE: a read AFTER a nested scriptblock is still inside the self-test' `
      ((Get-UnpinnedReads -Text (Get-SelfTestBlock -Text $src6)).Count -eq 1)
  # CLEAN TWIN 5: a read OUTSIDE the self-test block is the production path and none of this audit's business.
  $src7 = "if (`$SelfTest) {`n  `$a = 1`n}`n`$blocks = Read-JsonFile (Join-Path `$root 'known-wrong.json')`n"
  FiT 'CLEAN TWIN: the production path reading its own live rulings is not a finding' `
      ((Get-UnpinnedReads -Text (Get-SelfTestBlock -Text $src7)).Count -eq 0)
  # MUST FIRE: a file with NO self-test yields no block, and no block must yield no findings - never a
  # silent pass that looked at something else.
  FiT 'CLEAN TWIN: a script with no -SelfTest block contributes nothing' `
      ((Get-SelfTestBlock -Text "Write-Output 'hello'").Length -eq 0)
  # THE UNBALANCED BRACE INSIDE A STRING - rebid-ingredient's source pin. Counting it made the block run to
  # end-of-file and report three of the PRODUCTION path's reads against a self-test that never runs them.
  $src8 = "if (`$SelfTest) {`n  `$g = `$src.IndexOf(`"if (-not `$Apply) { Write-Output`")`n}`n`$f = Read-JsonFile (Join-Path `$root 'smp-feed.json')`n"
  FiT 'MUST FIRE: an unbalanced brace inside a STRING does not extend the block past its own closing brace' `
      ((Get-UnpinnedReads -Text (Get-SelfTestBlock -Text $src8)).Count -eq 0)
  # ...and the mask must not eat the paths. Same file, one real read INSIDE the block.
  $src9 = "if (`$SelfTest) {`n  `$g = `$src.IndexOf(`"{ unbalanced`")`n  `$b = Read-JsonFile (Join-Path `$root 'known-wrong.json')`n}`n"
  FiT 'CLEAN TWIN: masking strings for the brace count does not hide a quoted path from the scan' `
      ((Get-UnpinnedReads -Text (Get-SelfTestBlock -Text $src9)).Count -eq 1)
  # THE MULTI-LINE LIVE-TWIN DECLARATION: the reason takes several comment lines and the marker is on the first.
  $srcA = "if (`$SelfTest) {`n  # LIVE-TWIN, labelled.`n  # A red here means the live file changed,`n  # not that this watcher went blind.`n  `$l = Read-JsonFile (Join-Path `$root 'known-wrong.json')`n}`n"
  FiT 'CLEAN TWIN: a LIVE-TWIN marker anywhere in the comment block above the read still declares it' `
      ((Get-UnpinnedReads -Text (Get-SelfTestBlock -Text $srcA)).Count -eq 0)
  # ...but a marker separated from the read by real CODE declares nothing - or one label would exempt a file.
  $srcB = "if (`$SelfTest) {`n  # LIVE-TWIN: this one is deliberate`n  `$a = Read-JsonFile (Join-Path `$root 'stores.json')`n  `$b = Read-JsonFile (Join-Path `$root 'known-wrong.json')`n}`n"
  FiT 'MUST FIRE: a LIVE-TWIN label does not carry past the line of code it precedes' `
      ((Get-UnpinnedReads -Text (Get-SelfTestBlock -Text $srcB) -ConfigOk $CONFIG_OK).Count -eq 1)

  if ($fail) { Write-Output "FIXTURE-INPUTS SELF-TEST FAILED ($fail)"; exit 2 }
  Write-Output 'FIXTURE-INPUTS SELF-TEST PASSED (the founding shape armed, and every declaration that makes a read lawful holds)'
  exit 0
}

# ---- live path -----------------------------------------------------------------------------------------
$scripts = @(Get-ChildItem $repo -Recurse -File -Filter *.ps1 -ErrorAction SilentlyContinue |
  Where-Object { $_.FullName -notmatch '\\worktrees\\|\\archive\\|node_modules|\.venv|\\out\\' } |
  Sort-Object FullName)

$found = New-Object System.Collections.ArrayList
$withSelfTest = 0
foreach ($s in $scripts) {
  $txt = [IO.File]::ReadAllText($s.FullName)
  $blk = Get-SelfTestBlock -Text $txt
  if (-not $blk) { continue }
  $withSelfTest++
  $rel = $s.FullName.Replace($repo, '').TrimStart('\')
  foreach ($leaf in (Get-UnpinnedReads -Text $blk -ConfigOk $CONFIG_OK)) { [void]$found.Add($rel + '|' + $leaf) }
}
if (-not $withSelfTest) {
  Write-Output 'audit-fixture-inputs: BLIND - found no -SelfTest blocks at all, which means this discovery is broken, not that the tree is clean'
  Write-GuardComplete -Name 'audit-fixture-inputs' -Summary 'blind=no-selftests'
  exit 3
}
$now = @($found.ToArray() | Sort-Object -Unique)

$baseFile = Join-Path $PSScriptRoot 'fixture-input-baseline.json'
if ($Update) {
  Write-JsonFile -Path $baseFile -Content ([ordered]@{
    readme  = 'Baseline for ops\audit-fixture-inputs.ps1: the -SelfTest blocks that still read a LIVE rulings file. Written by -Update, which is a deliberate act after a real repair. The ratchet is BY NAME: a new entry fails the audit, and an entry that disappears is reported so this file can be trimmed. It may only ever get shorter.'
    written = (Get-Date).ToString('yyyy-MM-dd')
    entries = $now
  }) -Depth 6
  Write-Output ("audit-fixture-inputs: baseline rewritten with {0} entr(y/ies)" -f $now.Count)
  exit 0
}

$base = @()
if (Test-Path -LiteralPath $baseFile) { try { $base = @((Read-JsonFile $baseFile).entries | Where-Object { $_ }) } catch { $base = @() } }
$added   = @($now  | Where-Object { $base -notcontains $_ })
$cleared = @($base | Where-Object { $now  -notcontains $_ })

Write-Output ("audit-fixture-inputs: {0} script(s) with a -SelfTest block; {1} live-rulings dependenc(y/ies), baseline {2}" -f $withSelfTest, $now.Count, $base.Count)
foreach ($c in $cleared) { Write-Output ('  cleared: ' + $c + '  (ratchet tightened - re-run with -Update to trim the baseline)') }
foreach ($a in $added) { Write-Output ('  ! NEW: ' + $a) }
if ($added.Count) {
  Write-Output '  A self-test whose verdict depends on a live rulings file can be turned red by a correct edit'
  Write-Output '  somewhere else, and - worse - a ruling change can quietly alter what its clean twin proves.'
  Write-Output '  Fix: add a -SomethingFile parameter defaulting to the live path, freeze a copy under'
  Write-Output '  regression-inputs\guard-fixtures\, and drive the self-test from that. Keep the live read only'
  Write-Output '  where you MEAN it, and mark that line LIVE-TWIN so a red there is read as "live data changed".'
}
Write-GuardComplete -Name 'audit-fixture-inputs' -Summary ("{0} dependenc(y/ies), {1} new" -f $now.Count, $added.Count)
if ($added.Count) { exit 1 }
exit 0
