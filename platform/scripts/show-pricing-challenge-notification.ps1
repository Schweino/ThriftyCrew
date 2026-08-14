param(
  [Parameter(Mandatory=$true)][string]$ChallengeToken,
  [Parameter(Mandatory=$true)][string]$StoreName,
  [Parameter(Mandatory=$true)][string]$Context,
  [Parameter(Mandatory=$true)][string]$CallbackUrl,
  [Parameter(Mandatory=$true)][string]$CallbackAuthorization
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$form = New-Object System.Windows.Forms.Form
$form.Text = "ThriftyCrew pricing challenge - $StoreName"
$form.TopMost = $true
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object System.Drawing.Size(620,240)
$label = New-Object System.Windows.Forms.Label
$label.Location = New-Object System.Drawing.Point(20,20)
$label.Size = New-Object System.Drawing.Size(560,120)
$label.Text = "Store: $StoreName`r`nContext: $Context`r`n`r`nComplete the challenge in the affected run-owned browser tab, then choose Done. Other stores continue independently."
$done = New-Object System.Windows.Forms.Button
$done.Text = 'Done'
$done.Location = New-Object System.Drawing.Point(470,155)
$done.Size = New-Object System.Drawing.Size(110,35)
$done.Add_Click({
  $headers = @{ Authorization = $CallbackAuthorization; 'Idempotency-Key' = "challenge-ack-$ChallengeToken" }
  Invoke-RestMethod -Method Post -Uri $CallbackUrl -Headers $headers -ContentType 'application/json' -Body (@{ challengeToken = $ChallengeToken } | ConvertTo-Json -Compress) | Out-Null
  $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
  $form.Close()
})
$form.Controls.Add($label); $form.Controls.Add($done)
[void]$form.ShowDialog()
