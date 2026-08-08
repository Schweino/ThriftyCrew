<#
voices.ps1 - the narrator roster, by name.

Microsoft's voice ids are unmemorable and easy to fat-finger ("en-US-AndrewMultilingualNeural" versus
"en-US-AndrewNeural" is one word apart and a different voice), and a typo does not fail loudly: the
service just refuses, or worse, you ship a reel in the wrong voice and only notice on playback. So
the reels refer to the narrator by name, and the name resolves here.

Shared by build-reel.ps1 and build-demo-reel.ps1 so both reels on the Page speak in the same voice
and there is exactly one place to change it. Functions and one table, nothing that could clobber a
caller's parameters when dot-sourced.

Full Microsoft ids still work anywhere a name does, so nothing has to be renamed to try a voice that
does not have one yet.
#>

# Brad names the narrators. Goku is the house voice as of 2026-08-08, picked by listening to five
# candidates read a whole 65-second script rather than one stock line.
$script:TcVoiceAliases = @{
  'goku'        = 'en-US-AndrewMultilingualNeural'  # warm, confident, the house narrator
  'andrew'      = 'en-US-AndrewNeural'              # same persona, older generation
  'brian'       = 'en-US-BrianMultilingualNeural'   # approachable, casual, sincere
  'christopher' = 'en-US-ChristopherNeural'         # deep authority. Rejected: reads documentary
  'guy'         = 'en-US-GuyNeural'                 # passion
  'emma'        = 'en-US-EmmaMultilingualNeural'    # cheerful, clear, conversational
  'ava'         = 'en-US-AvaMultilingualNeural'     # expressive, caring, friendly

  # Azure Dragon HD, same Andrew persona, a newer model that phrases in longer groups instead of
  # chopping sentences into short chunks. Needs AZURE_SPEECH_KEY/REGION; runs on the free F0 tier.
  # These IGNORE rate: the model sets its own pace, so -RatePct does nothing for them.
  'goku-hd'      = 'en-US-Andrew:DragonHDLatestNeural'
  'goku-podcast' = 'en-US-Andrew3:DragonHDLatestNeural'      # tuned for podcast narration
  'goku-omni'    = 'en-US-Andrew:DragonHDOmniLatestNeural'   # fewest pauses per minute measured
}

function Test-AzureVoice {
  <# Dragon HD voices live on Azure Speech, everything else on the free edge-tts endpoint. The colon
     in the id is the marker Microsoft themselves use for a base-model voice. #>
  param([Parameter(Mandatory)][string]$Id)
  return $Id -like '*:Dragon*'
}

function Get-SpeakerScript {
  <# Which synthesis script speaks this voice, and the credentials it needs if it is an Azure one.

     Lives here because THREE call sites need it (both builders plus -VoiceSamples), and a routing
     rule copied three times is a rule that will eventually disagree with itself. Both scripts take
     identical arguments and emit identical timing files, so the caller only needs the path.

     Azure credentials are read from the USER environment and set on this process, because `setx`
     does not reach an already-running shell. The value is never echoed or written to disk. #>
  param([Parameter(Mandatory)][string]$VoiceId, [Parameter(Mandatory)][string]$ReelRoot)
  if (-not (Test-AzureVoice $VoiceId)) { return (Join-Path $ReelRoot 'speak-script.py') }
  foreach ($v in 'AZURE_SPEECH_KEY', 'AZURE_SPEECH_REGION') {
    $val = [System.Environment]::GetEnvironmentVariable($v, 'User')
    if (-not $val) { throw "$VoiceId is an Azure voice and needs $v set. See reels\README.md." }
    Set-Item -Path "Env:$v" -Value $val
  }
  return (Join-Path $ReelRoot 'azure-speak.py')
}

function Resolve-Voice {
  <# A house name, or any Microsoft voice id passed straight through. #>
  param([Parameter(Mandatory)][string]$Name)
  $key = $Name.Trim().ToLower()
  if ($script:TcVoiceAliases.ContainsKey($key)) { return $script:TcVoiceAliases[$key] }
  # Anything shaped like a real voice id is none of our business, pass it on. The optional
  # ":BaseModel" half is how Azure names its HD voices (en-US-Andrew3:DragonHDLatestNeural).
  if ($Name -match '^[a-z]{2}-[A-Z]{2}-\w+(:\w+)?Neural$') { return $Name }
  $known = ($script:TcVoiceAliases.Keys | Sort-Object) -join ', '
  throw "Unknown voice '$Name'. Use one of: $known, or a full Microsoft voice id like en-US-AndrewMultilingualNeural."
}

function Get-VoiceName {
  <# The house name for a resolved id, for logging. Falls back to the id itself. #>
  param([Parameter(Mandatory)][string]$Id)
  foreach ($k in $script:TcVoiceAliases.Keys) {
    if ($script:TcVoiceAliases[$k] -eq $Id) { return (Get-Culture).TextInfo.ToTitleCase($k) }
  }
  return $Id
}
