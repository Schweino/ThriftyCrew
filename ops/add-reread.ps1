<#
  add-reread.ps1 - record ONE re-read of a moved harness as a row in design\reread-ledger.tsv, in the caller's own words.

  W4.1 of design\PLAN-push-derived-conflicts-2026-09-23.md (Brad's ruling D4, 2026-09-23).

  WHAT A RE-READ IS. ops\audit-conclusion-currency.ps1 marks a recorded conclusion UNQUALIFIED when a harness it names
  moved after the commit it cites, and lists the harness commits it moved past. Reading those changes and deciding that
  the conclusion still holds IS the re-read (.claude\rules\measurement.md). This tool only WRITES what the caller decided:
  it takes the note the caller typed, and nothing here, in the audit or anywhere else, writes a row on anyone's behalf.

  WHY A ROW AND NOT A DOC LINE. A "Re-read at harness blob ..." line inside the doc collides with every other session that
  re-reads the same doc, and a rebase that moves the harness makes it stale on arrival. The ledger is one append-only
  file that git merges by union (.gitattributes), so two sessions' rows never conflict, and ops\audit-reread-ledger.ps1
  refuses a push that deletes or edits a row.

  WHAT IT WRITES, one row, seven tab-separated fields, LF, UTF-8 with no BOM:
      doc  harness  blob  prior_blob  date  reread  note
    blob        the harness's blob: `git rev-parse HEAD:<harness>`, or `git hash-object <harness>` when the working copy
                differs from HEAD (a row at an uncommitted blob qualifies only once that content is committed, and this
                says so);
    prior_blob  the blob the pair was LAST qualified at (a ledger row, a doc line's blob, or the harness at the cited
                commit), read from the audit's own -PairState report so there is one definition of it, or `-`;
    note        the caller's words: refused when empty, when it carries a tab, CR or LF, or when it repeats a note already
                written for this pair, because a copied note turns the re-read into a formality.
  It REFUSES a harness the doc does not enrol: a row never enrols a harness, so such a row would qualify nothing.
  It writes through lib\lf-write.ps1 (Write-TcLfFile -NoBom): read the current bytes, append the one LF-terminated row,
  write the whole file. NOT lib\append-line.ps1, whose Add-TcLine always appends CRLF. One person runs this, so append
  atomicity is not needed. It then counts the CRs in the bytes on disk and fails if there is one.

  A BY-HAND TOOL, and no executable names it on purpose (grocery\audit-script-census.ps1 records it in KNOWN): a scheduled
  or scripted caller would be writing re-reads nobody read.

    powershell -NoProfile -File ops\add-reread.ps1 -Doc design\MEASURE-x.md -Harness ops\run-gates.ps1 -Note "<what still holds>"
    powershell -NoProfile -File ops\add-reread.ps1 -SelfTest

  EXIT: 0 wrote one row, 2 refused and wrote nothing (or wrote a row the CR check then found wanting), 3 could not
  evaluate (no git, no ledger, or the audit's pair report could not be read).
#>
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop
param([string]$Doc = '', [string]$Harness = '', [string]$Note = '', [string]$Date = '', [string]$Root = '', [switch]$SelfTest)

$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\ops' }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $repo 'lib\lf-write.ps1')       # Write-TcLfFile: LF, one trailing LF, no BOM with -NoBom
. (Join-Path $repo 'lib\git-blob-lib.ps1')   # Invoke-GitCaptured: rc, stdout and stderr, no console decode

$script:ARR_LEDGER_REL = 'design/reread-ledger.tsv'
$script:ARR_HEADER = "doc`tharness`tblob`tprior_blob`tdate`taction`tnote"

function ConvertTo-TcRereadRel {
  <# A path as the ledger spells it: relative to -RootFull, forward slashes. An absolute path outside the root, or one
     that climbs out of it, comes back ''. #>
  param([string]$RootFull, [string]$Path)
  if (-not $Path) { return '' }
  $full = if ([IO.Path]::IsPathRooted($Path)) { [IO.Path]::GetFullPath($Path) } else { [IO.Path]::GetFullPath((Join-Path $RootFull $Path)) }
  $rf = $RootFull.TrimEnd('\') + '\'
  if (-not $full.StartsWith($rf, [StringComparison]::OrdinalIgnoreCase)) { return '' }
  return ($full.Substring($rf.Length) -replace '\\', '/')
}

function Get-TcRereadPriorNotes {
  <# Pure over the ledger's TEXT: the notes of every row already written for (doc, harness), matched as the audit
     matches paths (OrdinalIgnoreCase, forward slashes). #>
  param([string]$Text, [string]$DocRel, [string]$HarnessRel)
  $out = New-Object System.Collections.Generic.List[string]
  foreach ($ln in ([string]$Text -split "`n")) {
    $f = $ln.TrimEnd([char]13).Split([char]9)
    if ($f.Count -ne 7) { continue }
    if (-not [string]::Equals(($f[0] -replace '\\', '/').Trim(), $DocRel, [StringComparison]::OrdinalIgnoreCase)) { continue }
    if (-not [string]::Equals(($f[1] -replace '\\', '/').Trim(), $HarnessRel, [StringComparison]::OrdinalIgnoreCase)) { continue }
    [void]$out.Add($f[6].Trim())
  }
  $arr = $out.ToArray()
  return ,$arr
}

function Test-TcRereadNote {
  <# Pure. '' when the note may be written, otherwise the reason it is refused. #>
  param([string]$Note, [string[]]$PriorNotes = @())
  $n = ([string]$Note).Trim()
  if (-not $n) { return 'the note is empty: a re-read says, in your words, what still holds after the harness changes it read' }
  if ($Note.IndexOf([char]9) -ge 0 -or $Note.IndexOf([char]13) -ge 0 -or $Note.IndexOf([char]10) -ge 0) { return 'the note carries a tab, CR or LF, which would break the seven-field row' }
  foreach ($p in @($PriorNotes)) {
    if ([string]::Equals($n, [string]$p, [StringComparison]::Ordinal)) { return 'the note repeats one already written for this pair word for word; a copied note is a formality, not a re-read' }
  }
  return ''
}

function Invoke-TcAddReread {
  <# The whole write, returning @{ Code; Lines } so the self-test and the entry point read one answer. #>
  param([string]$RootFull, [string]$DocArg, [string]$HarnessArg, [string]$NoteArg, [string]$DateArg)
  $msgs = New-Object System.Collections.Generic.List[string]
  $refuse = { param($why) [void]$msgs.Add('add-reread: REFUSED - ' + $why + ' Nothing was written.'); return @{ Code = 2; Lines = $msgs.ToArray() } }
  $blind = { param($why) [void]$msgs.Add('add-reread: COULD NOT EVALUATE - ' + $why + ' Nothing was written.'); return @{ Code = 3; Lines = $msgs.ToArray() } }
  $day = if ($DateArg) { $DateArg } else { (Get-Date).ToString('yyyy-MM-dd') }
  if ($day -notmatch '^\d{4}-\d{2}-\d{2}$') { return (& $refuse ('-Date is not YYYY-MM-DD: ' + $day + '.')) }
  $docRel = ConvertTo-TcRereadRel -RootFull $RootFull -Path $DocArg
  $harRel = ConvertTo-TcRereadRel -RootFull $RootFull -Path $HarnessArg
  if (-not $docRel -or $docRel -notmatch '^design/(?:EVAL|MEASURE)-[^/]+\.md$') { return (& $refuse ('-Doc must name a design\EVAL-*.md or design\MEASURE-*.md file inside this checkout, the documents audit-conclusion-currency judges; got "' + $DocArg + '".')) }
  if (-not (Test-Path -LiteralPath (Join-Path $RootFull ($docRel -replace '/', '\')) -PathType Leaf)) { return (& $refuse ('the document ' + $docRel + ' does not exist.')) }
  if (-not $harRel) { return (& $refuse ('-Harness must name a file inside this checkout; got "' + $HarnessArg + '".')) }
  if (-not (Test-Path -LiteralPath (Join-Path $RootFull ($harRel -replace '/', '\')) -PathType Leaf)) { return (& $refuse ('the harness ' + $harRel + ' does not exist.')) }
  $ledgerFull = Join-Path $RootFull ($script:ARR_LEDGER_REL -replace '/', '\')
  if (-not (Test-Path -LiteralPath $ledgerFull -PathType Leaf)) { return (& $blind ('there is no ' + $script:ARR_LEDGER_REL + ' in ' + $RootFull + '; the ledger starts as its header line and is never created by this tool.')) }
  $bytes = [IO.File]::ReadAllBytes($ledgerFull)
  if ($bytes.Length -eq 0 -or $bytes[$bytes.Length - 1] -ne 10) { return (& $refuse ('the ledger does not end in LF, so a row appended now would be glued to its last line; repair it first (ops\audit-reread-ledger.ps1 names the line).')) }
  $text = (New-Object Text.UTF8Encoding($false)).GetString($bytes)
  $priorR = Get-TcRereadPriorNotes -Text $text -DocRel $docRel -HarnessRel $harRel
  $why = Test-TcRereadNote -Note $NoteArg -PriorNotes @($priorR)
  if ($why) { return (& $refuse ($why + '.')) }

  # THE PAIR, read from the audit's own report, so "enrolled" and "last qualified" have one definition each.
  $audit = Join-Path $repo 'ops\audit-conclusion-currency.ps1'
  $po = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $audit -Root $RootFull -PairState -PairDoc ([IO.Path]::GetFileName($docRel)))
  $prc = $LASTEXITCODE
  if ($prc -ne 0) { return (& $blind ('audit-conclusion-currency -PairState exited ' + $prc + ', so the pair''s state could not be read.')) }
  $mine = @($po | Where-Object { "$_" -like 'PAIR-STATE*' } | ForEach-Object { ,([string]$_).Split([char]9) } | Where-Object {
      $_.Count -ge 7 -and [string]::Equals($_[1], $docRel, [StringComparison]::OrdinalIgnoreCase) -and [string]::Equals($_[2], $harRel, [StringComparison]::OrdinalIgnoreCase) })
  if ($mine.Count -eq 0) { return (& $refuse ($docRel + ' does not enrol ' + $harRel + ' as a harness, so a row for that pair would qualify nothing: a ledger row never enrols a harness.')) }
  $pair = $mine[0]
  $prior = if ($pair[5] -match '^[0-9a-f]{40}$') { $pair[5] } else { '-' }

  # THE BLOB: HEAD's, unless the working copy differs, in which case hash-object's (filters applied, so a CRLF working
  # copy hashes as its LF blob would).
  $hb = Invoke-GitCaptured -Repo $RootFull -GitArgs @('rev-parse', '--verify', '--quiet', ('HEAD:' + $harRel))
  $headBlob = if ($hb.rc -eq 0) { ([string]$hb.stdout).Trim() } else { '' }
  $wb = Invoke-GitCaptured -Repo $RootFull -GitArgs @('hash-object', '--', $harRel)
  if ($wb.rc -ne 0) { return (& $blind ('git hash-object could not hash ' + $harRel + ': ' + ([string]$wb.stderr).Trim())) }
  $workBlob = ([string]$wb.stdout).Trim()
  $blob = $headBlob
  if (-not $headBlob -or -not [string]::Equals($headBlob, $workBlob, [StringComparison]::Ordinal)) {
    $blob = $workBlob
    [void]$msgs.Add('  note: the working copy of ' + $harRel + ' differs from HEAD, so the row cites its hash-object blob ' + $blob + '; it qualifies the pair only once that content is committed.')
  }
  if ($blob -notmatch '^[0-9a-f]{40}$') { return (& $blind ('the harness blob is not a 40-hex id: ' + $blob)) }

  $row = $docRel + [char]9 + $harRel + [char]9 + $blob + [char]9 + $prior + [char]9 + $day + [char]9 + 'reread' + [char]9 + $NoteArg.Trim()
  $newText = $text.Substring(0, $text.Length - 1) + "`n" + $row
  $null = Write-TcLfFile -Path $ledgerFull -Text $newText -NoBom
  $after = [IO.File]::ReadAllBytes($ledgerFull)
  $cr = 0; foreach ($x in $after) { if ($x -eq 13) { $cr++ } }
  if ($cr -ne 0 -or $after[$after.Length - 1] -ne 10) {
    [void]$msgs.Add(('add-reread: FAIL - the row was written, but ' + $script:ARR_LEDGER_REL + ' now carries {0} CR byte(s) or no final LF; fix the file before committing it.') -f $cr)
    return @{ Code = 2; Lines = $msgs.ToArray() }
  }
  [void]$msgs.Add('add-reread: wrote 1 row to ' + $script:ARR_LEDGER_REL + ' (0 CR in the bytes written):')
  [void]$msgs.Add('  ' + ($row -replace [char]9, ' | '))
  [void]$msgs.Add('  state before this row: ' + $pair[3] + '; last qualified at ' + $prior + ' by ' + $pair[6] + '.')
  [void]$msgs.Add('  After you commit it, check the committed blob the same way: git cat-file -p HEAD:' + $script:ARR_LEDGER_REL + ' must carry 0 CR.')
  return @{ Code = 0; Lines = $msgs.ToArray() }
}

if ($SelfTest) {
  $ran = New-Object System.Collections.Generic.List[string]
  $fails = New-Object System.Collections.Generic.List[string]
  function Case([string]$Label, [string]$Name, [bool]$Ok, [string]$Detail = '') {
    [void]$ran.Add($Name)
    if (-not $Ok) { [void]$fails.Add("$Label $Name") }
    Write-Output ("  {0,-14} {1,-70} {2}" -f $Label, $Name, $(if ($Ok) { 'ok' } else { "FAIL $Detail" }))
  }
  $TAB = [char]9
  # ---- pure ----
  Case 'MUST FIRE' 'an EMPTY note is refused' ([bool](Test-TcRereadNote -Note '   ')) ''
  Case 'MUST FIRE' 'a note carrying a TAB is refused, since it would break the row' ([bool](Test-TcRereadNote -Note ('a' + $TAB + 'b'))) ''
  Case 'MUST FIRE' 'a note that REPEATS one already written for the pair is refused' ([bool](Test-TcRereadNote -Note ' same words ' -PriorNotes @('same words'))) ''
  $okNote = Test-TcRereadNote -Note 'new words' -PriorNotes @('same words')
  Case 'MUST NOT FIRE' 'a new note beside an older one for the same pair may be written' ($okNote -eq '') $okNote
  $pn = Get-TcRereadPriorNotes -Text ($script:ARR_HEADER + "`n" + 'design/EVAL-a.md' + $TAB + 'ops/h.ps1' + $TAB + 'x' + $TAB + '-' + $TAB + 'd' + $TAB + 'reread' + $TAB + 'first' + "`n" + 'design/EVAL-b.md' + $TAB + 'ops/h.ps1' + $TAB + 'x' + $TAB + '-' + $TAB + 'd' + $TAB + 'reread' + $TAB + 'other doc' + "`n") -DocRel 'design/EVAL-a.md' -HarnessRel 'ops/h.ps1'
  Case 'CLEAN TWIN' 'the prior notes are the ones written for THIS pair only' (@($pn).Count -eq 1 -and $pn[0] -eq 'first') (@($pn) -join ',')

  # ---- the live write, in a temp repository, read back by the audit that consumes it ----
  . (Join-Path $repo 'lib\git-repo-env.ps1')
  Clear-TcGitRepoEnv
  $lt = Join-Path $env:TEMP ('arr-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Path $lt -ErrorAction Stop | Out-Null
  $u8 = New-Object Text.UTF8Encoding($false)
  function Invoke-FixGit([string]$Dir, [string[]]$GitArgs) {
    $r = Invoke-GitCaptured -Repo $Dir -GitArgs $GitArgs
    if ($r.rc -ne 0) { throw ("fixture git failed (rc {0}): git {1}: {2}" -f $r.rc, ($GitArgs -join ' '), $r.stderr) }
    return ([string]$r.stdout).Trim()
  }
  function Invoke-FixWriter([string[]]$WriterArgs) {
    $o = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Root $tr @WriterArgs)
    return @{ Rc = $LASTEXITCODE; Out = ($o -join "`n") }
  }
  function Get-FixLedgerHash { return [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $tr 'design\reread-ledger.tsv'))) }
  try {
    $tr = Join-Path $lt 'tree'
    [void][IO.Directory]::CreateDirectory((Join-Path $tr 'ops'))
    [void][IO.Directory]::CreateDirectory((Join-Path $tr 'design'))
    $null = Invoke-FixGit $tr @('-c', 'init.defaultBranch=main', 'init', '-q')
    $null = Invoke-FixGit $tr @('config', 'user.name', 'Fixture')
    $null = Invoke-FixGit $tr @('config', 'user.email', 't@t')
    $null = Invoke-FixGit $tr @('config', 'commit.gpgsign', 'false')
    Copy-Item -LiteralPath (Join-Path $repo '.gitattributes') -Destination (Join-Path $tr '.gitattributes')
    [IO.File]::WriteAllText((Join-Path $tr 'ops\h.ps1'), "Write-Output 1`n", $u8)
    [IO.File]::WriteAllText((Join-Path $tr 'ops\other.ps1'), "Write-Output 0`n", $u8)
    [IO.File]::WriteAllText((Join-Path $tr 'design\reread-ledger.tsv'), ($script:ARR_HEADER + "`n"), $u8)
    $null = Invoke-FixGit $tr @('add', '--', '.gitattributes', 'ops/h.ps1', 'ops/other.ps1', 'design/reread-ledger.tsv')
    $null = Invoke-FixGit $tr @('commit', '-q', '-m', 'one')
    $c1 = Invoke-FixGit $tr @('rev-parse', 'HEAD')
    $blobAtC1 = Invoke-FixGit $tr @('rev-parse', ($c1 + ':ops/h.ps1'))
    [IO.File]::WriteAllText((Join-Path $tr 'ops\h.ps1'), "Write-Output 2`n", $u8)
    [IO.File]::WriteAllText((Join-Path $tr 'design\EVAL-x.md'), ("Harness: ops/h.ps1`nCommit it ran at: " + $c1 + "`n"), $u8)
    $null = Invoke-FixGit $tr @('add', '--', 'ops/h.ps1', 'design/EVAL-x.md')
    $null = Invoke-FixGit $tr @('commit', '-q', '-m', 'two')
    $blobNow = Invoke-FixGit $tr @('rev-parse', 'HEAD:ops/h.ps1')

    $h0 = Get-FixLedgerHash
    $w1 = Invoke-FixWriter @('-Doc', 'design\EVAL-x.md', '-Harness', 'ops\h.ps1', '-Date', '2026-09-23')
    Case 'MUST FIRE' 'LIVE: a run with NO note exits 2 and leaves the ledger byte-identical' ($w1.Rc -eq 2 -and (Get-FixLedgerHash) -ceq $h0 -and $w1.Out -match 'note is empty') ("rc=$($w1.Rc) " + $w1.Out)
    $w2 = Invoke-FixWriter @('-Doc', 'design\EVAL-x.md', '-Harness', 'ops\other.ps1', '-Note', 'reads fine', '-Date', '2026-09-23')
    Case 'MUST FIRE' 'LIVE: a harness the doc does not enrol is refused with exit 2, since a row never enrols one' ($w2.Rc -eq 2 -and (Get-FixLedgerHash) -ceq $h0 -and $w2.Out -match 'does not enrol') ("rc=$($w2.Rc) " + $w2.Out)
    $w3 = Invoke-FixWriter @('-Doc', 'design\EVAL-x.md', '-Harness', 'ops\h.ps1', '-Note', 'the second write changed only the number printed', '-Date', '2026-09-23')
    $b3 = [IO.File]::ReadAllBytes((Join-Path $tr 'design\reread-ledger.tsv'))
    $cr3 = 0; foreach ($x in $b3) { if ($x -eq 13) { $cr3++ } }
    $want3 = 'design/EVAL-x.md' + $TAB + 'ops/h.ps1' + $TAB + $blobNow + $TAB + $blobAtC1 + $TAB + '2026-09-23' + $TAB + 'reread' + $TAB + 'the second write changed only the number printed'
    $lines3 = @($u8.GetString($b3).Split([char]10))
    Case 'CLEAN TWIN' 'LIVE: a new note writes ONE row - HEAD''s blob, the blob at the cited commit as prior_blob - with 0 CR and a final LF' `
      ($w3.Rc -eq 0 -and $cr3 -eq 0 -and $b3[$b3.Length - 1] -eq 10 -and $lines3.Count -eq 3 -and [string]::Equals($lines3[1], $want3, [StringComparison]::Ordinal) -and $b3[0] -ne 0xEF) ("rc=$($w3.Rc) cr=$cr3 lines=$($lines3.Count) got=[" + ($lines3[1] -replace [char]9, '<T>') + ']')
    $h3 = Get-FixLedgerHash
    $w4 = Invoke-FixWriter @('-Doc', 'design\EVAL-x.md', '-Harness', 'ops\h.ps1', '-Note', 'the second write changed only the number printed', '-Date', '2026-09-23')
    Case 'MUST FIRE' 'LIVE: the same note again for the same pair exits 2 and writes nothing' ($w4.Rc -eq 2 -and (Get-FixLedgerHash) -ceq $h3 -and $w4.Out -match 'repeats') ("rc=$($w4.Rc) " + $w4.Out)
    $cc = @(& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'ops\audit-conclusion-currency.ps1') -Root $tr -ReportOnly)
    $ccOut = $cc -join "`n"
    Case 'CLEAN TWIN' 'LIVE: the row the writer wrote is read by audit-conclusion-currency: the doc is current by a ledger row' `
      ($LASTEXITCODE -eq 0 -and $ccOut -match 'current\s+EVAL-x\.md' -and $ccOut -match 'ops/h\.ps1 re-read by a ledger row') ($ccOut -replace "`n", ' | ')
    [IO.File]::WriteAllText((Join-Path $tr 'ops\h.ps1'), "Write-Output 3`n", $u8)
    $wbNow = Invoke-FixGit $tr @('hash-object', '--', 'ops/h.ps1')
    $w5 = Invoke-FixWriter @('-Doc', 'design\EVAL-x.md', '-Harness', 'ops\h.ps1', '-Note', 'read against the uncommitted third write', '-Date', '2026-09-23')
    $last5 = @($u8.GetString([IO.File]::ReadAllBytes((Join-Path $tr 'design\reread-ledger.tsv'))).TrimEnd([char]10).Split([char]10))[-1]
    Case 'CLEAN TWIN' 'LIVE: a working copy that differs from HEAD is cited by its hash-object blob, and the writer says it qualifies only once committed' `
      ($w5.Rc -eq 0 -and $last5.Split([char]9)[2] -ceq $wbNow -and $last5.Split([char]9)[3] -ceq $blobNow -and $w5.Out -match 'only once that content is committed') ("rc=$($w5.Rc) " + $w5.Out)
  } catch {
    [void]$fails.Add('LIVE FIXTURES threw before finishing: ' + $_.Exception.Message)
    Write-Output ('  FAIL  the live fixtures threw: ' + $_.Exception.Message)
  } finally {
    Remove-Item -LiteralPath $lt -Recurse -Force -ErrorAction SilentlyContinue
  }

  $expectedCases = 11
  if ($ran.Count -ne $expectedCases) { [void]$fails.Add(("CASE COUNT ran {0} of the {1} cases written in this file" -f $ran.Count, $expectedCases)) }
  Write-Output ''
  if ($fails.Count) {
    Write-Output ("add-reread selftest: {0} FAILED of {1}" -f $fails.Count, $ran.Count)
    $fails | ForEach-Object { Write-Output "  $_" }
    Exit-Guard -Name 'ADD-REREAD-SELFTEST' -Code 1 -Summary "failed=$($fails.Count) cases=$($ran.Count)"
  }
  Write-Output ("add-reread selftest: {0} of {0} cases pass" -f $ran.Count)
  Exit-Guard -Name 'ADD-REREAD-SELFTEST' -Code 0 -Summary "cases=$($ran.Count)"
}

# ------------------------------------------------------------------------------------------------ live
$rootFull = [IO.Path]::GetFullPath($(if ($Root) { $Root } else { $repo })).TrimEnd('\')
$res = Invoke-TcAddReread -RootFull $rootFull -DocArg $Doc -HarnessArg $Harness -NoteArg $Note -DateArg $Date
foreach ($l in @($res.Lines)) { Write-Output $l }
Exit-Guard -Name 'ADD-REREAD' -Code $res.Code -Summary ('doc=' + $Doc + ' harness=' + $Harness + ' code=' + $res.Code)
