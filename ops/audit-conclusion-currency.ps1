<#
  audit-conclusion-currency.ps1 - a recorded conclusion whose harness has moved since is UNQUALIFIED.

  WS 7d of design\PLAN-brain-v2-2026-09-09.md.

  THE SHAPE. .claude\rules\measurement.md: "name the harness and the commit it ran at". A moved harness
  does not make a verdict wrong; it makes it UNQUALIFIED until somebody re-reads it. This estate has
  paid for that twice - a 30.9-vs-41.7-minute verdict that reverted a working parallel path, and a
  wall-clock EVAL that was arithmetically true and causally wrong - and both were caught by a person
  re-reading a commit clock months later, by luck. ops\audit-measurement-provenance.ps1 makes a
  document NAME its harness and commit. Nothing checked whether that harness had moved since. This is
  the back-link.

  WHAT IT READS. design\EVAL-*.md and design\MEASURE-*.md, the population the provenance audit owns.
    a HARNESS       a repo path to a .ps1 or .py on a line that says harness, measured through, ran
                    through, or generated ... by - and that exists.
    a CITED COMMIT  a hash on a line that says commit or blob, which git resolves to a commit.
    a CONTENT ID    a hash on such a line that names a blob or tree: listed, never read as a commit.
    an UNRESOLVED   a hash on such a line that names no object: counted on the marker and listed, not ratcheted.
  UNQUALIFIED when a named harness has a commit after the NEWEST cited commit, unless the document cites
  that harness's CURRENT blob. To re-qualify, re-read the conclusion against the moved harness and add
      Re-read at harness blob <git rev-parse HEAD:<path>> (<path>): <what still holds>
  THE BLOB FORM IS THE ONE TO USE (backlog I228, 2026-09-18). The older form, "Re-read at commit <hash>",
  still qualifies a harness when the hash is a commit at or after its last change, but the commit you
  would cite is your own, and ops\push-main.ps1 rebases it into a different id before it lands: the line
  then cites a commit main never holds. A blob id is content, so no rebase can move it. A blob from
  before the harness last changed is not its current blob and qualifies nothing.

  A RATCHET on the UNQUALIFIED count (lib\ratchet.ps1). The baseline was every qualifiable document on
  the day this shipped, so it fires only when a conclusion that WAS current goes stale in a push. A
  document naming no harness or no resolvable commit is NOT QUALIFIABLE: that is the provenance audit's
  finding, listed here and not counted twice.

  SCOPE OF A CLEAN REPORT: UNSOUND. It finds harnesses by the words on their line and commits by
  spelling. A conclusion whose harness is named in prose it does not recognise is NOT QUALIFIABLE, not
  current, and a moved harness that changed no behaviour still reads UNQUALIFIED - which is correct,
  because deciding that it changed nothing IS the re-read.

  A RUN THAT IS NOT ASKED TO RECORD WRITES NOTHING (2026-09-11). run-gates runs this with no arguments on every
  pre-push, and a fall used to rewrite the TRACKED baseline right there: the pushing checkout was left dirty, the
  lower mark never rode that push, and a count taken over uncommitted edits is not a baseline. So a fall is SPOKEN
  and the committed mark KEPT; -Tighten records it. ops\audit-write-only-reports.ps1 carries the full account.

    ops\audit-conclusion-currency.ps1              judge the documents, hold the ratchet; writes nothing
    ops\audit-conclusion-currency.ps1 -Tighten     the same, and record a believable FALL as the new high-water mark
    ops\audit-conclusion-currency.ps1 -Accept      record the CURRENT count as the new high-water mark
    ops\audit-conclusion-currency.ps1 -SelfTest    frozen fixtures, plus this script's live path run against a temp repository

  THE BASELINE FAILS CLOSED (2026-09-23, W1.2 of design\PLAN-push-derived-conflicts-2026-09-23.md). A baseline is
  READ (it parses and carries an integer `unqualified`), ABSENT (no file) or UNREADABLE (a parse error, conflict
  markers from a botched hand resolution, or no integer `unqualified`). Until this change an absent or unreadable
  baseline became $null, and `-Accept -or $null` then WROTE the current count as the new mark and exited 0 on a plain
  run: a damaged baseline silently accepted whatever count the push carried, a rise included. Now a plain run and
  -Tighten over an ABSENT or UNREADABLE baseline write nothing and exit 3 (blind=baseline-missing or
  blind=baseline-unreadable, with the path), and print a line starting with `!` so run-gates' excerpt filter shows it
  under the FAIL line. Only -Accept writes a baseline that could not be read, because recording a mark is a decision
  a person makes after looking. run-gates scores any non-zero static exit as a FAIL, 3 included, so the whole run
  exits 1 and pre-push refuses; the push ledger row reads refused-gate-red. On a READ baseline -Tighten and -Accept
  behave exactly as before.

  EXIT: 0 held, tightened or able to tighten, 2 the count rose or -Tighten refused an implausible fall, 3 could not
  evaluate (no documents, no git, or a baseline that is absent or unreadable on a run that is not -Accept).
#>
[CmdletBinding()]
param([switch]$SelfTest, [switch]$Json, [switch]$Accept, [switch]$ReportOnly, [switch]$Tighten, [string]$Root = '', [string]$BaselineFile = '')

$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\ops' }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $repo 'lib\ratchet.ps1')

# -Root and -BaselineFile exist so the self-test can drive the LIVE path against a temp repository. A gate passes neither.
$treeRoot = if ($Root) { $Root } else { $repo }

$script:HARNESS_LINE = '(?i)\b(harness|measured through|ran through|generated\b.{0,80}\bby)\b'
# A line that says BLOB is read too (backlog I228), because the rebase-proof re-read line cites a blob and need not
# say "commit" at all.
$script:COMMIT_LINE  = '(?i)\b(commit|blob)\b'
$script:PATH_RX = '(?<![\w/\\.-])((?:ops|grocery|graph|meal-prep|sidecar|lib|tools)[\\/][A-Za-z0-9_.\\/-]+?\.(?:ps1|py))(?![\w])'
$script:HASH_RX = '(?<![0-9A-Za-z])([0-9a-f]{7,40})(?![0-9A-Za-z])'

function Get-HarnessPaths {
  <# Repo-relative harness paths named on a harness line OR THE LINE AFTER IT, forward slashes, de-duplicated.

     THE LINE AFTER, because the first live run read EVAL-alert-retention-2026-09-09.md as naming no
     harness: its line 6 is "**Harness and commit** (per ...): the snapshot producer is" and the path
     wraps onto line 7. Markdown prose wraps at a column, not at a sentence. #>
  param([string]$Text)
  $out = New-Object System.Collections.Generic.List[string]
  $all = $Text -split "`r?`n"
  for ($i = 0; $i -lt $all.Count; $i++) {
    if ($all[$i] -notmatch $script:HARNESS_LINE) { continue }
    $line = $all[$i]
    if ($i + 1 -lt $all.Count) { $line = $line + ' ' + $all[$i + 1] }
    foreach ($m in [regex]::Matches($line, $script:PATH_RX)) {
      $p = $m.Groups[1].Value -replace '\\', '/'
      if (-not $out.Contains($p)) { [void]$out.Add($p) }
    }
  }
  $arr = $out.ToArray()
  return ,$arr
}

function Get-CitedHashes {
  <# Hash-shaped tokens on a commit line. A token must carry a letter AND a digit: a date, a count and a
     word like "accede" all fail that, and an all-digit hash is rare enough to be named by hand. #>
  param([string]$Text)
  $out = New-Object System.Collections.Generic.List[string]
  $all = $Text -split "`r?`n"
  for ($i = 0; $i -lt $all.Count; $i++) {
    if ($all[$i] -notmatch $script:COMMIT_LINE) { continue }
    # The line after as well, for the same reason Get-HarnessPaths reads it: EVAL-alert-retention-2026-09-09.md
    # writes "The commit that introduced both is" and puts **`60e944660`** at the start of the next line.
    $line = $all[$i]
    if ($i + 1 -lt $all.Count) { $line = $line + ' ' + $all[$i + 1] }
    foreach ($m in [regex]::Matches($line, $script:HASH_RX)) {
      $h = $m.Groups[1].Value
      # EXACTLY 32 HEX IS AN MD5, never a git id (2026-09-18). MEASURE-event-bus-concurrent-append-2026-09-11.md
      # writes "The new arm is md5 `b11149f3...`" on the line after a commit line, and nobody abbreviates a git
      # hash to 32 characters. Without this it would read as a cited hash git cannot resolve.
      if ($h.Length -eq 32) { continue }
      if ($h -cmatch '[a-f]' -and $h -match '[0-9]' -and -not $out.Contains($h)) { [void]$out.Add($h) }
    }
  }
  $arr = $out.ToArray()
  return ,$arr
}

function Get-CurrencyVerdict {
  <# @{ Verdict = CURRENT | UNQUALIFIED | NOT-QUALIFIABLE; Moved = @(@{Path; After; Since}); Why; Content; Unresolved }.
     Pure over its scriptblocks, so the fixtures never touch git.

     EVERY CITED HASH IS CLASSIFIED, NOT ONLY TESTED FOR BEING A COMMIT (2026-09-18). -HashType answers 'commit',
     'content' (a blob or tree id) or 'none' (git has no object by that name, or the short name is ambiguous).
     Until then one rev-parse "<hash>^{commit}" answered yes or no, so the three cases were one: measurement.md
     (2026-09-11) asks a document to cite each file's BLOB beside the commit, because a rebase cannot move a blob,
     and a cited blob was dropped exactly like a hash that names nothing - with git's own "expected commit type,
     but the object dereferences to blob type" on stderr as the only trace, printed to every push-main console and
     into no log. A content id is deliberately NOT a commit citation (it says what a file held, not when), so it
     never qualifies a document; it is counted and listed. A hash that resolves to nothing is counted and listed
     too, and is NOT a gate: an unreachable commit leaves the object store on git's clock, not in the push that
     is being gated, so a red on it would refuse a push that did not cause it. #>
  <# A CITED BLOB THAT IS THE HARNESS'S CURRENT CONTENT RE-QUALIFIES IT (2026-09-18, backlog I228). push-main rebases,
     so a "Re-read at commit <X>" line written before the push cites a commit that never reaches main: the re-read
     was real and the line naming it pointed at nothing. A blob id cannot be renamed by a rebase. -CurrentBlob answers
     a harness path's blob at HEAD (git rev-parse HEAD:<path>), and a cited content id that the current blob starts
     with qualifies THAT harness exactly as a cited commit at or after its last change would. A blob from before the
     harness last changed matches nothing and qualifies nothing, so a stale re-read stays stale. #>
  param([string[]]$Paths, [string[]]$Hashes, [scriptblock]$HashType, [scriptblock]$PathExists, [scriptblock]$After, [scriptblock]$CurrentBlob = { param($p) '' })
  $real = New-Object System.Collections.Generic.List[string]
  $content = New-Object System.Collections.Generic.List[string]
  $unres = New-Object System.Collections.Generic.List[string]
  foreach ($h in @($Hashes)) {
    if (-not $h) { continue }
    $t = [string](& $HashType $h)
    if ($t -ceq 'commit') { [void]$real.Add($h) }
    elseif ($t -ceq 'content') { [void]$content.Add($h) }
    else { [void]$unres.Add($h) }
  }
  $ca = $content.ToArray(); $ua = $unres.ToArray()
  $hp = @(@($Paths) | Where-Object { $_ -and (& $PathExists $_) })
  if ($hp.Count -eq 0) { return @{ Verdict = 'NOT-QUALIFIABLE'; Moved = @(); Why = 'names no harness that exists'; Content = $ca; Unresolved = $ua; BlobRead = @() } }
  $blobRead = New-Object System.Collections.Generic.List[string]
  foreach ($p in $hp) {
    $cb = ([string](& $CurrentBlob $p)).Trim().ToLowerInvariant()
    if (-not $cb) { continue }
    foreach ($c in $ca) {
      if ($cb.StartsWith($c.ToLowerInvariant(), [StringComparison]::Ordinal)) { [void]$blobRead.Add($p); break }
    }
  }
  $ba = $blobRead.ToArray()
  if ($real.Count -eq 0) {
    if ($ba.Count -eq $hp.Count) { return @{ Verdict = 'CURRENT'; Moved = @(); Why = ''; Content = $ca; Unresolved = $ua; BlobRead = $ba } }
    $why = 'cites no commit git can resolve'
    if ($ca.Count -or $ua.Count) { $why += (' ({0} blob or tree id(s), {1} hash(es) naming no object)' -f $ca.Count, $ua.Count) }
    return @{ Verdict = 'NOT-QUALIFIABLE'; Moved = @(); Why = $why; Content = $ca; Unresolved = $ua; BlobRead = $ba }
  }
  $moved = New-Object System.Collections.Generic.List[object]
  foreach ($p in $hp) {
    if ($blobRead.Contains($p)) { continue }
    $min = $null; $since = ''
    foreach ($h in $real) {
      $n = [int](& $After $h $p)
      if ($null -eq $min -or $n -lt $min) { $min = $n; $since = $h }
    }
    if ($min -gt 0) { [void]$moved.Add(@{ Path = $p; After = $min; Since = $since }) }
  }
  if ($moved.Count -gt 0) { return @{ Verdict = 'UNQUALIFIED'; Moved = $moved.ToArray(); Why = ''; Content = $ca; Unresolved = $ua; BlobRead = $ba } }
  return @{ Verdict = 'CURRENT'; Moved = @(); Why = ''; Content = $ca; Unresolved = $ua; BlobRead = $ba }
}

function Read-CcBaseline {
  <# The ratchet baseline as @{ State = read | absent | unreadable; Value; Why } (W1.2, 2026-09-23). READ only when the
     file parses as a JSON object carrying `unqualified` as a non-negative integer. Anything else is UNREADABLE with
     the reason, and no file at all is ABSENT: the caller refuses both unless it was asked to -Accept. A JSON number
     with a fraction, a quoted "4" and a missing field are all unreadable, because a mark nobody can read exactly is
     not a mark. #>
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @{ State = 'absent'; Value = $null; Why = 'no such file' } }
  $doc = $null
  try { $doc = [IO.File]::ReadAllText($Path) | ConvertFrom-Json } catch { return @{ State = 'unreadable'; Value = $null; Why = 'it does not parse as JSON' } }
  if ($null -eq $doc -or $doc -is [array] -or $doc -is [string] -or $doc -is [ValueType]) { return @{ State = 'unreadable'; Value = $null; Why = 'it is not a JSON object' } }
  $prop = $doc.PSObject.Properties['unqualified']
  if (-not $prop) { return @{ State = 'unreadable'; Value = $null; Why = 'it has no unqualified field' } }
  $v = $prop.Value
  if (-not ($v -is [int] -or $v -is [long]) -or $v -lt 0 -or $v -gt [int]::MaxValue) {
    return @{ State = 'unreadable'; Value = $null; Why = ('its unqualified field is not a non-negative integer: ' + [string]$v) }
  }
  return @{ State = 'read'; Value = [int]$v; Why = '' }
}

if ($SelfTest) {
  $ran = New-Object System.Collections.Generic.List[string]
  $fails = New-Object System.Collections.Generic.List[string]
  function Case([string]$Label, [string]$Name, [bool]$Ok, [string]$Detail = '') {
    [void]$ran.Add($Name)
    if (-not $Ok) { [void]$fails.Add("$Label $Name") }
    Write-Output ("  {0,-14} {1,-66} {2}" -f $Label, $Name, $(if ($Ok) { 'ok' } else { "FAIL $Detail" }))
  }
  $yes = { param($x) $true }
  $no = { param($x) $false }
  $isCommit = { param($x) 'commit' }
  $isNone = { param($x) 'none' }

  $t1 = 'Harness: grocery/guards.ps1, run three times.'
  $hp1 = Get-HarnessPaths -Text $t1
  $p1 = @($hp1)
  Case 'MUST FIRE' 'a script named on a harness line is the harness' ($p1.Count -eq 1 -and $p1[0] -eq 'grocery/guards.ps1') ($p1 -join ',')
  $t2 = 'Commit it ran at: 47150b330.'
  $hh2 = Get-CitedHashes -Text $t2
  $h2 = @($hh2)
  Case 'MUST FIRE' 'a hash on a commit line is a cited commit' ($h2.Count -eq 1 -and $h2[0] -eq '47150b330') ($h2 -join ',')
  $v3 = Get-CurrencyVerdict -Paths @('grocery/guards.ps1') -Hashes @('47150b330') -HashType $isCommit -PathExists $yes -After { param($h, $p) 2 }
  Case 'MUST FIRE' 'a harness with commits after the cited one is UNQUALIFIED' ($v3.Verdict -eq 'UNQUALIFIED' -and $v3.Moved[0].After -eq 2) $v3.Verdict

  $tw = "**Harness and commit** (per the rule): the snapshot producer is`n``ops/member-cohorts.ps1``, run nightly."
  $hpw = Get-HarnessPaths -Text $tw
  $pw = @($hpw)
  Case 'MUST FIRE' 'a harness path wrapped onto the line after the harness line is still found' ($pw.Count -eq 1 -and $pw[0] -eq 'ops/member-cohorts.ps1') ($pw -join ',')
  $t5 = "We then looked at grocery/check-ad-cycles.ps1 for a while.`n`nAnd later at ops/run-gates.ps1 too."
  $hp5 = Get-HarnessPaths -Text $t5
  $p5 = @($hp5)
  Case 'MUST NOT FIRE' 'a script named in prose, not on a harness line, is not a harness' ($p5.Count -eq 0) ($p5 -join ',')
  $hhw = Get-CitedHashes -Text "The commit that introduced both is`n**``60e944660``**, dated 2026-09-09."
  $hw = @($hhw)
  Case 'MUST FIRE' 'a hash wrapped onto the line after the commit line is still cited' ($hw.Count -eq 1 -and $hw[0] -eq '60e944660') ($hw -join ',')
  $hh6 = Get-CitedHashes -Text 'The commit landed on 2026-09-09 after 1630 seconds, and the fix was accede.'
  $h6 = @($hh6)
  Case 'MUST NOT FIRE' 'a date, a count and a hex-letter word on a commit line are not hashes' ($h6.Count -eq 0) ($h6 -join ',')
  $v7 = Get-CurrencyVerdict -Paths @('grocery/guards.ps1') -Hashes @('abc1234') -HashType $isNone -PathExists $yes -After { param($h, $p) 9 }
  Case 'MUST NOT FIRE' 'a hash git cannot resolve leaves the document NOT QUALIFIABLE, not unqualified' ($v7.Verdict -eq 'NOT-QUALIFIABLE') $v7.Verdict
  $v8 = Get-CurrencyVerdict -Paths @('grocery/gone.ps1') -Hashes @('abc1234') -HashType $isCommit -PathExists $no -After { param($h, $p) 9 }
  Case 'MUST NOT FIRE' 'a harness path that does not exist is not a harness' ($v8.Verdict -eq 'NOT-QUALIFIABLE') $v8.Verdict
  $hh9 = Get-CitedHashes -Text 'See commit deadbeef and commit 12345678.'
  $h9 = @($hh9)
  Case 'MUST NOT FIRE' 'all-letter and all-digit tokens are not taken as hashes' ($h9.Count -eq 0) ($h9 -join ',')

  $v10 = Get-CurrencyVerdict -Paths @('ops/run-gates.ps1') -Hashes @('679a153') -HashType $isCommit -PathExists $yes -After { param($h, $p) 0 }
  Case 'CLEAN TWIN' 'an unmoved harness is CURRENT' ($v10.Verdict -eq 'CURRENT') $v10.Verdict
  $after = { param($h, $p) if ($h -eq 'aaa1111') { 5 } else { 0 } }
  $v11 = Get-CurrencyVerdict -Paths @('ops/run-gates.ps1') -Hashes @('aaa1111', 'bbb2222') -HashType $isCommit -PathExists $yes -After $after
  Case 'CLEAN TWIN' 'a re-read line citing a NEWER commit re-qualifies the conclusion' ($v11.Verdict -eq 'CURRENT') $v11.Verdict
  $hp12 = Get-HarnessPaths -Text 'Measured through meal-prep\pipeline\hunt-run.ps1 at width 4.'
  $p12 = @($hp12)
  Case 'CLEAN TWIN' 'a backslash path is read and normalised to forward slashes' ($p12.Count -eq 1 -and $p12[0] -eq 'meal-prep/pipeline/hunt-run.ps1') ($p12 -join ',')
  $docs = @(Get-ChildItem (Join-Path $repo 'design') -File -Filter '*.md' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like 'EVAL-*' -or $_.Name -like 'MEASURE-*' })
  Case 'CLEAN TWIN' 'the population is the EVAL-* and MEASURE-* documents, and it is not empty' ($docs.Count -gt 0) "$($docs.Count)"

  # A CITED BLOB IS CONTENT, NOT A COMMIT, AND A HASH NAMING NOTHING IS COUNTED (2026-09-18). The founding line is
  # MEASURE-event-bus-concurrent-append-2026-09-11.md:62, "blob `1128546c`" on a commit line.
  $kind13 = { param($x) switch ($x) { 'b10b111' { 'content' } 'c0ffee1' { 'commit' } default { 'none' } } }
  $v13 = Get-CurrencyVerdict -Paths @('ops/run-gates.ps1') -Hashes @('b10b111', 'c0ffee1', 'dead123') -HashType $kind13 -PathExists $yes -After { param($h, $p) if ($h -eq 'c0ffee1') { 0 } else { 7 } }
  Case 'MUST FIRE' 'a cited blob id is listed as content and a hash naming no object is listed as unresolved' `
    (@($v13.Content).Count -eq 1 -and $v13.Content[0] -eq 'b10b111' -and @($v13.Unresolved).Count -eq 1 -and $v13.Unresolved[0] -eq 'dead123') `
    ("content=" + (@($v13.Content) -join ',') + " unresolved=" + (@($v13.Unresolved) -join ','))
  Case 'CLEAN TWIN' 'the commit beside that blob still decides the verdict, and the blob is never read as the cited commit' ($v13.Verdict -eq 'CURRENT') $v13.Verdict
  $v14 = Get-CurrencyVerdict -Paths @('ops/run-gates.ps1') -Hashes @('b10b111') -HashType $kind13 -PathExists $yes -After { param($h, $p) 0 }
  Case 'MUST FIRE' 'a document citing ONLY a blob is not qualifiable, and its reason names the blob' ($v14.Verdict -eq 'NOT-QUALIFIABLE' -and $v14.Why -match '1 blob or tree id') ($v14.Verdict + ' / ' + $v14.Why)
  $md5a = 'b11149f3e9bb71ef'; $md5b = '71628296fada6d27'
  $hh15 = Get-CitedHashes -Text ("The old arm is base commit ``8253ded82``. The new arm is md5`n``" + $md5a + $md5b + "``: the fix.")
  $h15 = @($hh15)
  Case 'MUST NOT FIRE' 'a 32-hex md5 on a commit line is not a cited hash' ($h15.Count -eq 1 -and $h15[0] -eq '8253ded82') ($h15 -join ',')
  # A RE-READ THAT CITES THE HARNESS'S BLOB (2026-09-18, backlog I228). The founding shape: a re-read line citing the
  # session's own commit, which push-main's rebase renamed before it landed, so the line named nothing on main.
  $nowBlob = 'c0de5eed00112233445566778899aabbccddeeff'
  $blobKind = { param($x) if ($x -eq 'aaa1111') { 'commit' } else { 'content' } }
  $curBlob = { param($p) $nowBlob }
  $after17 = { param($h, $p) 3 }   # the cited commit is 3 changes behind the harness
  $v17 = Get-CurrencyVerdict -Paths @('ops/run-gates.ps1') -Hashes @('aaa1111', 'b01d123') -HashType $blobKind -PathExists $yes -After $after17 -CurrentBlob $curBlob
  Case 'MUST FIRE' 'a re-read citing a STALE blob of the harness leaves it UNQUALIFIED' ($v17.Verdict -eq 'UNQUALIFIED' -and @($v17.BlobRead).Count -eq 0) $v17.Verdict
  $v18 = Get-CurrencyVerdict -Paths @('ops/run-gates.ps1') -Hashes @('b01d123') -HashType $blobKind -PathExists $yes -After $after17 -CurrentBlob $curBlob
  Case 'MUST FIRE' 'a document citing ONLY a stale blob of its harness is never CURRENT' ($v18.Verdict -ne 'CURRENT') $v18.Verdict
  $v19 = Get-CurrencyVerdict -Paths @('ops/run-gates.ps1') -Hashes @('aaa1111', 'c0de5eed00') -HashType $blobKind -PathExists $yes -After $after17 -CurrentBlob $curBlob
  Case 'CLEAN TWIN' 'a re-read citing the harness''s CURRENT blob qualifies it past an older cited commit' ($v19.Verdict -eq 'CURRENT' -and @($v19.BlobRead).Count -eq 1) $v19.Verdict
  $v20 = Get-CurrencyVerdict -Paths @('ops/run-gates.ps1', 'ops/h.ps1') -Hashes @('aaa1111', 'c0de5eed00') -HashType $blobKind -PathExists $yes -After $after17 -CurrentBlob { param($p) if ($p -eq 'ops/h.ps1') { 'fff0000111' } else { $nowBlob } }
  Case 'MUST FIRE' 'a current blob of ONE harness does not qualify a second harness that moved' ($v20.Verdict -eq 'UNQUALIFIED' -and @($v20.Moved).Count -eq 1 -and $v20.Moved[0].Path -eq 'ops/h.ps1') $v20.Verdict
  $v21 = Get-CurrencyVerdict -Paths @('ops/run-gates.ps1') -Hashes @('aaa1111', 'b01d123') -HashType $blobKind -PathExists $yes -After { param($h, $p) 0 } -CurrentBlob $curBlob
  Case 'CLEAN TWIN' 'the commit form still qualifies: a cited commit at the harness''s last change is CURRENT beside a stale blob' ($v21.Verdict -eq 'CURRENT') $v21.Verdict
  $hh22 = Get-CitedHashes -Text 'Re-read at harness blob `c0de5eed00` (ops/run-gates.ps1): every figure holds.'
  $h22 = @($hh22)
  Case 'CLEAN TWIN' 'a re-read line that says blob and not commit is read for its hash' ($h22.Count -eq 1 -and $h22[0] -eq 'c0de5eed00') ($h22 -join ',')
  $full16 = '679a1535661ad682dcdadb163c39c4057a1a7508'
  $hh16 = Get-CitedHashes -Text ('Commit it ran at: ' + $full16 + '.')
  $h16 = @($hh16)
  Case 'CLEAN TWIN' 'a full 40-hex commit id is still cited after the md5 rule' ($h16.Count -eq 1 -and $h16[0] -eq $full16) ($h16 -join ',')

  # THE LIVE PATH, DRIVEN (2026-09-11). The founding shape is a pre-push run-gates pass whose count FELL: it rewrote
  # the tracked baseline and left the pushing checkout dirty. These run THIS script as a child against a temp git
  # repository whose one EVAL document cites a commit its harness has since moved past, and a temp baseline, so they
  # exercise the code a gate runs, not a copy of it. One directory per run, removed in finally, because concurrent
  # pushes run this suite in the same %TEMP%.
  # THE REPOSITORY ENVIRONMENT IS CLEARED FIRST (lib\git-repo-env.ps1): under a hook in a linked worktree GIT_DIR is
  # exported, and the git init and git -C <temp> config below would otherwise write the shared .git.
  . (Join-Path $repo 'lib\git-repo-env.ps1')
  Clear-TcGitRepoEnv
  $lt = Join-Path $env:TEMP ('cc-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Path $lt -ErrorAction Stop | Out-Null
  try {
    $ltTree = Join-Path $lt 'tree'
    [void][IO.Directory]::CreateDirectory((Join-Path $ltTree 'ops'))
    [void][IO.Directory]::CreateDirectory((Join-Path $ltTree 'design'))
    $ltUtf8 = New-Object Text.UTF8Encoding($false)
    $null = & git -c init.defaultBranch=main init -q $ltTree
    $null = & git -C $ltTree config user.name Fixture
    $null = & git -C $ltTree config user.email t@t
    $null = & git -C $ltTree config commit.gpgsign false
    [IO.File]::WriteAllText((Join-Path $ltTree 'ops\h.ps1'), 'Write-Output 1', $ltUtf8)
    $null = & git -C $ltTree add -- ops/h.ps1
    $null = & git -C $ltTree commit -q -m one
    $ltCited = ([string](& git -C $ltTree rev-parse HEAD)).Trim()
    [IO.File]::WriteAllText((Join-Path $ltTree 'ops\h.ps1'), 'Write-Output 2', $ltUtf8)
    $null = & git -C $ltTree add -- ops/h.ps1
    $null = & git -C $ltTree commit -q -m two   # the harness moves after the cited commit
    # The document also cites the harness's BLOB at the cited commit, as measurement.md asks, and one hash that names
    # nothing. Neither may move the verdict, and neither may reach stderr.
    $ltBlob = ([string](& git -C $ltTree rev-parse ($ltCited + ':ops/h.ps1'))).Trim().Substring(0, 10)
    $ltNone = 'fedcba9876'
    [IO.File]::WriteAllText((Join-Path $ltTree 'design\EVAL-fixture.md'), ("Harness: ops/h.ps1`nCommit it ran at: " + $ltCited + "`nThat commit held the harness as blob " + $ltBlob + ", and commit " + $ltNone + " names nothing.`n"), $ltUtf8)
    # A second document re-read by the harness's CURRENT blob (backlog I228): same old commit, so only the blob can
    # qualify it. It is CURRENT, so the unqualified count the ratchet cases below read is unchanged.
    $ltNowBlob = ([string](& git -C $ltTree rev-parse 'HEAD:ops/h.ps1')).Trim().Substring(0, 10)
    [IO.File]::WriteAllText((Join-Path $ltTree 'design\EVAL-reread.md'), ("Harness: ops/h.ps1`nCommit it ran at: " + $ltCited + "`n`nRe-read at harness blob " + $ltNowBlob + " (ops/h.ps1): it still holds.`n"), $ltUtf8)
    $ltBl = Join-Path $lt 'baseline.json'
    [IO.File]::WriteAllText($ltBl, "{`n    ""unqualified"":  2,`n    ""note"":  ""fixture""`n}`n", $ltUtf8)
    $ltSeed = [Convert]::ToBase64String([IO.File]::ReadAllBytes($ltBl))
    $o1 = & powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Root $ltTree -BaselineFile $ltBl
    $rc1 = $LASTEXITCODE
    $o1 = @($o1)
    $same1 = [string]::Equals($ltSeed, [Convert]::ToBase64String([IO.File]::ReadAllBytes($ltBl)), [StringComparison]::Ordinal)
    $tally1 = (@($o1) -match 'document\(s\) UNQUALIFIED') -join ' '
    Case 'LIVE PATH' 'a FALL (1 unqualified, baseline 2) without -Tighten is spoken and NOT written, so a gate run leaves its checkout clean' `
      ($rc1 -eq 0 -and $same1 -and (($o1 -join "`n") -match 'CAN tighten')) ("rc=$rc1 baselineUnchanged=$same1 $tally1")
    $null = & powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Root $ltTree -BaselineFile $ltBl -Tighten
    $rc2 = $LASTEXITCODE
    $b2 = [IO.File]::ReadAllBytes($ltBl)
    $cr2 = 0; foreach ($x in $b2) { if ($x -eq 13) { $cr2++ } }
    $bom2 = ($b2.Length -ge 3 -and $b2[0] -eq 0xEF -and $b2[1] -eq 0xBB -and $b2[2] -eq 0xBF)
    $doc2 = $null
    try { $doc2 = [Text.Encoding]::UTF8.GetString($b2) | ConvertFrom-Json } catch { }
    # The committed blob is LF, no BOM, one trailing LF, and -Tighten must keep that shape.
    Case 'LIVE PATH' '-Tighten records the fall in the committed shape: no CR, no BOM, one trailing LF, and the new mark of 1' `
      ($rc2 -eq 0 -and $cr2 -eq 0 -and -not $bom2 -and $b2[-1] -eq 10 -and $null -ne $doc2 -and [int]$doc2.unqualified -eq 1) `
      ("rc=$rc2 cr=$cr2 bom=$bom2 unqualified=$(if ($doc2) { $doc2.unqualified })")
    $ltRise = Join-Path $lt 'baseline-rise.json'
    [IO.File]::WriteAllText($ltRise, "{`n    ""unqualified"":  0,`n    ""note"":  ""fixture""`n}`n", $ltUtf8)
    $null = & powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Root $ltTree -BaselineFile $ltRise
    $rc3 = $LASTEXITCODE
    Case 'CLEAN TWIN' 'a count that ROSE (1 against a bar of 0, one step past it) still fails the run with exit 2, so not writing on a fall did not disarm the ratchet' ($rc3 -eq 2) ("rc=$rc3")

    # THE BASELINE FAILS CLOSED (2026-09-23, W1.2). The founding shape: a baseline that failed to parse became $null,
    # and `-Accept -or $null` WROTE the current count as the mark and exited 0, so a botched hand resolution of the JSON
    # silently accepted whatever the push carried. Each case below runs this script as a child over the same temp
    # tree, whose count is 1.
    function Invoke-CcChild([string]$ChildBaseline, [string[]]$ChildArgs = @()) {
      $co = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Root $ltTree -BaselineFile $ChildBaseline @ChildArgs)
      $crc = $LASTEXITCODE
      $cm = @($co | Where-Object { "$_" -match '^CONCLUSION-CURRENCY-COMPLETE\b' })
      return @{ Rc = $crc; Out = $co; Mark = $(if ($cm.Count) { [string]$cm[$cm.Count - 1] } else { '' }); Bang = @($co | Where-Object { "$_" -match '^!' }).Count }
    }
    $ltConf = Join-Path $lt 'baseline-conflict.json'
    $confText = "{`n" + ('<' * 7) + " HEAD`n    ""unqualified"":  1,`n" + ('=' * 7) + "`n    ""unqualified"":  0,`n" + ('>' * 7) + " origin/main`n    ""note"":  ""fixture""`n}`n"
    [IO.File]::WriteAllText($ltConf, $confText, $ltUtf8)
    $confSeed = [Convert]::ToBase64String([IO.File]::ReadAllBytes($ltConf))
    $r5 = Invoke-CcChild $ltConf
    $same5 = [string]::Equals($confSeed, [Convert]::ToBase64String([IO.File]::ReadAllBytes($ltConf)), [StringComparison]::Ordinal)
    Case 'MUST FIRE' 'a baseline holding conflict markers exits 3, blind=baseline-unreadable, a ! line, and its bytes are unchanged' `
      ($r5.Rc -eq 3 -and $same5 -and $r5.Mark -match '\bblind=baseline-unreadable\b' -and $r5.Bang -ge 1) ("rc=$($r5.Rc) unchanged=$same5 bang=$($r5.Bang) marker=[$($r5.Mark)]")
    $ltQuoted = Join-Path $lt 'baseline-quoted.json'
    [IO.File]::WriteAllText($ltQuoted, "{`n    ""unqualified"":  ""1"",`n    ""note"":  ""fixture""`n}`n", $ltUtf8)
    $quotedSeed = [Convert]::ToBase64String([IO.File]::ReadAllBytes($ltQuoted))
    $r6 = Invoke-CcChild $ltQuoted
    $same6 = [string]::Equals($quotedSeed, [Convert]::ToBase64String([IO.File]::ReadAllBytes($ltQuoted)), [StringComparison]::Ordinal)
    Case 'MUST FIRE' 'a baseline whose unqualified is a quoted "1", not an integer, exits 3 unreadable and is not rewritten' `
      ($r6.Rc -eq 3 -and $same6 -and $r6.Mark -match '\bblind=baseline-unreadable\b') ("rc=$($r6.Rc) unchanged=$same6 marker=[$($r6.Mark)]")
    $ltAbsent = Join-Path $lt 'baseline-absent.json'
    $r7 = Invoke-CcChild $ltAbsent
    Case 'MUST FIRE' 'an ABSENT baseline on a plain run exits 3 with blind=baseline-missing, and no file is created' `
      ($r7.Rc -eq 3 -and -not (Test-Path -LiteralPath $ltAbsent) -and $r7.Mark -match '\bblind=baseline-missing\b' -and $r7.Bang -ge 1) ("rc=$($r7.Rc) created=$(Test-Path -LiteralPath $ltAbsent) marker=[$($r7.Mark)]")
    $r8 = Invoke-CcChild $ltAbsent @('-Tighten')
    Case 'MUST FIRE' '-Tighten over an ABSENT baseline also exits 3, and no file is created' `
      ($r8.Rc -eq 3 -and -not (Test-Path -LiteralPath $ltAbsent) -and $r8.Mark -match '\bblind=baseline-missing\b') ("rc=$($r8.Rc) created=$(Test-Path -LiteralPath $ltAbsent) marker=[$($r8.Mark)]")
    $r9 = Invoke-CcChild $ltAbsent @('-Accept')
    $b9 = Read-CcBaseline -Path $ltAbsent
    Case 'CLEAN TWIN' '-Accept over an ABSENT baseline writes it with the current count of 1 and exits 0 - the one road that records an unread mark' `
      ($r9.Rc -eq 0 -and $b9.State -eq 'read' -and $b9.Value -eq 1) ("rc=$($r9.Rc) state=$($b9.State) value=$($b9.Value)")
    $ltEqual = Join-Path $lt 'baseline-equal.json'
    [IO.File]::WriteAllText($ltEqual, "{`n    ""unqualified"":  1,`n    ""note"":  ""fixture""`n}`n", $ltUtf8)
    $equalSeed = [Convert]::ToBase64String([IO.File]::ReadAllBytes($ltEqual))
    $r10 = Invoke-CcChild $ltEqual
    $same10 = [string]::Equals($equalSeed, [Convert]::ToBase64String([IO.File]::ReadAllBytes($ltEqual)), [StringComparison]::Ordinal)
    Case 'MUST NOT FIRE' 'AT THE BAR: a count EQUAL to the baseline (1 against a bar of 1) holds with exit 0 and writes nothing' ($r10.Rc -eq 0 -and $same10) ("rc=$($r10.Rc) unchanged=$same10")
    # THE STDERR THIS WAS FOUND BY (2026-09-18). The whole child's stderr goes to a file, never a 2> on the native call.
    $ltOut = Join-Path $lt 'rep.out'; $ltErr = Join-Path $lt 'rep.err'
    $p4 = Start-Process -FilePath 'powershell.exe' -PassThru -NoNewWindow -RedirectStandardOutput $ltOut -RedirectStandardError $ltErr `
      -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'), '-Root', ('"' + $ltTree + '"'), '-ReportOnly')
    $null = $p4.Handle
    $p4.WaitForExit()
    $rc4 = $p4.ExitCode
    $err4 = ([IO.File]::ReadAllText($ltErr)).Trim()
    $out4 = [IO.File]::ReadAllText($ltOut)
    $mark4 = @(($out4 -split "`r?`n") | Where-Object { $_ -match '^CONCLUSION-CURRENCY-COMPLETE\b' })
    $markLine4 = $(if ($mark4.Count) { [string]$mark4[$mark4.Count - 1] } else { '' })
    Case 'LIVE PATH' 'a cited blob is read as content and a hash naming nothing is counted, with NOTHING on stderr' `
      ($rc4 -eq 0 -and $err4 -eq '' -and $markLine4 -match '\bunresolved=1\b' -and $markLine4 -match '\bcontent_ids=2\b' -and $out4 -match ('blob or tree id ' + $ltBlob) -and $out4 -match ('names no object: ' + $ltNone)) `
      ("rc=$rc4 stderr=[$err4] marker=[$markLine4]")
    Case 'CLEAN TWIN' 'the blob beside the cited commit leaves the verdict to the commit: the fixture document is still UNQUALIFIED' `
      ($out4 -match 'UNQUALIFIED\s+EVAL-fixture\.md') ($out4 -replace "`r?`n", ' | ')
    Case 'LIVE PATH' 'a document whose re-read line cites the harness''s CURRENT blob (git rev-parse HEAD:<path>) is current against a real repository' `
      ($out4 -match 'current\s+EVAL-reread\.md' -and $out4 -match 'ops/h\.ps1 re-read by its CURRENT blob') ($out4 -replace "`r?`n", ' | ')
  } finally {
    Remove-Item -LiteralPath $lt -Recurse -Force -ErrorAction SilentlyContinue
  }

  # A LITERAL-CASE SUITE ASSERTS HOW MANY RAN (.claude\rules\ops-and-gates.md): a case lost to a thrown helper, a
  # glued line or a comment is a shortfall here, never a smaller suite that still prints pass.
  $expectedCases = 37
  if ($ran.Count -ne $expectedCases) { [void]$fails.Add(("CASE COUNT ran {0} of the {1} cases written in this file" -f $ran.Count, $expectedCases)) }
  Write-Output ''
  if ($fails.Count) {
    Write-Output ("audit-conclusion-currency selftest: {0} FAILED of {1}" -f $fails.Count, $ran.Count)
    $fails | ForEach-Object { Write-Output "  $_" }
    Exit-Guard -Name 'CONCLUSION-CURRENCY-SELFTEST' -Code 1 -Summary "failed=$($fails.Count) cases=$($ran.Count)"
  }
  Write-Output ("audit-conclusion-currency selftest: {0} of {0} cases pass" -f $ran.Count)
  Exit-Guard -Name 'CONCLUSION-CURRENCY-SELFTEST' -Code 0 -Summary "cases=$($ran.Count)"
}

# ------------------------------------------------------------------------------------------------ live
$docs = @(Get-ChildItem (Join-Path $treeRoot 'design') -File -Filter '*.md' -ErrorAction SilentlyContinue |
          Where-Object { $_.Name -like 'EVAL-*' -or $_.Name -like 'MEASURE-*' } | Sort-Object Name)
if ($docs.Count -eq 0) {
  Write-Output 'CONCLUSION CURRENCY BLIND: no EVAL-* or MEASURE-* documents under design\ - nothing was judged.'
  if ($Json) { 'conclusion-currency-json: {"known": false}' }
  Exit-Guard -Name 'CONCLUSION-CURRENCY' -Code 3 -Summary 'docs=0 blind=1'
}
$head = & git -C $treeRoot rev-parse --verify --quiet HEAD
if ($LASTEXITCODE -ne 0 -or -not $head) {
  Write-Output 'CONCLUSION CURRENCY BLIND: not a git checkout, so no harness history can be read.'
  if ($Json) { 'conclusion-currency-json: {"known": false}' }
  Exit-Guard -Name 'CONCLUSION-CURRENCY' -Code 3 -Summary "docs=$($docs.Count) blind=1"
}

# WHAT KIND OF OBJECT A CITED HASH NAMES (2026-09-18). `cat-file -t` answers without peeling, so a blob is a blob and
# not "expected commit type, but the object dereferences to blob type" printed to stderr. A missing or ambiguous name
# makes cat-file exit non-zero and print to stderr, so that stream is dropped here, under Continue: the answer 'none'
# carries everything it said, and a 2>$null under this script's Stop would turn the first stderr line into a throw.
# An annotated tag is a commit citation when it peels to one.
$hashType = {
  param($h)
  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $to = @(& git -C $treeRoot cat-file -t $h 2>$null)
    $trc = $LASTEXITCODE
    $t = $(if ($to.Count) { ([string]$to[$to.Count - 1]).Trim() } else { '' })
    if ($trc -ne 0 -or -not $t) { return 'none' }
    if ($t -ceq 'commit') { return 'commit' }
    if ($t -ceq 'tag') {
      $null = & git -C $treeRoot rev-parse --verify --quiet ($h + '^{commit}') 2>$null
      if ($LASTEXITCODE -eq 0) { return 'commit' }
    }
    return 'content'
  } finally {
    $ErrorActionPreference = $prevEap
  }
}
$pathExists = { param($p) return (Test-Path -LiteralPath (Join-Path $treeRoot ($p -replace '/', '\'))) }
$afterFn = { param($h, $p) $n = & git -C $treeRoot rev-list --count "$h..HEAD" -- $p; return [int]("$n".Trim()) }
# The harness's blob at HEAD (backlog I228). Only an existing path reaches here, but a path that exists in the working
# tree and not at HEAD (a new, uncommitted harness) makes rev-parse fail: that answers '' and matches nothing.
$currentBlobFn = {
  param($p)
  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $bo = @(& git -C $treeRoot rev-parse --verify --quiet ('HEAD:' + $p) 2>$null)
    if ($LASTEXITCODE -ne 0 -or $bo.Count -eq 0) { return '' }
    return ([string]$bo[$bo.Count - 1]).Trim()
  } finally {
    $ErrorActionPreference = $prevEap
  }
}

$unq = 0; $cur = 0; $nq = 0; $unres = 0; $cids = 0; $cited = 0
Write-Output 'CONCLUSION CURRENCY - does each recorded conclusion still describe the harness it names?'
Write-Output ''
foreach ($d in $docs) {
  $text = [IO.File]::ReadAllText($d.FullName)
  $hpR = Get-HarnessPaths -Text $text
  $paths = @($hpR)
  $hhR = Get-CitedHashes -Text $text
  $hashes = @($hhR)
  $cited += $hashes.Count
  $v = Get-CurrencyVerdict -Paths $paths -Hashes $hashes -HashType $hashType -PathExists $pathExists -After $afterFn -CurrentBlob $currentBlobFn
  $vB = @($v.BlobRead | Where-Object { $_ })
  $vC = @($v.Content | Where-Object { $_ })
  $vU = @($v.Unresolved | Where-Object { $_ })
  $cids += $vC.Count; $unres += $vU.Count
  switch ($v.Verdict) {
    'UNQUALIFIED' {
      $unq++
      Write-Output ("  UNQUALIFIED      {0}" -f $d.Name)
      foreach ($m in @($v.Moved)) {
        $newest = & git -C $treeRoot log -1 '--format=%h %cs' -- $m.Path
        Write-Output ("                   {0} has {1} commit(s) after cited {2}; newest {3}" -f $m.Path, $m.After, $m.Since, "$newest".Trim())
      }
    }
    'CURRENT' { $cur++; Write-Output ("  current          {0}" -f $d.Name) }
    default { $nq++; Write-Output ("  not qualifiable  {0} - {1}" -f $d.Name, $v.Why) }
  }
  foreach ($b in $vB) { Write-Output ("                   {0} re-read by its CURRENT blob: qualified as a commit at or after its last change would be" -f $b) }
  foreach ($c in $vC) { Write-Output ("                   cites blob or tree id {0} on a commit or blob line: content, not a commit; it qualifies a harness only when it IS that harness's current blob" -f $c) }
  foreach ($u in $vU) { Write-Output ("                   UNRESOLVED hash on a commit line, git names no object: {0} (missing, gc'd or ambiguous)" -f $u) }
}
Write-Output ''
Write-Output ("  {0} of {1} document(s) UNQUALIFIED, {2} current, {3} not qualifiable (ops\audit-measurement-provenance.ps1's finding)" -f $unq, $docs.Count, $cur, $nq)
Write-Output ("  of {0} cited hash(es): {1} blob or tree id(s) read as content, {2} naming no object - counted and listed, not ratcheted" -f $cited, $cids, $unres)
Write-Output '  To re-qualify one: re-read it against the moved harness and add "Re-read at harness blob <git rev-parse HEAD:<path>> (<path>): <what still holds>".'
Write-Output '  Cite the BLOB, not your own unlanded commit: push-main rebases and renames that commit, and it never reaches main.'

$blF = if ($BaselineFile) { $BaselineFile } else { Join-Path $here 'conclusion-currency-baseline.json' }
function Write-CcBaseline([int]$Count) {
  $o = [ordered]@{ unqualified = $Count; examined = $docs.Count; recorded = (Get-Date).ToString('yyyy-MM-dd')
                   note = 'High-water mark for the conclusion-currency ratchet (WS 7d, 2026-09-10). May only go DOWN; a re-read lowers it.' }
  [IO.File]::WriteAllText($blF, ((($o | ConvertTo-Json) -replace "`r`n", "`n") + "`n"), (New-Object Text.UTF8Encoding($false)))
}
if ($Json) {
  'conclusion-currency-json: ' + (([ordered]@{ known = $true; docs = $docs.Count; unqualified = $unq; current = $cur; not_qualifiable = $nq; cited_hashes = $cited; content_ids = $cids; unresolved = $unres }) | ConvertTo-Json -Compress)
}
if ($ReportOnly) {
  # ops\brain-report.ps1 reads and never writes. The ratchet's verdict is run-gates' to give, and a report that
  # could tighten a baseline as a side effect of being read would be a writer by accident.
  Exit-Guard -Name 'CONCLUSION-CURRENCY' -Code 0 -Summary "docs=$($docs.Count) unqualified=$unq unresolved=$unres content_ids=$cids report-only=1"
}
if ($Accept) {
  Write-CcBaseline $unq
  Write-Output "  baseline written: $unq of $($docs.Count). From here the number may only go DOWN."
  Exit-Guard -Name 'CONCLUSION-CURRENCY' -Code 0 -Summary "docs=$($docs.Count) unqualified=$unq unresolved=$unres content_ids=$cids baseline=$unq"
}
# A PLAIN RUN AND -Tighten NEVER RECORD A MARK OVER A BASELINE THEY COULD NOT READ (W1.2). See the header.
$bl = Read-CcBaseline -Path $blF
if ($bl.State -ne 'read') {
  $blTok = if ($bl.State -eq 'absent') { 'baseline-missing' } else { 'baseline-unreadable' }
  Write-Output ("! conclusion-currency: COULD NOT EVALUATE - the ratchet baseline {0} is {1} ({2}). Nothing was written: a plain run and -Tighten never record a mark over a baseline they could not read. Restore it from git, or run -Accept once you have looked at the count above." -f $blF, $bl.State.ToUpperInvariant(), $bl.Why)
  Exit-Guard -Name 'CONCLUSION-CURRENCY' -Code 3 -Summary "docs=$($docs.Count) unqualified=$unq unresolved=$unres content_ids=$cids blind=$blTok baseline_file=$blF"
}
$base = [int]$bl.Value
$move = Test-RatchetMove -Name 'conclusion-currency' -Count $unq -Baseline $base
if ($move.Verdict -eq 'rose') {
  Write-Output "conclusion-currency: RATCHET BROKEN - $unq unqualified, baseline $base. A conclusion that was current now names a harness changed after it. Re-read it and add a Re-read at commit line."
  Exit-Guard -Name 'CONCLUSION-CURRENCY' -Code 2 -Summary "docs=$($docs.Count) unqualified=$unq unresolved=$unres content_ids=$cids baseline=$base"
}
if ($move.Verdict -eq 'tightened') {
  if ($Tighten) {
    Write-CcBaseline $unq
    Write-Output "  ratchet tightened: $unq, was $base. New baseline written - commit it, or it protects only this checkout."
  } else {
    Write-Output "  ratchet CAN tighten: $unq unqualified, baseline $base. NOT written: this may be a pre-push gate, and a rewrite here dirties the checkout being pushed without riding the push. Record it with -Tighten and commit ops\conclusion-currency-baseline.json."
  }
} elseif ($move.Verdict -eq 'implausible') {
  Write-Output ('  ' + $move.Message + ' - baseline kept at ' + $base + ' (-Accept is this script''s -AcceptDrop.)')
  if ($Tighten) { Exit-Guard -Name 'CONCLUSION-CURRENCY' -Code 2 -Summary "docs=$($docs.Count) unqualified=$unq unresolved=$unres content_ids=$cids baseline=$base refused-to-lower" }
}
Exit-Guard -Name 'CONCLUSION-CURRENCY' -Code 0 -Summary "docs=$($docs.Count) unqualified=$unq unresolved=$unres content_ids=$cids baseline=$base"
