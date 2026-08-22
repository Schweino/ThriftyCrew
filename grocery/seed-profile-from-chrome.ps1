<#
  seed-profile-from-chrome.ps1 - give a driver profile Brad's real logged-in session.

  WHY (Brad, 2026-08-22: "Why cant YOUR chrome use MY profile?").
  It cannot USE it directly: Chrome hard-locks a User Data directory to one running instance, so any
  launch pointed at his profile while his Chrome is open exits silently and never opens its debug
  port. That is the exact "Chrome never opened a debugging port" failure this estate already hit.
  What we CAN do is copy the session across, which is what this does.

  WHAT IT COPIES, AND WHAT IT DELIBERATELY DOES NOT.
    COPIED   Local State              the key that decrypts the cookie jar (DPAPI, per Windows user,
                                      so it only decrypts as Brad on this machine)
             Default\Network\Cookies  the cookie jar itself: logged-in sessions, store/club selection
    NOT COPIED
             Login Data               SAVED PASSWORDS. Never copied. The pull agents never sign in;
                                      they ride an existing session. Duplicating a password database
                                      into a folder a daily job reads is a risk with no upside here.
             History, bookmarks, extensions, everything else - not needed, more to leak.

  THIS IS A REAL LOGGED-IN SESSION ON DISK. Treat the driver profile as sensitive: it can act as
  Brad on those sites until the cookies expire. Delete out\browser-profiles\<store>\ to revoke it.

  THE COOKIE JAR IS A LIVE SQLITE FILE. Chrome keeps it open, so this copies the -journal/-wal
  sidecars too when they exist; without them a copy taken mid-write can be missing the newest
  cookies - which would look like "the session did not carry over" rather than a torn copy.

  Usage:  seed-profile-from-chrome.ps1 -Store samsclub [-SourceProfile Default] [-WhatIf]
#>
[CmdletBinding(SupportsShouldProcess)]
param(
  # Repeatable so several stores can be seeded from one close-and-reopen of Chrome.
  [Parameter(Mandatory)][ValidateSet('walmart', 'samsclub', 'fareway')][string[]]$Store,
  [string]$SourceProfile = 'Default',
  # Wait for Chrome to be closed rather than failing on the lock. The cookie jar is opened with NO
  # sharing at all - measured: Copy-Item fails, a FileStream with FileShare.ReadWrite|Delete fails,
  # and robocopy /B needs elevation we do not have. So there is no way to read it behind a running
  # Chrome, and the only honest options are "fail with instructions" or "wait for the user".
  [int]$WaitMinutes = 0
)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

$src = Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data'
if (-not (Test-Path $src)) { throw "no Chrome User Data at $src" }
$srcProf = Join-Path $src $SourceProfile
if (-not (Test-Path $srcProf)) { throw "no such Chrome profile: $SourceProfile (looked in $src)" }

# ---- wait for Chrome to be closed, if asked ---------------------------------------------------
# Polls the REAL profile's processes only - a driver Chrome on out\browser-profiles does not hold
# the source jar and must not be mistaken for something that does.
function Get-RealChrome {
  @(Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" |
    Where-Object { $_.CommandLine -notmatch 'browser-profiles|tc-demo-chrome' })
}
if ($WaitMinutes -gt 0) {
  $deadline = (Get-Date).AddMinutes($WaitMinutes)
  $n = (Get-RealChrome).Count
  if ($n -gt 0) {
    Write-Output ""
    Write-Output "  >>> CLOSE CHROME NOW. Waiting up to $WaitMinutes minute(s)."
    Write-Output "      ($n Chrome process(es) currently hold the cookie jar.)"
    Write-Output "      Nothing else is needed - this copies in a second or two and then you can reopen."
    Write-Output ""
  }
  while ((Get-RealChrome).Count -gt 0 -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2 }
  if ((Get-RealChrome).Count -gt 0) {
    throw "Chrome is still running after $WaitMinutes minute(s) - nothing copied, nothing changed."
  }
  Write-Output "Chrome is closed - copying now."
  Start-Sleep -Seconds 1     # let the last handle actually drop
}

$dstRoots = @()
foreach ($s in $Store) { $dstRoots += (Join-Path $root "out\browser-profiles\$s") }

# NOTHING MAY BE HOLDING A TARGET. Copying a cookie jar underneath a running Chrome leaves it
# reading the old one and, worse, overwriting our copy on exit.
foreach ($d in $dstRoots) {
  $held = @(Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" |
            Where-Object { $_.CommandLine -like "*$d*" })
  if ($held.Count) {
    Write-Output "closing $($held.Count) Chrome process(es) holding $(Split-Path $d -Leaf)"
    foreach ($p in $held) { & taskkill /PID $p.ProcessId /T /F 2>&1 | Out-Null }
    Start-Sleep -Seconds 2
  }
}

$copied = @()
function Copy-One([string]$From, [string]$To, [string]$Label) {
  if (-not (Test-Path $From)) { Write-Output "  skip  $Label (not present)"; return }
  if ($PSCmdlet.ShouldProcess($To, "copy $Label")) {
    # Chrome holds these open for read/write; Copy-Item honours the share mode it opened with, so
    # this normally succeeds while Chrome runs. If it ever does not, closing Chrome is the fix -
    # say so rather than leaving a half-seeded profile that fails later in a confusing way.
    try {
      Copy-Item -LiteralPath $From -Destination $To -Force
      $kb = [math]::Round((Get-Item $To).Length / 1KB)
      Write-Output ("  ok    {0,-24} {1:N0} KB" -f $Label, $kb)
      $script:copied += $Label
    } catch {
      throw ("could not copy $Label - it is locked. Close Chrome and re-run. ($($_.Exception.Message))")
    }
  }
}

$netSrc = Join-Path $srcProf 'Network'
foreach ($s in $Store) {
  $dst = Join-Path $root "out\browser-profiles\$s"
  $dstProf = Join-Path $dst 'Default'
  New-Item -ItemType Directory -Force -Path (Join-Path $dstProf 'Network') | Out-Null
  $copied = @()
  Write-Output "seeding $s from Chrome profile '$SourceProfile'"
  Copy-One (Join-Path $src 'Local State') (Join-Path $dst 'Local State') 'Local State (cookie key)'
  foreach ($f in @('Cookies', 'Cookies-journal', 'Cookies-wal', 'Cookies-shm')) {
    $p = Join-Path $netSrc $f
    if (Test-Path $p) { Copy-One $p (Join-Path $dstProf "Network\$f") $f }
  }

  # The marker is what the driver checks before it will capture. Written here because the SESSION is
  # now established - but it does not replace the store identity check: assertIdentity still has to
  # pass at capture time, and that is the one that decides whether we are pricing the right Omaha
  # store. A seeded profile is permission to try, never proof of correctness.
  if ($copied.Count) {
    Set-Content -Path (Join-Path $dst '.tc-seeded') -Encoding UTF8 -Value @(
      "seeded $(Get-Date -Format s) from Chrome profile '$SourceProfile'"
      "copied: $($copied -join ', ')"
      "NOT copied: Login Data (saved passwords) - never needed, never taken"
      "This profile carries a REAL logged-in session. Delete this folder to revoke it."
    )
    Write-Output "  SEEDED $s"
  } else {
    Write-Output "  NOTHING COPIED - $s is not seeded"
  }
}
