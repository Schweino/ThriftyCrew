<#
  merge-backlog-inbox.ps1 - one writer, one allocator, nothing lost.

  THE FAILURE THIS EXISTS FOR, and it happened on 2026-09-08. Four course agents
  ran in parallel. Because `BACKLOG-course-findings.md` is a shared file with a
  shared id counter and no lock, every agent was told NOT to write it and to
  report its findings instead, with the orchestrator merging afterwards.

  **Nine findings from three lanes were still sitting in agent reports hours
  later.** "Report it and I will merge" is not a mechanism; it is an intention,
  and an intention has no exit code. The one lane that DID write anything got its
  items in only because it invented a safe convention unprompted: append with
  explicitly unallocated ids in a single atomic write.

  THE FIX IS BRAD'S AND IT IS BETTER THAN WHAT I DID. Each agent writes its OWN
  file under `design\backlog-inbox\`. No two writers touch one file, so there is
  no contention to design around and nothing depends on anyone remembering. When
  the parallel run ends, this merges every inbox file into the backlog in one
  pass, as ONE writer, allocating ids sequentially because only one process is
  doing it.

  WHY A MERGE PASS IS BETTER THAN AGENTS WRITING DIRECTLY, beyond the locking.
  It is a review point. Four lanes on one estate produce near-duplicate findings,
  and the merge is where a human sees them side by side before they become two
  items that drift apart.

  AN INBOX FILE IS A FINDING, NOT AN ITEM. It needs no id and must not invent
  one. Format, one per finding, `##` separated:

      ## <title, one line>
      `<STATE>` `<queue tag>`
      <body, any markdown>

  The state must be one from the closed vocabulary `audit-backlog-status.ps1`
  enforces, and this refuses the merge rather than writing a heading that gate
  would fail - the whole point is that the backlog stays green.

  Exit 0 = merged, or nothing to merge. Exit 2 = an inbox file is malformed and
  NOTHING was written. Exit 3 = could not evaluate.

  Params: -InboxDir, -Backlog, -DryRun (print the plan, write nothing), -SelfTest
#>
[CmdletBinding()]
param(
  [string]$InboxDir = '',
  [string]$Backlog = '',
  [switch]$DryRun,
  [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repo = Split-Path -Parent $root
if (-not $InboxDir) { $InboxDir = Join-Path $repo 'design\backlog-inbox' }
if (-not $Backlog) { $Backlog = Join-Path $repo 'design\BACKLOG-course-findings.md' }

# The closed vocabulary, copied from the legend `audit-backlog-status.ps1` enforces.
# A state outside it turns that gate red, so this refuses rather than writes.
$STATES = @('DONE', 'PARKED', 'NEEDS A RULING', 'PARTLY DONE', 'OPEN')

function Test-State([string]$s) {
  foreach ($v in $STATES) { if ($s -match ('^' + [regex]::Escape($v) + '\b')) { return $true } }
  return $false
}

function Get-NextId([string]$text) {
  # The allocator. Only ever called by THIS script, and only one of it runs, which
  # is the entire reason the ids are safe here and were not safe in four agents.
  $ids = [regex]::Matches($text, '(?m)^### I(\d+)\b') | ForEach-Object { [int]$_.Groups[1].Value }
  if (-not $ids -or @($ids).Count -eq 0) { return 1 }
  return (($ids | Measure-Object -Maximum).Maximum + 1)
}

function Test-MislevelledFinding([string]$preamble) {
  <# A `#` heading is a mis-levelled FINDING only when a STATE LINE follows it. With prose
     under it, it is a document title - which is what every lane writes and what this
     check used to refuse. Three of three lanes tripped it on 2026-09-08; a rule broken by
     everyone who meets it is the defect. The state line is what makes a heading a finding,
     which is already how `##` is judged, so this just applies the same test one level up. #>
  $lines = $preamble -split "`r?`n"
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^#\s+\S') {
      $rest = @($lines | Select-Object -Skip ($i + 1) | Where-Object { $_.Trim() })
      if ($rest.Count -gt 0 -and $rest[0] -match '^\s*`([^`]+)`\s*(?:`([^`]+)`)?\s*$') { return $true }
    }
  }
  return $false
}

function Read-Inbox([string]$path) {
  <# [(title, state, body)] from one inbox file. Throws on a malformed finding. #>
  $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
  $raw = $raw -replace "^﻿", ''
  $out = @()
  # Split on a heading at column 0 that is exactly two hashes. Element 0 is everything
  # BEFORE the first heading, which is NOT a finding - on 2026-09-08 a README's level-one
  # title was reported as a finding with a missing state line, which is a true refusal of
  # a thing that was never a finding.
  #
  # It is dropped rather than parsed, but NOT silently: a `#` heading in the preamble is
  # very likely a finding somebody wrote with one hash instead of two, and dropping that
  # quietly would trade a loud wrong refusal for a silent LOSS. In a tool whose entire
  # purpose is that nothing gets lost, refusing loudly is the correct direction.
  $parts = [regex]::Split($raw, '(?m)^##\s+')
  $preamble = [string]$parts[0]
  $hasFindings = (@($parts).Count -gt 1)

  # A lane that measured nothing has a RESULT, not an absence, and must be able to say so.
  # 2026-09-08: a course lane was blocked by a 403, reached the index and none of the
  # material, and correctly filed nothing - and the merge refused every other lane's
  # findings because of it. "Landed with nothing" and "never landed" are different facts.
  #
  # The declaration is EXPLICIT and never inferred. Zero findings with no marker is still
  # a refusal, because a file empty by accident and a file empty on purpose are otherwise
  # identical, and this tool exists so nothing is lost silently.
  if (-not $hasFindings) {
    if ($raw -match '(?m)^\s*NOTHING TO FILE\b') {
      return @([pscustomobject]@{
        Title = ''; State = ''; Tag = ''; Body = ''
        From = [IO.Path]::GetFileName($path); Empty = $true
      })
    }
    # The MORE SPECIFIC diagnosis first. A `#` heading here is almost always a finding
    # written with one hash, and saying so sends the reader to the right fix; the generic
    # message would send them to add a marker they do not want.
    if (Test-MislevelledFinding $preamble) {
      throw "in $([IO.Path]::GetFileName($path)): a '#' heading has a state line under it, so it is a finding written with ONE hash. A finding is a '##' heading - use two."
    }
    throw "in $([IO.Path]::GetFileName($path)): no findings, and no 'NOTHING TO FILE' line. If this lane measured nothing, say so on a line of its own - an empty file and a lost one look identical otherwise. If this is documentation, name it README.md."
  }

  # A TITLE above the findings is fine and is what every lane writes. Only a `#` heading
  # with a STATE LINE under it is a finding somebody mis-levelled, and that is still
  # refused, because a silently dropped finding is the failure this whole tool exists for.
  if (Test-MislevelledFinding $preamble) {
    throw "in $([IO.Path]::GetFileName($path)): a '#' heading above the first finding has a state line under it, so it is a finding written with ONE hash. A finding is a '##' heading - use two. A plain title with prose under it is fine and needs no change."
  }
  $parts = @($parts | Select-Object -Skip 1) | Where-Object { $_.Trim() }
  foreach ($p in $parts) {
    $lines = $p -split "`r?`n"
    $title = $lines[0].Trim()
    if (-not $title) { continue }
    $stateLine = ($lines | Select-Object -Skip 1 | Where-Object { $_.Trim() } | Select-Object -First 1)
    $m = [regex]::Match([string]$stateLine, '^\s*`([^`]+)`\s*(?:`([^`]+)`)?\s*$')
    if (-not $m.Success) {
      throw "in $([IO.Path]::GetFileName($path)): finding '$title' has no state line. Expected a line of the form ``OPEN`` ``queue-6``."
    }
    $state = $m.Groups[1].Value.Trim()
    $tag = $m.Groups[2].Value.Trim()
    if (-not (Test-State $state)) {
      throw "in $([IO.Path]::GetFileName($path)): finding '$title' declares state '$state', which is not in the closed vocabulary ($($STATES -join ', ')). audit-backlog-status.ps1 would fail on it."
    }
    $bodyLines = @($lines | Select-Object -Skip 1) | Where-Object { $_ -ne $stateLine }
    $out += [pscustomobject]@{
      Title = $title; State = $state; Tag = $tag
      Body = (($bodyLines -join "`n").Trim())
      From = [IO.Path]::GetFileName($path)
    }
  }
  return $out
}

if ($SelfTest) {
  # FIXTURE RULE, learned twice on 2026-09-08: no case may depend on what an earlier case
  # left in the inbox. A case that needs a clean inbox clears it wholesale; a case that
  # needs a file writes that file; every removal by name is -ErrorAction SilentlyContinue.
  # Both times this was violated, the failure was reported against the CODE UNDER TEST
  # rather than the setup, and a suite that lies about which thing broke is worse than one
  # that fails.
  $tmp = Join-Path $env:TEMP ('mbi-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  $inb = Join-Path $tmp 'inbox'
  New-Item -ItemType Directory -Path $inb -Force | Out-Null
  $bl = Join-Path $tmp 'backlog.md'
  $pass = 0; $fails = New-Object System.Collections.ArrayList
  function _C($label, $name, $ok, $detail) {
    if ($ok) { $script:pass++ } else { [void]$script:fails.Add("$label $name") }
    Write-Output ("  {0,-14} {1,-58} {2}" -f $label, $name, $(if ($ok) { 'ok' } else { "FAIL $detail" }))
  }

  Set-Content $bl "# Backlog`n`n### I40 - an old one ``DONE```n`nbody`n" -Encoding UTF8
  Set-Content (Join-Path $inb 'lane-a.md') "## first finding`n``OPEN`` ``queue-6```n`nbody one`n" -Encoding UTF8
  Set-Content (Join-Path $inb 'lane-b.md') "## second finding`n``PARTLY DONE`` ``queue-6```n`nbody two`n" -Encoding UTF8

  $out = & $PSCommandPath -InboxDir $inb -Backlog $bl 2>&1 | Out-String
  $code = $LASTEXITCODE
  $after = Get-Content $bl -Raw -Encoding UTF8
  _C 'MUST FIRE' 'two findings from two lanes merge, exit 0' ($code -eq 0 -and $after -match 'I41' -and $after -match 'I42') $code
  _C 'MUST FIRE' 'ids are allocated sequentially from the existing maximum' ($after -match '### I41 - first finding' -and $after -match '### I42 - second finding') 'wrong ids'
  _C 'MUST FIRE' 'each item records which lane file it came from' ($after -match 'lane-a\.md' -and $after -match 'lane-b\.md') 'no provenance'
  _C 'MUST NOT FIRE' 'the inbox is emptied so a second run cannot double-file' (@(Get-ChildItem $inb -Filter *.md).Count -eq 0) 'inbox not cleared'

  $out2 = & $PSCommandPath -InboxDir $inb -Backlog $bl 2>&1 | Out-String
  _C 'MUST NOT FIRE' 'an empty inbox is exit 0 and writes nothing' ($LASTEXITCODE -eq 0 -and (Get-Content $bl -Raw -Encoding UTF8) -eq $after) $LASTEXITCODE

  # A bad state must refuse the WHOLE merge, not write half of it.
  Set-Content (Join-Path $inb 'lane-c.md') "## good one`n``OPEN`` ``queue-6```n`nbody`n" -Encoding UTF8
  Set-Content (Join-Path $inb 'lane-d.md') "## bad one`n``SHIPPED`` ``queue-6```n`nbody`n" -Encoding UTF8
  $before = Get-Content $bl -Raw -Encoding UTF8
  $out3 = & $PSCommandPath -InboxDir $inb -Backlog $bl 2>&1 | Out-String
  $c3 = $LASTEXITCODE
  _C 'MUST FIRE' 'an invented state refuses the merge with exit 2' ($c3 -eq 2 -and $out3 -match 'closed vocabulary') $c3
  _C 'MUST NOT FIRE' 'and NOTHING is written when one file is bad' ((Get-Content $bl -Raw -Encoding UTF8) -eq $before) 'partial write'
  _C 'MUST NOT FIRE' 'and the good file is left in the inbox for a retry' ((Test-Path (Join-Path $inb 'lane-c.md'))) 'good file consumed'

  # A finding with no state line at all.
  Remove-Item (Join-Path $inb 'lane-d.md') -Force -ErrorAction SilentlyContinue   # tolerant BY RULE: no case may depend on what an earlier case left behind
  Set-Content (Join-Path $inb 'lane-e.md') "## no state here`n`njust a body`n" -Encoding UTF8
  $out4 = & $PSCommandPath -InboxDir $inb -Backlog $bl 2>&1 | Out-String
  _C 'MUST FIRE' 'a finding with no state line refuses the merge' ($LASTEXITCODE -eq 2 -and $out4 -match 'no state line') $LASTEXITCODE

  # MUST NOT FIRE: a README in the drop box is documentation, not a finding. This is the
  # 2026-09-08 defect exactly: writing the README that explains the convention refused the
  # whole merge with exit 2, because every file in the directory was assumed to be findings.
  Remove-Item (Join-Path $inb 'lane-e.md') -Force -ErrorAction SilentlyContinue
  Set-Content (Join-Path $inb 'README.md') "# how this drop box works`n`nprose, no findings, no state lines`n" -Encoding UTF8
  $outR = & $PSCommandPath -InboxDir $inb -Backlog $bl 2>&1 | Out-String
  $cR = $LASTEXITCODE
  _C 'MUST NOT FIRE' 'a README.md is skipped, not parsed as a finding' ($cR -eq 0) "$cR"
  _C 'MUST NOT FIRE' 'and the README is NOT consumed by the merge' ((Test-Path (Join-Path $inb 'README.md'))) 'README deleted'

  # MUST FIRE: the preamble above the first `##` is not a finding, but a `#` heading there
  # is very likely one written with the wrong number of hashes. Refuse loudly rather than
  # drop it, because a silent loss is worse than a wrong refusal in THIS tool.
  Set-Content (Join-Path $inb 'lane-f.md') "# a finding written with one hash`n``OPEN`` ``queue-6```n`nbody`n" -Encoding UTF8
  $outP = & $PSCommandPath -InboxDir $inb -Backlog $bl 2>&1 | Out-String
  $cP = $LASTEXITCODE
  _C 'MUST FIRE' 'a one-hash heading WITH a state line under it refuses the merge' ($cP -eq 2 -and $outP -match 'ONE hash') "$cP"

  # MUST NOT FIRE: a plain document TITLE is not a mis-levelled finding. Three of three
  # lanes opened their file with one on 2026-09-08 and all three were refused; a rule
  # broken by everyone who meets it is the defect, not the users.
  Get-ChildItem $inb -Filter *.md | Remove-Item -Force
  Set-Content (Join-Path $inb 'lane-t.md') "# Lane: something, 2026-09-08`n`nSome prose about the lane.`n`n## a real finding`n``OPEN`` ``queue-6```n`nbody`n" -Encoding UTF8
  $blT = Get-Content $bl -Raw -Encoding UTF8
  $outT = & $PSCommandPath -InboxDir $inb -Backlog $bl 2>&1 | Out-String
  $cT = $LASTEXITCODE
  $blT2 = Get-Content $bl -Raw -Encoding UTF8
  _C 'MUST NOT FIRE' 'a plain document TITLE above the findings is accepted' ($cT -eq 0) "$cT"
  _C 'MUST NOT FIRE' 'and the title is not filed as a finding' ($blT2 -match 'a real finding' -and $blT2 -notmatch 'Lane: something') 'title was filed'

  # CLEAN TWIN: a title on a NOTHING TO FILE lane, which is the exact shape a blocked
  # course produced on 2026-09-08.
  Get-ChildItem $inb -Filter *.md | Remove-Item -Force
  Set-Content (Join-Path $inb 'lane-u.md') "# Lane: blocked, 2026-09-08`n`nNOTHING TO FILE`n`nthe course refused every supplement`n" -Encoding UTF8
  $outU = & $PSCommandPath -InboxDir $inb -Backlog $bl 2>&1 | Out-String
  $cU = $LASTEXITCODE
  _C 'CLEAN TWIN' 'a titled NOTHING TO FILE lane is accepted and consumed' ($cU -eq 0 -and -not (Test-Path (Join-Path $inb 'lane-u.md'))) "$cU"

  # CLEAN TWIN: ordinary prose above the first finding still merges, and is not itself
  # filed. This is the behaviour the refusal above was most likely to have broken.
  Remove-Item (Join-Path $inb 'lane-f.md') -Force -ErrorAction SilentlyContinue   # tolerant BY RULE: no case may depend on what an earlier case left behind
  Set-Content (Join-Path $inb 'lane-g.md') "a note from the lane, no heading`n`n## a real finding`n``OPEN`` ``queue-6```n`nbody`n" -Encoding UTF8
  $outG = & $PSCommandPath -InboxDir $inb -Backlog $bl 2>&1 | Out-String
  $cG = $LASTEXITCODE
  $blAfter = Get-Content $bl -Raw -Encoding UTF8
  _C 'CLEAN TWIN' 'prose above the first finding merges, and the prose is not filed' ($cG -eq 0 -and $blAfter -match 'a real finding' -and $blAfter -notmatch 'a note from the lane') "$cG"

  Remove-Item (Join-Path $inb 'README.md') -Force -ErrorAction SilentlyContinue
  # MUST NOT FIRE: a lane that measured nothing can SAY so, and one lane reporting
  # nothing must not refuse every other lane's findings. This is the 2026-09-08 defect:
  # a course blocked by a 403 filed nothing, correctly, and the merge refused the batch.
  Get-ChildItem $inb -Filter *.md | Remove-Item -Force
  Set-Content (Join-Path $inb 'lane-h.md') "# Lane: blocked`n`nNOTHING TO FILE`n`nthe course 403'd, so nothing was measured`n" -Encoding UTF8
  Set-Content (Join-Path $inb 'lane-i.md') "## a real finding beside it`n``OPEN`` ``queue-6```n`nbody`n" -Encoding UTF8
  $blPre = Get-Content $bl -Raw -Encoding UTF8
  $outN = & $PSCommandPath -InboxDir $inb -Backlog $bl 2>&1 | Out-String
  $cN = $LASTEXITCODE
  $blPost = Get-Content $bl -Raw -Encoding UTF8
  _C 'MUST NOT FIRE' 'a declared NOTHING TO FILE lane does not refuse the batch' ($cN -eq 0) "$cN"
  _C 'MUST FIRE' 'and the empty landing is REPORTED by name, not silently dropped' ($outN -match 'NOTHING TO FILE declared by lane-h') 'not reported'
  _C 'MUST NOT FIRE' 'and it is NOT filed as a backlog item' ($blPost -notmatch 'Lane: blocked' -and $blPost -match 'a real finding beside it') 'empty landing was filed'

  # MUST FIRE: zero findings with NO marker is still a refusal. A file empty by accident
  # and a file empty on purpose are otherwise identical.
  Get-ChildItem $inb -Filter *.md | Remove-Item -Force
  Set-Content (Join-Path $inb 'lane-j.md') "some prose, no heading, no findings and no marker`n" -Encoding UTF8
  $outS = & $PSCommandPath -InboxDir $inb -Backlog $bl 2>&1 | Out-String
  $cS = $LASTEXITCODE
  _C 'MUST FIRE' 'zero findings with NO marker is still refused' ($cS -eq 2 -and $outS -match 'NOTHING TO FILE') "$cS"

  # CLEAN TWIN: a lane declaring nothing, alone in the inbox, is consumed rather than
  # left to be re-reported on every future run.
  Get-ChildItem $inb -Filter *.md | Remove-Item -Force
  Set-Content (Join-Path $inb 'lane-k.md') "NOTHING TO FILE`n`nnothing measured this run`n" -Encoding UTF8
  $outK = & $PSCommandPath -InboxDir $inb -Backlog $bl 2>&1 | Out-String
  $cK = $LASTEXITCODE
  _C 'CLEAN TWIN' 'a lone empty landing is consumed, not re-reported forever' ($cK -eq 0 -and -not (Test-Path (Join-Path $inb 'lane-k.md'))) "$cK"

  # CLEAN TWIN: -DryRun prints the plan and changes nothing.
  # THIS CASE OWNS ITS FIXTURE. It used to assert on `lane-c.md` surviving, where lane-c
  # had been created eight cases earlier for an unrelated purpose. Inserting cases between
  # them turned it red with the message "dry run wrote", which was a claim about the code
  # under test and was FALSE - the file was simply gone. A fixture that lies about which
  # thing failed is worse than one that fails, so it now writes what it asserts on.
  Get-ChildItem $inb -Filter *.md | Remove-Item -Force
  Set-Content (Join-Path $inb 'lane-dry.md') "## a finding for the dry run`n``OPEN`` ``queue-6```n`nbody`n" -Encoding UTF8
  $before2 = Get-Content $bl -Raw -Encoding UTF8
  $out5 = & $PSCommandPath -InboxDir $inb -Backlog $bl -DryRun 2>&1 | Out-String
  $c5 = $LASTEXITCODE
  _C 'CLEAN TWIN' '-DryRun plans without writing or emptying the inbox' `
    ($c5 -eq 0 -and $out5 -match 'a finding for the dry run' -and (Get-Content $bl -Raw -Encoding UTF8) -eq $before2 -and (Test-Path (Join-Path $inb 'lane-dry.md'))) "dry run wrote, or planned nothing (exit $c5)"

  Remove-Item $tmp -Recurse -Force
  Write-Output ''
  $total = $pass + $fails.Count
  if ($fails.Count) {
    Write-Output ("SELF-TEST FAIL: {0} case(s) of {1}" -f $fails.Count, $total)
    foreach ($f in $fails) { Write-Output ("  " + $f) }
    exit 1
  }
  Write-Output ("merge-backlog-inbox self-test: {0} of {0} cases pass" -f $total)
  exit 0
}

if (-not (Test-Path -LiteralPath $Backlog)) {
  Write-Output "COULD NOT EVALUATE - no backlog at $Backlog."
  Write-Output 'MERGE-BACKLOG-INBOX-COMPLETE'
  exit 3
}
if (-not (Test-Path -LiteralPath $InboxDir)) {
  Write-Output "inbox directory does not exist yet: $InboxDir. Nothing to merge."
  Write-Output 'MERGE-BACKLOG-INBOX-COMPLETE'
  exit 0
}

# README.md documents the convention and lives here permanently so the directory survives
# in git; a name starting with `_` is a scratch file somebody parked. Everything else is
# findings. The skip list is deliberately TWO NAMES and not a heuristic: a broad "skip what
# does not look like findings" rule is a silent-loss machine in a tool that exists so that
# nothing is lost. What was skipped is printed, so a skip is never invisible.
$all = @(Get-ChildItem -LiteralPath $InboxDir -Filter *.md -ErrorAction SilentlyContinue |
         Sort-Object Name)
$files = @($all | Where-Object { $_.Name -ne 'README.md' -and $_.Name -notlike '_*' })
$skipped = @($all).Count - @($files).Count
if ($skipped -gt 0) { Write-Output ("skipping " + $skipped + " documentation file(s): README.md / _*.md") }
if (-not $files -or @($files).Count -eq 0) {
  Write-Output "inbox is empty. Nothing to merge."
  Write-Output 'MERGE-BACKLOG-INBOX-COMPLETE'
  exit 0
}

# READ EVERY FILE BEFORE WRITING ANYTHING. One malformed finding refuses the whole
# merge, so a bad lane cannot leave the backlog half-updated - the same
# verify-then-write ordering that stopped a broken pattern shipping earlier today.
$findings = @()
try {
  foreach ($f in $files) { $findings += Read-Inbox $f.FullName }
} catch {
  Write-Output ("MERGE REFUSED: " + $_.Exception.Message)
  Write-Output "Nothing was written and the inbox is untouched. Fix that file and re-run."
  Write-Output 'MERGE-BACKLOG-INBOX-COMPLETE'
  exit 2
}

# An empty landing is a RESULT and is reported by name; it never becomes a backlog item,
# because "this lane found nothing" is not a change anybody rules on. The two counts stay
# separate in the output: a total that folds them together is how a number comes to mean
# nothing.
$empties  = @($findings | Where-Object { $_.Empty })
$findings = @($findings | Where-Object { -not $_.Empty })
foreach ($e in $empties) { Write-Output ("  NOTHING TO FILE declared by " + $e.From) }

if (@($findings).Count -eq 0) {
  if (@($empties).Count -gt 0 -and -not $DryRun) {
    # Consume them, so a lane that landed with nothing is not re-reported forever.
    foreach ($f in $files) { Remove-Item -LiteralPath $f.FullName -Force }
    Write-Output ("no findings to merge; {0} lane(s) declared NOTHING TO FILE and were consumed." -f @($empties).Count)
  } else {
    Write-Output "inbox holds $(@($files).Count) file(s) and no findings. Nothing to merge."
  }
  Write-Output 'MERGE-BACKLOG-INBOX-COMPLETE'
  exit 0
}

$text = Get-Content -LiteralPath $Backlog -Raw -Encoding UTF8
$next = Get-NextId $text

Write-Output ("MERGING {0} finding(s) from {1} inbox file(s), ids I{2} onward:" -f `
  @($findings).Count, @($files).Count, $next)
$block = New-Object System.Text.StringBuilder
$i = $next
foreach ($f in $findings) {
  $tag = if ($f.Tag) { " ``$($f.Tag)``" } else { '' }
  Write-Output ("  I{0,-4} {1,-58} <- {2}" -f $i, $f.Title.Substring(0, [Math]::Min(58, $f.Title.Length)), $f.From)
  [void]$block.AppendLine("")
  [void]$block.AppendLine("### I$i - $($f.Title) ``$($f.State)``$tag")
  [void]$block.AppendLine("")
  [void]$block.AppendLine("**Merged from ``design\backlog-inbox\$($f.From)`` on $((Get-Date).ToString('yyyy-MM-dd')).** Written by a course agent during a parallel run; ids are allocated here because this is the only writer.")
  [void]$block.AppendLine("")
  [void]$block.AppendLine($f.Body)
  $i++
}

if ($DryRun) {
  Write-Output ''
  Write-Output "-DryRun: nothing written, inbox untouched."
  Write-Output 'MERGE-BACKLOG-INBOX-COMPLETE'
  exit 0
}

Add-Content -LiteralPath $Backlog -Value $block.ToString() -Encoding UTF8
# The inbox is emptied only after a successful append, so a crash re-runs cleanly
# rather than losing the findings - the failure this whole script exists for.
foreach ($f in $files) { Remove-Item -LiteralPath $f.FullName -Force }

Write-Output ''
$emptyNote = if (@($empties).Count -gt 0) { ", plus {0} lane(s) declaring NOTHING TO FILE" -f @($empties).Count } else { '' }
Write-Output ("merged {0} finding(s){1}; inbox emptied. Run ops\audit-backlog-status.ps1 to confirm the states." -f @($findings).Count, $emptyNote)
Write-Output 'MERGE-BACKLOG-INBOX-COMPLETE'
exit 0
