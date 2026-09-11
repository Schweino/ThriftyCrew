# seed-hint.ps1 - when a self-test cannot find an input, say whether this checkout was never seeded, and name the fix.
#
# WHY THIS EXISTS (2026-09-11). A push from a linked worktree that had not been seeded was BLOCKED by ops\hooks\pre-push
# because run-gates exited 1 on two self-tests: meal-prep\pipeline\feed-covers-published.ps1 ("a real built card is
# available to parse   got: missing ...\meal-prep\db\built\american-goulash-pasta.body.html") and
# meal-prep\pipeline\wave-preaudit.ps1 ("END-TO-END the drill inputs exist ...   got: one of them is missing").
# meal-prep\db\built is gitignored, so a worktree has none of its 1,168 files; `ops\seed-worktree.ps1 -Target .` copied
# them and both passed. seed-worktree's $SEED_DIRS already named exactly those two self-tests, and nothing a pusher
# could see did, so every spawned session that pushed met a red with no stated cause.
#
# WHY IN THE FAILING CASE'S TEXT, NOT IN THE HOOK OR run-gates. Blast radius:
#   - This code runs only inside a case that has ALREADY failed. It cannot turn a failure into a pass or a skip, cannot
#     move any verdict, and adds nothing to a green run. A could-not-look stays a FAIL; it only gains its cause.
#   - A hint in ops\hooks\pre-push or ops\run-gates.ps1 would run on every push by every session and the ~07:00 bot,
#     would need its own idea of which gitignored directories matter, and would print on ANY red in an unseeded
#     worktree, including a red that seeding cannot fix.
#   - It reaches a hand run of the self-test, not only a gate run.
#   WHAT IT DOES NOT REACH: the hook's own summary greps `^  FAIL`, and run-gates indents a case's lines further, so the
#   pusher's screen shows the failing FILE and the path of the kept gate log. The hint is in that log, under the file.
#
# TWO CAUSES, NOT ONE. A missing file under a seeded directory is either an UNSEEDED checkout (the directory is absent
# or empty) or a MOVED input (the directory is populated and this file is not in it: retired or renamed at its source).
# Seeding fixes only the first, so telling a main-checkout run whose sample card was retired to run seed-worktree would
# send it the wrong way. A missing file under no seeded directory gets no hint at all.
#
# THE SEEDED DIRECTORIES ARE READ, NEVER COPIED. Get-TcSeedDirs parses ops\seed-worktree.ps1 and takes the `p` of each
# entry in its $SEED_DIRS assignment, so a directory that leaves that list stops being called seedable here the same day.
# It reads a single-quoted or bare literal only; a computed `p` is not read.
#
# SCOPE OF AN EMPTY HINT: the path lies under no directory $SEED_DIRS names. It does not prove the file is tracked. A
# seed list that cannot be read is never empty: it is said.
#
# THE FIXTURES WRITE `~` FOR `$`, so this file never spells a $SEED_DIRS assignment ([[selftest-greps-its-own-source]]).
#
# NO param() BLOCK, DELIBERATELY: dot-sourced under PS 5.1 a param() block runs in the CALLER's scope and would reset the
# caller's own -SelfTest. Same rule as lib\selftest-discovery.ps1.
#
# Dot-source:  . (Join-Path $repo 'lib\seed-hint.ps1')
# Self-test:   powershell -File lib\seed-hint.ps1 -SelfTest

$__seedHintSelfTest = ($MyInvocation.InvocationName -ne '.') -and ($args -contains '-SelfTest')

function Get-TcSeedDirs {
  # The `p` of every entry in a $SEED_DIRS assignment, read off the parsed source. Returns string[], possibly empty.
  # A file that does not parse returns empty rather than a half-read.
  param([string]$Text)
  $dirs = New-Object System.Collections.Generic.List[string]
  if ([string]::IsNullOrEmpty($Text)) { return , $dirs.ToArray() }
  $errs = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$null, [ref]$errs)
  if ($errs -and $errs.Count) { return , $dirs.ToArray() }
  $assigns = $ast.FindAll({ param($x)
      ($x -is [System.Management.Automation.Language.AssignmentStatementAst]) -and
      ($x.Left -is [System.Management.Automation.Language.VariableExpressionAst]) -and
      [string]::Equals([string]$x.Left.VariablePath.UserPath, 'SEED_DIRS', [StringComparison]::OrdinalIgnoreCase) }, $true)
  foreach ($a in $assigns) {
    $tables = $a.Right.FindAll({ param($x) $x -is [System.Management.Automation.Language.HashtableAst] }, $true)
    foreach ($t in $tables) {
      foreach ($kv in $t.KeyValuePairs) {
        $k = $kv.Item1
        if (-not ($k -is [System.Management.Automation.Language.StringConstantExpressionAst])) { continue }
        if (-not [string]::Equals([string]$k.Value, 'p', [StringComparison]::OrdinalIgnoreCase)) { continue }
        $v = $kv.Item2.Find({ param($x) $x -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true)
        if ($v -and $v.Value) { $dirs.Add([string]$v.Value) }
      }
    }
  }
  return , $dirs.ToArray()
}

function Get-TcMissingInputHint {
  # Why a self-test input is missing and what fixes it. Pure: the file count of a directory is passed in as -FileCount,
  # so the cases drive it with synthetic roots. Returns '' when the path lies under no seeded directory of this checkout.
  param([string]$Repo, [string]$Missing, [string[]]$SeedDirs, [scriptblock]$FileCount)
  $root = ([string]$Repo).Replace('/', '\').TrimEnd('\')
  $full = ([string]$Missing).Replace('/', '\')
  if (-not $root -or -not $full.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { return '' }
  $rel = $full.Substring($root.Length + 1)
  foreach ($d in @($SeedDirs)) {
    $dn = ([string]$d).Replace('/', '\').Trim('\')
    if (-not $dn) { continue }
    # The trailing separator is the boundary: meal-prep\db\built-old is not under meal-prep\db\built.
    if (-not $rel.StartsWith($dn + '\', [StringComparison]::OrdinalIgnoreCase)) { continue }
    $n = [int](& $FileCount ([IO.Path]::Combine($root, $dn)))
    if ($n -le 0) {
      return ("UNSEEDED CHECKOUT: {0} is gitignored and this checkout has no files in it, so this input was never copied here. That is setup, not a code defect, and the case stays red until it is done. Fix: powershell -NoProfile -File {1}\ops\seed-worktree.ps1 -Target {1}   then re-run." -f $dn, $root)
    }
    return ("MOVED INPUT: {0} is seeded here ({1} file(s)) but {2} is not in it, so the input was retired or renamed at its source. Seeding will not bring it back: point the case at a file that exists." -f $dn, $n, $rel)
  }
  return ''
}

function Get-TcMissingInputHintHere {
  # The hint for a real checkout: reads <Repo>\ops\seed-worktree.ps1 for the seeded directories and counts files on disk.
  param([string]$Repo, [string]$Missing)
  $seedPath = [IO.Path]::Combine($Repo, 'ops\seed-worktree.ps1')
  $dirs = @()
  if (Test-Path -LiteralPath $seedPath -PathType Leaf) { $dirs = Get-TcSeedDirs -Text ([IO.File]::ReadAllText($seedPath)) }
  if (@($dirs).Count -eq 0) {
    return ("SEED LIST UNREADABLE: {0} is missing or names no seeded directory, so whether seeding supplies this input is unknown." -f $seedPath)
  }
  return (Get-TcMissingInputHint -Repo $Repo -Missing $Missing -SeedDirs $dirs -FileCount {
      param($dir)
      if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return 0 }
      return [IO.Directory]::GetFiles($dir).Length
    })
}

if ($__seedHintSelfTest) {
  $ErrorActionPreference = 'Stop'
  $script:shFail = 0
  $script:shCases = 0
  $script:shGot = ''
  function Test-ShCase([string]$Label, [scriptblock]$Check) {
    # A case that THROWS is a counted failure, never a skipped line: a suite whose cases all error must not pass.
    $script:shCases++
    $script:shGot = ''
    $ok = $false
    try { $ok = [bool](& $Check) } catch { $script:shGot = 'threw: ' + $_.Exception.Message }
    if ($ok) { Write-Output ('  PASS  ' + $Label) } else { Write-Output ('  FAIL  ' + $Label + '   got: ' + $script:shGot); $script:shFail++ }
  }
  function New-ShText([string[]]$Lines) { return (($Lines -join "`n").Replace('~', '$')) }

  $W = 'S:\wt'
  $seeded = @('meal-prep\db\built')   # reach-fixture-ok: the seeded directory NAME under test; this lib opens no path it is handed
  $none = { param($d) 0 }
  $full = { param($d) 1168 }

  # ---- the pure decision --------------------------------------------------------------------------------------------
  Test-ShCase 'MUST FIRE  THE FOUNDING CASE: a card under a seeded directory this checkout has no files in is UNSEEDED, and the fix names seed-worktree with this checkout as -Target' {
    $h = Get-TcMissingInputHint -Repo $W -Missing ($W + '\meal-prep\db\built\american-goulash-pasta.body.html') -SeedDirs $seeded -FileCount $none   # reach-fixture-ok: a synthetic S:\ card path, the founding case's own spelling; nothing here opens it
    $script:shGot = $h
    ($h -match '^UNSEEDED CHECKOUT: meal-prep\\db\\built is gitignored') -and $h.Contains('S:\wt\ops\seed-worktree.ps1 -Target S:\wt ')
  }
  Test-ShCase 'MUST FIRE  the same card under a POPULATED seeded directory is a MOVED input, and seeding is not offered as the fix' {
    $h = Get-TcMissingInputHint -Repo $W -Missing ($W + '\meal-prep\db\built\american-goulash-pasta.body.html') -SeedDirs $seeded -FileCount $full   # reach-fixture-ok: the same synthetic card, with the directory populated this time
    $script:shGot = $h
    ($h -match '^MOVED INPUT: meal-prep\\db\\built is seeded here \(1168 file\(s\)\)') -and ($h -notmatch 'seed-worktree') -and
      $h.Contains('meal-prep\db\built\american-goulash-pasta.body.html is not in it')   # reach-fixture-ok: expected MESSAGE text, not a read
  }
  Test-ShCase 'MUST NOT FIRE  a missing TRACKED input under no seeded directory gets no hint' {
    $h = Get-TcMissingInputHint -Repo $W -Missing ($W + '\meal-prep\db\costed.json') -SeedDirs $seeded -FileCount $none   # reach-fixture-ok: a synthetic path under no seeded directory, which must get NO hint
    $script:shGot = $h
    $h -ceq ''
  }
  Test-ShCase 'MUST NOT FIRE  a sibling directory sharing the prefix (db\built-old) is not under db\built' {
    $h = Get-TcMissingInputHint -Repo $W -Missing ($W + '\meal-prep\db\built-old\x.body.html') -SeedDirs $seeded -FileCount $none   # reach-fixture-ok: a synthetic sibling directory proving the prefix boundary
    $script:shGot = $h
    $h -ceq ''
  }
  # The other root is the SAME LENGTH as $W on purpose. With a longer one ('T:\main') the substring offset garbled the
  # relative path and this case passed with the root check deleted: a mutation probe's one survivor, 2026-09-11.
  Test-ShCase 'MUST NOT FIRE  a path in ANOTHER checkout, whose root is the same length, is not this checkout''s seeding problem' {
    $h = Get-TcMissingInputHint -Repo $W -Missing 'T:\wt\meal-prep\db\built\x.body.html' -SeedDirs $seeded -FileCount $none   # reach-fixture-ok: a synthetic path in ANOTHER checkout, never this repo
    $script:shGot = $h
    $h -ceq ''
  }
  Test-ShCase 'CLEAN TWIN  a root spelled with a trailing slash and another case, and a forward-slash path, still resolve to UNSEEDED with a clean -Target' {
    $h = Get-TcMissingInputHint -Repo 's:/WT/' -Missing 'S:\wt/meal-prep/db/built/x.body.html' -SeedDirs @('meal-prep/db/built/') -FileCount $none   # reach-fixture-ok: the same synthetic root and directory spelled with forward slashes and another case
    $script:shGot = $h
    ($h -match '^UNSEEDED CHECKOUT') -and $h.Contains('-Target s:\WT ')
  }

  # ---- reading the seed list ------------------------------------------------------------------------------------------
  $tTwo = New-ShText -Lines @('~SEED_DIRS = @(', '  @{ p = ''meal-prep\db\built''', '     why = ''a'' }', '  @{ p = ''fx\cache''; why = ''b'' }', ')')   # reach-fixture-ok: the TEXT of a fixture seed list, parsed as source; no path here is opened
  Test-ShCase 'MUST FIRE  every p of a two-entry seed list is read, in order' {
    $d = Get-TcSeedDirs -Text $tTwo
    $script:shGot = (@($d) -join '|')
    (@($d).Count -eq 2) -and ($d[0] -ceq 'meal-prep\db\built') -and ($d[1] -ceq 'fx\cache')   # reach-fixture-ok: the expected p value read out of that fixture text
  }
  $tMixed = New-ShText -Lines @('# ~SEED_DIRS = @( @{ p = ''commented\out'' } )', '~OTHER = @( @{ p = ''not\a\seed'' } )',
    '~SEED_DIRS = @( @{ p = ''real\seed''; why = ''c'' } )')
  Test-ShCase 'MUST NOT FIRE  a p in a comment or in another variable''s table is not a seeded directory' {
    $d = Get-TcSeedDirs -Text $tMixed
    $script:shGot = (@($d) -join '|')
    (@($d).Count -eq 1) -and ($d[0] -ceq 'real\seed')
  }
  $tBroken = New-ShText -Lines @('~SEED_DIRS = @(', '  @{ p = ''half\read''', '     why = ''unclosed')
  Test-ShCase 'MUST NOT FIRE  a seed list that does not parse yields nothing rather than a half-read' {
    $d = Get-TcSeedDirs -Text $tBroken
    $script:shGot = (@($d) -join '|')
    @($d).Count -eq 0
  }

  # ---- the live wrapper, against a real seed list and a real directory, in a per-run temp root -----------------------
  $tmp = Join-Path $env:TEMP ('sh-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  try {
    $null = New-Item -ItemType Directory -Path $tmp -ErrorAction Stop
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $tmp 'ops')
    [IO.File]::WriteAllText((Join-Path $tmp 'ops\seed-worktree.ps1'),
      (New-ShText -Lines @('~SEED_DIRS = @(', '  @{ p = ''meal-prep\db\built''; why = ''fixture'' }', ')')), (New-Object Text.UTF8Encoding($false)))   # reach-fixture-ok: a fixture seed list written into a %TEMP% root, never this repo's ops\seed-worktree.ps1
    $card = Join-Path $tmp 'meal-prep\db\built\card.body.html'   # reach-fixture-ok: a card path under the %TEMP% root, never this repo's meal-prep
    Test-ShCase 'MUST FIRE  the live wrapper over a real seed list and NO directory says UNSEEDED and names that checkout as -Target' {
      $h = Get-TcMissingInputHintHere -Repo $tmp -Missing $card
      $script:shGot = $h
      ($h -match '^UNSEEDED CHECKOUT') -and $h.Contains('-Target ' + $tmp + ' ')
    }
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $tmp 'meal-prep\db\built')   # reach-fixture-ok: the %TEMP% root's own empty seeded directory
    Test-ShCase 'MUST FIRE  an EMPTY seeded directory is unseeded too, not a moved input' {
      $h = Get-TcMissingInputHintHere -Repo $tmp -Missing $card
      $script:shGot = $h
      $h -match '^UNSEEDED CHECKOUT'
    }
    [IO.File]::WriteAllText((Join-Path $tmp 'meal-prep\db\built\other.body.html'), 'x')   # reach-fixture-ok: a stub file inside the %TEMP% root, so the count is 1
    Test-ShCase 'MUST FIRE  the live wrapper counts a populated directory and says MOVED' {
      $h = Get-TcMissingInputHintHere -Repo $tmp -Missing $card
      $script:shGot = $h
      $h -match '^MOVED INPUT: meal-prep\\db\\built is seeded here \(1 file\(s\)\)'
    }
    Test-ShCase 'MUST FIRE  a checkout with no readable seed list says so, rather than returning no hint' {
      $h = Get-TcMissingInputHintHere -Repo (Join-Path $tmp 'no-such-checkout') -Missing $card
      $script:shGot = $h
      $h -match '^SEED LIST UNREADABLE'
    }
  } finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
  }

  # ---- the shipped list: tracked, so hermetic ----------------------------------------------------------------------
  $shippedPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'ops\seed-worktree.ps1'
  $shipped = @()
  if (Test-Path -LiteralPath $shippedPath) { $shipped = Get-TcSeedDirs -Text ([IO.File]::ReadAllText($shippedPath)) }
  Write-Output ("  resolved {0} seeded director(ies) from ops\seed-worktree.ps1: {1}" -f @($shipped).Count, (@($shipped) -join ', '))
  Test-ShCase 'the shipped seed list resolves and names meal-prep\db\built, where both callers'' inputs live' {   # reach-fixture-ok: the case LABEL naming the directory this hint exists for
    $script:shGot = (@($shipped) -join '|')
    @($shipped) -contains 'meal-prep\db\built'   # reach-fixture-ok: asserted against seed-worktree's list as TEXT; nothing here opens the directory
  }

  if ($script:shCases -eq 0) { Write-Output 'SEED-HINT SELF-TEST FAILED (ran zero cases)'; exit 1 }
  if ($script:shFail) { Write-Output ("SEED-HINT SELF-TEST FAILED ({0} of {1} case(s))" -f $script:shFail, $script:shCases); exit 1 }
  Write-Output ("SEED-HINT SELF-TEST PASSED ({0} of {0} case(s): unseeded and moved inputs are told apart, only seeded directories get a hint, the seed list is read from source, and an unreadable one is said)" -f $script:shCases)
  exit 0
}
