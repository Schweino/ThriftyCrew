<#
  audit-task-registration.ps1 - a scheduled task may not be registered unwatched.

  SCOPE OF A CLEAN REPORT: UNSOUND. This is a pattern matcher over PowerShell source, so it finds
    the spellings it knows: a `Register-ScheduledTask` call whose `-TaskName` is a literal or a
    variable assigned a literal in the same file. A registrar that builds its task name from a
    config file, a loop variable or string arithmetic is INVISIBLE here and reports nothing. So a
    reported finding is real, and a clean report proves only that no registrar it can read is
    unwatched. The runtime backstop is health-heartbeat.ps1's TASK UNWATCHED and REGISTRY DRIFT
    lines, and neither is replaced by this.

  WHY THIS EXISTS (2026-09-09, queue 2026-09-09-d3e937). On 2026-09-08 the 21:30 graph nightly never
  started: Windows Update restarted the box three times between 20:29 and 20:33, nobody signed in
  until 03:29, and the task runs as an InteractiveToken, so the occurrence had no session and was
  counted missed. That is the surface. The CLASS underneath it is that task registration and task
  watching are two hand-maintained tables with nothing joining them at change time:

    * four registrars - graph\pipeline\install-nightly-task.ps1,
      meal-prep\pipeline\install-harvest-task.ps1, media\reels\install-daily-task.ps1 and
      ops\install-grocery-tasks.ps1
    * grocery\expected-automations.json, which health-heartbeat reads to notice silent death
    * ops\scheduled-tasks\*.xml, a third copy, which three gates read as the truth

  TC Graph Nightly Matching was registered on 2026-08-22 and reached the registry on 2026-08-25, so
  it was unwatched for three mornings. TC Recipe Harvest Crawl was registered on 2026-08-24 and
  hand-added later, the same way. In both cases the only thing that noticed was health-heartbeat
  printing TASK UNWATCHED the NEXT MORNING - an alarm whose only follower is a human typing an entry,
  which is the shape this estate has resolved not to rely on. The change-time join that existed,
  ops\install-grocery-tasks.ps1's Test-RegistryAgrees, covered the THREE tasks that file owns and
  therefore missed exactly the two that were hurt. That gate is now widened to every committed
  definition; this file closes the other end, so a registrar cannot introduce an unwatched task at
  all.

  WHAT IT CHECKS, per Register-ScheduledTask call site whose task name it can resolve:
    1. the name has a committed definition in ops\scheduled-tasks\*.xml
    2. the name has a windows_tasks entry in grocery\expected-automations.json
    3. the registrar carries the refuse-if-unwatched call, so it cannot register an unwatched task
       even on a box whose registry row was deleted

  Check 3 is scoped to registrars that name a task LITERALLY. ops\install-grocery-tasks.ps1 registers
  from committed XML under names held in its own $OWNED table and checks every one of those names
  against the registry on every push through Test-RegistryAgrees, which is a stronger guarantee than
  a refusal at install time; it is allowlisted below with that reason rather than special-cased in
  the logic.

  IT IS HERMETIC. It reads committed files only - no Get-ScheduledTask, no registry, no network - so
  it belongs in ops\run-gates.ps1's $static list rather than in the daily chain. That is the split
  run-gates' own header draws: hermetic detectors gate the push, data-dependent audits run against a
  real board. (ops\install-grocery-tasks.ps1's -Verify stays out of run-gates for the opposite
  reason: it reads the live scheduler.)

  EXIT CODES (lib\guard-contract.ps1 vocabulary): 0 clean, 2 hard finding, 3 could-not-evaluate.
  Read the verdict LINE, not the number.

  Self-test: powershell -File ops\audit-task-registration.ps1 -SelfTest
#>
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop (2026-09-07)
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\ops' }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')

$XMLDIR   = Join-Path $repo 'ops\scheduled-tasks'
$REGISTRY = Join-Path $repo 'grocery\expected-automations.json'

# Registrars whose call site is deliberately not held to one of the rules above. EVERY ENTRY CARRIES
# ITS REASON, because an allowlist without one is indistinguishable from a bug somebody hid.
$script:ALLOW_NO_DEFINITION = @{
  'media\reels\install-daily-task.ps1' =
    'registers "SMP Daily Facebook Reel", a RETIRED task from the pre-rebrand SMP era. It is not on the live scheduler, has no committed definition and no registry row, and Brad''s 2026-08-22 three-task rule is what retired it. Deleting this registrar is a separate decision and not this item, so it is named here rather than made to pass.'
}
$script:ALLOW_NO_REFUSAL = @{
  'ops\install-grocery-tasks.ps1' =
    'registers from committed XML under the names in its own $OWNED table, so it names no task literally. Its Test-RegistryAgrees checks every one of those names - and now every committed definition - against grocery\expected-automations.json on every push, which is a stronger guarantee than a refusal at install time.'
  'ops\install-ops-tasks.ps1' =
    'the ops-lane registrar, added 2026-09-09 for TC Sidecar Watchdog. Same shape as the grocery one directly above - it registers from committed XML under the names in its own $OWNED table, so this parser cannot resolve $o.Name to a literal - but it is held to MORE than that file, not less: it DOES carry Test-TaskWatched and calls it for every owned task BEFORE any scheduler call, so a partial install cannot leave one task registered and unwatched. Its own self-test additionally asserts each owned name against the committed XML <URI>, which is the mismatch a refusal keyed on the table would miss. This entry exempts the unresolvable NAME, never the refusal.'
  'media\reels\install-daily-task.ps1' =
    'the retired SMP registrar above. Adding a refusal to a script nobody should run is work spent on a file that is going away.'
}

function Get-RegistrarCallSites {
  <# Every Register-ScheduledTask call site in $Source, with the task name resolved where possible.

     Returns a list of @{ Line; NameToken; Name; Resolved }. `Name` is the literal task name; when
     -TaskName is a variable, its assignment is looked up in the SAME source and used. A name this
     cannot resolve comes back Resolved=$false rather than being dropped: "no name" and "no call
     site" are different states and collapsing them is how a detector reports clean on a file it
     could not read.

     PURE over the string, so the frozen fixtures below drive the same parser the live scan uses. #>
  param([Parameter(Mandatory=$true)][string]$Source)
  $out = New-Object System.Collections.Generic.List[object]
  # THE VERB IS BUILT, NOT WRITTEN OUT. A detector that scans the tree scans itself unless excluded,
  # and this estate has been bitten by a self-test whose check line was its own match. The exclusion
  # below is belt; this is braces.
  $verb = 'Register-Scheduled' + 'Task'
  # CASE-SENSITIVE, WITH A LOOKBEHIND, because `Unregister-ScheduledTask` CONTAINS this verb.
  # PowerShell's -match is case-INSENSITIVE by default, so the first version of this read every
  # `Unregister-ScheduledTask -TaskName $x` line in the tree as a registration, failed to parse it
  # (the case-sensitive [regex]::Match did not agree), and reported both real registrars as
  # "could not be resolved". Found by this file's own live fixture on 2026-09-09. An uninstall path
  # is not a registration and must never be judged as one.
  $anchor = '(?<![A-Za-z])' + [regex]::Escape($verb)
  # BLOCK COMMENTS ARE STRIPPED FIRST, and this estate has already paid for not doing it:
  # ops\audit-task-registry.ps1's header records run-gates enrolling that wrapper as a self-test
  # because its <# #> prose quoted the discovery token. The same shape bit this file on the day it
  # was written - ops\audit-run-log-claims.ps1 describes the rejected "grep every
  # Register-ScheduledTask" design in its header, and the first live run read that sentence as a call
  # site it could not parse. Prose about a verb is not a use of it.
  $clean = [regex]::Replace($Source, '(?s)<#.*?#>', '')
  foreach ($raw in ($clean -split "`n")) {
    $line = [string]$raw
    # skip line comments too, the way audit-git-sweepers skips its own fixture rows
    if ($line -match '^\s*#') { continue }
    if (-not [regex]::IsMatch($line, $anchor)) { continue }
    $m = [regex]::Match($line, $anchor + '\s+-TaskName\s+(\$?[A-Za-z_][A-Za-z0-9_]*|''[^'']+''|"[^"]+")')
    if (-not $m.Success) {
      [void]$out.Add([pscustomobject]@{ Line = $line.Trim(); NameToken = ''; Name = ''; Resolved = $false })
      continue
    }
    $tok = $m.Groups[1].Value
    $name = ''
    if ($tok -match "^'(.*)'$" -or $tok -match '^"(.*)"$') {
      $name = $matches[1]
    } elseif ($tok -match '^\$([A-Za-z_][A-Za-z0-9_]*)$') {
      $var = $matches[1]
      $a = [regex]::Match($Source, '(?m)^\s*\$' + [regex]::Escape($var) + "\s*=\s*'([^']+)'")
      if ($a.Success) { $name = $a.Groups[1].Value }
    }
    [void]$out.Add([pscustomobject]@{ Line = $line.Trim(); NameToken = $tok; Name = $name
                                      Resolved = [bool]$name })
  }
  return ,$out
}

function Test-RegistrarWatched {
  <# The judgement, pure. Returns a list of finding strings; empty means this registrar is clean.

     $Rel is the repo-relative path (used for the allowlists), $Source its text, $Definitions the
     task names with a committed XML, $RegistryNames the names in windows_tasks. #>
  param([Parameter(Mandatory=$true)][string]$Rel,
        [Parameter(Mandatory=$true)][string]$Source,
        [Parameter(Mandatory=$true)]$Definitions,
        [Parameter(Mandatory=$true)]$RegistryNames,
        $AllowNoDefinition = @{}, $AllowNoRefusal = @{})
  $findings = @()
  $sites = Get-RegistrarCallSites -Source $Source
  if (-not $sites.Count) { return ,$findings }

  $defs = @($Definitions | ForEach-Object { [string]$_ })
  $regs = @($RegistryNames | ForEach-Object { [string]$_ })
  $literal = $false

  foreach ($s in $sites) {
    if (-not $s.Resolved) {
      if (-not $AllowNoDefinition.ContainsKey($Rel) -and -not $AllowNoRefusal.ContainsKey($Rel)) {
        $findings += ("{0}: a Register call whose -TaskName ({1}) could not be resolved to a literal, so whether it is watched is UNKNOWN. Unreadable is not watched - name the task literally or allowlist the file with a reason." -f $Rel, $(if ($s.NameToken) { $s.NameToken } else { '<unparsed>' }))
      }
      continue
    }
    $literal = $true
    if ($AllowNoDefinition.ContainsKey($Rel)) { continue }
    if ($defs -notcontains $s.Name) {
      $findings += ("{0}: registers '{1}' and there is no committed definition for it in ops\scheduled-tasks - nothing static can read what this task actually runs" -f $Rel, $s.Name)
    }
    if ($regs -notcontains $s.Name) {
      $findings += ("{0}: registers '{1}' and grocery\expected-automations.json does not name it - the task would be UNWATCHED from birth, exactly as TC Graph Nightly Matching was for three mornings from 2026-08-22" -f $Rel, $s.Name)
    }
  }

  # The refusal, so a registrar cannot create the unwatched state even where this static gate is not
  # looking. Needle built by concatenation.
  if ($literal -and -not $AllowNoRefusal.ContainsKey($Rel)) {
    $needle = 'Test-Task' + 'Watched -TaskName'
    if (-not $Source.Contains($needle)) {
      $findings += ("{0}: names a task literally and carries no refuse-if-unwatched check, so it can register a task nothing watches on a box whose registry row was deleted" -f $Rel)
    }
  }
  return ,$findings
}

if ($SelfTest) {
  $fail = 0
  $ran = 0
  function T($n, $c, $g = '') {
    $script:ran++
    if ($c) { Write-Output ("ok    " + $n) } else { Write-Output ("FAIL  " + $n + "   got: " + $g); $script:fail++ }
  }

  # EVERY FIXTURE NEEDLE IS BUILT BY CONCATENATION, so this detector cannot match its own source and
  # score itself green. That failure mode has cost this estate real time twice.
  $V = 'Register-Scheduled' + 'Task'
  $REF = 'Test-Task' + 'Watched -TaskName $x -Registry $d'

  # ---- the parser -------------------------------------------------------------------------------
  $srcLiteral = ($V + " -TaskName 'TC Fixture Task' -Action `$a -Force")
  $p = Get-RegistrarCallSites -Source $srcLiteral
  T 'a literal -TaskName is read straight off the call site' ($p.Count -eq 1 -and $p[0].Name -eq 'TC Fixture Task') (($p | ForEach-Object { $_.Name }) -join ',')

  $srcVar = "`$taskName = 'TC Fixture Task'`n" + $V + ' -TaskName $taskName -Action $a -Force'
  $p2 = Get-RegistrarCallSites -Source $srcVar
  T 'a -TaskName held in a variable is resolved from its assignment in the same file' `
    ($p2.Count -eq 1 -and $p2[0].Name -eq 'TC Fixture Task') (($p2 | ForEach-Object { $_.Name }) -join ',')

  $srcUnres = $V + ' -TaskName $target -Xml $xml -Force'
  $p3 = Get-RegistrarCallSites -Source $srcUnres
  T 'MUST FIRE  a name that cannot be resolved is reported as unresolved, never dropped' `
    ($p3.Count -eq 1 -and -not $p3[0].Resolved) ([string]$p3.Count)

  $srcComment = '# ' + $V + " -TaskName 'TC Commented Out'"
  $p4 = Get-RegistrarCallSites -Source $srcComment
  T 'MUST NOT FIRE a commented-out call is not a call site' ($p4.Count -eq 0) ([string]$p4.Count)

  # MUST NOT FIRE, AND IT IS A REAL LINE IN THIS TREE: an UNINSTALL path. Every registrar here has
  # one, and `Unregister-ScheduledTask` CONTAINS this detector's verb. PowerShell's -match is
  # case-insensitive, so the first version of this parser read all four uninstall paths as
  # registrations it then could not parse, and reported both real registrars UNKNOWN. Frozen from the
  # line that caught it.
  $srcUninstall = 'Un' + 'register-ScheduledTask' + ' -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue'
  $p5 = Get-RegistrarCallSites -Source $srcUninstall
  T 'MUST NOT FIRE an Unregister call is not a registration, though it contains the verb' ($p5.Count -eq 0) ([string]$p5.Count)

  # MUST NOT FIRE, FROZEN FROM ops\audit-run-log-claims.ps1's REAL HEADER SENTENCE. That file's block
  # comment describes the rejected "grep every Register-ScheduledTask" design, and the first version
  # of this detector read that sentence as a call site. Prose about a verb is not a use of it, and
  # this estate has been bitten by the same block-comment blindness in run-gates' self-test discovery.
  $srcProse = "<#`n  E29 rejected the obvious detector - grep -WindowStyle Hidden out of every " + $V + "`n  and require the target to dot-source the library.`n#>`nWrite-Output 'hi'"
  $p6 = Get-RegistrarCallSites -Source $srcProse
  T 'MUST NOT FIRE the verb quoted inside a <# block comment #> is prose, not a call site' ($p6.Count -eq 0) ([string]$p6.Count)
  # CLEAN TWIN: a real call BELOW a block comment that mentions the verb is still found. Stripping
  # comments must not eat the code after them.
  $srcBoth = $srcProse + "`n`$taskName = 'TC Fixture Task'`n" + $V + ' -TaskName $taskName -Action $a -Force'
  $p7 = Get-RegistrarCallSites -Source $srcBoth
  T 'CLEAN TWIN a real call site below that block comment is still found' `
    ($p7.Count -eq 1 -and $p7[0].Name -eq 'TC Fixture Task') (($p7 | ForEach-Object { $_.Name }) -join ',')

  # ---- the judgement, frozen from the real 2026-08-22 state --------------------------------------
  # MUST FIRE (fixture c): a registrar that names a task with no committed definition and no registry
  # entry. This is the exact state TC Graph Nightly Matching was in on 2026-08-22, generalised.
  $fixtureSrc = "`$taskName = 'TC Fixture Task'`n" + $V + ' -TaskName $taskName -Action $a -Force'
  $f1 = Test-RegistrarWatched -Rel 'fixture\install-fixture-task.ps1' -Source $fixtureSrc `
          -Definitions @('TC Grocery Ad Pulls 0700') -RegistryNames @('TC Grocery Ad Pulls 0700')
  T 'MUST FIRE  a registrar with no committed definition is a finding that NAMES the task' `
    ((($f1 -join ' ') -like '*TC Fixture Task*') -and (($f1 -join ' ') -like '*no committed definition*')) ($f1 -join '; ')
  T 'MUST FIRE  and the same registrar is reported UNWATCHED against the registry' `
    ((($f1 -join ' ') -like '*UNWATCHED*')) ($f1 -join '; ')
  T 'MUST FIRE  and its missing refusal is the third finding' `
    ((($f1 -join ' ') -like '*refuse-if-unwatched*')) ($f1 -join '; ')

  # MUST NOT FIRE: the same registrar once the definition, the registry row and the refusal exist.
  # Zero findings, or the gate is red the day after it is fixed and gets switched off.
  $goodSrc = "`$taskName = 'TC Fixture Task'`n`$r = " + $REF + "`n" + $V + ' -TaskName $taskName -Action $a -Force'
  $f2 = Test-RegistrarWatched -Rel 'fixture\install-fixture-task.ps1' -Source $goodSrc `
          -Definitions @('TC Fixture Task') -RegistryNames @('TC Fixture Task')
  T 'MUST NOT FIRE a registrar with a definition, a registry row and a refusal is silent' ($f2.Count -eq 0) ($f2 -join '; ')

  # MUST FIRE: watched and defined, but no refusal. The state install-nightly-task.ps1 was in until
  # today - it could have re-registered onto a box whose registry row had been removed.
  $noRefusal = "`$taskName = 'TC Fixture Task'`n" + $V + ' -TaskName $taskName -Action $a -Force'
  $f3 = Test-RegistrarWatched -Rel 'fixture\install-fixture-task.ps1' -Source $noRefusal `
          -Definitions @('TC Fixture Task') -RegistryNames @('TC Fixture Task')
  T 'MUST FIRE  a watched, defined registrar with NO refusal is still a finding' `
    ($f3.Count -eq 1 -and (($f3 -join ' ') -like '*refuse-if-unwatched*')) ($f3 -join '; ')

  # MUST NOT FIRE: the allowlists, each entry with its reason. A retired registrar is named, not made
  # to pass by weakening the rule.
  $f4 = Test-RegistrarWatched -Rel 'media\reels\install-daily-task.ps1' -Source $noRefusal `
          -Definitions @() -RegistryNames @() `
          -AllowNoDefinition @{ 'media\reels\install-daily-task.ps1' = 'retired SMP task' } `
          -AllowNoRefusal @{ 'media\reels\install-daily-task.ps1' = 'retired SMP task' }
  T 'MUST NOT FIRE an allowlisted registrar with its reason is silent' ($f4.Count -eq 0) ($f4 -join '; ')

  # MUST FIRE: an unresolved name in a file that is NOT allowlisted. "Could not read it" must never
  # settle the question.
  $f5 = Test-RegistrarWatched -Rel 'fixture\install-dynamic.ps1' -Source $srcUnres `
          -Definitions @('TC Fixture Task') -RegistryNames @('TC Fixture Task')
  T 'MUST FIRE  an unresolvable task name is UNKNOWN, and unknown is a finding' `
    ($f5.Count -eq 1 -and (($f5 -join ' ') -like '*UNKNOWN*')) ($f5 -join '; ')

  # MUST NOT FIRE: a file with no call site at all is none of this gate's business.
  $f6 = Test-RegistrarWatched -Rel 'ops\something-else.ps1' -Source 'Write-Output "hello"' `
          -Definitions @() -RegistryNames @()
  T 'MUST NOT FIRE a file that registers nothing produces no findings' ($f6.Count -eq 0) ($f6 -join '; ')

  # ---- MUST NOT FIRE against the REAL tree. The half a frozen fixture cannot prove: that the four
  #      registrars shipped in this tree today are each defined, watched and refusing.
  $liveDefs = @()
  if (Test-Path $XMLDIR) {
    $xmlFiles = @(Get-ChildItem -Path $XMLDIR -Filter '*.xml' -File -ErrorAction SilentlyContinue)
    foreach ($xf in $xmlFiles) {
      $mm = [regex]::Match([IO.File]::ReadAllText($xf.FullName), '<URI>(.*?)</URI>', 'Singleline')
      if ($mm.Success) { $liveDefs += $mm.Groups[1].Value.Trim().TrimStart('\') }
    }
  }
  $liveRegs = @()
  if (Test-Path $REGISTRY) {
    $rd = [IO.File]::ReadAllText($REGISTRY) | ConvertFrom-Json
    foreach ($row in @($rd.windows_tasks)) { if ($row -and $row.name) { $liveRegs += [string]$row.name } }
  }
  # THE ASSERTION IS THAT THE TWO TABLES AGREE, NOT THAT THERE ARE FIVE OF THEM.
  # `[CORRECTED 2026-09-09]` This read `-eq 5 -and -eq 5` and went red the first time a
  # sixth task was legitimately added (TC Sidecar Watchdog, ops lane). A frozen count is
  # the weaker assertion in both directions: it fails on correct work, which teaches
  # people to edit the fixture, and it would PASS a tree with five definitions and five
  # watch rows naming five different tasks - which is precisely the unwatched-task state
  # this whole file exists to make impossible. Set equality cannot be satisfied that way,
  # and it never needs editing when a task is added properly.
  $onlyDefs = @($liveDefs | Where-Object { $liveRegs -notcontains $_ })
  $onlyRegs = @($liveRegs | Where-Object { $liveDefs -notcontains $_ })
  T 'every committed definition is watched, and every watched task has a definition' `
    ($liveDefs.Count -gt 0 -and $onlyDefs.Count -eq 0 -and $onlyRegs.Count -eq 0) `
    ("defs=" + $liveDefs.Count + " regs=" + $liveRegs.Count +
     " unwatched=[" + ($onlyDefs -join ',') + "] undefined=[" + ($onlyRegs -join ',') + "]")
  # AND THE FLOOR, because the check above is vacuously true over two empty lists: a
  # discovery glob that matches nothing reads exactly like a tree in perfect order.
  T 'the discovery actually resolved some definitions and some rows' `
    ($liveDefs.Count -ge 5 -and $liveRegs.Count -ge 5) `
    ("defs=" + $liveDefs.Count + " regs=" + $liveRegs.Count)

  $liveFindings = @()
  $scanned = 0
  foreach ($rel in @('graph\pipeline\install-nightly-task.ps1',
                     'meal-prep\pipeline\install-harvest-task.ps1',
                     'ops\install-grocery-tasks.ps1',
                     'media\reels\install-daily-task.ps1')) {
    $p = Join-Path $repo $rel
    if (-not (Test-Path $p)) { continue }
    $scanned++
    # ASSIGN, THEN APPEND. Test-RegistrarWatched comma-returns its list, so `+= @(call)` would append
    # the whole array as ONE element and a real finding would print as System.Object[]. Caught here
    # on 2026-09-09; it is the estate's most-repeated PS 5.1 trap.
    $one = Test-RegistrarWatched -Rel $rel -Source ([IO.File]::ReadAllText($p)) `
             -Definitions $liveDefs -RegistryNames $liveRegs `
             -AllowNoDefinition $script:ALLOW_NO_DEFINITION -AllowNoRefusal $script:ALLOW_NO_REFUSAL
    foreach ($x in $one) { $liveFindings += [string]$x }
  }
  T ("MUST NOT FIRE the {0} registrar(s) shipped in this tree are each defined, watched and refusing" -f $scanned) `
    ($scanned -eq 4 -and $liveFindings.Count -eq 0) ("scanned=" + $scanned + " " + ($liveFindings -join '; '))

  if ($fail -gt 0) {
    Write-Output ("SELF-TEST FAIL: {0} of {1} case(s)" -f $fail, $ran)
    Write-GuardComplete -Name 'task-registration' -Summary ("selftest-fail={0}/{1}" -f $fail, $ran)
    exit 2
  }
  Write-Output ("SELF-TEST PASS: {0} case(s) - the call-site parser (literal, variable, unresolved, commented out), the frozen 2026-08-22 registrar with no definition and no registry row, its fixed twin, a defined-and-watched registrar with no refusal, both allowlists with their reasons, an unresolvable name, a file that registers nothing, and the four real registrars in this tree" -f $ran)
  Exit-Guard -Name 'task-registration' -Summary ("selftest=pass cases={0}" -f $ran) -Code 0
}

# ---------------------------------------------------------------------------------- the live scan
if (-not (Test-Path $XMLDIR)) {
  Write-Output ("TASK REGISTRATION COULD NOT EVALUATE: {0} does not exist, so no committed definition can be read. Discovery broken, NOT a clean tree." -f $XMLDIR)
  Exit-Guard -Name 'task-registration' -Summary 'blind=no-xmldir' -Code 3
}
$definitions = @()
$xmlAll = @(Get-ChildItem -Path $XMLDIR -Filter '*.xml' -File -ErrorAction SilentlyContinue)
foreach ($xf in $xmlAll) {
  $mm = [regex]::Match([IO.File]::ReadAllText($xf.FullName), '<URI>(.*?)</URI>', 'Singleline')
  if ($mm.Success) { $definitions += $mm.Groups[1].Value.Trim().TrimStart('\') }
}
if (-not $definitions.Count) {
  Write-Output ("TASK REGISTRATION COULD NOT EVALUATE: {0} yielded ZERO task names from {1} file(s). A glob that matched nothing and a tree with no tasks are the same bytes, and only one of them is clean." -f $XMLDIR, $xmlAll.Count)
  Exit-Guard -Name 'task-registration' -Summary ("blind=no-definitions files={0}" -f $xmlAll.Count) -Code 3
}
if (-not (Test-Path $REGISTRY)) {
  Write-Output ("TASK REGISTRATION COULD NOT EVALUATE: {0} does not exist, so whether anything watches these tasks is unprovable rather than clean." -f $REGISTRY)
  Exit-Guard -Name 'task-registration' -Summary 'blind=no-registry' -Code 3
}
$regDoc = $null
try { $regDoc = [IO.File]::ReadAllText($REGISTRY) | ConvertFrom-Json } catch { $regDoc = $null }
if (-not $regDoc) {
  Write-Output ("TASK REGISTRATION COULD NOT EVALUATE: {0} did not parse as JSON. Unreadable is not clean." -f $REGISTRY)
  Exit-Guard -Name 'task-registration' -Summary 'blind=registry-unparseable' -Code 3
}
$registryNames = @()
foreach ($row in @($regDoc.windows_tasks)) { if ($row -and $row.name) { $registryNames += [string]$row.name } }

# DISCOVERED, NOT HAND-LISTED, and it PRINTS WHAT IT RESOLVED (backlog I39): a glob that matched
# nothing and a tree with no registrars are the same bytes otherwise. NEVER SCANS ITSELF - a detector
# that reads its own source finds its own needles and reports a defect it invented.
#
# THE WALK EXCLUDES \worktrees\, and that is not tidiness. .claude\worktrees holds other sessions'
# CHECKOUTS of this same repo, at whatever commit they were cut from; it is gitignored, and scanning
# it makes this gate's verdict depend on how stale somebody else's worktree is. The first live run
# reported nine findings, six of them the same two registrars at an older commit. Same exclusion set
# as ops\run-gates.ps1 line 52, deliberately - two walks over this tree that disagree about what the
# tree IS will disagree about everything downstream.
$self = $MyInvocation.MyCommand.Path
$files = @(Get-ChildItem -Path $repo -Recurse -Filter '*.ps1' -File -ErrorAction SilentlyContinue |
           Where-Object { $_.FullName -ne $self -and
                          $_.FullName -notmatch '\\worktrees\\|\\archive\\|node_modules|\.venv|\\out\\|\\\.git\\' })
$verbNeedle = 'Register-Scheduled' + 'Task'
$registrars = @()
foreach ($f in $files) {
  $txt = ''
  try { $txt = [IO.File]::ReadAllText($f.FullName) } catch { continue }
  # CASE-SENSITIVE: `Unregister-ScheduledTask` contains the verb, and a file that only uninstalls is
  # not a registrar. Get-RegistrarCallSites applies the same anchor per line.
  if (-not [regex]::IsMatch($txt, '(?<![A-Za-z])' + [regex]::Escape($verbNeedle))) { continue }
  $rel = $f.FullName.Substring($repo.Length).TrimStart('\')
  $sites = Get-RegistrarCallSites -Source $txt
  if (-not $sites.Count) { continue }   # mentions the verb in prose only
  $registrars += [pscustomobject]@{ Rel = $rel; Source = $txt; Sites = $sites.Count }
}
if (-not $registrars.Count) {
  Write-Output ("TASK REGISTRATION COULD NOT EVALUATE: the walk over {0} .ps1 file(s) found ZERO registrars. This tree has four. That is the walk broken, not the tree clean." -f $files.Count)
  Exit-Guard -Name 'task-registration' -Summary ("blind=no-registrars scanned={0}" -f $files.Count) -Code 3
}

$findings = @()
foreach ($r in $registrars) {
  Write-Output ("  registrar: {0}  ({1} call site(s))" -f $r.Rel, $r.Sites)
  # ASSIGN, THEN APPEND - see the note in the self-test. `+= @(call)` on a comma-returned list
  # appends the array as ONE element and prints a real finding as System.Object[].
  $one = Test-RegistrarWatched -Rel $r.Rel -Source $r.Source `
           -Definitions $definitions -RegistryNames $registryNames `
           -AllowNoDefinition $script:ALLOW_NO_DEFINITION -AllowNoRefusal $script:ALLOW_NO_REFUSAL
  foreach ($x in $one) { $findings += [string]$x }
}
foreach ($a in $script:ALLOW_NO_DEFINITION.Keys) { Write-Output ("  allowlisted (no definition): {0} - {1}" -f $a, $script:ALLOW_NO_DEFINITION[$a]) }
foreach ($a in $script:ALLOW_NO_REFUSAL.Keys)    { Write-Output ("  allowlisted (no refusal)   : {0} - {1}" -f $a, $script:ALLOW_NO_REFUSAL[$a]) }

foreach ($f in $findings) { Write-Output ("  " + $f) }
if ($findings.Count -gt 0) {
  Write-Output ("TASK REGISTRATION AUDIT FAILED: {0} finding(s) across {1} registrar(s) scanned out of {2} .ps1 file(s), against {3} committed definition(s) and {4} registry row(s). A task registered without a watch entry is unwatched from birth: TC Graph Nightly Matching was for three mornings from 2026-08-22 and TC Recipe Harvest Crawl the same way from 08-24, and in both cases the only thing that noticed was a heartbeat line the next morning that a human had to act on. Add the windows_tasks row and the committed definition FIRST, then register." -f $findings.Count, $registrars.Count, $files.Count, $definitions.Count, $registryNames.Count)
  Exit-Guard -Name 'task-registration' -Summary ("scanned={0} registrars={1} definitions={2} rows={3} findings={4}" -f $files.Count, $registrars.Count, $definitions.Count, $registryNames.Count, $findings.Count) -Code 2
}
Write-Output ("task-registration: PASSED - all {0} registrar(s) found in {1} .ps1 file(s) register only tasks that have a committed definition and a windows_tasks entry, and every registrar that names a task literally refuses to register an unwatched one ({2} definition(s), {3} registry row(s))." -f $registrars.Count, $files.Count, $definitions.Count, $registryNames.Count)
Exit-Guard -Name 'task-registration' -Summary ("scanned={0} registrars={1} definitions={2} rows={3} findings=0" -f $files.Count, $registrars.Count, $definitions.Count, $registryNames.Count) -Code 0
