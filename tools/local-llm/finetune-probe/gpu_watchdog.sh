#!/bin/bash
# Thermal watchdog. Samples every 5 s, logs every reading, KILLS the training
# process itself at the abort line. Abort is ~10 C under the card's own throttle.
SP="/c/Users/Owner/AppData/Local/Temp/claude/C--Codex-ThriftyCrew/ec9e4d31-4247-4a63-82e1-edcbd19bd7d3/scratchpad"
LOG="$SP/gpu-watch.log"; PIDF="$SP/train.pid"
ABORT_T=84; ABORT_HEAD=6; YEL_T=75; YEL_HEAD=15
n=0; state=green; maxt=0
while true; do
  IFS=',' read -r t fan pwr mem util <<<"$(nvidia-smi --query-gpu=temperature.gpu,fan.speed,power.draw,memory.used,utilization.gpu --format=csv,noheader,nounits 2>/dev/null)"
  t=${t// /}; fan=${fan// /}; pwr=${pwr// /}; pwr=${pwr%.*}; mem=${mem// /}; util=${util// /}
  head=$(nvidia-smi -q -d TEMPERATURE 2>/dev/null | grep "GPU T.Limit Temp" | awk '{print $(NF-1)}')
  [[ "$head" =~ ^-?[0-9]+$ ]] || head=99
  [[ "$t" =~ ^[0-9]+$ ]] || t=0
  flags=$(nvidia-smi --query-gpu=clocks_throttle_reasons.hw_thermal_slowdown,clocks_throttle_reasons.sw_thermal_slowdown --format=csv,noheader 2>/dev/null)
  thermal=$(echo "$flags" | tr ',' '\n' | grep -c -E '^\s*Active\s*$')
  ts=$(date +%H:%M:%S)
  [ "$t" -gt "$maxt" ] && maxt=$t
  echo "$ts temp=$t head=$head fan=$fan% pwr=${pwr}W mem=${mem}MiB util=$util% thermal=$thermal" >> "$LOG"
  if [ "$t" -ge $ABORT_T ] || [ "$head" -le $ABORT_HEAD ] || [ "$thermal" -gt 0 ]; then
    pid=$(cat "$PIDF" 2>/dev/null)
    [ -n "$pid" ] && taskkill //F //PID "$pid" >/dev/null 2>&1
    echo "ABORT $ts temp=$t head=$head thermal=$thermal -> killed training pid=$pid (max seen ${maxt}C)"
    echo "ABORT $ts killed pid=$pid" >> "$LOG"; exit 3
  fi
  if [ "$t" -ge $YEL_T ] || [ "$head" -le $YEL_HEAD ]; then new=yellow; else new=green; fi
  if [ "$new" != "$state" ]; then echo "$ts -> $new  temp=$t head=$head pwr=${pwr}W fan=$fan%"; state=$new; fi
  n=$((n+1)); [ $((n % 60)) -eq 0 ] && echo "$ts HB temp=$t head=$head fan=$fan% pwr=${pwr}W mem=${mem}MiB util=$util% (max ${maxt}C)"
  if [ -f "$SP/train.done" ]; then echo "$ts DONE training finished; temp=$t max seen ${maxt}C"; exit 0; fi
  sleep 5
done
