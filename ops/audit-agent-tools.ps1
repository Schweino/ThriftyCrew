<#
  audit-agent-tools.ps1 - every agent declares its tools, and what a definition SAYS about its tools
  matches what it HAS.

  WHY THIS EXISTS (2026-09-06, backlog E3). Course 6's finding: handed three well-named tools and no
  usage context, an agent decided the unnecessary one must be needed and INVENTED work to justify it.
  The fix was a block per agent naming which tools are situational - and a block like that is prose
  about a frontmatter line, so it is a drift surface. E3 is a defect about a description not matching
  reality; doing the check by eye would reproduce it one level up.

  TWO RULES, and the first is the one that stops a regression nobody would notice:

    1. EVERY AGENT DECLARES A `tools:` LINE. Four of the twelve declared none until 2026-09-06 and so
       inherited EVERY tool - including Write and Edit on two agents whose whole job is to render a
       verdict. An agent with no tools: line does not look wrong in a diff; it looks like a file that
       simply does not mention tools.
    2. A TOOL NAMED IN A CAPABILITY BLOCK MUST BE DECLARED - unless the line marks it ABSENT. Saying
       "`Edit` is deliberately absent" is the most useful sentence such a block can carry, so the rule
       has to admit it rather than punish it. Lines carrying an absence marker are exempt; every other
       named tool must exist in the frontmatter.

  EXIT CODES (lib\guard-contract.ps1 vocabulary): 0 clean, 2 hard finding, 3 could-not-evaluate.
  Read the verdict LINE, not the number (backlog E2).

  Self-test: powershell -File ops\audit-agent-tools.ps1 -SelfTest
#>
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\ops' }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')

$AGENT_DIR = Join-Path $repo '.claude\agents'
$KNOWN = @('Read', 'Grep', 'Glob', 'Bash', 'PowerShell', 'Edit', 'Write', 'WebFetch', 'WebSearch', 'Task', 'NotebookEdit')

# A line saying a tool is NOT there is documentation, not a claim to have it. Without this exemption the
# rule punishes the single most useful sentence one of these blocks can carry.
$ABSENT_MARKERS = @('deliberately absent', 'is missing', 'are missing', 'that is missing',
                    'do not have', 'does not have', 'cannot', 'inherited', 'before that',
                    'no longer', 'not there', 'without')

function Get-TcDeclaredTools {
  param([string[]]$Lines)
  $fm = @($Lines | Where-Object { $_ -match '^tools:\s' } | Select-Object -First 1)
  if (-not $fm.Count) { return ,@() }
  return ,@(($fm[0] -replace '^tools:\s*', '') -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Get-TcNamedTools {
  <# Tools a capability block CLAIMS, which is not every tool it mentions. Counted only inside a
     markdown table cell or backticks - the two places these blocks actually name a capability - and
     never on a line that marks the tool absent. #>
  param([string[]]$BlockLines, [string[]]$Known, [string[]]$AbsentMarkers)
  $named = @()
  $lines = @($BlockLines)
  for ($n = 0; $n -lt $lines.Count; $n++) {
    $line = $lines[$n]
    # THE EXEMPTION IS TESTED OVER A WINDOW, NOT ONE LINE, because prose wraps and the marker does not
    # move with it. "...named none and inherited `Write`," ended one line and "`Edit`, `Bash` and
    # `PowerShell`" began the next, so a per-line test exempted the first name and flagged the other
    # three. Table rows are self-contained and are matched on their own line either way; only prose
    # needs the look-back.
    $isTableRow = ($line -match '^\s*\|')
    $window = $line
    if (-not $isTableRow) {
      $lo = [Math]::Max(0, $n - 2)
      $window = ($lines[$lo..$n] | Where-Object { $_ -notmatch '^\s*\|' }) -join ' '
    }
    $l = $window.ToLower()
    $isAbsence = $false
    foreach ($m in $AbsentMarkers) { if ($l -match [regex]::Escape($m)) { $isAbsence = $true; break } }
    if ($isAbsence) { continue }
    foreach ($k in $Known) {
      # -cmatch: PowerShell's -match is CASE-INSENSITIVE, so "can write" and "do not edit" would both
      # score as tool names. Tool names are capitalised; the verbs are not.
      if ($line -cmatch ('(?m)^\|[^|]*\b' + [regex]::Escape($k) + '\b') -or
          $line -cmatch ('`[^`]*\b' + [regex]::Escape($k) + '\b[^`]*`')) { $named += $k }
    }
  }
  return ,@($named | Sort-Object -Unique)
}

function Get-TcFrontmatterValue {
  param([string[]]$Lines, [string]$Key)
  $hit = @($Lines | Where-Object { $_ -match ('^' + [regex]::Escape($Key) + ':\s') } | Select-Object -First 1)
  if (-not $hit.Count) { return '' }
  return ($hit[0] -replace ('^' + [regex]::Escape($Key) + ':\s*'), '').Trim()
}

function Get-TcAgentProblems {
  param([string]$Name, [string[]]$Lines, [string[]]$Known, [string[]]$AbsentMarkers)
  $p = @()

  # MATE's M and E, made non-silent (2026-09-06, backlog E9). Model choice is the highest-leverage
  # per-call decision available, and in this estate it is made in exactly one place: the frontmatter.
  # meal-prep\pipeline\hunt_dispatch.py routes every judgment call through `claude -p --agent <name>`
  # SPECIFICALLY so the CLI reads this file and the adapter cannot disagree with it - "two readers of
  # one authority is how the estate's forked-taxonomy defects start" - and it then CHECKS that the
  # model which actually ran is the model pinned here.
  #
  # All of which rests on the pin EXISTING. An agent with no `model:` line does not fail; it silently
  # runs on whatever the calling session happens to be, so a mechanical stage could quietly cost Opus
  # rates forever and the only symptom is the bill. Same shape as the missing tools: line above: it
  # does not look wrong in a diff, it looks like a file that does not mention models.
  foreach ($k in @('model', 'effort')) {
    if (-not (Get-TcFrontmatterValue -Lines $Lines -Key $k)) {
      $p += [pscustomobject]@{ Agent = $Name; Kind = ('no-' + $k + '-pin')
                               Detail = ('declares no ' + $k + ': line, so it silently inherits the calling session''s ' + $k) }
    }
  }

  $declared = Get-TcDeclaredTools -Lines $Lines
  if (-not @($declared).Count) {
    $p += [pscustomobject]@{ Agent = $Name; Kind = 'no-tools-line'
                             Detail = 'declares no tools: line, so it inherits EVERY tool including Write and Edit' }
    return ,@($p)
  }
  $i = -1
  for ($n = 0; $n -lt $Lines.Count; $n++) { if ($Lines[$n] -match 'tool list is not a checklist') { $i = $n; break } }
  if ($i -lt 0) { return ,@($p) }        # no capability block is legal; nothing to cross-check
  $block = $Lines[$i..($Lines.Count - 1)]
  # ASSIGN, THEN ITERATE. `foreach ($t in @(Get-TcNamedTools ...))` binds $t to the WHOLE comma-wrapped
  # array on the first pass, so every agent reported "the block claims Glob Grep Read" as one name.
  # Fourth instance of this trap in one session; the rule is never to wrap a function call inline.
  $namedTools = Get-TcNamedTools -BlockLines $block -Known $Known -AbsentMarkers $AbsentMarkers
  foreach ($t in @($namedTools)) {
    $hit = @($declared | Where-Object { $_ -eq $t -or $_.StartsWith($t) })
    if (-not $hit.Count) {
      $p += [pscustomobject]@{ Agent = $Name; Kind = 'names-undeclared-tool'
                               Detail = ("the block claims " + $t + ", which is not in its tools: line") }
    }
  }
  return ,@($p)
}

# ------------------------------------------------------------------------------------- self-test
if ($SelfTest) {
  $f = 0
  function T($m, $cond, $got) { if ($cond) { Write-Output ("ok    " + $m) } else { Write-Output ("FAIL  " + $m + "   got: " + $got); $script:f++ } }

  $K = $KNOWN; $A = $ABSENT_MARKERS

  # MUST FIRE 1 - the founding defect: four agents declared no tools line at all.
  $r1 = Get-TcAgentProblems -Name 'x' -Lines @('---', 'name: x', 'model: fable', 'effort: high', '---', 'body') -Known $K -AbsentMarkers $A
  T 'MUST FIRE  an agent with NO tools: line is a finding' (@($r1).Count -eq 1 -and $r1[0].Kind -eq 'no-tools-line') (($r1 | ForEach-Object { $_.Kind }) -join ',')

  # MATE's M and E. A missing pin costs money silently and looks like a file that does not mention models.
  $m1 = Get-TcAgentProblems -Name 'x' -Lines @('---', 'name: x', 'effort: high', 'tools: Read', '---') -Known $K -AbsentMarkers $A
  T 'MUST FIRE  an agent with NO model: pin silently inherits the session model' `
    (@($m1 | Where-Object { $_.Kind -eq 'no-model-pin' }).Count -eq 1) (($m1 | ForEach-Object { $_.Kind }) -join ',')
  $m2 = Get-TcAgentProblems -Name 'x' -Lines @('---', 'name: x', 'model: fable', 'tools: Read', '---') -Known $K -AbsentMarkers $A
  T 'MUST FIRE  an agent with NO effort: pin is a finding too' `
    (@($m2 | Where-Object { $_.Kind -eq 'no-effort-pin' }).Count -eq 1) (($m2 | ForEach-Object { $_.Kind }) -join ',')
  $m3 = Get-TcAgentProblems -Name 'x' -Lines @('---', 'name: x', 'model: fable', 'effort: medium', 'tools: Read', '---') -Known $K -AbsentMarkers $A
  T 'CLEAN TWIN both pins present raises nothing' (@($m3).Count -eq 0) (($m3 | ForEach-Object { $_.Kind }) -join ',')

  # MUST FIRE 2 - the drift E3 is actually about.
  $r2 = Get-TcAgentProblems -Name 'x' -Known $K -AbsentMarkers $A -Lines @(
    '---', 'model: fable', 'effort: medium', 'tools: Read, Grep', '---', '## Your tool list is not a checklist', '| Tool | Standing |', '| `Read` | spine |', '| `WebSearch` | situational |')
  T 'MUST FIRE  a block claiming a tool the agent does NOT declare is a finding' `
    (@($r2).Count -eq 1 -and $r2[0].Detail -like '*WebSearch*') (($r2 | ForEach-Object { $_.Detail }) -join ' | ')

  # CLEAN TWIN - THE ONE THAT MADE THIS FILE NECESSARY. Saying a tool is deliberately absent is the most
  # useful line such a block carries, and the first version of this check failed three agents over it.
  $r3 = Get-TcAgentProblems -Name 'x' -Known $K -AbsentMarkers $A -Lines @(
    '---', 'model: fable', 'effort: medium', 'tools: Read, Grep', '---', '## Your tool list is not a checklist', '| `Read` | spine |',
    '`Edit` is deliberately absent and that is the point of this list.')
  T 'CLEAN TWIN naming a tool to say it is DELIBERATELY ABSENT is documentation, not a claim' `
    (@($r3).Count -eq 0) (($r3 | ForEach-Object { $_.Detail }) -join ' | ')

  # CLEAN TWIN - prose verbs are not tool names. -match would score all three of these.
  $r4 = Get-TcAgentProblems -Name 'x' -Known $K -AbsentMarkers $A -Lines @(
    '---', 'model: fable', 'effort: medium', 'tools: Read', '---', '## Your tool list is not a checklist', '| `Read` | spine |',
    'You can write nothing, do not edit the catalog, and re-read the task.')
  T 'CLEAN TWIN lower-case verbs (write, edit, task) are not tool names' (@($r4).Count -eq 0) (($r4 | ForEach-Object { $_.Detail }) -join ' | ')

  # CLEAN TWIN - an agent with a tools line and no capability block is legal.
  $r5 = Get-TcAgentProblems -Name 'x' -Known $K -AbsentMarkers $A -Lines @('---', 'model: fable', 'effort: medium', 'tools: Read, Grep', '---', 'body with no block')
  T 'CLEAN TWIN a declared agent with no capability block raises nothing' (@($r5).Count -eq 0) (($r5 | ForEach-Object { $_.Kind }) -join ',')

  # CLEAN TWIN - a fully consistent agent.
  $r6 = Get-TcAgentProblems -Name 'x' -Known $K -AbsentMarkers $A -Lines @(
    '---', 'model: fable', 'effort: medium', 'tools: Read, Grep, Glob', '---', '## Your tool list is not a checklist', '| `Read`, `Grep`, `Glob` | spine |')
  T 'CLEAN TWIN a block naming exactly its declared tools raises nothing' (@($r6).Count -eq 0) (($r6 | ForEach-Object { $_.Detail }) -join ' | ')

  # CLEAN TWIN - the absence marker and the names on DIFFERENT lines, because prose wraps. Found live:
  # a per-line exemption passed `Write` on the marker's line and flagged the three that wrapped onto the
  # next one. If this ever fails again, someone has narrowed the exemption back to a single line.
  $r7 = Get-TcAgentProblems -Name 'x' -Known $K -AbsentMarkers $A -Lines @(
    '---', 'model: fable', 'effort: medium', 'tools: Read', '---', '## Your tool list is not a checklist', '| `Read` | spine |',
    'Before that this file named none and inherited `Write`,', '`Edit`, `Bash` and `PowerShell`, which contradicted its body.')
  T 'CLEAN TWIN an absence marker still exempts names that WRAPPED onto the next line' `
    (@($r7).Count -eq 0) (($r7 | ForEach-Object { $_.Detail }) -join ' | ')

  # MUST FIRE - and the look-back must not become a blanket amnesty: a genuine claim three lines after
  # an unrelated absence sentence is still a claim.
  $r8 = Get-TcAgentProblems -Name 'x' -Known $K -AbsentMarkers $A -Lines @(
    '---', 'model: fable', 'effort: medium', 'tools: Read', '---', '## Your tool list is not a checklist',
    '`Edit` is deliberately absent.', '', 'A paragraph about something else entirely.', 'Another one here.',
    '| `WebSearch` | situational |')
  T 'MUST FIRE  the look-back does not amnesty a real claim further down' `
    (@($r8).Count -eq 1 -and $r8[0].Detail -like '*WebSearch*') (($r8 | ForEach-Object { $_.Detail }) -join ' | ')

  T 'MUST FIRE  a single problem comes back as an ARRAY, not unrolled' ($r1 -is [array]) ($r1.GetType().FullName)

  if ($f) { Write-Output ("SELF-TEST FAIL: {0} check(s)" -f $f); exit 1 }
  Write-Output 'SELF-TEST PASS: the missing-tools-line case, the description-drift case, and four clean twins including the deliberately-absent exemption'
  exit 0
}

# ------------------------------------------------------------------------------------- live run
if (-not (Test-Path -LiteralPath $AGENT_DIR)) {
  Write-Output ("AGENT-TOOLS AUDIT BLIND: {0} does not exist. Nothing was checked." -f $AGENT_DIR)
  Write-GuardComplete -Name 'agent-tools' -Summary 'blind=no-agent-dir'
  exit 3
}
$files = @(Get-ChildItem $AGENT_DIR -Filter *.md -File -ErrorAction SilentlyContinue)
if (-not $files.Count) {
  Write-Output 'AGENT-TOOLS AUDIT BLIND: found zero agent definitions, which means the discovery is broken rather than there being none.'
  Write-GuardComplete -Name 'agent-tools' -Summary 'blind=no-agents'
  exit 3
}
$problems = @()
foreach ($fl in $files) {
  $found = Get-TcAgentProblems -Name $fl.BaseName -Lines ([IO.File]::ReadAllLines($fl.FullName)) -Known $KNOWN -AbsentMarkers $ABSENT_MARKERS
  foreach ($x in @($found)) { $problems += $x }
}
$problems = @($problems)
if ($problems.Count) {
  Write-Output ("AGENT-TOOLS AUDIT FAILED: {0} problem(s) across {1} agent definition(s):" -f $problems.Count, $files.Count)
  foreach ($p in $problems) { Write-Output ("  {0,-28} {1,-22} {2}" -f $p.Agent, $p.Kind, $p.Detail) }
  Write-GuardComplete -Name 'agent-tools' -Summary ("problems={0}" -f $problems.Count)
  exit 2
}
$writers = @($files | Where-Object {
  $d = Get-TcDeclaredTools -Lines ([IO.File]::ReadAllLines($_.FullName))
  @($d) -contains 'Write' -or @($d) -contains 'Edit'
})
$matrix = @{}
foreach ($fl in $files) {
  $ln = [IO.File]::ReadAllLines($fl.FullName)
  $k = (Get-TcFrontmatterValue -Lines $ln -Key 'model') + ' / ' + (Get-TcFrontmatterValue -Lines $ln -Key 'effort')
  if (-not $matrix.ContainsKey($k)) { $matrix[$k] = 0 }
  $matrix[$k]++
}
Write-Output ("agent-tools: PASSED - all {0} agent(s) declare a tools: line and every tool their blocks claim is declared. {1} can write." -f $files.Count, $writers.Count)
# The model/effort matrix is PRINTED, not judged. MATE says use the least capable model that finishes
# the job, and nothing here can know which that is - that is a measurement per stage, not a rule. What
# this does is make the spend visible on every gate run, so an upgrade is noticed rather than billed.
Write-Output '  model / effort pins:'
foreach ($k in ($matrix.Keys | Sort-Object)) { Write-Output ("    {0,-28} {1} agent(s)" -f $k, $matrix[$k]) }
Write-GuardComplete -Name 'agent-tools' -Summary ("agents={0} writers={1}" -f $files.Count, $writers.Count)
exit 0
