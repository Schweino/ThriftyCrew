<#
  audit-memory-citations.ps1 - every `[[memory]]` cited in this estate resolves to a real file.

  WHY THIS EXISTS (2026-09-06, backlog E13). The course's rule is "pass REFERENCES, not copies": a
  model can read far more than it can write, so a delegating agent physically cannot restate a large
  memory as a task description, and asking it to try produces paraphrase - the one failure a reference
  makes structurally impossible.

  This estate had the reference half and not the resolver. A spawned agent receives `MEMORY.md`, an
  index of ~130 facts, each a title plus a RELATIVE filename plus a one-line hook. It receives no
  CLAUDE.md at any level, and until today not one of the twelve agent definitions said WHERE those
  filenames live. So the pointers were real, unresolvable, and the only thing an agent could act on was
  the hook - which is the paraphrase, arriving by a longer road.

  A DANGLING REFERENCE IS WORSE THAN NO REFERENCE, and that is what this gate is for. A citation that
  does not resolve reads as authority: the reader believes there is a considered account behind the
  line, cannot reach it, and proceeds on the summary with more confidence than if nothing had been
  cited at all. Renaming or consolidating a memory is routine here - the index has been pruned by hand
  at least once - and nothing pointed at the citations that went stale with it.

  CHECKS TWO THINGS:
    1. every `[[name]]` in .claude/agents, .claude/rules and design resolves to a memory file
    2. every agent definition carries the resolver block, so the citations can actually be opened

  EXIT CODES (lib\guard-contract.ps1 vocabulary): 0 clean, 2 hard finding, 3 could-not-evaluate.
  Read the verdict LINE, not the number (backlog E2).

  Self-test: powershell -File ops\audit-memory-citations.ps1 -SelfTest
#>
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\ops' }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')

# The store for THIS project. C--Codex and C--Codex-income are different projects with their own
# stores and nothing in them applies here, so this is deliberately not a wildcard.
$MEM = Join-Path $env:USERPROFILE '.claude\projects\C--Codex-ThriftyCrew\memory'
$SCAN = @('.claude\agents', '.claude\rules', 'design')
$RESOLVER_MARK = 'The memory index is a set of POINTERS'

function Get-TcCitations {
  <# Pure. Every [[name]] in a body of text, deduplicated. Citations are lower-case kebab filenames;
     anything else in double brackets is not one and is left alone. #>
  param([string]$Text)
  # A BACKTICKED `[[x]]` IS SYNTAX BEING SHOWN, NOT A REFERENCE BEING MADE. The resolver block added to
  # all twelve agents explains the citation format using `[[double-bracket]]` as its example, and the
  # first live run duly reported "double-bracket" as a dangling memory in all twelve - the detector
  # flagging the very documentation that makes citations resolvable. Same shape as the
  # deliberately-absent exemption in ops\audit-agent-tools.ps1: prose ABOUT a thing is not a claim to it.
  $t = [regex]::Replace([string]$Text, '`[^`]*`', ' ')
  $out = @()
  foreach ($m in [regex]::Matches($t, '\[\[([a-z0-9][a-z0-9-]*)\]\]')) { $out += $m.Groups[1].Value }
  return ,@($out | Sort-Object -Unique)
}

function Get-TcDanglingCitations {
  <# Which cited names have no file. $Known is the set of memory basenames (no .md). #>
  param([string[]]$Cited, [string[]]$Known)
  $have = @{}
  foreach ($k in @($Known)) { if ($k) { $have[$k] = $true } }
  $bad = @()
  foreach ($c in @($Cited)) { if (-not $have.ContainsKey($c)) { $bad += $c } }
  return ,@($bad)
}

# ------------------------------------------------------------------------------------- self-test
if ($SelfTest) {
  $f = 0
  function T($m, $cond, $got) { if ($cond) { Write-Output ("ok    " + $m) } else { Write-Output ("FAIL  " + $m + "   got: " + $got); $script:f++ } }

  $c1 = Get-TcCitations -Text 'see [[propagate-has-no-slugs]] and also [[ps-json-array-collapse]].'
  T 'both citations are extracted' (@($c1).Count -eq 2) (($c1) -join ',')
  $c2 = Get-TcCitations -Text 'the same one twice: [[a-b]] and [[a-b]]'
  T 'a repeated citation counts once' (@($c2).Count -eq 1) (($c2) -join ',')
  $c3 = Get-TcCitations -Text 'a markdown table [[ ]] and [[Not A Memory]] are not citations'
  T 'CLEAN TWIN non-kebab double brackets are not citations' (@($c3).Count -eq 0) (($c3) -join ',')
  # The case that made the first live run report twelve false danglers.
  $c5 = Get-TcCitations -Text 'the format is `[[double-bracket]]`, as in [[a-real-one]].'
  T 'CLEAN TWIN a BACKTICKED citation is syntax being shown, not a reference being made' `
    (@($c5).Count -eq 1 -and $c5[0] -eq 'a-real-one') (($c5) -join ',')
  $c4 = Get-TcCitations -Text 'no citations here at all'
  T 'CLEAN TWIN text with none yields none' (@($c4).Count -eq 0) (($c4) -join ',')

  $d1 = Get-TcDanglingCitations -Cited @('real-one', 'ghost-one') -Known @('real-one', 'other')
  T 'MUST FIRE  a citation with no memory file is DANGLING' (@($d1).Count -eq 1 -and $d1[0] -eq 'ghost-one') (($d1) -join ',')
  $d2 = Get-TcDanglingCitations -Cited @('real-one') -Known @('real-one', 'other')
  T 'CLEAN TWIN a citation that resolves raises nothing' (@($d2).Count -eq 0) (($d2) -join ',')
  $d3 = Get-TcDanglingCitations -Cited @() -Known @('a')
  T 'CLEAN TWIN citing nothing raises nothing' (@($d3).Count -eq 0) (($d3) -join ',')
  # THE FAILURE THIS GATE IS ACTUALLY FOR: the store cannot be read, so EVERY citation looks dangling.
  # That must never be reported as 200 findings - it is one blind run, and the live path exits 3.
  $d4 = Get-TcDanglingCitations -Cited @('a', 'b', 'c') -Known @()
  T 'MUST FIRE  an EMPTY known-set makes every citation dangle, which the live run must treat as BLIND' (@($d4).Count -eq 3) (($d4) -join ',')
  T 'MUST FIRE  a single dangling citation comes back as an ARRAY, not unrolled' ($d1 -is [array]) ($d1.GetType().FullName)

  if ($f) { Write-Output ("SELF-TEST FAIL: {0} check(s)" -f $f); exit 1 }
  Write-Output 'SELF-TEST PASS: citation extraction with three clean twins, dangling detection, the empty-store blindness case, and return arity'
  exit 0
}

# ------------------------------------------------------------------------------------- live run
if (-not (Test-Path -LiteralPath $MEM)) {
  Write-Output ("MEMORY-CITATIONS AUDIT BLIND: the memory store is missing ({0}). Every citation would look dangling, which is a broken read and not 200 findings." -f $MEM)
  Write-GuardComplete -Name 'memory-citations' -Summary 'blind=no-store'
  exit 3
}
$known = @(Get-ChildItem $MEM -Filter *.md -File -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -ne 'MEMORY.md' } | ForEach-Object { $_.BaseName })
if (-not $known.Count) {
  Write-Output 'MEMORY-CITATIONS AUDIT BLIND: the memory store holds zero files. Unknown is not a finding and it is not a pass.'
  Write-GuardComplete -Name 'memory-citations' -Summary 'blind=empty-store'
  exit 3
}

$problems = @(); $files = 0; $cites = 0
foreach ($rel in $SCAN) {
  $dir = Join-Path $repo $rel
  if (-not (Test-Path -LiteralPath $dir)) { continue }
  foreach ($fl in @(Get-ChildItem $dir -Filter *.md -File -Recurse -ErrorAction SilentlyContinue)) {
    $files++
    $txt = [IO.File]::ReadAllText($fl.FullName)
    $cited = Get-TcCitations -Text $txt
    $cites += @($cited).Count
    $bad = Get-TcDanglingCitations -Cited $cited -Known $known
    foreach ($b in @($bad)) {
      $problems += [pscustomobject]@{ File = $fl.FullName.Replace($repo, '').TrimStart('\'); Kind = 'dangling-citation'; Detail = $b }
    }
  }
}
# The resolver block: without it the citations above are unopenable, which is the defect E13 names.
foreach ($fl in @(Get-ChildItem (Join-Path $repo '.claude\agents') -Filter *.md -File -ErrorAction SilentlyContinue)) {
  if ([IO.File]::ReadAllText($fl.FullName) -notmatch [regex]::Escape($RESOLVER_MARK)) {
    $problems += [pscustomobject]@{ File = ('.claude\agents\' + $fl.Name); Kind = 'no-resolver-block'
                                    Detail = 'this agent receives the memory index but is never told where the files are, so it can only act on the one-line hook' }
  }
}
$problems = @($problems)

if ($problems.Count) {
  Write-Output ("MEMORY-CITATIONS AUDIT FAILED: {0} problem(s). A citation that does not resolve reads as authority - the reader believes an account exists, cannot reach it, and proceeds on the summary with MORE confidence than if nothing had been cited." -f $problems.Count)
  foreach ($p in $problems) { Write-Output ("  {0,-46} {1,-20} {2}" -f $p.File, $p.Kind, $p.Detail) }
  Write-GuardComplete -Name 'memory-citations' -Summary ("problems={0}" -f $problems.Count)
  exit 2
}
Write-Output ("memory-citations: PASSED - {0} citation(s) across {1} file(s) all resolve against {2} memories, and every agent carries the resolver block." -f $cites, $files, $known.Count)
Write-GuardComplete -Name 'memory-citations' -Summary ("cites={0} memories={1}" -f $cites, $known.Count)
exit 0
