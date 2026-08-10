# One market clock for every grocery capture. GitHub-hosted runners use UTC while the production market is
# Omaha; using bare Get-Date during the UTC evening crossover stamps tomorrow's date and makes an otherwise
# fresh capture fail the server's required-date check. Try the IANA ID first (Linux/macOS) and the Windows ID
# second so the exact same source adapters remain portable.
function Get-OmahaNow {
  param([datetime]$Instant = [datetime]::UtcNow)
  $utc = if ($Instant.Kind -eq [DateTimeKind]::Utc) {
    $Instant
  } elseif ($Instant.Kind -eq [DateTimeKind]::Local) {
    $Instant.ToUniversalTime()
  } else {
    [datetime]::SpecifyKind($Instant, [DateTimeKind]::Utc)
  }
  $zone = $null
  foreach ($zoneId in @('America/Chicago', 'Central Standard Time')) {
    try { $zone = [TimeZoneInfo]::FindSystemTimeZoneById($zoneId); break } catch {}
  }
  if ($null -eq $zone) { throw 'Omaha time zone is unavailable on this host' }
  return [TimeZoneInfo]::ConvertTimeFromUtc($utc, $zone)
}

function Get-OmahaDateKey {
  param([datetime]$Instant = [datetime]::UtcNow)
  return (Get-OmahaNow $Instant).ToString('yyyy-MM-dd')
}
