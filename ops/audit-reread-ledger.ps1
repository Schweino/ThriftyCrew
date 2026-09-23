<#
  audit-reread-ledger.ps1 - the re-read ledger only grows, and every row in it is in shape.

  W4.1 of design\PLAN-push-derived-conflicts-2026-09-23.md (Brad's ruling D4, 2026-09-23).

  WHY IT EXISTS. design\reread-ledger.tsv holds one row per re-read of a moved harness, and ops\audit-conclusion-currency.ps1
  reads it as a set: a `reread` row qualifies its own (doc, harness) pair at the harness's current blob, and a
  `withdrawn` row cancels it. `.gitattributes` gives that ONE path merge=union, so two sessions that each append a row
  never conflict on it. Union has two costs, and this file pays both at push time:
    1. union keeps both sides' lines, so it would also keep an EDITED row beside its original and undo a DELETION. A
       ledger that is not append-only is not a ledger. So every row at `git merge-base HEAD origin/main` must still be
       present, byte for byte, in HEAD's ledger; a missing or edited row exits 2 and is named. A re-read is taken back
       by APPENDING a `withdrawn` row, never by editing one.
    2. union joins the two sides' last lines as they are, so a row with no trailing LF is glued onto the next row by the
       merge, and conclusion-currency then counts the glued line as malformed and silently qualifies nothing with it.
       So every line at HEAD must end in LF, the first line must be the header, and every row must have exactly seven
       tab-separated fields: doc, harness, a 40-hex lower-case blob, a 40-hex or `-` prior_blob, a YYYY-MM-DD date,
       an action of `reread` or `withdrawn` (case-exact), and a note that is not empty. No line may carry a CR, and the
       file carries no BOM.

  WHAT IT READS. The COMMITTED blobs at HEAD and at the merge base, as bytes (lib\git-blob-lib.ps1), never the working
  copy: a push is judged on what it carries, and a checkout's line endings are not the blob's.
    a base that git cannot resolve (a shallow checkout, a sandbox with no origin/main) is BLIND: blind=no-merge-base,
      exit 3, which run-gates scores as it scores any non-zero static exit;
    a ledger absent at the base is counted (base_rows=absent) and the comparison is skipped: the push that adds the file
      starts it as its header, so this is green on day one;
    a ledger absent at HEAD is a finding when the base has one (the file was deleted), and BLIND otherwise
      (blind=no-ledger), because there is then nothing to judge.

  SCOPE OF A CLEAN REPORT: SOUND for the two properties it states, over the committed blobs it reads: every base line is
  looked up in HEAD's line set by ordinal equality, and every HEAD line is checked field by field, so a deleted or edited
  row and a row out of shape cannot pass. It says NOTHING about whether a row is TRUE: a `reread` row whose note was
  never read against the harness is in shape and passes here. That half is the person who ran the writer (named in
  .claude\rules\measurement.md), and the audit prints no command that would write one. A finding is real: each is a
  line that fails a rule stated above.

    ops\audit-reread-ledger.ps1              judge HEAD's ledger against the merge base with origin/main
    ops\audit-reread-ledger.ps1 -SelfTest    frozen shape fixtures, the live path against temp repositories, and the
                                             union merge under a plain rebase and under the bot's autoStash -X theirs
                                             rebase, in a temp repo carrying this repo's own .gitattributes

  EXIT (lib\guard-contract.ps1 vocabulary): 0 clean, 2 a row deleted, edited or out of shape, 3 could not evaluate.
#>
# Its self-test builds every repository it reads under %TEMP%, and reads only this repo's .gitattributes (the union line
# it judges) and the three libraries below. So that is its whole input set, declared rather than guessed at.
# gate-inputs: .gitattributes, lib\git-blob-lib.ps1, lib\git-repo-env.ps1, lib\guard-contract.ps1
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop
param([switch]$SelfTest, [string]$Root = '', [string]$BaseRef = 'origin/main')

$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\ops' }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $repo 'lib\git-blob-lib.ps1')   # Get-CommittedBlobBytes and Invoke-GitCaptured: bytes and both streams, no decode

$script:RRL_PATH = 'design/reread-ledger.tsv'
$script:RRL_HEADER = "doc`tharness`tblob`tprior_blob`tdate`taction`tnote"

function Split-TcRereadLines {
  <# The ledger's lines, each WITHOUT its LF and with any CR kept, and whether the bytes end in LF. The empty string after
     the final LF is not a line. Returns @{ Lines; EndsLf; Text; Utf8Ok }. #>
  param([byte[]]$Bytes)
  if ($null -eq $Bytes -or $Bytes.Length -eq 0) { return @{ Lines = @(); EndsLf = $false; Text = ''; Utf8Ok = $true } }
  $strict = New-Object Text.UTF8Encoding($false, $true)
  $text = ''; $ok = $true
  try { $text = $strict.GetString($Bytes) } catch { $ok = $false; $text = (New-Object Text.UTF8Encoding($false)).GetString($Bytes) }
  $endsLf = ($Bytes[$Bytes.Length - 1] -eq 10)
  $parts = $text.Split([char]10)
  $n = $parts.Count
  if ($endsLf) { $n-- }
  $lines = @(if ($n -gt 0) { $parts[0..($n - 1)] })
  return @{ Lines = $lines; EndsLf = $endsLf; Text = $text; Utf8Ok = $ok }
}

function Test-TcRereadLedgerShape {
  <# Pure over the ledger's BYTES. One finding per line that breaks a rule in the header, as @{ Line; Why }, in line
     order; an empty array means the ledger is in shape. #>
  param([byte[]]$Bytes)
  $out = New-Object System.Collections.Generic.List[object]
  if ($null -eq $Bytes -or $Bytes.Length -eq 0) {
    [void]$out.Add(@{ Line = 1; Why = 'the ledger is empty; it starts as its one header line' })
    $a0 = $out.ToArray(); return ,$a0
  }
  if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) {
    [void]$out.Add(@{ Line = 1; Why = 'the file starts with a UTF-8 BOM; the ledger is UTF-8 without one' })
  }
  $sp = Split-TcRereadLines -Bytes $Bytes
  if (-not $sp.Utf8Ok) { [void]$out.Add(@{ Line = 1; Why = 'the file is not valid UTF-8' }) }
  $lines = @($sp.Lines)
  if (-not $sp.EndsLf) {
    [void]$out.Add(@{ Line = [Math]::Max(1, $lines.Count); Why = 'the last line does not end in LF, so a union merge would glue the next appended row onto it' })
  }
  for ($i = 0; $i -lt $lines.Count; $i++) {
    $ln = [string]$lines[$i]
    $no = $i + 1
    if ($ln.IndexOf([char]13) -ge 0) { [void]$out.Add(@{ Line = $no; Why = 'the line carries a CR; the ledger is LF only' }) }
    $clean = $ln.TrimStart([char]0xFEFF)
    if ($i -eq 0) {
      if (-not [string]::Equals($clean, $script:RRL_HEADER, [StringComparison]::Ordinal)) {
        [void]$out.Add(@{ Line = 1; Why = 'the first line is not the header doc<TAB>harness<TAB>blob<TAB>prior_blob<TAB>date<TAB>action<TAB>note' })
      }
      continue
    }
    $f = $ln.Split([char]9)
    if ($f.Count -ne 7) { [void]$out.Add(@{ Line = $no; Why = ('the row has {0} tab-separated field(s), not 7' -f $f.Count) }); continue }
    if (-not $f[0].Trim()) { [void]$out.Add(@{ Line = $no; Why = 'the doc field is empty' }) }
    if (-not $f[1].Trim()) { [void]$out.Add(@{ Line = $no; Why = 'the harness field is empty' }) }
    if ($f[2] -cnotmatch '^[0-9a-f]{40}$') { [void]$out.Add(@{ Line = $no; Why = ('the blob field is not a full 40-hex lower-case blob id: ' + $f[2]) }) }
    if ($f[3] -cnotmatch '^(?:[0-9a-f]{40}|-)$') { [void]$out.Add(@{ Line = $no; Why = ('the prior_blob field is neither a full 40-hex blob id nor -: ' + $f[3]) }) }
    if ($f[4] -cnotmatch '^\d{4}-\d{2}-\d{2}$') { [void]$out.Add(@{ Line = $no; Why = ('the date field is not YYYY-MM-DD: ' + $f[4]) }) }
    if (-not ($f[5] -ceq 'reread' -or $f[5] -ceq 'withdrawn')) { [void]$out.Add(@{ Line = $no; Why = ('the action is neither reread nor withdrawn: ' + $f[5]) }) }
    if (-not ($f[6].Trim([char]13).Trim())) { [void]$out.Add(@{ Line = $no; Why = 'the note is empty; a re-read says what still holds' }) }
  }
  $arr = $out.ToArray()
  return ,$arr
}

function Compare-TcRereadLedgerRows {
  <# Pure. Every BASE line (the header included) that is not present, byte for byte, among HEAD's lines, as
     @{ Line; Text } with the base line number. Ordinal, over lines decoded from the same UTF-8. #>
  param([string[]]$BaseLines, [string[]]$HeadLines)
  $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  foreach ($h in @($HeadLines)) { if ($null -ne $h) { [void]$set.Add([string]$h) } }
  $out = New-Object System.Collections.Generic.List[object]
  $bl = @($BaseLines)
  for ($i = 0; $i -lt $bl.Count; $i++) {
    if (-not $set.Contains([string]$bl[$i])) { [void]$out.Add(@{ Line = ($i + 1); Text = [string]$bl[$i] }) }
  }
  $arr = $out.ToArray()
  return ,$arr
}

function Get-TcRereadBlob {
  <# The ledger at <Commit> as @{ Present; Bytes }. Presence is asked first with cat-file -e through Invoke-GitCaptured,
     so an absent file is an answer and never a line of git's stderr on the console. An empty blob is present with
     zero bytes. #>
  param([string]$TreeRoot, [string]$Commit)
  $spec = $Commit + ':' + $script:RRL_PATH
  $e = Invoke-GitCaptured -Repo $TreeRoot -GitArgs @('cat-file', '-e', $spec)
  if ($e.rc -ne 0) { return @{ Present = $false; Bytes = $null } }
  $b = Get-CommittedBlobBytes -Repo $TreeRoot -Spec $spec
  if ($null -eq $b) { $b = [byte[]]@() }
  return @{ Present = $true; Bytes = $b }
}

function Invoke-TcRereadLedgerAudit {
  <# The live judgement over one checkout. Returns @{ Code; Lines; Summary } so the self-test and the entry point read
     one answer. Code is 0, 2 or 3 as the header says. #>
  param([string]$TreeRoot, [string]$Base = 'origin/main')
  $msgs = New-Object System.Collections.Generic.List[string]
  $hd = Invoke-GitCaptured -Repo $TreeRoot -GitArgs @('rev-parse', '--verify', '--quiet', 'HEAD')
  if ($hd.rc -ne 0) {
    [void]$msgs.Add('! reread-ledger: COULD NOT EVALUATE - ' + $TreeRoot + ' has no HEAD, so there is no committed ledger to judge.')
    return @{ Code = 3; Lines = $msgs.ToArray(); Summary = 'files=0 blind=no-head' }
  }
  $mb = Invoke-GitCaptured -Repo $TreeRoot -GitArgs @('merge-base', 'HEAD', $Base)
  $mbSha = ([string]$mb.stdout).Trim()
  if ($mb.rc -ne 0 -or -not $mbSha) {
    [void]$msgs.Add('! reread-ledger: COULD NOT EVALUATE - git merge-base HEAD ' + $Base + ' found no common ancestor (a shallow checkout, or no ' + $Base + ' here), so which rows the base held cannot be read.')
    return @{ Code = 3; Lines = $msgs.ToArray(); Summary = ('files=0 blind=no-merge-base base_ref=' + $Base) }
  }
  $headL = Get-TcRereadBlob -TreeRoot $TreeRoot -Commit 'HEAD'
  $baseL = Get-TcRereadBlob -TreeRoot $TreeRoot -Commit $mbSha
  $files = 0; if ($headL.Present) { $files++ }; if ($baseL.Present) { $files++ }
  $findings = New-Object System.Collections.Generic.List[string]
  if (-not $headL.Present) {
    if ($baseL.Present) {
      [void]$findings.Add(('the ledger ' + $script:RRL_PATH + ' was DELETED: the merge base ' + $mbSha.Substring(0, 9) + ' has it and HEAD does not. A re-read is withdrawn by appending a row, never by removing the file.'))
    } else {
      [void]$msgs.Add('! reread-ledger: COULD NOT EVALUATE - neither HEAD nor the merge base carries ' + $script:RRL_PATH + ', so there is nothing to judge.')
      return @{ Code = 3; Lines = $msgs.ToArray(); Summary = 'files=0 blind=no-ledger' }
    }
  }
  $headRows = 0; $baseRows = 'absent'
  if ($headL.Present) {
    $hs = Split-TcRereadLines -Bytes $headL.Bytes
    $headRows = [Math]::Max(0, @($hs.Lines).Count - 1)
    $shapeR = Test-TcRereadLedgerShape -Bytes $headL.Bytes
    foreach ($s in @($shapeR)) { [void]$findings.Add(('HEAD line {0}: {1}' -f $s.Line, $s.Why)) }
    if ($baseL.Present) {
      $bs = Split-TcRereadLines -Bytes $baseL.Bytes
      $baseRows = [string]([Math]::Max(0, @($bs.Lines).Count - 1))
      $missR = Compare-TcRereadLedgerRows -BaseLines @($bs.Lines) -HeadLines @($hs.Lines)
      foreach ($m in @($missR)) {
        [void]$findings.Add(('base line {0} is not in HEAD''s ledger byte for byte (deleted or edited; a re-read is taken back by appending a withdrawn row): {1}' -f $m.Line, ($m.Text -replace [char]9, ' | ')))
      }
    } else {
      [void]$msgs.Add('  the merge base ' + $mbSha.Substring(0, 9) + ' has no ' + $script:RRL_PATH + ': counted and skipped, so only its shape is judged')
    }
  }
  $sum = ('files={0} rows={1} base_rows={2} findings={3}' -f $files, $headRows, $baseRows, $findings.Count)
  if ($findings.Count) {
    foreach ($f in $findings) { [void]$msgs.Add('  FAIL  ' + $f) }
    [void]$msgs.Add(('reread-ledger: {0} finding(s) in {1}. The ledger is append-only and every row has seven fields; see this file''s header.' -f $findings.Count, $script:RRL_PATH))
    return @{ Code = 2; Lines = $msgs.ToArray(); Summary = $sum }
  }
  [void]$msgs.Add(('  ok    {0}: {1} row(s) at HEAD, {2} at the merge base, every base row kept byte for byte and every row in shape' -f $script:RRL_PATH, $headRows, $baseRows))
  return @{ Code = 0; Lines = $msgs.ToArray(); Summary = $sum }
}

if ($SelfTest) {
  $ran = New-Object System.Collections.Generic.List[string]
  $fails = New-Object System.Collections.Generic.List[string]
  function Case([string]$Label, [string]$Name, [bool]$Ok, [string]$Detail = '') {
    [void]$ran.Add($Name)
    if (-not $Ok) { [void]$fails.Add("$Label $Name") }
    Write-Output ("  {0,-14} {1,-70} {2}" -f $Label, $Name, $(if ($Ok) { 'ok' } else { "FAIL $Detail" }))
  }
  $u8 = New-Object Text.UTF8Encoding($false)
  $TAB = [char]9
  $blobA = 'aaaaaaaaaabbbbbbbbbbccccccccccdddddddddd'
  $blobB = '1111111111222222222233333333334444444444'
  $rowA = 'design/EVAL-a.md' + $TAB + 'ops/h.ps1' + $TAB + $blobA + $TAB + '-' + $TAB + '2026-09-23' + $TAB + 'reread' + $TAB + 'row A still holds'
  $rowB = 'design/EVAL-b.md' + $TAB + 'ops/h.ps1' + $TAB + $blobB + $TAB + $blobA + $TAB + '2026-09-23' + $TAB + 'reread' + $TAB + 'row B still holds'
  function ConvertTo-LedgerBytes([string[]]$Rows, [switch]$NoFinalLf) {
    $body = $script:RRL_HEADER + "`n" + (($Rows | ForEach-Object { $_ + "`n" }) -join '')
    if ($NoFinalLf) { $body = $body.TrimEnd([char]10) }
    return ,([byte[]]$u8.GetBytes($body))
  }

  # ---- the shape rules, pure over bytes ----
  $s1 = Test-TcRereadLedgerShape -Bytes (ConvertTo-LedgerBytes @($rowA, $rowB))
  Case 'MUST NOT FIRE' 'a header and two well-formed rows are in shape: 0 findings over 3 lines' (@($s1).Count -eq 0) ("findings=" + @($s1).Count)
  $six = 'design/EVAL-a.md' + $TAB + 'ops/h.ps1' + $TAB + $blobA + $TAB + '-' + $TAB + '2026-09-23' + $TAB + 'reread'
  $s2 = Test-TcRereadLedgerShape -Bytes (ConvertTo-LedgerBytes @($rowA, $six))
  Case 'MUST FIRE' 'a row with six fields is named by its line (3)' (@($s2).Count -eq 1 -and $s2[0].Line -eq 3 -and $s2[0].Why -match '6 tab-separated') ((@($s2) | ForEach-Object { "$($_.Line):$($_.Why)" }) -join '; ')
  $short = 'design/EVAL-a.md' + $TAB + 'ops/h.ps1' + $TAB + $blobA.Substring(0, 12) + $TAB + '-' + $TAB + '2026-09-23' + $TAB + 'reread' + $TAB + 'a prefix'
  $s3 = Test-TcRereadLedgerShape -Bytes (ConvertTo-LedgerBytes @($short))
  Case 'MUST FIRE' 'a row whose blob is a 12-character prefix is named by its line (2)' (@($s3).Count -eq 1 -and $s3[0].Line -eq 2 -and $s3[0].Why -match 'blob field') ((@($s3) | ForEach-Object { "$($_.Line):$($_.Why)" }) -join '; ')
  $crRow = $rowB + [char]13
  $s4 = Test-TcRereadLedgerShape -Bytes (ConvertTo-LedgerBytes @($rowA, $crRow))
  Case 'MUST FIRE' 'a row carrying a CR is named by its line (3)' (@($s4 | Where-Object { $_.Line -eq 3 -and $_.Why -match 'CR' }).Count -eq 1) ((@($s4) | ForEach-Object { "$($_.Line):$($_.Why)" }) -join '; ')
  $s5 = Test-TcRereadLedgerShape -Bytes (ConvertTo-LedgerBytes @($rowA, $rowB) -NoFinalLf)
  Case 'MUST FIRE' 'a ledger whose last row has no trailing LF is named at that row (3)' (@($s5).Count -eq 1 -and $s5[0].Line -eq 3 -and $s5[0].Why -match 'does not end in LF') ((@($s5) | ForEach-Object { "$($_.Line):$($_.Why)" }) -join '; ')
  $badAct = $rowA.Replace($TAB + 'reread' + $TAB, $TAB + 'Reread' + $TAB)
  $s6 = Test-TcRereadLedgerShape -Bytes (ConvertTo-LedgerBytes @($badAct))
  Case 'MUST FIRE' 'an action outside the closed pair (reread, withdrawn), case-exact, is named' (@($s6).Count -eq 1 -and $s6[0].Why -match 'action') ((@($s6) | ForEach-Object { "$($_.Line):$($_.Why)" }) -join '; ')
  $bomBytes = [byte[]](@(0xEF, 0xBB, 0xBF) + (ConvertTo-LedgerBytes @($rowA)))
  $s7 = Test-TcRereadLedgerShape -Bytes $bomBytes
  Case 'MUST FIRE' 'a ledger that starts with a BOM is named at line 1' (@($s7 | Where-Object { $_.Line -eq 1 -and $_.Why -match 'BOM' }).Count -eq 1) ((@($s7) | ForEach-Object { "$($_.Line):$($_.Why)" }) -join '; ')
  $s8 = Test-TcRereadLedgerShape -Bytes ([byte[]]$u8.GetBytes("doc`tharness`n"))
  Case 'MUST FIRE' 'a first line that is not the seven-field header is named at line 1' (@($s8 | Where-Object { $_.Line -eq 1 -and $_.Why -match 'header' }).Count -eq 1) ((@($s8) | ForEach-Object { "$($_.Line):$($_.Why)" }) -join '; ')
  $s9 = Test-TcRereadLedgerShape -Bytes ([byte[]]$u8.GetBytes($script:RRL_HEADER + "`n"))
  Case 'MUST NOT FIRE' 'the day-one ledger, its header and one LF, is in shape' (@($s9).Count -eq 0) ("findings=" + @($s9).Count)

  # ---- the append-only rule, pure over lines ----
  $baseLines = @($script:RRL_HEADER, $rowA)
  $m1 = Compare-TcRereadLedgerRows -BaseLines $baseLines -HeadLines @($script:RRL_HEADER, $rowA, $rowB)
  Case 'MUST NOT FIRE' 'appended rows only: every base line is still in HEAD, 0 missing' (@($m1).Count -eq 0) ("missing=" + @($m1).Count)
  $m2 = Compare-TcRereadLedgerRows -BaseLines $baseLines -HeadLines @($script:RRL_HEADER, $rowB)
  Case 'MUST FIRE' 'a HEAD ledger missing a base row names it with its base line number (2)' (@($m2).Count -eq 1 -and $m2[0].Line -eq 2 -and $m2[0].Text -ceq $rowA) ("missing=" + @($m2).Count)
  $rowAEdited = $rowA.Replace('row A still holds', 'row A still holds, mostly')
  $m3 = Compare-TcRereadLedgerRows -BaseLines $baseLines -HeadLines @($script:RRL_HEADER, $rowAEdited, $rowB)
  Case 'MUST FIRE' 'an EDITED row is missing byte for byte, even with its edit beside it' (@($m3).Count -eq 1 -and $m3[0].Line -eq 2) ("missing=" + @($m3).Count)

  # ---- the live path, and the union merge, in temp repositories ----
  . (Join-Path $repo 'lib\git-repo-env.ps1')
  Clear-TcGitRepoEnv
  $lt = Join-Path $env:TEMP ('rrl-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Path $lt -ErrorAction Stop | Out-Null
  function Invoke-FixGit([string]$Dir, [string[]]$GitArgs) {
    $r = Invoke-GitCaptured -Repo $Dir -GitArgs $GitArgs
    if ($r.rc -ne 0) { throw ("fixture git failed (rc {0}): git {1}: {2}" -f $r.rc, ($GitArgs -join ' '), $r.stderr) }
    return ([string]$r.stdout).Trim()
  }
  function New-FixRepo([string]$Name) {
    $d = Join-Path $lt $Name
    [void][IO.Directory]::CreateDirectory((Join-Path $d 'design'))
    $null = Invoke-FixGit $d @('-c', 'init.defaultBranch=main', 'init', '-q')
    $null = Invoke-FixGit $d @('config', 'user.name', 'Fixture')
    $null = Invoke-FixGit $d @('config', 'user.email', 't@t')
    $null = Invoke-FixGit $d @('config', 'commit.gpgsign', 'false')
    # THIS REPO'S OWN ATTRIBUTES, so the union case below judges the line that ships, not a copy of it.
    Copy-Item -LiteralPath (Join-Path $repo '.gitattributes') -Destination (Join-Path $d '.gitattributes')
    return $d
  }
  function Set-FixLedger([string]$Dir, [string[]]$Rows) {
    [IO.File]::WriteAllText((Join-Path $Dir 'design\reread-ledger.tsv'), ($script:RRL_HEADER + "`n" + (($Rows | ForEach-Object { $_ + "`n" }) -join '')), $u8)
  }
  function Save-FixCommit([string]$Dir, [string]$Msg, [string[]]$Paths = @('design/reread-ledger.tsv')) {
    $null = Invoke-FixGit $Dir (@('add', '--') + $Paths)
    $null = Invoke-FixGit $Dir @('commit', '-q', '-m', $Msg)
    return (Invoke-FixGit $Dir @('rev-parse', 'HEAD'))
  }
  function Invoke-FixAudit([string]$Dir, [string[]]$More = @()) {
    $o = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Root $Dir @More)
    $rc = $LASTEXITCODE
    $mk = @($o | Where-Object { "$_" -match '^REREAD-LEDGER-COMPLETE\b' })
    return @{ Rc = $rc; Out = ($o -join "`n"); Mark = $(if ($mk.Count) { [string]$mk[$mk.Count - 1] } else { '' }) }
  }
  try {
    # A: the base carries the header and row A, and origin/main names it.
    $ra = New-FixRepo 'a'
    Set-FixLedger $ra @($rowA)
    $baseSha = Save-FixCommit $ra 'base' @('.gitattributes', 'design/reread-ledger.tsv')
    $null = Invoke-FixGit $ra @('update-ref', 'refs/remotes/origin/main', $baseSha)
    Set-FixLedger $ra @($rowA, $rowB)
    $null = Save-FixCommit $ra 'append'
    $a1 = Invoke-FixAudit $ra
    Case 'CLEAN TWIN' 'LIVE: a push that only APPENDS a row exits 0, and its marker counts 2 files, 2 rows, 1 base row' ($a1.Rc -eq 0 -and $a1.Mark -match '\bfiles=2 rows=2 base_rows=1 findings=0\b') ("rc=$($a1.Rc) mark=[$($a1.Mark)]")
    Set-FixLedger $ra @($rowB)
    $null = Save-FixCommit $ra 'delete row A'
    $a2 = Invoke-FixAudit $ra
    Case 'MUST FIRE' 'LIVE: a push that DELETES a base row exits 2 and names the row' ($a2.Rc -eq 2 -and $a2.Out -match 'base line 2 is not in HEAD' -and $a2.Out -match 'row A still holds') ("rc=$($a2.Rc) mark=[$($a2.Mark)]")
    Set-FixLedger $ra @($rowAEdited, $rowB)
    $null = Save-FixCommit $ra 'edit row A'
    $a3 = Invoke-FixAudit $ra
    Case 'MUST FIRE' 'LIVE: a push that EDITS a base row exits 2 and names the original' ($a3.Rc -eq 2 -and $a3.Out -match 'base line 2 is not in HEAD') ("rc=$($a3.Rc) mark=[$($a3.Mark)]")
    Set-FixLedger $ra @($rowA, $six)
    $null = Save-FixCommit $ra 'six fields'
    $a4 = Invoke-FixAudit $ra
    Case 'MUST FIRE' 'LIVE: a committed row with six fields exits 2 and names HEAD line 3' ($a4.Rc -eq 2 -and $a4.Out -match 'HEAD line 3: the row has 6 tab-separated') ("rc=$($a4.Rc) mark=[$($a4.Mark)]")
    $a5 = Invoke-FixAudit $ra @('-BaseRef', 'origin/nope')
    Case 'MUST FIRE' 'LIVE: an unresolvable base exits 3 with blind=no-merge-base' ($a5.Rc -eq 3 -and $a5.Mark -match '\bblind=no-merge-base\b') ("rc=$($a5.Rc) mark=[$($a5.Mark)]")
    # B: no origin/main at all, the sandbox shape, on the DEFAULT base ref.
    $rb = New-FixRepo 'b'
    Set-FixLedger $rb @()
    $null = Save-FixCommit $rb 'only' @('.gitattributes', 'design/reread-ledger.tsv')
    $b1 = Invoke-FixAudit $rb
    Case 'MUST FIRE' 'LIVE: a checkout with no origin/main, on the default base, exits 3 blind=no-merge-base' ($b1.Rc -eq 3 -and $b1.Mark -match '\bblind=no-merge-base\b') ("rc=$($b1.Rc) mark=[$($b1.Mark)]")
    # C: the landing shape - the base has no ledger, HEAD adds it as its header.
    $rc0 = New-FixRepo 'c'
    [IO.File]::WriteAllText((Join-Path $rc0 'design\README.md'), "base`n", $u8)
    $cBase = Save-FixCommit $rc0 'base without a ledger' @('.gitattributes', 'design/README.md')
    $null = Invoke-FixGit $rc0 @('update-ref', 'refs/remotes/origin/main', $cBase)
    Set-FixLedger $rc0 @()
    $null = Save-FixCommit $rc0 'add the ledger'
    $c1 = Invoke-FixAudit $rc0
    Case 'CLEAN TWIN' 'LIVE: the push that ADDS the ledger as its header exits 0, base_rows=absent, 1 file read' ($c1.Rc -eq 0 -and $c1.Mark -match '\bfiles=1 rows=0 base_rows=absent findings=0\b') ("rc=$($c1.Rc) mark=[$($c1.Mark)]")

    # U: THE UNION MERGE (the plan's hard stop). Two branches append different rows; a plain rebase must keep both with
    # no conflict, and so must the bot's shape, `git -c rebase.autoStash=true rebase -X theirs`, over a dirty tree.
    $ru = New-FixRepo 'u'
    [IO.File]::WriteAllText((Join-Path $ru 'design\notes.md'), "notes`n", $u8)
    Set-FixLedger $ru @()
    $null = Save-FixCommit $ru 'header' @('.gitattributes', 'design/notes.md', 'design/reread-ledger.tsv')
    $null = Invoke-FixGit $ru @('checkout', '-q', '-b', 'lane')
    $rowL1 = 'design/EVAL-l.md' + $TAB + 'ops/l.ps1' + $TAB + $blobA + $TAB + '-' + $TAB + '2026-09-23' + $TAB + 'reread' + $TAB + 'lane row one'
    $rowM1 = 'design/EVAL-m.md' + $TAB + 'ops/m.ps1' + $TAB + $blobB + $TAB + '-' + $TAB + '2026-09-23' + $TAB + 'reread' + $TAB + 'main row one'
    Set-FixLedger $ru @($rowL1)
    $null = Save-FixCommit $ru 'lane appends'
    $null = Invoke-FixGit $ru @('checkout', '-q', 'main')
    Set-FixLedger $ru @($rowM1)
    $null = Save-FixCommit $ru 'main appends'
    $null = Invoke-FixGit $ru @('checkout', '-q', 'lane')
    $u1 = Invoke-GitCaptured -Repo $ru -GitArgs @('rebase', 'main')
    $gd = Invoke-FixGit $ru @('rev-parse', '--git-dir')
    $gdFull = if ([IO.Path]::IsPathRooted($gd)) { $gd } else { Join-Path $ru $gd }
    $midRebase = (Test-Path -LiteralPath (Join-Path $gdFull 'rebase-merge')) -or (Test-Path -LiteralPath (Join-Path $gdFull 'rebase-apply'))
    $uLines1 = @((Split-TcRereadLines -Bytes (Get-CommittedBlobBytes -Repo $ru -Spec 'HEAD:design/reread-ledger.tsv')).Lines)
    Case 'MUST FIRE' 'UNION: a plain rebase of two branches that each appended a row keeps BOTH rows, with no conflict and no rebase left open' `
      ($u1.rc -eq 0 -and -not $midRebase -and $uLines1.Count -eq 3 -and ($uLines1 -ccontains $rowL1) -and ($uLines1 -ccontains $rowM1)) ("rc=$($u1.rc) mid=$midRebase lines=$($uLines1.Count) err=" + ([string]$u1.stderr).Trim())
    $null = Invoke-FixGit $ru @('checkout', '-q', 'main')
    $rowM2 = 'design/EVAL-m.md' + $TAB + 'ops/m.ps1' + $TAB + $blobA + $TAB + $blobB + $TAB + '2026-09-23' + $TAB + 'reread' + $TAB + 'main row two'
    Set-FixLedger $ru @($rowM1, $rowM2)
    $null = Save-FixCommit $ru 'main appends again'
    $null = Invoke-FixGit $ru @('checkout', '-q', 'lane')
    $rowL2 = 'design/EVAL-l.md' + $TAB + 'ops/l.ps1' + $TAB + $blobB + $TAB + $blobA + $TAB + '2026-09-23' + $TAB + 'withdrawn' + $TAB + 'lane row two'
    $laneNow = @((Split-TcRereadLines -Bytes (Get-CommittedBlobBytes -Repo $ru -Spec 'HEAD:design/reread-ledger.tsv')).Lines | Select-Object -Skip 1)
    Set-FixLedger $ru @($laneNow + $rowL2)
    $null = Save-FixCommit $ru 'lane appends again'
    # A dirty tracked file, so autoStash has something to stash and restore around the rebase.
    [IO.File]::WriteAllText((Join-Path $ru 'design\notes.md'), "notes, edited and not committed`n", $u8)
    $u2 = Invoke-GitCaptured -Repo $ru -GitArgs @('-c', 'rebase.autoStash=true', 'rebase', '-X', 'theirs', 'main')
    $midRebase2 = (Test-Path -LiteralPath (Join-Path $gdFull 'rebase-merge')) -or (Test-Path -LiteralPath (Join-Path $gdFull 'rebase-apply'))
    $uBytes2 = Get-CommittedBlobBytes -Repo $ru -Spec 'HEAD:design/reread-ledger.tsv'
    $cr2 = 0; foreach ($x in $uBytes2) { if ($x -eq 13) { $cr2++ } }
    $uLines2 = @((Split-TcRereadLines -Bytes $uBytes2).Lines)
    $allFour = ($uLines2 -ccontains $rowL1) -and ($uLines2 -ccontains $rowM1) -and ($uLines2 -ccontains $rowM2) -and ($uLines2 -ccontains $rowL2)
    $stashBack = [IO.File]::ReadAllText((Join-Path $ru 'design\notes.md')).StartsWith('notes, edited', [StringComparison]::Ordinal)
    Case 'MUST FIRE' 'UNION under the BOT''s shape (autoStash, -X theirs): all four appended rows kept, 0 CR in the blob, the dirty file restored' `
      ($u2.rc -eq 0 -and -not $midRebase2 -and $uLines2.Count -eq 5 -and $allFour -and $cr2 -eq 0 -and $stashBack) ("rc=$($u2.rc) mid=$midRebase2 lines=$($uLines2.Count) all4=$allFour cr=$cr2 stash=$stashBack err=" + ([string]$u2.stderr).Trim())
    $shapeU = Test-TcRereadLedgerShape -Bytes $uBytes2
    Case 'MUST NOT FIRE' 'UNION: the merged ledger is still in shape - the union glued no two rows together' (@($shapeU).Count -eq 0 -and $uLines2.Count -eq 5) ("findings=" + @($shapeU).Count)
  } catch {
    # A fixture step that threw is a counted failure with its reason, never a suite that stops before its verdict.
    [void]$fails.Add('LIVE FIXTURES threw before finishing: ' + $_.Exception.Message)
    Write-Output ('  FAIL  the live fixtures threw: ' + $_.Exception.Message)
  } finally {
    Remove-Item -LiteralPath $lt -Recurse -Force -ErrorAction SilentlyContinue
  }

  # ---- this repo's own attributes: the union line names the ledger, and nothing else is merged by union ----
  $gaLines = @([IO.File]::ReadAllLines((Join-Path $repo '.gitattributes')) | Where-Object { -not $_.TrimStart().StartsWith('#', [StringComparison]::Ordinal) -and $_ -match '\bmerge=union\b' })   # .gitattributes comments, not PowerShell
  Case 'CLEAN TWIN' 'this repo''s .gitattributes gives design/reread-ledger.tsv merge=union' (@($gaLines | Where-Object { $_.Trim() -ceq ('design/reread-ledger.tsv' + ' merge=union') }).Count -eq 1) ($gaLines -join ' | ')
  Case 'MUST NOT FIRE' 'no other path in this repo''s .gitattributes is merged by union (a document merged by union interleaves prose)' ($gaLines.Count -eq 1) ($gaLines -join ' | ')

  $expectedCases = 24
  if ($ran.Count -ne $expectedCases) { [void]$fails.Add(("CASE COUNT ran {0} of the {1} cases written in this file" -f $ran.Count, $expectedCases)) }
  Write-Output ''
  if ($fails.Count) {
    Write-Output ("audit-reread-ledger selftest: {0} FAILED of {1}" -f $fails.Count, $ran.Count)
    $fails | ForEach-Object { Write-Output "  $_" }
    Exit-Guard -Name 'REREAD-LEDGER-SELFTEST' -Code 1 -Summary "failed=$($fails.Count) cases=$($ran.Count)"
  }
  Write-Output ("audit-reread-ledger selftest: {0} of {0} cases pass" -f $ran.Count)
  Exit-Guard -Name 'REREAD-LEDGER-SELFTEST' -Code 0 -Summary "cases=$($ran.Count)"
}

# ------------------------------------------------------------------------------------------------ live
$treeRoot = if ($Root) { $Root } else { $repo }
Write-Output ('REREAD LEDGER - does ' + $script:RRL_PATH + ' only grow, with every row in shape?')
$res = Invoke-TcRereadLedgerAudit -TreeRoot $treeRoot -Base $BaseRef
foreach ($l in @($res.Lines)) { Write-Output $l }
Exit-Guard -Name 'REREAD-LEDGER' -Code $res.Code -Summary $res.Summary
