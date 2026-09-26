# probe-staged-corpus.ps1 - run an UNCHANGED detector over the real tracked .ps1 and over a STAGED copy of
# them in which every comment and every string-literal body is blanked, and pair the findings site by site.
# ---------------------------------------------------------------------------------------------------------
# THE TECHNIQUE (2026-09-18, backlog I156). nand2tetris project 10 ships two versions of every test program:
# the real one, and an "expressionless" one mechanically derived from it that is semantically nonsense and
# SYNTACTICALLY VALID. This estate's fixtures are the opposite shape - hand-written MUST FIRE / MUST NOT FIRE /
# CLEAN TWIN literals, small by construction, assembled from bugs somebody already found. A staged corpus is
# manufactured FROM the real files instead, so it keeps their whole size, shape and awkwardness and flattens
# exactly one dimension. Here the dimension is prose and literal text: a finding that survives the flattening
# was STRUCTURAL; a finding that vanishes was living in a comment or inside a string. That is a DIFFERENTIAL
# ORACLE OVER TWO VERSIONS OF THE INPUT, rather than two versions of the program, and it needs no new gate.
#
# WHAT A VANISHED FINDING MEANS DEPENDS ON THE DETECTOR, and this probe does not decide it. For a detector
# whose defect is a CALL SHAPE, a finding that lived in a comment is noise. For audit-write-seam the defect
# is a URI, and a URI is a string, so a finding that vanishes here is usually the real thing and the
# probe's answer is "this detector must keep reading literals". The row records WHERE the text lived
# (comment, string, or both, by the tokens on that line); the reading is the person's.
#
# THE STAGED FILE IS PROVED VALID, NOT ASSUMED VALID. Every staged file is re-tokenized and its non-comment
# token stream must equal the original's in type, offset and length, with every non-string token's content
# identical. Comments and string bodies are blanked (to spaces, a quoted body filled with a number in digits, see
# ConvertTo-TcStagedSource) with every line break kept, so a staged file
# has the same length and the same line numbers as its original and a finding's file:line pairs across the
# two arms without any mapping. A file PSParser refuses is staged in NEITHER arm and counted as unstageable,
# because a pair with only one side is not a pair.
#
# WHY THIS IS NOT A FOURTH SOURCE REDUCER (Brad's ruling on backlog I154, recorded in lib\ps-source.ps1's
# header). That ruling binds the next rewrite of the three reducers detectors MATCH AGAINST to consolidate
# them into one lib\ reducer that blanks string contents behind a switch. This file is not one of them and
# does not rewrite one: it writes a corpus to disk for an unmodified detector to read, and its contract is
# stricter than any reducer's (same length, same line breaks, re-tokenized and proved). When that
# consolidation is done, ConvertTo-TcStagedSource's string half is a candidate to move into it, and this
# file should then call the lib rather than keep its own copy.
#
# IT IS A PROBE, NOT A GATE, and uncalled on purpose. A differential over one detector answers a question
# about that detector once; re-run it when the detector's matching changes. Its -SelfTest is the gate half:
# it proves the stager keeps a file valid, proves the validity check can go red, and runs the real
# audit-write-seam over a staged fixture tree to show its structural MUST FIRE fires identically in both arms.
#
# SCOPE OF A CLEAN REPORT: a staged arm with zero structure mismatches is SOUND for "these files still
# tokenize to the same code", because PowerShell's own lexer decides both sides. The survived/vanished split
# is only as good as the detector under test and says nothing about findings neither arm produced.
#
#   ops\probe-staged-corpus.ps1                          stage every tracked .ps1, run audit-write-seam on both arms
#   ops\probe-staged-corpus.ps1 -OutFile rows.jsonl      the same, plus one row per finding site per arm
#   ops\probe-staged-corpus.ps1 -KeepStage               leave the two staged trees on disk and print where
#   ops\probe-staged-corpus.ps1 -SelfTest                frozen fixtures, plus the real detector on a staged tree
# Exit 0 = ran (findings are data, not a failure). 1 = a staged file failed the structure proof, so the
# differential is void. 3 = BLIND: no files found, or a detector arm did not complete.
# Self-test: frozen fixtures, plus the real audit-write-seam.ps1 run as a child over a temp tree and a temp baseline it stages itself.
# gate-inputs: ops\probe-staged-corpus.ps1, lib\guard-contract.ps1, ops\audit-write-seam.ps1
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop (2026-09-07)
param([switch]$SelfTest, [string]$Detector = 'write-seam', [string]$Root = '', [string]$OutFile = '', [switch]$KeepStage)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\ops' }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')

# DETECTORS THIS PROBE CAN DRIVE. Each must accept -Root and -BaselineFile, print one line per finding, and
# carry its finding count on its completion marker, so the probe can check it parsed every line. Only
# audit-write-seam has all three today; audit-write-only-reports takes the same two arguments and is the
# obvious second entry.
$script:DETECTORS = @{
  'write-seam' = @{
    Path    = 'ops\audit-write-seam.ps1'
    Finding = '^\s+bypass\s+(?<file>.+):(?<line>\d+)\s*$'
    Count   = 'sites=(?<n>\d+)'
    Marker  = 'WRITE-SEAM-COMPLETE'
  }
}

function Test-TcSpanHasLineBreak {
  param([string]$Text, [int]$Start, [int]$End)
  return ($Text.IndexOfAny([char[]]@("`r", "`n"), $Start, $End - $Start) -ge 0)
}

function Test-TcSpanStandsAlone {
  # Nothing but whitespace between the span and the line break before it, and between the span and the
  # line break after it.
  param([string]$Text, [int]$Start, [int]$End)
  for ($i = $Start - 1; $i -ge 0; $i--) {
    $c = $Text[$i]
    if ($c -eq "`n" -or $c -eq "`r") { break }
    if (-not [char]::IsWhiteSpace($c)) { return $false }
  }
  for ($i = $End; $i -lt $Text.Length; $i++) {
    $c = $Text[$i]
    if ($c -eq "`n" -or $c -eq "`r") { break }
    if (-not [char]::IsWhiteSpace($c)) { return $false }
  }
  return $true
}

function ConvertTo-TcStagedSource {
  # Blank every comment and every string-literal BODY to spaces, keeping every line break and every quote
  # delimiter, so the result has the same length, the same line numbers and - proved separately by
  # Test-TcStagedStructure - the same code. Returns $null for a file PSParser refuses: there is no lexer
  # answer to stage from, and guessing would put an unproved file into one arm.
  param([string]$Text)
  if ($null -eq $Text) { return $null }
  $errs = $null
  $tokens = $null
  try { $tokens = [System.Management.Automation.PSParser]::Tokenize($Text, [ref]$errs) } catch { return $null }
  if ($null -eq $tokens) { return $null }
  if ($null -ne $errs) { $errList = @($errs); if ($errList.Count -gt 0) { return $null } }
  $chars = $Text.ToCharArray()
  $fillFor = @{}
  $nextFor = @{}
  foreach ($tk in $tokens) {
    $w = 0
    $t = [string]$tk.Type
    if ($t -ne 'Comment' -and $t -ne 'String') { continue }
    $s = [int]$tk.Start
    $e = $s + [int]$tk.Length
    # A MULTI-LINE BLOCK COMMENT WITH CODE BESIDE IT IS NOT STAGED. Blanking keeps its line breaks, and a
    # line break is a statement separator where the comment was not, so `Get-Foo <# ... #> -Bar` across
    # two lines could stage as two statements. Beside nothing but whitespace, its line breaks only add
    # blank lines, which change no statement. Refused rather than guessed, like an unparseable file.
    if ($t -eq 'Comment' -and (Test-TcSpanHasLineBreak -Text $Text -Start $s -End $e) -and -not (Test-TcSpanStandsAlone -Text $Text -Start $s -End $e)) { return $null }
    if ($t -eq 'String') {
      # Keep the delimiters: one quote each side, or two characters each side of a here-string.
      $w = 1
      if ($chars[$s] -eq '@') { $w = 2 }
      $s = $s + $w
      $e = $e - $w
    }
    for ($i = $s; $i -lt $e; $i++) {
      $c = $chars[$i]
      if ($c -ne "`r" -and $c -ne "`n") { $chars[$i] = ' ' }
    }
    # EQUAL STRINGS ARE NOT ALWAYS LEGAL, and this is the nand2tetris lesson in its sharpest form: the
    # staged program must stay VALID, and a hash literal whose keys all blank to the same spaces is a
    # parse error ("Duplicate keys"). The first staging of the real tree failed the structure proof in
    # 107 of 792 files for exactly that reason. So a quoted body is filled with a NUMBER in digits (padded
    # with spaces when it is longer): keys stay distinct and no word survives. A here-string
    # stays all spaces, because anything after its opening delimiter on that line is itself an error.
    if ($t -eq 'String' -and $w -eq 1) {
      # WHICH NUMBER, AND WHY IT TOOK THREE CUTS. A file-wide ordinal written high digits first staged 'A'
      # and 'B' both as '2' (3 files failed); written low digits first it collided ten apart (3 other files).
      # So the number is per BODY LENGTH and per DISTINCT TEXT: equal strings stage equal, and different
      # strings of one length get different numbers until that length runs out of digits - ten one-character
      # strings, a hundred two-character ones. The text map is case-INSENSITIVE on purpose, because a hash
      # literal's keys are: 'a' and 'A' are already the same key in the original.
      $room = 0
      while (($s + $room) -lt $e -and $chars[$s + $room] -ne "`r" -and $chars[$s + $room] -ne "`n") { $room++ }
      if ($room -gt 0) {
        $body = $Text.Substring($s, $e - $s)
        $key = [string]$room + '|' + $body
        if (-not $fillFor.ContainsKey($key)) {
          $n = 0
          if ($nextFor.ContainsKey($room)) { $n = $nextFor[$room] }
          $nextFor[$room] = $n + 1
          if ($room -le 9) { $fillFor[$key] = ([long]($n % [Math]::Pow(10, $room))).ToString(('D' + $room)) }
          else { $fillFor[$key] = [string]$n }
        }
        $fill = $fillFor[$key]
        for ($k = 0; $k -lt $fill.Length; $k++) { $chars[$s + $k] = $fill[$k] }
      }
    }
  }
  return (New-Object string (, $chars))
}

function Get-TcCodeSignature {
  # The code a file tokenizes to, minus its comments: type, offset and length of every token, and the
  # content of every token that is not a string. Two files with equal signatures are the same program up
  # to comment text and string bodies. $null when the text does not tokenize cleanly.
  # -CommentSpans are the ORIGINAL's comment spans, flattened as start,end pairs: a NewLine token the
  # staged text shows inside one is a line break the blanked comment kept, and the stager has already
  # refused every comment where such a break could separate two statements.
  param([string]$Text, [int[]]$CommentSpans = @())
  $errs = $null
  $tokens = $null
  try { $tokens = [System.Management.Automation.PSParser]::Tokenize($Text, [ref]$errs) } catch { return $null }
  if ($null -eq $tokens) { return $null }
  if ($null -ne $errs) { $errList = @($errs); if ($errList.Count -gt 0) { return $null } }
  $sb = New-Object System.Text.StringBuilder
  foreach ($tk in $tokens) {
    $t = [string]$tk.Type
    if ($t -eq 'Comment') { continue }
    if ($t -eq 'NewLine' -and $CommentSpans.Count -gt 0) {
      $inside = $false
      for ($k = 0; $k -lt $CommentSpans.Count; $k += 2) {
        if ($tk.Start -ge $CommentSpans[$k] -and $tk.Start -lt $CommentSpans[$k + 1]) { $inside = $true; break }
      }
      if ($inside) { continue }
    }
    $content = ''
    if ($t -ne 'String') { $content = [string]$tk.Content }
    [void]$sb.Append($t).Append('|').Append($tk.Start).Append('|').Append($tk.Length).Append('|').Append($content).Append("`n")
  }
  return $sb.ToString()
}

function Test-TcStagedStructure {
  # The proof that a staged file is the same program as its original. Length and every line-break offset
  # must match, and so must the code signature. Returns '' when it holds, or the first reason it does not.
  param([string]$Original, [string]$Staged)
  if ($null -eq $Staged) { return 'not staged' }
  if ($Original.Length -ne $Staged.Length) { return ('length {0} -> {1}' -f $Original.Length, $Staged.Length) }
  for ($i = 0; $i -lt $Original.Length; $i++) {
    $a = $Original[$i]; $b = $Staged[$i]
    if (($a -eq "`n" -or $a -eq "`r" -or $b -eq "`n" -or $b -eq "`r") -and $a -ne $b) { return ('line break moved at offset {0}' -f $i) }
  }
  $errs = $null
  $spans = New-Object System.Collections.Generic.List[int]
  foreach ($tk in [System.Management.Automation.PSParser]::Tokenize($Original, [ref]$errs)) {
    # Only a comment that SPANS a line break can leave a NewLine behind, so only those are passed on.
    if ([string]$tk.Type -ne 'Comment') { continue }
    $cs = [int]$tk.Start; $ce = $cs + [int]$tk.Length
    if (Test-TcSpanHasLineBreak -Text $Original -Start $cs -End $ce) { $spans.Add($cs); $spans.Add($ce) }
  }
  $sigA = Get-TcCodeSignature -Text $Original
  $sigB = Get-TcCodeSignature -Text $Staged -CommentSpans $spans.ToArray()
  if ($null -eq $sigB) { return 'staged text does not tokenize' }
  if (-not [string]::Equals($sigA, $sigB, [StringComparison]::Ordinal)) { return 'code signature differs' }
  return ''
}

function Get-TcLineLives {
  # For each line number, which of comment / string text sits on it in the ORIGINAL - the answer to "where
  # did a vanished finding live". Keys are line numbers; values 'comment', 'string' or 'comment+string'.
  param([string]$Text)
  $map = @{}
  $errs = $null
  $tokens = [System.Management.Automation.PSParser]::Tokenize($Text, [ref]$errs)
  foreach ($tk in $tokens) {
    $t = [string]$tk.Type
    if ($t -ne 'Comment' -and $t -ne 'String') { continue }
    $kind = $t.ToLowerInvariant()
    for ($ln = [int]$tk.StartLine; $ln -le [int]$tk.EndLine; $ln++) {
      if (-not $map.ContainsKey($ln)) { $map[$ln] = $kind }
      elseif ($map[$ln] -ne $kind -and $map[$ln] -ne 'comment+string') { $map[$ln] = 'comment+string' }
    }
  }
  return $map
}

function New-TcStagedCorpus {
  # Build BOTH arms from one file list, so the two differ in nothing but the flattening: RealDir holds a
  # byte copy of every stageable file, FlatDir its staged twin. Returns counts, the structure failures, and
  # the per-file line map a vanished finding is classified by.
  param([string]$SourceRoot, [string[]]$RelFiles, [string]$RealDir, [string]$FlatDir)
  $enc = New-Object Text.UTF8Encoding($false)
  $staged = 0
  $unstageable = New-Object System.Collections.ArrayList
  $broken = New-Object System.Collections.ArrayList
  $lives = @{}
  foreach ($rel in $RelFiles) {
    $src = Join-Path $SourceRoot $rel
    if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { continue }
    $text = [IO.File]::ReadAllText($src)
    $flat = ConvertTo-TcStagedSource -Text $text
    if ($null -eq $flat) { [void]$unstageable.Add($rel); continue }
    $why = Test-TcStagedStructure -Original $text -Staged $flat
    if ($why) { [void]$broken.Add(('{0}: {1}' -f $rel, $why)); continue }
    $realPath = Join-Path $RealDir $rel
    $flatPath = Join-Path $FlatDir $rel
    New-Item -ItemType Directory -Force -Path (Split-Path $realPath -Parent) | Out-Null
    New-Item -ItemType Directory -Force -Path (Split-Path $flatPath -Parent) | Out-Null
    [IO.File]::Copy($src, $realPath, $true)
    [IO.File]::WriteAllText($flatPath, $flat, $enc)
    $lives[$rel] = Get-TcLineLives -Text $text
    $staged++
  }
  return [pscustomobject]@{
    Listed = $RelFiles.Count; Staged = $staged
    Unstageable = $unstageable.ToArray(); Broken = $broken.ToArray(); Lives = $lives
  }
}

function Invoke-TcDetectorArm {
  # Run the detector UNCHANGED as a child against one arm. The baseline is a throwaway file holding 0, so
  # the run can never write one (a missing baseline is written) and every finding is printed; its exit is
  # then 0 or 2 by the ratchet, which means nothing here. What must hold is the completion marker, and a
  # parsed finding count equal to the count on that marker - otherwise the arm is BLIND, never empty.
  param([hashtable]$Spec, [string]$ArmRoot, [string]$Scratch)
  $bl = Join-Path $Scratch ('bl-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.json')
  [IO.File]::WriteAllText($bl, '{ "sites": 0, "note": "probe-staged-corpus throwaway" }', (New-Object Text.UTF8Encoding($false)))
  $det = Join-Path $repo $Spec.Path
  $out = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $det -Root $ArmRoot -BaselineFile $bl)
  $rc = $LASTEXITCODE
  $marker = @($out | Where-Object { [string]$_ -match [regex]::Escape($Spec.Marker) })
  $sites = New-Object System.Collections.ArrayList
  foreach ($l in $out) {
    $m = [regex]::Match([string]$l, $Spec.Finding)
    if ($m.Success) { [void]$sites.Add(('{0}:{1}' -f $m.Groups['file'].Value, $m.Groups['line'].Value)) }
  }
  $declared = -1
  if ($marker.Count -gt 0) {
    $cm = [regex]::Match([string]$marker[-1], $Spec.Count)
    if ($cm.Success) { $declared = [int]$cm.Groups['n'].Value }
  }
  $ok = ($marker.Count -gt 0) -and ($rc -eq 0 -or $rc -eq 2) -and ($declared -eq $sites.Count)
  return [pscustomobject]@{ Ok = $ok; Rc = $rc; Declared = $declared; Sites = $sites.ToArray(); Output = $out }
}

function Compare-TcArms {
  # One row per finding site per arm. A site is file:line, which means the same code in both arms because
  # the staging keeps every line where it was.
  param([string[]]$RealSites, [string[]]$FlatSites, [hashtable]$Lives)
  $flatSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  foreach ($s in $FlatSites) { [void]$flatSet.Add($s) }
  $realSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  foreach ($s in $RealSites) { [void]$realSet.Add($s) }
  $rows = New-Object System.Collections.ArrayList
  foreach ($s in ($realSet | Sort-Object)) {
    $survived = $flatSet.Contains($s)
    $where = ''
    if (-not $survived) {
      $idx = $s.LastIndexOf(':')
      $file = $s.Substring(0, $idx); $ln = [int]$s.Substring($idx + 1)
      $where = 'code'
      if ($Lives.ContainsKey($file) -and $Lives[$file].ContainsKey($ln)) { $where = $Lives[$file][$ln] }
    }
    [void]$rows.Add([pscustomobject]@{ site = $s; arm = 'real'; found = $true; lives_in = $where })
    [void]$rows.Add([pscustomobject]@{ site = $s; arm = 'staged'; found = $survived; lives_in = $where })
  }
  # A site only the staged arm finds would mean flattening CREATED a finding. It cannot happen for a
  # detector that only matches text that was there, so it is reported loudly rather than dropped.
  foreach ($s in ($flatSet | Sort-Object)) {
    if ($realSet.Contains($s)) { continue }
    [void]$rows.Add([pscustomobject]@{ site = $s; arm = 'real'; found = $false; lives_in = 'staged-only' })
    [void]$rows.Add([pscustomobject]@{ site = $s; arm = 'staged'; found = $true; lives_in = 'staged-only' })
  }
  return ,@($rows.ToArray())
}

function Invoke-TcStagedDifferential {
  param([string]$SourceRoot, [string[]]$RelFiles, [hashtable]$Spec, [string]$Scratch)
  $realDir = Join-Path $Scratch 'real'
  $flatDir = Join-Path $Scratch 'flat'
  New-Item -ItemType Directory -Force -Path $realDir, $flatDir -ErrorAction Stop | Out-Null
  # THE DETECTOR NEVER SCANS ITSELF in a real run (it excludes its own path), so its own file is left out of
  # both arms here, or the real arm would count the detector's fixtures and the pairing would start skewed.
  $self = $Spec.Path.ToLowerInvariant()
  $list = @($RelFiles | Where-Object { $_.ToLowerInvariant() -ne $self })
  $corpus = New-TcStagedCorpus -SourceRoot $SourceRoot -RelFiles $list -RealDir $realDir -FlatDir $flatDir
  $real = Invoke-TcDetectorArm -Spec $Spec -ArmRoot $realDir -Scratch $Scratch
  $flat = Invoke-TcDetectorArm -Spec $Spec -ArmRoot $flatDir -Scratch $Scratch
  $rows = @()
  if ($real.Ok -and $flat.Ok) { $rows = Compare-TcArms -RealSites $real.Sites -FlatSites $flat.Sites -Lives $corpus.Lives }
  return [pscustomobject]@{ Corpus = $corpus; Real = $real; Flat = $flat; Rows = $rows; RealDir = $realDir; FlatDir = $flatDir }
}

# ------------------------------------------------------------------------------------------ self-test
if ($SelfTest) {
  $script:stFail = 0
  $script:stCases = 0
  function Test-StagedCase {
    # A case that THROWS is a counted failure, never a skipped line; named in full because a one-letter
    # helper resolves to a built-in alias before a function.
    param([string]$Label, [scriptblock]$Check)
    $script:stCases++
    $ok = $false
    try { $ok = [bool](& $Check) } catch { $Label = $Label + ' (threw: ' + $_.Exception.Message + ')' }
    if ($ok) { Write-Output ('  PASS  ' + $Label) } else { Write-Output ('  FAIL  ' + $Label); $script:stFail++ }
  }
  # NEEDLES ARE BUILT BY CONCATENATION: audit-write-seam scans this file on every push, and a contiguous
  # fixture line here would be counted as a real bypass ([[selftest-greps-its-own-source]]).
  $irm = 'Invoke-' + 'RestMethod'
  $api = '$' + 'apiUrl'

  $stDir = Join-Path ([IO.Path]::GetTempPath()) ('psc-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -ErrorAction Stop -Path $stDir | Out-Null
  try {
    # ---- the stager on every quoting shape that has cost this estate a reducer bug --------------------
    $fxL1 = '$opener = ''<# a quoted opener, not a comment'''
    $fxL2 = '$banner = "first line'
    $fxL3 = '#second line is data'
    $fxL4 = 'third line $(Get-Thing)"'
    $fxL5 = '$doc = @'''
    $fxL6 = '<# header inside a here-string'
    $fxL7 = '''@'
    $fxL8 = '<# a real block'
    $fxL9 = '   comment #>'
    $fxL10 = '$live = 1 # a trailing comment'
    $fxShapes = @($fxL1, $fxL2, $fxL3, $fxL4, $fxL5, $fxL6, $fxL7, $fxL8, $fxL9, $fxL10) -join "`r`n"
    $flatShapes = ConvertTo-TcStagedSource -Text $fxShapes
    Test-StagedCase 'MUST FIRE  every comment and every string body is blanked: none of their words survive staging' {
      ($null -ne $flatShapes) -and ($flatShapes -notmatch 'quoted opener') -and ($flatShapes -notmatch 'second line') -and
      ($flatShapes -notmatch 'Get-Thing') -and ($flatShapes -notmatch 'header inside') -and
      ($flatShapes -notmatch 'real block') -and ($flatShapes -notmatch 'trailing comment')
    }
    Test-StagedCase 'CLEAN TWIN  the code survives staging: the assignments, their quote delimiters and the here-string terminator are all still there' {
      $lines = $flatShapes -split "`r`n"
      ($lines.Count -eq 10) -and ($lines[0] -match '^\$opener = ''0\s+''$') -and ($lines[1] -match '^\$banner = "') -and
      ($lines[4] -eq '$doc = @''') -and ($lines[6] -eq '''@') -and ($lines[9] -match '^\$live = 1\s+$')
    }
    Test-StagedCase 'CLEAN TWIN  the staged text is PROVED the same program: same length, same line breaks, same code signature' {
      (Test-TcStagedStructure -Original $fxShapes -Staged $flatShapes) -eq ''
    }
    # ---- the proof can go red --------------------------------------------------------------------------
    # A stager that blanked a here-string's TERMINATOR would still be the same length with the same line
    # breaks. Only the code signature catches it, so this case is what makes the structure proof a proof.
    $damaged = $flatShapes.Replace("`r`n'@`r`n", "`r`n  `r`n")
    Test-StagedCase 'MUST FIRE  a staged file whose here-string terminator was blanked FAILS the structure proof, though its length and line breaks still match' {
      ($damaged.Length -eq $flatShapes.Length) -and ((Test-TcStagedStructure -Original $fxShapes -Staged $damaged) -ne '')
    }
    Test-StagedCase 'MUST FIRE  a staged file that lost a line break FAILS the structure proof' {
      $shifted = $flatShapes.Remove($flatShapes.IndexOf("`n"), 1).Insert(0, ' ')
      (Test-TcStagedStructure -Original $fxShapes -Staged $shifted) -match 'line break'
    }
    Test-StagedCase 'CLEAN TWIN  a file PSParser refuses is not staged at all: the stager answers null rather than a guess' {
      $null -eq (ConvertTo-TcStagedSource -Text '$a = ''unterminated')
    }
    Test-StagedCase 'MUST FIRE  a multi-line block comment with code BESIDE it is refused, since its kept line break could split one statement into two' {
      $beside = 'Get-Thing <# spans' + "`r`n" + '   two lines #> -Name x'
      $alone = '$a = 1' + "`r`n" + '<# spans' + "`r`n" + '   two lines #>' + "`r`n" + '$b = 2'
      ($null -eq (ConvertTo-TcStagedSource -Text $beside)) -and ($null -ne (ConvertTo-TcStagedSource -Text $alone))
    }
    Test-StagedCase 'MUST FIRE  hash keys of EQUAL LENGTH stay distinct after staging, so the staged hash literal still parses (107 of 792 real files failed without this)' {
      $keys = '$m = @{' + "`r`n" + '  ''baking'' = @(''pantry'')' + "`r`n" + '  ''canned'' = @(''pantry'')' + "`r`n" + '}'
      $st = ConvertTo-TcStagedSource -Text $keys
      ($null -ne $st) -and ($st -notmatch 'baking|canned|pantry') -and ((Test-TcStagedStructure -Original $keys -Staged $st) -eq '')
    }

    # ---- THE REAL DETECTOR ON A STAGED TREE ----------------------------------------------------------
    # One file, three findings for audit-write-seam, each living somewhere different:
    #   line 1  STRUCTURAL - the call, the verb and the surface are all code, not text
    #   line 3  a LITERAL  - the whole call is the body of a string
    #   line 5  a COMMENT  - code with no bypass, and the bypass spelled in a TRAILING comment, which the
    #           detector's whole-line comment filter does not reach
    # Plus one file PSParser refuses, which must land in neither arm.
    $src = Join-Path $stDir 'src'
    New-Item -ItemType Directory -Force -Path (Join-Path $src 'grocery') | Out-Null
    $fxA1 = $irm + ' -Method Post -Uri ' + $api + ' -Body $b'
    $fxA3 = 'Write-Output ''' + $irm + ' -Method Post -Uri https://x.ghost.io/ is the shape'''
    $fxA5 = '$quiet = 1 # ' + $irm + ' -Method Put ' + $api
    $fxA = @($fxA1, '', $fxA3, '', $fxA5) -join "`n"
    [IO.File]::WriteAllText((Join-Path $src 'grocery\seam-fixture.ps1'), $fxA, (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $src 'grocery\broken.ps1'), ('$x = ''never closed' + "`n" + $fxA1), (New-Object Text.UTF8Encoding($false)))
    $scr = Join-Path $stDir 'stage'
    $d = Invoke-TcStagedDifferential -SourceRoot $src -RelFiles @('grocery\seam-fixture.ps1', 'grocery\broken.ps1') -Spec $script:DETECTORS['write-seam'] -Scratch $scr
    $site = 'grocery\seam-fixture.ps1'
    Test-StagedCase 'CLEAN TWIN  both detector arms COMPLETED, with the parsed finding count equal to the count on the marker' {
      $d.Real.Ok -and $d.Flat.Ok
    }
    Test-StagedCase 'MUST FIRE  on the REAL arm the unchanged detector fires on all three lines, as it does on the tree' {
      $r = @($d.Real.Sites)
      ($r.Count -eq 3) -and ($r -contains ($site + ':1')) -and ($r -contains ($site + ':3')) -and ($r -contains ($site + ':5'))
    }
    Test-StagedCase 'MUST FIRE  on the STAGED arm the structural bypass fires at the SAME file and line, and nothing else fires' {
      $f = @($d.Flat.Sites)
      ($f.Count -eq 1) -and ($f[0] -eq ($site + ':1'))
    }
    Test-StagedCase 'CLEAN TWIN  the paired rows name where each vanished finding lived: line 3 in a string, line 5 in a comment' {
      $rows = @($d.Rows)
      $v3 = @($rows | Where-Object { $_.site -eq ($site + ':3') -and $_.arm -eq 'staged' })
      $v5 = @($rows | Where-Object { $_.site -eq ($site + ':5') -and $_.arm -eq 'staged' })
      $s1 = @($rows | Where-Object { $_.site -eq ($site + ':1') -and $_.arm -eq 'staged' })
      ($rows.Count -eq 6) -and ($v3.Count -eq 1) -and (-not $v3[0].found) -and ($v3[0].lives_in -eq 'string') -and
      ($v5.Count -eq 1) -and (-not $v5[0].found) -and ($v5[0].lives_in -eq 'comment') -and ($s1.Count -eq 1) -and $s1[0].found
    }
    Test-StagedCase 'CLEAN TWIN  the unparseable file is in NEITHER arm and is counted, and the real arm is a byte copy of its source' {
      $srcHash = (Get-FileHash -LiteralPath (Join-Path $src 'grocery\seam-fixture.ps1') -Algorithm MD5).Hash
      $armHash = (Get-FileHash -LiteralPath (Join-Path $d.RealDir 'grocery\seam-fixture.ps1') -Algorithm MD5).Hash
      (@($d.Corpus.Unstageable).Count -eq 1) -and (@($d.Corpus.Unstageable)[0] -eq 'grocery\broken.ps1') -and
      (-not (Test-Path -LiteralPath (Join-Path $d.RealDir 'grocery\broken.ps1'))) -and
      (-not (Test-Path -LiteralPath (Join-Path $d.FlatDir 'grocery\broken.ps1'))) -and ($srcHash -eq $armHash)
    }
  } finally {
    Remove-Item -LiteralPath $stDir -Recurse -Force -ErrorAction SilentlyContinue
  }

  if ($script:stCases -ne 13) { Write-Output ('STAGED-CORPUS SELF-TEST FAIL (ran {0} of 13 cases)' -f $script:stCases); exit 1 }
  if ($script:stFail) { Write-Output ('STAGED-CORPUS SELF-TEST FAIL ({0} of {1} case(s))' -f $script:stFail, $script:stCases); exit 1 }
  Write-Output ('STAGED-CORPUS SELF-TEST PASS ({0} of {0} cases: the stager blanks every comment and string body and is proved the same program, the proof goes red on a damaged stage, and the unchanged audit-write-seam fires its structural bypass at the same line in both arms)' -f $script:stCases)
  exit 0
}

# ------------------------------------------------------------------------------------------ live run
$spec = $script:DETECTORS[$Detector]
if ($null -eq $spec) { Write-Output ('STAGED-CORPUS: unknown detector {0}; known: {1}' -f $Detector, (($script:DETECTORS.Keys | Sort-Object) -join ', ')); exit 3 }
$srcRoot = if ($Root) { (Resolve-Path -LiteralPath $Root).Path } else { $repo }
$rel = @(& git -C $srcRoot ls-files -- '*.ps1' | ForEach-Object { $_.Replace('/', '\') })
if ($rel.Count -eq 0) {
  Write-Output 'STAGED-CORPUS BLIND: git ls-files named zero tracked .ps1, which means the listing is broken rather than the tree being empty.'
  Exit-Guard -Name 'staged-corpus' -Summary 'blind=no-files' -Code 3
}
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('psc-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -ErrorAction Stop -Path $scratch | Out-Null
$exitCode = 0
$summary = ''
try {
  $head = (& git -C $srcRoot rev-parse --short HEAD)
  $d = Invoke-TcStagedDifferential -SourceRoot $srcRoot -RelFiles $rel -Spec $spec -Scratch $scratch
  $c = $d.Corpus
  Write-Output ('staged-corpus: at {0}, {1} tracked .ps1 listed, {2} staged in both arms, {3} unstageable (PSParser refuses them), {4} failed the structure proof' -f $head, $c.Listed, $c.Staged, @($c.Unstageable).Count, @($c.Broken).Count)
  foreach ($u in @($c.Unstageable)) { Write-Output ('  unstageable  ' + $u) }
  foreach ($b in @($c.Broken)) { Write-Output ('  STRUCTURE FAILED  ' + $b) }
  if (-not ($d.Real.Ok -and $d.Flat.Ok)) {
    Write-Output ('STAGED-CORPUS BLIND: a detector arm did not complete (real rc={0} declared={1} parsed={2}; staged rc={3} declared={4} parsed={5})' -f $d.Real.Rc, $d.Real.Declared, @($d.Real.Sites).Count, $d.Flat.Rc, $d.Flat.Declared, @($d.Flat.Sites).Count)
    $exitCode = 3
    $summary = 'blind=detector-arm'
  } else {
    $rows = @($d.Rows)
    $realRows = @($rows | Where-Object { $_.arm -eq 'real' -and $_.found })
    $survived = @($rows | Where-Object { $_.arm -eq 'staged' -and $_.found -and $_.lives_in -ne 'staged-only' })
    $vanished = @($rows | Where-Object { $_.arm -eq 'staged' -and -not $_.found })
    $stagedOnly = @($rows | Where-Object { $_.arm -eq 'staged' -and $_.lives_in -eq 'staged-only' })
    foreach ($r in ($rows | Where-Object { $_.arm -eq 'staged' } | Sort-Object site)) {
      $state = if ($r.lives_in -eq 'staged-only') { 'STAGED-ONLY' } elseif ($r.found) { 'survived' } else { 'vanished (' + $r.lives_in + ')' }
      Write-Output ('  {0,-28} {1}' -f $state, $r.site)
    }
    $byLife = @{}
    foreach ($v in $vanished) { if ($byLife.ContainsKey($v.lives_in)) { $byLife[$v.lives_in]++ } else { $byLife[$v.lives_in] = 1 } }
    $lifeText = (($byLife.Keys | Sort-Object | ForEach-Object { '{0} {1}' -f $byLife[$_], $_ }) -join ', ')
    if (-not $lifeText) { $lifeText = 'none' }
    Write-Output ('staged-corpus: detector {0} found {1} site(s) on the real arm; {2} of {1} survived the flattening (structural), {3} of {1} vanished ({4}); {5} site(s) found only on the staged arm' -f $Detector, $realRows.Count, $survived.Count, $vanished.Count, $lifeText, $stagedOnly.Count)
    if ($OutFile) {
      $lines = foreach ($r in $rows) { ([ordered]@{ detector = $Detector; commit = $head; site = $r.site; arm = $r.arm; found = $r.found; lives_in = $r.lives_in } | ConvertTo-Json -Compress) }
      [IO.File]::WriteAllText($OutFile, ((@($lines) -join "`n") + "`n"), (New-Object Text.UTF8Encoding($false)))
      Write-Output ('  rows written: {0} ({1} rows, one per site per arm)' -f $OutFile, $rows.Count)
    }
    $summary = ('files={0} staged={1} structure_failed={2} real={3} survived={4} vanished={5} staged_only={6}' -f $c.Listed, $c.Staged, @($c.Broken).Count, $realRows.Count, $survived.Count, $vanished.Count, $stagedOnly.Count)
    if (@($c.Broken).Count -gt 0) { $exitCode = 1 }
  }
  if ($KeepStage) { Write-Output ('  stage kept: real={0} staged={1}' -f $d.RealDir, $d.FlatDir) }
} finally {
  if (-not $KeepStage) { Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue }
}
Exit-Guard -Name 'staged-corpus' -Summary $summary -Code $exitCode
