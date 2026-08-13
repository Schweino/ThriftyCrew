param(
  [Parameter(Mandatory)][string]$ChallengeId,
  [ValidateRange(1,120)][int]$TimeoutMin = 20
)
$ErrorActionPreference = 'Stop'
$configFile = Join-Path $env:LOCALAPPDATA 'ThriftyCrew\grocery-v3\pc-capture-client.json'
$config = Get-Content -LiteralPath $configFile -Raw -Encoding UTF8 | ConvertFrom-Json
$deadline = (Get-Date).AddMinutes($TimeoutMin)

function Invoke-ControllerStatus {
  $pipe = [IO.Pipes.NamedPipeClientStream]::new('.', 'ThriftyCrew.GroceryV3.CaptureController', [IO.Pipes.PipeDirection]::InOut)
  try {
    $pipe.Connect(2000)
    $writer = [IO.StreamWriter]::new($pipe, [Text.UTF8Encoding]::new($false), 1024, $true)
    $reader = [IO.StreamReader]::new($pipe, [Text.UTF8Encoding]::new($false), $false, 1024, $true)
    $writer.AutoFlush = $true
    $writer.WriteLine((@{ token = [string]$config.controllerToken; pathname = '/v1/coordinator/status'; body = @{} } | ConvertTo-Json -Compress))
    return ($reader.ReadLine() | ConvertFrom-Json)
  } finally { $pipe.Dispose() }
}

Write-Output "Waiting for the Windows Done callback for $ChallengeId..."
while ((Get-Date) -lt $deadline) {
  $status = Invoke-ControllerStatus
  $challenge = @($status.challenges | Where-Object { $_.id -eq $ChallengeId } | Select-Object -First 1)
  if ($challenge.Count -eq 0) {
    Write-Output "CALLBACK - $ChallengeId is already resolved; proceed."
    exit 0
  }
  if ($challenge[0].status -eq 'acknowledged') {
    Write-Output "CALLBACK - Done was clicked for $ChallengeId; re-check the retailer canary, then resolve the challenge."
    exit 0
  }
  Start-Sleep -Seconds 2
}
Write-Output "TIMEOUT - no Done callback for $ChallengeId within $TimeoutMin minutes."
exit 1
