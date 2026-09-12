# audit-cross-module-reach.ps1
# ---------------------------------------------------------------------------------------------------
# A module reaches into another module's WORKING DIRECTORY by writing a path string, and nothing in this
# estate declares that (2026-09-09, backlog I90).
#
# THE DISTINCTION THIS DETECTOR EXISTS FOR, and it is not "does meal-prep mention grocery":
#   * `public/board.json` and `content/` are PUBLISHED artefacts. Reading one is the contract working.
#   * `grocery/out/`, `meal-prep/db/`, `graph/state/` are INTERNALS. They are gitignored or churn daily,
#     which is exactly why a worktree, a CI runner or a clean checkout prices nothing and exits 0.
# A reach into another module's internals is the finding. A reach into its published artefact is not.
#
# SCOPE OF A CLEAN REPORT: UNSOUND, so a clean report proves nothing. This is a pattern matcher over
# source text and it finds the spellings it knows - a literal path with a module-internals prefix, in
# either slash direction. It cannot see a path assembled at run time (`Join-Path $mp $sub`), one read
# from config, or one reached through a variable set three files away. A reported reach is real; the
# absence of one is not evidence there is none. The number it prints is a FLOOR, exactly as the
# founding grep's 36 was.
#
# WHAT IT IMPROVES ON THE FOUNDING MEASUREMENT. `grep -rl` counted a mention in a comment the same as a
# read, and counted a file once however many times it reached. This counts SITES, not files, and splits
# them into `code` and `comment`. Only the CODE count is ratcheted, because a comment naming a path is
# documentation and gating it would push people to delete the explanation rather than the coupling.
#
# A COMMENT IS WHAT THE TOKENIZER SAYS IT IS, NOT WHAT THE LINE SAYS (2026-09-11). Until then a site was a
# comment only when a `#` opened earlier on its OWN line, so every line inside a <# #> block scored as CODE
# and was ratcheted: ops\audit-glued-keyword.ps1 read 133 -> 134 for naming grocery's ads file in its header
# prose. That is the class ops\audit-source-comment-strip.ps1 names, in a spelling it does not match.
# Measured at 0a681beb0 over ALL 159 sites the sweep returned (578 files scanned, 54 carrying a site),
# through this file's own Get-ReachSites lifted by AST and each site placed in a Language.Parser token:
#   15 of the 133 code sites sat inside a block comment, every one of them header prose read by eye;
#    0 sat inside a here-string; 0 comment sites sat in real code; the other 144 kept their label.
# So the baseline moved 133 -> 118 that day FOR THAT REASON ALONE. The number changed because what is
# counted changed, not because any coupling was removed, and every run prints what the line rule would
# still read beside it so nobody mistakes the drop for progress.
#   * A HERE-STRING STAYS CODE. It is a value the program uses, like the quoted strings this has always
#     counted, and `reach-fixture-ok:` is the per-line opt-out for a fixture.
#   * The tokenizer runs only on a file that already has a site (54 of 578, about 0.3 s that day).
#   * A file that does not parse cleanly, or carries a bare CR the line split would miscount, is classified
#     by the old line rule, which leans CODE - so an unclosed block comment cannot hide the rest of a file.
#
# DELIBERATELY A RATCHET, NOT A GATE. The number is what it is today and a gate red on day one teaches
# people to ignore red. The high-water mark may only go DOWN.
#
#   .\audit-cross-module-reach.ps1                     report + ratchet
#   .\audit-cross-module-reach.ps1 -ShowClassifierDiff also list every site the line rule reads differently
#   .\audit-cross-module-reach.ps1 -UpdateBaseline     lower the high-water mark (refuses to raise it)
#   .\audit-cross-module-reach.ps1 -SelfTest
# Exit 0 clean, 2 the ratchet rose, 3 could not evaluate.
# ---------------------------------------------------------------------------------------------------
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop
param(
  [switch]$UpdateBaseline,
  [switch]$ShowClassifierDiff,
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$runSelfTest = [bool]$SelfTest; $runUpdate = [bool]$UpdateBaseline

$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repo = Split-Path -Parent $here
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $repo 'lib\tree-walk.ps1')   # Get-TcPathBelowRoot: exclusions match below the root, so a worktree root is not excluded whole
. (Join-Path $repo 'lib\lf-write.ps1')    # Write-TcLfFile: the baseline is tracked and stored eol=lf

$BASELINE = Join-Path $here 'cross-module-reach-baseline.json'

# A module's INTERNALS. Reaching one of these from outside that module is the finding.
$script:INTERNALS = @{
  'grocery'   = @('grocery/out')
  'meal-prep' = @('meal-prep/db')
  'graph'     = @('graph/state', 'graph/learning')
  'sidecar'   = @('sidecar/out')
}
# PUBLISHED artefacts, named here so the reader can see they were considered and excluded on purpose.
$script:PUBLISHED = @('public/', 'content/', 'site/')

function Get-ModuleOfPath {
  param([string]$RelPath)
  if (-not $RelPath) { return '' }
  $p = $RelPath -replace '\\', '/'
  $p = $p -replace '^\./', ''
  $seg = ($p -split '/')[0]
  return $seg
}

function Test-IsCommentSite {
  param([string]$Line, [int]$MatchIndex)
  # THE LINE RULE, now the FALLBACK (2026-09-11): used only for a file the tokenizer could not read cleanly,
  # and printed beside the real count so the 133 -> 118 reclassification stays visible.
  # A site is a COMMENT site when a `#` opens before it on the line. It cannot see a block comment, and a
  # `#` inside a string earlier on the line fools it the other way; but it leans toward calling a site CODE,
  # which is the right direction for a fallback under a ratchet.
  if ($null -eq $Line) { return $false }
  $hash = $Line.IndexOf('#')
  if ($hash -lt 0) { return $false }
  return ($hash -lt $MatchIndex)
}

function Get-PsCommentExtents {
  # The extents of every COMMENT token in $Text, line and block alike, from the real PowerShell tokenizer.
  # Returns $null - meaning "use the line rule" - when the text does not parse cleanly or carries a bare CR.
  # A parse error can leave a block comment unterminated, which would make the rest of the file one comment
  # and understate the ratchet; a bare CR is a newline to the tokenizer and not to Get-ReachSites' split, so
  # every line number after it would be off by one. Both fall back rather than guess.
  # (Documented in line comments on purpose: lib\ps-source.ps1 records why a doc about comment delimiters
  # should not itself be a block comment.)
  param([string]$Text)
  if ($null -eq $Text) { return $null }
  if ($Text -match "`r(?!`n)") { return $null }
  $tok = $null; $err = $null
  try { [void][System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tok, [ref]$err) } catch { return $null }
  if ($null -eq $tok) { return $null }
  if ($null -ne $err -and $err.Length -gt 0) { return $null }
  $found = New-Object System.Collections.Generic.List[object]
  foreach ($t in $tok) {
    if ($t.Kind -eq [System.Management.Automation.Language.TokenKind]::Comment) { [void]$found.Add($t.Extent) }
  }
  return ,$found
}

function Test-IsInCommentExtent {
  # True when (Line, Column), both 1-based, falls inside one of $Comments. An extent's end column is exclusive.
  param($Comments, [int]$Line, [int]$Column)
  foreach ($x in $Comments) {
    if ($Line -lt $x.StartLineNumber -or $Line -gt $x.EndLineNumber) { continue }
    if ($Line -eq $x.StartLineNumber -and $Column -lt $x.StartColumnNumber) { continue }
    if ($Line -eq $x.EndLineNumber -and $Column -ge $x.EndColumnNumber) { continue }
    return $true
  }
  return $false
}

function Get-ReachSites {
  param([string]$Text, [string]$OwnModule)
  # Returns an array of @{ target=; module=; line=; comment=<bool>; line_comment=<bool>; classifier= } for every
  # internals path literal in $Text that belongs to a module OTHER than $OwnModule. `comment` is the tokenizer's
  # verdict (or the line rule's, when classifier is 'line'); `line_comment` is always the line rule's.
  $out = @()
  if (-not $Text) { return $out }
  $lines = $Text -split "`r?`n"
  $comments = $null; $tokenised = $false
  foreach ($owner in $script:INTERNALS.Keys) {
    if ($owner -eq $OwnModule) { continue }
    foreach ($int in $script:INTERNALS[$owner]) {
      # match either slash direction
      $pat = [regex]::Escape($int) -replace '/', '[\\/]'
      for ($i = 0; $i -lt $lines.Count; $i++) {
        foreach ($m in [regex]::Matches($lines[$i], $pat)) {
          # AN ENTRY POINT IS NOT A DATA REACH (2026-09-09). This audit exists to separate a module's
          # published contract from its internals, and a script's command line IS an interface: calling
          # `graph\learning\promote_aliases.py --recheck-holds` is using graph's front door, while
          # reading `graph\learning\promotion-holds.json` is reaching past it. Both spell the same
          # directory prefix, so only what FOLLOWS the prefix can tell them apart. Found when the
          # watchdog started invoking that script and this ratchet - correctly, by its old rule -
          # called it a new reach.
          $rest = $lines[$i].Substring($m.Index + $m.Length)
          $tail = [regex]::Match($rest, '^[\\/][A-Za-z0-9_.\-]+')
          if ($tail.Success -and $tail.Value -match '\.(ps1|py)$') { continue }
          # A QUOTED FIXTURE LITERAL IS NOT A DATA REACH (2026-09-09, queue 2026-09-09-a95022). Same shape
          # as the entry-point rule directly above, and the same reason the scan already refuses to read
          # this file: a fixture is FULL of the literals the detector hunts, and quoting a path is not
          # opening one. The 09-09 case: lib\git-blob-lib.ps1's frozen must-fire reproduces the pre-commit
          # hook's own stderr, 'BOM CHANGED grocery/out/json-readers-baseline.json', and the throwaway
          # repo in its clean twin is seeded with 'grocery/out/x.json'. Neither line reads grocery's
          # internals - one is a string the hook printed, the other a file inside a %TEMP% repo - and the
          # ratchet counted both as new coupling.
          #
          # OPT-IN, PER LINE, AND IT MUST CARRY A REASON. Not a file-type exemption: excusing every
          # test-*.ps1 would have dropped 20 sites in ops\test-precommit-hook.ps1 alone out of the
          # measurement, which is lowering the baseline by changing what is counted rather than by
          # removing coupling. Nothing in the tree carried this marker when it was added, so the 133
          # high-water mark it was measured against is untouched - it can only ever exclude a line an
          # author wrote it on, in a diff a reviewer reads.
          if ($lines[$i] -match 'reach-fixture-ok:\s*\S') { continue }
          # Tokenise once per file, and only a file that has a site to classify.
          if (-not $tokenised) { $comments = Get-PsCommentExtents -Text $Text; $tokenised = $true }
          $lineRule = Test-IsCommentSite -Line $lines[$i] -MatchIndex $m.Index
          $byToken = ($null -ne $comments)
          $isComment = if ($byToken) { Test-IsInCommentExtent -Comments $comments -Line ($i + 1) -Column ($m.Index + 1) } else { $lineRule }
          $out += @{ target = $int; module = $owner; line = ($i + 1); comment = $isComment
                     line_comment = $lineRule; classifier = $(if ($byToken) { 'token' } else { 'line' }) }
        }
      }
    }
  }
  return $out
}

function Get-ReachSourceFiles {
  <# Every first-party .ps1 the sweep reads under $RootDir, excluded on the path BELOW the root
     (lib\tree-walk.ps1). On the full path a root under .claude\worktrees\ excluded itself whole, and this
     ratchet exited 3 from every spawned session (2026-09-11). #>
  param([string]$RootDir)
  $rootFull = Get-TcRootFull $RootDir
  $exclude = '\\\.claude\\worktrees\\|\\grocery\\out\\|\\archive\\|\\node_modules\\'
  Get-TcTreeFiles -RootFull $rootFull -Filter '*.ps1' -PruneBelow $exclude |
    Where-Object { (Get-TcPathBelowRoot $_.FullName $rootFull) -notmatch $exclude }
}

# ---- self-test -------------------------------------------------------------------------------------
if ($runSelfTest) {
  $bad = 0
  function T([string]$n, [bool]$ok, [string]$got) {
    if ($ok) { Write-Output ("  ok    " + $n) } else { Write-Output ("  X     " + $n + "   got: " + $got); $script:bad++ }
  }

  # MUST FIRE - the founding shape: meal-prep reaching into grocery's working directory.
  $s1 = @(Get-ReachSites -Text '$b = Get-ChildItem "grocery/out/comparison-2026-09-08.json"' -OwnModule 'meal-prep')
  T 'MUST FIRE  a meal-prep read of grocery/out is a reach' ($s1.Count -eq 1 -and $s1[0].module -eq 'grocery' -and -not $s1[0].comment) ([string]$s1.Count)

  # MUST FIRE - the other slash direction, because this is Windows and both spellings are live.
  $s2 = @(Get-ReachSites -Text '$b = "grocery\out\price-table.json"' -OwnModule 'meal-prep')
  T 'MUST FIRE  a backslash spelling is the same reach' ($s2.Count -eq 1) ([string]$s2.Count)

  # MUST NOT FIRE - reading the PUBLISHED artefact is the contract working, not a finding.
  $s3 = @(Get-ReachSites -Text '$b = Get-Content "public/board.json"' -OwnModule 'meal-prep')
  T 'MUST NOT FIRE  reading the published board.json is not a reach' ($s3.Count -eq 0) ([string]$s3.Count)

  # MUST NOT FIRE - invoking another module's SCRIPT is using its front door, not reaching past it.
  $sE = @(Get-ReachSites -Text '$p = Join-Path $root ''graph\learning\promote_aliases.py''' -OwnModule 'grocery')
  T 'MUST NOT FIRE  invoking another module''s script is an ENTRY POINT, not a data reach' ($sE.Count -eq 0) ([string]$sE.Count)

  # ---- THE FIXTURE MARKER (2026-09-09, queue 2026-09-09-a95022) ------------------------------------
  # MUST FIRE first, so the marker is proved to be doing the work rather than the line being uncounted
  # anyway. This is the exact line lib\git-blob-lib.ps1's frozen must-fire carries.
  $sF0 = @(Get-ReachSites -Text '$f = ''grocery/out/json-readers-baseline.json''' -OwnModule 'lib')
  T 'MUST FIRE  an UNMARKED fixture literal is still counted (the marker, not the file, does the work)' ($sF0.Count -eq 1 -and -not $sF0[0].comment) ([string]$sF0.Count)
  # MUST NOT FIRE with the marker and a reason.
  $sF1 = @(Get-ReachSites -Text '$f = ''grocery/out/json-readers-baseline.json''   # reach-fixture-ok: frozen hook stderr, nothing here opens it' -OwnModule 'lib')
  T 'MUST NOT FIRE  a marked fixture literal with a reason is not a data reach' ($sF1.Count -eq 0) ([string]$sF1.Count)
  # A MARKER WITH NO REASON IS NOT AN EXEMPTION - the same rule stores.json allowed_subsets gets wrong.
  $sF2 = @(Get-ReachSites -Text '$f = ''grocery/out/json-readers-baseline.json''   # reach-fixture-ok:' -OwnModule 'lib')
  T 'MUST FIRE  a marker with no reason exempts nothing' ($sF2.Count -eq 1) ([string]$sF2.Count)
  # AND IT IS PER LINE. A marker on one line must not excuse the next, or one fixture silences a file.
  $sF3 = @(Get-ReachSites -Text (@(
      '$a = ''grocery/out/x.json''   # reach-fixture-ok: throwaway repo seed',
      '$b = ''grocery/out/comparison-2026-09-08.json''') -join "`n") -OwnModule 'lib')
  T 'MUST FIRE  the marker is per LINE - the unmarked line below it is still counted' ($sF3.Count -eq 1 -and $sF3[0].line -eq 2) ([string]$sF3.Count)

  # MUST FIRE - the same directory prefix, but a DATA file behind it, is still a reach. This is the
  # pair that proves the entry-point rule did not just switch the check off.
  $sD = @(Get-ReachSites -Text '$h = Get-Content ''graph\learning\promotion-holds.json''' -OwnModule 'grocery')
  T 'MUST FIRE  reading a DATA file under the same directory is still a reach' ($sD.Count -eq 1) ([string]$sD.Count)

  # MUST NOT FIRE - a module touching its OWN internals is not a cross-module reach.
  $s4 = @(Get-ReachSites -Text '$b = "grocery/out/comparison.json"' -OwnModule 'grocery')
  T 'MUST NOT FIRE  a module reading its own internals is not a reach' ($s4.Count -eq 0) ([string]$s4.Count)

  # The code/comment split, which is the whole improvement over the founding grep.
  $s5 = @(Get-ReachSites -Text '# historical note: this used to read grocery/out directly' -OwnModule 'meal-prep')
  T 'a comment mention is a COMMENT site, not a code site' ($s5.Count -eq 1 -and $s5[0].comment) ("count=$($s5.Count)")
  $s6 = @(Get-ReachSites -Text '$p = "grocery/out/x.json"   # reads the internals' -OwnModule 'meal-prep')
  T 'MUST FIRE  code before a trailing comment is still a CODE site' ($s6.Count -eq 1 -and -not $s6[0].comment) ("comment=$($s6[0].comment)")

  # SITES, not files. The founding grep -rl counted this file once; it is two reaches.
  $s7 = @(Get-ReachSites -Text "`$a = 'grocery/out/one.json'`n`$b = 'grocery/out/two.json'" -OwnModule 'meal-prep')
  T 'two reaches on two lines count as two SITES, not one file' ($s7.Count -eq 2) ([string]$s7.Count)

  # MUST FIRE - the reach runs both directions, which is the half RUNTIME-MAP.md did not say.
  $s8 = @(Get-ReachSites -Text '$db = "meal-prep/db/recipes.json"' -OwnModule 'grocery')
  T 'MUST FIRE  grocery reaching into meal-prep/db is a reach too' ($s8.Count -eq 1 -and $s8[0].module -eq 'meal-prep') ([string]$s8.Count)

  T 'the module of a path is its first segment' ((Get-ModuleOfPath 'meal-prep\pipeline\x.ps1') -eq 'meal-prep') (Get-ModuleOfPath 'meal-prep\pipeline\x.ps1')
  T 'a leading ./ does not become the module' ((Get-ModuleOfPath './ops/x.ps1') -eq 'ops') (Get-ModuleOfPath './ops/x.ps1')

  # MUST NOT FIRE - an unrelated script with no cross-module path is silent. This asserts an ABSENCE,
  # so it is a negative assertion and NOT a clean twin, whatever it feels like.
  $s9 = @(Get-ReachSites -Text '$x = 1; Write-Output "hello"' -OwnModule 'meal-prep')
  T 'MUST NOT FIRE  a script with no cross-module path yields nothing' ($s9.Count -eq 0) ([string]$s9.Count)

  # CLEAN TWIN - the adjacent behaviour most likely to have broken while adding the comment split:
  # a code site and a comment site on the SAME line pair must still both be found and classified.
  $s10 = @(Get-ReachSites -Text "`$p = 'grocery/out/a.json'`n# and grocery/out/b.json is the old one" -OwnModule 'meal-prep')
  T 'CLEAN TWIN  code and comment sites are both still found, and split correctly' ($s10.Count -eq 2 -and @($s10 | Where-Object { -not $_.comment }).Count -eq 1) ([string]$s10.Count)

  # ---- BLOCK COMMENTS ARE THE TOKENIZER'S (2026-09-11) --------------------------------------------
  # The delimiters are BUILT, never written into a string here: lib\ps-source.ps1's regex reducer, which
  # run-gates' discovery and other scanners use, reads a comment opener inside a quoted string as a real one
  # and would swallow this file's code up to the next closer.
  $bo = '<' + '#'
  $bc = '#' + '>'
  # MUST NOT FIRE - the founding shape: a block header whose second line names grocery's ads file in prose.
  # The line rule scored it CODE, and ops\audit-glued-keyword.ps1's header moved the ratchet 133 -> 134.
  $bkText = @($bo, '  writing grocery\out\ads-<today>.json beside the tracked ads files', $bc, '$x = 1') -join "`n"
  $bk = @(Get-ReachSites -Text $bkText -OwnModule 'ops')
  T 'MUST NOT FIRE  a path inside a block comment is not a CODE site' ($bk.Count -eq 1 -and $bk[0].comment -and $bk[0].classifier -eq 'token') ("count=$($bk.Count) comment=$($bk[0].comment) by=$($bk[0].classifier)")
  # ...and the line rule alone still misreads it, so the case above proves the tokenizer did the work.
  T 'the line rule on its own still calls that block-comment line CODE (the misread this change retires)' ($bk.Count -eq 1 -and -not $bk[0].line_comment) ("line_comment=$($bk[0].line_comment)")

  # MUST FIRE - a real code literal still counts: right after a closed block, and on the same line as one.
  $afterText = @($bo, '  header prose that names nothing', $bc, '$p = ''grocery/out/x.json''') -join "`n"
  $after = @(Get-ReachSites -Text $afterText -OwnModule 'ops')
  T 'MUST FIRE  a code literal on the line after a closed block comment is a CODE site' ($after.Count -eq 1 -and -not $after[0].comment -and $after[0].line -eq 4) ("count=$($after.Count) comment=$($after[0].comment)")
  $inlineText = $bo + ' grocery/out is prose here ' + $bc + ' $p = ''grocery/out/x.json'''
  $inline = @(Get-ReachSites -Text $inlineText -OwnModule 'ops')
  T 'MUST FIRE  on one line, the path after the closer is CODE and the one inside is COMMENT' ($inline.Count -eq 2 -and @($inline | Where-Object { -not $_.comment }).Count -eq 1) ("count=$($inline.Count)")
  # MUST FIRE - an extent's end column is EXCLUSIVE. A path starting on the very next column after the closer is
  # code; a mutation probe that made the end inclusive survived every case above until this one was added.
  $flushText = $bo + ' x ' + $bc + 'grocery/out/x.json'
  $flush = @(Get-ReachSites -Text $flushText -OwnModule 'ops')
  T 'MUST FIRE  a path starting on the column right after the closer is CODE (the end column is exclusive)' ($flush.Count -eq 1 -and -not $flush[0].comment -and $flush[0].classifier -eq 'token') ("count=$($flush.Count) comment=$($flush[0].comment) by=$($flush[0].classifier)")

  # MUST FIRE - a `#` inside a string earlier on the line no longer hides a real reach. The line rule
  # called this a comment, the direction its header promised it never erred in.
  $hs = @(Get-ReachSites -Text '$u = ''a#b''; $p = ''grocery/out/x.json''' -OwnModule 'ops')
  T 'MUST FIRE  a hash inside an earlier string does not make a real reach a comment' ($hs.Count -eq 1 -and -not $hs[0].comment -and $hs[0].line_comment) ("comment=$($hs[0].comment) line_comment=$($hs[0].line_comment)")

  # MUST FIRE - text that does not parse falls back to the line rule, so an unclosed block comment cannot
  # turn every reach below it into prose. The opener line is ASSIGNED first: inside @( ) the comma binds tighter
  # than +, so `@($bo + ' never closed', $next)` is $bo plus a two-element array, one line, and the first cut of
  # this case ran on that fragment and went red for the fixture's reason, not the code's.
  $openLine = $bo + ' never closed'
  $openText = @($openLine, '$p = ''grocery/out/x.json''') -join "`n"
  $open = @(Get-ReachSites -Text $openText -OwnModule 'ops')
  T 'MUST FIRE  an unclosed block comment falls back to the line rule and still counts the reach below it' ($open.Count -eq 1 -and -not $open[0].comment -and $open[0].classifier -eq 'line') ("count=$($open.Count) comment=$($open[0].comment) by=$($open[0].classifier)")
  # MUST FIRE - a bare CR is a newline to the tokenizer and not to the line split, so every line number after it
  # would disagree; such text goes to the line rule rather than to a token looked up on the wrong line.
  $crText = '$z = 1' + "`r" + '$p = ''grocery/out/x.json'''
  $cr = @(Get-ReachSites -Text $crText -OwnModule 'ops')
  T 'MUST FIRE  text with a bare CR is classified by the line rule, never by mis-numbered tokens' ($cr.Count -eq 1 -and $cr[0].classifier -eq 'line') ("count=$($cr.Count) by=$($cr[0].classifier)")

  # CLEAN TWIN - a path inside a HERE-STRING is still a CODE site. It is the neighbour a reducer that went
  # one token kind too far would silently drop, and the 2026-09-11 decision is that it stays counted.
  $hereText = @('$body = @''', 'grocery/out/x.json', '''@') -join "`n"
  $here1 = @(Get-ReachSites -Text $hereText -OwnModule 'ops')
  T 'CLEAN TWIN  a path inside a here-string is still counted as a CODE site' ($here1.Count -eq 1 -and -not $here1[0].comment -and $here1[0].classifier -eq 'token') ("count=$($here1.Count) comment=$($here1[0].comment) by=$($here1[0].classifier)")

  # THE WALK, FROM A WORKTREE ROOT (2026-09-11, lib\tree-walk.ps1). Matched on the FULL path, every file under
  # .claude\worktrees\<name> was excluded and this ratchet exited 3 from every spawned session.
  $wtFx = New-TcWorktreeFixture -Files @{ 'ops\a.ps1' = 'Write-Output 1'; 'meal-prep\b.ps1' = 'Write-Output 2' }
  try {
    $wtFound = @(Get-ReachSourceFiles -RootDir $wtFx.Root)
    $wtHits = Measure-TcWorktreeFixture -Fixture $wtFx -Found $wtFound
    T 'MUST FIRE  a root that IS a worktree is scanned, not excluded whole' ($wtHits.Root -eq 2) ("root=" + $wtHits.Root)
    T 'MUST NOT FIRE  a sibling worktree BELOW that root is still excluded' ($wtHits.Sibling -eq 0) ("sibling=" + $wtHits.Sibling)
  } finally { Remove-Item -LiteralPath $wtFx.Temp -Recurse -Force -ErrorAction SilentlyContinue }

  if ($bad -gt 0) { Write-Output ("cross-module-reach SELF-TEST FAIL ({0})" -f $bad); exit 2 }
  Write-Output 'cross-module-reach SELF-TEST PASS'
  Exit-Guard -Name 'cross-module-reach' -Summary 'selftest pass' -Code 0
}

# ---- sweep -----------------------------------------------------------------------------------------
$files = @(Get-ReachSourceFiles -RootDir $repo)
# `archive\` is excluded on purpose: retired code is not a live dependency, and counting it would let a
# ratchet rise because somebody filed something away. Everything else is in scope, TEST scripts included -
# a test that builds a path into another module's internals still breaks when that directory moves.
if (-not $files.Count) { Write-Output 'cross-module-reach: no .ps1 files found - discovery is broken, not clean.'; exit 3 }

$codeSites = 0; $commentSites = 0; $lineRuleCode = 0
$byPair = @{}
$fileHits = @{}
$filesBy = @{ token = 0; line = 0 }
$reclassified = New-Object System.Collections.Generic.List[string]
foreach ($f in $files) {
  $rel = $f.FullName.Substring($repo.Length).TrimStart('\','/')
  $own = Get-ModuleOfPath $rel
  if (-not $script:INTERNALS.ContainsKey($own) -and $own -ne 'ops' -and $own -ne 'lib') { continue }
  # A detector must never scan itself: its own fixtures are full of the literals it hunts.
  if ($rel -replace '\\','/' -eq 'ops/audit-cross-module-reach.ps1') { continue }
  $text = [IO.File]::ReadAllText($f.FullName)
  $sites = @(Get-ReachSites -Text $text -OwnModule $own)
  if ($sites.Count -gt 0) { $filesBy[$sites[0].classifier]++ }
  foreach ($s in $sites) {
    if (-not $s.line_comment) { $lineRuleCode++ }
    if ($s.comment -ne $s.line_comment) {
      [void]$reclassified.Add(("{0}:{1}  {2} by the tokenizer, {3} by the line rule" -f $rel, $s.line,
        $(if ($s.comment) { 'comment' } else { 'code' }), $(if ($s.line_comment) { 'comment' } else { 'code' })))
    }
    if ($s.comment) { $commentSites++ } else {
      $codeSites++
      $k = "$own -> $($s.module)"
      if (-not $byPair.ContainsKey($k)) { $byPair[$k] = 0 }
      $byPair[$k]++
      if (-not $fileHits.ContainsKey($rel)) { $fileHits[$rel] = 0 }
      $fileHits[$rel]++
    }
  }
}

Write-Output ("cross-module-reach: scanned {0} first-party .ps1 file(s); {1} carry a site, classified by the tokenizer in {2} and by the line-rule fallback in {3}" -f $files.Count, ($filesBy.token + $filesBy.line), $filesBy.token, $filesBy.line)
Write-Output ("  code sites    {0}   (in {1} file(s))" -f $codeSites, $fileHits.Count)
Write-Output ("  comment sites {0}   (not ratcheted - a comment naming a path is documentation)" -f $commentSites)
Write-Output ("  the line rule alone would read {0} code site(s); {1} site(s) are classified differently (-ShowClassifierDiff lists them)" -f $lineRuleCode, $reclassified.Count)
foreach ($k in ($byPair.Keys | Sort-Object { -$byPair[$_] })) {
  Write-Output ("    {0,-26} {1}" -f $k, $byPair[$k])
}
Write-Output '  top files:'
foreach ($k in (@($fileHits.Keys | Sort-Object { -$fileHits[$_] }) | Select-Object -First 8)) {
  Write-Output ("    {0,-58} {1}" -f $k, $fileHits[$k])
}
if ($ShowClassifierDiff) {
  Write-Output '  classified differently from the line rule:'
  foreach ($r in $reclassified) { Write-Output ('    ' + $r) }
}

if ($runUpdate) {
  $prev = if (Test-Path $BASELINE) { (Get-Content $BASELINE -Raw | ConvertFrom-Json).code_sites } else { [int]::MaxValue }
  if ($codeSites -gt $prev) {
    Write-Output ("cross-module-reach: REFUSING to raise the high-water mark from {0} to {1}. A ratchet may only go DOWN." -f $prev, $codeSites)
    exit 2
  }
  $obj = [pscustomobject]@{
    code_sites = $codeSites
    recorded   = (Get-Date -Format 'yyyy-MM-dd')
    note       = 'HIGH-WATER MARK, MAY ONLY GO DOWN. Cross-module reaches into another module internals directory, counted as SITES in code (comments excluded). Backlog I90.'
  }
  # LF and no BOM, the bytes the committed blob carries, not the CRLF ConvertTo-Json writes under PS 5.1.
  $null = Write-TcLfFile -Path $BASELINE -Text ($obj | ConvertTo-Json) -NoBom
  Write-Output ("cross-module-reach: baseline set to {0}" -f $codeSites)
  Exit-Guard -Name 'cross-module-reach' -Summary ("baseline={0}" -f $codeSites) -Code 0
}

if (-not (Test-Path $BASELINE)) {
  Write-Output 'cross-module-reach: no baseline recorded. Run -UpdateBaseline once to set the high-water mark.'
  exit 3
}
$base = [int]((Get-Content $BASELINE -Raw | ConvertFrom-Json).code_sites)
if ($codeSites -gt $base) {
  Write-Output ("cross-module-reach: RATCHET ROSE. baseline {0}, now {1}. A new cross-module reach was added." -f $base, $codeSites)
  Write-Output '  Read the published artefact (public/board.json) instead, or lower the baseline deliberately with a reason.'
  Exit-Guard -Name 'cross-module-reach' -Summary ("ROSE base={0} now={1}" -f $base, $codeSites) -Code 2
}
if ($codeSites -lt $base) {
  Write-Output ("cross-module-reach: below the high-water mark ({0} < {1}). Lower it with -UpdateBaseline." -f $codeSites, $base)
}
Exit-Guard -Name 'cross-module-reach' -Summary ("code={0} comment={1} base={2}" -f $codeSites, $commentSites, $base) -Code 0
