# ---------------------------------------------------------------- N+5. delegated audits must say BLIND (exit 3), never a false OK
# Item 6 remainder (2026-07-30): every delegated/advisory audit used to print its OK line having examined
# NOTHING when its input was empty or schema-drifted - the zero-rows collapse, one script at a time
# (audit-price-mode printed "PRICE-MODE AUDIT OK" against an EMPTY out\regular; cell-drops printed the
# positive ok line against an empty baseline board; tile-integrity certified ACCURACY OK having graded zero
# links). Each now exits 3 = could-not-evaluate, which guards' delegate loop and advisory wrappers render as
# a WARN - never a block, never an ok. These fixtures freeze each script's founding blind shape (must-fire)
# next to a minimal clean twin, per the guard-fixture rule. Frozen/synthetic inputs only - never regenerated
# from the live board (the two live clean-twins below are deliberate: a machine where they fail is itself
# page-worthy).
function NewFxDir([string]$tag) {
  $d = Register-Fx (Join-Path $script:FxRoot ($tag + '-' + [guid]::NewGuid().ToString('N').Substring(0,8)))
  New-Item -ItemType Directory -Force $d | Out-Null
  # EVERY FIXTURE NEEDS lib\ WITHIN REACH (2026-09-05). A guard copied in here resolves its dependencies as
  # (Split-Path $PSScriptRoot -Parent)\lib\<name>.ps1, and $PSScriptRoot is this directory, so the parent is
  # $script:FxRoot. Without a lib\ there the dot-source throws at STARTUP and the guard exits 1 before printing
  # anything - indistinguishable from 'found nothing' to a caller reading only the exit code, and it turned 32
  # BLIND-path assertions red at once the first time the estate-wide reader sweep ran. This function used to
  # copy json-io into the shared %TEMP%\lib itself; since 2026-09-11 every library is copied once, at start-up,
  # into this run's root (see $script:FxRoot at the top), so a directory made here needs nothing more.
  # global-exclude-lib.ps1 IS NOT COPIED HERE, and the first cut of backlog I82 did copy it here for the
  # same reason json-io was - then five script-census cases went red, because that suite counts the
  # `.ps1` files under its own fixture root and an extra one is a new orphan. A dependency injected into
  # EVERY fixture is not free when a fixture's subject IS the file set. The three fixtures that need the
  # exclude library copy it in their own lists; their failure without it is a named FATAL at exit 2, not
  # a silent pass, which is what makes the targeted copy safe where json-io's would not have been.
  return $d
}
function RunPSAt([string]$dir, [string]$script, $argList) {
  # same stderr-throw guard as RunPS above - see the long note there
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try { $out = PSChild (Join-Path $dir $script) @argList | ForEach-Object { [string]$_ } }
  finally { $ErrorActionPreference = $prev }
  return [pscustomobject]@{ rc = $LASTEXITCODE; text = ($out -join "`n") }
}
# IS THE FIXTURE lib\ COMPLETE, AND IS IT THIS CHECKOUT'S? (2026-09-11). Pure, so u142 can drive it against a
# lib\ it breaks on purpose. One line per lib\*.ps1 of the source that the sandbox lacks ('<name> missing') or
# holds other bytes for ('<name> differs'); empty means every library a fixture copy could dot-source is there
# and current. Bytes, compared ordinally: a copy another checkout left behind can differ by one line.
function Get-FxLibGaps([string]$SourceLib, [string]$SandboxLib) {
  $gaps = New-Object System.Collections.ArrayList
  foreach ($srcLibFile in @(Get-ChildItem -LiteralPath $SourceLib -Filter '*.ps1' -File)) {
    $dstLibFile = Join-Path $SandboxLib $srcLibFile.Name
    if (-not (Test-Path -LiteralPath $dstLibFile)) { [void]$gaps.Add($srcLibFile.Name + ' missing'); continue }
    $srcB64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($srcLibFile.FullName))
    $dstB64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($dstLibFile))
    if (-not [string]::Equals($srcB64, $dstB64, [StringComparison]::Ordinal)) { [void]$gaps.Add($srcLibFile.Name + ' differs') }
  }
  return ,$gaps.ToArray()
}
