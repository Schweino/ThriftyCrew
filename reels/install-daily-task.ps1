param([switch]$Uninstall)
$ErrorActionPreference = 'Stop'
$taskName = 'SMP Daily Facebook Reel'
$builder = Join-Path $PSScriptRoot 'build-reel.ps1'

if ($Uninstall) {
  Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
  Write-Output "Removed $taskName."
  exit 0
}

if (-not (Test-Path -LiteralPath $builder)) { throw "reel builder is missing: $builder" }
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ("-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"{0}`"" -f $builder)
$trigger = New-ScheduledTaskTrigger -Daily -At '10:00 AM'
$principal = New-ScheduledTaskPrincipal -UserId ("{0}\{1}" -f $env:USERDOMAIN, $env:USERNAME) -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -WakeToRun -ExecutionTimeLimit (New-TimeSpan -Hours 2) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description 'Builds one local Facebook recipe reel and caption for manual posting; never uploads automatically.' -Force | Out-Null
Write-Output "Installed $taskName for 10:00 AM daily."
