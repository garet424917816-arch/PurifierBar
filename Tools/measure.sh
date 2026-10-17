#!/bin/bash
# Process resource measurements: average and peak CPU, phys_footprint (own memory),
# RSS (including shared framework pages - for SwiftUI always ~80 MB), wake-ups.
#   measure.sh <process name|PID> [seconds=60]
# Budget: panel closed - average < 0.3 % CPU, < 40 MB phys_footprint;
# panel open - < 5 % CPU.
set -euo pipefail
target="${1:?process}"; secs="${2:-60}"
if [[ "$target" =~ ^[0-9]+$ ]]; then pid="$target"; else pid="$(pgrep -nx "$target")" || { echo "measure.sh: $target not running" >&2; exit 1; }; fi
idlew() { top -l 1 -pid "$pid" -stats pid,idlew 2>/dev/null | awk -v p="$pid" '$1==p{print $2+0}'; }
start_cpu="$(ps -o time= -p "$pid" | tr -d ' ')"; start_w="$(idlew)"
to_sec() { awk -F'[:.]' '{ if (NF==3) print $1*60+$2+$3/100; else print $1*3600+$2*60+$3+$4/100 }' <<<"$1"; }
peak=0; rss_max=0
for _ in $(seq "$secs"); do
    read -r cpu rss < <(ps -o %cpu=,rss= -p "$pid")
    peak="$(awk -v a="$peak" -v b="$cpu" 'BEGIN{print (b>a)?b:a}')"
    (( rss > rss_max )) && rss_max=$rss
    sleep 1
done
end_cpu="$(ps -o time= -p "$pid" | tr -d ' ')"
avg="$(awk -v a="$(to_sec "$start_cpu")" -v b="$(to_sec "$end_cpu")" -v s="$secs" 'BEGIN{printf "%.2f", (b-a)/s*100}')"
wakeups="$(awk -v a="$start_w" -v b="$(idlew)" -v s="$secs" 'BEGIN{printf "%.1f", (b-a)/s}')"
fp="$(footprint -p "$pid" 2>/dev/null | awk -F': ' '/phys_footprint:/{print $2; exit}')"
echo "pid $pid · ${secs}s · CPU avg ${avg}% · CPU peak ${peak}% · footprint ${fp:-?} · RSS max $((rss_max/1024)) MB (with shared frameworks) · idle wakeups/s ${wakeups}"
