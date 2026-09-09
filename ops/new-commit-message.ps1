<#
  new-commit-message.ps1 - write a commit message file that `git commit -F` can use, BOM-less.

  WHY THIS EXISTS (2026-09-07). The estate's rule is that commit messages go in a FILE and ship with
  -F, because an inline -m executes backticks. The obvious way to write that file under PS 5.1 is
  `Set-Content -Encoding utf8`, and that emits a BOM - which then lives INSIDE the commit subject.
  Commit 79c62b0f0 carries one: its subject starts EF BB BF and always will, because rewriting pushed
  history to fix a cosmetic blemish is worse than the blemish.

  So the rule that keeps backticks out of a commit is the same rule that put a BOM into one, and
  neither of those is obvious at the moment somebody is writing a message. This is the two-line fix as
  a script rather than as a thing to remember, and ops\hooks\commit-msg refuses the mistake anyway -
  the tool and the check ship together, because a tool nobody is obliged to use is a memo.

  Usage:
    $p = ops\new-commit-message.ps1 -Body "subject`n`nbody..."      writes a temp file, prints its path
    ops\new-commit-message.ps1 -Body $text -Path msg.txt           writes where you say
    git commit -F $p
    ops\new-commit-message.ps1 -SelfTest                            frozen fixtures

  Exit 0 = written. 2 = self-test regression.
#>
[CmdletBinding()]
param([string]$Body = '', [string]$Path = '', [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')

function Write-CommitMessageFile {
  <# The whole point of the file, in one function so the fixture drives exactly the live path.
     UTF8Encoding($false) is the BOM-less constructor; Set-Content -Encoding utf8 under PS 5.1 is the
     one WITH a BOM, and the two are one character apart in the source and invisible apart on disk. #>
  param([Parameter(Mandatory = $true)][string]$Text, [string]$Dest = '')
  if (-not $Dest) {
    $Dest = Join-Path $env:TEMP ('tc-commit-msg-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.txt')
  }
  # Normalise to LF: git keeps whatever it is given, and a CRLF subject is its own small mess.
  $norm = ($Text -replace "`r`n", "`n")
  [IO.File]::WriteAllText($Dest, $norm, (New-Object Text.UTF8Encoding($false)))
  return $Dest
}

if ($SelfTest) {
  $bad = 0
  function T([string]$n, [bool]$ok, [string]$got) {
    if ($ok) { Write-Output ('  ok    ' + $n) } else { Write-Output ('  X     ' + $n + '   got: ' + $got); $script:bad++ }
  }
  $tmp = Join-Path $env:TEMP ('ncm-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  [void](New-Item -ItemType Directory -Path $tmp -Force)
  try {
    $f = Write-CommitMessageFile -Text "A subject line`n`nAnd a body." -Dest (Join-Path $tmp 'a.txt')
    $b = [IO.File]::ReadAllBytes($f)
    # MUST FIRE, and it is the founding bug read as bytes rather than as text - a decoder would hide it.
    $hasBom = ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
    T 'MUST FIRE  the written file has NO BOM (79c62b0f0 subject starts EF BB BF and always will)' `
      (-not $hasBom) ('first bytes ' + ($b[0..2] | ForEach-Object { $_.ToString('x2') }) -join ' ')
    T 'CLEAN TWIN the subject survives intact - a BOM-less writer that mangled the text would be worse' `
      ([IO.File]::ReadAllText($f).StartsWith('A subject line')) ([IO.File]::ReadAllText($f).Substring(0, 20))
    $f2 = Write-CommitMessageFile -Text "one`r`ntwo" -Dest (Join-Path $tmp 'b.txt')
    $t2 = [IO.File]::ReadAllText($f2)
    T 'CLEAN TWIN CRLF is normalised to LF, so the subject cannot carry a stray carriage return' `
      ($t2 -eq "one`ntwo") ([BitConverter]::ToString([Text.Encoding]::UTF8.GetBytes($t2)))
    # And the CONTRAST that proves the assertion can fail: the shape the rule warns about.
    $f3 = Join-Path $tmp 'c.txt'
    'subject' | Set-Content -LiteralPath $f3 -Encoding UTF8
    $b3 = [IO.File]::ReadAllBytes($f3)
    $bom3 = ($b3.Length -ge 3 -and $b3[0] -eq 0xEF -and $b3[1] -eq 0xBB -and $b3[2] -eq 0xBF)
    T 'MUST FIRE  Set-Content -Encoding UTF8 DOES write a BOM here - the test above is a real distinction' `
      $bom3 'Set-Content wrote no BOM on this host, so the founding bug cannot be reproduced'
  } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
  if ($bad) { Write-Output "NEW-COMMIT-MESSAGE SELF-TEST FAILED ($bad)"; exit 2 }
  Write-Output 'NEW-COMMIT-MESSAGE SELF-TEST PASS'
  Exit-Guard -Name 'new-commit-message' -Summary 'selftest ok' -Code 0
}

if (-not $Body) {
  Write-Output 'new-commit-message: nothing to write - pass -Body "<subject>`n`n<body>"'
  exit 0
}
$out = Write-CommitMessageFile -Text $Body -Dest $Path
Write-Output $out
exit 0
