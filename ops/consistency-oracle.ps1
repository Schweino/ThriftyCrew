<#
  consistency-oracle.ps1 - run a transformation stage AS IT IS and AS IT WAS over the same real
  input, and diff the output. Run it deliberately, before a refactor lands.

  SCOPE OF A CLEAN REPORT: SOUND over the rows both arms emitted, and silent about everything else.
    Identical output really does mean the two revisions agree on THIS input. It says nothing about
    inputs you did not feed it, and a row only one arm emits is reported separately rather than
    being folded into a difference count.

  WHY THIS EXISTS (2026-09-08, backlog I65). Where behaviour is meant to be UNCHANGED you do not have
  to author an oracle, because you already have one: THE PREVIOUS VERSION OF THE PROGRAM. Nobody
  writes the expected values, which is why it is the strongest of the oracles that scale - and this
  estate's whole architecture is a git-bus where one runtime writes a file another reads, so every
  stage boundary is a versioned pure-ish function, which is exactly the shape it wants.

  WHAT THE SUITE CANNOT DO, and this is the gap being filled. A `-SelfTest` proves a detector still
  fires on the one frozen fixture it was written for. It says nothing about whether a refactor
  changed the output of the 4,000 real rows nobody froze. The estate has been bitten by precisely
  that: the price formatter had five copies, compare-deals functions are lifted by twelve scripts,
  and a norm regex without a word boundary turned "Garlic" into "arlic". Every one of those is a
  behaviour change on real input that a fixture suite did not see.

  IT IS NOT A GATE, AND MUST NOT BECOME ONE. A consistency check that has to be green on every push
  is a ratchet nobody asked for and would be red on day one - `.claude\rules\ops-and-gates.md`
  forbids that shape. Output is MEANT to change when a fix lands; the point is to see WHICH rows
  changed and confirm you meant it.

  IT NEVER WRITES TO A TRACKED PATH. Both arms run inside their own temp sandbox, because a stage
  like grocery\build-walmart-deals.ps1 writes its output, a rejects file AND mutates the rollback
  ledger. Running an old revision in place would have written all three.

  THE SANDBOX HAS THE REPO'S SHAPE, NOT A FLAT FOLDER (2026-09-11). It used to copy the script's own
  directory straight into tc-oracle-<id>, so `Split-Path $PSScriptRoot -Parent` inside a sandboxed
  script pointed at %TEMP% and every `..\lib\x.ps1` it loads was missing. That was survivable only while
  every such load was guarded by a Test-Path (multipack-lib's is). The day grocery\rollback-ttl-lib.ps1
  started loading lib\atomic-write.ps1 unconditionally, the founding run below lost its NEW arm with
  "The term '...\Temp\lib\atomic-write.ps1' is not recognized". So the script's directory now lands at
  tc-oracle-<id>\<its repo-relative dir> with tc-oracle-<id>\lib beside it: lib\ at the old revision
  under -Mode World, and at HEAD under -Mode Script, the same rule the script's sibling libraries follow.

  -ARGS NEVER REACHED THE STAGE BEFORE 2026-09-11. The parameter was named $Args, and inside a plain
  function such as Invoke-TcArm that name is PowerShell's automatic $args, which was empty - measured:
  script scope saw [Date], the function saw []. So every arm ran on its own defaults. The founding run
  hid it because its -Date equalled the day it ran; on any other day the builder files its output under
  today and both arms report "wrote False". And a SECOND defect sat under the first: the pair was built as
  @('-' + $k, $v), where a comma binds tighter than +, so it was '-' + ($k, $v) - one element reading
  "-Date 2026-09-10", which the child cannot bind even once the hashtable arrives. The self-test's list
  count found it (8 elements, not 9). The parameter is $ScriptArgs now, still spelled -Args on the command
  line, and the argument list is built by Get-TcArmArgList, which is pure so the self-test reaches it.

  TWO PINNING MODES, and the difference decides what a result MEANS:
    -Mode Script  pins ONLY the script under test; its libraries stay at HEAD. Answers "did THIS
                  script's behaviour change".
    -Mode World   pins the whole source directory at that revision. Answers "did the pipeline's
                  output change". THIS IS USUALLY THE ONE YOU WANT, and the reason is real: on the
                  founding run, Script mode could not execute at all, because the old
                  build-walmart-deals lifts a hand-maintained list of function names out of
                  compare-deals.ps1 and against today's compare-deals it lifted a function whose
                  callee did not exist yet. That is a true finding about coupling (backlog I82) and
                  it is also a dead end for the diff.

  Example, the founding run:
    ops\consistency-oracle.ps1 -Script grocery\build-walmart-deals.ps1 -OldRev d81391efa `
      -InputFile grocery\out\captures\walmart-capture-2026-09-08.csv `
      -OutputRelPath out\regular\walmart-regular-2026-09-08.json -ArrayKey deals `
      -KeyFields item_id,item -Args @{ Date = '2026-09-08' }

  EXIT CODES (lib\guard-contract.ps1 vocabulary): 0 ran and diffed, 2 an arm failed to produce
  output, 3 could not evaluate. A non-zero difference count is NOT a failure - read the report.
#>
[CmdletBinding()]
param(
  [string]$Script = '',
  [string]$OldRev = '',
  [string]$InputFile = '',
  [string]$OutputRelPath = '',
  [string]$ArrayKey = '',
  [string[]]$KeyFields = @('id'),
  [ValidateSet('Script', 'World')][string]$Mode = 'World',
  # NOT named $Args: inside a plain function that name is PowerShell's automatic $args. See -ARGS in the header.
  [Alias('Args')][hashtable]$ScriptArgs = @{},
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\ops' }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')

function Get-TcRowKey {
  <# The identity of a row, so the diff is keyed rather than positional. A positional diff reports
     every row after an insertion as changed, which is the shape that makes a real finding
     unreadable. Pure. #>
  param([object]$Row, [string[]]$Fields)
  return (($Fields | ForEach-Object { [string]$Row.$_ }) -join '|')
}

function Compare-TcRowSets {
  <# The whole comparison, as a pure function over two row arrays, so the fixtures drive it without
     running anything. Returns OnlyA / OnlyB / Common / Differing / FieldHits.

     A row present in only ONE arm is reported separately and is NEVER counted as a difference: an
     emitted-versus-dropped row and a changed value are different findings with different causes,
     and folding them together is how a filter change hides inside a value change. #>
  param([object[]]$RowsA, [object[]]$RowsB, [string[]]$Fields)
  # CASE-SENSITIVE ON PURPOSE. A bare `@{}` in PowerShell is a CASE-INSENSITIVE hashtable, so
  # "Great Value BLACK BEANS" and "Great Value Black Beans" would collide into one key and a name
  # that changed only in case would read as the same row - the oracle silently missing exactly the
  # class of string change it exists to catch. This estate has already paid for a string defect of
  # that family (a norm regex without a word boundary turning "Garlic" into "arlic"). Caught by this
  # file's own composite-key fixture on the day it was written.
  $a = New-Object 'System.Collections.Hashtable' ([StringComparer]::Ordinal)
  $b = New-Object 'System.Collections.Hashtable' ([StringComparer]::Ordinal)
  foreach ($r in @($RowsA)) { if ($null -ne $r) { $a[(Get-TcRowKey -Row $r -Fields $Fields)] = $r } }
  foreach ($r in @($RowsB)) { if ($null -ne $r) { $b[(Get-TcRowKey -Row $r -Fields $Fields)] = $r } }
  $onlyA = @($a.Keys | Where-Object { -not $b.ContainsKey($_) })
  $onlyB = @($b.Keys | Where-Object { -not $a.ContainsKey($_) })
  $common = @($a.Keys | Where-Object { $b.ContainsKey($_) })
  $diff = @(); $fieldHits = @{}
  foreach ($k in $common) {
    $x = $a[$k]; $y = $b[$k]
    $names = @(@($x.PSObject.Properties.Name) + @($y.PSObject.Properties.Name) | Sort-Object -Unique)
    $changed = @()
    foreach ($p in $names) {
      if ("$($x.$p)" -ne "$($y.$p)") {
        $changed += $p
        if (-not $fieldHits.ContainsKey($p)) { $fieldHits[$p] = 0 }
        $fieldHits[$p]++
      }
    }
    if ($changed.Count) { $diff += [pscustomobject]@{ Key = $k; Fields = $changed; A = $x; B = $y } }
  }
  return @{ OnlyA = $onlyA; OnlyB = $onlyB; Common = $common; Differing = $diff; FieldHits = $fieldHits }
}

# ------------------------------------------------------------------------------------- self-test
function Get-TcSandboxLayout {
  <# Where a sandbox puts the script's directory and lib\, mirroring the repo so a script's own
     `Split-Path $PSScriptRoot -Parent` (or a walk up from it) reaches lib\ exactly as it does in the
     tree. Pure: New-TcSandbox creates what this names. #>
  param([string]$Top, [string]$SrcRel)
  $rel = ($SrcRel -replace '/', '\').Trim('\')
  $dir = if ($rel) { Join-Path $Top $rel } else { $Top }
  return @{ ScriptDir = $dir; Lib = (Join-Path $Top 'lib') }
}

function Get-TcArmArgList {
  <# The child powershell command line for one arm: the stage, its sandboxed input, then every -ScriptArgs
     entry as -Name value. Pure, and it takes the hashtable as a parameter rather than reading a script
     variable - reading one named $Args from a function is how the arguments were lost. #>
  param([string]$ScriptPath, [string]$InPath, [hashtable]$ScriptArgs = @{})
  $list = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath, '-In', $InPath)
  # PARENTHESISED ON PURPOSE: a comma binds tighter than +, so '-' + $k, $v is '-' + ($k, $v) - ONE element.
  foreach ($k in @($ScriptArgs.Keys | Sort-Object)) { $list += @(('-' + $k), [string]$ScriptArgs[$k]) }
  return ,$list
}

if ($SelfTest) {
  $f = 0
  function T($m, $cond, $got) { if ($cond) { Write-Output ("ok    " + $m) } else { Write-Output ("FAIL  " + $m + "   got: " + $got); $script:f++ } }

  $A = @(
    [pscustomobject]@{ id = '1'; item = 'beans'; price = '1.00'; seller = 'Walmart.com' },
    [pscustomobject]@{ id = '2'; item = 'rice';  price = '2.00'; seller = 'Walmart.com' }
  )
  $B = @(
    [pscustomobject]@{ id = '1'; item = 'beans'; price = '1.00'; seller = '' },
    [pscustomobject]@{ id = '2'; item = 'rice';  price = '2.50'; seller = '' },
    [pscustomobject]@{ id = '3'; item = 'flour'; price = '3.00'; seller = '' }
  )
  $r = Compare-TcRowSets -RowsA $A -RowsB $B -Fields @('id')
  T 'MUST FIRE  a CHANGED value on a row both arms emitted is a difference' `
    (@($r.Differing | Where-Object { $_.Key -eq '2' }).Count -eq 1) ("differing=" + @($r.Differing).Count)
  T 'MUST FIRE  THE ONE THAT KEEPS THE TWO FINDINGS APART - a row only the OLD arm emitted is reported as only-in-B and is NOT counted as a differing row' `
    ((@($r.OnlyB).Count -eq 1) -and (@($r.OnlyB)[0] -eq '3') -and (@($r.Differing | Where-Object { $_.Key -eq '3' }).Count -eq 0)) `
    ("onlyB=" + (@($r.OnlyB) -join ',') )
  T 'MUST NOT FIRE  an identical row is not a difference' `
    (@($r.Differing | Where-Object { $_.Key -eq '1' -and $_.Fields -contains 'price' }).Count -eq 0) 'row 1 price flagged'
  T 'CLEAN TWIN a field that moved on EVERY common row is counted as such, which is how a new field reads' `
    ($r.FieldHits['seller'] -eq 2) ("seller hits=" + $r.FieldHits['seller'])
  T 'CLEAN TWIN the common set is the intersection, with its own denominator' `
    (@($r.Common).Count -eq 2) ("common=" + @($r.Common).Count)

  $empty = Compare-TcRowSets -RowsA @() -RowsB @() -Fields @('id')
  T 'MUST NOT FIRE  two EMPTY arms produce 0 common and 0 differing, never 1 - @($null).Count is 1 in PS 5.1' `
    ((@($empty.Common).Count -eq 0) -and (@($empty.Differing).Count -eq 0) -and (@($empty.OnlyA).Count -eq 0)) `
    ("common=" + @($empty.Common).Count)

  $comp = @([pscustomobject]@{ id = '1'; item = 'beans' })
  $comp2 = @([pscustomobject]@{ id = '1'; item = 'BEANS' })
  $rk = Compare-TcRowSets -RowsA $comp -RowsB $comp2 -Fields @('id', 'item')
  T 'CLEAN TWIN a COMPOSITE key uses every field, so two rows sharing an id but not a name are not the same row' `
    ((@($rk.Common).Count -eq 0) -and (@($rk.OnlyA).Count -eq 1) -and (@($rk.OnlyB).Count -eq 1)) `
    ("common=" + @($rk.Common).Count)
  T 'CLEAN TWIN the key is built from the named fields in order' `
    ((Get-TcRowKey -Row $comp[0] -Fields @('id', 'item')) -eq '1|beans') (Get-TcRowKey -Row $comp[0] -Fields @('id', 'item'))

  # The founding layout bug: a flat sandbox put a grocery script's parent at %TEMP%, so its ..\lib load missed.
  $fakeTop = 'C:\sandbox-top'
  $l1 = Get-TcSandboxLayout -Top $fakeTop -SrcRel 'grocery'
  T 'MUST FIRE  a script one directory down finds lib\ at Split-Path $PSScriptRoot -Parent, as rollback-ttl-lib and send-alert load it' `
    ((Join-Path (Split-Path $l1.ScriptDir -Parent) 'lib') -eq $l1.Lib) ("scriptDir=" + $l1.ScriptDir + " lib=" + $l1.Lib)
  $l2 = Get-TcSandboxLayout -Top $fakeTop -SrcRel 'meal-prep/pipeline'
  T 'CLEAN TWIN a script two directories down reaches the same lib\ two hops up, as hunt-run and considered-dishes do' `
    ((Join-Path (Split-Path (Split-Path $l2.ScriptDir -Parent) -Parent) 'lib') -eq $l2.Lib) ("scriptDir=" + $l2.ScriptDir + " lib=" + $l2.Lib)

  # The founding -Args bug: the arms were launched with none of the arguments the caller passed.
  # Neutral paths on purpose: a module-internals literal here would read as a real reach to audit-cross-module-reach.
  $al = Get-TcArmArgList -ScriptPath 'C:\sb\stage\build.ps1' -InPath 'C:\sb\stage\in\w.csv' -ScriptArgs @{ Date = '2026-09-10' }
  $alText = ($al -join ' ')
  T 'MUST FIRE  a -Args entry reaches the arm''s command line as -Date 2026-09-10, after the stage and its -In' `
    (($alText -match '-File C:\\sb\\stage\\build\.ps1 -In C:\\sb\\stage\\in\\w\.csv -Date 2026-09-10$') -and (@($al).Count -eq 9)) $alText

  if ($f) { Write-Output ("SELF-TEST FAIL: {0} check(s)" -f $f); exit 1 }
  Write-Output 'SELF-TEST PASS: 4 must-fire cases led by the one that keeps an emitted-versus-dropped row apart from a changed value, 2 must-not-fire cases including two empty arms, and 5 clean twins over composite keys, field tallies, the common denominator and the sandbox layout'
  exit 0
}

# ------------------------------------------------------------------------------- the live run
foreach ($p in @('Script', 'OldRev', 'InputFile', 'OutputRelPath', 'ArrayKey')) {
  if (-not (Get-Variable $p -ValueOnly)) {
    Write-Output ("CONSISTENCY ORACLE COULD NOT EVALUATE: -{0} is required. See the header for a worked example." -f $p)
    Exit-Guard -Name 'consistency-oracle' -Summary 'blind=missing-argument' -Code 3
  }
}
$scriptRel = $Script -replace '\\', '/'
$srcDir = Split-Path (Join-Path $repo $Script) -Parent
$srcRel = (Split-Path $scriptRel -Parent)
$leaf = Split-Path $Script -Leaf
$inFull = if ([IO.Path]::IsPathRooted($InputFile)) { $InputFile } else { Join-Path $repo $InputFile }
if (-not (Test-Path $inFull)) {
  Write-Output ("CONSISTENCY ORACLE BLIND: the input {0} does not exist, so nothing was compared. That is not 'no difference'." -f $inFull)
  Exit-Guard -Name 'consistency-oracle' -Summary 'blind=no-input' -Code 3
}

function New-TcSandbox([string]$rev) {
  $top = Join-Path $env:TEMP ('tc-oracle-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  $layout = Get-TcSandboxLayout -Top $top -SrcRel $srcRel
  $sb = $layout.ScriptDir
  $libSb = $layout.Lib
  New-Item -ItemType Directory -Path $sb, $libSb -Force | Out-Null
  if ($rev -eq 'WORKTREE') {
    Copy-Item (Join-Path $srcDir '*.ps1')  $sb -Force -ErrorAction SilentlyContinue
    Copy-Item (Join-Path $srcDir '*.json') $sb -Force -ErrorAction SilentlyContinue
    Copy-Item (Join-Path $repo 'lib\*.ps1') $libSb -Force -ErrorAction SilentlyContinue
  } else {
    if ($Mode -eq 'World') {
      $names = @(& git -C $repo ls-tree --name-only ("{0}:{1}" -f $rev, $srcRel)) | Where-Object { $_ -match '\.(ps1|json)$' }
      # lib\ is pinned with the world it belongs to: an old script against today's lib is -Mode Script's question.
      $libNames = @(& git -C $repo ls-tree --name-only ("{0}:lib" -f $rev)) | Where-Object { $_ -match '\.ps1$' }
      foreach ($n in $libNames) {
        # 'Continue' around each redirect: under 'Stop' git's "does not exist" on stderr threw instead of reaching
        # the exit-code check below (grocery\test-native-stderr-eap.ps1).
        $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try { $blob = & git -C $repo show ("{0}:lib/{1}" -f $rev, $n) 2>$null } finally { $ErrorActionPreference = $prevEap }
        if ($LASTEXITCODE -eq 0) { Set-Content -LiteralPath (Join-Path $libSb $n) -Value $blob -Encoding UTF8 }
      }
    } else {
      Copy-Item (Join-Path $srcDir '*.ps1')  $sb -Force -ErrorAction SilentlyContinue
      Copy-Item (Join-Path $srcDir '*.json') $sb -Force -ErrorAction SilentlyContinue
      Copy-Item (Join-Path $repo 'lib\*.ps1') $libSb -Force -ErrorAction SilentlyContinue
      $names = @($leaf)
    }
    foreach ($n in $names) {
      $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
      try { $blob = & git -C $repo show ("{0}:{1}/{2}" -f $rev, $srcRel, $n) 2>$null } finally { $ErrorActionPreference = $prevEap }
      if ($LASTEXITCODE -eq 0) { Set-Content -LiteralPath (Join-Path $sb $n) -Value $blob -Encoding UTF8 }
    }
  }
  $outDir = Split-Path (Join-Path $sb $OutputRelPath) -Parent
  New-Item -ItemType Directory -Path $outDir -Force | Out-Null
  $inDir = Join-Path $sb 'out\captures'
  New-Item -ItemType Directory -Path $inDir -Force | Out-Null
  Copy-Item $inFull $inDir -Force
  return $sb
}

function Invoke-TcArm([string]$sb, [string]$label) {
  $inSandbox = Join-Path $sb ('out\captures\' + (Split-Path $inFull -Leaf))
  $log = Join-Path $env:TEMP ("tc-oracle-$label.log")
  $argList = Get-TcArmArgList -ScriptPath (Join-Path $sb $leaf) -InPath $inSandbox -ScriptArgs $ScriptArgs
  # One stderr line from the arm used to throw here under 'Stop' and lose both arms' verdicts.
  $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { & powershell @argList > $log 2>$null } finally { $ErrorActionPreference = $prevEap }
  $code = $LASTEXITCODE
  $out = Join-Path $sb $OutputRelPath
  $rows = @()
  if (Test-Path $out) {
    $j = Get-Content $out -Raw -Encoding UTF8 | ConvertFrom-Json
    $rows = @($j.$ArrayKey)
  }
  return @{ Code = $code; Rows = $rows; Exists = (Test-Path $out); Log = $log; Sandbox = $sb }
}

Write-Output ("CONSISTENCY ORACLE  subject {0}   old revision {1}   mode {2}" -f $Script, $OldRev, $Mode)
Write-Output ("input {0}" -f $inFull)
$A = Invoke-TcArm (New-TcSandbox 'WORKTREE') 'new'
Write-Output ("  arm NEW (worktree)  exit {0}  wrote {1}  rows {2}" -f $A.Code, $A.Exists, @($A.Rows).Count)
$B = Invoke-TcArm (New-TcSandbox $OldRev) 'old'
Write-Output ("  arm OLD ({0})       exit {1}  wrote {2}  rows {3}" -f $OldRev, $B.Code, $B.Exists, @($B.Rows).Count)

if (-not $A.Exists -or -not $B.Exists) {
  Write-Output 'CONSISTENCY ORACLE FAILED: an arm produced no output, so there is nothing to diff. THIS IS NOT "no difference".'
  $bad = if (-not $B.Exists) { $B } else { $A }
  Write-Output ("  tail of the failing log ({0}):" -f $bad.Log)
  if (Test-Path $bad.Log) { Get-Content $bad.Log -Tail 10 | ForEach-Object { Write-Output ('    ' + $_) } }
  Write-Output '  If the old arm died on a missing function, try -Mode World: a stage that LIFTS functions out of'
  Write-Output '  another script cannot run its old self against today''s library (backlog I82).'
  Exit-Guard -Name 'consistency-oracle' -Summary 'failed=arm-produced-no-output' -Code 2
}

$r = Compare-TcRowSets -RowsA $A.Rows -RowsB $B.Rows -Fields $KeyFields
Write-Output ''
Write-Output ("rows NEW {0}   rows OLD {1}   in both {2}" -f @($A.Rows).Count, @($B.Rows).Count, @($r.Common).Count)
Write-Output ("only in NEW {0}   only in OLD {1}   (reported apart from differences, never folded in)" -f @($r.OnlyA).Count, @($r.OnlyB).Count)
Write-Output ("rows in both that DIFFER: {0} of {1}" -f @($r.Differing).Count, @($r.Common).Count)
if ($r.FieldHits.Keys.Count) {
  Write-Output ''
  Write-Output 'WHICH FIELDS MOVED, each with the common-row denominator:'
  foreach ($k in ($r.FieldHits.Keys | Sort-Object { - $r.FieldHits[$_] })) {
    Write-Output ("   {0,-20} {1} of {2}" -f $k, $r.FieldHits[$k], @($r.Common).Count)
  }
}
foreach ($pair in @(@('OnlyA', 'only in NEW'), @('OnlyB', 'only in OLD'))) {
  $set = @($r.($pair[0]))
  if ($set.Count) {
    Write-Output ''
    Write-Output ("{0} ({1}):" -f $pair[1], $set.Count)
    $set | Select-Object -First 8 | ForEach-Object { Write-Output ('   ' + $_) }
  }
}
if (@($r.Differing).Count) {
  Write-Output ''
  Write-Output 'first few differing rows:'
  foreach ($d in (@($r.Differing) | Select-Object -First 5)) {
    Write-Output ("   {0}   fields: {1}" -f $d.Key, ($d.Fields -join ', '))
    foreach ($fl in $d.Fields) { Write-Output ("      {0,-18} new={1}   old={2}" -f $fl, $d.A.$fl, $d.B.$fl) }
  }
}
Write-Output ''
Write-Output 'A NON-ZERO COUNT IS NOT A FAILURE. Output is MEANT to change when a fix lands. The question this'
Write-Output 'answers is WHICH rows changed, so you can confirm you meant every one of them - and so a change'
Write-Output 'you did NOT mean cannot hide among the ones you did.'
Write-Output ("sandboxes kept: {0}  |  {1}" -f $A.Sandbox, $B.Sandbox)
Write-GuardComplete -Name 'consistency-oracle' -Summary ("new={0} old={1} common={2} differing={3} onlynew={4} onlyold={5}" -f `
  @($A.Rows).Count, @($B.Rows).Count, @($r.Common).Count, @($r.Differing).Count, @($r.OnlyA).Count, @($r.OnlyB).Count)
exit 0
