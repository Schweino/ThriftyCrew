<#
  audit-agent-tools.ps1 - every agent declares its tools, and what a definition SAYS about its tools
  matches what it HAS.

  SCOPE OF A CLEAN REPORT: UNSOUND, and the direction is worth knowing. It compares a
    definition's DECLARED tools list against what the harness gives it, so a clean report means
    the declarations it could PARSE agreed. An agent whose front matter it cannot parse is not
    checked, and says nothing about itself either way. RULE 3 is SOUND over MARKED store-step spans
    (every one is compared with the canonical text byte for byte, so a drift finding is real: the
    difference IS the defect, which makes that half COMPLETE too) and UNSOUND over UNMARKED copies,
    which it finds only by the two spellings it knows, the search.py command and the upper-case
    heading. A copy reworded past both is invisible to it.

  WHY THIS EXISTS (2026-09-06, backlog E3). Course 6's finding: handed three well-named tools and no
  usage context, an agent decided the unnecessary one must be needed and INVENTED work to justify it.
  The fix was a block per agent naming which tools are situational - and a block like that is prose
  about a frontmatter line, so it is a drift surface. E3 is a defect about a description not matching
  reality; doing the check by eye would reproduce it one level up.

  THREE RULES, and the first is the one that stops a regression nobody would notice:

    1. EVERY AGENT DECLARES A `tools:` LINE. Four of the twelve declared none until 2026-09-06 and so
       inherited EVERY tool - including Write and Edit on two agents whose whole job is to render a
       verdict. An agent with no tools: line does not look wrong in a diff; it looks like a file that
       simply does not mention tools.
    2. A TOOL NAMED IN A CAPABILITY BLOCK MUST BE DECLARED - unless the line marks it ABSENT. Saying
       "`Edit` is deliberately absent" is the most useful sentence such a block can carry, so the rule
       has to admit it rather than punish it. Lines carrying an absence marker are exempt; every other
       named tool must exist in the frontmatter.
    3. EVERY AGENT CARRIES THE STORE-STEP, BYTE FOR BYTE, OR SAYS WHY NOT (2026-09-23, plan
       design/PLAN-brain-consults-on-code-and-analysis-2026-09-22.md W5.2). The step that tells an agent to
       search the knowledge store was one 1,430-char text pasted into 6 of 13 agents, worded for code only,
       with a command that failed in both shells when launched without cmd. It now lives ONCE, in
       ops/agent-blocks/store-step.md, as two marked variants (CODE and ANALYSIS), and this rule holds:
         - every marked span in an agent is IDENTICAL to its canonical variant (LF-normalised, ordinal);
         - every agent carries the variants $STORE_STEP_REQUIRED names for it, and no others, or sits on
           $STORE_STEP_ALLOW with a reason; an agent named in neither carries at least one;
         - a verdict agent ($VERDICT_NO_EDIT) carries ANALYSIS unless it is allow-listed;
         - an agent with neither Bash nor PowerShell that is told to run search.py is refused, because it
           cannot, and an instruction it cannot follow teaches it to skip the step;
         - store-step text OUTSIDE a marked span (the pre-W5.2 copy, or a hand edit that lost its markers)
           is refused, because nothing can hold an unmarked copy to anything;
         - the same span rules over every ops/prompt-backup/scheduled-tasks/*/SKILL.md that carries a
           store-step. A task need not carry one. A task whose LIVE SKILL.md is not yet canonical sits on
           the allow-list in mode 'pending': its unmarked text is tolerated, its marked spans are still
           judged, and the run says RESOLVED once the mirror is canonical so the entry can be removed.

  EXIT CODES (lib\guard-contract.ps1 vocabulary): 0 clean, 2 hard finding, 3 could-not-evaluate.
  Read the verdict LINE, not the number (backlog E2).

  Self-test: powershell -File ops\audit-agent-tools.ps1 -SelfTest
#>
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop (2026-09-07)
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\ops' }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')

$AGENT_DIR = Join-Path $repo '.claude\agents'
$KNOWN = @('Read', 'Grep', 'Glob', 'Bash', 'PowerShell', 'Edit', 'Write', 'WebFetch', 'WebSearch', 'Task', 'NotebookEdit')

# LEAST PRIVILEGE FOR THE AGENTS THAT ONLY REPORT (2026-09-07, backlog E3b, Brad's ruling).
# An agent whose job is a verdict must never be able to EDIT the work it is judging - that is the
# tool that turns a reviewer into a participant, and a reviewer who can fix what it found stops
# reporting it. None declares Edit today; this keeps it that way.
#
# WRITE IS SPLIT, AND THE SPLIT IS THE MEASURED PART. Brad ruled "verdict-only agents lose Write" and
# the facts only half allow it. recipe-batch-auditor's verdict IS a file - waves\wave-<k>.audit.md,
# read by hunt-daemon.py:7522 and gated by audit-wave-blocker-headings.ps1 - so taking Write breaks
# the publish chain. post-publish-reviewer holds Bash and PowerShell and needs them, so removing
# Write would not narrow what it can do; it would only move the write out of a sanctioned
# repo-relative path into an unaudited shell call. The three that report through their RETURN VALUE
# have no such need and are held to it.
$VERDICT_NO_EDIT  = @('post-publish-reviewer', 'recipe-batch-auditor', 'recipe-dedup-selector',
                      'recipe-source-qa', 'triage-reviewer')
$VERDICT_NO_WRITE = @('recipe-dedup-selector', 'recipe-source-qa', 'triage-reviewer')

# RULE 3: THE STORE-STEP (2026-09-23, W5.2). The canonical text is a FILE so a change to it is one edit that
# every copy must follow, and the policy is HERE, beside the rule that enforces it, so the two cannot drift.
$STORE_STEP_FILE     = Join-Path $repo 'ops\agent-blocks\store-step.md'
$TASK_MIRROR_DIR     = Join-Path $repo 'ops\prompt-backup\scheduled-tasks'
$STORE_STEP_VARIANTS = @('CODE', 'ANALYSIS')
# Which variants each agent carries, exactly. Named in plan W5.2 step 2: ANALYSIS for every agent whose job
# is a verdict or a measurement, CODE for every agent that changes code, both where an agent does both.
$STORE_STEP_REQUIRED = [ordered]@{
  'commodity-registrar'      = @('CODE', 'ANALYSIS')
  'post-publish-reviewer'    = @('CODE', 'ANALYSIS')
  'recipe-batch-auditor'     = @('ANALYSIS')          # its Write is a verdict file, so ANALYSIS only
  'recipe-hunter-pricer'     = @('ANALYSIS')
  'recipe-ingredient-mapper' = @('CODE')
  'recipe-source-qa'         = @('ANALYSIS')
  'recipe-sourcer'           = @('ANALYSIS')
  'triage-developer'         = @('CODE')
  'triage-ops-developer'     = @('CODE')
  'triage-reviewer'          = @('CODE', 'ANALYSIS')
}
# Keyed '<kind>|<name>'. mode 'exempt': need not carry a variant, and anything it does carry is still judged.
# mode 'pending': its UNMARKED store-step text is tolerated because the fix is an edit outside this repo (a live
# scheduled-task SKILL.md, plan procedure P3); its marked spans are still judged.
$STORE_STEP_ALLOW = [ordered]@{
  'agent|recipe-hunter-extractor' = @{ mode = 'exempt';  reason = 'Bash, but transcription only: no code, no verdict' }
  'agent|recipe-dedup-selector'   = @{ mode = 'exempt';  reason = 'no Bash: the dispatcher must paste excerpts' }
  'agent|recipe-writer'           = @{ mode = 'exempt';  reason = 'no Bash: the dispatcher must paste excerpts' }
  'task|grocery-alert-triage'     = @{ mode = 'pending'; reason = 'P3 pending (W5.2 step 5): live SKILL.md edited by the orchestrator' }
}

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
  param([string]$Name, [string[]]$Lines, [string[]]$Known, [string[]]$AbsentMarkers,
         [string[]]$NoEdit = @(), [string[]]$NoWrite = @())
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
  foreach ($t in @('Edit', 'Write')) {
    $forbidden = if ($t -eq 'Edit') { $NoEdit } else { $NoWrite }
    if (@($forbidden) -contains $Name -and @($declared) -contains $t) {
      $p += [pscustomobject]@{ Agent = $Name; Kind = ('verdict-agent-declares-' + $t.ToLower())
        Detail = ('reports a verdict and declares ' + $t + ', which lets it change the work it is judging') }
    }
  }
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

# ------------------------------------------------------------------------------------- RULE 3
# The markers ARE part of the canonical text: a carrier pastes the whole span, begin and end lines included, and
# the comparison covers both. The begin line is matched loosely (so an edited tail still OPENS a span and is then
# reported as drift, not as a missing block) and the end line exactly.
$STEP_BEGIN_RE  = '^<!-- store-step:([A-Za-z]+) begin\b'
$STEP_END_RE    = '^<!-- store-step:([A-Za-z]+) end -->\s*$'
# Store-step text that no marker bounds: the command, in either separator, or the heading's upper-case lead. The
# heading is matched CASE-SENSITIVELY on purpose - prose that says "search the knowledge store" is not a copy.
$STEP_LEGACY_RE = '(?i:knowledge-search[\\/]+search\.py)|SEARCH THE KNOWLEDGE STORE'
$STEP_CMD_RE    = '(?i)knowledge-search[\\/]+search\.py'

function Get-TcStoreStepSpans {
  <# Every marked store-step span in a text (markers included, LF-normalised), every marker that does not pair,
     and every line OUTSIDE a span that still carries store-step text. Pure over a string, so the fixtures drive it
     without a file. CRLF -> LF only: a checkout may hold either, and git holds these files LF. #>
  param([string]$Text)
  $lines = ([string]$Text).Replace("`r`n", "`n").Split("`n")
  $spans = @(); $bad = @(); $legacy = @()
  $n = 0
  while ($n -lt $lines.Count) {
    $bm = [regex]::Match($lines[$n], $STEP_BEGIN_RE)
    if ($bm.Success) {
      $variant = $bm.Groups[1].Value
      $close = -1
      for ($j = $n + 1; $j -lt $lines.Count; $j++) {
        if ([regex]::IsMatch($lines[$j], $STEP_BEGIN_RE)) { break }
        $em = [regex]::Match($lines[$j], $STEP_END_RE)
        if ($em.Success) { if ([string]::Equals($em.Groups[1].Value, $variant, [StringComparison]::Ordinal)) { $close = $j }; break }
      }
      if ($close -lt 0) {
        $bad += [pscustomobject]@{ Line = $n + 1; Detail = ('a store-step:' + $variant + ' begin marker with no matching end marker') }
        $n++; continue
      }
      $spans += [pscustomobject]@{ Variant = $variant; Line = $n + 1; Text = (($lines[$n..$close]) -join "`n") }
      $n = $close + 1; continue
    }
    if ([regex]::IsMatch($lines[$n], $STEP_END_RE)) {
      $bad += [pscustomobject]@{ Line = $n + 1; Detail = 'a store-step end marker with no begin marker above it' }
    } elseif ([regex]::IsMatch($lines[$n], $STEP_LEGACY_RE)) {
      $legacy += [pscustomobject]@{ Line = $n + 1; Text = $lines[$n] }
    }
    $n++
  }
  return @{ spans = @($spans); bad = @($bad); legacy = @($legacy) }
}

function Get-TcCanonicalStoreSteps {
  <# The canonical variants, keyed ORDINALLY by name. THROWS when the file cannot say exactly one span per
     declared variant and nothing else, because a rule whose source is broken cannot judge a copy of it: the
     caller turns the throw into BLIND, never into a pass. #>
  param([string]$Text, [string[]]$Variants)
  $parsed = Get-TcStoreStepSpans -Text $Text
  if (@($parsed.bad).Count) { throw ('the canonical file has a broken marker at line ' + $parsed.bad[0].Line + ': ' + $parsed.bad[0].Detail) }
  $map = [System.Collections.Hashtable]::new([System.StringComparer]::Ordinal)
  foreach ($s in @($parsed.spans)) {
    if ($Variants -cnotcontains $s.Variant) { throw ('the canonical file holds an undeclared variant ' + $s.Variant + ' at line ' + $s.Line) }
    if ($map.ContainsKey($s.Variant)) { throw ('the canonical file holds two ' + $s.Variant + ' spans') }
    $map[$s.Variant] = $s.Text
  }
  foreach ($v in $Variants) { if (-not $map.ContainsKey($v)) { throw ('the canonical file holds no ' + $v + ' span') } }
  return $map
}

function Get-TcFirstLineDifference {
  <# The first line where two LF texts differ, so a drift finding names the line rather than "it differs".
     Parameter names are deliberately not $A/$B-and-$a/$b: PowerShell names are case-insensitive. #>
  param([string]$Carried, [string]$Canonical)
  $cl = $Carried.Split("`n"); $kl = $Canonical.Split("`n")
  $max = [Math]::Max($cl.Count, $kl.Count)
  for ($i = 0; $i -lt $max; $i++) {
    $got  = if ($i -lt $cl.Count) { $cl[$i] } else { '<end of block>' }
    $want = if ($i -lt $kl.Count) { $kl[$i] } else { '<end of block>' }
    if (-not [string]::Equals($got, $want, [StringComparison]::Ordinal)) { return [pscustomobject]@{ Index = $i; Got = $got; Want = $want } }
  }
  return $null
}

function Format-TcClip {
  param([string]$S, [int]$Max = 90)
  if ($S.Length -le $Max) { return $S }
  return ($S.Substring(0, $Max) + '...')
}

function Get-TcStoreStepProblems {
  <# RULE 3 for ONE agent definition or ONE task mirror. Pure: the caller hands in the text, the canonical map and
     this file's policy for the name. Returns @{ carried; problems; note }:
       carried   the canonical variants the file carries byte for byte
       problems  findings, each Agent/Kind/Detail like the other rules' findings
       note      '' | 'PENDING ...' | 'RESOLVED ...' for a pending allow-list entry #>
  param(
    [string]$Kind, [string]$Name, [string]$Text, [hashtable]$Canonical,
    [string[]]$Required = @(), [switch]$HasRequirement,
    [string]$AllowMode = '', [switch]$NoShell, [switch]$IsVerdict
  )
  $who = $Kind + ' ' + $Name
  $parsed = Get-TcStoreStepSpans -Text $Text
  $p = @(); $carried = @(); $present = @()
  foreach ($b in @($parsed.bad)) {
    $p += [pscustomobject]@{ Agent = $who; Kind = 'store-step-malformed'; Detail = ('line ' + $b.Line + ': ' + $b.Detail) }
  }
  foreach ($s in @($parsed.spans)) {
    $present += $s.Variant
    if (-not $Canonical.ContainsKey($s.Variant)) {
      $p += [pscustomobject]@{ Agent = $who; Kind = 'store-step-unknown-variant'
        Detail = ('line ' + $s.Line + ' opens a store-step:' + $s.Variant + ' span, and ops/agent-blocks/store-step.md declares only ' + (($Canonical.Keys | Sort-Object) -join ' and ')) }
      continue
    }
    if ([string]::Equals($s.Text, [string]$Canonical[$s.Variant], [StringComparison]::Ordinal)) {
      if ($carried -ccontains $s.Variant) {
        $p += [pscustomobject]@{ Agent = $who; Kind = 'store-step-duplicate'; Detail = ('carries the ' + $s.Variant + ' span twice (the second at line ' + $s.Line + ')') }
      } else { $carried += $s.Variant }
    } else {
      $d = Get-TcFirstLineDifference -Carried $s.Text -Canonical ([string]$Canonical[$s.Variant])
      $p += [pscustomobject]@{ Agent = $who; Kind = 'store-step-drift'
        Detail = ('the ' + $s.Variant + ' span at line ' + $s.Line + ' differs from ops/agent-blocks/store-step.md at its line ' + ($d.Index + 1) +
                  ': has "' + (Format-TcClip $d.Got) + '", canonical "' + (Format-TcClip $d.Want) + '". Paste the span from the canonical file') }
    }
  }
  $note = ''
  $legacy = @($parsed.legacy)
  if ($legacy.Count) {
    if ($AllowMode -eq 'pending') {
      $note = ('PENDING  ' + $who + ' - still carries store-step text outside a canonical span at line ' + $legacy[0].Line + ', which only the out-of-repo edit named in its reason can change')
    } else {
      $p += [pscustomobject]@{ Agent = $who; Kind = 'store-step-unmarked'
        Detail = ($legacy.Count.ToString() + ' line(s) carry store-step text outside a canonical span, the first at line ' + $legacy[0].Line + ': "' + (Format-TcClip $legacy[0].Text) + '". Replace the old block with a span from ops/agent-blocks/store-step.md') }
    }
  } elseif ($AllowMode -eq 'pending') {
    $note = ('RESOLVED  ' + $who + ' - carries no unmarked store-step text any more, so its pending allow-list entry in ops/audit-agent-tools.ps1 can be removed')
  }
  # A shell is Bash OR PowerShell: the section 4.7 command runs unchanged in both, and no agent here holds one
  # without the other, so refusing on "no Bash" alone would name a problem nobody has.
  if ($NoShell -and ([string]$Text -match $STEP_CMD_RE)) {
    $p += [pscustomobject]@{ Agent = $who; Kind = 'store-step-no-shell'
      Detail = 'declares neither Bash nor PowerShell and is told to run search.py, which it cannot: the dispatcher must paste excerpts instead' }
  }
  if (-not $AllowMode) {
    if ($HasRequirement) {
      foreach ($v in @($Required)) {
        if ($present -cnotcontains $v) { $p += [pscustomobject]@{ Agent = $who; Kind = 'store-step-missing'; Detail = ('carries no ' + $v + ' span, which $STORE_STEP_REQUIRED names for it') } }
      }
      foreach ($c in @($carried)) {
        if (@($Required) -cnotcontains $c) { $p += [pscustomobject]@{ Agent = $who; Kind = 'store-step-unrequired'; Detail = ('carries a ' + $c + ' span that $STORE_STEP_REQUIRED does not name for it; add it there too, or remove the span') } }
      }
    } elseif ($Kind -eq 'agent' -and -not $present.Count -and -not $legacy.Count) {
      $p += [pscustomobject]@{ Agent = $who; Kind = 'store-step-none'; Detail = 'carries no store-step span and is not on $STORE_STEP_ALLOW with a reason' }
    }
    if ($IsVerdict -and $present -cnotcontains 'ANALYSIS') {
      $p += [pscustomobject]@{ Agent = $who; Kind = 'store-step-verdict-without-analysis'; Detail = 'returns a verdict and carries no ANALYSIS span' }
    }
  }
  # steps: how much store-step material the file holds at all, so a task that carries none can be told from one
  # whose every span is canonical without parsing it twice.
  return @{ carried = @($carried); problems = @($p); note = $note; steps = (@($parsed.spans).Count + $legacy.Count + @($parsed.bad).Count) }
}

function Get-TcStoreStepPolicyProblems {
  <# The policy tables must name things that exist, and never name one agent twice: a renamed agent would
     otherwise drop out of RULE 3 with every copy of it still green. #>
  param([string[]]$AgentNames, [string[]]$TaskNames, $Required, $Allow)
  $p = @()
  foreach ($k in @($Required.Keys)) {
    if ($AgentNames -notcontains $k) { $p += [pscustomobject]@{ Agent = ('agent ' + $k); Kind = 'store-step-stale-policy'; Detail = '$STORE_STEP_REQUIRED names an agent with no definition in .claude\agents' } }
    if ($Allow.Contains('agent|' + $k)) { $p += [pscustomobject]@{ Agent = ('agent ' + $k); Kind = 'store-step-policy-conflict'; Detail = 'is both required and allow-listed; it must be one or the other' } }
  }
  foreach ($k in @($Allow.Keys)) {
    $parts = ([string]$k).Split('|')
    $mode = [string]$Allow[$k].mode
    if (@('exempt', 'pending') -cnotcontains $mode) { $p += [pscustomobject]@{ Agent = $k; Kind = 'store-step-stale-policy'; Detail = ('allow-list mode "' + $mode + '" is neither exempt nor pending') } }
    if (-not ([string]$Allow[$k].reason).Trim()) { $p += [pscustomobject]@{ Agent = $k; Kind = 'store-step-stale-policy'; Detail = 'an allow-list entry with no reason' } }
    switch ($parts[0]) {
      'agent' { if ($AgentNames -notcontains $parts[1]) { $p += [pscustomobject]@{ Agent = $k; Kind = 'store-step-stale-policy'; Detail = 'allow-lists an agent with no definition in .claude\agents' } } }
      'task'  { if ($TaskNames -notcontains $parts[1]) { $p += [pscustomobject]@{ Agent = $k; Kind = 'store-step-stale-policy'; Detail = 'allow-lists a task with no mirror under ops\prompt-backup\scheduled-tasks' } } }
      default { $p += [pscustomobject]@{ Agent = $k; Kind = 'store-step-stale-policy'; Detail = 'an allow-list key must start agent| or task|' } }
    }
  }
  return ,@($p)
}

# ------------------------------------------------------------------------------------- self-test
if ($SelfTest) {
  $f = 0; $n = 0
  function T($m, $cond, $got) { $script:n++; if ($cond) { Write-Output ("ok    " + $m) } else { Write-Output ("FAIL  " + $m + "   got: " + $got); $script:f++ } }

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
  T 'MUST NOT FIRE both pins present raises nothing' (@($m3).Count -eq 0) (($m3 | ForEach-Object { $_.Kind }) -join ',')

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
  T 'MUST NOT FIRE lower-case verbs (write, edit, task) are not tool names' (@($r4).Count -eq 0) (($r4 | ForEach-Object { $_.Detail }) -join ' | ')

  # CLEAN TWIN - an agent with a tools line and no capability block is legal.
  $r5 = Get-TcAgentProblems -Name 'x' -Known $K -AbsentMarkers $A -Lines @('---', 'model: fable', 'effort: medium', 'tools: Read, Grep', '---', 'body with no block')
  T 'MUST NOT FIRE a declared agent with no capability block raises nothing' (@($r5).Count -eq 0) (($r5 | ForEach-Object { $_.Kind }) -join ',')

  # CLEAN TWIN - a fully consistent agent.
  $r6 = Get-TcAgentProblems -Name 'x' -Known $K -AbsentMarkers $A -Lines @(
    '---', 'model: fable', 'effort: medium', 'tools: Read, Grep, Glob', '---', '## Your tool list is not a checklist', '| `Read`, `Grep`, `Glob` | spine |')
  T 'MUST NOT FIRE a block naming exactly its declared tools raises nothing' (@($r6).Count -eq 0) (($r6 | ForEach-Object { $_.Detail }) -join ' | ')

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

  # LEAST PRIVILEGE ON THE VERDICT AGENTS (2026-09-07, backlog E3b). Single-quoted literals, never
  # concatenation: `Fn 'a' + 'b'` passes THREE positional arguments and the case then runs on a
  # fragment - it cost two wrong-reason passes elsewhere the same day.
  $fmEdit = @('---', 'model: fable', 'effort: high', 'tools: Read, Grep, Glob, Edit', '---')
  $rv1 = Get-TcAgentProblems -Name 'recipe-source-qa' -Known $K -AbsentMarkers $A -Lines $fmEdit -NoEdit @('recipe-source-qa')
  T 'MUST FIRE  a verdict agent that declares Edit can change the work it is judging' `
    (@($rv1 | Where-Object { $_.Kind -eq 'verdict-agent-declares-edit' }).Count -eq 1) (($rv1 | ForEach-Object { $_.Kind }) -join ',')
  $fmWrite = @('---', 'model: fable', 'effort: high', 'tools: Read, Grep, Glob, Write', '---')
  $rv2 = Get-TcAgentProblems -Name 'triage-reviewer' -Known $K -AbsentMarkers $A -Lines $fmWrite -NoWrite @('triage-reviewer')
  T 'MUST FIRE  a return-value verdict agent that declares Write has gained a side effect' `
    (@($rv2 | Where-Object { $_.Kind -eq 'verdict-agent-declares-write' }).Count -eq 1) (($rv2 | ForEach-Object { $_.Kind }) -join ',')
  $rv3 = Get-TcAgentProblems -Name 'recipe-batch-auditor' -Known $K -AbsentMarkers $A -Lines $fmWrite -NoEdit @('recipe-batch-auditor') -NoWrite @('recipe-dedup-selector')
  T 'MUST NOT FIRE  THE ONE THAT KEEPS THE PUBLISH CHAIN ALIVE - the batch auditor''s verdict IS a file, so Write is required and must not be flagged' `
    (@($rv3).Count -eq 0) (($rv3 | ForEach-Object { $_.Kind }) -join ',')
  $rv4 = Get-TcAgentProblems -Name 'recipe-ingredient-mapper' -Known $K -AbsentMarkers $A -Lines $fmEdit -NoEdit @('recipe-source-qa')
  T 'MUST NOT FIRE  an agent that is not on the verdict list keeps Edit, because writing is its job' `
    (@($rv4).Count -eq 0) (($rv4 | ForEach-Object { $_.Kind }) -join ',')

  T 'MUST FIRE  a single problem comes back as an ARRAY, not unrolled' ($r1 -is [array]) ($r1.GetType().FullName)

  # ---- RULE 3, the store-step (2026-09-23, plan W5.2). The fixtures are built FROM the shipped canonical file,
  # so the first case also proves that the file every carrier copies parses the way this rule reads it. Every
  # fixture is a string in memory: no temp path, nothing another concurrent run can collide with.
  $canon = $null; $canonErr = ''
  try { $canon = Get-TcCanonicalStoreSteps -Text ([IO.File]::ReadAllText($STORE_STEP_FILE)) -Variants $STORE_STEP_VARIANTS }
  catch { $canonErr = $_.Exception.Message }
  if ($null -eq $canon) { Write-Output ('SELF-TEST FAIL: the canonical file ' + $STORE_STEP_FILE + ' did not parse: ' + $canonErr); exit 1 }
  $code = [string]$canon['CODE']; $ana = [string]$canon['ANALYSIS']
  $cmd  = 'C:/Codex/Python312/python.exe C:/Users/Owner/.claude/skills/knowledge-search/' + 'search.py --' + 'estate "<3-6 words>"'
  T 'CLEAN TWIN the shipped canonical file parses into exactly CODE and ANALYSIS, each holding the section 4.7 command' `
    ($canon.Count -eq 2 -and $code.Contains($cmd) -and $ana.Contains($cmd) -and $code.StartsWith('<!-- store-step:CODE begin') -and $ana.EndsWith('<!-- store-step:ANALYSIS end -->')) ($canon.Keys -join ',')
  $bare = 'knowledge-search/' + 'search.py "<3-6 words>"'
  T 'MUST NOT FIRE since W3.4 (2026-09-25) neither canonical variant still carries the command without --estate' `
    (-not $code.Contains($bare) -and -not $ana.Contains($bare)) 'a variant still carries the bare command'

  function Join-TcFixture {
    param([string[]]$Head, [string[]]$Blocks)
    $tail = @('', '## Next section', 'body text')
    return ((@($Head) + @($Blocks) + $tail) -join "`n")
  }
  # A COUNT AND A STRING, NEVER A COMMA-RETURNED ARRAY: `@(Fn ...)` of `,@()` counts 1, so an inline wrap of a
  # helper that returned the matches would pass a MUST FIRE over an empty result (ops-and-gates.md).
  function Get-TcKindCount { param($R, [string]$K) $hits = @(@($R.problems) | Where-Object { $_.Kind -eq $K }); return [int]$hits.Count }
  function Get-TcKindDetail {
    param($R, [string]$K)
    $hits = @(@($R.problems) | Where-Object { $_.Kind -eq $K })
    if ($hits.Count) { return [string]$hits[0].Detail }
    return ''
  }
  function Get-TcKindList { param($R) return ((@($R.problems) | ForEach-Object { $_.Kind + ': ' + $_.Detail }) -join ' | ') }
  $fmSh = @('---', 'name: x', 'model: fable', 'effort: high', 'tools: Read, Grep, Glob, Bash', '---', '', 'You are an agent.', '')
  $fmNo = @('---', 'name: x', 'model: fable', 'effort: high', 'tools: Read, Grep, Glob', '---', '', 'You are an agent.', '')
  $tkHd = @('---', 'name: t', 'description: a scheduled task', '---', '', 'You are a scheduled task.', '')
  # The founding shape, as the six agents and the triage task carried it until W5.2. Built by concatenation so the
  # needle is never one literal in this file.
  $legacyHead = '## SEARCH THE KNOWLEDGE' + ' STORE BEFORE YOU DESIGN OR CHANGE CODE (Brad, 2026-09-18)'
  $legacyCmd  = '    C:\Codex\Python312\python.exe %USERPROFILE%\.claude\skills\knowledge-search\' + 'search.py "<two or three terms>"'
  $legacyBlk  = @($legacyHead, '', 'Search before you change code:', '', $legacyCmd)

  $txtCode = Join-TcFixture -Head $fmSh -Blocks @($code)
  $s1 = Get-TcStoreStepProblems -Kind 'agent' -Name 'x' -Text $txtCode -Canonical $canon -Required @('CODE') -HasRequirement
  T 'CLEAN TWIN an agent carrying the canonical CODE span is counted as carrying CODE' (@($s1.carried) -ccontains 'CODE') (Get-TcKindList $s1)
  T 'MUST NOT FIRE the canonical CODE span, required and carried, raises nothing' (@($s1.problems).Count -eq 0) (Get-TcKindList $s1)

  $drifted = $code.Replace('Open what it returns', 'Open what it gives')
  $s2 = Get-TcStoreStepProblems -Kind 'agent' -Name 'x' -Text (Join-TcFixture -Head $fmSh -Blocks @($drifted)) -Canonical $canon -Required @('CODE') -HasRequirement
  $k2 = Get-TcKindDetail $s2 'store-step-drift'
  T 'MUST FIRE  one word changed in the CODE span is drift, and the finding quotes the line that moved' `
    ((-not [string]::Equals($drifted, $code, [StringComparison]::Ordinal)) -and (Get-TcKindCount $s2 'store-step-drift') -eq 1 -and $k2 -like '*Open what it gives*' -and @($s2.problems).Count -eq 1) (Get-TcKindList $s2)

  $s3 = Get-TcStoreStepProblems -Kind 'agent' -Name 'v' -Text $txtCode -Canonical $canon -IsVerdict
  T 'MUST FIRE  a verdict agent carrying only CODE is refused for want of ANALYSIS' `
    ((Get-TcKindCount $s3 'store-step-verdict-without-analysis') -eq 1 -and @($s3.problems).Count -eq 1) (Get-TcKindList $s3)

  $s4 = Get-TcStoreStepProblems -Kind 'agent' -Name 'w' -Text (Join-TcFixture -Head $fmNo -Blocks @($ana)) -Canonical $canon -AllowMode 'exempt' -NoShell
  T 'MUST FIRE  an agent with no Bash and no PowerShell whose span says run search.py is refused, allow-listed or not' `
    ((Get-TcKindCount $s4 'store-step-no-shell') -eq 1) (Get-TcKindList $s4)

  $s5 = Get-TcStoreStepProblems -Kind 'agent' -Name 'recipe-writer' -Text (Join-TcFixture -Head $fmNo -Blocks @('A body with no store-step in it.')) -Canonical $canon -AllowMode 'exempt' -NoShell -IsVerdict
  T 'MUST NOT FIRE an allow-listed agent with no span, no shell and a verdict job raises nothing' (@($s5.problems).Count -eq 0) (Get-TcKindList $s5)

  $s6 = Get-TcStoreStepProblems -Kind 'agent' -Name 'x' -Text (Join-TcFixture -Head $fmSh -Blocks $legacyBlk) -Canonical $canon -Required @('CODE') -HasRequirement
  T 'MUST FIRE  THE FOUNDING SHAPE - the pre-W5.2 block, %USERPROFILE% command and no markers, is refused as unmarked and as missing CODE' `
    ((Get-TcKindCount $s6 'store-step-unmarked') -eq 1 -and (Get-TcKindCount $s6 'store-step-missing') -eq 1) (Get-TcKindList $s6)

  $s7 = Get-TcStoreStepProblems -Kind 'agent' -Name 'commodity-registrar' -Text $txtCode -Canonical $canon -Required @('CODE', 'ANALYSIS') -HasRequirement
  $k7 = Get-TcKindDetail $s7 'store-step-missing'
  T 'MUST FIRE  an agent whose row names CODE and ANALYSIS and carries only CODE is refused, naming ANALYSIS' `
    ((Get-TcKindCount $s7 'store-step-missing') -eq 1 -and $k7 -like '*no ANALYSIS span*' -and @($s7.carried) -ccontains 'CODE') (Get-TcKindList $s7)

  $s8 = Get-TcStoreStepProblems -Kind 'agent' -Name 'new-agent' -Text (Join-TcFixture -Head $fmSh -Blocks @('A body with no store-step in it.')) -Canonical $canon
  T 'MUST FIRE  a new agent named in neither table that carries nothing is refused' ((Get-TcKindCount $s8 'store-step-none') -eq 1) (Get-TcKindList $s8)

  $txtBoth = Join-TcFixture -Head $fmSh -Blocks @($code, '', $ana)
  $s9 = Get-TcStoreStepProblems -Kind 'agent' -Name 'recipe-batch-auditor' -Text $txtBoth -Canonical $canon -Required @('ANALYSIS') -HasRequirement -IsVerdict
  $k9 = Get-TcKindDetail $s9 'store-step-unrequired'
  T 'MUST FIRE  the batch auditor carrying CODE beside its ANALYSIS is refused, because its row says ANALYSIS only' `
    ((Get-TcKindCount $s9 'store-step-unrequired') -eq 1 -and $k9 -like '*a CODE span*' -and @($s9.problems).Count -eq 1) (Get-TcKindList $s9)

  $s10 = Get-TcStoreStepProblems -Kind 'agent' -Name 'triage-reviewer' -Text $txtBoth -Canonical $canon -Required @('CODE', 'ANALYSIS') -HasRequirement -IsVerdict
  T 'CLEAN TWIN an agent whose row names both carries both, adjacent, and both are counted in order' ((@($s10.carried) -join ',') -ceq 'CODE,ANALYSIS') (Get-TcKindList $s10)

  $codeLines = $code.Split("`n")
  $noEnd = ($codeLines[0..($codeLines.Count - 2)]) -join "`n"
  $s11 = Get-TcStoreStepProblems -Kind 'agent' -Name 'x' -Text (Join-TcFixture -Head $fmSh -Blocks @($noEnd)) -Canonical $canon -Required @('CODE') -HasRequirement
  T 'MUST FIRE  a begin marker whose end marker was lost is malformed, and the body it no longer bounds is unmarked text' `
    ((Get-TcKindCount $s11 'store-step-malformed') -eq 1 -and (Get-TcKindCount $s11 'store-step-unmarked') -eq 1) (Get-TcKindList $s11)

  $s12 = Get-TcStoreStepProblems -Kind 'agent' -Name 'x' -Text ($txtCode.Replace("`n", "`r`n")) -Canonical $canon -Required @('CODE') -HasRequirement
  T 'CLEAN TWIN a CRLF checkout of the canonical span still counts as carrying CODE, because both sides are LF-normalised' (@($s12.carried) -ccontains 'CODE') (Get-TcKindList $s12)

  $s13 = Get-TcStoreStepProblems -Kind 'agent' -Name 'x' -Text (Join-TcFixture -Head $fmSh -Blocks @($code.Replace('store-step:CODE', 'store-step:Code'))) -Canonical $canon -Required @('CODE') -HasRequirement
  T 'MUST FIRE  a span opened as store-step:Code is an unknown variant, never CODE: variant names compare ordinally' `
    ((Get-TcKindCount $s13 'store-step-unknown-variant') -eq 1 -and @($s13.carried).Count -eq 0) (Get-TcKindList $s13)

  $s14 = Get-TcStoreStepProblems -Kind 'agent' -Name 'x' -Text (Join-TcFixture -Head $fmSh -Blocks @($code, '', 'When in doubt, search the knowledge store again.')) -Canonical $canon -Required @('CODE') -HasRequirement
  T 'MUST NOT FIRE prose saying "search the knowledge store" in lower case outside a span is not a copy of the step' (@($s14.problems).Count -eq 0) (Get-TcKindList $s14)

  $t1 = Get-TcStoreStepProblems -Kind 'task' -Name 't' -Text (Join-TcFixture -Head $tkHd -Blocks @($drifted)) -Canonical $canon
  T 'MUST FIRE  a task mirror whose marked span drifted is refused exactly as an agent is' ((Get-TcKindCount $t1 'store-step-drift') -eq 1) (Get-TcKindList $t1)

  $t2 = Get-TcStoreStepProblems -Kind 'task' -Name 'grocery-alert-triage' -Text (Join-TcFixture -Head $tkHd -Blocks $legacyBlk) -Canonical $canon -AllowMode 'pending'
  T 'MUST NOT FIRE a pending task mirror still carrying the pre-W5.2 text raises nothing, because only its live SKILL.md can change it' (@($t2.problems).Count -eq 0) (Get-TcKindList $t2)
  T 'CLEAN TWIN ...and the same run still SAYS it is pending, naming the line' ($t2.note -like 'PENDING  task grocery-alert-triage*line 8*') $t2.note

  $t3 = Get-TcStoreStepProblems -Kind 'task' -Name 'grocery-alert-triage' -Text (Join-TcFixture -Head $tkHd -Blocks @($code)) -Canonical $canon -AllowMode 'pending'
  T 'CLEAN TWIN a pending task whose mirror now carries the canonical span is reported RESOLVED, so its entry gets removed' `
    ($t3.note -like 'RESOLVED*' -and @($t3.carried) -ccontains 'CODE') ($t3.note + ' / ' + (Get-TcKindList $t3))

  $t4 = Get-TcStoreStepProblems -Kind 'task' -Name 'dns' -Text (Join-TcFixture -Head $tkHd -Blocks @('No store-step here.')) -Canonical $canon
  T 'MUST NOT FIRE a task mirror with no store-step is silent: a task need not carry one' (@($t4.problems).Count -eq 0) (Get-TcKindList $t4)

  $t5 = Get-TcStoreStepProblems -Kind 'task' -Name 'other' -Text (Join-TcFixture -Head $tkHd -Blocks $legacyBlk) -Canonical $canon
  T 'MUST FIRE  a task mirror carrying the pre-W5.2 text with no pending entry is refused as unmarked' ((Get-TcKindCount $t5 'store-step-unmarked') -eq 1) (Get-TcKindList $t5)

  $threw = ''
  try { $null = Get-TcCanonicalStoreSteps -Text $code -Variants $STORE_STEP_VARIANTS } catch { $threw = $_.Exception.Message }
  T 'MUST FIRE  a canonical file with no ANALYSIS span THROWS, so the live run says BLIND and never passes' ($threw -like '*no ANALYSIS span*') $threw
  $twice = $code + "`n`n" + $code + "`n`n" + $ana
  $threw = ''
  try { $null = Get-TcCanonicalStoreSteps -Text $twice -Variants $STORE_STEP_VARIANTS } catch { $threw = $_.Exception.Message }
  T 'MUST FIRE  a canonical file holding two CODE spans THROWS rather than picking one' ($threw -like '*two CODE spans*') $threw

  $polReq = [ordered]@{ 'a' = @('CODE'); 'gone' = @('CODE') }
  $polAll = [ordered]@{ 'agent|a' = @{ mode = 'exempt'; reason = 'r' }; 'task|nope' = @{ mode = 'pending'; reason = 'r' } }
  $pp = Get-TcStoreStepPolicyProblems -AgentNames @('a') -TaskNames @('t') -Required $polReq -Allow $polAll
  T 'MUST FIRE  a policy naming an agent with no file, a task with no mirror, and an agent both required and allow-listed is three findings' `
    (@($pp).Count -eq 3 -and @($pp | Where-Object { $_.Kind -eq 'store-step-policy-conflict' }).Count -eq 1) (($pp | ForEach-Object { $_.Agent + ' ' + $_.Kind }) -join ' | ')

  # A LITERAL-CASE SUITE ASSERTS HOW MANY RAN (ops-and-gates.md): a case that silently stopped running reads as a
  # smaller suite, never as a failure, unless the number is checked.
  $EXPECTED_CASES = 42
  if ($n -ne $EXPECTED_CASES) { Write-Output ("FAIL  ran {0} case(s), expected {1}: a case was skipped, or one was added without moving `$EXPECTED_CASES" -f $n, $EXPECTED_CASES); $f++ }

  if ($f) { Write-Output ("SELF-TEST FAIL: {0} check(s)" -f $f); exit 1 }
  Write-Output ("SELF-TEST PASS: {0} cases - the missing-tools-line case, the description-drift case, four clean twins including the deliberately-absent exemption, the four verdict-agent privilege cases led by the batch auditor whose verdict IS a file, and RULE 3's store-step cases over agents, task mirrors, the canonical file and the policy tables" -f $n)
  exit 0
}

# ------------------------------------------------------------------------------------- live run
if (-not (Test-Path -LiteralPath $AGENT_DIR)) {
  Write-Output ("AGENT-TOOLS AUDIT BLIND: {0} does not exist. Nothing was checked." -f $AGENT_DIR)
  Exit-Guard -Name 'agent-tools' -Summary 'blind=no-agent-dir' -Code 3
}
$files = @(Get-ChildItem $AGENT_DIR -Filter *.md -File -ErrorAction SilentlyContinue)
if (-not $files.Count) {
  Write-Output 'AGENT-TOOLS AUDIT BLIND: found zero agent definitions, which means the discovery is broken rather than there being none.'
  Exit-Guard -Name 'agent-tools' -Summary 'blind=no-agents' -Code 3
}
$problems = @()
foreach ($fl in $files) {
  $found = Get-TcAgentProblems -Name $fl.BaseName -Lines ([IO.File]::ReadAllLines($fl.FullName)) -Known $KNOWN -AbsentMarkers $ABSENT_MARKERS -NoEdit $VERDICT_NO_EDIT -NoWrite $VERDICT_NO_WRITE
  foreach ($x in @($found)) { $problems += $x }
}
# ---- RULE 3, the store-step. Its source must be readable and its task set must resolve, or it judged nothing,
# and a rule that judged nothing says BLIND (exit 3), never PASSED.
if (-not (Test-Path -LiteralPath $STORE_STEP_FILE)) {
  Write-Output ("AGENT-TOOLS AUDIT BLIND: {0} does not exist, so RULE 3 has no canonical store-step to hold any copy to." -f $STORE_STEP_FILE)
  Exit-Guard -Name 'agent-tools' -Summary 'blind=no-store-step-file' -Code 3
}
$canon = $null
try { $canon = Get-TcCanonicalStoreSteps -Text ([IO.File]::ReadAllText($STORE_STEP_FILE)) -Variants $STORE_STEP_VARIANTS }
catch {
  Write-Output ("AGENT-TOOLS AUDIT BLIND: {0} cannot be read as the canonical store-step ({1}). RULE 3 judged nothing." -f $STORE_STEP_FILE, $_.Exception.Message)
  Exit-Guard -Name 'agent-tools' -Summary 'blind=store-step-canonical' -Code 3
}
$taskFiles = @()
foreach ($td in @(Get-ChildItem -LiteralPath $TASK_MIRROR_DIR -Directory -ErrorAction SilentlyContinue)) {
  $sk = Join-Path $td.FullName 'SKILL.md'
  if (Test-Path -LiteralPath $sk) { $taskFiles += [pscustomobject]@{ Name = $td.Name; Path = $sk } }
}
if (-not $taskFiles.Count) {
  Write-Output ("AGENT-TOOLS AUDIT BLIND: found zero SKILL.md under {0}, which means the discovery is broken rather than there being none." -f $TASK_MIRROR_DIR)
  Exit-Guard -Name 'agent-tools' -Summary 'blind=no-task-mirrors' -Code 3
}
$agentNames = @($files | ForEach-Object { $_.BaseName })
$taskNames  = @($taskFiles | ForEach-Object { $_.Name })
$policyProblems = Get-TcStoreStepPolicyProblems -AgentNames $agentNames -TaskNames $taskNames -Required $STORE_STEP_REQUIRED -Allow $STORE_STEP_ALLOW
foreach ($x in @($policyProblems)) { $problems += $x }
$ss = @{ carried = 0; allow = 0; failing = 0; tasks = 0; tsteps = 0; tcarried = 0; tpending = 0; tfailing = 0 }
$ssNotes = @(); $ssRows = @()
foreach ($fl in $files) {
  $declared = Get-TcDeclaredTools -Lines ([IO.File]::ReadAllLines($fl.FullName))
  $noShell = -not (@($declared) -contains 'Bash' -or @($declared) -contains 'PowerShell')
  $allowKey = 'agent|' + $fl.BaseName
  $mode = ''
  if ($STORE_STEP_ALLOW.Contains($allowKey)) { $mode = [string]$STORE_STEP_ALLOW[$allowKey].mode }
  $hasReq = $STORE_STEP_REQUIRED.Contains($fl.BaseName)
  $req = @()
  if ($hasReq) { $req = @($STORE_STEP_REQUIRED[$fl.BaseName]) }
  $r = Get-TcStoreStepProblems -Kind 'agent' -Name $fl.BaseName -Text ([IO.File]::ReadAllText($fl.FullName)) -Canonical $canon `
         -Required $req -HasRequirement:$hasReq -AllowMode $mode -NoShell:$noShell -IsVerdict:($VERDICT_NO_EDIT -contains $fl.BaseName)
  $rp = @($r.problems)
  foreach ($x in $rp) { $problems += $x }
  if ($mode) { $ss.allow++ }
  if ($rp.Count) { $ss.failing++ } elseif (-not $mode -and @($r.carried).Count) { $ss.carried++ }
  if ($r.note) { $ssNotes += $r.note }
  $what = '-'
  if (@($r.carried).Count) { $what = (@($r.carried) -join ' + ') } elseif ($mode) { $what = ('allow-listed (' + $mode + '): ' + [string]$STORE_STEP_ALLOW[$allowKey].reason) }
  $ssRows += ('    {0,-28} {1}' -f $fl.BaseName, $what)
}
foreach ($tf in $taskFiles) {
  $ss.tasks++
  $allowKey = 'task|' + $tf.Name
  $mode = ''
  if ($STORE_STEP_ALLOW.Contains($allowKey)) { $mode = [string]$STORE_STEP_ALLOW[$allowKey].mode }
  $r = Get-TcStoreStepProblems -Kind 'task' -Name $tf.Name -Text ([IO.File]::ReadAllText($tf.Path)) -Canonical $canon -AllowMode $mode
  $rp = @($r.problems)
  foreach ($x in $rp) { $problems += $x }
  if ($r.steps) { $ss.tsteps++ }
  if ($mode -eq 'pending') { $ss.tpending++ }
  if ($rp.Count) { $ss.tfailing++ } elseif (@($r.carried).Count) { $ss.tcarried++ }
  if ($r.note) { $ssNotes += $r.note }
}
$ssLine = ('store-step: agents={0} carried={1} allow-listed={2} failing={3} tasks={4} carried={5} failing={6}' -f
           $files.Count, $ss.carried, $ss.allow, $ss.failing, $ss.tasks, $ss.tcarried, $ss.tfailing)
$ssTask = ('  task mirrors: {0} SKILL.md read under ops\prompt-backup\scheduled-tasks, {1} carry store-step text, {2} carry a canonical span, {3} pending on the allow-list, {4} failing' -f
           $ss.tasks, $ss.tsteps, $ss.tcarried, $ss.tpending, $ss.tfailing)

$problems = @($problems)
if ($problems.Count) {
  Write-Output ("AGENT-TOOLS AUDIT FAILED: {0} problem(s) across {1} agent definition(s) and {2} task mirror(s):" -f $problems.Count, $files.Count, $ss.tasks)
  foreach ($p in $problems) { Write-Output ("  {0,-28} {1,-22} {2}" -f $p.Agent, $p.Kind, $p.Detail) }
  Write-Output $ssLine
  Write-Output $ssTask
  foreach ($nt in $ssNotes) { Write-Output ('  ' + $nt) }
  Exit-Guard -Name 'agent-tools' -Summary ("problems={0} agents={1} store_failing={2} tasks={3} task_failing={4}" -f $problems.Count, $files.Count, $ss.failing, $ss.tasks, $ss.tfailing) -Code 2
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
Write-Output $ssLine
Write-Output '  store-step carried per agent (canonical text: ops\agent-blocks\store-step.md):'
foreach ($row in $ssRows) { Write-Output $row }
Write-Output $ssTask
foreach ($nt in $ssNotes) { Write-Output ('  ' + $nt) }
# The model/effort matrix is PRINTED, not judged. MATE says use the least capable model that finishes
# the job, and nothing here can know which that is - that is a measurement per stage, not a rule. What
# this does is make the spend visible on every gate run, so an upgrade is noticed rather than billed.
Write-Output '  model / effort pins:'
foreach ($k in ($matrix.Keys | Sort-Object)) { Write-Output ("    {0,-28} {1} agent(s)" -f $k, $matrix[$k]) }
Exit-Guard -Name 'agent-tools' -Summary ("agents={0} writers={1} store_carried={2} store_allowlisted={3} store_failing=0 tasks={4} task_steps={5} task_carried={6} task_pending={7} task_failing=0" -f
  $files.Count, $writers.Count, $ss.carried, $ss.allow, $ss.tasks, $ss.tsteps, $ss.tcarried, $ss.tpending) -Code 0
