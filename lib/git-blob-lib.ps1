<#
  git-blob-lib.ps1 - read a COMMITTED blob as BYTES, and hash bytes.

  THE CLASS (2026-09-04, queue 2026-09-04-4ec26c). capture-run.ps1's read-after-write asked the right
  question - "is the edge serving the bytes we just pushed?" - and answered it by comparing two different
  DECODINGS of identical bytes:

      $repoBoard = (& git -C $repo show HEAD:public/board.json | Out-String)   # console code page
      $liveBoard = (Invoke-WebRequest ...).Content                            # decoded as UTF-8
      if ($liveBoard -ne $repoBoard) { ...EDGE STALE... }

  A native command's stdout is decoded through [Console]::OutputEncoding on its way into a PowerShell
  string, so every multi-byte UTF-8 sequence in the blob became 2+ characters. Measured on the live board
  that morning: 2,961,318 bytes, 2,959,184 characters when decoded as UTF-8, and exactly 2,134 characters
  above U+007F - 2961318 - 2959184 = 2134. The check could not pass while the board contained a single
  non-ASCII character, and it paged "board.json edge did not pick up today's push" on a board the edge was
  serving byte-for-byte correctly (SHA256 identical on both sides).

  The rule this file exists to enforce: a payload you intend to COMPARE never round-trips through a decoded
  string. Get the bytes, hash the bytes, compare the hashes. Decode only when you actually want text, and
  then say which encoding you mean.

  Used by capture-run.ps1 at BOTH read-after-write call sites (smp-feed and board.json). The smp-feed one
  survived only by accident - it ConvertFrom-Json'd the blob and compared one ASCII field - so the defect
  was latent there and would have fired the moment anyone compared more.
#>

# The blob at <Spec> (e.g. 'HEAD:public/board.json') as [byte[]], or $null if git could not produce it.
#
# WHY System.Diagnostics.Process AND NOT `& git ... `: the call operator hands stdout to PowerShell's TEXT
# pipeline, which is the whole defect. This reads the raw stdout stream instead, so no encoding is applied
# in either direction.
# STDERR IS NOT REDIRECTED, deliberately. Two reasons: this estate runs under $ErrorActionPreference='Stop',
# where merging a native child's stderr turns its first line into a terminating error; and a redirected
# stream nobody drains can fill its buffer and deadlock the child. git's diagnostics go to the console,
# where a human can see them, and the exit code is what this function judges.
function Get-CommittedBlobBytes {
  param([Parameter(Mandatory)][string]$Repo, [Parameter(Mandatory)][string]$Spec)
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = 'git'
  # cat-file, not show: `show` on a blob spec is equivalent here but `cat-file blob` is the plumbing command
  # and cannot be reshaped by a user's diff/pager configuration.
  # .Arguments, NOT .ArgumentList: this runs on Windows PowerShell 5.1 / .NET Framework, where
  # ProcessStartInfo has no ArgumentList property at all (it is .NET Core+). Both operands are quoted
  # because a repo path can contain spaces.
  $psi.Arguments = '-C "' + $Repo + '" cat-file blob "' + $Spec + '"'
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.CreateNoWindow = $true
  $p = $null
  try {
    $p = [System.Diagnostics.Process]::Start($psi)
    $ms = New-Object System.IO.MemoryStream
    $p.StandardOutput.BaseStream.CopyTo($ms)
    $p.WaitForExit()
    if ($p.ExitCode -ne 0) { return $null }   # no such blob / not a repo: could-not-read, never "empty"
    $bytes = $ms.ToArray()
    if ($null -eq $bytes -or $bytes.Length -eq 0) { return $null }
    return , $bytes                            # comma: keep the array from unrolling on the way out
  } catch { return $null }
  finally { if ($p) { $p.Dispose() } }
}

# SHA256 of a byte array, uppercase hex. '' for a null/empty input, so a caller that compares two hashes can
# never read "both unreadable" as "they match" - '' -eq '' would be a false agreement, so the callers test
# for emptiness explicitly and report BLIND.
function Get-Sha256Hex {
  param([byte[]]$Bytes)
  if ($null -eq $Bytes -or $Bytes.Length -eq 0) { return '' }
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes)) -replace '-', '') }
  finally { $sha.Dispose() }
}

# The bytes of an Invoke-WebRequest response, without going through .Content as a string.
# -UseBasicParsing gives .Content as a string on Windows PowerShell 5.1 and as a byte[] in some hosts, so
# BOTH shapes are handled and the string case is re-encoded as UTF-8 - which is what the server sent and
# what the string was decoded from. RawContentStream is preferred when present because it never decoded.
function Get-ResponseBytes {
  param($Response)
  if ($null -eq $Response) { return $null }
  try {
    if ($Response.PSObject.Properties['RawContentStream'] -and $Response.RawContentStream) {
      $ms = New-Object System.IO.MemoryStream
      $Response.RawContentStream.Position = 0
      $Response.RawContentStream.CopyTo($ms)
      $b = $ms.ToArray()
      if ($b -and $b.Length -gt 0) { return , $b }
    }
  } catch { }
  $c = $Response.Content
  if ($null -eq $c) { return $null }
  if ($c -is [byte[]]) { return , $c }
  return , ([Text.Encoding]::UTF8.GetBytes([string]$c))
}
