param([Parameter(Mandatory)][string]$ChallengeId)
$ErrorActionPreference = 'Stop'
$configFile = Join-Path $env:LOCALAPPDATA 'ThriftyCrew\grocery-v3\pc-capture-client.json'
$config = Get-Content -LiteralPath $configFile -Raw -Encoding UTF8 | ConvertFrom-Json
$pipe = [IO.Pipes.NamedPipeClientStream]::new('.', 'ThriftyCrew.GroceryV3.CaptureController', [IO.Pipes.PipeDirection]::InOut)
try {
  $pipe.Connect(2000)
  $writer = [IO.StreamWriter]::new($pipe, [Text.UTF8Encoding]::new($false), 1024, $true)
  $reader = [IO.StreamReader]::new($pipe, [Text.UTF8Encoding]::new($false), $false, 1024, $true)
  $writer.AutoFlush = $true
  $writer.WriteLine((@{
    token = [string]$config.controllerToken
    pathname = "/v1/challenges/$ChallengeId/acknowledge"
    body = @{}
  } | ConvertTo-Json -Compress))
  $response = $reader.ReadLine() | ConvertFrom-Json
  if ($response.ok -ne $true) { throw "capture controller rejected challenge acknowledgment" }
} finally { $pipe.Dispose() }
