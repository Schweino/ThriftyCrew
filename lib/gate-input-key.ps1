<#
  gate-input-key.ps1 - the INPUT KEY of one gate, so a gate that already passed over exactly these bytes is not
  run again.

  Self-test:   powershell -File lib\gate-input-key.ps1 -SelfTest

  WHY (2026-09-12, Brad: "1141s per run is insane. If I have 20 sessions, they would be waiting a while to
  push"). lib\gate-verdict.ps1 already reuses a WHOLE run when the tree is byte-identical, which is why a
  re-push costs 3s. It cannot help the ordinary case: a session commits two files and every one of the 383
  gates runs again, including the 279 self-tests that could not have been affected. MEASURED that morning:
  874s of gate work in an up-to-date checkout and 1,141s estate-wide, against a median commit of 2 files. At
  10 slots that is 90 to 115s of machine time per push, and the push lock makes it serial: twenty sessions
  wait half an hour for the last one.

  THE KEY IS EVERY FILE THE GATE READS, and that is the whole safety argument. A gate is cached under a key
  built from its own bytes, the bytes of every library it dot-sources (transitively), the bytes of every
  repo file its source names as a literal, its argument, and the runner's own bytes. Change any of them and
  the key changes and the gate runs. The danger of a cache is a STALE PASS - a gate reported green over
  content it never saw - so the refusals below matter more than the hits.

  IT REFUSES MORE THAN IT ACCEPTS, DELIBERATELY. Measured over the 279 self-tests in the tree:
    185 cacheable      - every file they read is named in their source and goes into the key
     83 refused        - they read a DATA directory (grocery\out, meal-prep\db, public\, ...). Those bytes   # reach-fixture-ok: the shape this rule REFUSES, named in a pattern or written into a temp sandbox; nothing here opens a real data file
                         change with no commit at all, so no key over source could watch them.
     11 refused        - they build a path from a variable, and a key cannot watch what it cannot name.
  A refusal costs one gate run. A wrong acceptance costs the property the whole estate rests on, so anything
  this file cannot resolve is refused, and the refusals are counted in the run's own output.

  NOT AN EXPIRY, AND NOT A CLOCK. The key is content, so an entry is valid until its content changes. A max
  age is kept anyway as a backstop against a machine whose PowerShell or OS moved under it, and it is long.
#>
# Its self-test builds every sandbox it reads under %TEMP% and reads three frozen blobs by id from git's object store,
# which cannot change under an id. So it reads nothing else of this repo, and says so rather than being guessed at.
# gate-inputs: lib\gate-input-key.ps1
$__gikSelfTest = ($MyInvocation.InvocationName -ne '.') -and ($args -contains '-SelfTest')

# A DATA DIRECTORY IS BYTES THAT CHANGE WITHOUT A COMMIT. A gate that reads one cannot be keyed on source.
# reach-fixture-ok: these are the NAMES this rule refuses, not a reach - nothing here opens any of them, and a
# detector that names the directories it excludes cannot avoid spelling them.
# The DIRECTORIES whose bytes move without a commit. Kept as a body so the two rules below can ask a different
# question of the same list: one about a path joined to THIS repo, one about a drive-rooted literal.
$script:TcGateDataBody = '(?:grocery\\out|meal-prep\\db|meal-prep\\out|graph\\(?:gold|learning|out)|public\\|content\\|site\\|run\\waves|\.git\\)'   # reach-fixture-ok: the shape this rule REFUSES, named in a pattern; nothing here opens a real data file
$script:TcGateDataRx = '(?i)' + $script:TcGateDataBody
# Join-Path $repo $something: the second part is a variable, so the file it names cannot be read from source.
$script:TcGateComputedRx = '(?i)Join-Path\s+\$(repo|root|RepoRoot|here|PSScriptRoot)\s+\$'
# Join-Path <base> 'a\b.ps1': a literal the key can resolve and hash. Group 1 is the BASE as written, group 2 the
# literal. A base is one of the four named variables, $PSScriptRoot, or (Split-Path $PSScriptRoot -Parent) in either
# argument order - the three spellings this estate uses for "the folder a path is joined to".
$script:TcGateLiteralRx = '(?i)Join-Path\s+(\$(?:repo|root|RepoRoot|here|PSScriptRoot)\b|\(\s*Split-Path\s+(?:-Parent\s+)?\$(?:PSScriptRoot|repo|root|RepoRoot|here)\b(?:\s+-Parent)?\s*\))\s+''([^'']+)'''
$script:TcGateBaseVarNames = @('repo', 'root', 'RepoRoot', 'here')
# THE SAME DIRECTORIES as $script:TcGateDataBody, asked of a RESOLVED repo-relative path with a trailing separator, and
# anchored at both ends of the directory name so grocery\outline.ps1 is not grocery\out. Keep the two lists in step.
$script:TcGateDataResolvedRx = '(?i)^(?:grocery\\out|meal-prep\\db|meal-prep\\out|graph\\(?:gold|learning|out)|public|content|site|run\\waves|\.git)\\'   # reach-fixture-ok: the shape this rule REFUSES, named in a pattern; nothing here opens a real data file
$script:TcGateKeyMaxAgeHours = 72

# ---- THE KEY RESOLVES A PATH AGAINST THE FOLDER ITS VARIABLE NAMES (2026-09-23) ----
# WHY. Until this change every `Join-Path $root '<lit>'` was resolved against the REPO ROOT, whatever $root was. In this
# estate $root is usually $PSScriptRoot, so grocery\capture-watchdog.ps1's twelve inputs were all looked for at the root,
# none was there, and each was hashed as the constant 'absent' and ACCEPTED. capture-run.ps1 changed four times and the
# watchdog's key did not move once, so a 19:06 pass was replayed over a red self-test on five pushes to main
# (427327335, 1fb95392f, 92f2cfa7c, 1fbb617c4, f936a4b31). Measured at 351ff7f5c: 133 of 277 keyable self-tests named
# a real file the key could not see. grocery\triage-plans\investigation-red-on-main-2026-09-23.md is the account.
# THE FOUR RULES (Brad, 2026-09-23, "Full fix + declare"):
#   1. a literal is resolved against the folder its base names: $PSScriptRoot is the file's own folder, and a named
#      variable is read from its assignment in the same file (Get-TcGateVarBase). A base it cannot read is every
#      ancestor folder of the file and of the gate, and every one of those candidates goes into the key.
#   2. an input that exists under no candidate is a REFUSAL, never the constant 'absent' - the rule this file already
#      applied to the gate file itself. So is a directory, whose listing no source key can watch.
#   3. the data-directory refusal is asked of the RESOLVED path, so `Join-Path $root 'out'` beside a grocery script is
#      data even though the literal never spells grocery\out.
#   4. a spelling that builds a path on a base and that this file does not parse is refused (Test-TcGateUnparsed).
# A DECLARATION (# gate-inputs:) still outranks all four: the author has said what the gate reads.

function Resolve-TcGateBaseExpr {
  <# Pure over one assignment's right-hand side. Returns an array of bases - an [int] number of folders UP from the
     file's own folder, or the string 'repo' for the checkout root, or 'var:<name>' for another base variable - or
     $null when the expression is a spelling this file does not read. $null is the conservative answer: the caller
     then treats every ancestor folder as a candidate. #>
  param([string]$Expr)
  $e = ([string]$Expr).Trim()
  $e = ($e -replace '\s+#.*$', '').Trim().TrimEnd(';').Trim()
  if (-not $e) { return $null }
  if ($e -match '(?i)^\$(repo|root|RepoRoot|here)$') { return , @('var:' + $Matches[1].ToLowerInvariant()) }
  if ($e -match '(?i)\bgit\b.*\brev-parse\b.*--show-toplevel') { return , @('repo') }
  $m = [regex]::Match($e, '(?is)^if\s*\(\s*\$PSScriptRoot\s*\)\s*\{(.+)\}\s*else\s*\{(.+)\}$')
  $branches = if ($m.Success) { @($m.Groups[1].Value, $m.Groups[2].Value) } else { @($e) }
  $out = [Collections.Generic.List[object]]::new()
  foreach ($b in $branches) {
    $ps = [regex]::IsMatch($b, '(?i)\$PSScriptRoot\b')
    $mi = [regex]::IsMatch($b, '(?i)\$MyInvocation\.MyCommand\.(?:Path|Definition)\b')
    if ($ps -eq $mi) { return $null }
    # Everything left after the tokens this reader understands must be nothing but brackets and space.
    $rest = $b -replace '(?i)\$PSScriptRoot\b|\$MyInvocation\.MyCommand\.(?:Path|Definition)\b|\bSplit-Path\b|\bResolve-Path\b|\bConvert-Path\b|\bJoin-Path\b|-Parent\b|-LiteralPath\b|-Path\b|\.ProviderPath\b|\.Path\b|\[(?:System\.)?IO\.Path\]::GetFullPath|''(?:\.\.[\\/]?)+''', ''
    if ($rest -notmatch '^[\s\(\)]*$') { return $null }
    $ups = ([regex]::Matches($b, '(?i)\bSplit-Path\b')).Count
    foreach ($dm in [regex]::Matches($b, '''((?:\.\.[\\/]?)+)''')) { $ups += ([regex]::Matches($dm.Groups[1].Value, '\.\.')).Count }
    if ($mi) { $ups-- }
    if ($ups -lt 0) { return $null }
    $out.Add([int]$ups)
  }
  return , $out.ToArray()
}

function Get-TcGateVarBase {
  <# Pure over TEXT (comment-stripped). For each named base variable, the bases its assignments in this file give it
     (see Resolve-TcGateBaseExpr), or $null when it has no assignment here, any assignment is unreadable, or it is also
     a typed parameter or a loop variable - each of those means the folder is decided somewhere this file cannot see. #>
  param([string]$Code)
  $raw = @{}
  foreach ($v in $script:TcGateBaseVarNames) {
    $raw[$v.ToLowerInvariant()] = $null
    if ([regex]::IsMatch($Code, ('(?i)\[[\w\.\[\]]+\]\s*\$' + $v + '\b')) -or [regex]::IsMatch($Code, ('(?i)foreach\s*\(\s*\$' + $v + '\s+in\b'))) { continue }
    $ms = [regex]::Matches($Code, ('(?im)^[ \t]*(?:\$script:)?\$' + $v + '[ \t]*=(?!=)[ \t]*(.+?)[ \t]*$'))
    if (-not $ms.Count) { continue }
    $bases = [Collections.Generic.List[object]]::new(); $unknown = $false
    foreach ($m in $ms) {
      $b = Resolve-TcGateBaseExpr -Expr $m.Groups[1].Value
      if ($null -eq $b) { $unknown = $true; break }
      foreach ($x in $b) { $bases.Add($x) }
    }
    if (-not $unknown) { $raw[$v.ToLowerInvariant()] = $bases.ToArray() }
  }
  # One level of `$repo = $root`: follow it when the other variable is itself known, otherwise the pair is unknown.
  $out = @{}
  foreach ($k in @($raw.Keys)) {
    $list = $raw[$k]
    if ($null -eq $list) { $out[$k] = $null; continue }
    $res = [Collections.Generic.List[object]]::new(); $bad = $false
    foreach ($x in $list) {
      if ($x -is [string] -and $x.StartsWith('var:')) {
        $o = $raw[$x.Substring(4)]
        if ($null -eq $o -or $x.Substring(4) -eq $k) { $bad = $true; break }
        foreach ($y in $o) { if ($y -is [string] -and $y.StartsWith('var:')) { $bad = $true; break } else { $res.Add($y) } }
        if ($bad) { break }
      } else { $res.Add($x) }
    }
    $out[$k] = if ($bad) { $null } else { $res.ToArray() }
  }
  return $out
}

function Get-TcGateAncestorDirs {
  <# Every folder from $Rel up to the checkout root, root last as ''. Repo-relative, no trailing separator. #>
  param([string]$Rel)
  $out = [Collections.Generic.List[string]]::new()
  $cur = ([string]$Rel).Trim('\')
  while ($true) {
    $out.Add($cur)
    if (-not $cur) { break }
    $i = $cur.LastIndexOf('\')
    $cur = if ($i -lt 0) { '' } else { $cur.Substring(0, $i) }
  }
  return , $out.ToArray()
}

function Test-TcGateUnparsed {
  <# Pure over comment-stripped TEXT. RULE 4: a spelling that builds a path on a base and that Get-TcGateReferencedPaths
     does not parse would otherwise be neither keyed nor refused - an input dropped from the key in silence. Returns
     the name of the first such spelling, or '' when there is none. A backtick-escaped `$root inside a fixture string
     is text, not a read, so every pattern refuses only an unescaped $. #>
  param([string]$Code)
  $b = '(?:repo|root|RepoRoot|here|PSScriptRoot)'
  $rules = @(
    @(('(?i)\[(?:System\.)?IO\.Path\]::Combine\(\s*\$' + $b + '\b'), '[IO.Path]::Combine on a base folder'),
    @(('(?i)"[^"\r\n]*(?<!`)\$\{?' + $b + '\}?\\'), 'a path interpolated into a double-quoted string on a base folder'),
    @(('(?i)Join-Path\s+\$' + $b + '\s+"'), 'Join-Path on a base folder with a double-quoted child'),
    @(('(?i)Join-Path\s+-Path\s+\$' + $b + '\b'), 'Join-Path on a base folder with named parameters'),
    @(('(?i)Join-Path\s+\((?!\s*Split-Path\s+(?:-Parent\s+)?\$(?:PSScriptRoot|repo|root|RepoRoot|here)\b(?:\s+-Parent)?\s*\)\s+'')[^\r\n]*?(?<!`)\$' + $b + '\b'), 'Join-Path over a nested expression on a base folder')
  )
  foreach ($r in $rules) { if ([regex]::IsMatch($Code, $r[0])) { return $r[1] } }
  return ''
}

function Resolve-TcGateFileRefs {
  <# The inputs ONE file names, resolved against the folders its bases really point to. $FileRel is the file's path
     below the checkout, $GateRel the gate's (an unreadable base takes the ancestors of both). -Strict applies rules
     2 and 3; without it (a gate or a library that DECLARES its inputs) only the candidates that exist are hashed and
     nothing refuses, because the declaration already answered the question.
     Returns Ok, Why, Paths (existing files, repo-relative) and Absent (candidates that do not exist, which still go
     into the key so a file appearing there moves it). #>
  param([string]$Repo, [string]$FileRel, [string]$GateRel, [string]$Text, [switch]$Strict, [switch]$KeepDataGlobs)
  $repoFull = [IO.Path]::GetFullPath($Repo).TrimEnd('\')
  $code = Remove-TcGateComments -Text $Text
  $vars = Get-TcGateVarBase -Code $code
  $fileDir = [IO.Path]::GetDirectoryName(([string]$FileRel).TrimStart('\'))
  if ($null -eq $fileDir) { $fileDir = '' }
  $gateDir = [IO.Path]::GetDirectoryName(([string]$GateRel).TrimStart('\'))
  if ($null -eq $gateDir) { $gateDir = '' }
  $fileAnc = Get-TcGateAncestorDirs -Rel $fileDir
  $fallback = [Collections.Generic.List[string]]::new()
  # ASSIGN, THEN USE: the helper returns its array with a leading comma, and an inline @() around the call would read it as ONE element.
  $gateAnc = Get-TcGateAncestorDirs -Rel $gateDir
  foreach ($d in $fileAnc) { if (-not $fallback.Contains($d)) { $fallback.Add($d) } }
  foreach ($d in $gateAnc) { if (-not $fallback.Contains($d)) { $fallback.Add($d) } }
  $paths = [Collections.Generic.List[string]]::new()
  $absent = [Collections.Generic.List[string]]::new()
  foreach ($m in [regex]::Matches($code, $script:TcGateLiteralRx)) {
    $baseTxt = $m.Groups[1].Value
    $lit = $m.Groups[2].Value -replace '/', '\'
    $dirs = [Collections.Generic.List[string]]::new()
    $bases = $null
    if ($baseTxt -match '(?i)^\$PSScriptRoot$') { $bases = @(0) }
    elseif ($baseTxt.StartsWith('(')) {
      # (Split-Path <base> -Parent): one folder above whatever the inner base names.
      $inner = [regex]::Match($baseTxt, '(?i)\$(PSScriptRoot|repo|root|RepoRoot|here)\b').Groups[1].Value
      if ($inner -ieq 'PSScriptRoot') { $bases = @(1) }
      else {
        $ib = $vars[$inner.ToLowerInvariant()]
        if ($null -ne $ib) { $bases = @(foreach ($x in $ib) { if ($x -is [string]) { 'outside' } else { [int]$x + 1 } }) }
      }
    }
    else { $bases = $vars[$baseTxt.Substring(1).ToLowerInvariant()] }
    if ($null -eq $bases) { foreach ($d in $fallback) { $dirs.Add($d) } }
    else {
      foreach ($x in $bases) {
        if ($x -is [string]) { if ($x -eq 'repo' -and -not $dirs.Contains('')) { $dirs.Add('') } ; continue }
        $ups = [int]$x
        if ($ups -lt $fileAnc.Count) { $d = $fileAnc[$ups]; if (-not $dirs.Contains($d)) { $dirs.Add($d) } }
      }
    }
    $found = 0; $cands = [Collections.Generic.List[string]]::new()
    foreach ($d in $dirs) {
      $full = ''
      # A WILDCARD LITERAL NAMES A LISTING: every file it matches is hashed, so a file added or removed there moves the
      # key the way a declared glob does. It resolves like any literal, and its FOLDER is what the data rule reads.
      if ($lit -match '[\*\?]') {
        $gdir = ''
        try { $gdir = [IO.Path]::GetFullPath([IO.Path]::Combine([IO.Path]::Combine($repoFull, $d), [IO.Path]::GetDirectoryName($lit))).TrimEnd('\') } catch { continue }
        if (-not ($gdir + '\').StartsWith($repoFull + '\', [StringComparison]::OrdinalIgnoreCase)) { continue }
        $grel = if ($gdir.Length -gt $repoFull.Length) { $gdir.Substring($repoFull.Length + 1) } else { '' }
        $gkey = $grel + '\' + [IO.Path]::GetFileName($lit)
        if ($cands.Contains($gkey)) { continue }
        $cands.Add($gkey)
        if ($Strict -and [regex]::IsMatch($grel + '\', $script:TcGateDataResolvedRx)) {
          return [pscustomobject]@{ Ok = $false; Why = ("reads '" + $lit + "', which resolves into a data directory (" + $gkey + "), whose bytes change with no commit"); Paths = @(); Absent = @() }
        }
        # UNDER A DECLARATION A DATA GLOB IN A FILE THE WALK REACHED IS NOT HASHED, exactly as a data literal is not
        # (2026-09-24). Until then only the literal was skipped, so grocery\capture-run.ps1's
        # 'meal-prep\db\recipes\*.json' and meal-prep\engine\publish.ps1's 'db\built\*.body.html' put every spec and
        # built card into the key of any declared gate whose walk reached them: 585 to 2,346 gitignored files in eight
        # suites, so every data rebuild re-ran them. THE GATE'S OWN data glob is still hashed (-KeepDataGlobs): the
        # gate's text is where its self-test runs, and hunt-run's -Init fixture really lists grocery\out\comparison-*.json.
        if (-not $Strict -and -not $KeepDataGlobs -and [regex]::IsMatch($grel + '\', $script:TcGateDataResolvedRx)) { continue }
        $hits = @()
        if ([IO.Directory]::Exists($gdir)) { $hits = @([IO.Directory]::GetFiles($gdir, [IO.Path]::GetFileName($lit)) | Sort-Object) }
        if ($hits.Count) {
          $found++
          foreach ($h in $hits) { $hr = $h.Substring($repoFull.Length + 1); if (-not $paths.Contains($hr)) { $paths.Add($hr) } }
        } elseif (-not $absent.Contains($gkey)) { $absent.Add($gkey) }
        continue
      }
      try { $full = [IO.Path]::GetFullPath([IO.Path]::Combine([IO.Path]::Combine($repoFull, $d), $lit)).TrimEnd('\') } catch { continue }
      if (-not $full.StartsWith($repoFull + '\', [StringComparison]::OrdinalIgnoreCase)) { continue }
      $rel = $full.Substring($repoFull.Length + 1)
      if ($cands.Contains($rel)) { continue }
      $cands.Add($rel)
      # Under a DECLARATION a data file is not hashed either: the author has said the self-test does not read it, and
      # hashing it would only turn every daily data write into a miss.
      if (-not $Strict -and [regex]::IsMatch($rel + '\', $script:TcGateDataResolvedRx)) { continue }
      if ($Strict -and [regex]::IsMatch($rel + '\', $script:TcGateDataResolvedRx)) {
        return [pscustomobject]@{ Ok = $false; Why = ("reads '" + $lit + "', which resolves into a data directory (" + $rel + "), whose bytes change with no commit"); Paths = @(); Absent = @() }
      }
      if ([IO.File]::Exists($full)) { $found++; if (-not $paths.Contains($rel)) { $paths.Add($rel) } }
      elseif ([IO.Directory]::Exists($full)) {
        if ($Strict) { return [pscustomobject]@{ Ok = $false; Why = ("names the directory '" + $rel + "', whose listing a source key cannot watch"); Paths = @(); Absent = @() } }
      } elseif (-not $absent.Contains($rel)) { $absent.Add($rel) }
    }
    if ($Strict -and -not $found) {
      $where = if ($cands.Count) { $cands -join ', ' } else { 'no folder inside this repo' }
      return [pscustomobject]@{ Ok = $false; Why = ("names '" + $lit + "', which exists nowhere it could be read from (" + $where + "), so the key cannot hash it and will not stand in 'absent' for it"); Paths = @(); Absent = @() }
    }
  }
  $pa = $paths.ToArray(); [Array]::Sort($pa, [StringComparer]::OrdinalIgnoreCase)
  $ab = $absent.ToArray(); [Array]::Sort($ab, [StringComparer]::OrdinalIgnoreCase)
  return [pscustomobject]@{ Ok = $true; Why = ''; Paths = $pa; Absent = $ab }
}

function Get-TcFileSha256 {
  param([string]$Path)
  if (-not [IO.File]::Exists($Path)) { return 'absent' }
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    try { return ([BitConverter]::ToString($sha.ComputeHash($fs)) -replace '-', '').ToLowerInvariant() }
    finally { $fs.Dispose() }
  } catch { return 'unreadable' } finally { $sha.Dispose() }
}

function Get-TcGateReferencedPaths {
  <# Pure over TEXT. Every repo-relative path the source names as a literal, plus the libs it dot-sources.
     Returns Paths (repo-relative, de-duplicated, ordered) and Computed ($true when it builds one from a
     variable, which is what makes a gate uncacheable). #>
  param([string]$Text)
  $paths = [Collections.Generic.List[string]]::new()
  $seen = New-Object Collections.Hashtable ([StringComparer]::OrdinalIgnoreCase)
  foreach ($m in [regex]::Matches($Text, $script:TcGateLiteralRx)) {
    $p = $m.Groups[2].Value
    if (-not $p) { continue }
    if (-not $seen.ContainsKey($p)) { $seen[$p] = $true; $paths.Add($p) }
  }
  $sorted = $paths.ToArray()
  [Array]::Sort($sorted, [StringComparer]::OrdinalIgnoreCase)
  return [pscustomobject]@{ Paths = @($sorted); Computed = [regex]::IsMatch($Text, $script:TcGateComputedRx) }
}

function Remove-TcGateComments {
  <# Pure. Drops whole-line comments before the refusal rules read the text. A comment cannot open a file, and
     a header that DESCRIBES the data a script avoids would otherwise refuse it: measured 2026-09-12, 12 of the
     279 self-tests were refused for a data path that appears only in prose or on a fixture line. #>
  param([string]$Text)
  $out = [Collections.Generic.List[string]]::new()
  foreach ($l in ($Text -split "`n")) {
    $t = $l.TrimStart()
    if ($t.StartsWith('#')) { continue }
    if ($l -match 'reach-fixture-ok') { continue }
    $out.Add($l)
  }
  return ($out -join "`n")
}

function Test-TcGateCacheable {
  <# Pure over TEXT. Why is returned even on success, so a run can print WHY a gate was refused rather than
     leaving a reader to guess which of the two rules bit.

     IT ASKS WHAT THE PATH IS JOINED TO (2026-09-12). The first version matched a data directory ANYWHERE in
     the text, so a suite that builds a sandbox repo under %TEMP% and writes `Join-Path $main '.git\...'` was
     refused as a data reader. That is how the most expensive gates on the box - the ones that test the push
     and commit hooks, 54s and 34s - stayed uncacheable while reading nothing of this estate's data at all.
     A read of THIS repo's data is joined to the repo root; a path joined to some other variable is a sandbox
     the suite made itself. A bare literal with no join is still refused, because it names a real place. #>
  param([string]$Text)
  $code = Remove-TcGateComments -Text $Text
  if ([regex]::IsMatch($code, ('(?i)Join-Path\s+\$(?:repo|root|RepoRoot|here)\s+''' + $script:TcGateDataBody))) {
    return [pscustomobject]@{ Ok = $false; Why = 'reads a data directory under this repo, whose bytes change with no commit' }
  }
  # A DRIVE-ROOTED literal names a real place on this box whatever it is joined to, so it is still refused.
  # A relative literal is NOT, because that is what a sandbox path looks like: 'Join-Path $main ''.git\hooks'''
  # builds a temp repo, and refusing it cost the two hook suites - the most expensive gates here - for nothing.
  if ([regex]::IsMatch($code, ('(?i)''[A-Za-z]:\\[^'']*' + $script:TcGateDataBody))) {
    return [pscustomobject]@{ Ok = $false; Why = 'names a data path on this box as an absolute literal' }
  }
  if ([regex]::IsMatch($Text, $script:TcGateComputedRx)) {
    return [pscustomobject]@{ Ok = $false; Why = 'builds a repo path from a variable, which a source key cannot watch' }
  }
  $unparsed = Test-TcGateUnparsed -Code $code
  if ($unparsed) {
    return [pscustomobject]@{ Ok = $false; Why = ('builds a path with ' + $unparsed + ', a spelling the key does not parse, so the file it reads cannot be hashed') }
  }
  return [pscustomobject]@{ Ok = $true; Why = '' }
}

# A GATE MAY DECLARE WHAT IT READS, instead of being guessed at (Brad, 2026-09-12). One line in its own source:
#
#     # gate-inputs: lib\*.ps1, ops\hooks\pre-push, ops\prepush-test-auditors.ps1
#
# WHY IT EXISTS. The rules below INFER a gate's inputs from its source text, and inference has exactly two failure
# directions. Guessing too wide refuses a gate that reads nothing of the kind - 53 of 293 on 2026-09-12, among them
# every expensive suite on the box, and ops\test-prepush-hook.ps1 (67s) which cannot EVER be inferred because it
# copies lib\*.ps1 by DIRECTORY ENUMERATION and no source key can name a listing. Guessing too narrow would reuse a
# stale pass, which is why the inference is deliberately conservative and why its refusals are not a bug.
# A declaration replaces the guess with an assertion the author signed, visible in a diff and reviewable as code.
#
# WHAT IT DOES NOT DO. It does not shorten the key: every declared path is hashed, globs and all, and the transitive
# walk still follows a declared .ps1 into what IT loads, so a library two hops away still moves the key.
# A DECLARED PATH THAT MATCHES NOTHING IS A REFUSAL, never an empty set: a typo'd or stale declaration would
# otherwise narrow the input set silently, which is the one direction that turns into a stale pass.
$script:TcGateDeclRx = '(?im)^[ \t]*#[ \t]*gate-inputs:[ \t]*(.+?)[ \t]*$'

function Get-TcGateDeclaredInputs {
  <# The declared input patterns, in source order, or an empty array when the gate declares none. Pure over text so
     the fixture drives it without a disk. #>
  param([string]$Text)
  $out = [Collections.Generic.List[string]]::new()
  foreach ($m in [regex]::Matches($Text, $script:TcGateDeclRx)) {
    foreach ($p in ($m.Groups[1].Value -split ',')) {
      $t = $p.Trim()
      if ($t) { [void]$out.Add($t) }
    }
  }
  return @($out)
}

# A DECLARED INPUT MAY BE READ AS TEXT ONLY (2026-09-24, push-speed review F3). One more line form:
#
#     # gate-inputs-text: grocery\capture-run.ps1
#
# WHY. A declared .ps1 is WALKED like a loaded library, so everything it dot-sources and names joins the key. That is
# right for a file the gate LOADS and wrong for one it only PARSES or COPIES: lib\checkout-sync.ps1's suite reads
# grocery\capture-run.ps1 once, as text, for an AST scan, and the walk behind that one file put 2,968 files in its
# key, 1,202 of them gitignored boards and built cards. Measured over the 287 commits on origin/main from 2026-09-21
# to faafb042c: that key moved on 201 of them, and a key over the files the suite really reads moved on 18. A key
# that moves on 70% of commits, and on every data rebuild, is keyed on paper and re-run in practice.
# WHAT IT DOES. The file's bytes go into the key exactly as a declared file's do, so any edit to it still moves the
# key; only the walk INTO it is skipped, whichever road reached it (a declaration or a literal in a walked file).
# WHAT KEEPS IT HONEST. A text input that the gate or any file in its walk DOT-SOURCES, calls with & or runs with
# -File is refused (Test-TcGateLoadsLeaf): that file executes, so what it loads is an input, and skipping the walk
# would drop it in silence. A text pattern that matches nothing is refused like any declared one.
$script:TcGateTextDeclRx = '(?im)^[ \t]*#[ \t]*gate-inputs-text:[ \t]*(.+?)[ \t]*$'

function Get-TcGateDeclaredTextInputs {
  <# The text-only input patterns, in source order. Pure over text. #>
  param([string]$Text)
  $out = [Collections.Generic.List[string]]::new()
  foreach ($m in [regex]::Matches($Text, $script:TcGateTextDeclRx)) {
    foreach ($p in ($m.Groups[1].Value -split ',')) {
      $t = $p.Trim()
      if ($t) { [void]$out.Add($t) }
    }
  }
  return @($out)
}

# A LIBRARY MAY DECLARE A FILE IT ONLY WRITES (2026-09-24). One more line form, in a LIBRARY:
#
#     # gate-output: ops\out\events.jsonl read-by Read-TcEvents, Get-TcEventBusPath
#
# WHY. lib\event-bus.ps1 names its gitignored bus by a literal, so every gate whose walk reached it hashed
# ops\out\events.jsonl: 20 keyed self-tests at 2026-09-24, and every event this checkout recorded, from any producer,
# moved all twenty keys. Their suites append to the bus through Write-TcEvent or never touch it; an append is not a read.
# WHAT IT DOES. In a caller's key the named file is left out when it arrives through THAT library's own literals.
# WHAT KEEPS IT HONEST. It is put back, hashed like any input, when any OTHER walked file (the gate included) names a
# read-by function or the file's own name, because that code may read what the library writes; and it is always hashed
# when another road reaches it. A gate-output that names code, or carries no read-by list, refuses the gate: a writer
# whose readers nobody listed cannot be told apart from one that has none. UNSOUND like the load rule: a read through
# some spelling that names neither is outside it, and the read-by list is the library author's assertion to keep true.
$script:TcGateOutDeclRx = '(?im)^[ \t]*#[ \t]*gate-output:[ \t]*(.*?)[ \t]*$'

function Get-TcGateDeclaredOutputs {
  <# Pure over text. Returns Ok, Why and Outputs (Path repo-relative with backslashes, Readers). #>
  param([string]$Text)
  $outs = [Collections.Generic.List[object]]::new()
  foreach ($m in [regex]::Matches($Text, $script:TcGateOutDeclRx)) {
    $body = $m.Groups[1].Value
    $pm = [regex]::Match($body, '(?i)^(\S+)\s+read-by\s+(.+)$')
    if (-not $pm.Success) { return [pscustomobject]@{ Ok = $false; Why = ("the gate-output line '" + $body + "' is not '<path> read-by <function>[, <function>]'"); Outputs = @() } }
    $p = $pm.Groups[1].Value -replace '/', '\'
    if ($p -match '(?i)\.psm?1$' -or $p -match '[\*\?]' -or $p -match '(?i)^[a-z]:\\' -or $p -match '\.\.') {
      return [pscustomobject]@{ Ok = $false; Why = ("the gate-output '" + $p + "' must be one data file inside this repo, never code, a glob or an outside path"); Outputs = @() }
    }
    $rd = @($pm.Groups[2].Value -split '[,\s]+' | Where-Object { $_ -match '^[A-Za-z][\w-]*$' })
    if (-not $rd.Count) { return [pscustomobject]@{ Ok = $false; Why = ("the gate-output '" + $p + "' names no reader function"); Outputs = @() } }
    $outs.Add([pscustomobject]@{ Path = $p; Readers = $rd })
  }
  return [pscustomobject]@{ Ok = $true; Why = ''; Outputs = $outs.ToArray() }
}

function Test-TcGateNamesOutputReader {
  <# Pure over comment-stripped TEXT. True when the code names one of the output's reader functions as a word, or the
     output file's own name. Either means the code may read the file, so the caller's key keeps it. #>
  param([string]$Code, [string]$Path, [string[]]$Readers)
  foreach ($r in @($Readers)) { if ([regex]::IsMatch($Code, ('(?i)(?<![\w-])' + [regex]::Escape($r) + '(?![\w-])'))) { return $true } }
  $leaf = [IO.Path]::GetFileName($Path)
  if ($leaf -and $Code.IndexOf($leaf, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
  return $false
}

function Test-TcGateLoadsLeaf {
  <# Pure over comment-stripped TEXT. True when the code dot-sources, calls with & or starts with -File a path whose
     Join-Path literal ENDS in $Leaf (a file name). Matched on the file name, not the resolved path, so it refuses more
     than it must, which is the safe direction for a rule whose failure is an input dropped from the key.
     UNSOUND: a load through a variable (`$p = Join-Path ...; . $p`) is outside it. That is the declaration's author's
     assertion to make, as every other declared input is. #>
  param([string]$Code, [string]$Leaf)
  if (-not $Leaf) { return $false }
  $l = [regex]::Escape($Leaf)
  $rx = '(?im)(?:(?:^|[;{(|]|\s)[.&]\s*\(?\s*Join-Path\b|-File\s+\(?\s*(?:Join-Path\b)?)[^\r\n]*?[''"](?:[^''"\r\n]*[\\/])?' + $l + '[''"]'
  return [regex]::IsMatch($Code, $rx)
}

function Resolve-TcGateDeclaredInputs {
  <# Expand declared patterns against the repo root. Returns Ok and either Paths (relative, sorted ordinally) or
     Why. A pattern matching nothing refuses the whole gate; so does one that escapes the repo. #>
  param([string]$Repo, [string[]]$Patterns)
  $repoFull = [IO.Path]::GetFullPath($Repo).TrimEnd('\')
  $seen = New-Object Collections.Hashtable ([StringComparer]::OrdinalIgnoreCase)
  $paths = [Collections.Generic.List[string]]::new()
  foreach ($pat in @($Patterns)) {
    if ($pat -match '(?i)^[a-z]:\\' -or $pat -match '\.\.') {
      return [pscustomobject]@{ Ok = $false; Paths = @(); Why = ("the declared input '" + $pat + "' is not a path inside this repo") }
    }
    $rel = $pat -replace '/', '\'
    $full = [IO.Path]::Combine($repoFull, $rel)
    $hits = @()
    if ($rel -match '[\*\?]') {
      $dir = [IO.Path]::GetDirectoryName($full)
      $leaf = [IO.Path]::GetFileName($full)
      if ($dir -and [IO.Directory]::Exists($dir)) {
        $hits = @([IO.Directory]::GetFiles($dir, $leaf) | Sort-Object)
      }
    } elseif ([IO.File]::Exists($full)) {
      $hits = @($full)
    }
    if (-not $hits.Count) {
      return [pscustomobject]@{ Ok = $false; Paths = @(); Why = ("the declared input '" + $pat + "' matches no file, so the declaration is stale or misspelt") }
    }
    foreach ($h in $hits) {
      $r = $h.Substring($repoFull.Length).TrimStart('\')
      if (-not $seen.ContainsKey($r)) { $seen[$r] = $true; [void]$paths.Add($r) }
    }
  }
  $sorted = $paths.ToArray()
  [Array]::Sort($sorted, [StringComparer]::OrdinalIgnoreCase)
  return [pscustomobject]@{ Ok = $true; Paths = @($sorted); Why = '' }
}

function Test-TcGateDeclarationMoves {
  <# VERIFIES A DECLARATION the way Brad's 2026-09-23 ruling asks for one: in a TEMP COPY of every file the gate's key
     reads, change each declared input by one byte, and add a file under each declared glob, and require the key to
     move each time. A declaration is an author's assertion that nothing mechanical can prove COMPLETE; what this
     proves is that every file it names really reaches the key, so a typo that matched the wrong file, or a key that
     stopped hashing declared paths, is caught. Returns Ok, Why and one row per probe. #>
  param([string]$Repo, [string]$GateFile)
  $repoFull = [IO.Path]::GetFullPath($Repo).TrimEnd('\')
  $gateFull = [IO.Path]::GetFullPath($GateFile)
  $none = [pscustomobject]@{ Ok = $false; Why = ''; Rows = @() }
  if (-not $gateFull.StartsWith($repoFull + '\', [StringComparison]::OrdinalIgnoreCase)) { $none.Why = 'the gate is not inside the repo'; return $none }
  $gateRel = $gateFull.Substring($repoFull.Length + 1)
  $gateSrc = [IO.File]::ReadAllText($gateFull)
  $decl = Get-TcGateDeclaredInputs -Text $gateSrc
  $declT = Get-TcGateDeclaredTextInputs -Text $gateSrc
  # Text-only inputs are probed exactly like the rest: an edit to one must move the key.
  $decl = @($decl) + @($declT)
  if (-not $decl.Count) { $none.Why = 'declares nothing, so there is no declaration to verify'; return $none }
  $k = Get-TcGateInputKey -Repo $Repo -GateFile $gateFull -GateArg '-SelfTest'
  if (-not $k.Ok) { $none.Why = ('is not keyable: ' + $k.Why); return $none }
  $res = Resolve-TcGateDeclaredInputs -Repo $Repo -Patterns $decl
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ('tc-gikv-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
  $rows = [Collections.Generic.List[object]]::new()
  try {
    foreach ($f in @($k.Files)) {
      $ff = [IO.Path]::GetFullPath([string]$f)
      if (-not $ff.StartsWith($repoFull + '\', [StringComparison]::OrdinalIgnoreCase)) { continue }
      $dst = Join-Path $tmp $ff.Substring($repoFull.Length + 1)
      $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) -ErrorAction Stop
      [IO.File]::Copy($ff, $dst, $true)
    }
    $gCopy = Join-Path $tmp $gateRel
    $base = Get-TcGateInputKey -Repo $tmp -GateFile $gCopy -GateArg '-SelfTest'
    # The copy holds the files the key hashed, not the folders beside them, so a candidate that is a DIRECTORY in the
    # checkout can read as an absent candidate here and move the base key. Each probe is judged against the copy's own base.
    if (-not $base.Ok) { $none.Why = ('the temp copy is not keyable (' + $base.Why + ')'); return $none }
    foreach ($rel in @($res.Paths)) {
      $cp = Join-Path $tmp $rel
      $orig = [IO.File]::ReadAllBytes($cp)
      [IO.File]::WriteAllBytes($cp, [byte[]]($orig + [byte]32))
      $k2 = Get-TcGateInputKey -Repo $tmp -GateFile $gCopy -GateArg '-SelfTest'
      [IO.File]::WriteAllBytes($cp, $orig)
      $rows.Add([pscustomobject]@{ Probe = ('edit ' + $rel); Moved = [bool]($k2.Ok -and $k2.Key -ne $base.Key) })
    }
    foreach ($pat in @($decl)) {
      if ($pat -notmatch '[\*\?]') { continue }
      $nf = Join-Path $tmp (($pat -replace '/', '\') -replace '\*', 'zz-gikv-new' -replace '\?', 'z')
      if ([IO.File]::Exists($nf)) { continue }
      $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $nf) -ErrorAction Stop
      [IO.File]::WriteAllText($nf, "# a file that appeared under a declared glob`n")
      $k3 = Get-TcGateInputKey -Repo $tmp -GateFile $gCopy -GateArg '-SelfTest'
      [IO.File]::Delete($nf)
      $rows.Add([pscustomobject]@{ Probe = ('add under ' + $pat); Moved = [bool]($k3.Ok -and $k3.Key -ne $base.Key) })
    }
  } finally {
    if ($tmp -and $tmp.Contains('tc-gikv-')) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
  }
  $still = @($rows | Where-Object { -not $_.Moved })
  $why = if ($still.Count) { ('the key did not move for: ' + (($still | ForEach-Object { $_.Probe }) -join '; ')) } elseif (-not $rows.Count) { 'nothing was probed' } else { '' }
  return [pscustomobject]@{ Ok = [bool]($rows.Count -and -not $still.Count); Why = $why; Rows = $rows.ToArray() }
}

function Get-TcGateInputKey {
  <# The key for ONE gate. $Repo is the checkout, $GateFile its full path, $GateArg the argument it runs with
     (so `-SelfTest` and a renamed switch are different entries), $RunnerFiles the bytes of whatever dispatches
     it - change the runner and every key changes, which is the conservative direction.

     Returns Ok, Key, Why and Files (what went into it, for the fixture and for a reader). NOT cacheable comes
     back Ok=$false with Why, and the caller must then run the gate. #>
  param(
    [Parameter(Mandatory = $true)][string]$Repo,
    [Parameter(Mandatory = $true)][string]$GateFile,
    [string]$GateArg = '',
    [string[]]$RunnerFiles = @()
  )
  if (-not [IO.File]::Exists($GateFile)) {
    return [pscustomobject]@{ Ok = $false; Key = ''; Why = 'the gate file does not exist'; Files = @() }
  }
  $text = ''
  try { $text = [IO.File]::ReadAllText($GateFile) } catch {
    return [pscustomobject]@{ Ok = $false; Key = ''; Why = 'the gate file could not be read'; Files = @() }
  }
  # A DECLARATION OUTRANKS THE INFERENCE, because the author knows what the gate reads and the regex is guessing.
  # Only the REFUSAL is lifted: every declared path is still hashed below, and the transitive walk still runs.
  $declared = Get-TcGateDeclaredInputs -Text $text
  $declared = @($declared)
  # TEXT-ONLY inputs (gate-inputs-text:) are part of the declaration: hashed like the rest, never walked into.
  $textDecl = Get-TcGateDeclaredTextInputs -Text $text
  $textDecl = @($textDecl)
  $textSet = New-Object Collections.Hashtable ([StringComparer]::OrdinalIgnoreCase)
  if ($textDecl.Count) {
    $textRes = Resolve-TcGateDeclaredInputs -Repo $Repo -Patterns $textDecl
    if (-not $textRes.Ok) { return [pscustomobject]@{ Ok = $false; Key = ''; Why = $textRes.Why; Files = @() } }
    foreach ($p in $textRes.Paths) { $textSet[$p] = $true }
  }
  $declResolved = $null
  # A GATE THAT IS NOT POWERSHELL MUST DECLARE, OR IT IS NOT KEYED (2026-09-12). The inference below reads PowerShell
  # spellings - Join-Path literals, dot-sourced lib\ paths - and a Python suite has neither. Handed a .py, it finds
  # nothing to refuse and nothing to follow, and would key the file on its own bytes alone: an `import hunt_lib` or an
  # open() of a board would be invisible, and a pass would replay after either changed. That is the unsafe direction,
  # so for anything but PowerShell the only road to a key is the author's own list.
  # Either line form is a declaration; each form's patterns are resolved, and refused on a miss, exactly once.
  $hasDecl = ($declared.Count + $textDecl.Count) -gt 0
  if (-not $hasDecl -and $GateFile -notmatch '(?i)\.psm?1$') {
    return [pscustomobject]@{ Ok = $false; Key = ''; Why = 'is not PowerShell and declares no inputs, and the inference cannot see what it imports or opens'; Files = @() }
  }
  if ($hasDecl) {
    $declResolved = [pscustomobject]@{ Ok = $true; Paths = @(); Why = '' }
    if ($declared.Count) {
      $declResolved = Resolve-TcGateDeclaredInputs -Repo $Repo -Patterns $declared
      if (-not $declResolved.Ok) { return [pscustomobject]@{ Ok = $false; Key = ''; Why = $declResolved.Why; Files = @() } }
    }
    $declResolved = [pscustomobject]@{ Ok = $true; Paths = (@($declResolved.Paths) + @($textSet.Keys)); Why = '' }
  } else {
    $can = Test-TcGateCacheable -Text $text
    if (-not $can.Ok) { return [pscustomobject]@{ Ok = $false; Key = ''; Why = $can.Why; Files = @() } }
  }

  $repoFull = [IO.Path]::GetFullPath($Repo).TrimEnd('\')
  # THE WALK MAY RUN MORE THAN ONCE. A library's text-only input that some other file in the walk LOADS must be walked
  # as code after all, and whether one is only shows once the walk has read everything; so the walk restarts with that
  # path forced back to code. Each restart forces one more path, so it ends within one attempt per text input.
  $gateTextSet = New-Object Collections.Hashtable ([StringComparer]::OrdinalIgnoreCase)
  foreach ($p in @($textSet.Keys)) { $gateTextSet[$p] = $true }
  $forceWalk = New-Object Collections.Hashtable ([StringComparer]::OrdinalIgnoreCase)
  $walkDone = $false
  for ($attempt = 0; $attempt -lt 64; $attempt++) {
    $textSet = New-Object Collections.Hashtable ([StringComparer]::OrdinalIgnoreCase)
    foreach ($p in @($gateTextSet.Keys)) { $textSet[$p] = $true }
    $rows = [Collections.Generic.List[string]]::new()
    $files = [Collections.Generic.List[string]]::new()
    $rows.Add('gate ' + [IO.Path]::GetFileName($GateFile) + ' ' + (Get-TcFileSha256 $GateFile))
    $files.Add($GateFile)
    $rows.Add('arg ' + $GateArg)

    # TRANSITIVE, because a library that dot-sources another is exactly how a change reaches a gate without
    # touching it. The walk is breadth-first and stops at what it has already seen. EVERY literal a walked file names
    # joins the walk (2026-09-23), resolved against that file's own bases: until then only lib\ spellings were followed
    # below the gate, so a file a loaded library named was outside the key.
    $gateFull = [IO.Path]::GetFullPath($GateFile)
    $gateRel = if ($gateFull.StartsWith($repoFull + '\', [StringComparison]::OrdinalIgnoreCase)) { $gateFull.Substring($repoFull.Length + 1) } else { [IO.Path]::GetFileName($gateFull) }
    $queue = [Collections.Generic.Queue[string]]::new()
    $seen = New-Object Collections.Hashtable ([StringComparer]::OrdinalIgnoreCase)
    $seen[$gateRel] = $true
    $absentSeen = New-Object Collections.Hashtable ([StringComparer]::OrdinalIgnoreCase)
    $gateRefs = Resolve-TcGateFileRefs -Repo $Repo -FileRel $gateRel -GateRel $gateRel -Text $text -Strict:(-not $declResolved) -KeepDataGlobs
    if (-not $gateRefs.Ok) { return [pscustomobject]@{ Ok = $false; Key = ''; Why = $gateRefs.Why; Files = @() } }
    foreach ($p in $gateRefs.Paths) { $queue.Enqueue($p) }
    foreach ($p in $gateRefs.Absent) { $absentSeen[$p] = $true }
    # The declared set joins the same queue, so a declared .ps1 is walked into exactly like an inferred one.
    if ($declResolved) { foreach ($p in $declResolved.Paths) { $queue.Enqueue($p) } }
    # A TEXT INPUT THAT SOMETHING HERE LOADS IS NOT TEXT. Every walked file's code is kept, and after the walk each one is
    # checked against every text input, including those a walked library declared after that file was read.
    $walkedCode = [Collections.Generic.List[object]]::new()
    $walkedCode.Add([pscustomobject]@{ Rel = ''; Code = (Remove-TcGateComments -Text $text) })
    $outDecl = [Collections.Generic.List[object]]::new()
    while ($queue.Count) {
      $rel = $queue.Dequeue()
      if ($seen.ContainsKey($rel)) { continue }
      $seen[$rel] = $true
      $full = [IO.Path]::Combine($repoFull, $rel)
      # A text-only input is hashed and NOT walked into, whichever road reached it.
      if ($textSet.ContainsKey($rel)) {
        $rows.Add('text ' + $rel + ' ' + (Get-TcFileSha256 $full))
        $files.Add($full)
        continue
      }
      $rows.Add('ref ' + $rel + ' ' + (Get-TcFileSha256 $full))
      $files.Add($full)
      if ($rel -match '(?i)\.ps1$' -and [IO.File]::Exists($full)) {
        $sub = ''
        try { $sub = [IO.File]::ReadAllText($full) } catch { $sub = '' }
        if ($sub) { $walkedCode.Add([pscustomobject]@{ Rel = $rel; Code = (Remove-TcGateComments -Text $sub) }) }
        if ($sub) {
          # A LIBRARY THAT READS DATA POISONS EVERY GATE THAT LOADS IT, so the refusal travels up the graph - UNLESS
          # this gate declared its inputs, in which case the author has already answered the question the inference
          # was asking, and the contagion is the inference's uncertainty rather than a fact about the library.
          # This is what unblocks the 8 gates refused on 2026-09-12 only because something they load was unkeyable.
          # A DECLARING LIBRARY DOES NOT POISON ITS CALLERS EITHER, and that is the half that matters: on
          # 2026-09-12 lib\gate-slots.ps1 alone refused four gates that merely dot-source it. Its own declaration
          # answers the question the inference was guessing at, so the contagion stops there - and the library's
          # declared inputs join this walk, or a caller's key would be blind to what the library reads.
          $subDecl = Get-TcGateDeclaredInputs -Text $sub
          $subDecl = @($subDecl)
          # A LIBRARY'S TEXT-ONLY INPUTS are hashed in its callers' keys too, and not walked, exactly as in its own.
          $subText = Get-TcGateDeclaredTextInputs -Text $sub
          $subText = @($subText)
          if ($subText.Count) {
            $subTRes = Resolve-TcGateDeclaredInputs -Repo $Repo -Patterns $subText
            if (-not $subTRes.Ok) {
              return [pscustomobject]@{ Ok = $false; Key = ''; Why = ('a file it loads (' + $rel + ') ' + $subTRes.Why); Files = @() }
            }
            foreach ($p in $subTRes.Paths) { if (-not $forceWalk.ContainsKey($p)) { $textSet[$p] = $true }; $queue.Enqueue($p) }
          }
          if ($subDecl.Count) {
            $subRes = Resolve-TcGateDeclaredInputs -Repo $Repo -Patterns $subDecl
            if (-not $subRes.Ok) {
              return [pscustomobject]@{ Ok = $false; Key = ''; Why = ('a file it loads (' + $rel + ') ' + $subRes.Why); Files = @() }
            }
            foreach ($p in $subRes.Paths) { $queue.Enqueue($p) }
          } elseif ($subText.Count) {
            # a library that declares only text inputs has still answered the inference's question
          } elseif (-not $declResolved) {
            $subCan = Test-TcGateCacheable -Text $sub
            if (-not $subCan.Ok) {
              return [pscustomobject]@{ Ok = $false; Key = ''; Why = ('a file it loads (' + $rel + ') ' + $subCan.Why); Files = @() }
            }
          }
          $subStrict = (-not $declResolved) -and (-not $subDecl.Count) -and (-not $subText.Count)
          $subRefs = Resolve-TcGateFileRefs -Repo $Repo -FileRel $rel -GateRel $gateRel -Text $sub -Strict:$subStrict
          if (-not $subRefs.Ok) {
            return [pscustomobject]@{ Ok = $false; Key = ''; Why = ('a file it loads (' + $rel + ') ' + $subRefs.Why); Files = @() }
          }
          # A FILE THIS LIBRARY DECLARES IT ONLY WRITES leaves its own literals here; whether it comes back is decided
          # after the walk, once every file that could read it has been seen.
          $subOut = Get-TcGateDeclaredOutputs -Text $sub
          if (-not $subOut.Ok) { return [pscustomobject]@{ Ok = $false; Key = ''; Why = ('a file it loads (' + $rel + ') ' + $subOut.Why); Files = @() } }
          $subOutSet = New-Object Collections.Hashtable ([StringComparer]::OrdinalIgnoreCase)
          foreach ($o in $subOut.Outputs) { $subOutSet[$o.Path] = $true; $outDecl.Add([pscustomobject]@{ Path = $o.Path; Readers = $o.Readers; Owner = $rel }) }
          foreach ($p in $subRefs.Paths) { if (-not $subOutSet.ContainsKey($p)) { $queue.Enqueue($p) } }
          foreach ($p in $subRefs.Absent) { if (-not $subOutSet.ContainsKey($p)) { $absentSeen[$p] = $true } }
        }
      }
    }
    $conflict = $false
    foreach ($tp in @($textSet.Keys)) {
      $tl = [IO.Path]::GetFileName($tp)
      foreach ($wc in $walkedCode) {
        if (Test-TcGateLoadsLeaf -Code $wc.Code -Leaf $tl) {
          # The GATE's own text declaration is an assertion the author got wrong: refuse. A LIBRARY's is only true of
          # that library, so here the file is walked as code on the next attempt - the key widens, never narrows.
          if ($gateTextSet.ContainsKey($tp)) {
            $who = if ($wc.Rel) { 'a file it loads (' + $wc.Rel + ')' } else { 'the gate' }
            return [pscustomobject]@{ Ok = $false; Key = ''; Why = ("declares '" + $tp + "' as text only, but " + $who + " loads or runs it, so what it loads would be missing from the key"); Files = @() }
          }
          $forceWalk[$tp] = $true; $conflict = $true
          break
        }
      }
    }
    if (-not $conflict) { $walkDone = $true; break }
  }
  if (-not $walkDone) { return [pscustomobject]@{ Ok = $false; Key = ''; Why = 'the text-input walk did not settle, so the key refuses rather than guess'; Files = @() } }
  # A DECLARED OUTPUT COMES BACK INTO THE KEY when any walked file but its own library names a reader of it or the file
  # itself: that code may read it. Reached by another road, it is already hashed, and nothing here removes it.
  foreach ($o in $outDecl) {
    if ($seen.ContainsKey($o.Path)) { continue }
    $reads = $false
    foreach ($wc in $walkedCode) {
      if ([string]::Equals($wc.Rel, $o.Owner, [StringComparison]::OrdinalIgnoreCase)) { continue }
      if (Test-TcGateNamesOutputReader -Code $wc.Code -Path $o.Path -Readers $o.Readers) { $reads = $true; break }
    }
    if (-not $reads) { continue }
    $seen[$o.Path] = $true
    $ofull = [IO.Path]::Combine($repoFull, $o.Path)
    if ([IO.File]::Exists($ofull)) { $rows.Add('ref ' + $o.Path + ' ' + (Get-TcFileSha256 $ofull)); $files.Add($ofull) }
    else { $rows.Add('cand ' + $o.Path + ' absent') }
  }
  # A CANDIDATE THAT IS NOT THERE STILL GOES INTO THE KEY, so a file appearing where a base could point moves it.
  foreach ($p in @($absentSeen.Keys)) { if (-not $seen.ContainsKey($p)) { $rows.Add('cand ' + $p + ' absent') } }
  foreach ($rf in @($RunnerFiles)) {
    if (-not $rf) { continue }
    $rows.Add('runner ' + [IO.Path]::GetFileName($rf) + ' ' + (Get-TcFileSha256 $rf))
    $files.Add($rf)
  }
  # The interpreter is part of the answer: the same bytes on a different PowerShell are a different run.
  $rows.Add('ps ' + $PSVersionTable.PSVersion.ToString())
  $sorted = $rows.ToArray()
  [Array]::Sort($sorted, [StringComparer]::Ordinal)
  $sha = [Security.Cryptography.SHA256]::Create()
  try { $key = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($sorted -join "`n")))) -replace '-', '').ToLowerInvariant() }
  finally { $sha.Dispose() }
  return [pscustomobject]@{ Ok = $true; Key = $key; Why = ''; Files = @($files) }
}

function Get-TcGateCachedVerdict {
  <# The gate's OWN last line, stored beside the key and replayed when the entry is reused.

     WHY IT IS STORED AT ALL (2026-09-12, found by running it). run-gates scores a self-test that exits 0
     without naming its own verdict as a 3 (lib\selftest-verdict.ps1), so a reused gate that printed a
     invented line scored could-not-evaluate: 182 of them in one run. A reused gate must say what it said
     when it ran, not what the cache thinks of it. Everything after the third field is that line. #>
  param([string]$Line)
  if (-not $Line) { return '' }
  $t = $Line.Trim()
  $parts = $t -split '\s+', 4
  if ($parts.Count -lt 4) { return '' }
  return $parts[3]
}

function Get-TcGateCacheId {
  <# What a cache entry is NAMED by: the gate's path BELOW its checkout, its switch, and its key.

     THE CACHE WAS NEVER SHARED, although the comment on Get-TcGateCachePath said it was (found 2026-09-12). run-gates
     named each entry from the gate's FULL path, so C:\Codex\ThriftyCrew\ops\x.ps1 and
     ...\.claude\worktrees\w1\ops\x.ps1 were two entries. The KEY inside was already path-independent - its rows are a
     file name, a repo-relative path and a SHA - so the answer was right and simply unreachable from any other checkout.
     Measured with the main checkout and a worktree at the SAME commit: 5 of 7 keyable gates had identical keys and
     different cache files, and the directory held 4,551 entries, 18.6 per keyable gate, across 138 worktrees. A push
     from any checkout that had not itself passed that content ran cold: 93 to 373 s of wall that day against 43 to 71 s
     warm.

     THE KEY IS IN THE NAME, not just in the line, so two checkouts at DIFFERENT commits do not overwrite each other's
     entry and evict it on every alternate push. One entry per (gate, content) is shared by every checkout that holds
     that content, which is what the cache was for.

     NOT NORMALISED: the key still hashes raw bytes. The same day, three tracked files read clean in `git status` in both
     checkouts with different bytes on disk (line endings), so gates reading them do not share between those two. That
     is the conservative direction on purpose - several gates here read other files' BYTES, and a key that folded CRLF
     into LF would replay a pass across a difference such a gate would see. #>
  param([string]$Repo, [string]$GateFile, [string]$GateArg, [string]$Key)
  $root = [IO.Path]::GetFullPath($Repo).TrimEnd('\')
  $full = [IO.Path]::GetFullPath(($GateFile -replace '/', '\'))
  $rel = $full
  if ($full.Length -gt $root.Length -and $full.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) {
    $rel = $full.Substring($root.Length + 1)
  }
  # A gate outside its own checkout keeps its full path, so it simply does not share - it never collides.
  return ($rel.ToLowerInvariant() + '|' + $GateArg + '|' + $Key)
}

function Remove-TcGateStaleEntries {
  <# Delete cache entries past the age backstop, and nothing else. Returns how many were removed.

     NOTHING PRUNED THIS DIRECTORY BEFORE, and naming entries by their key means one per (gate, content), so it would
     otherwise only grow. It is safe BY THE HIT RULE: Test-TcGateCacheHit refuses an entry whose recorded time is older
     than the backstop, and an entry's recorded time is written in the same write as the file, so a file whose write
     time is past the backstop can never be a hit. Removing it changes no answer any run could get. A delete that races
     another run's is caught and ignored; a reader that loses the race reads a miss and runs the gate. #>
  param([string]$CacheDir, [DateTime]$NowUtc, [int]$MaxAgeHours = $script:TcGateKeyMaxAgeHours)
  if (-not $CacheDir -or -not [IO.Directory]::Exists($CacheDir)) { return 0 }
  $cut = $NowUtc.AddHours(-$MaxAgeHours)
  $removed = 0
  foreach ($p in [IO.Directory]::EnumerateFiles($CacheDir, '*.pass')) {
    try {
      if ([IO.File]::GetLastWriteTimeUtc($p) -lt $cut) { [IO.File]::Delete($p); $removed++ }
    } catch { }
  }
  return $removed
}

function Get-TcGateCachePath {
  <# The file for one cache id under the COMMON git directory. Pass it Get-TcGateCacheId's answer, never a full path:
     a full path is one checkout's name for a gate, and that is exactly how the cache stopped being shared. #>
  param([string]$CacheDir, [string]$GateId)
  $sha = [Security.Cryptography.SHA256]::Create()
  try { $h = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($GateId))) -replace '-', '').ToLowerInvariant() }
  finally { $sha.Dispose() }
  return (Join-Path $CacheDir ($h.Substring(0, 32) + '.pass'))
}

function Test-TcGateCacheHit {
  <# Pure over the stored LINE, so the fixture drives it without a disk. A hit needs the same key, a recorded
     exit 0, and an age inside the backstop. Anything else is a miss with a reason. #>
  param([string]$Line, [string]$Key, [DateTime]$NowUtc, [int]$MaxAgeHours = $script:TcGateKeyMaxAgeHours)
  if (-not $Line) { return [pscustomobject]@{ Hit = $false; Why = 'no entry' } }
  $p = $Line.Trim() -split '\s+'
  if ($p.Count -lt 3) { return [pscustomobject]@{ Hit = $false; Why = 'entry is not three fields' } }
  if (-not [string]::Equals($p[0], $Key, [StringComparison]::Ordinal)) { return [pscustomobject]@{ Hit = $false; Why = 'the inputs changed' } }
  if ($p[1] -ne '0') { return [pscustomobject]@{ Hit = $false; Why = 'the recorded run did not pass' } }
  $at = [DateTime]::MinValue
  if (-not [DateTime]::TryParse($p[2], [ref]$at)) { return [pscustomobject]@{ Hit = $false; Why = 'unreadable timestamp' } }
  if (($NowUtc - $at.ToUniversalTime()).TotalHours -gt $MaxAgeHours) { return [pscustomobject]@{ Hit = $false; Why = 'older than the backstop' } }
  return [pscustomobject]@{ Hit = $true; Why = '' }
}

# -VerifyDeclared <gate>[,<gate>...]: run Test-TcGateDeclarationMoves over each named gate and exit 1 if any declared input
# fails to move its key. The harness for "each declaration must be verified" (2026-09-23), committed so the next
# declaration is verified the same way.
$__gikVerify = ($MyInvocation.InvocationName -ne '.') -and ($args -contains '-VerifyDeclared')
if ($__gikVerify) {
  $vRepo = Split-Path -Parent $PSScriptRoot
  $vi = [Array]::IndexOf($args, '-VerifyDeclared')
  $vGates = @(); for ($j = $vi + 1; $j -lt $args.Count; $j++) { foreach ($g in ([string]$args[$j] -split ',')) { if ($g.Trim()) { $vGates += $g.Trim() } } }
  $vBad = 0
  foreach ($g in $vGates) {
    $vr = Test-TcGateDeclarationMoves -Repo $vRepo -GateFile (Join-Path $vRepo $g)
    Write-Output ('{0} {1}  probes={2}{3}' -f $(if ($vr.Ok) { 'VERIFIED' } else { 'NOT-VERIFIED' }), $g, @($vr.Rows).Count, $(if ($vr.Why) { '  ' + $vr.Why } else { '' }))
    if (-not $vr.Ok) { $vBad++ }
  }
  Write-Output ('GATE-DECLARATIONS-VERIFIED {0} of {1}' -f ($vGates.Count - $vBad), $vGates.Count)
  if ($vBad -or -not $vGates.Count) { exit 1 }
  exit 0
}

if ($__gikSelfTest) {
  $f = 0; $cases = 0
  function T([string]$m, [bool]$c, [string]$got = '') {
    $script:cases++
    if ($c) { Write-Output ('ok    ' + $m) } else { Write-Output ('FAIL  ' + $m + '   got: ' + $got); $script:f++ }
  }
  $sb = Join-Path $env:TEMP ('tc-gik-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
  $utf8 = New-Object Text.UTF8Encoding($false)
  try {
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $sb 'lib')
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $sb 'ops')
    $gate = Join-Path $sb 'ops\audit-thing.ps1'
    $lib = Join-Path $sb 'lib\helper.ps1'
    $lib2 = Join-Path $sb 'lib\deeper.ps1'
    $other = Join-Path $sb 'ops\caller.ps1'
    $runner = Join-Path $sb 'ops\run-gates.ps1'
    [IO.File]::WriteAllText($lib2, "# deeper`n", $utf8)
    [IO.File]::WriteAllText($lib, ". (Join-Path `$repo 'lib\deeper.ps1')`n", $utf8)
    [IO.File]::WriteAllText($other, "# the production caller this gate asserts`n", $utf8)
    [IO.File]::WriteAllText($runner, "# the runner`n", $utf8)
    $gateText = @'
. (Join-Path $repo 'lib\helper.ps1')
$caller = Join-Path $repo 'ops\caller.ps1'
if ($SelfTest) { Write-Output 'cases' }
'@
    [IO.File]::WriteAllText($gate, $gateText, $utf8)
    $k1 = Get-TcGateInputKey -Repo $sb -GateFile $gate -GateArg '-SelfTest' -RunnerFiles @($runner)
    T 'CLEAN TWIN a gate whose inputs are all named resolves to a key, and names what went into it' `
      ($k1.Ok -and $k1.Key.Length -eq 64 -and @($k1.Files).Count -eq 5) ("ok={0} files={1} why={2}" -f $k1.Ok, @($k1.Files).Count, $k1.Why)
    $k1b = Get-TcGateInputKey -Repo $sb -GateFile $gate -GateArg '-SelfTest' -RunnerFiles @($runner)
    T 'CLEAN TWIN the same bytes twice give the same key, or nothing could ever be reused' ($k1.Key -eq $k1b.Key) ("{0} / {1}" -f $k1.Key, $k1b.Key)

    # MUST FIRE - each input, one at a time. These are the cases that make a stale pass impossible.
    [IO.File]::WriteAllText($gate, $gateText + "# edited`n", $utf8)
    $kGate = Get-TcGateInputKey -Repo $sb -GateFile $gate -GateArg '-SelfTest' -RunnerFiles @($runner)
    T 'MUST FIRE  editing the GATE changes its key' ($kGate.Key -ne $k1.Key) 'key survived an edit to the gate'
    [IO.File]::WriteAllText($gate, $gateText, $utf8)
    [IO.File]::WriteAllText($lib, ". (Join-Path `$repo 'lib\deeper.ps1')`n# edited`n", $utf8)
    $kLib = Get-TcGateInputKey -Repo $sb -GateFile $gate -GateArg '-SelfTest' -RunnerFiles @($runner)
    T 'MUST FIRE  editing a LIBRARY it dot-sources changes its key' ($kLib.Key -ne $k1.Key) 'key survived an edit to a library'
    [IO.File]::WriteAllText($lib2, "# deeper edited`n", $utf8)
    $kDeep = Get-TcGateInputKey -Repo $sb -GateFile $gate -GateArg '-SelfTest' -RunnerFiles @($runner)
    T 'MUST FIRE  editing a library TWO hops away changes its key - the walk is transitive, which is how a change reaches a gate that never named it' `
      ($kDeep.Key -ne $kLib.Key) 'key survived an edit two hops down'
    [IO.File]::WriteAllText($other, "# caller edited`n", $utf8)
    $kOther = Get-TcGateInputKey -Repo $sb -GateFile $gate -GateArg '-SelfTest' -RunnerFiles @($runner)
    T 'MUST FIRE  editing a repo file the gate NAMES changes its key' ($kOther.Key -ne $kDeep.Key) 'key survived an edit to a named file'
    [IO.File]::WriteAllText($runner, "# runner edited`n", $utf8)
    $kRun = Get-TcGateInputKey -Repo $sb -GateFile $gate -GateArg '-SelfTest' -RunnerFiles @($runner)
    T 'MUST FIRE  editing the RUNNER changes every key - the dispatcher is part of what a pass means' ($kRun.Key -ne $kOther.Key) 'key survived an edit to the runner'
    $kArg = Get-TcGateInputKey -Repo $sb -GateFile $gate -GateArg '-OtherSwitch' -RunnerFiles @($runner)
    T 'MUST FIRE  the same file run with a different switch is a different gate' ($kArg.Key -ne $kRun.Key) 'the argument did not reach the key'

    # MUST NOT FIRE - a file it never reads must NOT change the key, or nothing is ever reused.
    [IO.File]::WriteAllText((Join-Path $sb 'ops\unrelated.ps1'), "# nothing to do with the gate`n", $utf8)
    $kUnrel = Get-TcGateInputKey -Repo $sb -GateFile $gate -GateArg '-OtherSwitch' -RunnerFiles @($runner)
    T 'MUST NOT FIRE  a file the gate never names does not change its key, which is the whole point of caching per gate' `
      ($kUnrel.Key -eq $kArg.Key) 'an unrelated file moved the key'

    # ---- A GATE MAY DECLARE ITS INPUTS (Brad, 2026-09-12) ----
    # The declaration exists for gates the inference cannot key, so every case here starts from a gate the
    # inference REFUSES and asks what the declaration does to it.
    $decl = Join-Path $sb 'ops\test-hooky.ps1'
    $declBody = "`$p = Join-Path `$repo `$whatever   # the inference cannot follow this`nif (`$SelfTest) { }`n"
    [IO.File]::WriteAllText($decl, $declBody, $utf8)
    $kNoDecl = Get-TcGateInputKey -Repo $sb -GateFile $decl -GateArg '-SelfTest' -RunnerFiles @($runner)
    T 'MUST FIRE  without a declaration the inference still refuses a variable-built path, so nothing is weakened by default' `
      ((-not $kNoDecl.Ok) -and $kNoDecl.Why -match 'variable') ("ok={0} why={1}" -f $kNoDecl.Ok, $kNoDecl.Why)
    [IO.File]::WriteAllText($decl, ("# gate-inputs: lib\*.ps1, ops\unrelated.ps1`n" + $declBody), $utf8)
    $kDecl = Get-TcGateInputKey -Repo $sb -GateFile $decl -GateArg '-SelfTest' -RunnerFiles @($runner)
    T 'MUST FIRE  a gate that DECLARES what it reads is keyable although the inference refused it' `
      ($kDecl.Ok) ("ok={0} why={1}" -f $kDecl.Ok, $kDecl.Why)
    # THE DECLARED FILES ARE HASHED, not merely listed - the point is that a change to one still moves the key.
    [IO.File]::WriteAllText((Join-Path $sb 'ops\unrelated.ps1'), "# edited after the declaration`n", $utf8)
    $kDeclEdit = Get-TcGateInputKey -Repo $sb -GateFile $decl -GateArg '-SelfTest' -RunnerFiles @($runner)
    T 'MUST FIRE  editing a DECLARED file moves the key, so a declaration shortens nothing' `
      ($kDeclEdit.Ok -and $kDeclEdit.Key -ne $kDecl.Key) 'a declared file was not in the key'
    # A GLOB MEANS THE DIRECTORY, which is the only form that can cover ops\test-prepush-hook.ps1 - it copies
    # lib\*.ps1 by enumeration, so a NEW library must move its key without anyone editing the declaration.
    [IO.File]::WriteAllText((Join-Path $sb 'lib\brand-new.ps1'), "# a library that did not exist a moment ago`n", $utf8)
    $kDeclNew = Get-TcGateInputKey -Repo $sb -GateFile $decl -GateArg '-SelfTest' -RunnerFiles @($runner)
    T 'MUST FIRE  a NEW file appearing under a declared glob moves the key, which a hand list could never do' `
      ($kDeclNew.Ok -and $kDeclNew.Key -ne $kDeclEdit.Key) 'a new file under the declared glob did not reach the key'
    # THE SAFETY PROPERTY. A declaration that matches nothing is the one way this could narrow an input set in
    # silence, and silence here is a STALE PASS - so it refuses instead.
    [IO.File]::WriteAllText($decl, ("# gate-inputs: lib\typo-*.ps1`n" + $declBody), $utf8)
    $kStale = Get-TcGateInputKey -Repo $sb -GateFile $decl -GateArg '-SelfTest' -RunnerFiles @($runner)
    T 'MUST FIRE  a declared pattern matching NO file is refused, never read as an empty input set' `
      ((-not $kStale.Ok) -and $kStale.Why -match 'matches no file') ("ok={0} why={1}" -f $kStale.Ok, $kStale.Why)
    [IO.File]::WriteAllText($decl, ("# gate-inputs: ..\outside.ps1`n" + $declBody), $utf8)
    $kEsc = Get-TcGateInputKey -Repo $sb -GateFile $decl -GateArg '-SelfTest' -RunnerFiles @($runner)
    T 'MUST FIRE  a declaration cannot name a path outside this repo' `
      ((-not $kEsc.Ok) -and $kEsc.Why -match 'inside this repo') ("ok={0} why={1}" -f $kEsc.Ok, $kEsc.Why)
    $declPure = Get-TcGateDeclaredInputs -Text "# gate-inputs: a.ps1 , b.ps1`n# gate-inputs: c.ps1`n"
    T 'CLEAN TWIN  the declaration parser splits on commas, trims, and reads more than one declaration line' `
      ($declPure.Count -eq 3 -and $declPure[0] -eq 'a.ps1' -and $declPure[2] -eq 'c.ps1') ($declPure -join '|')
    T 'MUST NOT FIRE  a gate with no declaration line declares nothing, rather than declaring everything' `
      ((Get-TcGateDeclaredInputs -Text "# just a comment`n").Count -eq 0) 'a gate without a declaration was read as declaring something'
    # THE CONTAGION STOPS AT A DECLARATION. An undeclared gate that loads an unkeyable library is refused, and
    # must stay refused; the same gate loading a library that DECLARES is keyable, because the library has
    # answered the question the inference could not. On 2026-09-12 one library refused four gates this way.
    $poisonLib = Join-Path $sb 'lib\poisons.ps1'
    [IO.File]::WriteAllText($poisonLib, "`$q = Join-Path `$repo `$whatever`n", $utf8)
    $caller = Join-Path $sb 'ops\loads-poison.ps1'
    [IO.File]::WriteAllText($caller, ". (Join-Path `$repo 'lib\poisons.ps1')`nif (`$SelfTest) { }`n", $utf8)
    $kPoisoned = Get-TcGateInputKey -Repo $sb -GateFile $caller -GateArg '-SelfTest' -RunnerFiles @($runner)
    T 'MUST FIRE  a gate that loads an UNKEYABLE library is still refused, so the contagion rule is not lost' `
      ((-not $kPoisoned.Ok) -and $kPoisoned.Why -match 'a file it loads') ("ok={0} why={1}" -f $kPoisoned.Ok, $kPoisoned.Why)
    [IO.File]::WriteAllText($poisonLib, ("# gate-inputs: lib\poisons.ps1`n`$q = Join-Path `$repo `$whatever`n"), $utf8)
    $kCured = Get-TcGateInputKey -Repo $sb -GateFile $caller -GateArg '-SelfTest' -RunnerFiles @($runner)
    T 'MUST FIRE  the same gate is keyable once the library it loads DECLARES, so one file stops refusing its callers' `
      ($kCured.Ok) ("ok={0} why={1}" -f $kCured.Ok, $kCured.Why)
    [IO.File]::WriteAllText($poisonLib, ("# gate-inputs: lib\never-existed-*.ps1`n`$q = Join-Path `$repo `$whatever`n"), $utf8)
    $kBadSub = Get-TcGateInputKey -Repo $sb -GateFile $caller -GateArg '-SelfTest' -RunnerFiles @($runner)
    T 'MUST FIRE  a STALE declaration in a loaded library refuses its callers too, rather than quietly keying them' `
      ((-not $kBadSub.Ok) -and $kBadSub.Why -match 'matches no file') ("ok={0} why={1}" -f $kBadSub.Ok, $kBadSub.Why)

    # MUST FIRE - the refusals. A gate we cannot key must never be cached.
    $dataGate = Join-Path $sb 'ops\audit-data.ps1'
    # reach-fixture-ok: the fixture GATE's source, written into a temp sandbox - it is the input this refusal
    # exists to detect, so the case cannot be written without naming the shape it refuses.
    [IO.File]::WriteAllText($dataGate, "`$b = Join-Path `$repo 'grocery\out\comparison-2026-01-01.json'`nif (`$SelfTest) { }`n", $utf8)   # reach-fixture-ok: the shape this rule REFUSES, named in a pattern or written into a temp sandbox; nothing here opens a real data file
    $kData = Get-TcGateInputKey -Repo $sb -GateFile $dataGate -GateArg '-SelfTest'
    T 'MUST FIRE  a gate that reads a DATA directory is refused, because those bytes change with no commit' `
      ((-not $kData.Ok) -and $kData.Why -match 'data directory') ("ok={0} why={1}" -f $kData.Ok, $kData.Why)
    $compGate = Join-Path $sb 'ops\audit-computed.ps1'
    [IO.File]::WriteAllText($compGate, "`$p = Join-Path `$repo `$someVar`nif (`$SelfTest) { }`n", $utf8)
    $kComp = Get-TcGateInputKey -Repo $sb -GateFile $compGate -GateArg '-SelfTest'
    T 'MUST FIRE  a gate that builds a repo path from a VARIABLE is refused - a key cannot watch what it cannot name' `
      ((-not $kComp.Ok) -and $kComp.Why -match 'variable') ("ok={0} why={1}" -f $kComp.Ok, $kComp.Why)
    # MUST FIRE - and the refusal travels UP: a clean-looking gate that loads a data-reading library is refused too.
    $poison = Join-Path $sb 'lib\reads-data.ps1'
    # reach-fixture-ok: the fixture LIBRARY's source, in a temp sandbox - the case exists to prove a data read
    # one hop down still refuses the gate above it, and it cannot be written without naming that shape.
    [IO.File]::WriteAllText($poison, "`$x = Join-Path `$repo 'meal-prep\db\costed.json'`n", $utf8)   # reach-fixture-ok: the shape this rule REFUSES, named in a pattern or written into a temp sandbox; nothing here opens a real data file
    $viaLib = Join-Path $sb 'ops\audit-vialib.ps1'
    [IO.File]::WriteAllText($viaLib, ". (Join-Path `$repo 'lib\reads-data.ps1')`nif (`$SelfTest) { }`n", $utf8)
    $kVia = Get-TcGateInputKey -Repo $sb -GateFile $viaLib -GateArg '-SelfTest'
    T 'MUST FIRE  a gate is refused when a LIBRARY it loads reads data - the refusal travels up the graph, or the key would vouch for bytes nobody watched' `
      ((-not $kVia.Ok) -and $kVia.Why -match 'a file it loads') ("ok={0} why={1}" -f $kVia.Ok, $kVia.Why)
    $kMissing = Get-TcGateInputKey -Repo $sb -GateFile (Join-Path $sb 'ops\not-here.ps1') -GateArg ''
    T 'MUST FIRE  a gate file that is not there is refused, never keyed as absent' `
      ((-not $kMissing.Ok) -and $kMissing.Why -match 'does not exist') $kMissing.Why

    # ---- THE FOUR RULES OF 2026-09-23: a path is resolved against the folder its variable names ----
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $sb 'grocery')
    $gDep = Join-Path $sb 'grocery\dep.ps1'
    [IO.File]::WriteAllText($gDep, "# read by the gate beside it`n", $utf8)
    $g1 = Join-Path $sb 'grocery\beside-gate.ps1'
    $g1Text = @'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$crPath = Join-Path $root 'dep.ps1'
if ($SelfTest) { }
'@
    [IO.File]::WriteAllText($g1, $g1Text, $utf8)
    $kR1a = Get-TcGateInputKey -Repo $sb -GateFile $g1 -GateArg '-SelfTest' -RunnerFiles @($runner)
    [IO.File]::WriteAllText($gDep, "# read by the gate beside it, edited`n", $utf8)
    $kR1b = Get-TcGateInputKey -Repo $sb -GateFile $g1 -GateArg '-SelfTest' -RunnerFiles @($runner)
    T 'MUST FIRE  rule 1: editing a file joined to $root = $PSScriptRoot moves the key (the founding incident: capture-run.ps1 changed four times under one watchdog key)' `
      ($kR1a.Ok -and $kR1b.Ok -and $kR1a.Key -ne $kR1b.Key) ("okA={0} okB={1} whyA={2}" -f $kR1a.Ok, $kR1b.Ok, $kR1a.Why)
    $gUp = Join-Path $sb 'ops\up-one.ps1'
    $gUpText = @'
$repo = Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'lib\helper.ps1')
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\brand-new.ps1')
if ($SelfTest) { }
'@
    [IO.File]::WriteAllText($gUp, $gUpText, $utf8)
    $kUp1 = Get-TcGateInputKey -Repo $sb -GateFile $gUp -GateArg '-SelfTest' -RunnerFiles @($runner)
    [IO.File]::WriteAllText((Join-Path $sb 'lib\brand-new.ps1'), "# edited through a (Split-Path `$PSScriptRoot -Parent) join`n", $utf8)
    $kUp2 = Get-TcGateInputKey -Repo $sb -GateFile $gUp -GateArg '-SelfTest' -RunnerFiles @($runner)
    T 'MUST FIRE  rule 1: a base ONE folder up (Split-Path -Parent $PSScriptRoot, and the inline (Split-Path $PSScriptRoot -Parent)) resolves there, and an edit there moves the key' `
      ($kUp1.Ok -and $kUp2.Ok -and $kUp1.Key -ne $kUp2.Key) ("ok1={0} ok2={1} why={2}" -f $kUp1.Ok, $kUp2.Ok, $kUp1.Why)
    $gPs = Join-Path $sb 'grocery\ps-root.ps1'
    [IO.File]::WriteAllText($gPs, "`$d = Join-Path `$PSScriptRoot 'dep.ps1'`nif (`$SelfTest) { }`n", $utf8)
    $kPs1 = Get-TcGateInputKey -Repo $sb -GateFile $gPs -GateArg '-SelfTest' -RunnerFiles @($runner)
    [IO.File]::WriteAllText($gDep, "# read by the gate beside it, edited twice`n", $utf8)
    $kPs2 = Get-TcGateInputKey -Repo $sb -GateFile $gPs -GateArg '-SelfTest' -RunnerFiles @($runner)
    T 'CLEAN TWIN  rule 4 parses Join-Path $PSScriptRoot ''<lit>'' rather than refusing it: it keys, and an edit to the file moves the key' `
      ($kPs1.Ok -and $kPs2.Ok -and $kPs1.Key -ne $kPs2.Key) ("ok1={0} ok2={1} why={2}" -f $kPs1.Ok, $kPs2.Ok, $kPs1.Why)
    # RULE 2. The constant 'absent' is gone: a named input that is nowhere is a refusal.
    $gNo = Join-Path $sb 'grocery\names-ghost.ps1'
    [IO.File]::WriteAllText($gNo, "`$root = `$PSScriptRoot`n`$x = Join-Path `$root 'never-made.ps1'`nif (`$SelfTest) { }`n", $utf8)
    $kNo = Get-TcGateInputKey -Repo $sb -GateFile $gNo -GateArg '-SelfTest' -RunnerFiles @($runner)
    T 'MUST FIRE  rule 2: an input that exists under no candidate folder is refused, never hashed as absent' `
      ((-not $kNo.Ok) -and $kNo.Why -match 'exists nowhere' -and $kNo.Why -match 'never-made') ("ok={0} why={1}" -f $kNo.Ok, $kNo.Why)
    [IO.File]::WriteAllText((Join-Path $sb 'root-only.ps1'), "# exists at the repo root and nowhere else`n", $utf8)
    [IO.File]::WriteAllText($gNo, "`$root = `$PSScriptRoot`n`$x = Join-Path `$root 'root-only.ps1'`nif (`$SelfTest) { }`n", $utf8)
    $kRootOnly = Get-TcGateInputKey -Repo $sb -GateFile $gNo -GateArg '-SelfTest' -RunnerFiles @($runner)
    T 'MUST FIRE  rule 2: a file at the REPO ROOT does not stand in for the one beside the gate its $root names - the old resolution keyed exactly that wrong file' `
      ((-not $kRootOnly.Ok) -and $kRootOnly.Why -match 'exists nowhere') ("ok={0} why={1}" -f $kRootOnly.Ok, $kRootOnly.Why)
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $sb 'grocery\fixtures')
    [IO.File]::WriteAllText($gNo, "`$root = `$PSScriptRoot`n`$x = Join-Path `$root 'fixtures'`nif (`$SelfTest) { }`n", $utf8)
    $kDir = Get-TcGateInputKey -Repo $sb -GateFile $gNo -GateArg '-SelfTest' -RunnerFiles @($runner)
    T 'MUST FIRE  rule 2: a named DIRECTORY is refused, because its listing is not in any key' `
      ((-not $kDir.Ok) -and $kDir.Why -match 'directory') ("ok={0} why={1}" -f $kDir.Ok, $kDir.Why)
    # An UNREADABLE base keys every candidate folder, including the ones that do not exist yet.
    [IO.File]::WriteAllText($gNo, "`$root = Get-Location`n`$x = Join-Path `$root 'root-only.ps1'`nif (`$SelfTest) { }`n", $utf8)
    $kUnk1 = Get-TcGateInputKey -Repo $sb -GateFile $gNo -GateArg '-SelfTest' -RunnerFiles @($runner)
    [IO.File]::WriteAllText((Join-Path $sb 'grocery\root-only.ps1'), "# a second candidate appears beside the gate`n", $utf8)
    $kUnk2 = Get-TcGateInputKey -Repo $sb -GateFile $gNo -GateArg '-SelfTest' -RunnerFiles @($runner)
    T 'CLEAN TWIN  a base the key cannot read still keys over every ancestor candidate, and a file APPEARING at another candidate moves the key' `
      ($kUnk1.Ok -and $kUnk2.Ok -and $kUnk1.Key -ne $kUnk2.Key) ("ok1={0} ok2={1} why={2}" -f $kUnk1.Ok, $kUnk2.Ok, $kUnk1.Why)
    # RULE 3. Data is judged on where the path LANDS.
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $sb 'grocery\out')
    [IO.File]::WriteAllText($gNo, "`$root = `$PSScriptRoot`n`$OutDir = Join-Path `$root 'out'`nif (`$SelfTest) { }`n", $utf8)
    $kOut = Get-TcGateInputKey -Repo $sb -GateFile $gNo -GateArg '-SelfTest' -RunnerFiles @($runner)
    T 'MUST FIRE  rule 3: Join-Path $root ''out'' beside a grocery script resolves into grocery\out and is refused as data, though the literal never spells it' `
      ((-not $kOut.Ok) -and $kOut.Why -match 'data directory') ("ok={0} why={1}" -f $kOut.Ok, $kOut.Why)
    Remove-Item -LiteralPath (Join-Path $sb 'grocery\out') -Recurse -Force
    $kOut2 = Get-TcGateInputKey -Repo $sb -GateFile $gNo -GateArg '-SelfTest' -RunnerFiles @($runner)
    T 'MUST FIRE  rule 3: the data refusal holds in a checkout where the data folder does not exist yet' `
      ((-not $kOut2.Ok) -and $kOut2.Why -match 'data directory') ("ok={0} why={1}" -f $kOut2.Ok, $kOut2.Why)
    [IO.File]::WriteAllText((Join-Path $sb 'grocery\outline.ps1'), "# a script whose name begins with out`n", $utf8)
    [IO.File]::WriteAllText($gNo, "`$root = `$PSScriptRoot`n`$x = Join-Path `$root 'outline.ps1'`nif (`$SelfTest) { }`n", $utf8)
    $kOutline = Get-TcGateInputKey -Repo $sb -GateFile $gNo -GateArg '-SelfTest' -RunnerFiles @($runner)
    T 'CLEAN TWIN  rule 3 matches a whole folder name: grocery\outline.ps1 is a source file and still keys' `
      ($kOutline.Ok) ("ok={0} why={1}" -f $kOutline.Ok, $kOutline.Why)
    # RULE 4. Every spelling that builds a path on a base and is not parsed is refused.
    $spell = @(
      @('[IO.Path]::Combine', "`$x = [IO.Path]::Combine(`$root, 'dep.ps1')"),
      @('interpolated string', "`$x = `"`$root\dep.ps1`""),
      @('double-quoted child', "`$x = Join-Path `$root `"dep.ps1`""),
      @('named parameters', "`$x = Join-Path -Path `$root -ChildPath 'dep.ps1'"),
      @('nested expression', "`$x = Join-Path (Join-Path `$root 'a') 'dep.ps1'"),
      @('$PSScriptRoot and a variable', "`$x = Join-Path `$PSScriptRoot `$leaf")
    )
    foreach ($sp in $spell) {
      [IO.File]::WriteAllText($gNo, ("`$root = `$PSScriptRoot`n" + $sp[1] + "`nif (`$SelfTest) { }`n"), $utf8)
      $kSp = Get-TcGateInputKey -Repo $sb -GateFile $gNo -GateArg '-SelfTest' -RunnerFiles @($runner)
      T ('MUST FIRE  rule 4: a path built by ' + $sp[0] + ' is refused, never silently dropped from the key') `
        ((-not $kSp.Ok) -and $kSp.Why -match 'spelling the key does not parse|from a variable') ("ok={0} why={1}" -f $kSp.Ok, $kSp.Why)
    }
    [IO.File]::WriteAllText($gNo, ("`$root = `$PSScriptRoot`n`$fx = `"`$root\dep.ps1 is fixture text`"`n" -replace '\$root\\dep', '`$root\dep') + "`$d = Join-Path `$root 'dep.ps1'`nif (`$SelfTest) { }`n", $utf8)
    $kEsc2 = Get-TcGateInputKey -Repo $sb -GateFile $gNo -GateArg '-SelfTest' -RunnerFiles @($runner)
    T 'MUST NOT FIRE  rule 4: a backtick-escaped `$root inside a fixture string is text, not a read, and does not refuse the gate' `
      ($kEsc2.Ok) ("ok={0} why={1}" -f $kEsc2.Ok, $kEsc2.Why)
    # TRANSITIVE: a file named by a LOADED library is an input too.
    [IO.File]::WriteAllText((Join-Path $sb 'grocery\g5-rules.json'), '{"v":1}', $utf8)
    [IO.File]::WriteAllText((Join-Path $sb 'grocery\g5-lib.ps1'), "`$here = `$PSScriptRoot`n`$rules = Join-Path `$here 'g5-rules.json'`n", $utf8)
    $g5 = Join-Path $sb 'grocery\g5.ps1'
    [IO.File]::WriteAllText($g5, ". (Join-Path `$PSScriptRoot 'g5-lib.ps1')`nif (`$SelfTest) { }`n", $utf8)
    $kG5a = Get-TcGateInputKey -Repo $sb -GateFile $g5 -GateArg '-SelfTest' -RunnerFiles @($runner)
    [IO.File]::WriteAllText((Join-Path $sb 'grocery\g5-rules.json'), '{"v":2}', $utf8)
    $kG5b = Get-TcGateInputKey -Repo $sb -GateFile $g5 -GateArg '-SelfTest' -RunnerFiles @($runner)
    T 'MUST FIRE  a file that a LOADED library names, beside that library, moves the key: the walk follows every literal, not only lib\ ones' `
      ($kG5a.Ok -and $kG5b.Ok -and $kG5a.Key -ne $kG5b.Key) ("okA={0} okB={1} why={2}" -f $kG5a.Ok, $kG5b.Ok, $kG5a.Why)
    [IO.File]::WriteAllText($gDep, "# the repo-root clean twin`n", $utf8)
    $gRootLib = Join-Path $sb 'ops\root-lib-gate.ps1'
    [IO.File]::WriteAllText($gRootLib, ". (Join-Path `$repo 'lib\deeper.ps1')`nif (`$SelfTest) { }`n", $utf8)
    $kRl1 = Get-TcGateInputKey -Repo $sb -GateFile $gRootLib -GateArg '-SelfTest' -RunnerFiles @($runner)
    [IO.File]::WriteAllText($lib2, "# deeper edited for the repo-root twin`n", $utf8)
    $kRl2 = Get-TcGateInputKey -Repo $sb -GateFile $gRootLib -GateArg '-SelfTest' -RunnerFiles @($runner)
    T 'CLEAN TWIN  a repo-root Join-Path $repo ''lib\x.ps1'' still keys, and still moves when x.ps1 changes' `
      ($kRl1.Ok -and $kRl2.Ok -and $kRl1.Key -ne $kRl2.Key) ("ok1={0} ok2={1} why={2}" -f $kRl1.Ok, $kRl2.Ok, $kRl1.Why)

    # A WILDCARD LITERAL is a listing: a new file under it moves the key.
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $sb 'grocery\rules')
    [IO.File]::WriteAllText((Join-Path $sb 'grocery\rules\a.json'), '{}', $utf8)
    $gGlob = Join-Path $sb 'grocery\globber.ps1'
    [IO.File]::WriteAllText($gGlob, "`$root = `$PSScriptRoot`n`$all = Get-ChildItem (Join-Path `$root 'rules\*.json')`nif (`$SelfTest) { }`n", $utf8)
    $kGl1 = Get-TcGateInputKey -Repo $sb -GateFile $gGlob -GateArg '-SelfTest' -RunnerFiles @($runner)
    [IO.File]::WriteAllText((Join-Path $sb 'grocery\rules\b.json'), '{}', $utf8)
    $kGl2 = Get-TcGateInputKey -Repo $sb -GateFile $gGlob -GateArg '-SelfTest' -RunnerFiles @($runner)
    T 'MUST FIRE  a wildcard literal is a listing: a NEW file matching it moves the key' `
      ($kGl1.Ok -and $kGl2.Ok -and $kGl1.Key -ne $kGl2.Key) ("ok1={0} ok2={1} why={2}" -f $kGl1.Ok, $kGl2.Ok, $kGl1.Why)
    # THE VERIFIER that every declaration added on 2026-09-23 went through.
    $gDecl = Join-Path $sb 'ops\declared-ok.ps1'
    [IO.File]::WriteAllText($gDecl, "# gate-inputs: ops\caller.ps1, grocery\rules\*.json`n`$p = Join-Path `$repo `$whatever`nif (`$SelfTest) { }`n", $utf8)
    $vOk = Test-TcGateDeclarationMoves -Repo $sb -GateFile $gDecl
    T 'CLEAN TWIN  the declaration verifier edits every declared file and adds one under every declared glob in a temp copy, and the key moves for each' `
      ($vOk.Ok -and @($vOk.Rows).Count -ge 3) ("ok={0} rows={1} why={2}" -f $vOk.Ok, @($vOk.Rows).Count, $vOk.Why)
    $vNone = Test-TcGateDeclarationMoves -Repo $sb -GateFile $g1
    T 'MUST FIRE  the verifier refuses a gate that declares nothing, rather than reporting a declaration it never saw as verified' `
      ((-not $vNone.Ok) -and $vNone.Why -match 'declares nothing') ("ok={0} why={1}" -f $vNone.Ok, $vNone.Why)

    # ---- A TEXT-ONLY INPUT (gate-inputs-text:, 2026-09-24): hashed, never walked into ----
    # The founding shape: lib\checkout-sync.ps1's suite parses grocery\capture-run.ps1 as text, and walking into it put
    # 2,968 files in the key. Here the parsed file loads a library that moves on its own, and names a file that is gone.
    $txBig = Join-Path $sb 'grocery\big-entry.ps1'
    $txDep = Join-Path $sb 'grocery\big-dep.ps1'
    [IO.File]::WriteAllText($txDep, "# a library the parsed file loads; the gate never runs it`n", $utf8)
    [IO.File]::WriteAllText($txBig, ". (Join-Path `$PSScriptRoot 'big-dep.ps1')`n`$x = Join-Path `$PSScriptRoot 'gone-by-now.ps1'`n", $utf8)
    $txGate = Join-Path $sb 'lib\parses-big.ps1'
    $txBody = "# gate-inputs: lib\helper.ps1`n# gate-inputs-text: grocery\big-entry.ps1`n`$src = Join-Path (Split-Path -Parent `$PSScriptRoot) 'grocery\big-entry.ps1'`n`$ast = [System.Management.Automation.Language.Parser]::ParseFile(`$src, [ref]`$null, [ref]`$null)`nif (`$SelfTest) { }`n"
    [IO.File]::WriteAllText($txGate, $txBody, $utf8)
    $kTx1 = Get-TcGateInputKey -Repo $sb -GateFile $txGate -GateArg '-SelfTest' -RunnerFiles @($runner)
    $txFiles = @($kTx1.Files | ForEach-Object { [IO.Path]::GetFileName([string]$_) })
    T 'CLEAN TWIN  a gate that TEXT-declares a file it parses is keyable, hashes that file, and does not walk into what the file loads' `
      ($kTx1.Ok -and ($txFiles -contains 'big-entry.ps1') -and -not ($txFiles -contains 'big-dep.ps1')) ("ok={0} why={1} files={2}" -f $kTx1.Ok, $kTx1.Why, ($txFiles -join ','))
    [IO.File]::WriteAllText($txBig, ". (Join-Path `$PSScriptRoot 'big-dep.ps1')`n`$x = Join-Path `$PSScriptRoot 'gone-by-now.ps1'`n# edited`n", $utf8)
    $kTx2 = Get-TcGateInputKey -Repo $sb -GateFile $txGate -GateArg '-SelfTest' -RunnerFiles @($runner)
    T 'MUST FIRE  editing a TEXT-ONLY input moves the key, so reading it as text shortens nothing about its own bytes' `
      ($kTx2.Ok -and $kTx2.Key -ne $kTx1.Key) ("ok={0} why={1}" -f $kTx2.Ok, $kTx2.Why)
    [IO.File]::WriteAllText($txDep, "# the library the parsed file loads, edited`n", $utf8)
    $kTx3 = Get-TcGateInputKey -Repo $sb -GateFile $txGate -GateArg '-SelfTest' -RunnerFiles @($runner)
    T 'MUST NOT FIRE  editing a file only the text input LOADS leaves the key alone - the gate never ran it, even though the gate names the text input by a literal the walk follows' `
      ($kTx3.Ok -and $kTx3.Key -eq $kTx2.Key) ("ok={0} why={1}" -f $kTx3.Ok, $kTx3.Why)
    [IO.File]::WriteAllText($txGate, ($txBody + ". (Join-Path (Split-Path -Parent `$PSScriptRoot) 'grocery\big-entry.ps1')`n"), $utf8)
    $kTxRun = Get-TcGateInputKey -Repo $sb -GateFile $txGate -GateArg '-SelfTest' -RunnerFiles @($runner)
    T 'MUST FIRE  a gate that DOT-SOURCES a file it declared as text is refused, because what that file loads would be missing from the key' `
      ((-not $kTxRun.Ok) -and $kTxRun.Why -match 'as text only') ("ok={0} why={1}" -f $kTxRun.Ok, $kTxRun.Why)
    [IO.File]::WriteAllText($lib, ". (Join-Path `$repo 'lib\deeper.ps1')`n& (Join-Path `$repo 'grocery\big-entry.ps1')`n", $utf8)
    [IO.File]::WriteAllText($txGate, $txBody, $utf8)
    $kTxSub = Get-TcGateInputKey -Repo $sb -GateFile $txGate -GateArg '-SelfTest' -RunnerFiles @($runner)
    T 'MUST FIRE  a gate is refused when a library in its walk RUNS the text-declared file with &, so a load one hop down still counts' `
      ((-not $kTxSub.Ok) -and $kTxSub.Why -match 'a file it loads') ("ok={0} why={1}" -f $kTxSub.Ok, $kTxSub.Why)
    [IO.File]::WriteAllText($lib, ". (Join-Path `$repo 'lib\deeper.ps1')`n", $utf8)
    [IO.File]::WriteAllText($txGate, ($txBody -replace 'big-entry\.ps1', 'big-typo.ps1'), $utf8)
    $kTxNone = Get-TcGateInputKey -Repo $sb -GateFile $txGate -GateArg '-SelfTest' -RunnerFiles @($runner)
    T 'MUST FIRE  a text-only pattern matching NO file is refused, never an empty input set' `
      ((-not $kTxNone.Ok) -and $kTxNone.Why -match 'matches no file') ("ok={0} why={1}" -f $kTxNone.Ok, $kTxNone.Why)
    [IO.File]::WriteAllText($txGate, $txBody, $utf8)
    $vTx = Test-TcGateDeclarationMoves -Repo $sb -GateFile $txGate
    T 'CLEAN TWIN  the declaration verifier probes a text-only input too, and the key moves for it' `
      ($vTx.Ok -and (@($vTx.Rows | ForEach-Object { $_.Probe }) -contains 'edit grocery\big-entry.ps1')) ("ok={0} why={1} rows={2}" -f $vTx.Ok, $vTx.Why, (@($vTx.Rows | ForEach-Object { $_.Probe }) -join '; '))
    # A LIBRARY'S text-only inputs reach its CALLERS' keys as text: the founding case is lib\checkout-sync.ps1 under a
    # gate that declares lib\*.ps1, whose key walked capture-run.ps1's whole closure through that library.
    $txLib = Join-Path $sb 'lib\parses-big-lib.ps1'
    [IO.File]::WriteAllText($txLib, "# gate-inputs-text: grocery\big-entry.ps1`n`$src = Join-Path (Split-Path -Parent `$PSScriptRoot) 'grocery\big-entry.ps1'`n", $utf8)
    $txCaller = Join-Path $sb 'ops\calls-parser-lib.ps1'
    [IO.File]::WriteAllText($txCaller, "# gate-inputs: lib\parses-big-lib.ps1`nif (`$SelfTest) { }`n", $utf8)
    $kTc1 = Get-TcGateInputKey -Repo $sb -GateFile $txCaller -GateArg '-SelfTest' -RunnerFiles @($runner)
    [IO.File]::WriteAllText($txBig, ". (Join-Path `$PSScriptRoot 'big-dep.ps1')`n`$x = Join-Path `$PSScriptRoot 'gone-by-now.ps1'`n# edited again`n", $utf8)
    $kTc2 = Get-TcGateInputKey -Repo $sb -GateFile $txCaller -GateArg '-SelfTest' -RunnerFiles @($runner)
    T 'MUST FIRE  a file a LOADED LIBRARY declares as text is in its caller''s key: editing it moves the caller''s key' `
      ($kTc1.Ok -and $kTc2.Ok -and $kTc1.Key -ne $kTc2.Key) ("ok1={0} ok2={1} why={2}" -f $kTc1.Ok, $kTc2.Ok, $kTc1.Why)
    [IO.File]::WriteAllText($txDep, "# the library the parsed file loads, edited for the caller case`n", $utf8)
    $kTc3 = Get-TcGateInputKey -Repo $sb -GateFile $txCaller -GateArg '-SelfTest' -RunnerFiles @($runner)
    T 'MUST NOT FIRE  and the caller does not walk into it either: a file only that text input loads leaves the caller''s key alone' `
      ($kTc3.Ok -and $kTc3.Key -eq $kTc2.Key) ("ok={0} why={1}" -f $kTc3.Ok, $kTc3.Why)
    $txRunner = Join-Path $sb 'lib\a-runs-big.ps1'
    [IO.File]::WriteAllText($txRunner, ". (Join-Path (Split-Path -Parent `$PSScriptRoot) 'grocery\big-entry.ps1')`n", $utf8)
    [IO.File]::WriteAllText($txCaller, "# gate-inputs: lib\parses-big-lib.ps1, lib\a-runs-big.ps1`nif (`$SelfTest) { }`n", $utf8)
    $kTc4 = Get-TcGateInputKey -Repo $sb -GateFile $txCaller -GateArg '-SelfTest' -RunnerFiles @($runner)
    [IO.File]::WriteAllText($txDep, "# the library the parsed file loads, edited once the file is RUN in this walk`n", $utf8)
    $kTc5 = Get-TcGateInputKey -Repo $sb -GateFile $txCaller -GateArg '-SelfTest' -RunnerFiles @($runner)
    T 'MUST FIRE  when ANOTHER file in the walk dot-sources what a library declared as text, even one read BEFORE that library declared it, the file is walked as code: what it loads moves the key' `
      ($kTc4.Ok -and $kTc5.Ok -and $kTc4.Key -ne $kTc5.Key) ("ok4={0} ok5={1} why={2}" -f $kTc4.Ok, $kTc5.Ok, $kTc4.Why)
    Remove-Item -LiteralPath $txRunner -Force
    $leafFire = @(
      ". (Join-Path `$PSScriptRoot 'zz-leaf-probe.ps1')",
      "& (Join-Path `$root 'grocery\zz-leaf-probe.ps1') -Kind daily",
      "powershell -NoProfile -File (Join-Path `$repo 'grocery/zz-leaf-probe.ps1')"
    )
    $leafQuiet = @(
      "Push-Up `$E 'grocery/zz-leaf-probe.ps1' 'body' 'msg'",
      "`$list = @('grocery/zz-leaf-probe.ps1', 'grocery/alert-lib.ps1')",
      "`$src = Join-Path `$repo 'grocery\zz-leaf-probe.ps1'",
      ". (Join-Path `$PSScriptRoot 'zz-leaf-probe-lock-lib.ps1')"
    )
    T 'MUST FIRE  the load rule sees a dot-source, an & call and a -File launch of the file by name' `
      (@($leafFire | Where-Object { -not (Test-TcGateLoadsLeaf -Code $_ -Leaf 'zz-leaf-probe.ps1') }).Count -eq 0) (@($leafFire | Where-Object { -not (Test-TcGateLoadsLeaf -Code $_ -Leaf 'zz-leaf-probe.ps1') }) -join ' | ')
    T 'MUST NOT FIRE  the load rule is silent on the file named in a string, a list, a plain Join-Path read, and a file whose name only BEGINS the same' `
      (@($leafQuiet | Where-Object { Test-TcGateLoadsLeaf -Code $_ -Leaf 'zz-leaf-probe.ps1' }).Count -eq 0) (@($leafQuiet | Where-Object { Test-TcGateLoadsLeaf -Code $_ -Leaf 'zz-leaf-probe.ps1' }) -join ' | ')

    # ---- A DATA GLOB IN A WALKED FILE, UNDER A DECLARATION (2026-09-24) ----
    # The founding shape: grocery\capture-run.ps1 names 'meal-prep\db\recipes\*.json', and every declared gate whose walk
    # reached it hashed every spec. A data LITERAL there was already left out; the glob was not.
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $sb 'meal-prep\db\recipes')
    [IO.File]::WriteAllText((Join-Path $sb 'meal-prep\db\recipes\a.json'), '{}', $utf8)
    $dgLib = Join-Path $sb 'grocery\globs-data-lib.ps1'
    [IO.File]::WriteAllText($dgLib, "`$repo = Split-Path -Parent `$PSScriptRoot`n`$specs = Get-ChildItem (Join-Path `$repo 'meal-prep\db\recipes\*.json')`n", $utf8)
    $dgGate = Join-Path $sb 'ops\declares-data-lib.ps1'
    [IO.File]::WriteAllText($dgGate, "# gate-inputs: grocery\globs-data-lib.ps1`nif (`$SelfTest) { }`n", $utf8)
    $kDg1 = Get-TcGateInputKey -Repo $sb -GateFile $dgGate -GateArg '-SelfTest' -RunnerFiles @($runner)
    [IO.File]::WriteAllText((Join-Path $sb 'meal-prep\db\recipes\a.json'), '{"edited":1}', $utf8)
    [IO.File]::WriteAllText((Join-Path $sb 'meal-prep\db\recipes\b.json'), '{}', $utf8)
    $kDg2 = Get-TcGateInputKey -Repo $sb -GateFile $dgGate -GateArg '-SelfTest' -RunnerFiles @($runner)
    $dgFiles = @($kDg2.Files | ForEach-Object { [string]$_ } | Where-Object { $_ -match 'recipes' })
    T 'MUST NOT FIRE  a data glob in a LIBRARY a declared gate walks is not hashed: editing and adding a spec under it leaves the key alone, as a data literal there already did' `
      ($kDg1.Ok -and $kDg2.Ok -and $kDg1.Key -eq $kDg2.Key -and $dgFiles.Count -eq 0) ("ok1={0} ok2={1} why={2} data-files={3}" -f $kDg1.Ok, $kDg2.Ok, $kDg1.Why, ($dgFiles -join ','))
    [IO.File]::WriteAllText($dgLib, "`$repo = Split-Path -Parent `$PSScriptRoot`n`$specs = Get-ChildItem (Join-Path `$repo 'meal-prep\db\recipes\*.json')`n# edited`n", $utf8)
    $kDg3 = Get-TcGateInputKey -Repo $sb -GateFile $dgGate -GateArg '-SelfTest' -RunnerFiles @($runner)
    T 'MUST FIRE  the library that names the data glob is still an input: editing it moves the key' `
      ($kDg3.Ok -and $kDg3.Key -ne $kDg2.Key) ("ok={0} why={1}" -f $kDg3.Ok, $kDg3.Why)
    $vDg = Test-TcGateDeclarationMoves -Repo $sb -GateFile $dgGate
    T 'MUST FIRE  the declaration verifier still moves the key for every declared input of that gate' `
      ($vDg.Ok) ("ok={0} why={1}" -f $vDg.Ok, $vDg.Why)
    $dgOwn = Join-Path $sb 'ops\own-data-glob.ps1'
    [IO.File]::WriteAllText($dgOwn, "# gate-inputs: grocery\globs-data-lib.ps1`n`$repo = Split-Path -Parent `$PSScriptRoot`n`$b = Get-ChildItem (Join-Path `$repo 'meal-prep\db\recipes\*.json')`nif (`$SelfTest) { }`n", $utf8)
    $kDo1 = Get-TcGateInputKey -Repo $sb -GateFile $dgOwn -GateArg '-SelfTest' -RunnerFiles @($runner)
    [IO.File]::WriteAllText((Join-Path $sb 'meal-prep\db\recipes\c.json'), '{}', $utf8)
    $kDo2 = Get-TcGateInputKey -Repo $sb -GateFile $dgOwn -GateArg '-SelfTest' -RunnerFiles @($runner)
    [IO.File]::WriteAllText((Join-Path $sb 'meal-prep\db\recipes\c.json'), '{"edited":1}', $utf8)
    $kDo3 = Get-TcGateInputKey -Repo $sb -GateFile $dgOwn -GateArg '-SelfTest' -RunnerFiles @($runner)
    T 'MUST FIRE  the GATE''S OWN data glob is still hashed under a declaration: a new spec and an edited spec each move its key (hunt-run''s -Init fixture lists the real boards)' `
      ($kDo1.Ok -and $kDo2.Ok -and $kDo3.Ok -and $kDo1.Key -ne $kDo2.Key -and $kDo2.Key -ne $kDo3.Key) ("ok={0}/{1}/{2} why={3}" -f $kDo1.Ok, $kDo2.Ok, $kDo3.Ok, $kDo1.Why)
    $dgStrict = Join-Path $sb 'ops\loads-data-lib.ps1'
    [IO.File]::WriteAllText($dgStrict, "`$repo = Split-Path -Parent `$PSScriptRoot`n. (Join-Path `$repo 'grocery\globs-data-lib.ps1')`nif (`$SelfTest) { }`n", $utf8)
    $kDs = Get-TcGateInputKey -Repo $sb -GateFile $dgStrict -GateArg '-SelfTest' -RunnerFiles @($runner)
    T 'MUST FIRE  with NO declaration the same library still refuses its caller as a data reader, so the inference is not weakened' `
      ((-not $kDs.Ok) -and $kDs.Why -match 'data directory') ("ok={0} why={1}" -f $kDs.Ok, $kDs.Why)

    # ---- A FILE A LIBRARY ONLY WRITES (gate-output:, 2026-09-24) ----
    # The founding shape: lib\event-bus.ps1 names ops\out\events.jsonl, so every event this checkout recorded moved the
    # key of every gate that loads the bus, 20 of them, though most only append to it.
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $sb 'ops\out')
    $busRel = 'ops\out\zz-bus.jsonl'
    $busFull = Join-Path $sb $busRel
    if (Test-Path -LiteralPath $busFull) { Remove-Item -LiteralPath $busFull -Force }
    $busLibBody = "# gate-inputs: lib\zz-bus-lib.ps1`n# gate-output: ops\out\zz-bus.jsonl read-by Read-ZzBus, Get-ZzBusPath`n`$repo = Split-Path -Parent `$PSScriptRoot`nfunction Get-ZzBusPath { Join-Path `$repo 'ops\out\zz-bus.jsonl' }`nfunction Write-ZzBus([string]`$t) { Add-Content -LiteralPath (Get-ZzBusPath) -Value `$t }`nfunction Read-ZzBus { Get-Content -LiteralPath (Get-ZzBusPath) }`n"
    $busLib = Join-Path $sb 'lib\zz-bus-lib.ps1'
    [IO.File]::WriteAllText($busLib, $busLibBody, $utf8)
    $busW = Join-Path $sb 'ops\writes-bus.ps1'
    [IO.File]::WriteAllText($busW, "# gate-inputs: lib\zz-bus-lib.ps1`n# Read-ZzBus is named only in this comment, which cannot read anything`nWrite-ZzBus 'x'`nif (`$SelfTest) { }`n", $utf8)
    $kBw1 = Get-TcGateInputKey -Repo $sb -GateFile $busW -GateArg '-SelfTest' -RunnerFiles @($runner)
    [IO.File]::WriteAllText($busFull, "{}`n", $utf8)
    $kBw2 = Get-TcGateInputKey -Repo $sb -GateFile $busW -GateArg '-SelfTest' -RunnerFiles @($runner)
    [IO.File]::AppendAllText($busFull, "{`"t`":1}`n", $utf8)
    $kBw3 = Get-TcGateInputKey -Repo $sb -GateFile $busW -GateArg '-SelfTest' -RunnerFiles @($runner)
    $bwFiles = @($kBw3.Files | ForEach-Object { [string]$_ } | Where-Object { $_ -match 'zz-bus\.jsonl' })
    T 'MUST NOT FIRE  a gate that only WRITES through a library''s declared output keeps it out: the file appearing and an append each leave the key alone (a comment naming a reader reads nothing)' `
      ($kBw1.Ok -and $kBw2.Ok -and $kBw3.Ok -and $kBw1.Key -eq $kBw2.Key -and $kBw2.Key -eq $kBw3.Key -and $bwFiles.Count -eq 0) ("ok={0}/{1}/{2} why={3} bus-in-key={4}" -f $kBw1.Ok, $kBw2.Ok, $kBw3.Ok, $kBw1.Why, $bwFiles.Count)
    [IO.File]::WriteAllText($busLib, ($busLibBody + "# edited`n"), $utf8)
    $kBw4 = Get-TcGateInputKey -Repo $sb -GateFile $busW -GateArg '-SelfTest' -RunnerFiles @($runner)
    T 'MUST FIRE  the library that declares the output is still an input: editing it moves the writer''s key' `
      ($kBw4.Ok -and $kBw4.Key -ne $kBw3.Key) ("ok={0} why={1}" -f $kBw4.Ok, $kBw4.Why)
    [IO.File]::WriteAllText($busLib, $busLibBody, $utf8)
    $vBw = Test-TcGateDeclarationMoves -Repo $sb -GateFile $busW
    T 'MUST FIRE  the declaration verifier still moves the writer''s key for its declared library' ($vBw.Ok) ("ok={0} why={1}" -f $vBw.Ok, $vBw.Why)
    $busReaders = @(
      @('the gate calls a read-by function', "# gate-inputs: lib\zz-bus-lib.ps1`n`$e = Read-ZzBus`nif (`$SelfTest) { }`n", ''),
      @('the gate asks for the path through a read-by function', "# gate-inputs: lib\zz-bus-lib.ps1`n`$p = Get-ZzBusPath`nif (`$SelfTest) { }`n", ''),
      @('the gate names the file itself', "# gate-inputs: lib\zz-bus-lib.ps1`n`$raw = [IO.File]::ReadAllText('zz-bus.jsonl')`nif (`$SelfTest) { }`n", ''),
      @('ANOTHER library the gate loads calls the reader', "# gate-inputs: lib\zz-bus-lib.ps1, lib\zz-bus-reader.ps1`nif (`$SelfTest) { }`n", "`$seen = Read-ZzBus`n")
    )
    $busRdr = Join-Path $sb 'lib\zz-bus-reader.ps1'
    foreach ($br in $busReaders) {
      $bg = Join-Path $sb 'ops\reads-bus.ps1'
      [IO.File]::WriteAllText($bg, $br[1], $utf8)
      if ($br[2]) { [IO.File]::WriteAllText($busRdr, $br[2], $utf8) }
      if (Test-Path -LiteralPath $busFull) { Remove-Item -LiteralPath $busFull -Force }
      $kR0 = Get-TcGateInputKey -Repo $sb -GateFile $bg -GateArg '-SelfTest' -RunnerFiles @($runner)
      [IO.File]::WriteAllText($busFull, "{}`n", $utf8)
      $kR1 = Get-TcGateInputKey -Repo $sb -GateFile $bg -GateArg '-SelfTest' -RunnerFiles @($runner)
      [IO.File]::AppendAllText($busFull, "{`"t`":2}`n", $utf8)
      $kR2 = Get-TcGateInputKey -Repo $sb -GateFile $bg -GateArg '-SelfTest' -RunnerFiles @($runner)
      T ('MUST FIRE  the output comes back into the key when ' + $br[0] + ': the file appearing and an append each move it') `
        ($kR0.Ok -and $kR1.Ok -and $kR2.Ok -and $kR0.Key -ne $kR1.Key -and $kR1.Key -ne $kR2.Key) ("ok={0}/{1}/{2} why={3}" -f $kR0.Ok, $kR1.Ok, $kR2.Ok, $kR0.Why)
    }
    Remove-Item -LiteralPath $busRdr -Force -ErrorAction SilentlyContinue
    $busBad = @(
      @('names no read-by list', "# gate-output: ops\out\zz-bus.jsonl`n", 'is not ''<path> read-by'),
      @('has a read-by list holding no function name', "# gate-output: ops\out\zz-bus.jsonl read-by 42`n", 'names no reader function'),
      @('names code', "# gate-output: lib\zz-other.ps1 read-by Read-ZzBus`n", 'never code'),
      @('names a glob', "# gate-output: ops\out\*.jsonl read-by Read-ZzBus`n", 'never code, a glob')
    )
    foreach ($bb in $busBad) {
      [IO.File]::WriteAllText($busLib, ($busLibBody -replace '(?m)^# gate-output:.*\n', $bb[1]), $utf8)
      $kBb = Get-TcGateInputKey -Repo $sb -GateFile $busW -GateArg '-SelfTest' -RunnerFiles @($runner)
      T ('MUST FIRE  a gate-output line that ' + $bb[0] + ' refuses the caller for that reason, rather than dropping a file on an assertion nobody could check') `
        ((-not $kBb.Ok) -and $kBb.Why -match 'gate-output' -and $kBb.Why -match $bb[2]) ("ok={0} why={1}" -f $kBb.Ok, $kBb.Why)
    }
    [IO.File]::WriteAllText($busLib, $busLibBody, $utf8)

    # ---- THE FOUNDING REPLAY, from FROZEN BLOBS (never regenerated). grocery\capture-watchdog.ps1 at 1ec218d5f..f936a4b31
    # was one blob; capture-run.ps1 was adafac8e1070 at 1ec218d5f and cbb188c3e749 at 0da71cba5, where the bare
    # `$failed +=` that turned the watchdog red arrived. The old key was bbba10ec... over both. The new one must differ,
    # or refuse. A blob is read by its id and its id is re-derived from its bytes, so the fixture cannot drift.
    $realRepo = Split-Path -Parent $PSScriptRoot
    $blobs = @{ wd = '2e195d34fbedba9e24457fca5fea0fd8d4dedfa4'; crA = 'adafac8e10705d25342851ed7a18fd0b545bd866'; crB = 'cbb188c3e749b4cfd5d1c1f81ea260e6c8974ae8' }
    $got = @{}
    foreach ($bk in @($blobs.Keys)) {
      $psi = New-Object Diagnostics.ProcessStartInfo 'git'
      $psi.Arguments = '-C "' + $realRepo + '" cat-file blob ' + $blobs[$bk]
      $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
      $gp = [Diagnostics.Process]::Start($psi)
      $ms = New-Object IO.MemoryStream
      $gp.StandardOutput.BaseStream.CopyTo($ms)
      $null = $gp.StandardError.ReadToEnd(); $gp.WaitForExit()
      $bytes = $ms.ToArray()
      $hdr = [Text.Encoding]::ASCII.GetBytes('blob ' + $bytes.Length + [char]0)
      $sha1 = [Security.Cryptography.SHA1]::Create()
      $id = ([BitConverter]::ToString($sha1.ComputeHash([byte[]]($hdr + $bytes))) -replace '-', '').ToLowerInvariant()
      $sha1.Dispose()
      if ($gp.ExitCode -ne 0 -or $id -ne $blobs[$bk]) { throw ('frozen blob ' + $blobs[$bk] + ' could not be read back byte for byte (git exit ' + $gp.ExitCode + ', id ' + $id + ')') }
      $got[$bk] = $bytes
    }
    $rp = Join-Path $sb 'replay'
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $rp 'grocery')
    $rpWd = Join-Path $rp 'grocery\capture-watchdog.ps1'
    $rpCr = Join-Path $rp 'grocery\capture-run.ps1'
    [IO.File]::WriteAllBytes($rpWd, $got['wd'])
    [IO.File]::WriteAllBytes($rpCr, $got['crA'])
    $kWdA = Get-TcGateInputKey -Repo $rp -GateFile $rpWd -GateArg '-SelfTest' -RunnerFiles @($runner)
    [IO.File]::WriteAllBytes($rpCr, $got['crB'])
    $kWdB = Get-TcGateInputKey -Repo $rp -GateFile $rpWd -GateArg '-SelfTest' -RunnerFiles @($runner)
    T 'MUST FIRE  REPLAY: the real watchdog blob over the real capture-run change is refused or keyed differently - never the one key that replayed a 19:06 pass on five pushes' `
      (((-not $kWdA.Ok) -and (-not $kWdB.Ok)) -or ($kWdA.Ok -and $kWdB.Ok -and $kWdA.Key -ne $kWdB.Key)) ("okA={0} okB={1} whyA={2}" -f $kWdA.Ok, $kWdB.Ok, $kWdA.Why)
    $wdRefs = Resolve-TcGateFileRefs -Repo $rp -FileRel 'grocery\capture-watchdog.ps1' -GateRel 'grocery\capture-watchdog.ps1' -Text ([Text.Encoding]::UTF8.GetString($got['wd']))
    T 'MUST FIRE  REPLAY: the key now SEES the file the failing case reads - grocery\capture-run.ps1 is among the watchdog''s resolved inputs, where the old resolution looked for it at the root' `
      (@($wdRefs.Paths) -contains 'grocery\capture-run.ps1') (@($wdRefs.Paths) -join ', ')
    T 'MUST FIRE  REPLAY: the watchdog is refused for a named reason the rules give (data, a missing input or an unparsed spelling), not for a missing gate file' `
      ((-not $kWdA.Ok) -and $kWdA.Why -match 'data directory|exists nowhere|does not parse') ("why={0}" -f $kWdA.Why)

    # ---- the stored entry ----
    $now = [DateTime]::UtcNow
    T 'CLEAN TWIN a stored pass over the same key, inside the backstop, is a hit' `
      ((Test-TcGateCacheHit -Line ($k1.Key + ' 0 ' + $now.AddMinutes(-5).ToString('o')) -Key $k1.Key -NowUtc $now).Hit) 'a fresh identical pass missed'
    T 'MUST FIRE  a stored entry for DIFFERENT inputs is a miss, and says so' `
      (-not (Test-TcGateCacheHit -Line ('deadbeef 0 ' + $now.ToString('o')) -Key $k1.Key -NowUtc $now).Hit) 'a different key was reused'
    T 'MUST FIRE  a recorded FAILURE is never reused - a red gate runs again every time' `
      (-not (Test-TcGateCacheHit -Line ($k1.Key + ' 1 ' + $now.ToString('o')) -Key $k1.Key -NowUtc $now).Hit) 'a red result was reused'
    T 'MUST FIRE  an entry older than the backstop is a miss' `
      (-not (Test-TcGateCacheHit -Line ($k1.Key + ' 0 ' + $now.AddHours(-1000).ToString('o')) -Key $k1.Key -NowUtc $now).Hit) 'an ancient entry was reused'
    T 'MUST FIRE  a truncated entry is a miss, never a pass' `
      (-not (Test-TcGateCacheHit -Line ($k1.Key + ' 0') -Key $k1.Key -NowUtc $now).Hit) 'a half-written entry was reused'
    T 'MUST NOT FIRE  no entry at all is simply a miss with a reason' `
      ((-not (Test-TcGateCacheHit -Line '' -Key $k1.Key -NowUtc $now).Hit) -and (Test-TcGateCacheHit -Line '' -Key $k1.Key -NowUtc $now).Why -eq 'no entry') 'an empty entry did not say why'
    # THE VERDICT TRAVELS WITH THE ENTRY. run-gates scores a self-test that exits 0 without naming its own
    # verdict as a 3, so an entry that cannot replay the gate's last line is not a usable answer - measured
    # the first time this ran, when 182 reused gates all scored could-not-evaluate.
    $stored = $k1.Key + ' 0 ' + $now.ToString('o') + ' SELF-TEST PASS: 14 cases - the founding bug and its twin'
    T 'CLEAN TWIN the gate''s own last line comes back with the entry, whitespace and all' `
      ((Get-TcGateCachedVerdict -Line $stored) -eq 'SELF-TEST PASS: 14 cases - the founding bug and its twin') (Get-TcGateCachedVerdict -Line $stored)
    T 'MUST FIRE  an entry with no verdict line yields nothing, so the caller runs the gate rather than replaying silence' `
      ((Get-TcGateCachedVerdict -Line ($k1.Key + ' 0 ' + $now.ToString('o'))) -eq '') 'invented a verdict from an entry that had none'
    # ---- A NON-POWERSHELL GATE KEYS ONLY ON WHAT IT DECLARES (2026-09-12) ----
    $pyGate = Join-Path $sb 'ops\suite_thing.py'
    $pyHelper = Join-Path $sb 'ops\helper_lib.py'
    [IO.File]::WriteAllText($pyHelper, "VALUE = 1`n", $utf8)
    [IO.File]::WriteAllText($pyGate, "import helper_lib`nif '--selftest' in __import__('sys').argv: pass`n", $utf8)
    $kPyBare = Get-TcGateInputKey -Repo $sb -GateFile $pyGate -GateArg '--selftest' -RunnerFiles @($runner)
    T 'MUST FIRE  a Python suite with no declaration is refused, because the inference cannot see an import' `
      ((-not $kPyBare.Ok) -and $kPyBare.Why -match 'not PowerShell') ("ok={0} why={1}" -f $kPyBare.Ok, $kPyBare.Why)
    [IO.File]::WriteAllText($pyGate, "# gate-inputs: ops\helper_lib.py`nimport helper_lib`nif '--selftest' in __import__('sys').argv: pass`n", $utf8)
    $kPyDecl = Get-TcGateInputKey -Repo $sb -GateFile $pyGate -GateArg '--selftest' -RunnerFiles @($runner)
    T 'CLEAN TWIN  the same Python suite is keyable once it declares what it imports' ($kPyDecl.Ok) ("ok={0} why={1}" -f $kPyDecl.Ok, $kPyDecl.Why)
    [IO.File]::WriteAllText($pyHelper, "VALUE = 2`n", $utf8)
    $kPyEdit = Get-TcGateInputKey -Repo $sb -GateFile $pyGate -GateArg '--selftest' -RunnerFiles @($runner)
    T 'MUST FIRE  editing the module a Python suite imports moves its key, so an import is never a stale pass' `
      ($kPyEdit.Ok -and $kPyEdit.Key -ne $kPyDecl.Key) 'editing an imported module left the key unchanged'

    # ---- ONE ENTRY PER GATE AND CONTENT, SHARED BY EVERY CHECKOUT (2026-09-12) ----
    # The founding defect, end to end rather than through the id function alone: two byte-identical checkouts at two
    # different paths. Before the fix they computed the same key and wrote two different cache files.
    $twinGate = Join-Path $sb 'ops\audit-twin.ps1'
    [IO.File]::WriteAllText($twinGate, "# a gate with nothing to read`nif (`$SelfTest) { }`n", $utf8)
    $sb2 = $sb + '-twin'
    Copy-Item -LiteralPath $sb -Destination $sb2 -Recurse -Force
    try {
      $twinGate2 = Join-Path $sb2 'ops\audit-twin.ps1'
      $kTwinA = Get-TcGateInputKey -Repo $sb -GateFile $twinGate -GateArg '-SelfTest' -RunnerFiles @($runner)
      $kTwinB = Get-TcGateInputKey -Repo $sb2 -GateFile $twinGate2 -GateArg '-SelfTest' -RunnerFiles @((Join-Path $sb2 'ops\run-gates.ps1'))
      $cA = Get-TcGateCachePath -CacheDir 'C:\c' -GateId (Get-TcGateCacheId -Repo $sb -GateFile $twinGate -GateArg '-SelfTest' -Key $kTwinA.Key)
      $cB = Get-TcGateCachePath -CacheDir 'C:\c' -GateId (Get-TcGateCacheId -Repo $sb2 -GateFile $twinGate2 -GateArg '-SelfTest' -Key $kTwinB.Key)
      T 'MUST FIRE  byte-identical checkouts at two different paths compute one key AND land on one cache file' `
        ($kTwinA.Ok -and $kTwinB.Ok -and $kTwinA.Key -eq $kTwinB.Key -and $cA -eq $cB) ("okA={0} okB={1} sameKey={2} sameFile={3}" -f $kTwinA.Ok, $kTwinB.Ok, ($kTwinA.Key -eq $kTwinB.Key), ($cA -eq $cB))
    } finally {
      Remove-Item -LiteralPath $sb2 -Recurse -Force -ErrorAction SilentlyContinue
    }
    $idA = Get-TcGateCacheId -Repo 'C:\box\main' -GateFile 'C:\box\main\ops\audit-thing.ps1' -GateArg '-SelfTest' -Key 'k1'
    $idC = Get-TcGateCacheId -Repo 'C:\box\main' -GateFile 'C:\box\main\ops\audit-thing.ps1' -GateArg '-SelfTest' -Key 'k2'
    T 'MUST FIRE  different inputs are a different entry, so checkouts at two commits never evict each other' ($idA -ne $idC) "$idA / $idC"
    $idD = Get-TcGateCacheId -Repo 'C:\Box\Main' -GateFile 'c:\box\main\OPS/audit-thing.ps1' -GateArg '-SelfTest' -Key 'k1'
    T 'MUST NOT FIRE  case and separator spelling do not split one gate into two entries' ($idA -eq $idD) "$idA / $idD"

    # ---- PRUNING, which is only safe because it agrees with the hit rule ----
    $pc = Join-Path $sb 'cache'
    $null = New-Item -ItemType Directory -Force -Path $pc
    $oldE = Join-Path $pc 'old.pass'; $freshE = Join-Path $pc 'fresh.pass'; $notMine = Join-Path $pc 'readme.txt'
    foreach ($x in @($oldE, $freshE, $notMine)) { [IO.File]::WriteAllText($x, 'x', $utf8) }
    $nowP = [DateTime]::UtcNow
    $pastBackstop = $nowP.AddHours(-($script:TcGateKeyMaxAgeHours + 1))
    [IO.File]::SetLastWriteTimeUtc($oldE, $pastBackstop)
    [IO.File]::SetLastWriteTimeUtc($notMine, $pastBackstop)
    $gone = Remove-TcGateStaleEntries -CacheDir $pc -NowUtc $nowP
    T 'MUST FIRE  an entry past the backstop is removed, because it can never be a hit again' `
      ((-not (Test-Path -LiteralPath $oldE)) -and $gone -eq 1) ("removed={0} oldStillThere={1}" -f $gone, (Test-Path -LiteralPath $oldE))
    T 'CLEAN TWIN  an entry inside the backstop is still there to be reused' (Test-Path -LiteralPath $freshE) 'a fresh entry was pruned'
    T 'CLEAN TWIN  a file that is not a cache entry is kept, however old it is' (Test-Path -LiteralPath $notMine) 'pruning removed a file it does not own'
    $staleLine = 'kX 0 ' + $pastBackstop.ToString('o') + ' SELF-TEST PASS: x'
    T 'MUST NOT FIRE  an entry old enough to prune is one the hit rule already refuses, so pruning changes no answer' `
      (-not (Test-TcGateCacheHit -Line $staleLine -Key 'kX' -NowUtc $nowP).Hit) 'an entry past the backstop still read as a hit'

    $p1 = Get-TcGateCachePath -CacheDir 'C:\c' -GateId 'ops\a.ps1|-SelfTest'
    $p2 = Get-TcGateCachePath -CacheDir 'C:\c' -GateId 'ops\a.ps1|-Other'
    T 'MUST FIRE  two arguments of one file are two cache entries, never one' ($p1 -ne $p2) "$p1 / $p2"
  } catch {
    $script:f++
    Write-Output ('FAIL  the self-test threw: ' + $_.Exception.Message)
  } finally {
    Remove-Item -LiteralPath $sb -Recurse -Force -ErrorAction SilentlyContinue
  }
  # A SUITE CAN RUN ZERO CASES AND EXIT 0, so the count is asserted.
  if ($cases -lt 96) { $f++; Write-Output ("FAIL  only {0} of 96 cases ran" -f $cases) }
  if ($f) { Write-Output ("gate-input-key SELF-TEST FAIL: {0} of {1} case(s)" -f $f, $cases); exit 1 }
  Write-Output ("gate-input-key SELF-TEST PASS: {0} cases - led by every input moving the key one at a time, including two hops down a library graph, and by the three refusals that keep a stale pass impossible" -f $cases)
  exit 0
}
