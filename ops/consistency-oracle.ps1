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
  <arm>\<its repo-relative dir> with <arm>\lib beside it holding EVERY lib\*.ps1: a grocery script walks
  up one level to it and a meal-prep\pipeline script two.
  MISSING WAS THE LUCKY CASE. %TEMP%\lib does exist on a box that has run grocery\test-auditors, whose
  fixtures keep json-io.ps1 and guard-contract.ps1 there, so a flat sandbox loaded whatever copy that
  suite last left and ran on a library nobody chose. The self-test's MUST FIRE plants exactly that: a
  working library where the flat layout looked, and the arm's own lib\ without it.
  Only the source directory and lib\ are carried: a subject that reads another top-level directory
  (graph\, public\) will not find it in the sandbox.

  ONE ROOT PER RUN, REMOVED IN A FINALLY. %TEMP%\tc-oracle-<id>\ holds both arms, new\ and old\, and
  both arms' logs, and a finally removes it; -KeepSandbox keeps it and prints where. Every earlier run
  left both sandboxes behind, and the logs were the fixed %TEMP%\tc-oracle-new.log and
  tc-oracle-old.log, which two concurrent runs overwrote for each other. Each arm's stderr now has its
  own log too, because a subject that dies on a missing library says so on stderr.

  A REVISION IS EXTRACTED WITH `git archive -o` AND tar.exe: one process each, writing straight to a
  file, so no file taken from a revision passes through PowerShell's text pipeline. This is NOT a fix
  for damage anyone saw. The old path, one `& git show` per file written back with Set-Content, decodes
  git's output with the console code page; on the box where this was written that page is 65001, and
  that path round-tripped 10 of 10 non-ASCII grocery scripts intact (2026-09-11). The gain is one
  process instead of one per file, and a result that does not depend on the console code page.

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
    -Mode Script  pins ONLY the script under test. Its sibling scripts and lib\ stay as they are in
                  the working tree. Answers "did THIS script's behaviour change".
    -Mode World   pins the whole source directory AND lib\ at that revision - the world the old
                  script actually ran in. Answers "did the pipeline's output change". THIS IS
                  USUALLY THE ONE YOU WANT, and the reason is real: on the founding run, Script mode
                  could not execute at all, because the old build-walmart-deals lifts a
                  hand-maintained list of function names out of compare-deals.ps1 and against
                  today's compare-deals it lifted a function whose callee did not exist yet. That is
                  a true finding about coupling (backlog I82) and it is also a dead end for the diff.
                  LIB\ IS PINNED TOO, deliberately. Keeping lib\ at HEAD would rebuild that same dead
                  end one directory up, because shared code keeps moving out of the stage scripts and
                  into libraries: an old stage beside today's lib\ is a pairing that never existed at
                  any revision, so a diff over it answers neither question. A library added since
                  that revision is simply absent, and the old script never named it.

  Example, the founding run:
    ops\consistency-oracle.ps1 -Script grocery\build-walmart-deals.ps1 -OldRev d81391efa `
      -InputFile grocery\out\captures\walmart-capture-2026-09-08.csv `
      -OutputRelPath out\regular\walmart-regular-2026-09-08.json -ArrayKey deals `
      -KeyFields item_id,item -Args @{ Date = '2026-09-08' }

  EXIT CODES (lib\guard-contract.ps1 vocabulary): 0 ran and diffed, 2 an arm failed to produce
  output, 3 could not evaluate (a missing argument or input, an -OldRev that is not a commit, a
  subject absent at that revision, or a sandbox git could not build). A non-zero difference count
  is NOT a failure - read the report.
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
  [switch]$KeepSandbox,
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\ops' }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $repo 'lib\git-repo-env.ps1')   # Clear-TcGitRepoEnv, for the self-test's temp repo
$script:TcTar = Join-Path $env:SystemRoot 'System32\tar.exe'

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

# --------------------------------------------------------------------------------- the sandbox
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

function New-TcRunRoot {
  <# One directory per run, directly under %TEMP%, holding both arms and both arms' logs. Created with
     -ErrorAction Stop so a name clash refuses rather than shares. The id is 8 hex characters, not a
     whole guid, because every character lands on every path a subject writes and PS 5.1 stops at
     MAX_PATH. #>
  param([string]$Prefix = 'tc-oracle-')
  $p = Join-Path $env:TEMP ($Prefix + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Path $p -ErrorAction Stop | Out-Null
  return $p
}

function Remove-TcRunRoot {
  <# '' when the root is gone, otherwise the reason, so a root that could not be removed is SPOKEN. #>
  param([Parameter(Mandatory=$true)][string]$Path)
  try { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop; return '' }
  catch { return [string]$_.Exception.Message }
}

function Get-TcRevisionNames {
  <# The repo-relative names git ls-tree lists at $Rev under $Prefix ('stage/', 'lib/', or '' for the
     root). Throws when git cannot read the tree, so an unreadable revision never reads as an empty
     directory. #>
  param([string]$RepoRoot, [string]$Rev, [string]$Prefix)
  $argv = @('-C', $RepoRoot, 'ls-tree', '--name-only', $Rev)
  if ($Prefix) { $argv += @('--', $Prefix) }
  $out = & git @argv
  if ($LASTEXITCODE -ne 0) { throw ("git ls-tree could not read '{0}' at {1} (exit {2})" -f $Prefix, $Rev, $LASTEXITCODE) }
  return $out
}

function Copy-TcRevision {
  <# Extracts every file matching $Specs at $Rev into $Dest, at its repo-relative path. #>
  param([string]$RepoRoot, [string]$Rev, [string[]]$Specs, [string]$Dest)
  if (-not @($Specs).Count) { return }
  if (-not (Test-Path -LiteralPath $script:TcTar)) { throw ("tar.exe is not at {0}, so no revision can be extracted" -f $script:TcTar) }
  $tarFile = $Dest.TrimEnd('\') + '.tar'
  & git -C $RepoRoot archive --format=tar -o $tarFile $Rev -- @Specs
  if ($LASTEXITCODE -ne 0) { throw ("git archive could not extract {0} at {1} (exit {2})" -f ($Specs -join ' '), $Rev, $LASTEXITCODE) }
  & $script:TcTar -xf $tarFile -C $Dest
  $tarCode = $LASTEXITCODE
  Remove-Item -LiteralPath $tarFile -Force
  if ($tarCode -ne 0) { throw ("tar could not unpack {0} into {1} (exit {2})" -f $tarFile, $Dest, $tarCode) }
}

function New-TcSandbox {
  <# Builds ONE arm's repo-shaped sandbox at $Root, which must not exist yet, laid out by
     Get-TcSandboxLayout:
       $Root\<SrcRel>\   the source directory's *.ps1 and *.json, plus out\captures\<input>
       $Root\lib\        every lib\*.ps1
     -Rev WORKTREE copies both from the working tree. Any other -Rev is a commit, and -PinMode decides
     what it pins: Script overwrites only the subject with its bytes at that revision; World takes the
     source directory AND lib\ from that revision and nothing from the working tree.
     Returns Root, Dir (the directory the subject runs from - what Invoke-TcArm is handed), and the
     SourceFiles and LibFiles counts it resolved, so a sandbox built over nothing says so. #>
  param(
    [Parameter(Mandatory=$true)][string]$Root,
    [Parameter(Mandatory=$true)][string]$RepoRoot,
    [AllowEmptyString()][string]$SrcRel = '',
    [Parameter(Mandatory=$true)][string]$Leaf,
    [string]$Rev = 'WORKTREE',
    [ValidateSet('Script', 'World')][string]$PinMode = 'World',
    [string]$InputFile = '',
    [string]$OutputRelPath = ''
  )
  $SrcRel = ($SrcRel -replace '/', '\').Trim('\')
  $layout = Get-TcSandboxLayout -Top $Root -SrcRel $SrcRel
  $dir = $layout.ScriptDir
  $libDir = $layout.Lib
  New-Item -ItemType Directory -Path $Root -ErrorAction Stop | Out-Null
  New-Item -ItemType Directory -Path $dir -Force | Out-Null
  New-Item -ItemType Directory -Path $libDir -Force | Out-Null
  $srcCount = 0; $libCount = 0

  if ($Rev -eq 'WORKTREE' -or $PinMode -eq 'Script') {
    $srcFull = if ($SrcRel) { Join-Path $RepoRoot $SrcRel } else { $RepoRoot }
    $src = @(Get-ChildItem -LiteralPath $srcFull -File | Where-Object { @('.ps1', '.json') -contains $_.Extension.ToLowerInvariant() })
    foreach ($s in $src) { Copy-Item -LiteralPath $s.FullName -Destination (Join-Path $dir $s.Name) -Force }
    $libSrc = Join-Path $RepoRoot 'lib'
    $libs = @()
    if (Test-Path -LiteralPath $libSrc) { $libs = @(Get-ChildItem -LiteralPath $libSrc -File | Where-Object { $_.Extension.ToLowerInvariant() -eq '.ps1' }) }
    foreach ($l in $libs) { Copy-Item -LiteralPath $l.FullName -Destination (Join-Path $libDir $l.Name) -Force }
    $srcCount = $src.Count; $libCount = $libs.Count
  }

  if ($Rev -ne 'WORKTREE') {
    & git -C $RepoRoot rev-parse --verify --quiet ($Rev + '^{commit}') | Out-Null
    if ($LASTEXITCODE -ne 0) { throw ("-OldRev '{0}' is not a commit in {1}" -f $Rev, $RepoRoot) }
    $prefix = if ($SrcRel) { ($SrcRel -replace '\\', '/') + '/' } else { '' }
    $leafRaw = Get-TcRevisionNames -RepoRoot $RepoRoot -Rev $Rev -Prefix ($prefix + $Leaf)
    if (-not @($leafRaw | Where-Object { $_ }).Count) { throw ("the subject {0}{1} does not exist at {2}, so there is no old arm to run" -f $prefix, $Leaf, $Rev) }
    if ($PinMode -eq 'Script') {
      Copy-TcRevision -RepoRoot $RepoRoot -Rev $Rev -Specs @(':(literal)' + $prefix + $Leaf) -Dest $Root
    } else {
      $specs = @()
      $srcRaw = Get-TcRevisionNames -RepoRoot $RepoRoot -Rev $Rev -Prefix $prefix
      $srcNames = @($srcRaw | Where-Object { $_ })
      foreach ($ext in @('ps1', 'json')) {
        $n = @($srcNames | Where-Object { $_ -cmatch ('\.' + $ext + '$') }).Count
        if ($n) { $specs += (':(glob)' + $prefix + '*.' + $ext); $srcCount += $n }
      }
      $libRaw = Get-TcRevisionNames -RepoRoot $RepoRoot -Rev $Rev -Prefix 'lib/'
      $libNames = @($libRaw | Where-Object { $_ -cmatch '\.ps1$' })
      if ($libNames.Count) { $specs += ':(glob)lib/*.ps1'; $libCount = $libNames.Count }
      Copy-TcRevision -RepoRoot $RepoRoot -Rev $Rev -Specs $specs -Dest $Root
    }
  }

  if ($OutputRelPath) { New-Item -ItemType Directory -Path (Split-Path (Join-Path $dir $OutputRelPath) -Parent) -Force | Out-Null }
  $capDir = Join-Path $dir 'out\captures'
  New-Item -ItemType Directory -Path $capDir -Force | Out-Null
  if ($InputFile) { Copy-Item -LiteralPath $InputFile -Destination $capDir -Force }
  return [pscustomobject]@{ Root = $Root; Dir = $dir; SourceFiles = $srcCount; LibFiles = $libCount }
}

function Invoke-TcArm {
  <# Runs the subject from its sandbox directory and reads its output. Stdout goes to <LogBase>.log
     and stderr to <LogBase>.err.log. -ScriptArgs is handed in BY NAME and becomes the command line
     through Get-TcArmArgList. #>
  param(
    [Parameter(Mandatory=$true)][string]$Dir,
    [Parameter(Mandatory=$true)][string]$Leaf,
    [Parameter(Mandatory=$true)][string]$InputFile,
    [Parameter(Mandatory=$true)][string]$OutputRelPath,
    [Parameter(Mandatory=$true)][string]$ArrayKey,
    [hashtable]$ScriptArgs = @{},
    [Parameter(Mandatory=$true)][string]$LogBase
  )
  $log = $LogBase + '.log'
  $errLog = $LogBase + '.err.log'
  $inSandbox = Join-Path $Dir ('out\captures\' + (Split-Path $InputFile -Leaf))
  $argList = Get-TcArmArgList -ScriptPath (Join-Path $Dir $Leaf) -InPath $inSandbox -ScriptArgs $ScriptArgs
  # Continue around the child only: under Stop, a redirected native stderr line becomes a terminating error.
  $eap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try { & powershell @argList > $log 2> $errLog } finally { $ErrorActionPreference = $eap }
  $code = $LASTEXITCODE
  $out = Join-Path $Dir $OutputRelPath
  $rows = @()
  $exists = Test-Path -LiteralPath $out
  if ($exists) {
    $j = Get-Content -LiteralPath $out -Raw -Encoding UTF8 | ConvertFrom-Json
    $rows = @($j.$ArrayKey)
  }
  return @{ Code = $code; Rows = $rows; Exists = $exists; Log = $log; ErrLog = $errLog }
}

# ------------------------------------------------------------------------------------- self-test
if ($SelfTest) {
  $f = 0; $n = 0; $nMust = 0; $nNot = 0; $nTwin = 0
  function T($m, $cond, $got) {
    $script:n++
    if ($m -like 'MUST FIRE*') { $script:nMust++ } elseif ($m -like 'MUST NOT FIRE*') { $script:nNot++ } elseif ($m -like 'CLEAN TWIN*') { $script:nTwin++ }
    if ($cond) { Write-Output ("ok    " + $m) } else { Write-Output ("FAIL  " + $m + "   got: " + $got); $script:f++ }
  }

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

  # ---- a real sandbox, built and run (2026-09-11) ----------------------------------------------
  # The layout cases above check path arithmetic; nothing in them builds a sandbox, copies lib\ or
  # runs a subject, so a New-TcSandbox that skipped lib\ would leave them green. These do all three.
  # Hermetic: a frozen fixture REPO under this run's own root - lib\ holding a copy of the real
  # json-io.ps1 (source, not data) and a library no subject names, and two frozen subjects under
  # neutral directory names - plus a three-line CSV. Subjects run out of process because resolving
  # $PSScriptRoot IS the behaviour. Every case builds its arm one directory below its own case
  # directory, so the case directory is exactly where a FLAT sandbox would look for ..\lib.
  $st = New-TcRunRoot -Prefix 'tco-st-'
  try {
    $fx = Join-Path $st 'repo'
    foreach ($d in @('lib', 'stage', 'pack\stage')) { New-Item -ItemType Directory -Path (Join-Path $fx $d) -Force | Out-Null }
    Copy-Item -LiteralPath (Join-Path $repo 'lib\json-io.ps1') -Destination (Join-Path $fx 'lib\json-io.ps1')
    Set-Content -LiteralPath (Join-Path $fx 'lib\fx-extra.ps1') -Value 'function Get-FxExtra { return ''extra'' }' -Encoding UTF8
    $subjectBody = @'
$ErrorActionPreference = 'Stop'
. (Join-Path LIBROOT 'lib\json-io.ps1')
$rows = @(Import-Csv -LiteralPath $In | ForEach-Object { [pscustomobject]@{ id = $_.id; item = $_.item; date = $Date } })
Write-JsonFile -Path (Join-Path $PSScriptRoot 'out\fx\fx-out.json') -Content ([pscustomobject]@{ deals = $rows })
'@
    Set-Content -LiteralPath (Join-Path $fx 'stage\fx-subject.ps1') -Encoding UTF8 -Value (
      "param([string]`$In = '', [string]`$Date = '')`r`n" + $subjectBody.Replace('LIBROOT', '(Split-Path $PSScriptRoot -Parent)'))
    Set-Content -LiteralPath (Join-Path $fx 'pack\stage\fx-deep.ps1') -Encoding UTF8 -Value (
      "param([string]`$In = '', [string]`$Date = '')`r`n" + $subjectBody.Replace('LIBROOT', '(Split-Path (Split-Path $PSScriptRoot -Parent) -Parent)'))
    $fxIn = Join-Path $st 'fx-in-2026-09-08.csv'
    Set-Content -LiteralPath $fxIn -Value @('id,item', '1,beans', '2,rice') -Encoding ASCII
    $fxOut = 'out\fx\fx-out.json'

    function Invoke-FxArm([string]$CaseDir, [string]$SrcRel, [string]$Leaf, [string]$RepoRoot, [string]$Rev = 'WORKTREE', [string]$PinMode = 'World', [string]$OutRel = $fxOut) {
      $sb = New-TcSandbox -Root (Join-Path $CaseDir 'arm') -RepoRoot $RepoRoot -SrcRel $SrcRel -Leaf $Leaf -Rev $Rev -PinMode $PinMode -InputFile $fxIn -OutputRelPath $OutRel
      $arm = Invoke-TcArm -Dir $sb.Dir -Leaf $Leaf -InputFile $fxIn -OutputRelPath $OutRel -ArrayKey 'deals' -ScriptArgs @{ Date = '2026-09-08' } -LogBase (Join-Path $CaseDir 'arm')
      return @{ Sandbox = $sb; Arm = $arm }
    }

    $runA = Invoke-FxArm -CaseDir (Join-Path $st 'a') -SrcRel 'stage' -Leaf 'fx-subject.ps1' -RepoRoot $fx
    T 'CLEAN TWIN  a complete repo-shaped sandbox runs a subject that dot-sources ..\lib\json-io.ps1 to its output' `
      (($runA.Arm.Code -eq 0) -and $runA.Arm.Exists -and (@($runA.Arm.Rows).Count -eq 2)) `
      ("exit={0} wrote={1} rows={2}" -f $runA.Arm.Code, $runA.Arm.Exists, @($runA.Arm.Rows).Count)
    $dates = @(@($runA.Arm.Rows) | ForEach-Object { [string]$_.date })
    T 'CLEAN TWIN  the -Args value reaches the RUNNING subject end to end, not only its command line' `
      ((@($dates | Where-Object { $_ -eq '2026-09-08' }).Count -eq 2)) ("dates=" + ($dates -join ','))

    $want = @(Get-ChildItem -LiteralPath (Join-Path $fx 'lib') -File | ForEach-Object { $_.Name } | Sort-Object)
    $got = @(Get-ChildItem -LiteralPath (Join-Path $runA.Sandbox.Root 'lib') -File -ErrorAction SilentlyContinue | ForEach-Object { $_.Name } | Sort-Object)
    T 'CLEAN TWIN  the sandbox lib\ holds EVERY lib\*.ps1 of the source, including one no subject names, and says how many it resolved' `
      ([string]::Equals(($want -join ','), ($got -join ','), [StringComparison]::Ordinal) -and ($got -contains 'fx-extra.ps1') -and ($runA.Sandbox.LibFiles -eq $want.Count)) `
      ("want={0} got={1} resolved={2}" -f ($want -join ','), ($got -join ','), $runA.Sandbox.LibFiles)

    # THE FOUNDING BUG, AS IT RAN. A working copy of json-io.ps1 sits where a FLAT sandbox resolves
    # ..\lib - the parent of the arm's root - which is what %TEMP%\lib was. The arm's OWN lib\ loses
    # the library. A repo-shaped sandbox must fail the subject; a flat one is rescued by the stray copy.
    # THE DECOY IS LOAD-BEARING: without it a flat sandbox fails the subject too, for the wrong reason,
    # and this case stays green (measured by mutation, 2026-09-11).
    $caseB = Join-Path $st 'b'
    New-Item -ItemType Directory -Path (Join-Path $caseB 'lib') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $fx 'lib\json-io.ps1') -Destination (Join-Path $caseB 'lib\json-io.ps1')
    $sbB = New-TcSandbox -Root (Join-Path $caseB 'arm') -RepoRoot $fx -SrcRel 'stage' -Leaf 'fx-subject.ps1' -InputFile $fxIn -OutputRelPath $fxOut
    $dropped = Join-Path $sbB.Root 'lib\json-io.ps1'
    if (Test-Path -LiteralPath $dropped) { Remove-Item -LiteralPath $dropped }
    $armB = Invoke-TcArm -Dir $sbB.Dir -Leaf 'fx-subject.ps1' -InputFile $fxIn -OutputRelPath $fxOut -ArrayKey 'deals' -ScriptArgs @{ Date = '2026-09-08' } -LogBase (Join-Path $caseB 'arm')
    $errText = if (Test-Path -LiteralPath $armB.ErrLog) { [IO.File]::ReadAllText($armB.ErrLog) } else { '' }
    T 'MUST FIRE  a sandbox whose own lib\ lacks json-io.ps1 FAILS the subject that dot-sources it, even with a working copy where the old flat sandbox looked (the stale %TEMP%\lib)' `
      (($armB.Code -ne 0) -and (-not $armB.Exists) -and ($errText -match 'json-io\.ps1')) `
      ("exit={0} wrote={1} stderr names json-io={2}" -f $armB.Code, $armB.Exists, ($errText -match 'json-io\.ps1'))

    $runD = Invoke-FxArm -CaseDir (Join-Path $st 'd') -SrcRel 'pack\stage' -Leaf 'fx-deep.ps1' -RepoRoot $fx
    T 'CLEAN TWIN  a subject two directories down that walks up TWO levels to lib\ runs to its output' `
      (($runD.Arm.Code -eq 0) -and $runD.Arm.Exists -and (@($runD.Arm.Rows).Count -eq 2)) `
      ("exit={0} wrote={1} rows={2}" -f $runD.Arm.Code, $runD.Arm.Exists, @($runD.Arm.Rows).Count)

    # WHAT A REVISION PINS. A temp repo whose library says 'old' at the first commit and 'new' at the
    # second, and whose subject carries a non-ASCII word built from a code point, so this file's own
    # encoding cannot supply it. The word case is a positive check on git archive only: a mutant that put
    # the old per-file `git show` back SURVIVED it on a UTF-8 console (2026-09-11), so it does not guard
    # that path.
    Clear-TcGitRepoEnv
    $gr = Join-Path $st 'git'
    foreach ($d in @('lib', 'stage')) { New-Item -ItemType Directory -Path (Join-Path $gr $d) -Force | Out-Null }
    & git -C $gr init -q .
    & git -C $gr config user.email t@t
    & git -C $gr config user.name t
    & git -C $gr config core.autocrlf false
    $word = 'caf' + [char]0x00E9
    $verBody = @'
param([string]$In = '', [string]$Date = '')
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\fx-ver.ps1')
$doc = [pscustomobject]@{ deals = @([pscustomobject]@{ id = '1'; ver = (Get-FxVer); word = 'WORD' }) }
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'out\fx\fx-ver.json'), ($doc | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))
'@
    Set-Content -LiteralPath (Join-Path $gr 'stage\fx-ver.ps1') -Value $verBody.Replace('WORD', $word) -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $gr 'lib\fx-ver.ps1') -Value "function Get-FxVer { return 'old' }" -Encoding UTF8
    & git -C $gr add -- stage/fx-ver.ps1 lib/fx-ver.ps1
    & git -C $gr commit -q -m one
    $rev1 = [string](& git -C $gr rev-parse HEAD)
    Set-Content -LiteralPath (Join-Path $gr 'lib\fx-ver.ps1') -Value "function Get-FxVer { return 'new' }" -Encoding UTF8
    & git -C $gr add -- lib/fx-ver.ps1
    & git -C $gr commit -q -m two

    $runW = Invoke-FxArm -CaseDir (Join-Path $st 'w') -SrcRel 'stage' -Leaf 'fx-ver.ps1' -RepoRoot $gr -Rev $rev1 -PinMode 'World' -OutRel 'out\fx\fx-ver.json'
    $verW = @(@($runW.Arm.Rows) | ForEach-Object { [string]$_.ver }) -join ','
    T 'CLEAN TWIN  -Mode World at an old revision pins lib\ too: the old subject runs beside its library AS IT WAS' `
      ($runW.Arm.Exists -and ($verW -eq 'old')) ("exit={0} wrote={1} ver={2}" -f $runW.Arm.Code, $runW.Arm.Exists, $verW)
    $wordW = @(@($runW.Arm.Rows) | ForEach-Object { [string]$_.word }) -join ','
    T 'CLEAN TWIN  a non-ASCII word in a script taken from a revision survives extraction and runs' `
      ([string]::Equals($wordW, $word, [StringComparison]::Ordinal)) ("word code points=" + (($wordW.ToCharArray() | ForEach-Object { [int]$_ }) -join ' '))

    $runS = Invoke-FxArm -CaseDir (Join-Path $st 's') -SrcRel 'stage' -Leaf 'fx-ver.ps1' -RepoRoot $gr -Rev $rev1 -PinMode 'Script' -OutRel 'out\fx\fx-ver.json'
    $verS = @(@($runS.Arm.Rows) | ForEach-Object { [string]$_.ver }) -join ','
    T 'CLEAN TWIN  -Mode Script at the same revision pins only the subject, and lib\ comes from the working tree' `
      ($runS.Arm.Exists -and ($verS -eq 'new')) ("exit={0} wrote={1} ver={2}" -f $runS.Arm.Code, $runS.Arm.Exists, $verS)
  } catch {
    T ('the sandbox cases could not run: ' + $_.Exception.Message) $false ('at line ' + $_.InvocationInfo.ScriptLineNumber)
  } finally {
    $why = Remove-TcRunRoot -Path $st
    if ($why) { Write-Output ("FAIL  the self-test root {0} was not removed: {1}" -f $st, $why); $f++ }
  }

  if ($f) { Write-Output ("SELF-TEST FAIL: {0} of {1} check(s)" -f $f, $n); exit 1 }
  Write-Output ("SELF-TEST PASS: {0} cases - {1} must-fire, {2} must-not-fire, {3} clean twins. The row diff keeps an emitted-versus-dropped row apart from a changed value; the sandbox cases build and run real sandboxes, led by the must-fire that a library missing from the arm's own lib\ fails its subject despite a stray copy where the flat sandbox looked" -f $n, $nMust, $nNot, $nTwin)
  exit 0
}

# ------------------------------------------------------------------------------- the live run
foreach ($p in @('Script', 'OldRev', 'InputFile', 'OutputRelPath', 'ArrayKey')) {
  if (-not (Get-Variable $p -ValueOnly)) {
    Write-Output ("CONSISTENCY ORACLE COULD NOT EVALUATE: -{0} is required. See the header for a worked example." -f $p)
    Exit-Guard -Name 'consistency-oracle' -Summary 'blind=missing-argument' -Code 3
  }
}
$srcRel = Split-Path ($Script -replace '/', '\') -Parent
$leaf = Split-Path $Script -Leaf
$inFull = if ([IO.Path]::IsPathRooted($InputFile)) { $InputFile } else { Join-Path $repo $InputFile }
if (-not (Test-Path $inFull)) {
  Write-Output ("CONSISTENCY ORACLE BLIND: the input {0} does not exist, so nothing was compared. That is not 'no difference'." -f $inFull)
  Exit-Guard -Name 'consistency-oracle' -Summary 'blind=no-input' -Code 3
}

Write-Output ("CONSISTENCY ORACLE  subject {0}   old revision {1}   mode {2}" -f $Script, $OldRev, $Mode)
Write-Output ("input {0}" -f $inFull)
$runRoot = New-TcRunRoot
$verdict = 0
$summary = ''
try {
  $sbA = New-TcSandbox -Root (Join-Path $runRoot 'new') -RepoRoot $repo -SrcRel $srcRel -Leaf $leaf -Rev 'WORKTREE' -PinMode $Mode -InputFile $inFull -OutputRelPath $OutputRelPath
  Write-Output ("  sandbox NEW  {0} source file(s) and {1} lib file(s), from the working tree" -f $sbA.SourceFiles, $sbA.LibFiles)
  $A = Invoke-TcArm -Dir $sbA.Dir -Leaf $leaf -InputFile $inFull -OutputRelPath $OutputRelPath -ArrayKey $ArrayKey -ScriptArgs $ScriptArgs -LogBase (Join-Path $runRoot 'new')
  Write-Output ("  arm NEW (worktree)  exit {0}  wrote {1}  rows {2}" -f $A.Code, $A.Exists, @($A.Rows).Count)
  $sbB = New-TcSandbox -Root (Join-Path $runRoot 'old') -RepoRoot $repo -SrcRel $srcRel -Leaf $leaf -Rev $OldRev -PinMode $Mode -InputFile $inFull -OutputRelPath $OutputRelPath
  $pinned = if ($Mode -eq 'World') { 'source directory and lib\ at ' + $OldRev } else { 'the subject at ' + $OldRev + ', the rest from the working tree' }
  Write-Output ("  sandbox OLD  {0} source file(s) and {1} lib file(s): {2}" -f $sbB.SourceFiles, $sbB.LibFiles, $pinned)
  $B = Invoke-TcArm -Dir $sbB.Dir -Leaf $leaf -InputFile $inFull -OutputRelPath $OutputRelPath -ArrayKey $ArrayKey -ScriptArgs $ScriptArgs -LogBase (Join-Path $runRoot 'old')
  Write-Output ("  arm OLD ({0})       exit {1}  wrote {2}  rows {3}" -f $OldRev, $B.Code, $B.Exists, @($B.Rows).Count)

  if (-not $A.Exists -or -not $B.Exists) {
    Write-Output 'CONSISTENCY ORACLE FAILED: an arm produced no output, so there is nothing to diff. THIS IS NOT "no difference".'
    $bad = if (-not $B.Exists) { $B } else { $A }
    foreach ($lf in @($bad.Log, $bad.ErrLog)) {
      Write-Output ("  tail of {0}:" -f (Split-Path $lf -Leaf))
      if (Test-Path -LiteralPath $lf) { Get-Content -LiteralPath $lf -Tail 10 | ForEach-Object { Write-Output ('    ' + $_) } }
    }
    Write-Output '  If the old arm died on a missing function, try -Mode World: a stage that LIFTS functions out of'
    Write-Output '  another script cannot run its old self against today''s library (backlog I82).'
    $verdict = 2
  } else {
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
    $summary = "new={0} old={1} common={2} differing={3} onlynew={4} onlyold={5}" -f `
      @($A.Rows).Count, @($B.Rows).Count, @($r.Common).Count, @($r.Differing).Count, @($r.OnlyA).Count, @($r.OnlyB).Count
  }
} catch {
  Write-Output ("CONSISTENCY ORACLE COULD NOT EVALUATE: {0}" -f $_.Exception.Message)
  $verdict = 3
} finally {
  if ($KeepSandbox) {
    Write-Output ("sandboxes and arm logs kept (-KeepSandbox): {0}" -f $runRoot)
  } else {
    $why = Remove-TcRunRoot -Path $runRoot
    if ($why) { Write-Output ("sandboxes NOT removed from {0}: {1}" -f $runRoot, $why) }
    else { Write-Output ("sandboxes and arm logs removed: {0}" -f $runRoot) }
  }
}
if ($verdict -eq 3) { Exit-Guard -Name 'consistency-oracle' -Summary 'blind=sandbox-or-arm-could-not-run' -Code 3 }
if ($verdict -eq 2) { Exit-Guard -Name 'consistency-oracle' -Summary 'failed=arm-produced-no-output' -Code 2 }
Write-GuardComplete -Name 'consistency-oracle' -Summary $summary
exit 0
