<#
  drain-staged.ps1 - put an AGENT in front of a publish, so staging works when nobody is watching.

  WHY THIS EXISTS (2026-09-06, backlog E1). The staging gate queues a mutating Ghost call instead of
  sending it, and something has to approve the queue. Until now that something was a person running
  ops\review-staged.ps1 -Apply, which is fine at a keyboard and useless at 07:00 - an unattended run
  would stage its writes and the board would simply stop updating. That is why staging could not be
  armed globally, and it is the whole of what this file fixes.

  IT IS ALSO WHAT E1 ACTUALLY ASKED FOR. The entry's complaint is that post-publish-reviewer "runs
  after the irreversible step, which is the wrong side of it". This runs the same reviewer on the same
  work, BEFORE the PUT goes out, against a queue that describes exactly what is about to ship.

  THE REVIEWER SEES THE SET, WHICH IS THE ARGUMENT FOR STAGING OVER AN UNDO LOG. It is handed every
  queued call plus Get-TcQueueConcerns' set-level findings - two calls on one uri, a queued DELETE, a
  queue spanning several scripts. Nothing at the level of one call can see those, and today's stale-feed
  incident (the board republished, the feed not, 583 recipe pages quoting a four-day-old week for four
  and a half hours) is exactly the shape a human or an agent looking at the whole set would question.

  A REFUSAL LEAVES THE QUEUE INTACT. Nothing is discarded on a NO-GO: the calls stay queued, the run
  reports, and a person decides. Discarding on a verdict would make this the fastest way to lose a
  publish nobody meant to cancel.

  Usage:
    powershell -File ops\drain-staged.ps1                  # review and, on GO, apply
    powershell -File ops\drain-staged.ps1 -WhatIf          # review and report, never apply
    powershell -File ops\drain-staged.ps1 -Queue <path>

  EXIT CODES (lib\guard-contract.ps1 vocabulary): 0 applied or nothing queued, 2 held, 3 could-not-run.
  Read the verdict LINE, not the number (backlog E2).
#>
param(
  [string]$Queue = '',
  [switch]$WhatIf,
  [string]$DispatchCommand = '',   # self-test injection point; empty means the real adapter
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\ops' }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $repo 'lib\ghost-lib.ps1')

function Get-TcDrainVerdict {
  <# Read a GO/NO-GO out of the reviewer's reply. PURE, and deliberately strict in one direction.

     ANYTHING THAT IS NOT AN EXPLICIT GO IS A HOLD. A missing verdict, an unparseable reply, an empty
     string, a timeout - all hold. The asymmetry is the point: the cost of holding a good publish is
     that somebody runs a command; the cost of applying on a reply nobody understood is a wrong page on
     a live paid site. This is the same rule the wave auditor already follows, where only exit 0 with
     its completion line is a clean bill. #>
  param([string]$Reply)
  if (-not $Reply) { return ([pscustomobject]@{ Go = $false; Why = 'the reviewer returned nothing' }) }
  $t = [string]$Reply
  if ($t -cmatch '(?m)^\s*NO-?GO\b' -or $t -match '(?i)\bNO-?GO\b') {
    return ([pscustomobject]@{ Go = $false; Why = 'the reviewer returned NO-GO' })
  }
  if ($t -cmatch '\bGO\b') {
    return ([pscustomobject]@{ Go = $true; Why = 'the reviewer returned GO' })
  }
  return ([pscustomobject]@{ Go = $false; Why = 'no GO or NO-GO in the reply - held, because anything that is not an explicit GO is a hold' })
}

function New-TcDrainBrief {
  <# What the reviewer is shown. It gets the CALLS and the SET-LEVEL concerns, because the set is the
     thing only staging can show it. #>
  param([object[]]$Entries, [string[]]$Concerns)
  $b = New-Object System.Collections.Generic.List[string]
  [void]$b.Add('You are reviewing writes that are QUEUED and have NOT been sent. This is a pre-publish review.')
  [void]$b.Add('')
  [void]$b.Add(('There are {0} queued call(s):' -f @($Entries).Count))
  foreach ($e in @($Entries)) {
    [void]$b.Add(("  [{0}] {1} {2}   from {3}" -f $e.id, $e.method, $e.uri, $(if ($e.caller) { $e.caller } else { '(caller unknown)' })))
    if ($e.body) {
      $s = [string]$e.body
      [void]$b.Add(("        body: {0}" -f $(if ($s.Length -gt 400) { $s.Substring(0, 400) + ' ...' } else { $s })))
    }
  }
  if (@($Concerns).Count) {
    [void]$b.Add('')
    [void]$b.Add('CONCERNS ACROSS THE SET (a per-call check cannot see these):')
    foreach ($c in @($Concerns)) { [void]$b.Add('  ! ' + $c) }
  }
  [void]$b.Add('')
  [void]$b.Add('Answer with GO on its own line to send these, or NO-GO followed by what is wrong.')
  [void]$b.Add('Anything else is treated as a HOLD and nothing is sent.')
  return ($b -join "`n")
}

# ------------------------------------------------------------------------------------- self-test
if ($SelfTest) {
  $f = 0
  function T($m, $cond, $got) { if ($cond) { Write-Output ("ok    " + $m) } else { Write-Output ("FAIL  " + $m + "   got: " + $got); $script:f++ } }

  T 'MUST FIRE  a plain GO applies' ((Get-TcDrainVerdict 'GO').Go -eq $true) (Get-TcDrainVerdict 'GO').Why
  T 'MUST FIRE  NO-GO holds' ((Get-TcDrainVerdict 'NO-GO: the feed was not republished').Go -eq $false) (Get-TcDrainVerdict 'NO-GO: x').Why
  T 'MUST FIRE  NOGO without the hyphen holds' ((Get-TcDrainVerdict 'NOGO because x').Go -eq $false) (Get-TcDrainVerdict 'NOGO because x').Why
  # THE ASYMMETRY. Holding a good publish costs a command; applying on a reply nobody understood costs
  # a wrong page on a live paid site.
  T 'MUST FIRE  an empty reply HOLDS, it does not apply' ((Get-TcDrainVerdict '').Go -eq $false) (Get-TcDrainVerdict '').Why
  T 'MUST FIRE  a reply with no verdict at all HOLDS' ((Get-TcDrainVerdict 'I looked at the pages and they seem fine').Go -eq $false) (Get-TcDrainVerdict 'I looked...').Why
  T 'MUST FIRE  a NO-GO that also contains the word GO still holds' ((Get-TcDrainVerdict 'NO-GO - do not GO ahead').Go -eq $false) (Get-TcDrainVerdict 'NO-GO - do not GO ahead').Why

  $ents = @([pscustomobject]@{ id = 'a1'; method = 'PUT'; uri = 'https://h/posts/x/'; caller = 'wave-publish.ps1'; body = '{"posts":[{"title":"t"}]}' })
  $brief = New-TcDrainBrief -Entries $ents -Concerns @('2 calls target the same uri')
  T 'the brief names the call, its caller and the set-level concern' `
    ($brief -like '*PUT*' -and $brief -like '*wave-publish.ps1*' -and $brief -like '*same uri*') $brief.Substring(0, 120)
  T 'MUST FIRE  the brief says explicitly that nothing has been sent yet' ($brief -like '*have NOT been sent*') 'the reviewer could mistake this for a post-publish review'
  T 'the brief tells the reviewer that anything but GO is a hold' ($brief -like '*treated as a HOLD*') 'missing'

  if ($f) { Write-Output ("SELF-TEST FAIL: {0} check(s)" -f $f); exit 1 }
  Write-Output 'SELF-TEST PASS: six verdict cases including the three that must HOLD, and the brief carrying the calls, the set concerns and the not-yet-sent statement'
  exit 0
}

# ------------------------------------------------------------------------------------- live run
if (-not $Queue) { $Queue = $(if ($env:TC_STAGE_WRITES) { $env:TC_STAGE_WRITES } else { Join-Path $repo 'ops\staged-writes.jsonl' }) }
if (-not (Test-Path -LiteralPath $Queue)) {
  Write-Output ("drain-staged: nothing queued ({0}). An armed run that wrote nothing is a normal result." -f $Queue)
  Write-GuardComplete -Name 'drain-staged' -Summary 'queued=0'
  exit 0
}
$lines = @([IO.File]::ReadAllLines($Queue))
$entries = @(); $bad = 0
$n = 0
foreach ($l in $lines) { $n++; if (-not $l.Trim()) { continue }; try { $entries += ($l | ConvertFrom-Json) } catch { $bad++ } }
if ($bad) {
  Write-Output ("DRAIN-STAGED COULD NOT RUN: {0} queue line(s) will not parse. Some intended write is invisible to the reviewer, so approving now would send an unknown subset." -f $bad)
  Write-GuardComplete -Name 'drain-staged' -Summary ("blind=badlines-" + $bad)
  exit 3
}
$entries = @($entries)
if (-not $entries.Count) {
  Write-Output 'drain-staged: the queue file exists but holds no calls.'
  Write-GuardComplete -Name 'drain-staged' -Summary 'queued=0'
  exit 0
}

$concerns = Get-TcQueueConcerns -Entries $entries
$concerns = @($concerns)
$brief = New-TcDrainBrief -Entries $entries -Concerns $concerns
$briefFile = Join-Path ([IO.Path]::GetTempPath()) ("tc-drain-" + [guid]::NewGuid().ToString('N').Substring(0, 8) + ".txt")
[IO.File]::WriteAllText($briefFile, $brief, (New-Object System.Text.UTF8Encoding($false)))

Write-Output ("drain-staged: {0} queued call(s), {1} set-level concern(s) - dispatching post-publish-reviewer BEFORE the publish" -f $entries.Count, $concerns.Count)
try {
  if ($DispatchCommand) {
    $reply = & powershell -NoProfile -ExecutionPolicy Bypass -Command $DispatchCommand
  } else {
    # The one road a judgment call takes in this estate: the agent, its model, its effort and its tool
    # list all come from .claude\agents\post-publish-reviewer.md and from nowhere else.
    $py = 'C:\Codex\Python312\python.exe'
    $reply = & $py (Join-Path $repo 'meal-prep\pipeline\hunt_dispatch.py') --agent post-publish-reviewer --prompt-file $briefFile
  }
  $reply = (@($reply) -join "`n")
} catch {
  Write-Output ("DRAIN-STAGED COULD NOT RUN: the reviewer dispatch failed ({0}). The queue is untouched." -f $_.Exception.Message)
  Write-GuardComplete -Name 'drain-staged' -Summary 'blind=dispatch-failed'
  exit 3
} finally { if (Test-Path -LiteralPath $briefFile) { Remove-Item -LiteralPath $briefFile -Force } }

$v = Get-TcDrainVerdict $reply
if (-not $v.Go) {
  Write-Output ("drain-staged: HELD - {0}. The queue is LEFT IN PLACE and nothing was sent; read it with ops\review-staged.ps1 and apply or discard by hand." -f $v.Why)
  Write-GuardComplete -Name 'drain-staged' -Summary ("held=" + $entries.Count)
  exit 2
}
if ($WhatIf) {
  Write-Output ("drain-staged: WOULD APPLY {0} call(s) - the reviewer returned GO, and -WhatIf means nothing was sent." -f $entries.Count)
  Write-GuardComplete -Name 'drain-staged' -Summary 'whatif=1'
  exit 0
}
Write-Output 'drain-staged: GO - applying the queue.'
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'ops\review-staged.ps1') -Queue $Queue -Apply
$rc = $LASTEXITCODE
Write-GuardComplete -Name 'drain-staged' -Summary ("applied=" + $entries.Count + " rc=" + $rc)
exit $rc
