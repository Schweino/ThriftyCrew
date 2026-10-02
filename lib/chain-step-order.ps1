# chain-step-order.ps1 - the daily chain's step order, checked against what each step declares it reads and writes.
#
# THE RULING (Brad, 2026-10-02, D2 = A of design/PLAN-weekly-root-families-2026-10-02.md, Phase 5): "The chain's step order
# is checked against a declared input/output list, so a step that reads a file before its writer runs fails a gate."
#
# THE FOUNDING DEFECT (queue 2026-09-28-c6bafd). check-ad-cycles ran export-feed before top5-weekly wrote
# grocery\out\recipe-costs.json, so the feed's recipe membership and week_cost were one run behind every day (the "feed
# note" line in 7 of 28 daily capture-run logs, 2026-08-30..09-28). The order was kept by a comment ("KEEP THE ORDER
# ABOVE"), and a comment cannot refuse a push.
#
# THE DECLARATION is ops\chain-steps.json: the steps of the PUBLISHING path (compare succeeded, guards did not block,
# no -NoPublish, a quarantine day included) in execution order, each with the files it reads and writes. Steps that
# re-run the same job share a `group` (default: the script), and only a group's LAST step is graded, because a later
# run of the same job supersedes what an earlier one produced.
#
# RULE A, ORDER. For the last step S of each group, and each file X that S reads: the last step of ANOTHER group that
# writes X must run before S. Otherwise S produces its output from an X the chain rewrites after it - the c6bafd shape.
# A step may name a read in `exempt` with its reason; every exemption is printed on every run, so it stays visible.
# It is graded on TWO paths: the whole declaration (a quarantine day) and the ordinary day, without the steps marked
# "conditional": true, because a conditional re-run late in the list would otherwise hide an ordinary day's stale read.
# RULE B, DRIFT. The declaration must be the chain as written. Each step names its `site` in grocery\check-ad-cycles.ps1:
# `literal:<script leaf>` (a string constant equal to the leaf or ending in \<leaf>), `call:<Command>` (a command by
# name), or `rerun` (a re-run through a variable, which is not located). For each leaf and command, the declaration holds
# exactly as many steps as the source has sites, and the declared order is the source's execution order: a site inside
# a function defined in the chain file sorts at that function's first call, then by its offset inside it.
#
# SCOPE OF A CLEAN REPORT: UNSOUND. A read or write the declaration does not list, a branch other than the publishing
# path (a held board, -NoPublish), a site in a file the chain dot-sources, and a step re-run through a variable are all
# outside it. It does not close queue 2026-09-28-871301 (chain-code-currency's producer closure at push time, whose
# eight unsound sites are in capture-run, wave-preaudit, hunt-run and stamp-live-price-fallback, none of them steps here).
# COMPLETE for rule A: a finding is a declared read whose declared writer runs later, which is the defect itself.
#
# NO param() BLOCK: dot-sourced by check-ad-cycles' -SelfTest, which runs the live check over the real files.
# Self-test (fixtures only, reads no repo file): powershell -File lib\chain-step-order.ps1 -SelfTest
# gate-inputs: lib\chain-step-order.ps1

function Get-TcCsoGroup($Step) { if ($Step.PSObject.Properties['group'] -and $Step.group) { return [string]$Step.group }; return [string]$Step.script }

function Test-TcChainStepOrder {
  <# Rule A over a declared step list (objects with id, script, reads, writes, optional group and exempt). Returns
     .findings (one string per stale read) and .exempted (one string per exemption that applied). #>
  param([Parameter(Mandatory = $true)][object[]]$Steps)
  $findings = New-Object Collections.ArrayList
  $exempted = New-Object Collections.ArrayList
  $graded = New-Object Collections.ArrayList
  $n = $Steps.Count
  $lastOfGroup = @{}
  for ($i = 0; $i -lt $n; $i++) { $lastOfGroup[(Get-TcCsoGroup $Steps[$i])] = $i }
  for ($i = 0; $i -lt $n; $i++) {
    $s = $Steps[$i]; $g = Get-TcCsoGroup $s
    if ($lastOfGroup[$g] -ne $i) { continue }
    [void]$graded.Add([string]$s.id)
    foreach ($x in @($s.reads)) {
      if (-not $x) { continue }
      $lw = -1
      for ($j = 0; $j -lt $n; $j++) { if (((Get-TcCsoGroup $Steps[$j]) -ne $g) -and (@($Steps[$j].writes) -contains $x)) { $lw = $j } }
      if ($lw -le $i) { continue }
      $ex = $null
      if ($s.PSObject.Properties['exempt'] -and $s.exempt -and $s.exempt.PSObject.Properties[[string]$x]) { $ex = [string]$s.exempt.$x }
      $line = ('{0} (step {1}) reads {2}, which {3} (step {4}) writes LATER in the chain' -f $s.id, ($i + 1), $x, $Steps[$lw].id, ($lw + 1))
      if ($ex) { [void]$exempted.Add($line + ' - EXEMPT: ' + $ex) } else { [void]$findings.Add($line) }
    }
  }
  return [pscustomobject]@{ findings = @($findings); exempted = @($exempted); graded = @($graded); steps = $n }
}

function Get-TcCsoSites {
  <# Rule B's source side: every site of each declared literal leaf and command in the chain file, outside its -SelfTest
     block, as objects { kind, key, line, order } sorted by execution order. #>
  param([Parameter(Mandatory = $true)][string]$ChainFile, [string[]]$Leaves = @(), [string[]]$Commands = @())
  $tok = $null; $err = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseFile($ChainFile, [ref]$tok, [ref]$err)
  if ($err -and $err.Count) { throw ('chain-step-order: ' + $ChainFile + ' does not parse: ' + $err[0].Message) }
  $self = $null
  foreach ($st in @($ast.EndBlock.Statements)) {
    if (($st -is [System.Management.Automation.Language.IfStatementAst]) -and [string]::Equals($st.Clauses[0].Item1.Extent.Text.Trim(), ('$Self' + 'Test'), [StringComparison]::Ordinal)) { $self = $st }
  }
  $inSelf = { param($nd) ($null -ne $self) -and ($nd.Extent.StartOffset -ge $self.Extent.StartOffset) -and ($nd.Extent.EndOffset -le $self.Extent.EndOffset) }
  $funcs = @($ast.FindAll({ param($nd) $nd -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | Where-Object { -not (& $inSelf $_) })
  $calls = @($ast.FindAll({ param($nd) $nd -is [System.Management.Automation.Language.CommandAst] }, $true) | Where-Object { -not (& $inSelf $_) })
  $orderOf = {
    param($nd)
    foreach ($f in $funcs) {
      if (($nd.Extent.StartOffset -gt $f.Extent.StartOffset) -and ($nd.Extent.EndOffset -le $f.Extent.EndOffset)) {
        $first = @($calls | Where-Object { [string]::Equals([string]$_.GetCommandName(), $f.Name, [StringComparison]::OrdinalIgnoreCase) -and -not (($_.Extent.StartOffset -gt $f.Extent.StartOffset) -and ($_.Extent.EndOffset -le $f.Extent.EndOffset)) } | Sort-Object { $_.Extent.StartOffset } | Select-Object -First 1)
        if ($first.Count) { return ([double]$first[0].Extent.StartOffset + ([double]$nd.Extent.StartOffset / 1e9)) }
      }
    }
    return [double]$nd.Extent.StartOffset
  }
  $sites = New-Object Collections.ArrayList
  foreach ($lf in @($Leaves)) {
    $hits = @($ast.FindAll({ param($nd) ($nd -is [System.Management.Automation.Language.StringConstantExpressionAst]) -and (([string]$nd.Value -eq $lf) -or ([string]$nd.Value).EndsWith('\' + $lf)) }.GetNewClosure(), $true) | Where-Object { -not (& $inSelf $_) })
    foreach ($h in $hits) { [void]$sites.Add([pscustomobject]@{ kind = 'literal'; key = $lf; line = $h.Extent.StartLineNumber; order = (& $orderOf $h) }) }
  }
  foreach ($cm in @($Commands)) {
    foreach ($h in @($calls | Where-Object { [string]::Equals([string]$_.GetCommandName(), $cm, [StringComparison]::OrdinalIgnoreCase) })) {
      [void]$sites.Add([pscustomobject]@{ kind = 'call'; key = $cm; line = $h.Extent.StartLineNumber; order = (& $orderOf $h) })
    }
  }
  return @($sites | Sort-Object order)
}

function Test-TcChainStepDrift {
  <# Rule B: the declared steps against the chain file. Returns .findings and .located (declared steps placed on a line). #>
  param([Parameter(Mandatory = $true)][object[]]$Steps, [Parameter(Mandatory = $true)][string]$ChainFile)
  $findings = New-Object Collections.ArrayList
  $decl = @($Steps | Where-Object { [string]$_.site -ne 'rerun' })
  foreach ($d in $decl) { if ([string]$d.site -notmatch '^(literal|call):.+$') { [void]$findings.Add(('{0}: site ''{1}'' is not literal:<leaf>, call:<Command> or rerun' -f $d.id, $d.site)) } }
  $leaves = @($decl | Where-Object { [string]$_.site -like 'literal:*' } | ForEach-Object { ([string]$_.site).Substring(8) } | Select-Object -Unique)
  $cmds = @($decl | Where-Object { [string]$_.site -like 'call:*' } | ForEach-Object { ([string]$_.site).Substring(5) } | Select-Object -Unique)
  $sites = @(Get-TcCsoSites -ChainFile $ChainFile -Leaves $leaves -Commands $cmds)
  foreach ($k in @(@($leaves) + @($cmds))) {
    $nd = @($decl | Where-Object { ([string]$_.site -eq ('literal:' + $k)) -or ([string]$_.site -eq ('call:' + $k)) }).Count
    $ns = @($sites | Where-Object { $_.key -eq $k }).Count
    if ($nd -ne $ns) { [void]$findings.Add(('{0}: declared {1} step(s), the chain has {2} site(s) (lines {3})' -f $k, $nd, $ns, ((@($sites | Where-Object { $_.key -eq $k }) | ForEach-Object { $_.line }) -join ', '))) }
  }
  if ($findings.Count) { return [pscustomobject]@{ findings = @($findings); located = 0 } }
  # Each declared step takes the next unused site of its key, in source execution order; the result must be ascending.
  $used = @{}
  $placed = New-Object Collections.ArrayList
  foreach ($d in $decl) {
    $k = ([string]$d.site) -replace '^(literal|call):', ''
    $ix = if ($used.ContainsKey($k)) { $used[$k] } else { 0 }
    $site = @($sites | Where-Object { $_.key -eq $k })[$ix]; $used[$k] = $ix + 1
    [void]$placed.Add([pscustomobject]@{ id = $d.id; line = $site.line; order = $site.order })
  }
  for ($i = 1; $i -lt $placed.Count; $i++) {
    if ($placed[$i].order -lt $placed[$i - 1].order) { [void]$findings.Add(('{0} is declared after {1}, but the chain runs it first (line {2} before line {3})' -f $placed[$i].id, $placed[$i - 1].id, $placed[$i].line, $placed[$i - 1].line)) }
  }
  return [pscustomobject]@{ findings = @($findings); located = $placed.Count }
}

function Test-TcChainStepPaths {
  <# Rule A on BOTH paths: the full declaration (a quarantine day, every conditional step run) and the ordinary day
     (steps marked "conditional": true removed). A conditional re-run late in the list must not hide the stale read of
     the unconditional step that is the last run on an ordinary day. Findings and exemptions are de-duplicated. #>
  param([Parameter(Mandatory = $true)][object[]]$Steps)
  $plain = @($Steps | Where-Object { -not ($_.PSObject.Properties['conditional'] -and $_.conditional) })
  $full = Test-TcChainStepOrder -Steps $Steps
  $ord = Test-TcChainStepOrder -Steps $plain
  $f = @(@(@($full.findings) | ForEach-Object { 'quarantine day: ' + $_ }) + @(@($ord.findings) | ForEach-Object { 'ordinary day: ' + $_ }))
  $e = @(@(@($full.exempted) + @($ord.exempted)) -replace ' \(step \d+\)', '' | Select-Object -Unique)
  return [pscustomobject]@{ findings = $f; exempted = $e; steps = $Steps.Count }
}

function Invoke-TcChainStepGate {
  <# Both rules over the declaration file and the chain file; prints the verdict and returns $true when clean. #>
  param([Parameter(Mandatory = $true)][string]$StepsFile, [Parameter(Mandatory = $true)][string]$ChainFile)
  $doc = [IO.File]::ReadAllText($StepsFile) | ConvertFrom-Json
  $steps = @($doc.steps)
  $a = Test-TcChainStepPaths -Steps $steps
  $b = Test-TcChainStepDrift -Steps $steps -ChainFile $ChainFile
  foreach ($f in @($a.findings)) { Write-Output ('  ORDER  ' + $f) }
  foreach ($f in @($b.findings)) { Write-Output ('  DRIFT  ' + $f) }
  foreach ($e in @($a.exempted)) { Write-Output ('  exempt ' + $e) }
  Write-Output ('CHAIN-STEP-ORDER-COMPLETE steps={0} located={1} order_findings={2} drift_findings={3} exempt={4}' -f $steps.Count, $b.located, @($a.findings).Count, @($b.findings).Count, @($a.exempted).Count)
  return ((@($a.findings).Count -eq 0) -and (@($b.findings).Count -eq 0) -and ($steps.Count -gt 0))
}

$__csoSelfTest = ($MyInvocation.InvocationName -ne '.') -and ($args -contains '-SelfTest')
if ($__csoSelfTest) {
  $script:csN = 0; $script:csF = 0
  function CsT([string]$Label, [bool]$Ok, [string]$Got = '') {
    $script:csN++
    if ($Ok) { Write-Output ('  PASS  ' + $Label) } else { $script:csF++; Write-Output ('  FAIL  ' + $Label + $(if ($Got) { '   got: ' + $Got } else { '' })) }
  }
  function New-CsStep([string]$Id, [string]$Script, [string[]]$Reads = @(), [string[]]$Writes = @(), [string]$Site = '', [string]$Group = '') {
    $o = [pscustomobject]@{ id = $Id; script = $Script; reads = $Reads; writes = $Writes; site = $Site }
    if ($Group) { $o | Add-Member -NotePropertyName group -NotePropertyValue $Group }
    return $o
  }
  $sb = Join-Path ([IO.Path]::GetTempPath()) ('cso-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
  [void](New-Item -ItemType Directory -Path $sb -ErrorAction Stop)
  try {
    $RC = 'grocery/out/recipe-costs.json'; $V2 = 'meal-prep/pipeline/v2-perserving.json'; $FD = 'grocery/out/smp-feed.json'   # reach-fixture-ok: a self-test fixture string naming a file, nothing opens it
    # MUST FIRE: the c6bafd order as the chain ran it on 2026-09-28 (check-ad-cycles at 30015ad86).
    $c6 = @((New-CsStep 'export-feed (daily)' 'grocery/export-feed.ps1' @($RC, $V2) @($FD)), (New-CsStep 'compute-v2' 'meal-prep/pipeline/compute-v2-perserving.ps1' @() @($V2)),
            (New-CsStep 'top5-weekly' 'meal-prep/top5-weekly.ps1' @($V2) @($RC)))
    $r = Test-TcChainStepOrder -Steps $c6
    CsT 'MUST FIRE  c6bafd: export-feed reads recipe-costs.json before top5-weekly writes it (and v2-perserving before compute-v2)' ((@($r.findings).Count -eq 2) -and ((@($r.findings) -join ' ') -match 'export-feed \(daily\) \(step 1\) reads grocery/out/recipe-costs\.json, which top5-weekly \(step 3\) writes LATER')) (@($r.findings) -join ' | ')   # reach-fixture-ok: a self-test fixture string naming a file, nothing opens it
    # CLEAN TWIN: the corrected order, a second export after top5-weekly. The daily export is superseded, not graded.
    $fix = @($c6) + @(New-CsStep 'export-feed (after top5-weekly)' 'grocery/export-feed.ps1' @($RC, $V2) @($FD))
    $r = Test-TcChainStepOrder -Steps $fix
    CsT 'MUST NOT FIRE  the corrected order (export-feed again after top5-weekly) has no stale read' ((@($r.findings).Count -eq 0) -and (@($r.exempted).Count -eq 0)) (@($r.findings) -join ' | ')
    CsT 'CLEAN TWIN  ...because the re-export after top5-weekly is the export that is graded, and the daily one is superseded' ((@($r.graded) -contains 'export-feed (after top5-weekly)') -and (@($r.graded) -notcontains 'export-feed (daily)')) (@($r.graded) -join ' | ')
    # MUST NOT FIRE: a legal order, an external input (no writer in the chain) and a read after its writer.
    $legal = @((New-CsStep 'compare-deals' 'grocery/compare-deals.ps1' @('grocery/out/ads-x.json') @('grocery/out/comparison.json')), (New-CsStep 'guards' 'grocery/guards.ps1' @('grocery/out/comparison.json', 'grocery/known-wrong.json') @()))   # reach-fixture-ok: a self-test fixture string naming a file, nothing opens it
    $r = Test-TcChainStepOrder -Steps $legal
    CsT 'MUST NOT FIRE  a step reading an external input and a file its writer already wrote' (@($r.findings).Count -eq 0) (@($r.findings) -join ' | ')
    # A self-rewrite is not a stale read: apply-cell-quarantine reads and writes the comparison, twice.
    $self = @((New-CsStep 'quarantine' 'grocery/apply-cell-quarantine.ps1' @('c') @('c')), (New-CsStep 'reapply' 'grocery/apply-cell-quarantine.ps1' @('c') @('c')))
    CsT 'MUST NOT FIRE  a group that reads and rewrites its own file' (@((Test-TcChainStepOrder -Steps $self).findings).Count -eq 0)
    # A grouped re-derive: the verified board re-derived after the quarantine is graded at its LAST step.
    $grp = @((New-CsStep 'verify-apply' 'grocery/verify-apply.ps1' @('c') @('v') '' 'gen'), (New-CsStep 'quarantine' 'grocery/apply-cell-quarantine.ps1' @('c') @('c')), (New-CsStep 'advance' 'lib/board-pin.ps1' @('c') @('v') '' 'gen'))
    $rg = Test-TcChainStepOrder -Steps $grp
    CsT 'MUST NOT FIRE  verify-apply then a quarantine then the pin advance (one group) has no stale read' (@($rg.findings).Count -eq 0)
    CsT 'CLEAN TWIN  ...because the group is graded at the advance, which runs after the quarantine rewrote the comparison' ((@($rg.graded) -contains 'advance') -and (@($rg.graded) -notcontains 'verify-apply')) (@($rg.graded) -join ' | ')
    $grpNo = @($grp[0], $grp[1])
    CsT 'MUST FIRE  ...and without the advance the verified board is derived before the quarantine rewrote its comparison (1d4206)' (@((Test-TcChainStepOrder -Steps $grpNo).findings).Count -eq 1)
    $ex = @((New-CsStep 'compute-v2' 'm/compute-v2.ps1' @($FD) @($V2)), (New-CsStep 'export' 'g/export-feed.ps1' @() @($FD)))
    $ex[0] | Add-Member -NotePropertyName exempt -NotePropertyValue ([pscustomobject]@{ 'grocery/out/smp-feed.json' = 'reads ingredients only' })   # reach-fixture-ok: a self-test fixture string naming a file, nothing opens it
    $r = Test-TcChainStepOrder -Steps $ex
    CsT 'MUST NOT FIRE  a declared exemption is not a finding, and it is reported with its reason' ((@($r.findings).Count -eq 0) -and ((@($r.exempted) -join ' ') -match 'EXEMPT: reads ingredients only')) (@($r.exempted) -join ' | ')
    # The hole the real declaration exposed: a CONDITIONAL re-export after top5-weekly (a quarantine day only) made the
    # daily export look superseded. On an ordinary day the daily export is the last one, and it is stale.
    $hid = @($c6) + @(New-CsStep 'export-feed (repair, quarantine days only)' 'grocery/export-feed.ps1' @($RC, $V2) @($FD))
    $hid[3] | Add-Member -NotePropertyName conditional -NotePropertyValue $true
    $r = Test-TcChainStepPaths -Steps $hid
    CsT 'MUST FIRE  a conditional re-run does not hide the ordinary day''s stale export: graded on the path without it' ((@($r.findings).Count -eq 2) -and ((@($r.findings) -join ' ') -match '^ordinary day: export-feed \(daily\)')) (@($r.findings) -join ' | ')

    # ---- rule B over a fixture chain file
    $chain = Join-Path $sb 'chain.ps1'
    $src = @('param([switch]$SelfTest)', 'if ($SelfTest) { $x = Join-Path $root ''top5-weekly.ps1''; exit 0 }',
      'function Invoke-Gate { & powershell -File (Join-Path $root ''guards.ps1''); & powershell -File (Join-Path $root ''export-feed.ps1'') }',
      '& powershell -File (Join-Path $root ''export-feed.ps1'')', 'Invoke-Gate', 'New-TcBoardPin -OutDir x',
      '& powershell -File (Join-Path $mp ''meal-prep\top5-weekly.ps1'')', '& powershell -File (Join-Path $root ''export-feed.ps1'')') -join "`r`n"
    [IO.File]::WriteAllText($chain, $src, (New-Object Text.UTF8Encoding($false)))
    $ok = @((New-CsStep 'export (daily)' 'e' @() @() 'literal:export-feed.ps1'), (New-CsStep 'pin' 'p' @() @() 'call:New-TcBoardPin'),
            (New-CsStep 'guards' 'g' @() @() 'literal:guards.ps1'), (New-CsStep 'guards rerun' 'g' @() @() 'rerun'), (New-CsStep 'export (quarantine)' 'e' @() @() 'literal:export-feed.ps1'),
            (New-CsStep 'top5' 't' @() @() 'literal:top5-weekly.ps1'), (New-CsStep 'export (after top5)' 'e' @() @() 'literal:export-feed.ps1'))
    # $ok declares the pin second; the chain calls Invoke-Gate (line 5, holding guards and the quarantine export) first.
    $okFixed = @($ok[0], $ok[2], $ok[3], $ok[4], $ok[1], $ok[5], $ok[6])
    $r = Test-TcChainStepDrift -Steps $okFixed -ChainFile $chain
    CsT 'MUST NOT FIRE  a declaration in the chain''s execution order (sites inside Invoke-Gate sort at its call, the self-test''s top5 literal is ignored)' ((@($r.findings).Count -eq 0) -and ($r.located -eq 6)) (@($r.findings) -join ' | ')
    $r = Test-TcChainStepDrift -Steps $ok -ChainFile $chain
    CsT 'MUST FIRE  the pin declared before the gate the chain runs first is DRIFT, naming both lines' ((@($r.findings).Count -eq 1) -and ((@($r.findings) -join ' ') -match '^guards is declared after pin, but the chain runs it first \(line 3 before line 6\)')) (@($r.findings) -join ' | ')
    $r = Test-TcChainStepDrift -Steps @($okFixed | Where-Object { $_.id -ne 'export (after top5)' }) -ChainFile $chain
    CsT 'MUST FIRE  a site the declaration does not list (the after-top5 export) is DRIFT with its count and lines, in execution order' ((@($r.findings) -join ' ') -match '^export-feed\.ps1: declared 2 step\(s\), the chain has 3 site\(s\) \(lines 4, 3, 8\)') (@($r.findings) -join ' | ')
  } catch {
    CsT 'the suite ran to the end without throwing' $false $_.Exception.Message
  } finally { Remove-Item -LiteralPath $sb -Recurse -Force -ErrorAction SilentlyContinue }
  $want = 13
  if ($script:csN -ne $want) { Write-Output ('  FAIL  the suite ran {0} case(s), expected {1}' -f $script:csN, $want); $script:csF++ }
  if ($script:csF) { Write-Output ('chain-step-order self-test FAIL: {0} of {1}' -f $script:csF, $script:csN); exit 1 }
  Write-Output ('chain-step-order self-test PASS: {0} of {0} cases - led by the c6bafd order (export-feed before top5-weekly) firing' -f $script:csN)
  exit 0
}
