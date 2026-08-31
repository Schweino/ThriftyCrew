<#
  test-pull-agent-lib.ps1 - the browser-pull JS lane's first automated coverage.

  WHY IT DID NOT EXIST (2026-08-31). grocery\pull-agent-lib.js and the four store agents beside it are
  the WHOLE capture path for the walled stores - Walmart, Sam's Club, Fareway, Aldi. Between them they
  decide whether a term was EMPTY (the store does not stock it) or UNUSABLE (we were blocked), which is
  the distinction pull-agent-lib's own header calls the reason it exists: "a false EMPTY is a silent
  claim the store does not stock an item". Not one line of that was under test. Every -SelfTest in this
  tree is PowerShell, so run-gates discovered 158 of them and none of them could see the JS.

  WHAT IT TESTS TODAY: wallWhy(), added 2026-08-31 so a bot-wall verdict keeps its own evidence.
  Every agent used to record a wall as the bare string 'bot-wall', which is a verdict with the proof
  thrown away - afterwards nothing could say which phrase matched or what surrounded it, so a one-term
  blip and a store-wide block read identically. That cost a false "Walmart is walled" report on
  2026-08-31 over a capture that had in fact completed all 592 terms.

  THE SOURCE IS READ, NEVER COPIED. The fixture extracts wallWhy from the real pull-agent-lib.js and
  evals it. A test carrying its own copy of the function proves the copy works, which is the
  duplicated-constant trap the lib's own header was written against.

  ON NOT FINDING NODE. If node cannot be located this prints BLIND and exits 0, and that is a
  deliberate, narrow exception to the estate's "unknown is not a pass" rule - stated here rather than
  hidden. The alternative is a gate that goes red on every machine without node, which is a gate
  someone removes. The line says BLIND in capitals so a green run that proved nothing is still legible,
  and node IS present on the box this lane actually runs on (it is a browser-driving lane).

  Usage: .\test-pull-agent-lib.ps1 -SelfTest
#>
param([switch]$SelfTest)

$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

function Find-Node {
  # PATH first, then the known local installs. NOT a hardcoded absolute path: the estate has already
  # shipped a fixture that passed on Brad's box and failed everywhere else for exactly that reason
  # (see the derived-path note in lib\ghost-drift-lib.ps1).
  $c = Get-Command node -ErrorAction SilentlyContinue
  if ($c) { return $c.Source }
  foreach ($p in @(
      'C:\Program Files\nodejs\node.exe',
      'C:\Codex\node-v24.15.0-win-x64\node.exe',
      'C:\Codex\tools\node-v22.11.0-win-x64\node.exe')) {
    if (Test-Path $p) { return $p }
  }
  foreach ($d in @(Get-ChildItem 'C:\Codex' -Directory -Filter 'node-v*' -ErrorAction SilentlyContinue)) {
    $p = Join-Path $d.FullName 'node.exe'
    if (Test-Path $p) { return $p }
  }
  return $null
}

if (-not $SelfTest) { Write-Output 'test-pull-agent-lib: pass -SelfTest'; exit 0 }

$node = Find-Node
if (-not $node) {
  Write-Output 'test-pull-agent-lib: BLIND - node was not found on PATH or in the known install locations, so the browser-pull JS lane was NOT tested. This run proves nothing about it.'
  Write-Output 'test-pull-agent-lib SELF-TEST BLIND'
  exit 0
}

$lib = Join-Path $here 'pull-agent-lib.js'
if (-not (Test-Path $lib)) { Write-Output 'test-pull-agent-lib: pull-agent-lib.js is MISSING'; exit 1 }

# --- 1. every file in the lane must at least PARSE -------------------------------------------------
$bad = 0
$lane = @('pull-agent-lib.js', 'pull-walmart-instore.js', 'pull-sams-instore.js', 'pull-fareway-instore.js', 'pull-aldi-instore.js')
foreach ($f in $lane) {
  $p = Join-Path $here $f
  if (-not (Test-Path $p)) { Write-Output ("  X     " + $f + " is missing from the lane"); $bad++; continue }
  # Start-Process WITH REDIRECTED STREAMS, not `& node ... 2>&1`. Under $ErrorActionPreference='Stop'
  # a native child's first stderr line is a TERMINATING error, so the plain call made an unparseable
  # file KILL this script instead of reporting it - the case died silently and the neuter that proved
  # it came back 0 red. Same trap that took ops\run-gates.ps1 down this morning; see the note in
  # meal-prep\pipeline\ingredient-resolutions.ps1.
  $so = [IO.Path]::GetTempFileName(); $se = [IO.Path]::GetTempFileName()
  $pi = Start-Process -FilePath $node -ArgumentList @('--check', $p) -Wait -PassThru -NoNewWindow `
        -RedirectStandardOutput $so -RedirectStandardError $se
  $err = [string](Get-Content $se -Raw); if ($null -eq $err) { $err = '' }
  Remove-Item $so, $se -Force -ErrorAction SilentlyContinue
  if ($pi.ExitCode -eq 0) { Write-Output ("  ok    " + $f + " parses") }
  else {
    $first = (($err -split "`n") | Where-Object { $_.Trim() } | Select-Object -First 1)
    Write-Output ("  X     " + $f + " DOES NOT PARSE - the capture lane would fail at injection: " + ([string]$first).Trim())
    $bad++
  }
}

# --- 2. wallWhy's behaviour, against the real source ------------------------------------------------
$js = @'
const fs = require('fs');
// argv[2], NOT argv[1]: for `node script.js <arg>` argv[0] is node and argv[1] is the SCRIPT, so
// argv[1] made this read its own temp file, find no wallWhy in it, and report the lib as missing it.
const src = fs.readFileSync(process.argv[2], 'utf8');
const m = src.match(/function wallWhy\(html, phrases\) \{[\s\S]*?\n\}/);
if (!m) { console.log('  X     wallWhy is not defined in pull-agent-lib.js'); process.exit(1); }
eval(m[0]);
let bad = 0;
function T(n, ok, got) { if (ok) console.log('  ok    ' + n); else { console.log('  X     ' + n + '   got: ' + got); bad++; } }
const P = ['robot or human', 'access denied', 'px-captcha'];
const wall = '<html><head><title>Robot or human?</title></head><body>Please verify you are not a robot.</body></html>';
const r1 = wallWhy(wall, P);
T('a wall verdict NAMES the phrase that matched', r1.indexOf('[robot or human]') >= 0, r1);
T('...and records where in the body it matched', /@\d+/.test(r1), r1);
T('...and carries the surrounding text, not just the phrase', r1.indexOf(' :: ') >= 0 && r1.length > 40, r1);
T('...and still begins with bot-wall, so old greps still find it', r1.indexOf('bot-wall') === 0, r1);
T('MUST NOT FIRE  a page with no wall phrase returns the bare verdict', wallWhy('an ordinary product page', P) === 'bot-wall', wallWhy('an ordinary product page', P));
T('matching is case-insensitive on both sides', wallWhy('ACCESS DENIED to this page', P).indexOf('[access denied]') >= 0, wallWhy('ACCESS DENIED', P));
const a = wallWhy('the page says access denied here', P), b = wallWhy('the page says px-captcha here', P);
T('MUST FIRE  two DIFFERENT walls produce DIFFERENT evidence (the entire point)', a !== b, a + '  vs  ' + b);
T('the context is collapsed to one line, so it cannot break a jsonl row', wallWhy('noise\n\n\taccess denied\n\n  spread  over  lines', P).indexOf('\n') < 0, 'newline survived');
let threw = false;
try { wallWhy(null, P); wallWhy(undefined, P); wallWhy('', P); } catch (e) { threw = true; }
T('MUST NOT THROW  an empty or absent body is not an exception', !threw, 'threw');
process.exit(bad === 0 ? 0 : 1);
'@
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('wallwhy-' + [guid]::NewGuid().ToString('N') + '.js')
[IO.File]::WriteAllText($tmp, $js, (New-Object System.Text.UTF8Encoding($false)))
try {
  & $node $tmp $lib
  if ($LASTEXITCODE -ne 0) { $bad++ }
} finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }

# --- 3. and every agent that detects a wall must actually USE it ------------------------------------
# Without this, wallWhy could be perfect and still be called by nobody - which is the state the lane
# was in before today, with three inline copies of the bare verdict.
foreach ($f in @('pull-walmart-instore.js', 'pull-sams-instore.js', 'pull-fareway-instore.js')) {
  $txt = [IO.File]::ReadAllText((Join-Path $here $f))
  $needle = 'wall' + 'Why('          # built by concatenation: a literal here could match this file
  if ($txt.Contains($needle)) { Write-Output ("  ok    " + $f + " reports its wall through the shared evidence helper") }
  else { Write-Output ("  X     " + $f + " still records a wall without evidence"); $bad++ }
  if ($txt -match "why:\s*'bot-wall'") { Write-Output ("  X     " + $f + " still carries a bare 'bot-wall' verdict"); $bad++ }
}

if ($bad -eq 0) { Write-Output 'test-pull-agent-lib SELF-TEST PASS'; exit 0 }
Write-Output ("test-pull-agent-lib SELF-TEST FAIL: {0} case(s)" -f $bad); exit 1
