<#
  audit-cmdlet-shadow.ps1 - no script defines a function named after a built-in cmdlet or module function.

  WHY THIS EXISTS (2026-09-11). PowerShell resolves a FUNCTION before a CMDLET of the same name, so a script that
  defines one silently changes what every call to that name does, everywhere in its scope, and nothing errors.
  grocery\ingredient-queue.ps1 defined its queue lookup as a function named Get-Item taking ($doc, $term). Its
  -Promote fixture then read `(Get-Item $live).Length` to prove the live carriage.json was untouched. That called
  the lookup instead, which returned nothing for a path, and .Length on nothing is 0 before and after. So the
  assertion could not fire from 2026-08-25 to 2026-09-11. The fixture was fixed on
  fix/ingredient-queue-inert-live-ledger-check and .claude\rules\ops-and-gates.md gained the rule. A rule in a
  file reaches whoever opens the file. This reaches the next definition at push time.

  SCOPE OF A CLEAN REPORT: UNSOUND. It reads every FunctionDefinitionAst (function, filter, workflow, nested or
  scope-qualified) in the tracked .ps1 and .psm1 files and compares its literal name to the pinned list below. A
  clean report means no such DEFINITION carries a listed name. It does not see a function made any other way:
  Set-Item or New-Item on function:, ${function:Name} = {...}, a name built at run time, Invoke-Expression text, or
  an alias. It does not see a module installed outside $PSHOME (see THE NAME LIST). Nor does it see the opposite
  trap, an ALIAS that hides a function (the `R` helper recorded in ops-and-gates.md). A reported definition is real.

  THE NAME LIST IS PINNED, NOT READ FROM Get-Command, AND THAT IS THE HERMETIC CHOICE. Get-Command answers from
  whatever modules this box has installed, so the same tree could be red on one machine and green on another.
  ops\cmdlet-shadow-builtins.txt is generated once by -Regenerate in a -NoProfile child and committed. It keeps
  every Cmdlet and Function whose module is Microsoft.PowerShell.* or lives under $PSHOME (the modules that ship
  inside Windows PowerShell 5.1: Storage, NetTCPIP, ScheduledTasks, CimCmdlets and the rest), plus the module-less
  session functions (Clear-Host, Pause, help, mkdir, prompt). It leaves out modules installed per box or per user
  (PowerShellGet, Pester, PackageManagement, PSReadLine, ImportExcel), whose versions and names vary.
  Measured 2026-09-11: a scratch AST census over the 749 tracked files at 3176eb82b found the SAME 3 definitions
  whether it compared the 300 Microsoft.PowerShell.* names or all 1,676 cmdlet and function names installed on
  this box, so the pin loses nothing measured today. This file's first live run, at bfefc7d97 plus this change
  (the two renames included), read 749 of 749 against the pinned 1,531 names and found 1: the allowlisted mock.

  AN ALLOWLIST WITH A REASON PER ENTRY, NOT A COUNT RATCHET. A ratchet holding a count lets a new shadow replace
  a fixed one on the same day and stay green. An entry keyed on FILE AND NAME cannot be spent twice. An entry that
  no longer matches fails too (STALE), so the list stays closed instead of accumulating permissions nobody uses.
  The 3 found on 2026-09-11: ingredient-queue's Get-Item and media\reels\build-reel.ps1's Format-List were renamed
  (Brad, 2026-09-11: Get-QueueItem and Format-RowList). test-auditors' Get-Date is the one entry below.

  EXIT CODES: 0 clean, 1 a definition not on the allowlist or a stale allowlist entry, 2 self-test regression,
  3 BLIND (no tracked scripts resolved, the anchor script missing from them, or a name list without its anchors).

    ops\audit-cmdlet-shadow.ps1               scan the tracked tree
    ops\audit-cmdlet-shadow.ps1 -SelfTest     frozen founding definitions, the renamed forms, the allowlist, the walk
    ops\audit-cmdlet-shadow.ps1 -Regenerate   rewrite the pinned name list from this box (deliberate; review the diff)
#>
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop (2026-09-07)
param([switch]$SelfTest, [switch]$Regenerate)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $repo 'lib\lf-write.ps1')       # Write-TcLfFile: the pinned list is tracked, so it is written LF
. (Join-Path $repo 'lib\git-repo-env.ps1')   # Clear-TcGitRepoEnv: the self-test points git at a directory by path

$BUILTINS_FILE = Join-Path $repo 'ops\cmdlet-shadow-builtins.txt'
$SELF_REL = 'ops/audit-cmdlet-shadow.ps1'
# Names every honest list carries. A list missing one was truncated or generated wrong, and would pass a tree it
# cannot judge, so the live run reads it as BLIND. The first three are the definitions this file was written for.
$script:CS_ANCHORS = @('Get-Item', 'Get-Date', 'Format-List', 'ForEach-Object', 'Set-Content')
# A tracked script the discovery must resolve, or it found some other tree (or none) and its silence means nothing.
$script:CS_ANCHOR_FILE = 'ops/run-gates.ps1'

# THE ALLOWLIST. One entry per FILE AND NAME, each with the reason the shadow is the point.
$script:CS_ALLOW = @(
  [pscustomobject]@{ File = 'grocery/test-auditors.ps1'; Name = 'Get-Date'
    Reason = 'a deliberate clock mock scoped inside RfRunDay: the sentinelled production regions it runs call Get-Date and must read $script:RF_NOW' }
)

# ------------------------------------------------------------------------------------------- the name list
function ConvertFrom-CsBuiltinsText {
  <# Pure. 'Name<TAB>Module' lines, '#' comments and blanks ignored. Returns @{ Map; Missing } where Map is a
     case-insensitive name -> module dictionary and Missing lists the anchors the text does not carry. #>
  param([AllowEmptyString()][string]$Text)
  $map = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
  foreach ($l in ([string]$Text -split "`r?`n")) {
    $t = $l.Trim()
    if (-not $t -or $t.StartsWith('#')) { continue }
    $parts = $t -split "`t"
    if ($parts[0] -and -not $map.ContainsKey($parts[0])) { $map[$parts[0]] = $(if ($parts.Count -gt 1) { $parts[1] } else { '' }) }
  }
  $missing = @($script:CS_ANCHORS | Where-Object { -not $map.ContainsKey($_) })
  return [pscustomobject]@{ Map = $map; Missing = $missing }
}

function ConvertTo-CsBuiltinsText {
  <# Pure. Rows of @{ Name; Source; ModuleBase } (Get-Command's view) to the pinned file's text: kept by the rule
     in the header, one line per name, modules joined with ',' when two carry the name, sorted ordinally so the
     bytes do not depend on the culture of the box that regenerated them. The parameter is -PsHomeDir because
     variable names are case-insensitive, and a parameter named PsHome collides with the read-only $PSHOME. #>
  param($Rows, [string]$PsHomeDir, [string]$PsVersion)
  $mods = New-Object 'System.Collections.Generic.Dictionary[string,System.Collections.Generic.List[string]]' ([StringComparer]::OrdinalIgnoreCase)
  foreach ($r in @($Rows)) {
    $name = [string]$r.Name; $src = [string]$r.Source; $base = [string]$r.ModuleBase
    if ($name -notmatch '^[A-Za-z][\w-]*$') { continue }   # drive functions (C:) and cd.. are not definable names
    $keep = (-not $src) -or ($src -like 'Microsoft.PowerShell.*') -or
            ($base -and $PsHomeDir -and $base.StartsWith($PsHomeDir, [StringComparison]::OrdinalIgnoreCase))
    if (-not $keep) { continue }
    $label = $(if ($src) { $src } else { '(session)' })
    if (-not $mods.ContainsKey($name)) { $mods[$name] = New-Object 'System.Collections.Generic.List[string]' }
    if (-not $mods[$name].Contains($label)) { $mods[$name].Add($label) }
  }
  $names = [string[]]@($mods.Keys)
  [Array]::Sort($names, [StringComparer]::OrdinalIgnoreCase)
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append("# cmdlet-shadow-builtins.txt - the command names ops\audit-cmdlet-shadow.ps1 treats as built in. GENERATED.`n")
  [void]$sb.Append("# Regenerate with: powershell -NoProfile -File ops\audit-cmdlet-shadow.ps1 -Regenerate`n")
  [void]$sb.Append("# Kept: Cmdlet and Function names whose module is Microsoft.PowerShell.* or lives under `$PSHOME, and module-less`n")
  [void]$sb.Append("# session functions. The header of the audit says why the list is pinned rather than read at run time.`n")
  [void]$sb.Append(("# Generated under Windows PowerShell {0}. {1} names. Format: name<TAB>module[,module]`n" -f $PsVersion, $names.Count))
  foreach ($n in $names) {
    $m = [string[]]$mods[$n].ToArray()
    [Array]::Sort($m, [StringComparer]::Ordinal)
    [void]$sb.Append($n + "`t" + ($m -join ',') + "`n")
  }
  return $sb.ToString().TrimEnd("`n")
}

# ------------------------------------------------------------------------------------------- the detector
function Get-CsFindings {
  <# Pure over one file's text, so the self-test drives exactly what the live scan runs. Returns
     @{ Findings = @({ Line; Name; Module }); ParseErrors }. Comments and strings are never definitions, because
     only the AST is read. #>
  param([AllowEmptyString()][string]$Text, $Builtins)
  $tok = $null; $err = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseInput([string]$Text, [ref]$tok, [ref]$err)
  $out = New-Object System.Collections.ArrayList
  $defs = $ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
  foreach ($d in $defs) {
    $name = ([string]$d.Name) -replace '^(?i:global|local|private|script):', ''
    $mod = $null
    if ($Builtins.TryGetValue($name, [ref]$mod)) {
      [void]$out.Add([pscustomobject]@{ Line = $d.Extent.StartLineNumber; Name = $name; Module = $mod })
    }
  }
  return [pscustomobject]@{ Findings = $out.ToArray(); ParseErrors = @($err).Count }
}

function Split-CsAllowed {
  <# Pure. Findings carry File (repo-relative) and Name. An allowlist entry covers every definition of its NAME in
     its FILE and nothing else; paths compare with either slash and in any case. Returns @{ New; Allowed; Stale }. #>
  param($Findings, $Allow)
  $norm = { param($p) ([string]$p).Replace('\', '/').TrimStart('/') }
  $new = New-Object System.Collections.ArrayList; $allowed = New-Object System.Collections.ArrayList
  $used = New-Object 'System.Collections.Generic.HashSet[int]'
  foreach ($f in @($Findings)) {
    $hit = -1
    for ($i = 0; $i -lt @($Allow).Count; $i++) {
      $a = @($Allow)[$i]
      if ([string]::Equals((& $norm $a.File), (& $norm $f.File), [StringComparison]::OrdinalIgnoreCase) -and
          [string]::Equals([string]$a.Name, [string]$f.Name, [StringComparison]::OrdinalIgnoreCase)) { $hit = $i; break }
    }
    if ($hit -ge 0) { [void]$allowed.Add($f); [void]$used.Add($hit) } else { [void]$new.Add($f) }
  }
  $stale = New-Object System.Collections.ArrayList
  for ($i = 0; $i -lt @($Allow).Count; $i++) { if (-not $used.Contains($i)) { [void]$stale.Add(@($Allow)[$i]) } }
  return [pscustomobject]@{ New = $new.ToArray(); Allowed = $allowed.ToArray(); Stale = $stale.ToArray() }
}

# ------------------------------------------------------------------------------------------------ the walk
function Get-CsScanFiles {
  <# The TRACKED .ps1 and .psm1 under $RootDir, repo-relative with forward slashes, never $SelfRel. git ls-files
     rather than a directory walk: it lists paths relative to the checkout it is run in, so a linked worktree is
     read whole and a sibling worktree below it (untracked) is never read, with no exclusion pattern to get wrong;
     and untracked scratch in the main checkout cannot make the verdict differ between checkouts.
     Returns @{ Ok; Files; Error }. #>
  param([string]$RootDir, [string]$SelfRel = '')
  $ErrorActionPreference = 'Continue'   # git's stderr under Stop is a terminating error in PS 5.1
  $prevEnc = $null
  try { $prevEnc = [Console]::OutputEncoding; [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false) } catch { $prevEnc = $null }
  try {
    $lines = @(& git -C $RootDir -c core.quotepath=off ls-files -- '*.ps1' '*.psm1' 2>$null)
    $rc = $LASTEXITCODE
  } finally {
    if ($null -ne $prevEnc) { try { [Console]::OutputEncoding = $prevEnc } catch { } }
  }
  if ($rc -ne 0) { return [pscustomobject]@{ Ok = $false; Files = @(); Error = ("git ls-files exited {0} in {1}" -f $rc, $RootDir) } }
  $files = @($lines | ForEach-Object { ([string]$_).Trim() } |
             Where-Object { $_ -and ($_ -match '(?i)\.psm?1$') -and -not [string]::Equals($_, $SelfRel, [StringComparison]::OrdinalIgnoreCase) })
  return [pscustomobject]@{ Ok = $true; Files = $files; Error = '' }
}

# -------------------------------------------------------------------------------------------- regenerate
if ($Regenerate) {
  # A -NoProfile CHILD, so a function from somebody's profile never lands in the list as a built-in.
  $enum = 'Get-Command -CommandType Cmdlet,Function | ForEach-Object { $b = ''''; if ($_.Module) { $b = [string]$_.Module.ModuleBase }; ' +
          '[string]$_.Name + [char]9 + [string]$_.Source + [char]9 + $b }'
  $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($enum))
  $raw = @(& powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand $enc)
  if ($LASTEXITCODE -ne 0 -or -not $raw.Count) { Write-Output 'audit-cmdlet-shadow: -Regenerate got nothing from the child Get-Command; the list was NOT rewritten'; exit 3 }
  $rows = @($raw | ForEach-Object { $p = ([string]$_) -split "`t"; [pscustomobject]@{ Name = $p[0]; Source = $(if ($p.Count -gt 1) { $p[1] } else { '' }); ModuleBase = $(if ($p.Count -gt 2) { $p[2] } else { '' }) } })
  $text = ConvertTo-CsBuiltinsText -Rows $rows -PsHomeDir $PSHOME -PsVersion ([string]$PSVersionTable.PSVersion)
  $check = ConvertFrom-CsBuiltinsText -Text $text
  if (@($check.Missing).Count) { Write-Output ('audit-cmdlet-shadow: the generated list lacks anchor name(s) ' + (@($check.Missing) -join ', ') + '; NOT written'); exit 3 }
  $wrote = Write-TcLfFile -Path $BUILTINS_FILE -Text $text -NoBom
  Write-Output ("audit-cmdlet-shadow: {0} child row(s) read, {1} built-in name(s) kept; {2}" -f $rows.Count, $check.Map.Count, $(if ($wrote) { 'ops\cmdlet-shadow-builtins.txt rewritten - review its diff before committing' } else { 'ops\cmdlet-shadow-builtins.txt already held these bytes' }))
  exit 0
}

# ------------------------------------------------------------------------------------------------ self-test
if ($SelfTest) {
  Clear-TcGitRepoEnv   # one case points git at a directory by path; an inherited GIT_DIR would override -C
  $script:fail = 0; $script:cases = 0
  function CsT([string]$m, [bool]$c, [string]$got = '') {
    $script:cases++
    if ($c) { Write-Output ('  ok    ' + $m) } else { Write-Output ('  FAIL  ' + $m + '   got: ' + $got); $script:fail++ }
  }
  function CsGot($r) { return ('count=' + @($r.Findings).Count + ' ' + ((@($r.Findings) | ForEach-Object { '' + $_.Line + ':' + $_.Name + '(' + $_.Module + ')' }) -join ' ')) }

  # A frozen name list, so no case below depends on the committed file or on this box.
  $fxList = @(
    '# a frozen list for the self-test',
    '',
    ('Get-' + 'Item' + "`t" + 'Microsoft.PowerShell.Management'),
    ('Get-' + 'Date' + "`t" + 'Microsoft.PowerShell.Utility'),
    ('Format-' + 'List' + "`t" + 'Microsoft.PowerShell.Utility'),
    ('ForEach-' + 'Object' + "`t" + 'Microsoft.PowerShell.Core'),
    ('Set-' + 'Content' + "`t" + 'Microsoft.PowerShell.Management'),
    ('Where-' + 'Object' + "`t" + 'Microsoft.PowerShell.Core'),
    ('Get-' + 'FileHash' + "`t" + 'Microsoft.PowerShell.Utility'),
    ('Get-' + 'ScheduledTask' + "`t" + 'ScheduledTasks')
  ) -join "`n"
  $kw = 'func' + 'tion '

  try {
    $ErrorActionPreference = 'Stop'
    $bl = ConvertFrom-CsBuiltinsText -Text $fxList
    $B = $bl.Map
    CsT 'the frozen list parses: 8 names, comments and blanks skipped, every anchor present' ($B.Count -eq 8 -and @($bl.Missing).Count -eq 0) ('count=' + $B.Count + ' missing=' + (@($bl.Missing) -join ','))

    # ---- MUST FIRE: the three definitions the tree carried on 2026-09-11, spelled as they were ---------------
    $fxQueue = @(
      ($kw + 'Get-' + 'Item($doc, [string]$term) {'),
      '  return @($doc.items | Where-Object { [string]$_.term -eq $term })[0]',
      '}',
      '$liveBefore = $(if (Test-Path $live) { (Get-Item $live).Length } else { -1 })'
    ) -join "`n"
    $r = Get-CsFindings -Text $fxQueue -Builtins $B
    CsT 'MUST FIRE  grocery\ingredient-queue.ps1 before 2026-09-11: its queue lookup named Get-Item, on line 1' (@($r.Findings).Count -eq 1 -and $r.Findings[0].Line -eq 1 -and $r.Findings[0].Name -eq ('Get-' + 'Item') -and $r.Findings[0].Module -eq 'Microsoft.PowerShell.Management') (CsGot $r)

    $fxMock = @(
      '  function RfRunDay([datetime]$now, [hashtable]$fstate) {',
      '    $script:RF_NOW = $now',
      ('    ' + $kw + 'Get-' + 'Date { return $script:RF_NOW }'),
      '  }'
    ) -join "`n"
    $r = Get-CsFindings -Text $fxMock -Builtins $B
    CsT 'MUST FIRE  a definition NESTED inside another function (test-auditors'' clock mock), on line 3' (@($r.Findings).Count -eq 1 -and $r.Findings[0].Line -eq 3) (CsGot $r)

    $fxReel = @(
      ($kw + 'Format-' + 'List {'),
      '  param($Rows)',
      '  return ''<div class="list"></div>''',
      '}',
      '$body = (Format-List -Rows $shown)'
    ) -join "`n"
    $r = Get-CsFindings -Text $fxReel -Builtins $B
    CsT 'MUST FIRE  media\reels\build-reel.ps1 before 2026-09-11: an HTML formatter named Format-List' (@($r.Findings).Count -eq 1 -and $r.Findings[0].Name -eq ('Format-' + 'List')) (CsGot $r)

    # ---- MUST FIRE: the other spellings the header claims ---------------------------------------------------
    $fxScoped = $kw + 'script:Set-' + 'Content([string]$Path) { }'
    $r = Get-CsFindings -Text $fxScoped -Builtins $B
    CsT 'MUST FIRE  a scope-qualified name (script:) is the built-in name once the qualifier is off' (@($r.Findings).Count -eq 1 -and $r.Findings[0].Name -eq ('Set-' + 'Content')) (CsGot $r)
    $fxCase = $kw + 'get-' + 'item($x) { $x }'
    $r = Get-CsFindings -Text $fxCase -Builtins $B
    CsT 'MUST FIRE  a lower-case spelling, because command names resolve case-insensitively' (@($r.Findings).Count -eq 1) (CsGot $r)
    $fxFilter = 'fil' + 'ter Where-' + 'Object { if ($_) { $_ } }'
    $r = Get-CsFindings -Text $fxFilter -Builtins $B
    CsT 'MUST FIRE  a filter is a function definition too' (@($r.Findings).Count -eq 1) (CsGot $r)
    $fxModFn = $kw + 'Get-' + 'FileHash($p) { ''x'' }'
    $r = Get-CsFindings -Text $fxModFn -Builtins $B
    CsT 'MUST FIRE  a module FUNCTION, not only a compiled cmdlet (Get-FileHash is script in Utility)' (@($r.Findings).Count -eq 1) (CsGot $r)
    $fxInbox = $kw + 'Get-' + 'ScheduledTask($n) { $null }'
    $r = Get-CsFindings -Text $fxInbox -Builtins $B
    CsT 'MUST FIRE  an in-box module outside Microsoft.PowerShell.* (ScheduledTasks), which this estate calls' (@($r.Findings).Count -eq 1 -and $r.Findings[0].Module -eq 'ScheduledTasks') (CsGot $r)
    $fxTwo = @(($kw + 'Get-' + 'Date { 1 }'), '$x = 1', ($kw + 'ForEach-' + 'Object { 2 }')) -join "`n"
    $r = Get-CsFindings -Text $fxTwo -Builtins $B
    CsT 'MUST FIRE  two definitions in one file are two findings, on lines 1 and 3' (@($r.Findings).Count -eq 2 -and $r.Findings[0].Line -eq 1 -and $r.Findings[1].Line -eq 3) (CsGot $r)

    # ---- MUST NOT FIRE: the renamed forms and the shapes that are not definitions -----------------------------
    $fxRenamed = @(
      ($kw + 'Get-' + 'QueueItem($doc, [string]$term) {'),
      '  return @($doc.items | Where-Object { [string]$_.term -eq $term })[0]',
      '}',
      '$liveBefore = (Get-FileHash -LiteralPath $live -Algorithm MD5).Hash'
    ) -join "`n"
    $r = Get-CsFindings -Text $fxRenamed -Builtins $B
    CsT 'MUST NOT FIRE  the lookup renamed Get-QueueItem, the fix Brad chose on 2026-09-11' (@($r.Findings).Count -eq 0 -and $r.ParseErrors -eq 0) (CsGot $r)
    $fxProse = @(
      ('# was: ' + $kw + 'Get-' + 'Item($doc, $term)'),
      ('Write-Output ''' + $kw + 'Get-' + 'Date { }'''),
      '$h = @''',
      ($kw + 'Format-' + 'List { }'),
      '''@'
    ) -join "`n"
    $r = Get-CsFindings -Text $fxProse -Builtins $B
    CsT 'MUST NOT FIRE  a definition quoted in a comment, a string and a here-string is not a definition' (@($r.Findings).Count -eq 0) (CsGot $r)
    $fxCall = '$n = (Get-' + 'Item $live).Length; Get-' + 'Date | Out-Null'
    $r = Get-CsFindings -Text $fxCall -Builtins $B
    CsT 'MUST NOT FIRE  CALLING the cmdlets defines nothing' (@($r.Findings).Count -eq 0) (CsGot $r)
    $fxPrefix = $kw + 'Get-' + 'Items($d) { }; ' + $kw + 'Format-' + 'ListRow { }'
    $r = Get-CsFindings -Text $fxPrefix -Builtins $B
    CsT 'MUST NOT FIRE  a name that merely STARTS with a built-in name is a different command' (@($r.Findings).Count -eq 0) (CsGot $r)
    $fxSetItem = 'Set-Item -Path function:Get-' + 'Item -Value { ''x'' }'
    $r = Get-CsFindings -Text $fxSetItem -Builtins $B
    CsT 'MUST NOT FIRE  UNSOUND BY DESIGN, as the header says: a function made with Set-Item function: is not seen' (@($r.Findings).Count -eq 0) (CsGot $r)

    # ---- CLEAN TWIN: the adjacent behaviour an exemption was most likely to break ----------------------------
    $fxMixed = $fxRenamed + "`n" + $fxReel
    $r = Get-CsFindings -Text $fxMixed -Builtins $B
    CsT 'CLEAN TWIN  a renamed lookup beside a shadowing formatter still reports the formatter, on line 5' (@($r.Findings).Count -eq 1 -and $r.Findings[0].Line -eq 5) (CsGot $r)

    # ---- THE ALLOWLIST ----------------------------------------------------------------------------------------
    $allow = @([pscustomobject]@{ File = 'grocery/test-auditors.ps1'; Name = ('Get-' + 'Date'); Reason = 'fixture' })
    $fMock = [pscustomobject]@{ File = 'grocery/test-auditors.ps1'; Name = ('Get-' + 'Date'); Line = 2964; Module = 'x' }
    $s = Split-CsAllowed -Findings @($fMock) -Allow $allow
    CsT 'MUST NOT FIRE  a definition on the allowlist is not a new finding' (@($s.New).Count -eq 0 -and @($s.Stale).Count -eq 0) ('new=' + @($s.New).Count + ' stale=' + @($s.Stale).Count)
    CsT 'CLEAN TWIN  ...and it is still COUNTED as allowed, so the live summary keeps it in the denominator' (@($s.Allowed).Count -eq 1) ('allowed=' + @($s.Allowed).Count)
    $fElsewhere = [pscustomobject]@{ File = 'grocery/other.ps1'; Name = ('Get-' + 'Date'); Line = 9; Module = 'x' }
    $s = Split-CsAllowed -Findings @($fMock, $fElsewhere) -Allow $allow
    CsT 'MUST FIRE  the same name in ANOTHER file is new: an entry is keyed on file and name, never on the name alone' (@($s.New).Count -eq 1 -and $s.New[0].File -eq 'grocery/other.ps1') ('new=' + @($s.New).Count)
    $s = Split-CsAllowed -Findings @() -Allow $allow
    CsT 'MUST FIRE  an allowlist entry that matches no definition is STALE, so the list cannot outlive its reasons' (@($s.Stale).Count -eq 1) ('stale=' + @($s.Stale).Count)
    $allowBack = @([pscustomobject]@{ File = 'Grocery\Test-Auditors.ps1'; Name = ('get-' + 'date'); Reason = 'fixture' })
    $s = Split-CsAllowed -Findings @($fMock) -Allow $allowBack
    CsT 'CLEAN TWIN  an entry spelled with backslashes and another case still covers its definition' (@($s.Allowed).Count -eq 1 -and $s.Allowed[0].Line -eq 2964) ('allowed=' + @($s.Allowed).Count + ' new=' + @($s.New).Count)

    # ---- THE NAME LIST ----------------------------------------------------------------------------------------
    $short = ($fxList -split "`n" | Where-Object { $_ -notmatch ('^Format-' + 'List\t') }) -join "`n"
    $bs = ConvertFrom-CsBuiltinsText -Text $short
    CsT 'MUST FIRE  a list missing an anchor name reports it, which the live run reads as BLIND' (@($bs.Missing).Count -eq 1 -and $bs.Missing[0] -eq ('Format-' + 'List')) ('missing=' + (@($bs.Missing) -join ','))
    $rows = @(
      [pscustomobject]@{ Name = ('Get-' + 'Item'); Source = 'Microsoft.PowerShell.Management'; ModuleBase = '' },
      [pscustomobject]@{ Name = ('Get-' + 'Disk'); Source = 'Storage'; ModuleBase = 'C:\PSH\Modules\Storage' },
      [pscustomobject]@{ Name = ('Get-' + 'Disk'); Source = 'Other'; ModuleBase = 'C:\PSH\Modules\Other' },
      [pscustomobject]@{ Name = 'Invoke-Pester'; Source = 'Pester'; ModuleBase = 'C:\Program Files\WindowsPowerShell\Modules\Pester' },
      [pscustomobject]@{ Name = 'Pause'; Source = ''; ModuleBase = '' },
      [pscustomobject]@{ Name = 'C:'; Source = ''; ModuleBase = '' }
    )
    $gen = ConvertTo-CsBuiltinsText -Rows $rows -PsHomeDir 'C:\PSH' -PsVersion '5.1'
    $gl = ConvertFrom-CsBuiltinsText -Text $gen
    CsT 'CLEAN TWIN  what -Regenerate writes, the loader reads: in-box and session names kept, both modules named for a shared name' ($gl.Map.Count -eq 3 -and $gl.Map[('Get-' + 'Disk')] -eq 'Other,Storage' -and $gl.Map['Pause'] -eq '(session)') ('count=' + $gl.Map.Count + ' disk=' + $gl.Map[('Get-' + 'Disk')])
    CsT 'MUST NOT FIRE  a module installed outside $PSHOME (Pester) and a drive function (C:) are left out of the list' (-not $gl.Map.ContainsKey('Invoke-Pester') -and -not $gl.Map.ContainsKey('C:')) ('keys=' + (@($gl.Map.Keys) -join ','))
    $committed = ConvertFrom-CsBuiltinsText -Text ([IO.File]::ReadAllText($BUILTINS_FILE))
    CsT 'CLEAN TWIN  the committed ops\cmdlet-shadow-builtins.txt loads and carries every anchor' ($committed.Map.Count -gt 300 -and @($script:CS_ANCHORS | Where-Object { $committed.Map.ContainsKey($_) }).Count -eq $script:CS_ANCHORS.Count) ('count=' + $committed.Map.Count + ' missing=' + (@($committed.Missing) -join ','))

    # ---- THE WALK ---------------------------------------------------------------------------------------------
    $scan = Get-CsScanFiles -RootDir $repo -SelfRel $SELF_REL
    $scripts = @($scan.Files | Where-Object { $_ -match '(?i)\.psm?1$' })
    CsT 'CLEAN TWIN  this checkout, worktree or not, resolves its tracked scripts, the anchor among them, only .ps1 and .psm1' ($scan.Ok -and @($scan.Files).Count -gt 0 -and ($scan.Files -contains $script:CS_ANCHOR_FILE) -and $scripts.Count -eq @($scan.Files).Count) ('ok=' + $scan.Ok + ' files=' + @($scan.Files).Count + ' scripts=' + $scripts.Count + ' ' + $scan.Error)
    CsT 'MUST NOT FIRE  the detector never scans itself' (-not ($scan.Files -contains $SELF_REL)) ''
    # A per-run directory, with git told not to climb above it, so no enclosing checkout can answer for it.
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('tc-cs-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
    $ceiling = $env:GIT_CEILING_DIRECTORIES
    try {
      $null = New-Item -ItemType Directory -Path $tmp -ErrorAction Stop
      $env:GIT_CEILING_DIRECTORIES = Split-Path $tmp -Parent
      $blind = Get-CsScanFiles -RootDir $tmp -SelfRel $SELF_REL
      CsT 'MUST FIRE  a directory that is not a checkout resolves NOT OK, which the live run reads as BLIND rather than clean' (-not $blind.Ok) ('ok=' + $blind.Ok + ' files=' + @($blind.Files).Count)
    } finally {
      $env:GIT_CEILING_DIRECTORIES = $ceiling
      if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }
  } catch {
    $script:cases++; $script:fail++
    Write-Output ('  FAIL  the self-test THREW, so every case after this point did not run: ' + $_.Exception.Message)
  }

  if ($script:cases -eq 0) { $script:fail++ }
  ''
  if ($script:fail) {
    Write-Output ("cmdlet-shadow selftest: {0} FAILED of {1}" -f $script:fail, $script:cases)
    Exit-Guard -Name 'CMDLET-SHADOW-SELFTEST' -Code 2 -Summary ("failed={0} of {1}" -f $script:fail, $script:cases)
  }
  Write-Output ("cmdlet-shadow selftest: {0} of {0} cases pass (the three founding definitions fire, the renamed forms stay silent, the allowlist is keyed and closed, the walk reads this checkout)" -f $script:cases)
  Exit-Guard -Name 'CMDLET-SHADOW-SELFTEST' -Code 0 -Summary ("cases={0}" -f $script:cases)
}

# ------------------------------------------------------------------------------------------------- live run
if (-not (Test-Path -LiteralPath $BUILTINS_FILE)) {
  Write-Output 'audit-cmdlet-shadow: BLIND - ops\cmdlet-shadow-builtins.txt is missing, so there is no name to compare a definition to'
  Exit-Guard -Name 'AUDIT-CMDLET-SHADOW' -Code 3 -Summary 'blind=no-name-list'
}
$bl = ConvertFrom-CsBuiltinsText -Text ([IO.File]::ReadAllText($BUILTINS_FILE))
if (@($bl.Missing).Count) {
  Write-Output ('audit-cmdlet-shadow: BLIND - the name list lacks anchor name(s) ' + (@($bl.Missing) -join ', ') + ', so it was truncated or generated wrong; re-run -Regenerate')
  Exit-Guard -Name 'AUDIT-CMDLET-SHADOW' -Code 3 -Summary ("blind=list-missing-anchors names={0}" -f $bl.Map.Count)
}
$scan = Get-CsScanFiles -RootDir $repo -SelfRel $SELF_REL
if (-not $scan.Ok -or -not @($scan.Files).Count -or -not ($scan.Files -contains $script:CS_ANCHOR_FILE)) {
  Write-Output ("audit-cmdlet-shadow: BLIND - resolved {0} tracked script(s) and {1}, which means the discovery is broken, not that the tree is clean. {2}" -f @($scan.Files).Count, $(if ($scan.Files -contains $script:CS_ANCHOR_FILE) { 'the anchor among them' } else { 'NOT ' + $script:CS_ANCHOR_FILE }), $scan.Error)
  Exit-Guard -Name 'AUDIT-CMDLET-SHADOW' -Code 3 -Summary ("blind=discovery files={0}" -f @($scan.Files).Count)
}

$all = New-Object System.Collections.ArrayList
$read = 0; $absent = 0; $parseErrorFiles = @()
foreach ($rel in $scan.Files) {
  $full = Join-Path $repo ($rel.Replace('/', '\'))
  if (-not (Test-Path -LiteralPath $full)) { $absent++; continue }   # tracked, deleted in this checkout
  $r = Get-CsFindings -Text ([IO.File]::ReadAllText($full)) -Builtins $bl.Map
  $read++
  if ($r.ParseErrors) { $parseErrorFiles += $rel }
  foreach ($h in $r.Findings) { [void]$all.Add([pscustomobject]@{ File = $rel; Line = $h.Line; Name = $h.Name; Module = $h.Module }) }
}
$split = Split-CsAllowed -Findings $all.ToArray() -Allow $script:CS_ALLOW
$nNew = @($split.New).Count; $nAllowed = @($split.Allowed).Count; $nStale = @($split.Stale).Count

Write-Output ("audit-cmdlet-shadow: {0} tracked .ps1/.psm1 resolved, {1} read ({2} deleted in this checkout, {3} with a parse error) against {4} built-in names; {5} definition(s) carry one: {6} allowlisted, {7} new; {8} stale allowlist entr(ies)" -f @($scan.Files).Count, $read, $absent, $parseErrorFiles.Count, $bl.Map.Count, $all.Count, $nAllowed, $nNew, $nStale)
foreach ($p in $parseErrorFiles) { Write-Output ('  parse error (partial AST read)  ' + $p) }
foreach ($f in $split.Allowed) {
  $why = @($script:CS_ALLOW | Where-Object { [string]::Equals($_.Name, $f.Name, [StringComparison]::OrdinalIgnoreCase) -and [string]::Equals($_.File.Replace('\', '/'), $f.File, [StringComparison]::OrdinalIgnoreCase) })[0].Reason
  Write-Output ("  allowed  {0}:{1}  function {2} ({3}) - {4}" -f $f.File, $f.Line, $f.Name, $f.Module, $why)
}
foreach ($f in $split.New) { Write-Output ("  SHADOW   {0}:{1}  function {2} hides the {3} command of that name everywhere in its scope" -f $f.File, $f.Line, $f.Name, $f.Module) }
foreach ($a in $split.Stale) { Write-Output ("  STALE    allowlist entry {0} / {1} matches no definition - delete it from `$script:CS_ALLOW in ops\audit-cmdlet-shadow.ps1" -f $a.File, $a.Name) }

$summary = "scanned={0} findings={1} allowed={2} new={3} stale={4}" -f $read, $all.Count, $nAllowed, $nNew, $nStale
if ($nNew -or $nStale) {
  if ($nNew) {
    Write-Output '  A script function outranks a cmdlet of the same name, so every call to that name in its scope now runs the'
    Write-Output '  function and nothing errors. On 2026-09-11 that left ingredient-queue''s live-ledger assertion unable to fire'
    Write-Output '  for 17 days. Rename the function (a noun of its own: Get-QueueItem, Format-RowList). If the shadow IS the'
    Write-Output '  point, as a scoped mock is, add a file-and-name entry with its reason to $script:CS_ALLOW.'
  }
  Exit-Guard -Name 'AUDIT-CMDLET-SHADOW' -Code 1 -Summary $summary
}
Exit-Guard -Name 'AUDIT-CMDLET-SHADOW' -Code 0 -Summary $summary
