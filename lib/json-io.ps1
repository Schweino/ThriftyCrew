# json-io.ps1 - THE one way this estate reads a data file, because PowerShell 5.1's default is wrong.
#
# THE MECHANISM, reproduced in three lines (2026-09-05):
#     original              : Campbell{U+2019}s Turkey Gravy
#     no BOM, bare read     : Campbell{mojibake}s Turkey Gravy   <- corrupted
#     no BOM, -Encoding UTF8: Campbell{U+2019}s Turkey Gravy
#     with BOM, bare read   : Campbell{U+2019}s Turkey Gravy
# Windows PowerShell 5.1's Get-Content decodes a file with NO byte-order mark using the system ANSI
# codepage (Windows-1252 on this box), not UTF-8. It is not a bug in any one script.
#
# CORRUPTION NEEDS A PAIR, AND NEITHER HALF LOOKS WRONG ON ITS OWN:
#   a WRITER that emits BOM-less UTF-8 - Python's json.dump does, and so does .NET
#     WriteAllText(..., UTF8Encoding($false)). The file it produces is perfectly valid UTF-8.
#   a READER that omits -Encoding - completely ordinary-looking PowerShell.
# Put them together and every non-ASCII byte is silently reinterpreted. Then the misdecoded string is
# written back, so the damage is baked into the BYTES and reading correctly afterwards does not undo it.
# EACH ROUND TRIP ADDS ONE GENERATION. That is why the live Campbell's row was 117 characters for a
# 36-character name (five generations) and why commodities.json once carried 61,542 mojibake characters
# eight to ten generations deep (2026-08-31, see audit-json-encoding.ps1).
#
# MEASURED ON THIS TREE THE DAY THIS LIB WAS WRITTEN:
#     capture files WITH a BOM     314
#     capture files WITHOUT a BOM   45      <- any bare reader touching one of these manufactures mojibake
#     JSON reads WITH -Encoding     55
#     JSON reads WITHOUT it        683
# The five corrupted board cells found on 2026-09-05 were simply the intersection that happened to be live.
#
# WHY THE FIX IS ON THE READER SIDE, NOT THE WRITER SIDE. Making every writer emit a BOM would work, but
# it is unenforceable at the edges (Python tools, browser downloads, anything we do not own) and it
# CONFLICTS with a rule this estate already relies on: audit-json-encoding.ps1 pins commodities.json to
# PURE ASCII WITH NO BOM, deliberately, because pure ASCII decodes identically under UTF-8 and cp1252.
# A reader that handles all three shapes is compatible with that pin and needs no cooperation from anyone.
#
# [IO.File]::ReadAllText IS THE CORRECT PRIMITIVE, and it is better than -Encoding UTF8:
#   - a UTF-8 BOM is detected and stripped
#   - a UTF-16 BOM is detected and honoured
#   - no BOM falls back to UTF-8, which is what every file in this estate actually is
#   - pure ASCII is correct under all of the above
# -Encoding UTF8 only covers the third case, so it is a narrower fix that looks like the same fix.
#
# Dot-source:  . (Join-Path $repoRoot 'lib\json-io.ps1')
# Self-test:   powershell -File lib\json-io.ps1 -SelfTest
#
# NO param() BLOCK HERE, DELIBERATELY - same reason as lib\guard-contract.ps1. In PS 5.1, dot-sourcing a
# script runs its param() block in the CALLER's scope, so a param([switch]$SelfTest) here would reset the
# caller's own -SelfTest to $false on the line after it bound, silently disarming its self-test. Read the
# switch off $args, and only when this file is RUN rather than dot-sourced.
$__jioSelfTest = ($MyInvocation.InvocationName -ne '.') -and ($args -contains '-SelfTest')

function Resolve-JioPath {
  <# PowerShell LOCATION semantics, which [IO.File] does not have (2026-09-06, PLAN-top5 area 5, measured).
     .NET resolves a relative path against the PROCESS working directory; `Push-Location` moves only the
     PowerShell location, and the two are routinely different. `Get-Content 'x.json'` after a Push-Location
     read the file; ReadAllText threw. Three scripts in this estate call Read-JsonFile AND change location -
     check-ad-cycles.ps1, ops\verify-bulk-edit.ps1, meal-prep\pipeline\wave-preaudit.ps1.
     GetUnresolvedProviderPathFromPSPath and NOT Resolve-Path: the latter EXPANDS WILDCARDS, so a file whose
     name contains `[` or `]` would fail - which is the one shape the old bare `Get-Content` got wrong and
     this library got right. Keep it right. #>
  param([Parameter(Mandatory=$true)][string]$Path)
  try { return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path) }
  catch { return $Path }   # no session state (a runspace without one): the raw path is still better than a throw
}

function Read-TextFile {
  <# Raw text, decoded correctly whatever the BOM situation. Throws if the file is missing: an
     unreadable file is not an empty one, and returning '' here is the fail-open-reads-as-empty class.

     THREE THINGS THIS DOES THAT [IO.File]::ReadAllText DOES NOT (all four probed on this box 2026-09-06,
     PLAN-top5-2026-09-06 area 5). ReadAllText was the right primitive for the ENCODING question and it is
     not the right primitive for the FILE question, and the difference was shipped to 608 call sites:

     1. IT REFUSES BYTES THAT ARE NOT UTF-8. ReadAllText's default decoder REPLACES an invalid byte with
        U+FFFD and says nothing. A U+FFFD in a product name is the mojibake class wearing a different face:
        silent corruption, baked into whatever we write back. Measured on this tree the day it was found:
        26,573 .json/.jsonl files, 0 of them invalid UTF-8 - so this class is EMPTY on disk today, and the
        reader must still refuse it, because the corruption is silent on the day it does happen.
     2. IT SHARES THE FILE WITH A WRITER. ReadAllText opens FileShare.Read, so reading a .jsonl while its
        appender holds the handle THREW - where the `Get-Content` it replaced simply read. Every reader of
        graph\provenance\*.jsonl and of a live capture sink's output is that shape. FileShare.ReadWrite
        matches the behaviour this estate was built on. An EXCLUSIVE lock (FileShare.None) still throws,
        because that one is real.
     3. IT HONOURS THE PowerShell LOCATION for a relative path (see Resolve-JioPath). #>
  param([Parameter(Mandatory=$true)][string]$Path)
  $full = Resolve-JioPath $Path
  # A MISSING FILE THROWS, NAMED. FileStream would throw anyway; this says which path, resolved, so a
  # relative-path mistake reads as a relative-path mistake rather than as a missing file.
  if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "Read-TextFile: no such file: $full (from '$Path')" }
  $bytes = $null
  $fs = New-Object IO.FileStream($full, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
  try {
    $ms = New-Object IO.MemoryStream
    try { $fs.CopyTo($ms); $bytes = $ms.ToArray() } finally { $ms.Dispose() }
  } finally { $fs.Dispose() }
  return ConvertFrom-JioBytes -Bytes $bytes -Path $full
}

function ConvertFrom-JioBytes {
  <# The decode half, split out so the self-test can drive every encoding without touching the disk.
     BOM order matters: UTF-32 LE begins FF FE 00 00, which also PREFIXES the UTF-16 LE mark, so the
     four-byte marks are tested first or a UTF-32 file decodes as UTF-16 and reads as gibberish. #>
  param([byte[]]$Bytes, [string]$Path = '')
  if ($null -eq $Bytes -or $Bytes.Length -eq 0) { return '' }
  $b = $Bytes
  if ($b.Length -ge 4 -and $b[0] -eq 0xFF -and $b[1] -eq 0xFE -and $b[2] -eq 0x00 -and $b[3] -eq 0x00) {
    return (New-Object Text.UTF32Encoding($false, $true)).GetString($b, 4, $b.Length - 4)
  }
  if ($b.Length -ge 4 -and $b[0] -eq 0x00 -and $b[1] -eq 0x00 -and $b[2] -eq 0xFE -and $b[3] -eq 0xFF) {
    return (New-Object Text.UTF32Encoding($true, $true)).GetString($b, 4, $b.Length - 4)
  }
  if ($b.Length -ge 2 -and $b[0] -eq 0xFF -and $b[1] -eq 0xFE) { return [Text.Encoding]::Unicode.GetString($b, 2, $b.Length - 2) }
  if ($b.Length -ge 2 -and $b[0] -eq 0xFE -and $b[1] -eq 0xFF) { return [Text.Encoding]::BigEndianUnicode.GetString($b, 2, $b.Length - 2) }
  $off = 0
  if ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) { $off = 3 }
  # THE SECOND ARGUMENT IS THE WHOLE POINT: throwOnInvalidBytes. Without it .NET substitutes U+FFFD and
  # the caller gets a string that looks fine and is not.
  $strict = New-Object Text.UTF8Encoding($false, $true)
  try { return $strict.GetString($b, $off, $b.Length - $off) }
  catch [System.Text.DecoderFallbackException] {
    $at = $_.Exception.Index + $off
    throw ("Read-TextFile: $Path is not valid UTF-8 - first bad byte at offset $at (0x" + ('{0:X2}' -f $b[$at]) + "). It is most likely cp1252/ANSI. Re-save it as UTF-8; decoding it anyway would put a U+FFFD in the data, which is the mojibake class with a different face.")
  }
}

function Read-JsonFile {
  <# The one JSON reader. Returns whatever ConvertFrom-Json returns; wrap in @() at the call site if you
     need an array, because PS 5.1 unrolls a single-element array to a scalar. #>
  param([Parameter(Mandatory=$true)][string]$Path)
  # THE COMMA IS LOAD-BEARING (2026-09-05). A PowerShell function UNROLLS a collection on return, so a
  # single-element top-level JSON array came back as the ELEMENT, while the bare `Get-Content -Raw |
  # ConvertFrom-Json` this replaced returned a 1-element Object[]. Measured:
  #     [{"a":1}]   bare -> Object[]      this function without the comma -> PSCustomObject
  # Every converted call site that then reads .Count, indexes [0], or wraps in @() would have changed
  # behaviour silently - and 608 call sites were converted in one sweep. `return ,$x` wraps once so the
  # unroll on return hands $x back intact, array-ness included. See [[ps51-json-array-traps]]; the estate
  # already documents this exact trap in import-walmart-batch's 'ASSIGN FIRST, THEN WRAP' note.
  # THROUGH Read-TextFile, NOT ReadAllText (2026-09-06): the refusal of non-UTF-8 bytes, the shared read
  # that does not fail on a writer mid-append, and PowerShell location semantics all live there, and a
  # second door into this library would have had none of them.
  return ,(Read-TextFile $Path | ConvertFrom-Json)
}

function Read-JsonFileSettled {
  <# A read that WAITS OUT A REPLACE WINDOW instead of reporting the window as the file's answer (2026-09-11).

     THE HAZARD, measured on this box (Windows 11, PS 5.1). A writer that replaces a file by `Move-Item -Force`
     from a .tmp deletes the destination and then renames the .tmp onto it, so for a moment there is NO FILE,
     and for a moment around the delete the name exists and cannot be opened. [IO.File]::Replace is no better.
     A separate process polling [IO.File]::Exists while 1,500 replaces ran saw the file ABSENT on 4,024 of
     109,718 polls in one run and 6,057 of 93,172 in another; with [IO.File]::Replace, 20,416 of 146,084.
     A reader that tests for the file and maps a miss to "empty" is wrong that often, silently, and in the
     direction that loses rows: the ingredient-resolutions ledger's own writer re-read its ledger that
     way inside its lock, so a could-not-read would have saved only the new row over every existing one.

     WHAT IT RETURNS. The caller owns the policy, because the right policy differs by caller:
       State 'ok'          Doc is the parsed JSON, and -Accept (when given) says it is the expected shape
       State 'absent'      no file, STILL, after waiting -WaitMs
       State 'unreadable'  a file that would not open, decode, parse or pass -Accept, STILL, after -WaitMs
     A WRITER that creates the file may treat a settled 'absent' as a new file. A CONSUMER of a file that has
     existed before must not. Nobody may treat 'unreadable' as empty.

     THE BOUND, AND WHAT ELSE WAS TRIED (measured 2026-09-11: a writer replacing a copy of the live 193 KB
     ledger 1,500 times, a tight-polling reader in a separate process). The window in which the file was
     absent or unopenable ran p50 5.4 and 11.7 ms, p99 10.4 and 99.0 ms, MAX 16.9 and 258.6 ms, over two runs
     of 686 and 461 windows. A reader retrying for 2,000 ms saw 0 blind reads of 299, longest wait 113 ms.
     The bar written before those runs was a bound of at least 10x the longest window seen, which is 3,000
     ms. Only that one other value was tried. The wait is paid only when the file is genuinely missing or
     broken: a present, readable file returns on the first attempt with Waits 0.

     NO WAIT WHEN THE DIRECTORY IS MISSING. A replace never removes the directory, so there is no window to
     wait out, and a path under a directory that does not exist comes back 'absent' at once.

     -OnWait IS THE FIXTURE SEAM. It runs before each sleep with (attempt, state), which is how a self-test
     holds a window open deterministically and closes it mid-read instead of racing a real writer. #>
  param([Parameter(Mandatory=$true)][string]$Path, [int]$WaitMs = 3000, [int]$StepMs = 20,
        [scriptblock]$Accept = $null, [scriptblock]$OnWait = $null)
  $jsFull = Resolve-JioPath $Path
  $jsDir = [IO.Path]::GetDirectoryName($jsFull)
  $jsClock = [Diagnostics.Stopwatch]::StartNew()
  $jsWaits = 0; $jsState = ''; $jsWhy = ''
  while ($true) {
    if (-not [IO.File]::Exists($jsFull)) { $jsState = 'absent'; $jsWhy = "no file at $jsFull" }
    else {
      try {
        $jsDoc = Read-JsonFile $jsFull
        if ($null -eq $Accept -or (& $Accept $jsDoc)) {
          return [pscustomobject]@{ State = 'ok'; Doc = $jsDoc; Why = ''; Waits = $jsWaits; Path = $jsFull }
        }
        $jsState = 'unreadable'; $jsWhy = "$jsFull parsed, but is not the expected shape"
      } catch { $jsState = 'unreadable'; $jsWhy = $_.Exception.Message }
    }
    if ($jsState -eq 'absent' -and $jsDir -and -not [IO.Directory]::Exists($jsDir)) { break }
    if ($jsClock.ElapsedMilliseconds -ge $WaitMs) { break }
    $jsWaits++
    if ($OnWait) { & $OnWait $jsWaits $jsState }
    Start-Sleep -Milliseconds $StepMs
  }
  return [pscustomobject]@{ State = $jsState; Doc = $null; Waits = $jsWaits; Path = $jsFull
                            Why = ("{0} (still {1} after {2} attempt(s) over {3} ms)" -f $jsWhy, $jsState, ($jsWaits + 1), $jsClock.ElapsedMilliseconds) }
}

function Write-JsonFile {
  <# Writes UTF-8 WITH a BOM, so a bare Get-Content elsewhere in the estate still reads it correctly.
     This is belt and braces: Read-JsonFile does not need the BOM, but anything we have not converted yet
     does, and a file we write is the one half of the pair we fully control.
     -Ascii pins the output to pure ASCII with NO BOM instead, for the rule files audit-json-encoding
     pins that way (commodities.json, category-excludes.json). It REFUSES rather than silently mangling
     when the content is not actually ASCII, because a pin that quietly transliterates is worse than none. #>
  param(
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)]$Content,     # a string, or an object to be serialized
    [int]$Depth = 8,
    [switch]$Ascii
  )
  $text = if ($Content -is [string]) { $Content } else { $Content | ConvertTo-Json -Depth $Depth }
  if ($Ascii) {
    $bad = [regex]::Matches($text, '[^\x00-\x7F]')
    if ($bad.Count) { throw ("Write-JsonFile -Ascii refused $Path - it carries $($bad.Count) non-ASCII character(s), so pinning it as ASCII would corrupt them. Escape them at the source (\uXXXX form) or drop -Ascii.") }
    [IO.File]::WriteAllText($Path, $text, (New-Object Text.UTF8Encoding($false)))
    return
  }
  [IO.File]::WriteAllText($Path, $text, (New-Object Text.UTF8Encoding($true)))
}

if ($__jioSelfTest) {
  $fail = 0
  $t = Join-Path $env:TEMP ('jio-' + [guid]::NewGuid().ToString('N').Substring(0,8))
  New-Item -ItemType Directory -Force $t | Out-Null
  # The FROZEN founding string: the apostrophe from the live Hy-Vee Campbell's row, as a codepoint so
  # that re-encoding THIS FILE can never quietly alter the fixture ([[guard-fixture-rule]]).
  $apos = [char]0x2019
  $name = 'Campbell' + $apos + 's Turkey Gravy'
  $json = '{"item":"' + $name + '"}'
  $noBom   = Join-Path $t 'nobom.json'
  $withBom = Join-Path $t 'withbom.json'
  $ascii   = Join-Path $t 'ascii.json'
  [IO.File]::WriteAllText($noBom,   $json, (New-Object Text.UTF8Encoding($false)))
  [IO.File]::WriteAllText($withBom, $json, (New-Object Text.UTF8Encoding($true)))
  [IO.File]::WriteAllText($ascii,   '{"item":"Plain ASCII"}', (New-Object Text.UTF8Encoding($false)))

  # (1) MUST FIRE - the founding bug. A bare Get-Content on the BOM-less file MUST corrupt the name. If
  #     this case ever passes, PowerShell's default changed and the rest of this library is decoration;
  #     it is asserted rather than assumed so the lib cannot outlive its own reason to exist.
  $bare = (Get-Content $noBom -Raw | ConvertFrom-Json).item   # json-readers:allow this IS the founding bug, performed on purpose to prove it still exists
  if ($bare -ne $name) { Write-Output "  PASS  MUST FIRE: a bare Get-Content on a BOM-less UTF-8 file still corrupts the name (this is the bug)" }
  else { Write-Output '  FAIL  a bare read no longer corrupts a BOM-less file - re-derive whether this library is still needed'; $fail++ }

  # (2) the fix, on the same file
  if ((Read-JsonFile $noBom).item -eq $name) { Write-Output '  PASS  Read-JsonFile decodes the BOM-less file correctly' }
  else { Write-Output '  FAIL  Read-JsonFile did not decode a BOM-less UTF-8 file'; $fail++ }

  # (3) CLEAN TWIN - the BOM'd file, which a bare read already handled. The fix must not break what worked.
  if ((Read-JsonFile $withBom).item -eq $name -and (Get-Content $withBom -Raw | ConvertFrom-Json).item -eq $name) {   # json-readers:allow the clean twin must show a bare read still works on a BOM'd file
    Write-Output '  PASS  CLEAN TWIN: a BOM-carrying file reads correctly both ways - the fix breaks nothing that worked'
  } else { Write-Output '  FAIL  Read-JsonFile mishandled a file that already had a BOM'; $fail++ }

  # (4) CLEAN TWIN - pure ASCII with no BOM, the shape audit-json-encoding PINS commodities.json to.
  #     If this ever fails, the reader has become incompatible with the estate's own rule-file policy.
  if ((Read-JsonFile $ascii).item -eq 'Plain ASCII') { Write-Output '  PASS  CLEAN TWIN: pure ASCII with no BOM (the commodities.json pin) reads correctly' }
  else { Write-Output '  FAIL  Read-JsonFile broke the pure-ASCII no-BOM shape that audit-json-encoding pins'; $fail++ }

  # (5) A MISSING FILE THROWS. Returning $null or '' here would be the fail-open-reads-as-empty class,
  #     which on this estate manufactures false ABSENCE and publishes a board with cells missing.
  $threw = $false
  try { [void](Read-JsonFile (Join-Path $t 'does-not-exist.json')) } catch { $threw = $true }
  if ($threw) { Write-Output '  PASS  a missing file THROWS rather than reading as empty' }
  else { Write-Output '  FAIL  a missing file did not throw - could-not-read is being reported as no-data'; $fail++ }

  # (6) Write-JsonFile round trip, and the BOM it promises
  $rt = Join-Path $t 'rt.json'
  Write-JsonFile -Path $rt -Content ([pscustomobject]@{ item = $name })
  $head = [IO.File]::ReadAllBytes($rt)[0..2]
  $bomOk = ($head[0] -eq 0xEF -and $head[1] -eq 0xBB -and $head[2] -eq 0xBF)
  if ($bomOk -and (Read-JsonFile $rt).item -eq $name -and (Get-Content $rt -Raw | ConvertFrom-Json).item -eq $name) {   # json-readers:allow proves the BOM we write makes an unconverted bare reader safe
    Write-Output '  PASS  Write-JsonFile emits a BOM, so even an unconverted bare reader elsewhere still reads it correctly'
  } else { Write-Output "  FAIL  Write-JsonFile round trip failed (bom=$bomOk)"; $fail++ }

  # (7) -Ascii pins with NO BOM, and REFUSES content it would corrupt. A pin that silently transliterates
  #     is worse than no pin: that is how commodities.json lost its accented spellings for weeks.
  $ap = Join-Path $t 'pinned.json'
  Write-JsonFile -Path $ap -Content '{"id":"jalapenos"}' -Ascii
  $ah = [IO.File]::ReadAllBytes($ap)[0..2]
  $noBomOk = -not ($ah[0] -eq 0xEF -and $ah[1] -eq 0xBB -and $ah[2] -eq 0xBF)
  $refused = $false
  try { Write-JsonFile -Path (Join-Path $t 'bad.json') -Content ('{"id":"jalape' + [char]0x00F1 + 'o"}') -Ascii } catch { $refused = $true }
  if ($noBomOk -and $refused) { Write-Output '  PASS  -Ascii writes no BOM and REFUSES non-ASCII content rather than corrupting it' }
  else { Write-Output "  FAIL  -Ascii pin is wrong (noBom=$noBomOk refusedNonAscii=$refused)"; $fail++ }

  # ---- THE SHAPES THE SWEEP NEVER MEASURED (2026-09-06, PLAN-top5-2026-09-06 area 5) -------------------
  # 608 call sites moved to this reader on the strength of three shapes being equivalent. Four more were
  # NOT: cp1252 bytes, a file a writer holds open, a relative path after Push-Location, and a UTF-16 file.
  # Each is a case here now, so the parity that was measured stays measured.

  # (8) MUST FIRE - cp1252 bytes are REFUSED, not silently replaced with U+FFFD. ReadAllText's default
  #     decoder substitutes and says nothing, and a U+FFFD in a product name is the mojibake class with a
  #     different face. The class is EMPTY on this tree today (0 of 26,573 files are invalid UTF-8) and the
  #     reader must still refuse, because the corruption is silent on the day it happens.
  $cp = Join-Path $t 'cp1252.json'
  [IO.File]::WriteAllBytes($cp, [Text.Encoding]::GetEncoding(1252).GetBytes($json))
  $cpThrew = $false; $cpMsg = ''
  try { [void](Read-TextFile $cp) } catch { $cpThrew = $true; $cpMsg = $_.Exception.Message }
  if ($cpThrew -and $cpMsg -match 'not valid UTF-8') { Write-Output '  PASS  MUST FIRE: cp1252 bytes are REFUSED by name and offset, never decoded to a U+FFFD' }
  else { Write-Output "  FAIL  cp1252 bytes were accepted (threw=$cpThrew msg=$cpMsg) - the reader is substituting U+FFFD silently"; $fail++ }
  # (8b) CLEAN TWIN - the SAME characters as BOM-less UTF-8 still read correctly. Refusing everything would
  #      pass case 8 and break the library's whole reason to exist.
  if ((Read-JsonFile $noBom).item -eq $name) { Write-Output '  PASS  CLEAN TWIN: the same string as BOM-less UTF-8 still reads correctly (the refusal is not a blanket)' }
  else { Write-Output '  FAIL  the strict decoder broke the BOM-less UTF-8 case this library exists for'; $fail++ }

  # (9) MUST FIRE - a file another handle holds OPEN FOR WRITE still reads. ReadAllText opens
  #     FileShare.Read and THREW here; the `Get-Content` it replaced simply read. Every reader of
  #     graph\provenance\*.jsonl and of a live capture sink's output is exactly this shape.
  $held = Join-Path $t 'held.json'
  [IO.File]::WriteAllText($held, '{"item":"held"}', (New-Object Text.UTF8Encoding($false)))
  $hs = New-Object IO.FileStream($held, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read)
  try {
    $heldOk = $false
    try { $heldOk = ((Read-JsonFile $held).item -eq 'held') } catch { $heldOk = $false }
    if ($heldOk) { Write-Output '  PASS  MUST FIRE: a file a WRITER holds open still reads (a jsonl appender must not break its readers)' }
    else { Write-Output '  FAIL  a file held open for write could not be read - every provenance jsonl reader breaks mid-append'; $fail++ }
  } finally { $hs.Dispose() }
  # (9b) CLEAN TWIN - an EXCLUSIVE lock is a real lock and must still throw. Sharing everything would turn
  #      a genuine conflict into a half-written read.
  $lock = Join-Path $t 'locked.json'
  [IO.File]::WriteAllText($lock, '{"item":"locked"}', (New-Object Text.UTF8Encoding($false)))
  $ls = New-Object IO.FileStream($lock, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
  try {
    $lockThrew = $false
    try { [void](Read-TextFile $lock) } catch { $lockThrew = $true }
    if ($lockThrew) { Write-Output '  PASS  CLEAN TWIN: an EXCLUSIVE lock still throws - a real conflict is not read through' }
    else { Write-Output '  FAIL  an exclusively locked file was read anyway'; $fail++ }
  } finally { $ls.Dispose() }

  # (10) MUST FIRE - a RELATIVE path resolves against the PowerShell location, not the process working
  #      directory. `Push-Location` moves only the former, and three scripts in this estate call
  #      Read-JsonFile and change location.
  Push-Location $t
  try {
    $relOk = $false
    try { $relOk = ((Read-JsonFile 'nobom.json').item -eq $name) } catch { $relOk = $false }
    if ($relOk) { Write-Output '  PASS  MUST FIRE: a relative path after Push-Location resolves the way Get-Content did' }
    else { Write-Output '  FAIL  a relative path after Push-Location did not resolve - .NET resolved it against the PROCESS cwd'; $fail++ }
  } finally { Pop-Location }
  # (10b) CLEAN TWIN - a name containing `[` still reads. Resolve-Path would EXPAND that as a wildcard;
  #       this is the one shape the old bare Get-Content got wrong and this library got right.
  $brk = Join-Path $t 'we[i]rd.json'
  [IO.File]::WriteAllText($brk, '{"item":"bracket"}', (New-Object Text.UTF8Encoding($false)))
  $brkOk = $false
  try { $brkOk = ((Read-JsonFile $brk).item -eq 'bracket') } catch { $brkOk = $false }
  if ($brkOk) { Write-Output '  PASS  CLEAN TWIN: a file name containing [ ] still reads (path resolution did not start expanding wildcards)' }
  else { Write-Output '  FAIL  a bracketed file name broke - the path now goes through a wildcard-expanding API'; $fail++ }

  # (11) UTF-16 WITH A BOM, EMPTY, AND WHITESPACE-ONLY - the three shapes measured as EQUIVALENT on
  #      2026-09-05. They are asserted here so the parity that was measured stays measured.
  $u16 = Join-Path $t 'utf16.json'
  [IO.File]::WriteAllText($u16, $json, (New-Object Text.UnicodeEncoding($false, $true)))
  $u16b = Join-Path $t 'utf16be.json'
  [IO.File]::WriteAllText($u16b, $json, (New-Object Text.UnicodeEncoding($true, $true)))
  $emptyF = Join-Path $t 'empty.json';  [IO.File]::WriteAllBytes($emptyF, [byte[]]@())
  $wsF    = Join-Path $t 'ws.json';     [IO.File]::WriteAllText($wsF, "  `r`n `t ", (New-Object Text.UTF8Encoding($false)))
  $u16ok = ((Read-JsonFile $u16).item -eq $name) -and ((Read-JsonFile $u16b).item -eq $name)
  $emptyOk = ($null -eq (Read-JsonFile $emptyF)) -and ($null -eq (Read-JsonFile $wsF))
  if ($u16ok -and $emptyOk) { Write-Output '  PASS  CLEAN TWIN: UTF-16 LE and BE with a BOM decode, and an empty or whitespace-only file reads as $null (as Get-Content did)' }
  else { Write-Output "  FAIL  a measured-equivalent shape moved (utf16=$u16ok empty/ws=$emptyOk)"; $fail++ }

  # ---- A SETTLED READ WAITS OUT A REPLACE WINDOW (2026-09-11) -------------------------------------------
  # Each window is HELD deterministically: the fixture removes or exclusively locks the file before the read
  # and -OnWait puts it back on the first wait, so the read provably SAW the window (Waits >= 1) and provably
  # outlived it. Racing a real writer would pass or fail on the scheduler, not on the code.
  $sj = Join-Path $t 'settled.json'
  $sjBody = '{"resolutions":[{"key":"sumac"},{"key":"za atar"},{"key":"labneh"}]}'
  $sjEnc = New-Object Text.UTF8Encoding($false)
  [IO.File]::WriteAllText($sj, $sjBody, $sjEnc)
  $sjAccept = { param($d) $null -ne $d -and ($d.PSObject.Properties.Name -contains 'resolutions') }

  # (12) MUST FIRE - ABSENT, THEN PRESENT. The founding shape: Move-Item -Force deleted the name mid-read.
  Remove-Item $sj -Force
  $r12 = Read-JsonFileSettled -Path $sj -WaitMs 5000 -Accept $sjAccept -OnWait ({ param($n, $s) if ($n -eq 1) { [IO.File]::WriteAllText($sj, $sjBody, $sjEnc) } }.GetNewClosure())
  if ($r12.State -eq 'ok' -and $r12.Waits -ge 1 -and @($r12.Doc.resolutions).Count -eq 3) { Write-Output '  PASS  MUST FIRE: a file ABSENT at the first look and back within the bound reads whole (3 rows), not as empty' }
  else { Write-Output ("  FAIL  an absent-then-present file did not read whole (state={0} waits={1})" -f $r12.State, $r12.Waits); $fail++ }

  # (12b) MUST FIRE - PRESENT BUT UNOPENABLE, THEN OPENABLE. The other half of the window: the name exists and
  #       the open fails. An exclusive handle holds it; the first wait releases it.
  $sjLock = New-Object IO.FileStream($sj, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
  try {
    $r12b = Read-JsonFileSettled -Path $sj -WaitMs 5000 -Accept $sjAccept -OnWait ({ param($n, $s) if ($n -eq 1) { $sjLock.Dispose() } }.GetNewClosure())
  } finally { $sjLock.Dispose() }
  if ($r12b.State -eq 'ok' -and $r12b.Waits -ge 1 -and @($r12b.Doc.resolutions).Count -eq 3) { Write-Output '  PASS  MUST FIRE: a file that exists but will not OPEN at the first look reads whole once the handle is released' }
  else { Write-Output ("  FAIL  an unopenable-then-openable file did not read whole (state={0} waits={1})" -f $r12b.State, $r12b.Waits); $fail++ }

  # (12c) MUST FIRE - a file that STAYS broken is reported 'unreadable', never 'ok' and never an empty doc.
  $sjBad = Join-Path $t 'settled-truncated.json'
  [IO.File]::WriteAllText($sjBad, '{"resolutions":[{"key":"sumac"},{"key":', $sjEnc)
  $r12c = Read-JsonFileSettled -Path $sjBad -WaitMs 150 -Accept $sjAccept
  if ($r12c.State -eq 'unreadable' -and $null -eq $r12c.Doc -and $r12c.Waits -ge 1 -and $r12c.Why) { Write-Output '  PASS  MUST FIRE: a file that stays truncated is UNREADABLE after the bound, with a reason, and no doc' }
  else { Write-Output ("  FAIL  a persistently truncated file was not reported unreadable (state={0} waits={1})" -f $r12c.State, $r12c.Waits); $fail++ }

  # (12d) MUST FIRE - valid JSON of the WRONG SHAPE is unreadable too. A ledger with no rows array is not an
  #       empty ledger, and a writer that believed it was would save over everything the real one held.
  $sjShape = Join-Path $t 'settled-shape.json'
  [IO.File]::WriteAllText($sjShape, '{"oops":1}', $sjEnc)
  $r12d = Read-JsonFileSettled -Path $sjShape -WaitMs 150 -Accept $sjAccept
  if ($r12d.State -eq 'unreadable' -and $null -eq $r12d.Doc) { Write-Output '  PASS  MUST FIRE: parsed JSON that -Accept refuses is UNREADABLE, not an empty ledger' }
  else { Write-Output ("  FAIL  a wrong-shape file was accepted (state={0})" -f $r12d.State); $fail++ }

  # (12e) MUST FIRE - a file that STAYS absent in a directory that exists is reported 'absent' after the bound.
  $r12e = Read-JsonFileSettled -Path (Join-Path $t 'settled-never.json') -WaitMs 150
  if ($r12e.State -eq 'absent' -and $r12e.Waits -ge 1) { Write-Output '  PASS  MUST FIRE: a file that never appears is ABSENT after waiting, and the caller is told so' }
  else { Write-Output ("  FAIL  a never-present file was not reported absent after waiting (state={0} waits={1})" -f $r12e.State, $r12e.Waits); $fail++ }

  # (12f) CLEAN TWIN - the normal path costs nothing: a present, readable file returns on the FIRST attempt,
  #       and a path under a directory that does not exist returns at once, because no replace removes one.
  [IO.File]::WriteAllText($sj, $sjBody, $sjEnc)
  $r12f = Read-JsonFileSettled -Path $sj -WaitMs 5000 -Accept $sjAccept
  $r12g = Read-JsonFileSettled -Path (Join-Path $t 'no-such-dir\settled.json') -WaitMs 5000
  if ($r12f.State -eq 'ok' -and $r12f.Waits -eq 0 -and @($r12f.Doc.resolutions).Count -eq 3 -and $r12g.State -eq 'absent' -and $r12g.Waits -eq 0) {
    Write-Output '  PASS  CLEAN TWIN: a readable file reads on the first attempt (Waits 0), and a missing DIRECTORY is absent at once'
  } else { Write-Output ("  FAIL  the settled read taxed the normal path (ok-waits={0} state={1}; missing-dir waits={2} state={3})" -f $r12f.Waits, $r12f.State, $r12g.Waits, $r12g.State); $fail++ }

  Remove-Item $t -Recurse -Force -ErrorAction SilentlyContinue
  if ($fail) { Write-Output "JSON-IO SELF-TEST FAILED ($fail)"; exit 1 }
  Write-Output 'JSON-IO SELF-TEST PASSED (founding bug armed; cp1252 refused, a held-open file read, an exclusive lock still refused, PS location semantics, brackets, UTF-16, empty and whitespace-only)'
  exit 0
}
