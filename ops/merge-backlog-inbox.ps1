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

  ONE MALFORMED FILE IS QUARANTINED; IT NO LONGER REFUSES THE BATCH.
  `[CHANGED 2026-09-12. The all-or-nothing rule above was deliberate, so here is why it
  is going, argued from what it was actually buying.]`
  It was chosen for two reasons: the backlog must stay GREEN for audit-backlog-status.ps1,
  and an id allocator with several writers loses findings. QUARANTINE KEEPS BOTH. The bad
  file's findings are never appended, so no heading that gate would fail is ever written;
  and this is still the ONE writer and the ONE allocator, over a smaller accepted set, so
  no id is reused and none is lost - the quarantined lane's findings are allocated on the
  retry run instead. What the batch refusal bought beyond those two was nothing. What it
  COST was measured: three times on 2026-09-11 and 12 a lane ended its file with a closing
  section like `## Nothing else` and no state line under it, and each refusal blocked THREE
  innocent lanes until a human fixed the one file. A gate that reddens three lanes for a
  fourth lane's typo teaches people to ignore red, or to hand-edit somebody else's drop
  file under time pressure, which ops-and-gates.md warns about in as many words.
  So the bad file is MOVED to `<inbox>\quarantine\` with its bytes intact and a
  `.reason.txt` beside it, it is NAMED in the output, the rest of the batch merges, and the
  run EXITS NON-ZERO so the failure is loud and attributable. Quarantine is per FILE and
  never per finding: dropping one `##` block out of a file a lane meant to file whole would
  be the silent loss this tool exists to prevent.

  VALIDATION IS A STEP WITH AN EXIT CODE, NOT A SENTENCE:

      -ValidateFile <path>      one file, in ISOLATION, before it joins the drop box

  It copies that ONE file into a fresh per-run temp inbox and runs this same code path with
  -DryRun, which reads the real backlog and writes nothing. It never reads the real inbox,
  though, because siblings are
  writing there and their problems are not this lane's to report. Exit 0 = it would merge,
  2 = it would be quarantined, 3 = could not evaluate. This NAMES the existing -InboxDir
  plus -DryRun mechanism rather than adding a second one: one lane did exactly this by hand
  on 2026-09-12 and its files merged first time, and the lanes that broke the batch are the
  ones that skipped the same instruction when it was only prose in a spawn prompt.

  Exit 0 = everything merged, or nothing to merge. Exit 2 = at least one inbox file was
  malformed and QUARANTINED; every other file merged. Exit 3 = could not evaluate.
  Read the verdict LINE, not the number alone.

  Params: -InboxDir, -Backlog, -DryRun (print the plan, write nothing),
          -ValidateFile <path> (one file, isolated), -SelfTest
#>
[CmdletBinding()]
param(
  [string]$InboxDir = '',
  [string]$Backlog = '',
  [string]$ValidateFile = '',
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
# The first-rung types audit-backlog-status.ps1 accepts, kept here so this merge refuses an invented
# one rather than writing a heading that reddens the next push. `[ADDED 2026-09-12 after eight did.]`
$RUNG_TYPES = @('READ', 'MEASURE', 'DOC', 'BUILD', 'RULING', 'BLOCKED')

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

# A STATE LINE, DEFINED ONCE. `[2026-09-09.]` This pattern lived in two places - the finding parser
# and Test-MislevelledFinding - and widening one to carry the reversibility and first-rung axes left
# the other refusing to recognise its own fixture's input. A rule implemented twice diverges the
# moment one copy moves, which this estate has a memory about. One constant, two readers.
$STATE_LINE_RE = '^\s*(`[^`]+`\s*)+$'

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
      if ($rest.Count -gt 0 -and $rest[0] -match $STATE_LINE_RE) { return $true }
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
    # EVERY backticked tag on the line, not the first two. `[WIDENED 2026-09-09, measured.]` The old
    # pattern took a state and at most ONE tag, so an OPEN finding could not carry the reversibility
    # and first-rung type that audit-backlog-status REQUIRES of it - and the merge duly wrote
    # `### I101 - ... ``OPEN`` ``queue-reach``, which that gate failed on the next run. The header
    # above promises this script refuses rather than writing a heading the gate rejects; it checked
    # the state vocabulary and nothing else, so it kept the half of the promise it could parse.
    $tags = @([regex]::Matches([string]$stateLine, '`([^`]+)`') | ForEach-Object { $_.Groups[1].Value.Trim() })
    if (-not $tags.Count -or ([string]$stateLine) -notmatch $STATE_LINE_RE) {
      throw "in $([IO.Path]::GetFileName($path)): finding '$title' has no state line. Expected a line of the form ``OPEN`` ``queue-6``, and for an open state also ``2-WAY``/``1-WAY`` and ``RUNG1 <TYPE>``."
    }
    $state = $tags[0]
    $rest = @($tags | Select-Object -Skip 1)
    $tag = ($rest -join '` `')
    if (-not (Test-State $state)) {
      throw "in $([IO.Path]::GetFileName($path)): finding '$title' declares state '$state', which is not in the closed vocabulary ($($STATES -join ', ')). audit-backlog-status.ps1 would fail on it."
    }
    # AND THE AXES, for the same reason and from the same gate. An open item owes both; a closed one
    # owes neither. Refusing here is the whole point of a single writer: the alternative is a heading
    # that lands and turns run-gates red for whoever next touches the ledger.
    if (@('NEEDS A RULING', 'PARTLY DONE', 'OPEN') -contains $state) {
      $hasRev = @($rest | Where-Object { $_ -eq '2-WAY' -or $_ -eq '1-WAY' }).Count
      $hasRung = @($rest | Where-Object { $_ -match '^RUNG1\s+\S+$' }).Count
      if ($hasRev -ne 1 -or $hasRung -ne 1) {
        throw ("in $([IO.Path]::GetFileName($path)): finding '$title' is state '$state', so its state line owes exactly one of ``2-WAY``/``1-WAY`` (it has $hasRev) and exactly one ``RUNG1 <TYPE>`` (it has $hasRung). audit-backlog-status.ps1 fails the heading without them, which is what happened to I101 on 2026-09-09.")
      }
      # AND THE TYPE ITSELF IS A CLOSED VOCABULARY, which this check missed until 2026-09-12.
      # `RUNG1 <anything>` satisfied the count above, so eight findings landed carrying MEASUREMENT,
      # CENSUS and PROTOTYPE - all reasonable English, none of them a value the audit accepts. They
      # merged clean and turned run-gates red on the push instead, which is the late failure a single
      # writer exists to prevent: this merge is the last place that can refuse a heading cheaply.
      $rungRow = @($rest | Where-Object { $_ -match '^RUNG1\s+\S+$' })
      if ($rungRow.Count -eq 1) {
        $rtype = ($rungRow[0] -replace '^RUNG1\s+', '')
        if ($RUNG_TYPES -notcontains $rtype) {
          throw ("in $([IO.Path]::GetFileName($path)): finding '$title' declares ``RUNG1 $rtype``, which is not in the closed vocabulary ($($RUNG_TYPES -join ', ')). audit-backlog-status.ps1 would fail the heading. A census or a count is MEASURE; building a throwaway to learn from is BUILD.")
        }
      }
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

# ---- -ValidateFile: ONE inbox file, in ISOLATION, with an exit code. ----------------
# A NAME for -InboxDir plus -DryRun, not a second implementation: it copies the one file
# into a fresh per-run temp inbox and re-enters this same script. What that buys over
# doing it by hand, which is what the instruction used to ask for in prose: it cannot be
# pointed at the REAL inbox, so a sibling's malformed file is never reported as this
# lane's problem, and this lane's check never touches a sibling's bytes.
if ($ValidateFile) {
  if ($PSBoundParameters.ContainsKey('InboxDir')) {
    Write-Output "COULD NOT EVALUATE - -ValidateFile judges ONE file in its own temp inbox, so -InboxDir means nothing here. Drop one of the two."
    Write-Output 'MERGE-BACKLOG-INBOX-COMPLETE'
    exit 3
  }
  if (-not (Test-Path -LiteralPath $ValidateFile)) {
    Write-Output "COULD NOT EVALUATE - no file at $ValidateFile."
    Write-Output 'MERGE-BACKLOG-INBOX-COMPLETE'
    exit 3
  }
  $leaf = [IO.Path]::GetFileName($ValidateFile)
  if ($leaf -notlike '*.md') {
    Write-Output "COULD NOT EVALUATE - $leaf is not a .md file, so the merge would never read it and validating it would prove nothing."
    Write-Output 'MERGE-BACKLOG-INBOX-COMPLETE'
    exit 3
  }
  if ($leaf -eq 'README.md' -or $leaf -like '_*') {
    Write-Output "COULD NOT EVALUATE - the merge SKIPS README.md and _*.md, so validating a findings file under that name would report a clean pass over a file that is never read. Rename it."
    Write-Output 'MERGE-BACKLOG-INBOX-COMPLETE'
    exit 3
  }
  # Named per run under one directory removed in a finally: several sessions share one
  # %TEMP%, and a fixed name here would have lanes validating into each other.
  $valBox = Join-Path $env:TEMP ('mbi-val-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  try {
    New-Item -ItemType Directory -Path $valBox -ErrorAction Stop | Out-Null
    Copy-Item -LiteralPath $ValidateFile -Destination (Join-Path $valBox $leaf) -ErrorAction Stop
    $valOut = & $PSCommandPath -InboxDir $valBox -Backlog $Backlog -DryRun 2>&1 | Out-String
    $valCode = $LASTEXITCODE
    foreach ($ln in ($valOut -split "`r?`n")) {
      if ($ln.Trim() -eq 'MERGE-BACKLOG-INBOX-COMPLETE') { continue }
      if (-not $ln.Trim()) { continue }
      Write-Output $ln
    }
    if ($valCode -eq 0) {
      Write-Output ("VALIDATE OK - {0} would merge. Nothing was written, and the real inbox was neither read nor touched." -f $leaf)
    } elseif ($valCode -eq 2) {
      Write-Output ("VALIDATE FAILED - {0} would be QUARANTINED, not merged. Fix it before the merge runs; the reason is above." -f $leaf)
    } else {
      Write-Output ("VALIDATE COULD NOT EVALUATE - exit {0}. That is discovery broken, not a pass." -f $valCode)
    }
    Write-Output 'MERGE-BACKLOG-INBOX-COMPLETE'
    exit $valCode
  } finally {
    # RETRY THE REMOVAL. A single -ErrorAction SilentlyContinue delete left an empty temp
    # directory behind in 16 of about 90 validate calls on 2026-09-12: the child process
    # has only just exited and Windows can still hold a handle to the directory it copied
    # into. Three tries, then give up quietly - a leaked empty directory must never turn a
    # validation into a failure.
    for ($try = 0; $try -lt 3; $try++) {
      if (-not (Test-Path -LiteralPath $valBox)) { break }
      Remove-Item -LiteralPath $valBox -Recurse -Force -ErrorAction SilentlyContinue
      if (Test-Path -LiteralPath $valBox) { Start-Sleep -Milliseconds 120 }
    }
  }
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
  Set-Content (Join-Path $inb 'lane-a.md') "## first finding`n``OPEN`` ``queue-6`` ``2-WAY`` ``RUNG1 MEASURE```n`nbody one`n" -Encoding UTF8
  Set-Content (Join-Path $inb 'lane-b.md') "## second finding`n``PARTLY DONE`` ``queue-6`` ``2-WAY`` ``RUNG1 MEASURE```n`nbody two`n" -Encoding UTF8

  # Byte length BEFORE the merge, so the line-ending assertion below can look at the
  # appended region alone. The seed above is written by Set-Content, which ends it with
  # [Environment]::NewLine, so asserting over the whole file would fail on the fixture's
  # own trailing CRLF and prove nothing about the writer under test.
  $seedLen = ([IO.File]::ReadAllBytes($bl)).Length

  $out = & $PSCommandPath -InboxDir $inb -Backlog $bl 2>&1 | Out-String
  $code = $LASTEXITCODE
  $after = Get-Content $bl -Raw -Encoding UTF8
  _C 'MUST FIRE' 'two findings from two lanes merge, exit 0' ($code -eq 0 -and $after -match 'I41' -and $after -match 'I42') $code
  _C 'MUST FIRE' 'ids are allocated sequentially from the existing maximum' ($after -match '### I41 - first finding' -and $after -match '### I42 - second finding') 'wrong ids'
  _C 'MUST FIRE' 'each item records which lane file it came from' ($after -match 'lane-a\.md' -and $after -match 'lane-b\.md') 'no provenance'
  _C 'MUST NOT FIRE' 'the inbox is emptied so a second run cannot double-file' (@(Get-ChildItem $inb -Filter *.md).Count -eq 0) 'inbox not cleared'

  # MUST FIRE - the founding bug, 2026-09-08. The first real merge appended 75 CRLF into a
  # 5,927-line LF file and all 22 cases here stayed green, because every one of them reads
  # the result with Get-Content -Raw, which cannot see a line ending. Git said it, not this
  # script - and git normalises on the way in, so the commit was clean and `git diff` showed
  # nothing. THE ASSERTION HAS TO BE ON BYTES or it is not testing the thing that broke.
  # Assign, THEN wrap - never @(expression) inline, per the estate's array-collapse rule.
  $allBytes = [IO.File]::ReadAllBytes($bl)
  $sliceRaw = $allBytes[$seedLen..($allBytes.Length - 1)]
  $addedBytes = @($sliceRaw)
  $crCount = @($addedBytes | Where-Object { $_ -eq 13 }).Count
  _C 'MUST FIRE' 'the appended block is LF: no CR byte anywhere in it' ($crCount -eq 0) "$crCount CR byte(s)"
  # CLEAN TWIN - the behaviour a line-ending change is most likely to break on its way past:
  # the block must still be separated from what was already there, so the first appended
  # byte is a newline and headings do not run onto the previous line.
  _C 'CLEAN TWIN' 'the appended block still starts on a fresh line' ($addedBytes.Count -gt 0 -and $addedBytes[0] -eq 10) "first byte $($addedBytes[0])"

  $out2 = & $PSCommandPath -InboxDir $inb -Backlog $bl 2>&1 | Out-String
  _C 'MUST NOT FIRE' 'an empty inbox is exit 0 and writes nothing' ($LASTEXITCODE -eq 0 -and (Get-Content $bl -Raw -Encoding UTF8) -eq $after) $LASTEXITCODE

  # A bad file must reach the backlog with NOTHING, and must not take its siblings down
  # with it. `[CONTRACT CHANGED 2026-09-12.]` Two of these cases asserted the old
  # all-or-nothing refusal; what survives of it is the half that mattered, which is that
  # nothing the bad file says is ever appended.
  Set-Content (Join-Path $inb 'lane-c.md') "## good one`n``OPEN`` ``queue-6`` ``2-WAY`` ``RUNG1 MEASURE```n`nbody`n" -Encoding UTF8
  Set-Content (Join-Path $inb 'lane-d.md') "## bad one`n``SHIPPED`` ``queue-6```n`nbody`n" -Encoding UTF8
  $before = Get-Content $bl -Raw -Encoding UTF8
  $out3 = & $PSCommandPath -InboxDir $inb -Backlog $bl 2>&1 | Out-String
  $c3 = $LASTEXITCODE
  $after3 = Get-Content $bl -Raw -Encoding UTF8
  $q = Join-Path $inb 'quarantine'
  _C 'MUST FIRE' 'an invented state refuses the merge with exit 2' ($c3 -eq 2 -and $out3 -match 'closed vocabulary') $c3
  _C 'MUST FIRE' 'and NOTHING the bad file said reaches the backlog' `
    (($after3 -notmatch 'SHIPPED') -and ($after3 -notmatch 'bad one') -and ($after3 -notmatch 'lane-d')) 'bad content was written'
  _C 'MUST FIRE' 'and the INNOCENT file merges and is consumed, not held hostage' `
    (($after3 -match 'good one') -and -not (Test-Path (Join-Path $inb 'lane-c.md'))) 'the good lane was blocked by its sibling'
  _C 'MUST FIRE' 'and the bad file keeps its bytes under inbox\quarantine, named in the output' `
    ((Test-Path (Join-Path $q 'lane-d.md')) -and ((Get-Content (Join-Path $q 'lane-d.md') -Raw -Encoding UTF8) -match 'SHIPPED') -and
     ($out3 -match 'QUARANTINED') -and ($out3 -match 'lane-d\.md') -and -not (Test-Path (Join-Path $inb 'lane-d.md'))) 'no retriable copy'
  _C 'MUST FIRE' 'and a .reason.txt beside it names the cause and the retry route' `
    ((Test-Path (Join-Path $q 'lane-d.md.reason.txt')) -and
     ((Get-Content (Join-Path $q 'lane-d.md.reason.txt') -Raw -Encoding UTF8) -match 'closed vocabulary') -and
     ((Get-Content (Join-Path $q 'lane-d.md.reason.txt') -Raw -Encoding UTF8) -match 'ValidateFile')) 'no reason on disk'
  _C 'MUST FIRE' 'and the VERDICT line states merged and quarantined counts' `
    ($out3 -match 'VERDICT: merged 1 finding\(s\) from 1 file\(s\), quarantined 1 file\(s\). Exit 2.') 'no verdict line'
  Remove-Item $q -Recurse -Force -ErrorAction SilentlyContinue

  # MUST FIRE - AN INVENTED FIRST-RUNG TYPE, and this is a MEASURED escape rather than a hypothetical.
  # `[2026-09-12.]` The check above counted `RUNG1 <anything>`, so eight findings merged clean carrying
  # MEASUREMENT, CENSUS and PROTOTYPE. Every one is reasonable English and none is a value
  # audit-backlog-status.ps1 accepts, so they turned run-gates red on the push instead, which is the
  # late failure a single writer exists to prevent. The twin is the point: a LEGAL rung must still
  # merge, because a vocabulary check that refused everything would satisfy the must-fire by accident.
  $inbR = Join-Path $root 'inbox-rung'
  New-Item -ItemType Directory -Path $inbR -Force | Out-Null
  Set-Content (Join-Path $inbR 'lane-rung-bad.md')  "## a census is not a rung type`n``OPEN`` ``queue-7`` ``2-WAY`` ``RUNG1 CENSUS```n`nbody`n" -Encoding UTF8
  Set-Content (Join-Path $inbR 'lane-rung-good.md') "## a legal rung lands`n``OPEN`` ``queue-7`` ``2-WAY`` ``RUNG1 MEASURE```n`nbody`n" -Encoding UTF8
  $outR = & $PSCommandPath -InboxDir $inbR -Backlog $bl 2>&1 | Out-String
  $cR = $LASTEXITCODE
  $afterR = Get-Content $bl -Raw -Encoding UTF8
  $qR = Join-Path $inbR 'quarantine'
  _C 'MUST FIRE' 'an invented RUNG1 type is quarantined and names the vocabulary' `
    ($cR -eq 2 -and $outR -match 'RUNG1 CENSUS' -and $outR -match 'closed vocabulary' -and (Test-Path (Join-Path $qR 'lane-rung-bad.md'))) "exit $cR :: $outR"
  _C 'MUST FIRE' 'and no heading carrying it reaches the backlog' `
    (($afterR -notmatch 'RUNG1 CENSUS') -and ($afterR -notmatch 'a census is not a rung type')) 'an unacceptable rung was written'
  _C 'CLEAN TWIN' 'a LEGAL rung type still merges beside it' `
    (($afterR -match 'a legal rung lands') -and -not (Test-Path (Join-Path $inbR 'lane-rung-good.md'))) 'the vocabulary check refused a legal value'
  Remove-Item $inbR -Recurse -Force -ErrorAction SilentlyContinue

  # MUST FIRE - THE MEASURED SHAPE, and the whole reason this changed. Three times on
  # 2026-09-11 and 12 a lane closed its file with a `## Nothing else` section carrying no
  # state line, and each refusal blocked THREE other lanes' findings until a human fixed
  # the one file. Four lanes, one typo: three must land.
  Get-ChildItem $inb -Filter *.md | Remove-Item -Force
  Set-Content (Join-Path $inb 'lane-p.md') "## p finding`n``OPEN`` ``queue-7`` ``2-WAY`` ``RUNG1 MEASURE```n`nbody p`n" -Encoding UTF8
  Set-Content (Join-Path $inb 'lane-q.md') "## q finding`n``OPEN`` ``queue-7`` ``2-WAY`` ``RUNG1 MEASURE```n`nbody q`n" -Encoding UTF8
  Set-Content (Join-Path $inb 'lane-r.md') "## r finding`n``OPEN`` ``queue-7`` ``2-WAY`` ``RUNG1 MEASURE```n`nbody r`n" -Encoding UTF8
  Set-Content (Join-Path $inb 'lane-s.md') "## s finding`n``OPEN`` ``queue-7`` ``2-WAY`` ``RUNG1 MEASURE```n`nbody s`n`n## Nothing else`n" -Encoding UTF8
  $outT4 = & $PSCommandPath -InboxDir $inb -Backlog $bl 2>&1 | Out-String
  $cT4 = $LASTEXITCODE
  $blT4 = Get-Content $bl -Raw -Encoding UTF8
  _C 'MUST FIRE' 'the 3x measured shape: one typo quarantines ONE file, three lanes land' `
    ($cT4 -eq 2 -and $blT4 -match 'body p' -and $blT4 -match 'body q' -and $blT4 -match 'body r' -and
     $blT4 -notmatch 'body s' -and (Test-Path (Join-Path $q 'lane-s.md'))) "exit $cT4 :: $outT4"
  # CLEAN TWIN: the allocator still runs ONCE over the accepted set, so the three that
  # landed got three consecutive ids and the quarantined lane burned none of them.
  $idsT4 = @([regex]::Matches($blT4, '(?m)^### I(\d+)\b') | ForEach-Object { [int]$_.Groups[1].Value })
  $maxT4 = ($idsT4 | Measure-Object -Maximum).Maximum
  $dupT4 = @($idsT4 | Group-Object | Where-Object { $_.Count -gt 1 })
  _C 'CLEAN TWIN' 'ids stay a single dense sequence: the quarantined lane burns none' `
    ($dupT4.Count -eq 0 -and $idsT4.Count -eq ($maxT4 - 39)) "max I$maxT4 over $($idsT4.Count) id(s), $($dupT4.Count) duplicate(s)"
  Remove-Item $q -Recurse -Force -ErrorAction SilentlyContinue

  # CLEAN TWIN: every file bad is still the old behaviour - nothing written - but it is
  # now reached by quarantining each of them rather than by refusing the batch.
  Get-ChildItem $inb -Filter *.md | Remove-Item -Force
  Set-Content (Join-Path $inb 'lane-m.md') "## m`n``SHIPPED`` ``queue-6```n`nbody`n" -Encoding UTF8
  Set-Content (Join-Path $inb 'lane-n.md') "## n`n`nno state line at all`n" -Encoding UTF8
  $blPreAll = Get-Content $bl -Raw -Encoding UTF8
  $outAll = & $PSCommandPath -InboxDir $inb -Backlog $bl 2>&1 | Out-String
  $cAll = $LASTEXITCODE
  _C 'CLEAN TWIN' 'every file bad: nothing written, both quarantined, exit 2' `
    ($cAll -eq 2 -and ((Get-Content $bl -Raw -Encoding UTF8) -eq $blPreAll) -and
     (Test-Path (Join-Path $q 'lane-m.md')) -and (Test-Path (Join-Path $q 'lane-n.md'))) "exit $cAll :: $outAll"
  Remove-Item $q -Recurse -Force -ErrorAction SilentlyContinue

  # CLEAN TWIN: the no-findings branch has its own consume step, and it must consume the
  # ACCEPTED files only. A lane that landed with nothing beside a lane that landed badly:
  # the empty one is consumed, the bad one is quarantined, and neither is deleted wrongly.
  Get-ChildItem $inb -Filter *.md | Remove-Item -Force
  Set-Content (Join-Path $inb 'lane-nil.md') "NOTHING TO FILE`n`nnothing measured this run`n" -Encoding UTF8
  Set-Content (Join-Path $inb 'lane-rot.md') "## rotten`n``SHIPPED`` ``queue-6```n`nbody`n" -Encoding UTF8
  $blPreNil = Get-Content $bl -Raw -Encoding UTF8
  $outNil = & $PSCommandPath -InboxDir $inb -Backlog $bl 2>&1 | Out-String
  $cNil = $LASTEXITCODE
  _C 'CLEAN TWIN' 'an empty landing beside a bad file: empty consumed, bad quarantined, nothing written' `
    ($cNil -eq 2 -and ((Get-Content $bl -Raw -Encoding UTF8) -eq $blPreNil) -and
     -not (Test-Path (Join-Path $inb 'lane-nil.md')) -and
     (Test-Path (Join-Path $q 'lane-rot.md')) -and
     ((Get-Content (Join-Path $q 'lane-rot.md') -Raw -Encoding UTF8) -match 'rotten')) "exit $cNil :: $outNil"
  Remove-Item $q -Recurse -Force -ErrorAction SilentlyContinue

  # ---------------- -ValidateFile: one file, in isolation, with an exit code ---------
  # The instruction to do this was PROSE in the spawn prompt, and the lanes that skipped
  # it are the ones that broke the batch. These cases make it a step.
  $vbox = Join-Path $tmp 'validate-box'
  New-Item -ItemType Directory -Path $vbox -Force | Out-Null
  $vgood = Join-Path $vbox 'lane-v.md'
  Set-Content $vgood "## a legal finding`n``OPEN`` ``queue-6`` ``2-WAY`` ``RUNG1 MEASURE```n`nbody`n" -Encoding UTF8
  $vsib = Join-Path $vbox 'lane-v-sibling.md'
  Set-Content $vsib "## a sibling's bad finding`n``SHIPPED`` ``queue-6```n`nbody`n" -Encoding UTF8
  $blV = Get-Content $bl -Raw -Encoding UTF8
  $outV = & $PSCommandPath -ValidateFile $vgood -Backlog $bl 2>&1 | Out-String
  $cV = $LASTEXITCODE
  _C 'MUST NOT FIRE' '-ValidateFile on a legal file is exit 0, writes nothing, consumes nothing' `
    ($cV -eq 0 -and $outV -match 'VALIDATE OK' -and (Test-Path $vgood) -and ((Get-Content $bl -Raw -Encoding UTF8) -eq $blV)) "exit $cV :: $outV"
  _C 'CLEAN TWIN' 'a sibling''s malformed file in the same directory does not fail this lane' `
    ($cV -eq 0 -and $outV -notmatch 'sibling' -and (Test-Path $vsib)) "exit $cV :: $outV"

  $outVb = & $PSCommandPath -ValidateFile $vsib -Backlog $bl 2>&1 | Out-String
  $cVb = $LASTEXITCODE
  _C 'MUST FIRE' '-ValidateFile on a malformed file is exit 2 and names the reason' `
    ($cVb -eq 2 -and $outVb -match 'VALIDATE FAILED' -and $outVb -match 'closed vocabulary') "exit $cVb :: $outVb"

  $outVc = & $PSCommandPath -ValidateFile $vgood -InboxDir $vbox -Backlog $bl 2>&1 | Out-String
  $cVc = $LASTEXITCODE
  _C 'MUST FIRE' '-ValidateFile together with -InboxDir is exit 3, never a quiet pass' `
    ($cVc -eq 3 -and $outVc -match 'COULD NOT EVALUATE') "exit $cVc :: $outVc"

  $outVd = & $PSCommandPath -ValidateFile (Join-Path $vbox 'no-such-lane.md') -Backlog $bl 2>&1 | Out-String
  $cVd = $LASTEXITCODE
  _C 'MUST FIRE' '-ValidateFile on a missing path is exit 3, not exit 0' `
    ($cVd -eq 3 -and $outVd -match 'COULD NOT EVALUATE') "exit $cVd :: $outVd"

  $vskip = Join-Path $vbox 'README.md'
  Set-Content $vskip "## a finding hiding in a skipped name`n``OPEN`` ``queue-6`` ``2-WAY`` ``RUNG1 MEASURE```n`nbody`n" -Encoding UTF8
  $outVe = & $PSCommandPath -ValidateFile $vskip -Backlog $bl 2>&1 | Out-String
  $cVe = $LASTEXITCODE
  _C 'MUST FIRE' '-ValidateFile on a skipped name is exit 3, because the merge never reads it' `
    ($cVe -eq 3 -and $outVe -match 'SKIPS README') "exit $cVe :: $outVe"

  Get-ChildItem $inb -Filter *.md | Remove-Item -Force -ErrorAction SilentlyContinue

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
  Set-Content (Join-Path $inb 'lane-f.md') "# a finding written with one hash`n``OPEN`` ``queue-6`` ``2-WAY`` ``RUNG1 MEASURE```n`nbody`n" -Encoding UTF8
  $outP = & $PSCommandPath -InboxDir $inb -Backlog $bl 2>&1 | Out-String
  $cP = $LASTEXITCODE
  _C 'MUST FIRE' 'a one-hash heading WITH a state line under it refuses the merge' ($cP -eq 2 -and $outP -match 'ONE hash') "$cP"

  # MUST NOT FIRE: a plain document TITLE is not a mis-levelled finding. Three of three
  # lanes opened their file with one on 2026-09-08 and all three were refused; a rule
  # broken by everyone who meets it is the defect, not the users.
  Get-ChildItem $inb -Filter *.md | Remove-Item -Force
  Set-Content (Join-Path $inb 'lane-t.md') "# Lane: something, 2026-09-08`n`nSome prose about the lane.`n`n## a real finding`n``OPEN`` ``queue-6`` ``2-WAY`` ``RUNG1 MEASURE```n`nbody`n" -Encoding UTF8
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
  Set-Content (Join-Path $inb 'lane-g.md') "a note from the lane, no heading`n`n## a real finding`n``OPEN`` ``queue-6`` ``2-WAY`` ``RUNG1 MEASURE```n`nbody`n" -Encoding UTF8
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
  Set-Content (Join-Path $inb 'lane-i.md') "## a real finding beside it`n``OPEN`` ``queue-6`` ``2-WAY`` ``RUNG1 MEASURE```n`nbody`n" -Encoding UTF8
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
  Set-Content (Join-Path $inb 'lane-dry.md') "## a finding for the dry run`n``OPEN`` ``queue-6`` ``2-WAY`` ``RUNG1 MEASURE```n`nbody`n" -Encoding UTF8
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

# READ EVERY FILE BEFORE WRITING ANYTHING, AND JUDGE EACH FILE ALONE. A malformed file
# is QUARANTINED and its siblings still merge: nothing it says is appended, so the backlog
# still cannot go red on its account, and the single allocator below still runs once, over
# the accepted set. The whole-batch refusal this replaced blocked three innocent lanes
# three times on 2026-09-11 and 12, every time over a closing `## Nothing else` heading
# with no state line under it.
$findings = @()
$bad = New-Object System.Collections.ArrayList
foreach ($f in $files) {
  try {
    $findings += Read-Inbox $f.FullName
  } catch {
    [void]$bad.Add([pscustomobject]@{ Name = $f.Name; Path = $f.FullName; Reason = $_.Exception.Message })
  }
}

$badNames = @($bad | ForEach-Object { $_.Name })
$accepted = @($files | Where-Object { $badNames -notcontains $_.Name })
if (@($bad).Count -gt 0) {
  $verb = 'QUARANTINED'
  if ($DryRun) { $verb = 'WOULD BE QUARANTINED' }
  Write-Output ("{0} ({1} inbox file(s)) - NOT merged, kept on disk, and this run exits 2:" -f $verb, @($bad).Count)
  foreach ($b in $bad) { Write-Output ("  " + $b.Name + ": " + $b.Reason) }
}

function Move-ToQuarantine {
  <# The bad files, AFTER the accepted ones have landed. They keep their bytes, because
     the lane's work is in them; they MOVE, so an empty inbox still means what it says and
     a re-run does not re-report them forever; and each lands beside a .reason.txt,
     because a reason printed to a console nobody kept is not a retry.
     Returns $true, or $false having said why. #>
  if (@($script:bad).Count -eq 0) { return $true }
  $qdir = Join-Path $InboxDir 'quarantine'
  try {
    if (-not (Test-Path -LiteralPath $qdir)) { New-Item -ItemType Directory -Path $qdir -Force -ErrorAction Stop | Out-Null }
    foreach ($b in $script:bad) {
      $dest = Join-Path $qdir $b.Name
      Move-Item -LiteralPath $b.Path -Destination $dest -Force -ErrorAction Stop  # atomic-replace:allow the destination is a quarantine path nothing reads concurrently, and the source is a drop file its lane has finished with; losing this move to a reader is not a failure mode here
      $note = "QUARANTINED $((Get-Date).ToString('yyyy-MM-dd')) by merge-backlog-inbox.ps1`n`n" + $b.Reason +
              "`n`nThe file itself is UNCHANGED. Fix it, move it back into the inbox, and re-run the merge.`n" +
              "Check it first, in isolation:`n  ops\merge-backlog-inbox.ps1 -ValidateFile <path to the fixed file>`n"
      [IO.File]::WriteAllText(($dest + '.reason.txt'), ($note -replace "`r`n", "`n"), (New-Object Text.UTF8Encoding($false)))
    }
  } catch {
    Write-Output ("COULD NOT EVALUATE - the accepted lanes MERGED, but moving a bad file to quarantine failed: " + $_.Exception.Message)
    Write-Output "That bad file is still in the inbox and its findings have NOT landed. Move it out by hand before the next run."
    return $false
  }
  return $true
}

# An empty landing is a RESULT and is reported by name; it never becomes a backlog item,
# because "this lane found nothing" is not a change anybody rules on. The two counts stay
# separate in the output: a total that folds them together is how a number comes to mean
# nothing.
$empties  = @($findings | Where-Object { $_.Empty })
$findings = @($findings | Where-Object { -not $_.Empty })
foreach ($e in $empties) { Write-Output ("  NOTHING TO FILE declared by " + $e.From) }

$exitCode = 0
if (@($bad).Count -gt 0) { $exitCode = 2 }

if (@($findings).Count -eq 0) {
  if (@($empties).Count -gt 0 -and -not $DryRun) {
    # Consume them, so a lane that landed with nothing is not re-reported forever.
    # ONLY THE ACCEPTED ONES: a quarantined file has landed nowhere, and deleting it
    # would be the silent loss this whole tool exists to prevent.
    foreach ($f in $accepted) { Remove-Item -LiteralPath $f.FullName -Force }
    Write-Output ("no findings to merge; {0} lane(s) declared NOTHING TO FILE and were consumed." -f @($empties).Count)
  } else {
    Write-Output "inbox holds $(@($accepted).Count) accepted file(s) and no findings. Nothing to merge."
  }
  if (-not $DryRun) {
    $moved = Move-ToQuarantine
    if (-not $moved) {
      Write-Output 'MERGE-BACKLOG-INBOX-COMPLETE'
      exit 3
    }
  }
  Write-Output ("VERDICT: merged 0 finding(s), quarantined {0} file(s). Exit {1}." -f @($bad).Count, $exitCode)
  Write-Output 'MERGE-BACKLOG-INBOX-COMPLETE'
  exit $exitCode
}

$text = Get-Content -LiteralPath $Backlog -Raw -Encoding UTF8
$next = Get-NextId $text

Write-Output ("MERGING {0} finding(s) from {1} inbox file(s), ids I{2} onward:" -f `
  @($findings).Count, @($accepted).Count, $next)
$block = New-Object System.Text.StringBuilder
$i = $next
foreach ($f in $findings) {
  $tag = if ($f.Tag) { " ``$($f.Tag)``" } else { '' }
  Write-Output ("  I{0,-4} {1,-58} <- {2}" -f $i, $f.Title.Substring(0, [Math]::Min(58, $f.Title.Length)), $f.From)
  # LF EXPLICITLY, never AppendLine. `[FIXED 2026-09-08, measured.]` AppendLine emits
  # [Environment]::NewLine, which is CRLF on this box, and the backlog is an LF file. The
  # first real merge put 75 CRLF into 5,927 LF and NOTHING IN THIS SCRIPT NOTICED - git
  # normalises on the way in, so the commit was clean and `git diff` showed nothing. That is
  # the estate's own crlf-flip-is-invisible-in-git-diff trap, arriving through a writer.
  [void]$block.Append("`n")
  [void]$block.Append("### I$i - $($f.Title) ``$($f.State)``$tag`n")
  [void]$block.Append("`n")
  [void]$block.Append("**Merged from ``design\backlog-inbox\$($f.From)`` on $((Get-Date).ToString('yyyy-MM-dd')).** Written by a course agent during a parallel run; ids are allocated here because this is the only writer.`n")
  [void]$block.Append("`n")
  [void]$block.Append("$($f.Body)`n")
  $i++
}

if ($DryRun) {
  Write-Output ''
  Write-Output "-DryRun: nothing written, inbox untouched, nothing quarantined."
  Write-Output ("VERDICT: {0} finding(s) would merge, {1} file(s) would be quarantined. Exit {2}." -f @($findings).Count, @($bad).Count, $exitCode)
  Write-Output 'MERGE-BACKLOG-INBOX-COMPLETE'
  exit $exitCode
}

# NOT Add-Content: it appends [Environment]::NewLine after the value on top of whatever the
# value already ends with. AppendAllText writes exactly the bytes given, and the explicit
# UTF8Encoding($false) is the no-BOM form the workspace CLAUDE.md prescribes.
[IO.File]::AppendAllText($Backlog, $block.ToString(), (New-Object Text.UTF8Encoding($false)))
# The inbox is emptied only after a successful append, so a crash re-runs cleanly
# rather than losing the findings - the failure this whole script exists for. ONLY THE
# ACCEPTED FILES: a quarantined file has landed nowhere and is never deleted.
foreach ($f in $accepted) { Remove-Item -LiteralPath $f.FullName -Force }

$moved = Move-ToQuarantine
if (-not $moved) {
  Write-Output 'MERGE-BACKLOG-INBOX-COMPLETE'
  exit 3
}

Write-Output ''
$emptyNote = if (@($empties).Count -gt 0) { ", plus {0} lane(s) declaring NOTHING TO FILE" -f @($empties).Count } else { '' }
Write-Output ("merged {0} finding(s){1}. Run ops\audit-backlog-status.ps1 to confirm the states." -f @($findings).Count, $emptyNote)
if (@($bad).Count -gt 0) {
  Write-Output ("{0} inbox file(s) were QUARANTINED into {1} and were NOT merged. Fix each one, move it back, and re-run." -f @($bad).Count, (Join-Path $InboxDir 'quarantine'))
}
Write-Output ("VERDICT: merged {0} finding(s) from {1} file(s), quarantined {2} file(s). Exit {3}." -f @($findings).Count, @($accepted).Count, @($bad).Count, $exitCode)
Write-Output 'MERGE-BACKLOG-INBOX-COMPLETE'
exit $exitCode
