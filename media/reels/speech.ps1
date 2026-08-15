<#
speech.ps1 - turning numbers into something a neural voice reads correctly.

Shared by build-reel.ps1 (the daily recipe reel) and build-demo-reel.ps1 (the product demo). It was
inline in build-reel until the demo needed the same three functions. Copying them would have put two
copies of one rule in the estate, which is the failure this codebase keeps re-learning: the copy that
gets fixed is never the copy that ships. One file, dot-sourced by both.

WHY IT EXISTS AT ALL: edge-tts reads "$1.63" inconsistently, sometimes as "one point six three
dollars", which sounds wrong next to a frame showing $1.63. Spelling money out the way a person says
it out loud ("a dollar sixty three") removes the guess.

Defines functions only, no top-level variables besides the two digit tables, so dot-sourcing it
cannot clobber a caller's parameters.
#>

$script:Ones = @('zero','one','two','three','four','five','six','seven','eight','nine','ten',
                 'eleven','twelve','thirteen','fourteen','fifteen','sixteen','seventeen','eighteen','nineteen')
$script:Tens = @('','','twenty','thirty','forty','fifty','sixty','seventy','eighty','ninety')

function ConvertTo-Words {
  param([int]$N)
  if ($N -lt 0)   { return 'minus ' + (ConvertTo-Words ([math]::Abs($N))) }
  if ($N -lt 20)  { return $script:Ones[$N] }
  if ($N -lt 100) {
    $t = $script:Tens[[math]::Floor($N / 10)]
    $r = $N % 10
    if ($r -eq 0) { return $t }
    return "$t $($script:Ones[$r])"
  }
  if ($N -lt 1000) {
    $h = "$($script:Ones[[math]::Floor($N / 100)]) hundred"
    $r = $N % 100
    if ($r -eq 0) { return $h }
    return "$h $(ConvertTo-Words $r)"
  }
  $k = "$(ConvertTo-Words ([math]::Floor($N / 1000))) thousand"
  $r = $N % 1000
  if ($r -eq 0) { return $k }
  return "$k $(ConvertTo-Words $r)"
}

function Get-MoneySpeech {
  # How a person actually says money out loud: "a dollar sixty three", "twenty two eighty two".
  param([double]$Amount)
  $cents   = [int][math]::Round($Amount * 100)
  $dollars = [math]::Floor($cents / 100)
  $rem     = $cents % 100
  if ($rem -eq 0)      { if ($dollars -eq 1) { return 'one dollar' } ; return "$(ConvertTo-Words $dollars) dollars" }
  if ($dollars -eq 0)  { return "$(ConvertTo-Words $rem) cents" }
  $centWords = if ($rem -lt 10) { "oh $(ConvertTo-Words $rem)" } else { ConvertTo-Words $rem }
  if ($dollars -eq 1)  { return "a dollar $centWords" }
  return "$(ConvertTo-Words $dollars) $centWords"
}

function Format-Money { param([double]$A) '$' + $A.ToString('0.00') }
