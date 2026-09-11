# lf-write.ps1 - write a TRACKED text file in the bytes git stores, so a run over unchanged content leaves the
# checkout clean.
#
# WHY THIS EXISTS (2026-09-11). .gitattributes stores every text file `eol=lf`, and under Windows PowerShell 5.1
# this estate's habitual writer, `ConvertTo-Json | Set-Content -Encoding UTF8`, writes CRLF twice over:
# ConvertTo-Json joins its lines with CRLF and Set-Content ends the file with one more (Out-File does the same).
# Over an LF blob that leaves the file ` M` with a ZERO-line `git diff`, which is enough to make `git rebase`
# refuse ("You have unstaged changes") and is exactly the churn that makes `git add -A` dangerous. Measured from
# a fresh LF worktree the day this was written, before any caller moved here:
#     ops\audit-write-only-reports.ps1, a ratchet tighten   1,915-byte LF input -> 1,866 bytes, 48 CR
#     ops\audit-arg-binding.ps1 -Accept                     358 bytes, 9 CR
# meal-prep\pipeline\audit-spec-contradictions.ps1's Write-ReportJson fixed its own two writes the same morning.
# This is that rule as a library, so the next writer does not copy six lines and drift from them.
#
# THE RULE. CRLF becomes LF, the file ends in the one newline Set-Content would have written, the UTF-8 BOM is
# written unless -NoBom, and identical bytes are NOT rewritten, so an unchanged run does not even move the mtime.
# The bytes on disk are then the bytes git would have stored from the old writer: a caller that switches changes
# no blob and gains a clean checkout. Match the BOM to the committed blob, read with
# `git cat-file blob HEAD:<path> > file` - Format-Hex on a decoded string hides a BOM.
#
# THE NAME IS LOAD-BEARING. ops\audit-write-only-reports.ps1 recognises a write by its verb, and Write-<x>File is
# on its list. A helper named otherwise hides every report family written through it, and that ratchet then
# records the disappearance as an improvement.
#
# WHAT IT DOES NOT DO. It is not atomic and takes no lock (lib\atomic-write.ps1 is the ledger writer, and keeps
# Set-Content's CRLF bytes on purpose). A lone CR that is not part of a CRLF is left as it is.
#
# SCOPE OF A CLEAN REPORT: the self-test writes real files in a per-run temp directory under this PowerShell. A
# pass proves these bytes for these shapes; it says nothing about a caller that still writes some other way.
#
# Dot-source:  . (Join-Path $repoRoot 'lib\lf-write.ps1')
# Self-test:   powershell -File lib\lf-write.ps1 -SelfTest
#
# NO param() BLOCK HERE, DELIBERATELY - dot-sourced under PS 5.1 a param() block runs in the CALLER's scope and
# would reset the caller's own -SelfTest. Same rule as lib\json-io.ps1.
$__lfwSelfTest = ($MyInvocation.InvocationName -ne '.') -and ($args -contains '-SelfTest')

function Write-TcLfFile {
  <# Writes $Text to $Path as UTF-8 (BOM unless -NoBom) with LF line endings and one trailing LF: the bytes
     `$Text | Set-Content -Encoding UTF8` produces once git has normalised them. Returns $true when it wrote,
     $false when the file already held exactly these bytes. #>
  param(
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Text,
    [switch]$NoBom
  )
  # PowerShell LOCATION semantics for a relative path, the way Set-Content resolved it (lib\json-io.ps1, Resolve-JioPath).
  $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
  $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes((($Text -replace "`r`n", "`n") + "`n"))
  if (-not $NoBom) { $bytes = [byte[]]((New-Object Text.UTF8Encoding($true)).GetPreamble() + $bytes) }
  if (Test-Path -LiteralPath $full -PathType Leaf) {
    $old = [IO.File]::ReadAllBytes($full)
    if ([string]::Equals([Convert]::ToBase64String($old), [Convert]::ToBase64String($bytes), [StringComparison]::Ordinal)) { return $false }
  }
  [IO.File]::WriteAllBytes($full, $bytes)
  return $true
}

if ($__lfwSelfTest) {
  $ErrorActionPreference = 'Stop'
  $fail = 0; $cases = 0
  function Check([string]$Name, [bool]$Ok, [string]$Got) {
    $script:cases++
    if ($Ok) { Write-Output ('  PASS  ' + $Name) } else { Write-Output ('  FAIL  ' + $Name + '   got: ' + $Got); $script:fail++ }
  }
  function Get-LfwStats([byte[]]$B) {
    $cr = 0; foreach ($x in $B) { if ($x -eq 13) { $cr++ } }
    [pscustomobject]@{ Cr = $cr; Bom = ($B.Length -ge 3 -and $B[0] -eq 0xEF -and $B[1] -eq 0xBB -and $B[2] -eq 0xBF)
                       Tail = $(if ($B.Length -ge 2) { '{0:X2}{1:X2}' -f $B[-2], $B[-1] } else { '' }) }
  }
  # ONE DIRECTORY PER RUN, removed in finally: run-gates runs every -SelfTest and concurrent pushes share %TEMP%.
  $t = Join-Path $env:TEMP ('lfw-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Path $t -ErrorAction Stop | Out-Null
  try {
    $json = [ordered]@{ note = 'fixture'; families = 2; names = @('a', 'b') } | ConvertTo-Json -Depth 3

    # (1) MUST FIRE - the founding bug, performed on purpose. If this ever passes, PowerShell stopped writing CRLF
    #     and this library is decoration; asserted rather than assumed so it cannot outlive its reason.
    $old = Join-Path $t 'old.json'
    $json | Set-Content $old -Encoding UTF8
    $ob = [IO.File]::ReadAllBytes($old); $os = Get-LfwStats $ob
    Check 'MUST FIRE  ConvertTo-Json | Set-Content -Encoding UTF8 still writes CR bytes here (the bug this exists for)' ($os.Cr -gt 0) ("cr=$($os.Cr)")

    # (2) The fix, and the property that makes switching safe: the new bytes ARE the old writer's bytes with CRLF
    #     folded to LF, which is what git stored from the old writer. So no committed blob moves.
    $new = Join-Path $t 'new.json'
    $w1 = Write-TcLfFile -Path $new -Text $json
    $nb = [IO.File]::ReadAllBytes($new); $ns = Get-LfwStats $nb
    # THE OUTER PARENS ARE LOAD-BEARING: inside a .NET method call the comma of `-replace a, b` splits the arguments.
    $expect = [Text.Encoding]::UTF8.GetBytes((([Text.Encoding]::UTF8.GetString($ob)) -replace "`r`n", "`n"))
    $same = [string]::Equals([Convert]::ToBase64String($nb), [Convert]::ToBase64String($expect), [StringComparison]::Ordinal)
    Check 'writes no CR, one trailing LF, the BOM, and exactly the old writer''s bytes with CRLF folded to LF' `
      ($w1 -and $ns.Cr -eq 0 -and $ns.Bom -and $ns.Tail -eq '7D0A' -and $same) ("wrote=$w1 cr=$($ns.Cr) bom=$($ns.Bom) tail=$($ns.Tail) equalsNormalisedOld=$same")

    # (3) An identical rewrite is skipped, so a run over unchanged content does not touch the file at all.
    $stamp = (Get-Date).AddDays(-3)
    [IO.File]::SetLastWriteTime($new, $stamp)
    $w2 = Write-TcLfFile -Path $new -Text $json
    $kept = ([IO.File]::GetLastWriteTime($new) -eq $stamp)
    Check 'an identical rewrite is skipped: returns $false and leaves the mtime where it was' ((-not $w2) -and $kept) ("wrote=$w2 mtimeKept=$kept")

    # (4) CLEAN TWIN - the skip must not swallow a real change.
    $json1 = [ordered]@{ note = 'fixture'; families = 1; names = @('a') } | ConvertTo-Json -Depth 3
    $w3 = Write-TcLfFile -Path $new -Text $json1
    $s3 = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($new))
    Check 'CLEAN TWIN  changed content is still written: returns $true and the new count is on disk' ($w3 -and $s3 -match '"families":\s+1') ("wrote=$w3")

    # (5) -NoBom, for a blob that carries none.
    $nob = Join-Path $t 'nobom.json'
    $null = Write-TcLfFile -Path $nob -Text $json -NoBom
    $nbs = Get-LfwStats ([IO.File]::ReadAllBytes($nob))
    Check '-NoBom writes no BOM and still no CR' ((-not $nbs.Bom) -and $nbs.Cr -eq 0) ("bom=$($nbs.Bom) cr=$($nbs.Cr)")

    # (6) A relative path resolves against the PowerShell location, as Set-Content's did, not the process directory.
    Push-Location $t
    try { $null = Write-TcLfFile -Path 'rel.json' -Text $json } finally { Pop-Location }
    Check 'a relative path lands at the PowerShell location, not the process working directory' ([IO.File]::Exists((Join-Path $t 'rel.json'))) ''
  } catch {
    Write-Output ('  FAIL  the self-test threw: ' + $_.Exception.Message); $fail++
  } finally {
    Remove-Item -LiteralPath $t -Recurse -Force -ErrorAction SilentlyContinue
  }
  # A SUITE THAT RAN FEWER CASES THAN IT HOLDS HAS NOT PASSED (the estate's zero-cases-exit-0 trap).
  if ($cases -lt 6) { Write-Output ("  FAIL  only $cases of 6 cases ran"); $fail++ }
  if ($fail) { Write-Output ("LF-WRITE SELF-TEST FAILED ($fail, $cases case(s) ran)"); exit 1 }
  Write-Output ("LF-WRITE SELF-TEST PASSED ($cases of 6 cases)")
  exit 0
}
