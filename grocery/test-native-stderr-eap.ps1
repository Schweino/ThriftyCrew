<#
  test-native-stderr-eap.ps1 - the frozen fixture for the 2026-08-22 exit-1 bug, and the repo-wide watcher for its class.

  FOUNDING BUG. capture-run.ps1 sets $ErrorActionPreference='Stop' and invoked its
  downstream child as:
        & powershell ... -File check-ad-cycles.ps1 -NoPull 2>&1 | ForEach-Object {...}
  In PS 5.1, redirecting a NATIVE child's stderr wraps every line in an ErrorRecord
  (NativeCommandError). Under EAP=Stop the FIRST such line is a TERMINATING error, so
  the caller died mid-script: no rc line, no browser handoff, no CAPTURE-RUN-COMPLETE,
  exit 1. 'TC Grocery Ad Pulls 0700' and 'TC Grocery Daily Capture 0800' both showed
  LastTaskResult=1 for days and the cause was invisible because the tasks ran hidden
  with no transcript. check-ad-cycles.ps1 already documented this exact rule in its own
  comments; the caller just did not follow it.

  WHY A FIXTURE AND NOT A CODE READ. The failure is a PROPERTY OF THE SHELL, not of our
  logic, so the only honest check is to make the shell do it. This file therefore has a
  MUST-FIRE case (the founding bug, which must still fail) and a CLEAN TWIN (the fixed
  shape, which must pass). If the must-fire case ever stops failing, this test is no
  longer testing anything and must be re-examined rather than trusted.

  THE WATCHER (CASE 5) READS THE WHOLE REPO SINCE 2026-09-11. It walked grocery\ only, so the
  class went unwatched in ops\, meal-prep\, graph\, lib\ and tools\. It was found there when
  meal-prep\pipeline\wave-preaudit.ps1's -SelfTest drill (`$out = & powershell @a 2>&1`) died
  mid-suite with no FAIL line and no summary. Widening the walk showed the line regex it used
  was blind three more ways, and it was replaced by a read of the PowerShell AST (CASE 4 has the
  account). Measured the same day, at 0a681beb0 before any fix and with out\ still walked: 614
  .ps1, 476 set 'Stop', 71 unguarded sites, 26 of them invisible to the old regex, and 22 of the
  old regex's 67 hits guarded or not code at all. design\TRIAGE-native-stderr-eap-2026-09-11.md
  rules on every one.

  SCOPE OF A CLEAN REPORT: UNSOUND, so a clean report proves nothing, and it is a named-site
  RATCHET for exactly that reason. It finds the shapes it knows:
    * a native command is recognised by NAME ($NativeName below) or by a VARIABLE named like one
      ($py, $NodeExe, $PSEXE). `& $cmd` under any other name, or a path built inline, is not seen.
    * the error preference is read LEXICALLY, from assignments that precede the call in its
      enclosing blocks. A function inherits its CALLER's preference at run time, which a lexical
      read cannot follow; and a library that never sets 'Stop' itself is not scanned, although
      every caller that dot-sources it runs it under 'Stop'.
    * \out\, \archive\, node_modules and sibling worktrees are not walked.
  A reported site is a native redirect under a preference this could not read as 'Continue'.

  THE RATCHET NAMES SITES, IT DOES NOT COUNT THEM. The baseline, native-stderr-eap-baseline.json,
  lists each known site as `path|command`, with no line number, so a site that only moves keeps
  its name. A site not in it fails the run, even when the total fell (a fix and a new one in the
  same change). A fall is SPOKEN and NOT written by a plain run, because run-gates runs this at
  push time and a rewrite would dirty the checkout being pushed; -Tighten records a believable
  fall through lib\ratchet.ps1's plausibility bar, -Accept records the current sites whatever
  they are.

  Usage:
    powershell -File grocery\test-native-stderr-eap.ps1            every case, plus the repo scan against the baseline; writes nothing
    powershell -File grocery\test-native-stderr-eap.ps1 -Tighten   the same, and record a believable fall as the new baseline
    powershell -File grocery\test-native-stderr-eap.ps1 -Accept    record the current sites as the baseline

  Exit 0 = all cases behaved. 1 = a case regressed or a NEW site appeared. 3 = could not evaluate:
  a library would not load, or the walk found too few scripts to be the real tree.
#>
[CmdletBinding()]
param([switch]$Tighten, [switch]$Accept, [string]$BaselineFile = '')

$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repo = Split-Path $root -Parent
# A LIBRARY THAT CANNOT LOAD IS EXIT 3, NEVER A RUN OVER NOTHING. Under 'Continue' a missing dot-source prints
# "is not recognized" and carries on, and every scan below would then report clean over a function that does
# not exist (ops-and-gates.md, 2026-09-11). So they load under 'Stop' inside a try.
try {
  $ErrorActionPreference = 'Stop'
  . (Join-Path $repo 'lib\tree-walk.ps1')   # Get-TcPathBelowRoot: exclusions match below the root, so a worktree root is scanned
  . (Join-Path $repo 'lib\ratchet.ps1')     # Test-RatchetMove: a fall clears a plausibility bar before -Tighten records it
  . (Join-Path $repo 'lib\lf-write.ps1')    # Write-TcLfFile: the baseline is tracked and stored eol=lf
} catch {
  Write-Output ('  FAIL  a library would not load, so nothing below could be evaluated: ' + $_.Exception.Message)
  Write-Output 'NATIVE-STDERR-EAP-TEST-COMPLETE cases=0 failed=1 blind=lib-load'
  exit 3
}
# THIS FILE RUNS UNDER 'Continue' ON PURPOSE. CASE 1 performs the founding shape in a CHILD so the child dies, never
# this process, and Invoke-Case below reads each child with a redirect, which this statement keeps non-terminating.
$ErrorActionPreference = 'Continue'

# LIVE-TWIN, AND DELIBERATELY SO (ops\audit-fixture-inputs.ps1 reads this label). CASE 5's verdict rests on this
# file, and that is the gate rather than a leak: the baseline is a ratchet's high-water mark over the LIVE tree,
# not a ruling somebody adjudicates, so a red here means a new site appeared in the tree this run walked. Freezing
# it would leave the repo unwatched, which is the whole failure this file exists to end. -BaselineFile drives the
# same code from a frozen copy where a fixture needs one.
$BASELINE_FILE = if ($BaselineFile) { $BaselineFile } else { Join-Path $root 'native-stderr-eap-baseline.json' }
$tmp = Join-Path $env:TEMP ("eap-fixture-" + $PID)
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$fail = 0
$n = 0
$blind = ''

function Invoke-Case([string]$Name, [string]$Body) {
  $p = Join-Path $tmp ($Name + '.ps1')
  Set-Content -Path $p -Value $Body -Encoding UTF8
  $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $p 2>$null
  return [pscustomobject]@{ Rc = $LASTEXITCODE; Out = (@($out) -join "`n") }
}

# One assertion, counted. The CASE 1-3b blocks below keep their own wording; the watcher cases use this.
function Check([string]$Name, [bool]$Ok, [string]$Got) {
  $script:n++
  if ($Ok) { Write-Output ('  ok    ' + $Name) } else { Write-Output ('  FAIL  ' + $Name + '   got: ' + $Got); $script:fail++ }
}

# --- CASE 1: MUST-FIRE. The founding bug, verbatim in shape. -----------------
# A child that writes ONE stderr line and exits 0, redirected with 2>&1 under EAP=Stop.
# Correct behaviour for this case is FAILURE: rc=1 and the completion marker missing.
$n++
$c1 = Invoke-Case 'mustfire' @'
$ErrorActionPreference = 'Stop'
& powershell -NoProfile -Command "[Console]::Error.WriteLine('a warning line'); exit 0" 2>&1 | ForEach-Object { $_ }
Write-Output "COMPLETE-MARKER"
exit 0
'@
if ($c1.Rc -eq 1 -and $c1.Out -notmatch 'COMPLETE-MARKER') {
  Write-Output "  ok    must-fire: 2>&1 under EAP=Stop still kills the caller (rc=$($c1.Rc), no marker)"
} else {
  Write-Output "  FAIL  must-fire: expected rc=1 and NO marker, got rc=$($c1.Rc) marker=$($c1.Out -match 'COMPLETE-MARKER')"
  Write-Output "        This case existing-and-failing is what proves the fix below is load-bearing."
  $fail++
}

# --- CASE 2: CLEAN TWIN. The shipped fix. ------------------------------------
# Same child, same stderr, same EAP=Stop - but no redirection. Must survive, must
# reach its marker, and must still read the child's real exit code.
$n++
$c2 = Invoke-Case 'cleantwin' @'
$ErrorActionPreference = 'Stop'
$out = & powershell -NoProfile -Command "[Console]::Error.WriteLine('a warning line'); Write-Output 'child said hello'; exit 0"
$rc = $LASTEXITCODE
foreach ($l in @($out)) { Write-Output ("  " + $l) }
Write-Output ("downstream rc=" + $rc)
Write-Output "COMPLETE-MARKER"
exit 0
'@
if ($c2.Rc -eq 0 -and $c2.Out -match 'COMPLETE-MARKER' -and $c2.Out -match 'downstream rc=0') {
  Write-Output "  ok    clean-twin: unredirected child survives stderr and reports rc"
} else {
  Write-Output "  FAIL  clean-twin: expected rc=0 + marker + 'downstream rc=0', got rc=$($c2.Rc)"
  Write-Output ("        output: " + ($c2.Out -replace "`n", ' | '))
  $fail++
}

# --- CASE 3: the fix must still PROPAGATE a real child failure ---------------
# The danger in "just stop redirecting" is over-correcting into swallowing failures.
# A child that genuinely exits non-zero must still be seen as failed.
$n++
$c3 = Invoke-Case 'realfail' @'
$ErrorActionPreference = 'Stop'
$out = & powershell -NoProfile -Command "Write-Output 'work'; exit 4"
$rc = $LASTEXITCODE
Write-Output ("downstream rc=" + $rc)
if ($rc -ne 0) { exit 1 } else { exit 0 }
'@
if ($c3.Rc -eq 1 -and $c3.Out -match 'downstream rc=4') {
  Write-Output "  ok    real-failure: a genuinely failing child is still detected (rc=4 -> caller rc=1)"
} else {
  Write-Output "  FAIL  real-failure: expected caller rc=1 and 'downstream rc=4', got rc=$($c3.Rc)"
  $fail++
}

# --- CASE 3a: a CATCH IS NOT A GUARD (2026-09-11) -----------------------------
# Several sites wrapped the redirect in try { } catch { } and read as handled. The caller does survive, and the
# child's answer is thrown away with the error, so a warning on stderr read as an EMPTY result: a staged set with
# no files, a commit with no hash. This case keeps that measured, so the watcher's refusal to accept a catch as a
# guard rests on the shell's behaviour rather than on an opinion.
$n++
$c3a = Invoke-Case 'catchloses' @'
$ErrorActionPreference = 'Stop'
$v = @('unset')
try { $v = @(& powershell -NoProfile -Command "[Console]::Error.WriteLine('a warning line'); Write-Output 'the answer'; exit 0" 2>$null) } catch { $v = @('CAUGHT') }
Write-Output ("v=" + ($v -join '|'))
exit 0
'@
if ($c3a.Rc -eq 0 -and $c3a.Out -match 'v=CAUGHT' -and $c3a.Out -notmatch 'the answer') {
  Write-Output "  ok    catch-loses-the-answer: a try/catch around the redirect survives and LOSES the child's stdout (v=CAUGHT)"
} else {
  Write-Output ("  FAIL  catch-loses-the-answer: expected rc=0 and v=CAUGHT with no 'the answer', got rc=$($c3a.Rc) out=" + ($c3a.Out -replace "`n", ' | '))
  Write-Output "        If a catch now keeps the answer, PS changed and the watcher's rule about catches must be re-examined."
  $fail++
}

# --- CASE 3b: the browser driver's agent contract ----------------------------
# The browser driver (pull-browser-stores.py) injects pull-agent-lib.js + a store agent and calls
# functions BY NAME. If an agent renames its entry point or its storage key, the driver breaks at
# 08:00 with a ReferenceError that reads like a store outage. The driver's own --selftest proves this
# against a live browser, but that costs a Chrome launch per store; this is the cheap source-level
# half, so a rename is caught by the daily suite rather than by a red task.
$n++
$drvPath = Join-Path $root 'pull-browser-stores.py'
if (-not (Test-Path $drvPath)) {
  Write-Output '  skip  browser-driver contract: pull-browser-stores.py not present'
} else {
  $drv = Get-Content $drvPath -Raw
  $contractBad = @()
  # TWO LANES, TWO CONTRACTS (updated 2026-08-22 when Fareway moved lanes - and this check FAILED on
  # that change, which is the point of it).
  #   paced   Walmart, Sam's Club: runPacedSweep over a term list, results in localStorage under a
  #           storage key, exported by a *SweepToCsv function.
  #   navigate Fareway: the storefront went client-rendered, so there is nothing for a same-origin
  #           fetch to read. The driver navigates per term and calls farewayShopExtract, which reads
  #           the Apollo cache. No sweep function, no storage key - asserting them here would be
  #           asserting the dead contract. farewayIdentity still comes from the instore file and is
  #           load-bearing: it proves BOTH the Omaha location and In-Store mode, which is what
  #           licenses -ModeVerified downstream.
  foreach ($pair in @(
      @{ Agent = 'pull-walmart-instore.js'; Fns = @('pullWalmartInStore', 'walmartSweepToCsv'); Key = 'TC_WALMART_SWEEP' },
      @{ Agent = 'pull-sams-instore.js';    Fns = @('pullSamsInStore', 'samsSweepToCsv');       Key = 'TC_SAMS_SWEEP' },
      @{ Agent = 'pull-fareway-instore.js'; Fns = @('farewayIdentity');                         Key = '' },
      @{ Agent = 'pull-fareway-shop.js';    Fns = @('farewayShopExtract');                      Key = '' })) {
    $ap = Join-Path $root $pair.Agent
    if (-not (Test-Path $ap)) { $contractBad += ($pair.Agent + ' is missing'); continue }
    $asrc = Get-Content $ap -Raw
    foreach ($fn in $pair.Fns) {
      if ($asrc -notmatch [regex]::Escape($fn)) { $contractBad += ("$($pair.Agent) no longer defines $fn") }
      if ($drv  -notmatch [regex]::Escape($fn)) { $contractBad += ("the driver no longer calls $fn") }
    }
    if ($pair.Key) {
      if ($asrc -notmatch [regex]::Escape($pair.Key)) { $contractBad += ("$($pair.Agent) no longer uses $($pair.Key)") }
      if ($drv  -notmatch [regex]::Escape($pair.Key)) { $contractBad += ("the driver no longer expects $($pair.Key)") }
    }
  }
  # Fareway's In-Store assertion is the whole basis for stamping -ModeVerified from a script. If it
  # ever stops asserting the mode, that flag becomes a claim nobody checked.
  $fwId = Get-Content (Join-Path $root 'pull-fareway-instore.js') -Raw -ErrorAction SilentlyContinue
  if ($fwId -and $fwId -notmatch 'In-Store') {
    $contractBad += 'farewayIdentity no longer asserts In-Store - capture-run stamps -ModeVerified on the strength of it'
  }
  if (-not $contractBad.Count) {
    Write-Output '  ok    browser-driver contract: every agent entry point and storage key the driver names still exists'
  } else {
    Write-Output ('  FAIL  browser-driver contract drift: ' + ($contractBad -join '; '))
    Write-Output '        The 08:00 capture calls these BY NAME - a rename fails the pull, not the test.'
    $fail++
  }
}

# --- THE SHARED RULE, AND CASE 4: THE WATCHER MUST PROVE IT CAN STILL SEE --------
# ON 2026-08-23 THIS SCANNER WAS FOUND TO BE STRUCTURALLY BLIND. When it was "widened"
# on 08-22 a stray U+0008 (backspace) got into the pattern, right after the alternation
# group. No source line contains a backspace, so the regex could not match ANYTHING. It
# reported "ok" for a day while watching nothing - and in that day `& git fetch origin main
# 2>$null` was written into capture-run's push stage and killed the 07:00 run. A green
# watcher and a dead watcher looked identical.
#
# So the rule lives in ONE place, used by BOTH the self-proof below and the tree scan, and
# the self-proof runs FIRST. A watcher that cannot demonstrate a catch on a frozen known-bad
# line is reported as BROKEN, never as clean.
#
# 2026-09-11: THE ONE PLACE IS NOW A READ OF THE POWERSHELL AST, NOT A LINE REGEX. Walking the whole
# repo showed the regex blind in three ways, each with a live site behind it, and noisy in three more:
#   MISSED  a call continued over a backtick (wave-publish's update-recipes-db -DryRun, in the publish path),
#           `*>&1` (fourteen in grocery\apply-coverage-batch.ps1), and a bare `git ... 2>&1` with no `&`.
#   MISSED  EVERYTHING after any line that merely MENTIONED Start-Job, until a `} -ArgumentList` line: a
#           comment was enough, which is how wave-preaudit's second drill and three check-ad-cycles and
#           test-auditors sites were never read.
#   FALSE   a redirect quoted in a block comment or a here-string, and a preference set to 'Continue'
#           for a whole self-test block or a whole script more than 8 lines above the call.
# The AST sees a redirection only where one executes, one call however many lines it spans, and the
# preference assignment wherever it sits in an enclosing block.
$NativeName = '^(?i)(powershell|pwsh|git|python3?|py|node|npm|npx|wrangler|cmd|robocopy|taskkill|nvidia-smi|schtasks|icacls|curl|where|llama-server)(\.exe|\.cmd)?$'
$NativeVar  = '(?i)^(py|python\d*|node|git)$|exe$'
$ScanExclude = '\\archive\\|\\worktrees\\|\\out\\|\\node_modules\\|^\\\.git\\'
# 476 scripts set 'Stop' on 2026-09-11 at 0a681beb0. A walk that finds fewer than 250 has lost most of the tree,
# not cleaned it. First plausible value, not the survivor of a sweep.
$ScanFloor = 250

function Test-TcNativeCommand {
  # A command is NATIVE when its name is a known executable, or it is invoked through a variable named like one.
  param($Cmd)
  $name = $Cmd.GetCommandName()
  if ($name) { return ((([string]$name) -split '[\\/]')[-1] -match $script:NativeName) }
  $e0 = $Cmd.CommandElements[0]
  if ($e0 -is [System.Management.Automation.Language.VariableExpressionAst]) { return ([string]$e0.VariablePath.UserPath -match $script:NativeVar) }
  return $false
}

function Test-TcEapAssignment($X) {
  return ($X -is [System.Management.Automation.Language.AssignmentStatementAst] -and
          $X.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
          ([string]$X.Left.VariablePath.UserPath) -match '^(?i)((global|script|local):)?ErrorActionPreference$')
}

function Get-TcEapValue($Assignment) {
  $v = $Assignment.Right.Extent.Text.Trim().Trim("'", '"')
  if ($v -match '^(?i)(Continue|SilentlyContinue|Ignore)$') { return 'continue' }
  if ($v -match '^(?i)Stop$') { return 'stop' }
  return 'restore'
}

function Test-TcInNestedScope($Node, $Stop) {
  # True when $Node sits in a function body or a scriptblock below $Stop: an assignment there is not $Stop's block's.
  $q = $Node.Parent
  while ($null -ne $q -and -not [object]::ReferenceEquals($q, $Stop)) {
    if ($q -is [System.Management.Automation.Language.FunctionDefinitionAst] -or $q -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) { return $true }
    $q = $q.Parent
  }
  return $false
}

function Get-TcEapInForce {
  <# The error preference a node runs under, read lexically: 'continue', 'stop', 'restore' (set back from a variable,
     so whatever the caller had, which in these scripts is 'Stop'), 'conditional' (set inside a branch that may not
     have run), 'job' (a Start-Job scriptblock, which runs in a fresh runspace at the default 'Continue'), or 'none'.
     The nearest preceding statement that sets it, in the nearest enclosing block, decides. So
     `$prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'` ahead of a try guards the call inside it,
     and a call AFTER that try is 'conditional', never guarded by the 'Continue' above it. #>
  param($Node)
  $child = $Node
  $p = $Node.Parent
  while ($null -ne $p) {
    if ($p -is [System.Management.Automation.Language.ScriptBlockExpressionAst] -and
        $p.Parent -is [System.Management.Automation.Language.CommandAst] -and
        ([string]$p.Parent.GetCommandName()) -match '^(?i)(Start-Job|Start-ThreadJob)$') { return 'job' }
    if ($p -is [System.Management.Automation.Language.StatementBlockAst] -or $p -is [System.Management.Automation.Language.NamedBlockAst]) {
      $st = @($p.Statements)
      $idx = -1
      for ($k = 0; $k -lt $st.Count; $k++) { if ([object]::ReferenceEquals($st[$k], $child)) { $idx = $k; break } }
      for ($k = $idx - 1; $k -ge 0; $k--) {
        $s = $st[$k]
        if (Test-TcEapAssignment $s) { return (Get-TcEapValue $s) }
        # A function defined here sets nothing for this block when it is defined.
        if ($s -is [System.Management.Automation.Language.FunctionDefinitionAst]) { continue }
        # A COMPOUND STATEMENT THAT SETS THE PREFERENCE ANYWHERE INSIDE ITSELF decides it too, as 'conditional', which
        # is not a guard (found 2026-09-11 in review: the scoped shape's own restore sits in a finally, and a redirect
        # one statement after that try was read as guarded by the 'Continue' above it). Whether a branch ran, or what
        # value a try left behind, is not readable here, and the only reading that cannot hide a site is unguarded.
        $inner = @($s.FindAll({ param($x) Test-TcEapAssignment $x }, $true) | Where-Object { -not (Test-TcInNestedScope $_ $s) })
        if ($inner.Count) { return 'conditional' }
      }
    }
    $child = $p
    $p = $p.Parent
  }
  return 'none'
}

function Get-TcNativeStderrSites {
  <# Every NATIVE command in $Text that redirects its error stream (2>, *>, merged or to a file), with the
     preference in force. Parsed, never matched line by line. Returns Sites (Line, Eap, Command with its
     whitespace and backtick continuations folded) and the parser's error count. #>
  param([string]$Text)
  $tokens = $null
  $errors = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errors)
  $sites = New-Object System.Collections.ArrayList
  $cmds = $ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.CommandAst] -and $x.Redirections.Count -gt 0 }, $true)
  foreach ($c in $cmds) {
    $toErr = $false
    foreach ($r in $c.Redirections) { if ([string]$r.FromStream -eq 'Error' -or [string]$r.FromStream -eq 'All') { $toErr = $true } }
    if (-not $toErr) { continue }
    if (-not (Test-TcNativeCommand $c)) { continue }
    $cmdText = (($c.Extent.Text -replace '`[ \t]*\r?\n', ' ') -replace '\s+', ' ').Trim()
    [void]$sites.Add([pscustomobject]@{ Line = $c.Extent.StartLineNumber; Eap = (Get-TcEapInForce $c); Command = $cmdText })
  }
  return [pscustomobject]@{ Sites = @($sites.ToArray()); ParseErrors = @($errors).Count }
}

function Test-TcGuarded([string]$Eap) {
  # The only two readings under which a native stderr line cannot terminate the caller. Every other reading is a site.
  return ($Eap -eq 'continue' -or $Eap -eq 'job')
}

function Get-TcUnguardedCount([string]$Text) {
  $r = Get-TcNativeStderrSites -Text $Text
  $u = @($r.Sites | Where-Object { -not (Test-TcGuarded $_.Eap) })
  return $u.Count
}

function Invoke-TcEapScan {
  <# The CASE 5 walk as one function over a root, so the self-proof points it at a fixture tree and the live run at
     the repo. Only a script that sets 'Stop' is judged. Returns Walked, Scanned, ScannedRel, Sites (unguarded, each
     with its ratchet Key), Guarded, Unparsed. #>
  param([string]$RootDir, [string]$Self = '')
  $rootFull = Get-TcRootFull $RootDir
  # NEVER SCAN YOURSELF (ops-and-gates.md). The AST cannot read this file's fixtures as calls, since they are strings,
  # but the rule is cheaper to keep than to argue with, and this file sets no 'Stop' around a native call of its own.
  $files = @(Get-ChildItem -LiteralPath $rootFull -Recurse -File -Filter *.ps1 -ErrorAction SilentlyContinue |
             Where-Object { (Get-TcPathBelowRoot $_.FullName $rootFull) -notmatch $script:ScanExclude -and $_.FullName -ne $Self })
  $scannedRel = New-Object System.Collections.ArrayList
  $sites = New-Object System.Collections.ArrayList
  $guarded = New-Object System.Collections.ArrayList
  $unparsed = New-Object System.Collections.ArrayList
  foreach ($fi in $files) {
    $rel = (Get-TcPathBelowRoot $fi.FullName $rootFull).TrimStart('\')
    $text = $null
    try { $text = [IO.File]::ReadAllText($fi.FullName) } catch { [void]$unparsed.Add($rel); continue }
    # ONLY A SCRIPT THAT SETS 'Stop' CAN HAVE THIS BUG IN ITS OWN CODE. Everything else redirects harmlessly.
    if ($text -notmatch "(?mi)^\s*\`$((global|script):)?ErrorActionPreference\s*=\s*['""]Stop['""]") { continue }
    [void]$scannedRel.Add($rel)
    if ($text -notmatch '[2*]>') { continue }
    $r = Get-TcNativeStderrSites -Text $text
    if ($r.ParseErrors -gt 0) { [void]$unparsed.Add($rel) }
    foreach ($s in $r.Sites) {
      $rec = [pscustomobject]@{ Rel = $rel; Line = $s.Line; Eap = $s.Eap; Command = $s.Command; Key = ($rel + '|' + $s.Command) }
      if (Test-TcGuarded $s.Eap) { [void]$guarded.Add($rec) } else { [void]$sites.Add($rec) }
    }
  }
  return [pscustomobject]@{ Walked = $files.Count; Scanned = $scannedRel.Count; ScannedRel = @($scannedRel.ToArray())
                            Sites = @($sites.ToArray()); Guarded = @($guarded.ToArray()); Unparsed = @($unparsed.ToArray()) }
}

function Compare-TcSiteBaseline {
  <# NAMES AGAINST THE BASELINE, NEVER A COUNT. A count that held while one site was fixed and another added reads
     as 'held'; a named comparison calls the new one new. Keys compare ORDINALLY: a bare @{} is case-insensitive.
     Returns Verdict 'rose' | 'fell' | 'held', New (one entry per occurrence above the baseline), Gone. #>
  param([string[]]$Current, [string[]]$Baseline)
  $cur = New-Object 'System.Collections.Generic.Dictionary[string,int]' ([StringComparer]::Ordinal)
  $base = New-Object 'System.Collections.Generic.Dictionary[string,int]' ([StringComparer]::Ordinal)
  foreach ($k in @($Current)) { if ($null -eq $k) { continue }; if ($cur.ContainsKey($k)) { $cur[$k] = $cur[$k] + 1 } else { $cur[$k] = 1 } }
  foreach ($k in @($Baseline)) { if ($null -eq $k) { continue }; if ($base.ContainsKey($k)) { $base[$k] = $base[$k] + 1 } else { $base[$k] = 1 } }
  $new = New-Object System.Collections.ArrayList
  $gone = New-Object System.Collections.ArrayList
  foreach ($k in $cur.Keys) { $b = 0; if ($base.ContainsKey($k)) { $b = $base[$k] }; for ($i = $b; $i -lt $cur[$k]; $i++) { [void]$new.Add($k) } }
  foreach ($k in $base.Keys) { $c = 0; if ($cur.ContainsKey($k)) { $c = $cur[$k] }; for ($i = $c; $i -lt $base[$k]; $i++) { [void]$gone.Add($k) } }
  $verdict = if ($new.Count) { 'rose' } elseif ($gone.Count) { 'fell' } else { 'held' }
  return [pscustomobject]@{ Verdict = $verdict; New = @($new.ToArray()); Gone = @($gone.ToArray()) }
}

function ConvertTo-TcJsonText([string]$s) {
  # A minimal JSON string. ConvertTo-Json under PS 5.1 writes & ' < > as \u escapes, which leaves a baseline of
  # shell commands unreadable in a diff; every character a command can hold is legal JSON once \ and " are escaped.
  return ('"' + $s.Replace('\', '\\').Replace('"', '\"').Replace("`t", '\t') + '"')
}

$n++
# FROZEN FIXTURES. Every real shape that has ever hurt us, plus the legal shapes that must never be accused. The
# six single lines of each list are the 2026-08-23 originals; the rest were added 2026-09-11 from the sites the
# repo-wide walk found.
$mustCatch = @(
  '      & git -C $repo fetch origin main 2>$null',                                  # the 2026-08-23 07:00 killer
  '  & git -C $repo add -A -- $paths 2>$null',                                       # the 2026-08-22 publish killer
  '    & powershell -NoProfile -File $cac -NoPull 2>&1 | ForEach-Object { $_ }',     # the founding bug
  '  $lastBot = (& git -C $r log -1 --format=%cd 2>$null | Select-Object -First 1)', # capture-watchdog, found blind
  '        $ceOut = & powershell -File (Join-Path $root "a.ps1") 2>$null',           # check-ad-cycles, found blind
  '    $q = & nvidia-smi --query-gpu=memory.free --format=csv 2>$null',
  '& powershell -ExecutionPolicy Bypass -File (Join-Path $root ''compare-deals.ps1'') *>&1 | Out-Null',   # apply-coverage-batch, *>&1
  'try { git -C $repoRoot pull --rebase --autostash origin main 2>&1 | Select-Object -Last 1 } catch { }', # bakers-daily-scan: bare git, and a catch is no guard
  '    $txt = $req | & $py $script --split-terms 2>&1',                              # map-preresolve: a native named by a variable
  '  & powershell @argList > $log 2>$null'                                           # consistency-oracle: stdout to a file, stderr to $null
)
# Multi-line MUST FIRE shapes, each with the count of unguarded sites it must yield.
$mustCatchBlocks = @(
  @{ Name = 'a call continued over a backtick is one call (wave-publish E1)'; Want = 1; Text = @'
$dry = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'update-recipes-db.ps1') `
        -RunDir $RunDir -SpecsDir $specsDir -DryRun 2>&1
'@ }
  @{ Name = 'a comment mentioning Start-Job does not blind the rest of the file (wave-preaudit drill 2)'; Want = 1; Text = @'
    # Start-Job's process does not inherit this one's working directory, so a relative -RunDir is resolved first.
    function RunDrillFrom([string]$cwd) {
      Push-Location $cwd
      try { $out = & powershell @a 2>&1 } finally { Pop-Location }
    }
'@ }
  @{ Name = 'a preference RESTORED before the call leaves the call unguarded, and the guarded call before it is not counted'; Want = 1; Text = @'
$prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
try { $a = @(& git -C $r log -1 2>$null) } finally { $ErrorActionPreference = $prev }
$ErrorActionPreference = $prev
$b = @(& git -C $r status --porcelain 2>$null)
'@ }
  @{ Name = 'a Continue set inside an if-branch does not guard a call after the branch'; Want = 1; Text = @'
if ($quiet) { $ErrorActionPreference = 'Continue' }
$v = & git rev-parse HEAD 2>$null
'@ }
  @{ Name = 'a redirect one statement AFTER the scoped Continue try/finally runs under Stop again'; Want = 1; Text = @'
$ErrorActionPreference = 'Stop'
$prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
try { $a = @(& git -C $r log -1 2>$null) } finally { $ErrorActionPreference = $prevEap }
$b = @(& git -C $r status --porcelain 2>$null)
'@ }
)
$mustPass = @(
  '      & git -C $repo fetch origin main | ForEach-Object { Write-Output $_ }',     # legal shape 1: no redirect
  '  $r = Invoke-Native "git" "-C" $repo "fetch" "origin" "main"',                   # legal shape 2: the helper
  '  # & git -C $repo fetch origin main 2>$null   <- a commented example must not fire',
  '  $out = Get-Content $f 2>$null',                                                 # a CMDLET redirect is harmless
  '  Write-Output "the text 2>$null inside a string is not a call"',
  '$x = & powershell -NoProfile -Command "& { $ErrorActionPreference=''Continue''; & ''a.ps1'' 2>&1 | Out-String }"',
  '    $vnrOut = & (Join-Path $root ''verify-no-regression.ps1'') @vnrArgs 2>&1',     # an IN-PROCESS script is not a native child
  '    & $PSCommandPath -Revive -RunDir $rv -Slug ''x'' 2>&1 | Out-Null'               # nor is this script calling itself
)
$mustPassBlocks = @(
  @{ Name = 'a redirect quoted in a block comment (brain-digest)'; Text = @'
function Invoke-DigestPython {
  <# Every call here was `& $PY script 2>$null` under $ErrorActionPreference = 'Stop'.
     & git fetch 2>&1 #>
  param([string]$Exe)
}
'@ }
  @{ Name = 'a child script body held in a here-string (audit-git-fixture-env)'; Text = @"
`$body = @'
`$null = & git -C `$Temp config commit.gpgsign false 2>`$null
`$null = & git -C `$Temp config user.name FixtureWrote 2>`$null
'@
"@ }
  @{ Name = 'a Continue for the whole self-test block, far above the call (audit-git-fixture-env)'; Text = @'
if ($SelfTest) {
  $ErrorActionPreference = 'Continue'
  $fail = 0
  function T([string]$m) { Write-Output $m }
  try {
    $main = Join-Path $sb 'main'
    $null = & git -C $main config user.name orig 2>$null
    $linkedGitDir = [string](@(& git -C $linked rev-parse --absolute-git-dir 2>$null) | Select-Object -Last 1)
  } finally { Remove-Item $sb -Recurse -Force }
}
'@ }
  @{ Name = 'a script-scope Continue above the functions that call git (prepush-test-auditors)'; Text = @'
$ErrorActionPreference = 'Stop'
try { . (Join-Path $RepoRoot 'lib\guard-contract.ps1') } catch { exit 3 }
$ErrorActionPreference = 'Continue'
function Get-TrackedScriptReader([string]$Root) {
  foreach ($t in @(& git -C $Root -c core.quotepath=off ls-files 2>$null)) { $t }
}
'@ }
  @{ Name = 'a function defined between the guard and the call does not change the preference the call runs under'; Text = @'
$ErrorActionPreference = 'Continue'
function Set-Loud { $ErrorActionPreference = 'Stop' }
$v = & git rev-parse HEAD 2>$null
'@ }
  @{ Name = 'a Start-Job scriptblock runs at the default Continue'; Text = @'
$ErrorActionPreference = 'Stop'
$job = Start-Job -ScriptBlock { param($r) & git -C $r fetch origin main 2>&1 } -ArgumentList $repo
'@ }
)
$watcherBad = @()
foreach ($l in $mustCatch) { if ((Get-TcUnguardedCount $l) -lt 1) { $watcherBad += ('MISSED: ' + $l.Trim()) } }
foreach ($b in $mustCatchBlocks) { $got = Get-TcUnguardedCount $b.Text; if ($got -ne $b.Want) { $watcherBad += ('MISSED: ' + $b.Name + ' (unguarded ' + $got + ', want ' + $b.Want + ')') } }
foreach ($l in $mustPass) { if ((Get-TcUnguardedCount $l) -ne 0) { $watcherBad += ('FALSE ALARM: ' + $l.Trim()) } }
foreach ($b in $mustPassBlocks) { $got = Get-TcUnguardedCount $b.Text; if ($got -ne 0) { $watcherBad += ('FALSE ALARM: ' + $b.Name + ' (unguarded ' + $got + ')') } }
if (-not $watcherBad.Count) {
  Write-Output ("  ok    watcher self-proof: the AST rule still catches all {0} known-bad shapes and accuses none of the {1} legal ones" -f ($mustCatch.Count + $mustCatchBlocks.Count), ($mustPass.Count + $mustPassBlocks.Count))
} else {
  Write-Output '  FAIL  watcher self-proof: THE SCANNER ITSELF IS BROKEN - every "ok" it prints below is worthless'
  foreach ($b in $watcherBad) { Write-Output ('        ' + $b) }
  $fail++
}

# THE SANCTIONED SHAPE IS READ AS GUARDED, NOT MERELY UNREPORTED. A rule that stopped finding redirects at all would
# also pass every must-pass line above, so this asserts the site is FOUND and read as 'continue'.
$sanctioned = Get-TcNativeStderrSites -Text @'
$ErrorActionPreference = 'Stop'
function Get-Head {
  $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { $c = @(& git -C $repo rev-parse --short HEAD 2>$null) } catch { } finally { $ErrorActionPreference = $prevEap }
  return $c
}
'@
$sanSites = @($sanctioned.Sites)
Check 'CLEAN TWIN  the scoped Continue shape the fixes use is FOUND and read as guarded, not skipped' ($sanSites.Count -eq 1 -and $sanSites[0].Eap -eq 'continue') ("sites=" + $sanSites.Count + " eap=" + $(if ($sanSites.Count) { $sanSites[0].Eap } else { '' }))
# A site that only MOVED keeps its ratchet name, so a blank line added above it is not a new finding.
$moveA = @((Get-TcNativeStderrSites -Text '$v = & git log -1 2>$null').Sites)
$moveB = @((Get-TcNativeStderrSites -Text ("`r`n`r`n" + '  $v = & git   log -1 2>$null')).Sites)
Check 'MUST NOT FIRE  a site that only moved lines or re-indented keeps its name' ($moveA.Count -eq 1 -and $moveB.Count -eq 1 -and $moveA[0].Command -eq $moveB[0].Command -and $moveA[0].Line -ne $moveB[0].Line) ("a=" + $(if ($moveA.Count) { $moveA[0].Command }) + " b=" + $(if ($moveB.Count) { $moveB[0].Command }))

# --- THE WALK, FROM A WORKTREE ROOT, AND A HIT OUTSIDE grocery\ ------------------------------------------------
# MUST FIRE for the 2026-09-11 gap: the walk was $root, the grocery\ directory, so a site in ops\ or meal-prep\ was
# never read. The fixture root is a worktree with a sibling below it (lib\tree-walk.ps1), so a walk that matched the
# full path would read nothing and one that dropped the exclusion would read the sibling twice over.
$fxBad = @'
$ErrorActionPreference = 'Stop'
$v = @(& git -C $r log -1 --format=%h 2>$null)
'@
$fxGuarded = @'
$ErrorActionPreference = 'Stop'
$prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
try { $v = @(& git -C $r log -1 2>$null) } finally { $ErrorActionPreference = $prevEap }
'@
$fxNoStop = @'
$v = & git -C $r log -1 2>&1
'@
$wtFx = New-TcWorktreeFixture -Files @{
  'ops\fx-bad.ps1' = $fxBad; 'meal-prep\pipeline\fx-bad.ps1' = $fxBad; 'grocery\fx-guarded.ps1' = $fxGuarded
  'lib\fx-nostop.ps1' = $fxNoStop; 'grocery\archive\fx-old.ps1' = $fxBad; 'grocery\out\fx-debris.ps1' = $fxBad }
try {
  $ws = Invoke-TcEapScan -RootDir $wtFx.Root
  $wsSites = @($ws.Sites)
  $wsRels = @($wsSites | ForEach-Object { $_.Rel })
  Check 'MUST FIRE  an unguarded redirect OUTSIDE grocery\ is caught, in ops\ and in meal-prep\pipeline\' (($wsRels -contains 'ops\fx-bad.ps1') -and ($wsRels -contains 'meal-prep\pipeline\fx-bad.ps1')) ("sites in: " + ($wsRels -join ', '))
  Check 'MUST NOT FIRE  archive\, out\, the sibling worktree and a script that never sets Stop add nothing' ($wsSites.Count -eq 2) ("sites=" + $wsSites.Count + ": " + ($wsRels -join ', '))
  Check 'CLEAN TWIN  the walk still reaches grocery\ and reads a guarded script as examined, with its site found and guarded' ((@($ws.ScannedRel) -contains 'grocery\fx-guarded.ps1') -and @($ws.Guarded).Count -eq 1) ("scanned=" + (@($ws.ScannedRel) -join ', ') + " guarded=" + @($ws.Guarded).Count)
} finally { Remove-Item -LiteralPath $wtFx.Temp -Recurse -Force -ErrorAction SilentlyContinue }

# --- THE RATCHET, BY NAME ------------------------------------------------------------------------------------------
$cmp = Compare-TcSiteBaseline -Current @('a|x', 'b|y') -Baseline @('b|y', 'a|x')
Check 'an unchanged set of sites holds, in any order' ($cmp.Verdict -eq 'held') $cmp.Verdict
$cmp = Compare-TcSiteBaseline -Current @('a|x', 'c|z') -Baseline @('a|x', 'b|y')
Check 'MUST FIRE  a fix plus a NEW site in one change is a rise, although the count held at 2' ($cmp.Verdict -eq 'rose' -and @($cmp.New).Count -eq 1 -and $cmp.New[0] -eq 'c|z') ("{0} new={1}" -f $cmp.Verdict, (@($cmp.New) -join ','))
$cmp = Compare-TcSiteBaseline -Current @('a|x', 'a|x') -Baseline @('a|x')
Check 'MUST FIRE  a second copy of a known site is new' ($cmp.Verdict -eq 'rose' -and @($cmp.New).Count -eq 1) ("{0} new={1}" -f $cmp.Verdict, @($cmp.New).Count)
$cmp = Compare-TcSiteBaseline -Current @('a|x') -Baseline @('a|x', 'b|y')
Check 'CLEAN TWIN  a fixed site is a fall that names what went' ($cmp.Verdict -eq 'fell' -and @($cmp.Gone).Count -eq 1 -and $cmp.Gone[0] -eq 'b|y') ("{0} gone={1}" -f $cmp.Verdict, (@($cmp.Gone) -join ','))
$cmp = Compare-TcSiteBaseline -Current @('A|x') -Baseline @('a|x')
Check 'MUST FIRE  names compare ordinally, so a case change is not waved through as the same site' ($cmp.Verdict -eq 'rose') $cmp.Verdict
$cmp = Compare-TcSiteBaseline -Current @() -Baseline @()
Check 'an empty tree against an empty baseline holds, not a PS 5.1 @($null) count of 1' ($cmp.Verdict -eq 'held' -and @($cmp.New).Count -eq 0) ("{0} new={1}" -f $cmp.Verdict, @($cmp.New).Count)

# --- CASE 5: the tree scan, over targets it DERIVES rather than a list that rots ------
# The old scan named three files. The bug class does not live in three files - it lives
# in every script that sets EAP='Stop', which is the only condition under which a native
# child's stderr can terminate anyone. So derive the target set from that fact. A file
# added to the estate tomorrow is covered the day it sets EAP='Stop'; nobody has to
# remember to add it here. Since 2026-09-11 the walk is the repo root, not this directory.
$n++
$scan = Invoke-TcEapScan -RootDir $repo -Self $PSCommandPath
$sites = @($scan.Sites | Sort-Object Rel, Line)
Write-Output ("  scan: walked {0} .ps1 below the repo root, {1} set 'Stop' and were examined, {2} native redirect(s) read as guarded, {3} unguarded" -f $scan.Walked, $scan.Scanned, @($scan.Guarded).Count, $sites.Count)
foreach ($u in @($scan.Unparsed)) { Write-Output ('  note  could not parse cleanly, sites there may be missed: ' + $u) }
# A SCAN THAT EXAMINED NOTHING IS NOT A CLEAN SCAN. A moved root, a broken exclusion or a regex that stopped
# matching would find a handful and report them clean - the silent-skip shape that lets a watcher go quiet.
# AND THE WALK MUST REACH EVERY MODULE, because the floor alone cannot see the founding gap: grocery\ by itself sets
# 'Stop' in enough scripts to clear it, so a walk put back on this directory would pass the floor and watch nothing else.
$tops = @($scan.ScannedRel | ForEach-Object { ($_ -split '\\')[0] } | Sort-Object -Unique)
$missingTops = @(@('grocery', 'ops', 'meal-prep', 'graph') | Where-Object { $tops -notcontains $_ })
if ($scan.Scanned -lt $ScanFloor -or $missingTops.Count) {
  Write-Output ("  FAIL  tree scan examined {0} EAP=Stop script(s) (floor {1}) and reached no script in: {2}. A scan that did not reach the tree is BLIND, not clean." -f $scan.Scanned, $ScanFloor, $(if ($missingTops.Count) { $missingTops -join ', ' } else { 'none missing' }))
  $fail++
  $blind = 'scan-floor'
} else {
  $baseKeys = @()
  $baseNote = ''
  if (Test-Path -LiteralPath $BASELINE_FILE) {
    $doc = $null
    try { $doc = [IO.File]::ReadAllText($BASELINE_FILE) | ConvertFrom-Json } catch { $doc = $null }
    if ($null -eq $doc) {
      Write-Output ('  FAIL  the baseline exists and does not parse, so no site can be judged against it: ' + $BASELINE_FILE)
      $fail++
      $blind = 'baseline-unreadable'
    } elseif ($null -ne $doc.sites) {
      $baseKeys = @($doc.sites | ForEach-Object { [string]$_ })
    }
  } else {
    $baseNote = ' (no baseline file, so every site counts as new)'
  }
  $keys = @($sites | ForEach-Object { $_.Key })
  $cmp = Compare-TcSiteBaseline -Current $keys -Baseline $baseKeys
  $newSet = @($cmp.New)
  foreach ($s in $sites) {
    $tag = if ($newSet -ccontains $s.Key) { 'NEW  ' } else { 'known' }
    Write-Output ("        {0} {1}:{2}  [{3}]  {4}" -f $tag, $s.Rel, $s.Line, $s.Eap, $(if ($s.Command.Length -gt 140) { $s.Command.Substring(0, 140) + '...' } else { $s.Command }))
  }
  $doWrite = $false
  if ($blind) {
    # the unreadable-baseline FAIL above already speaks for this run
  } elseif ($Accept) {
    $doWrite = $true
    Write-Output ("  ok    -Accept: recording {0} site(s) as the baseline, against {1} before" -f $keys.Count, $baseKeys.Count)
  } elseif ($cmp.Verdict -eq 'rose') {
    Write-Output ("  FAIL  tree scan: {0} NEW unguarded native stderr redirect(s) under EAP=Stop{1}:" -f $newSet.Count, $baseNote)
    foreach ($k in $newSet) { Write-Output ('        new: ' + $k) }
    Write-Output '        Use Invoke-Native/Invoke-NativeScript (grocery\native-lib.ps1), a scoped $ErrorActionPreference = ''Continue'' restored in a finally, or drop the redirect.'
    $fail++
  } elseif ($cmp.Verdict -eq 'fell') {
    $move = Test-RatchetMove -Name 'native-stderr-eap' -Count $keys.Count -Baseline $baseKeys.Count -AcceptDrop:$false
    if ($Tighten) {
      if ($move.Verdict -eq 'implausible') {
        Write-Output ('  FAIL  -Tighten refused: ' + $move.Message + ' (-Accept records it anyway.)')
        $fail++
      } else {
        $doWrite = $true
        Write-Output ("  ok    ratchet tightened: {0} site(s), was {1}. Gone: {2}. Commit the baseline, or it protects only this checkout." -f $keys.Count, $baseKeys.Count, (@($cmp.Gone) -join '; '))
      }
    } else {
      Write-Output ("  ok    tree scan: no new site; {0} known site(s) are gone since the baseline ({1}). Ratchet CAN tighten to {2}, NOT written: this runs at push time, and a rewrite here dirties the checkout being pushed. Record it with -Tighten and commit grocery\native-stderr-eap-baseline.json." -f @($cmp.Gone).Count, (@($cmp.Gone) -join '; '), $keys.Count)
    }
  } else {
    Write-Output ("  ok    tree scan: {0} EAP=Stop script(s) examined, no new unguarded native stderr redirect; {1} known site(s) held at the baseline" -f $scan.Scanned, $keys.Count)
  }
  if ($doWrite) {
    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add('{')
    [void]$lines.Add('  "note": ' + (ConvertTo-TcJsonText 'NAMED high-water mark for native stderr redirects under EAP=Stop that the watcher could not read as guarded, one entry per site as path|command. A site not listed fails grocery\test-native-stderr-eap.ps1. Only a plain run is safe at push time: it never writes this file. -Tighten records a believable fall; -Accept records the current set.') + ',')
    [void]$lines.Add('  "generated": ' + (ConvertTo-TcJsonText ((Get-Date).ToString('s'))) + ',')
    [void]$lines.Add('  "count": ' + $keys.Count + ',')
    $sorted = @($keys | Sort-Object)
    if ($sorted.Count) {
      [void]$lines.Add('  "sites": [')
      for ($i = 0; $i -lt $sorted.Count; $i++) { [void]$lines.Add('    ' + (ConvertTo-TcJsonText $sorted[$i]) + $(if ($i -lt $sorted.Count - 1) { ',' } else { '' })) }
      [void]$lines.Add('  ]')
    } else {
      [void]$lines.Add('  "sites": []')
    }
    [void]$lines.Add('}')
    $null = Write-TcLfFile -Path $BASELINE_FILE -Text ($lines -join "`n") -NoBom
    Write-Output ('  wrote ' + $BASELINE_FILE)
  }
}

Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
Write-Output ("NATIVE-STDERR-EAP-TEST-COMPLETE cases={0} failed={1} scanned={2} sites={3}{4}" -f $n, $fail, $scan.Scanned, $sites.Count, $(if ($blind) { ' blind=' + $blind } else { '' }))
if ($blind) { exit 3 }
if ($fail) { exit 1 } else { exit 0 }
