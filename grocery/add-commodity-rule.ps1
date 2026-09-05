<#
  add-commodity-rule.ps1 - add include/exclude patterns to a commodity in commodities.json, SURGICALLY.

  WHY TEXT SURGERY AND NOT ConvertFrom-Json | ConvertTo-Json. commodities.json is 2.2 MB across 505 entries.
  Round-tripping it through PowerShell 5.1's ConvertTo-Json reformats every line, escapes every non-ASCII
  character, and silently truncates past -Depth. The diff would be 54,000 lines wide, which means nobody can
  review it and a mangled regex three commodities away would never be spotted. So this edits the bytes of one
  entry and PROVES it touched nothing else.

  THE PROOF (this is the part that matters): after writing, it re-parses the file and compares EVERY entry's
  serialized form against the original. Any entry other than the target that differs by a single character is
  a hard failure and the file is rolled back. A rule editor that can quietly corrupt a neighbour is worse than
  editing by hand, because it looks careful.

  RELAX_GLOBAL IS A THIRD LIST, AND IT IS THE ONE THAT HAD NO PATH (2026-08-28). The board applies a
  set of GLOBAL excludes to every commodity - `\bfrozen\b` among them - and a commodity that IS the
  frozen thing has to opt out of the one that would erase it. frozen-broccoli and frozen-vegetables
  both carry `relax_global`, so the shape has been settled since long before this script; what did
  not exist was any gated way to write it. The registrar's 2026-08-28 ruling on
  frozen-cauliflower-rice routed the edit "through add-commodity-rule.ps1", which could not do it,
  and without the field the global frozen exclude drops every ad for the id - so it keeps its
  everyday price and simply never sees a sale. That is a silent half-price, not a visible error.

  AND UNLIKE include/exclude, THIS ONE MAY HAVE TO CREATE ITS ARRAY. Every commodity has include and
  exclude; almost none has relax_global. Creating a key is a bigger act than appending to one, so it
  is placed exactly where ConvertTo-Json would have put it - immediately before "include", matching
  frozen-broccoli byte for byte in shape - and the whole-file proof below is unchanged: every OTHER
  entry must still serialize identically or nothing is written.

  Usage:
    add-commodity-rule.ps1 -Id pears -Exclude 'irregular\s+pears?'
    add-commodity-rule.ps1 -Id frozen-cauliflower-rice -RelaxGlobal '\bfrozen\b'
    add-commodity-rule.ps1 -Id canned-pears -Include 'irregular\s+pears?' -Why "Fareway's canned pear pack"
    add-commodity-rule.ps1 -Id pears -Exclude 'a','b' -DryRun

  Patterns are stored verbatim. They are validated as legal .NET regex BEFORE anything is written, because an
  invalid pattern in this file throws at board-build time, i.e. at 3am in the nightly, not here.

  Exit 0 = written (or DryRun clean). Exit 1 = refused, nothing written.
#>
param(
  # NOT Mandatory, and the refusal below is why. run-gates invokes every gated script as
  # `-SelfTest` and nothing else, so a mandatory -Id makes the self-test unrunnable - PowerShell
  # refuses the call before a single line of the script executes. The requirement has not been
  # relaxed, it has been moved to where it can coexist with the drill.
  [string]$Id = '',
  [string[]]$Include = @(),
  [string[]]$Exclude = @(),
  [string[]]$RemoveExclude = @(),
  [string[]]$RemoveInclude = @(),
  [string[]]$RelaxGlobal = @(),
  [string[]]$RemoveRelaxGlobal = @(),
  [string]$Why = '',
  [string]$File = '',
  [switch]$DryRun,
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $File) { $File = Join-Path $root 'commodities.json' }
function Say([string]$s) { Write-Output $s }
function Die([string]$s) { Write-Output ('add-commodity-rule: ' + $s); exit 1 }

# ---- SELF-TEST ---------------------------------------------------------------------------------
# It drives the REAL script as a child process against a scratch file, rather than dot-sourcing its
# internals. That is the point: the thing this script promises is "the bytes of one entry change and
# nothing else does", and only an end-to-end run over a whole file can show that. Until 2026-08-28
# this script had no self-test at all, so run-gates never saw it.
# A FUNCTION SO IT CAN ACTUALLY BE TESTED. Driving this through the self-test's Run helper cannot
# reach it: Run shells out with `& powershell -File`, and a native-exe argument list DROPS an empty
# string element before the script ever binds it - so a case written that way passes whether the check
# exists or not. A direct `.\add-commodity-rule.ps1 -Include ''` binds it just fine, which is how the
# 2026-08-31 incident happened. The rule is testable in-process; the invocation is not.
function Test-PatternUsable {
  <# $true when this pattern may be written. An EMPTY pattern is a LEGAL regex and a catastrophe:
     [regex]::new('') succeeds and matches EVERY product string. On 2026-08-31 a stray -Include ''
     wrote a zero-length include onto dried-parsley and that commodity immediately swallowed roach
     gel, freezer bags, evaporated goat milk and acorn squash. Two other guards caught it inside one
     run (audit-household-in-food, 11 rows; compare-deals' routing fixtures, 6 red) - but nothing HERE
     said no, in the one file whose whole purpose is to refuse rather than guess.
     Whitespace counts as empty: '\s*' is a deliberate pattern, a bare space is a typo. #>
  param([string]$P)
  return -not [string]::IsNullOrWhiteSpace($P)
}

if ($SelfTest) {
  $bad = 0
  function T([string]$n, [bool]$ok, [string]$got) {
    if ($ok) { Write-Output ('  ok    ' + $n) } else { Write-Output ('  X     ' + $n + '   got: ' + $got); $script:bad++ }
  }
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ('acr-selftest-' + [guid]::NewGuid().ToString('N'))
  [void](New-Item -ItemType Directory -Path $tmp)
  try {
    $f = Join-Path $tmp 'c.json'
    $seed = @(
      [ordered]@{ id = 'alpha'; label = 'Alpha'; unit = 'oz'; include = @('alpha'); exclude = @('nope') },
      [ordered]@{ id = 'frozen-thing'; label = 'Frozen Thing'; unit = 'oz'; include = @('frozen\s+thing'); exclude = @('fresh') },
      [ordered]@{ id = 'omega'; label = 'Omega'; unit = 'lb'; relax_global = @('\bfrozen\b'); include = @('omega'); exclude = @() }
    )
    [IO.File]::WriteAllText($f, (ConvertTo-Json $seed -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
    $self = $PSCommandPath; if (-not $self) { $self = $MyInvocation.MyCommand.Path }
    function Run { param([object[]]$a) $o = & powershell -NoProfile -ExecutionPolicy Bypass -File $self @a; return @{ rc = $LASTEXITCODE; out = ($o -join "`n") } }
    function Doc { (Read-JsonFile $f) }
    function Ent([string]$i) { @(Doc) | Where-Object { $_.id -eq $i } }

    # CREATE the key on an entry that has never had one - the frozen-cauliflower-rice case exactly.
    $r = Run @('-Id','frozen-thing','-RelaxGlobal','\bfrozen\b','-File',$f)
    T 'relax_global is CREATED on an entry that has none' ($r.rc -eq 0 -and @((Ent 'frozen-thing').relax_global) -contains '\bfrozen\b') $r.out
    # ...and the neighbours are untouched, which is the whole safety contract.
    T '  ...and no other entry moved' (((Ent 'alpha') | ConvertTo-Json -Compress) -eq (($seed[0] | ConvertTo-Json -Compress)) -and @((Ent 'omega').relax_global).Count -eq 1) 'neighbour changed'
    # APPEND to an entry that already has one - it must not create a second key.
    $r = Run @('-Id','omega','-RelaxGlobal','\bchilled\b','-File',$f)
    T 'relax_global APPENDS when the array already exists' ($r.rc -eq 0 -and @((Ent 'omega').relax_global).Count -eq 2) $r.out
    $keyN = [regex]::Matches((Get-Content $f -Raw), '"relax_global"').Count
    T '  ...and did not create a duplicate key' ($keyN -eq 2) ("relax_global key count across the file = $keyN, expected 2 (frozen-thing + omega, one each)")
    # MUST FIRE: an invalid regex never reaches the file.
    $r = Run @('-Id','alpha','-RelaxGlobal','[unclosed','-File',$f)
    T 'MUST FIRE  an invalid regex is refused before any write' ($r.rc -ne 0 -and $null -eq (Ent 'alpha').relax_global) $r.out
    # MUST FIRE: an EMPTY pattern. It is a LEGAL regex, so the check above waves it through, and it
    # matches every product string - on 2026-08-31 a stray -Include '' gave dried-parsley the whole
    # catalogue (roach gel, freezer bags, goat milk, acorn squash) until two other guards caught it.
    # TESTED IN-PROCESS, because the process boundary eats the very input this defends against: a
    # native-exe argument list drops an empty string element, so no Run-based case can reach it. Two
    # earlier cuts of this case passed for that reason alone and the neuter is what exposed both.
    T 'MUST FIRE  an EMPTY pattern is refused - it is legal regex and matches every product' `
      (-not (Test-PatternUsable '')) 'an empty pattern would be written'
    T 'MUST FIRE  ...and so is whitespace-only' `
      ((-not (Test-PatternUsable ' ')) -and (-not (Test-PatternUsable "`t"))) 'a blank pattern would be written'
    T 'CLEAN TWIN  a real pattern is still usable' `
      ((Test-PatternUsable 'canned\s+potatoes') -and (Test-PatternUsable '\s*sample\s*')) 'a good pattern was refused'
    $excBefore = @((Ent 'alpha').exclude).Count
    $r = Run @('-Id','alpha','-Exclude','   ','-File',$f)
    T 'MUST FIRE  ...and a whitespace-only pattern too' `
      ($r.rc -ne 0 -and @((Ent 'alpha').exclude).Count -eq $excBefore) $r.out
    # CLEAN TWIN: a deliberate whitespace PATTERN is not a blank one and must still be accepted.
    $r = Run @('-Id','alpha','-Exclude','\s*sample\s*','-File',$f)
    T 'CLEAN TWIN  a real pattern containing whitespace classes is still accepted' ($r.rc -eq 0) $r.out
    # MUST FIRE: a dry run reports and writes nothing.
    $b4 = Get-Content $f -Raw
    $r = Run @('-Id','alpha','-RelaxGlobal','\bfrozen\b','-File',$f,'-DryRun')
    T 'MUST FIRE  -DryRun writes nothing' ($r.rc -eq 0 -and (Get-Content $f -Raw) -eq $b4) $r.out
    # MUST FIRE: removal takes it back out again, so a bad pattern can be replaced not layered over.
    $r = Run @('-Id','omega','-RemoveRelaxGlobal','\bchilled\b','-File',$f)
    T 'MUST FIRE  -RemoveRelaxGlobal takes a pattern back out' ($r.rc -eq 0 -and @((Ent 'omega').relax_global).Count -eq 1) $r.out
    # CLEAN TWIN: the include/exclude road still behaves exactly as it did.
    $r = Run @('-Id','alpha','-Exclude','banana','-File',$f)
    T 'CLEAN TWIN an exclude still appends as before' ($r.rc -eq 0 -and @((Ent 'alpha').exclude) -contains 'banana') $r.out
    # MUST FIRE: an id that is not there is refused, not created.
    $r = Run @('-Id','no-such-id','-RelaxGlobal','x','-File',$f)
    # ASSERT THE REASON, NOT MERELY THE EXIT CODE. Tearing the id refusal out left this case GREEN:
    # the script ran on without a target and failed later for an unrelated reason, so a non-zero exit
    # proved only that something went wrong somewhere. The message is what distinguishes the two.
    T 'MUST FIRE  an unknown id is refused BY NAME, never created' ($r.rc -ne 0 -and $r.out -match 'no commodity with id' -and @(Doc).Count -eq 3) $r.out
  } finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
  if ($bad) { Write-Output ("add-commodity-rule SELF-TEST FAIL ({0})" -f $bad); exit 1 }
  Write-Output 'add-commodity-rule SELF-TEST PASS'; exit 0
}

if (-not $Id) { Die 'pass -Id <commodity id> (or -SelfTest). An edit with no target is not a default, it is a mistake.' }
if (-not (Test-Path $File)) { Die ('file not found: ' + $File) }
if ($Include.Count -eq 0 -and $Exclude.Count -eq 0 -and $RemoveExclude.Count -eq 0 -and $RemoveInclude.Count -eq 0 -and
    $RelaxGlobal.Count -eq 0 -and $RemoveRelaxGlobal.Count -eq 0) {
  Die 'nothing to do: pass -Include / -Exclude / -RelaxGlobal / -Remove*.'
}


# validate every pattern as a real regex before touching the file
foreach ($p in ($Include + $Exclude + $RelaxGlobal)) {
  # AN EMPTY PATTERN IS A VALID REGEX AND A CATASTROPHE, so it is refused before the regex check
  # rather than by it. [regex]::new('') succeeds and matches EVERY string; on 2026-08-31 a call that
  # passed -Include '' alongside -RemoveExclude wrote a zero-length include onto dried-parsley, and
  # that commodity immediately swallowed roach gel, freezer bags, evaporated goat milk and acorn
  # squash. It was caught the same run - audit-household-in-food found 11 rows and compare-deals' own
  # routing fixtures went 6 red - but nothing here said no, and this is the file whose whole purpose
  # is to refuse rather than guess. Whitespace is treated the same: '\s*' is a deliberate pattern, but
  # a bare space is a typo.
  if (-not (Test-PatternUsable $p)) {
    Die 'an EMPTY (or whitespace-only) pattern was passed. It is a legal regex that matches every product string, so it would hand this commodity the entire catalogue. Refusing - if you meant to remove a pattern, use -RemoveInclude / -RemoveExclude on its own.'
  }
  try { [void][regex]::new($p) } catch { Die ('not a valid regex, refusing: ' + $p + '  (' + $_.Exception.Message + ')') }
}

$raw = [IO.File]::ReadAllText($File)
$before = $raw | ConvertFrom-Json
# TWO FILE SHAPES, ONE TOOL (2026-08-27) - the same gap new-commodity.ps1 carried, in its sibling.
# commodities.json is a bare top-level array; recipe-commodities.json nests its entries under a
# `commodities` key. Without this, every id in the RECIPE namespace answered "no commodity with id" -
# and the recipe namespace is exactly where the registrar sends form-splits, so a ruling could be
# approved and then be unexecutable by the two tools that exist to execute it.
$Entries = { param($doc) if ($null -ne $doc -and $doc.PSObject.Properties.Name -contains 'commodities') { return @($doc.commodities) } return @($doc) }
$bList = New-Object System.Collections.ArrayList; foreach ($x in (& $Entries $before)) { [void]$bList.Add($x) }
$target = $bList | Where-Object { [string]$_.id -eq $Id }
if ($null -eq $target) { Die ('no commodity with id ''' + $Id + '''. It must exist already; this script does not create commodities.') }

# ---- locate the entry's text block ----------------------------------------------------------------------
# Anchor on the id line, then walk braces outward to the object that contains it. Brace-walking (rather than a
# regex for the whole object) is what makes this safe against nested arrays and escaped braces in patterns.
$idPat = '"id":\s*"' + [regex]::Escape($Id) + '"'
$m = [regex]::Match($raw, $idPat)
if (-not $m.Success) { Die ('could not find the id line for ' + $Id + ' in the raw text.') }
if ([regex]::Matches($raw, $idPat).Count -ne 1) { Die ('the id ' + $Id + ' appears more than once in the raw text; refusing to guess which one.') }
$start = $raw.LastIndexOf('{', $m.Index)
if ($start -lt 0) { Die 'could not find the opening brace of the entry.' }
$depth = 0; $end = -1
for ($i = $start; $i -lt $raw.Length; $i++) {
  $ch = $raw[$i]
  if ($ch -eq '"') { # skip strings, honouring backslash escapes
    $i++
    while ($i -lt $raw.Length -and $raw[$i] -ne '"') { if ($raw[$i] -eq '\') { $i++ }; $i++ }
    continue
  }
  if ($ch -eq '{') { $depth++ }
  elseif ($ch -eq '}') { $depth--; if ($depth -eq 0) { $end = $i; break } }
}
if ($end -lt 0) { Die 'could not find the closing brace of the entry.' }
$block = $raw.Substring($start, $end - $start + 1)

# ---- insert into an array inside that block --------------------------------------------------------------
function Add-ToArray([string]$blk, [string]$key, [string[]]$vals) {
  if ($vals.Count -eq 0) { return $blk }
  $km = [regex]::Match($blk, '"' + $key + '":\s*\[')
  if (-not $km.Success) { throw ('entry has no "' + $key + '" array; this script does not create the array.') }
  # find the matching ] for this [
  $open = $blk.IndexOf('[', $km.Index)
  $d = 0; $close = -1
  for ($i = $open; $i -lt $blk.Length; $i++) {
    $ch = $blk[$i]
    if ($ch -eq '"') { $i++; while ($i -lt $blk.Length -and $blk[$i] -ne '"') { if ($blk[$i] -eq '\') { $i++ }; $i++ }; continue }
    if ($ch -eq '[') { $d++ } elseif ($ch -eq ']') { $d-- ; if ($d -eq 0) { $close = $i; break } }
  }
  if ($close -lt 0) { throw ('could not find the end of the "' + $key + '" array.') }
  $inner = $blk.Substring($open + 1, $close - $open - 1)
  $isEmpty = ($inner.Trim().Length -eq 0)
  # match the file's existing indentation for array elements
  $indent = '                    '
  $im = [regex]::Match($inner, '(?m)^([ \t]+)"')
  if ($im.Success) { $indent = $im.Groups[1].Value }
  $enc = @()
  foreach ($v in $vals) { $enc += ($indent + (ConvertTo-Json $v -Compress)) }
  $add = ($enc -join (",`r`n"))
  if ($isEmpty) { $newInner = "`r`n" + $add + "`r`n" + ($indent.Substring(0, [Math]::Max(0, $indent.Length - 4))) }
  else { $newInner = $inner.TrimEnd() + ",`r`n" + $add + "`r`n" + ($indent.Substring(0, [Math]::Max(0, $indent.Length - 4))) }
  return $blk.Substring(0, $open + 1) + $newInner + $blk.Substring($close)
}

# CREATE a key that is not there yet, in the place ConvertTo-Json would have written it. The element
# indent is not decorative: this file is 2.2 MB and the whole reason for text surgery is that a diff
# stays reviewable, so a new key that lands at a different indent than its neighbours makes the one
# line a human must read look like the one line a human cannot trust. Measured off frozen-broccoli:
# elements sit at (key indent + the quoted key's length + 7), and the closing bracket 4 back from
# that - exactly what Add-ToArray already assumes when it appends.
function New-KeyArray([string]$blk, [string]$key, [string[]]$vals, [string]$beforeKey) {
  if ($vals.Count -eq 0) { return $blk }
  $bm = [regex]::Match($blk, '(?m)^([ \t]*)"' + $beforeKey + '":')
  if (-not $bm.Success) { throw ('cannot place "' + $key + '": the entry has no "' + $beforeKey + '" key to sit before.') }
  $keyIndent = $bm.Groups[1].Value
  $elem  = $keyIndent + (' ' * (($key.Length + 2) + 7))
  $close = $elem.Substring(0, [Math]::Max(0, $elem.Length - 4))
  $enc = @(); foreach ($v in $vals) { $enc += ($elem + (ConvertTo-Json $v -Compress)) }
  $text = $keyIndent + '"' + $key + '":  [' + "`r`n" + ($enc -join (",`r`n")) + "`r`n" + $close + '],' + "`r`n"
  return $blk.Substring(0, $bm.Index) + $text + $blk.Substring($bm.Index)
}

function Remove-FromArray([string]$blk, [string]$key, [string[]]$vals) {
  # Removal exists so a bad pattern can be REPLACED, not layered over. Matching is on the exact stored string:
  # a fuzzy match here would delete a neighbouring rule that merely looks similar, and exclude lists are the
  # armour that keeps cat food out of the salmon cell.
  if ($vals.Count -eq 0) { return $blk }
  foreach ($v in $vals) {
    $enc = [regex]::Escape((ConvertTo-Json $v -Compress))
    # element plus its trailing comma+newline, or (if it is last) its LEADING comma+newline
    $pat1 = '(?m)^[ \t]*' + $enc + ',\r?\n'
    $pat2 = ',\r?\n[ \t]*' + $enc + '(?=\r?\n)'
    if ($blk -match $pat1) { $blk = [regex]::Replace($blk, $pat1, '', 1) }
    elseif ($blk -match $pat2) { $blk = [regex]::Replace($blk, $pat2, '', 1) }
    else { throw ('cannot remove from "' + $key + '": pattern not present verbatim -> ' + $v) }
  }
  return $blk
}

$newBlock = $block
try {
  $newBlock = Remove-FromArray $newBlock 'include' $RemoveInclude
  $newBlock = Remove-FromArray $newBlock 'exclude' $RemoveExclude
  $newBlock = Remove-FromArray $newBlock 'relax_global' $RemoveRelaxGlobal
  $newBlock = Add-ToArray $newBlock 'include' $Include
  $newBlock = Add-ToArray $newBlock 'exclude' $Exclude
  # APPEND IF IT IS THERE, CREATE IF IT IS NOT - and never both.
  if ($RelaxGlobal.Count -gt 0) {
    if ($newBlock -match '"relax_global":\s*\[') { $newBlock = Add-ToArray $newBlock 'relax_global' $RelaxGlobal }
    else { $newBlock = New-KeyArray $newBlock 'relax_global' $RelaxGlobal 'include' }
  }
} catch { Die $_.Exception.Message }

$newRaw = $raw.Substring(0, $start) + $newBlock + $raw.Substring($end + 1)

# ---- prove it ---------------------------------------------------------------------------------------------
$after = $null
try { $after = $newRaw | ConvertFrom-Json } catch { Die ('the edit produced invalid JSON, nothing written: ' + $_.Exception.Message) }
$aList = New-Object System.Collections.ArrayList; foreach ($x in (& $Entries $after)) { [void]$aList.Add($x) }
if ($aList.Count -ne $bList.Count) { Die ('entry count changed ' + $bList.Count + ' -> ' + $aList.Count + '; refusing.') }

$collateral = New-Object System.Collections.ArrayList
for ($i = 0; $i -lt $bList.Count; $i++) {
  $bi = $bList[$i]; $ai = $aList[$i]
  if ([string]$bi.id -ne [string]$ai.id) { Die ('entry order changed at index ' + $i + '; refusing.') }
  if ([string]$bi.id -eq $Id) { continue }
  $bs = ($bi | ConvertTo-Json -Depth 8 -Compress)
  $as = ($ai | ConvertTo-Json -Depth 8 -Compress)
  if ($bs -ne $as) { [void]$collateral.Add([string]$bi.id) }
}
if ($collateral.Count -gt 0) {
  Die ('COLLATERAL DAMAGE: ' + $collateral.Count + ' other commodit(ies) changed (' + (($collateral | Select-Object -First 5) -join ', ') + '). Nothing written.')
}

$tNew = $aList | Where-Object { [string]$_.id -eq $Id }
# @($null).Count IS 1 IN POWERSHELL 5.1, NOT 0. That is not a curiosity here, it is the difference
# between creating a key and being told you did not: an entry with no relax_global scored 1 for its
# absent list, so a successful creation read as "changed by 0, expected 1" and the proof refused a
# correct write. The self-test caught it on its first run. Absence is 0.
function Get-ListCount($v) { if ($null -eq $v) { return 0 }; return @($v).Count }
$gotInc = (Get-ListCount $tNew.include) - (Get-ListCount $target.include)
$gotExc = (Get-ListCount $tNew.exclude) - (Get-ListCount $target.exclude)
$gotRlx = (Get-ListCount $tNew.relax_global) - (Get-ListCount $target.relax_global)
$wantInc = $Include.Count - $RemoveInclude.Count
$wantExc = $Exclude.Count - $RemoveExclude.Count
$wantRlx = $RelaxGlobal.Count - $RemoveRelaxGlobal.Count
if ($gotInc -ne $wantInc) { Die ('include changed by ' + $gotInc + ', expected ' + $wantInc + '; refusing.') }
if ($gotExc -ne $wantExc) { Die ('exclude changed by ' + $gotExc + ', expected ' + $wantExc + '; refusing.') }
# THE SAME COUNT PROOF THE OTHER TWO GET. A created key that parsed but landed in the wrong entry, or
# an append that silently no-opped, both read as success without this line.
# NOTE, HONESTLY: the self-test below cannot make this line fire, and tearing it out leaves every
# case green. It is kept because it is the SAME arithmetic include and exclude already get and the
# three lists are edited by the same two helpers - a proof that is redundant today stops being
# redundant the first time someone adds a fourth road into this block. It is not claimed as proved.
if ($gotRlx -ne $wantRlx) { Die ('relax_global changed by ' + $gotRlx + ', expected ' + $wantRlx + '; refusing.') }

Say ('add-commodity-rule: ' + $Id + '  include ' + ('{0:+#;-#;+0}' -f $wantInc) + '  exclude ' + ('{0:+#;-#;+0}' -f $wantExc) + '  relax_global ' + ('{0:+#;-#;+0}' -f $wantRlx) + '   (' + $bList.Count + '-entry file verified: 0 collateral changes)')
foreach ($p in $RemoveInclude) { Say ('    -include  ' + $p) }
foreach ($p in $RemoveExclude) { Say ('    -exclude  ' + $p) }
foreach ($p in $Include) { Say ('    +include  ' + $p) }
foreach ($p in $Exclude) { Say ('    +exclude  ' + $p) }
foreach ($p in $RemoveRelaxGlobal) { Say ('    -relax    ' + $p) }
foreach ($p in $RelaxGlobal) { Say ('    +relax    ' + $p) }
if ($Why) { Say ('    why: ' + $Why) }
if ($DryRun) { Say '    DRY RUN - nothing written.'; exit 0 }
[IO.File]::WriteAllText($File, $newRaw, (New-Object System.Text.UTF8Encoding($false)))
Say ('    wrote ' + $File)
exit 0
