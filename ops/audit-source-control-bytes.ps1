<#
  audit-source-control-bytes.ps1 - No tracked source file carries a raw control byte.

  THE FOUNDING BUG (2026-09-07). A patch written through a bash heredoc turned `meal-prep\db\built\`
  into `meal-prep\db<0x08>uilt\`: the heredoc collapsed `\\b` to `\b`, and Python read that as a valid
  escape and wrote the BACKSPACE BYTE into a live PowerShell script. C:\Codex\CLAUDE.md already carries
  the rule that a Windows path goes through the Write tool rather than a heredoc, so this is not a new
  rule - it is the enforcement the rule never had.

  WHY IT NEEDED A DETECTOR RATHER THAN MORE CARE. Every ordinary signal said the file was fine:

    - the script's own -SelfTest stayed GREEN, because the corrupted path is only read on the live
      path and Test-Path on a bad path simply returns $false. The proof it guarded silently carried
      nobody;
    - grep and sed both DISPLAYED it as `dbuilt`, so it read as a DROPPED character, and searching for
      that spelling found nothing. `cat -A` is what showed it;
    - the first repair fixed only the occurrence I had looked at. A second, in a comment, survived -
      which is why this scans for the byte class rather than for an expected spelling.

  BYTES, NOT TEXT. Read as text and the decoder can normalise or replace the very byte in question, so
  the check would be measuring its own reader. ReadAllBytes has no such opinion.

  SOURCE ONLY, AND TRACKED ONLY. A CRLF sweep across this estate once silently rewrote a .npy, so an
  audit that walks the tree by extension is a hazard in itself. This asks git for its file list and
  looks only at the source extensions where a control byte can never be legitimate.
#>
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop (2026-09-07)
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Resolve-Path (Join-Path $here '..')

# Tab, LF and CR are the three that belong in source. Everything else below 0x20, plus DEL, does not.
# The regex says exactly that, and it is now the ONLY statement of the rule; a parallel list of the
# legal byte values used to state the same thing a second time.
$CTRL_RX = [regex]::new("[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]", 'Compiled')
# ISO-8859-1, and the choice matters. The header says bytes rather than text because a decoder can
# normalise or replace the very byte being hunted. This one cannot: it maps 0x00-0xFF to U+0000-U+00FF
# one for one, no multi-byte sequences, no replacement character, no normalisation. So a regex over
# the resulting string is still a BYTE view - and .NET runs it at native speed, where the per-byte
# PowerShell loop this replaced cost 112s of a 490s gate run (measured 2026-09-07).
$LATIN1 = [Text.Encoding]::GetEncoding(28591)
$EXT   = @('.ps1', '.psm1', '.py', '.js', '.md', '.json', '.jsonl', '.txt', '.yml', '.yaml', '.css', '.html')

function Find-TcControlBytes {
  <# The offending byte offsets in a byte array, with the line each one falls on. PURE, so the fixtures
     drive it against literal byte arrays rather than against files on disk. #>
  param([byte[]]$Bytes)
  $hits = @()
  if ($null -eq $Bytes -or $Bytes.Length -eq 0) { return ,$hits }
  $s = $LATIN1.GetString($Bytes)
  $ms = $CTRL_RX.Matches($s)
  # The overwhelmingly common answer, and the whole reason this is fast: one native regex sweep and out.
  if ($ms.Count -eq 0) { return ,$hits }
  foreach ($m in $ms) {
    # Only a file that actually has a hit pays for line numbers, and IndexOf is native too.
    $line = 1; $ix = -1
    while ((($ix = $s.IndexOf("`n", $ix + 1)) -ge 0) -and ($ix -lt $m.Index)) { $line++ }
    $hits += [pscustomobject]@{ Offset = $m.Index; Line = $line; Byte = [int][char]$s[$m.Index] }
  }
  # Unary comma: a single finding must stay an ARRAY, or .Count reads the object's own property and a
  # one-hit file can score wrong. Same collapse this estate keeps being bitten by.
  return ,$hits
}

if ($SelfTest) {
  $f = 0
  function T($m, $cond, $got) { if ($cond) { Write-Output ("ok    " + $m) } else { Write-Output ("FAIL  " + $m + "   got: " + $got); $script:f++ } }
  $enc = [Text.Encoding]::UTF8

  # MUST FIRE - the founding bug, byte for byte as it appeared on disk.
  $bug = $enc.GetBytes('$p = Join-Path $repo "meal-prep\db') + [byte]8 + $enc.GetBytes('uilt\file.html"')
  $hit = Find-TcControlBytes -Bytes $bug
  T 'MUST FIRE  THE ONE THIS EXISTS FOR - a heredoc-collapsed \b left a BACKSPACE byte inside a live path, and every ordinary signal read it as clean' `
    ($hit.Count -eq 1 -and $hit[0].Byte -eq 8) ([string]$hit.Count)
  # ASSIGN, THEN MEASURE. This function returns `,$hits`, so the caller gets the array as ONE object and
  # an inline @(Find-TcControlBytes ...) counts 1 for every input - two findings, none, an empty file,
  # all 1. Five cases here failed that way against a live path that assigns and is correct.
  $two = $enc.GetBytes("# a comment with db") + [byte]8 + $enc.GetBytes("uilt`nand code db") + [byte]8 + $enc.GetBytes('uilt')
  $rTwo = Find-TcControlBytes -Bytes $two
  T 'MUST FIRE  it finds ALL of them, not the first - the real repair missed a second occurrence in a comment because it searched for the spelling it expected' `
    ($rTwo.Count -eq 2) ([string]$rTwo.Count)
  T 'MUST FIRE  and it says which LINE, so the finding is actionable rather than a byte offset into a 200-line file' `
    ($rTwo[1].Line -eq 2) ([string]$rTwo[1].Line)
  $rNul = Find-TcControlBytes -Bytes ($enc.GetBytes('ok') + [byte]0)
  T 'MUST FIRE  a NUL byte counts too - that is the shape a binary written over a text file takes' `
    ($rNul.Count -eq 1) 'a NUL passed'

  # MUST NOT FIRE - the legal inputs. A source tree is full of things that only LOOK like this.
  $rWs = Find-TcControlBytes -Bytes $enc.GetBytes("a`tb`r`nc")
  T 'MUST NOT FIRE  tab, CR and LF are source, not corruption - flagging them would make this red on every file in the estate' `
    ($rWs.Count -eq 0) ([string]$rWs.Count)
  $rEsc = Find-TcControlBytes -Bytes $enc.GetBytes('$rx = "\bword\b"')
  T 'MUST NOT FIRE  THE DISTINCTION THE WHOLE AUDIT RESTS ON - a backslash-b written as TWO CHARACTERS is an escape sequence in a regex or a docstring, and is entirely legal' `
    ($rEsc.Count -eq 0) ([string]$rEsc.Count)
  $rUtf = Find-TcControlBytes -Bytes ([Text.Encoding]::UTF8.GetBytes([char]0x00E9 + 'clair and jalape' + [char]0x00F1 + 'o'))
  T 'MUST NOT FIRE  multi-byte UTF-8 is not a control byte - the continuation bytes are all above 0x7F and an accented word must not read as corruption' `
    ($rUtf.Count -eq 0) ([string]$rUtf.Count)
  $rEmpty = Find-TcControlBytes -Bytes @()
  T 'MUST NOT FIRE  an empty file is clean, not unmeasurable' ($rEmpty.Count -eq 0) ([string]$rEmpty.Count)

  # CLEAN TWIN - adjacent behaviour that still works.
  T 'CLEAN TWIN a single finding is still an ARRAY, so .Count is the number of hits and not a property of the one object' `
    ($hit -is [array]) ($hit.GetType().Name)
  $rNl = Find-TcControlBytes -Bytes ($enc.GetBytes("one`ntwo`n") + [byte]7)
  T 'CLEAN TWIN line numbering survives a file that ends on a newline, so the last finding is not reported one line late' `
    ($rNl[0].Line -eq 3) ([string]$rNl[0].Line)
  T 'CLEAN TWIN it reports the OFFSET as well as the line, so a minified or single-line file is still locatable' `
    ($hit[0].Offset -eq 34) ([string]$hit[0].Offset)

  if ($f) { Write-Output ("SELF-TEST FAIL: {0} check(s)" -f $f); Write-Output 'SOURCE-CONTROL-BYTES-COMPLETE'; exit 1 }
  Write-Output 'SELF-TEST PASS: 4 must-fire cases led by the backspace byte a heredoc wrote into a live path, 4 must-not-fire cases led by a written \b escape staying legal, and 3 clean twins'
  Write-Output 'SOURCE-CONTROL-BYTES-COMPLETE'
  exit 0
}

# ------------------------------------------------------------------------------------ the real tree
Push-Location $repo
try { $tracked = & git ls-files } finally { Pop-Location }
if (-not $tracked -or -not @($tracked).Count) {
  Write-Output 'could not read the tracked file list from git - this audit DID NOT RUN'
  Write-Output 'SOURCE-CONTROL-BYTES-COMPLETE'
  exit 2
}

$scanned = 0; $findings = @()
foreach ($rel in $tracked) {
  if ($EXT -notcontains ([IO.Path]::GetExtension($rel)).ToLower()) { continue }
  $full = Join-Path $repo $rel
  if (-not (Test-Path $full)) { continue }
  $bytes = $null
  try { $bytes = [IO.File]::ReadAllBytes($full) } catch { continue }
  $scanned++
  $hits = Find-TcControlBytes -Bytes $bytes
  foreach ($h in $hits) {
    $findings += [pscustomobject]@{ File = $rel; Line = $h.Line; Offset = $h.Offset; Byte = $h.Byte }
  }
}

foreach ($x in ($findings | Select-Object -First 40)) {
  Write-Output ("  FINDING  {0}:{1}  byte 0x{2:X2} at offset {3}" -f $x.File, $x.Line, $x.Byte, $x.Offset)
}
Write-Output ("scanned {0} tracked source file(s); {1} carrying a raw control byte" -f $scanned, @($findings).Count)
if (@($findings).Count) {
  Write-Output 'A control byte in source is almost always a shell or escape mishap, not something anyone typed.'
  Write-Output 'Repair it with the Write tool, then re-run - a heredoc will do it again.'
}
Write-Output 'SOURCE-CONTROL-BYTES-COMPLETE'
exit $(if (@($findings).Count) { 1 } else { 0 })
