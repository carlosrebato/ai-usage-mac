#!/bin/sh

set -eu

if [ "$#" -lt 1 ] || [ "$#" -gt 4 ]; then
  echo "Usage: $0 PID [duration-seconds] [interval-seconds] [report.csv]" >&2
  exit 2
fi

PID="$1"
DURATION="${2:-3600}"
INTERVAL="${3:-10}"
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
REPORT="${4:-$ROOT/.artifacts/release-performance.csv}"
PROBE="${TMPDIR:-/private/tmp}/ai-usage-process-usage-probe-$$"

case "$PID:$DURATION:$INTERVAL" in
  *[!0-9:]*|:*|*::*|*:) echo "PID, duration and interval must be positive integers." >&2; exit 2 ;;
esac
[ "$PID" -gt 0 ] && [ "$DURATION" -gt 0 ] && [ "$INTERVAL" -gt 0 ] || {
  echo "PID, duration and interval must be positive integers." >&2
  exit 2
}

mkdir -p "$(dirname -- "$REPORT")"
cc -Wall -Wextra -Werror "$ROOT/Scripts/process-usage-probe.c" -o "$PROBE"
trap 'rm -f "$PROBE"' EXIT HUP INT TERM

SAMPLES=$((DURATION / INTERVAL))
[ "$SAMPLES" -gt 0 ] || SAMPLES=1
echo "timestamp,cpu_percent,rss_kb,resident_bytes,physical_footprint_bytes,disk_read_bytes,disk_write_bytes" > "$REPORT"

sample=1
while [ "$sample" -le "$SAMPLES" ]; do
  kill -0 "$PID" 2>/dev/null || {
    echo "Process $PID exited before the measurement completed." >&2
    exit 1
  }

  PROCESS_SAMPLE="$(ps -p "$PID" -o %cpu=,rss= | awk '{$1=$1; print}')"
  CPU="$(printf '%s\n' "$PROCESS_SAMPLE" | awk '{print $1}')"
  RSS="$(printf '%s\n' "$PROCESS_SAMPLE" | awk '{print $2}')"
  USAGE="$($PROBE "$PID")"
  TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '%s,%s,%s,%s\n' "$TIMESTAMP" "$CPU" "$RSS" "$USAGE" >> "$REPORT"

  if [ "$sample" -eq 1 ] || [ $((sample % 6)) -eq 0 ]; then
    echo "Performance sample $sample/$SAMPLES: CPU ${CPU}%, RSS $((RSS / 1024)) MB"
  fi

  sample=$((sample + 1))
  [ "$sample" -gt "$SAMPLES" ] || sleep "$INTERVAL"
done

awk -F, '
  NR == 2 {
    firstRead = $6; firstWrite = $7;
    minCPU = maxCPU = $2;
    minRSS = maxRSS = $3;
  }
  NR > 1 {
    count++;
    cpu += $2; rss += $3; footprint += $5;
    if ($2 < minCPU) minCPU = $2;
    if ($2 > maxCPU) maxCPU = $2;
    if ($3 < minRSS) minRSS = $3;
    if ($3 > maxRSS) maxRSS = $3;
    lastRead = $6; lastWrite = $7;
  }
  END {
    printf "Samples: %d\n", count;
    printf "Average CPU: %.3f%% (max %.3f%%)\n", cpu / count, maxCPU;
    printf "Average RSS: %.2f MB (min %.2f, max %.2f)\n", rss / count / 1024, minRSS / 1024, maxRSS / 1024;
    printf "Average physical footprint: %.2f MB\n", footprint / count / 1048576;
    printf "Disk read during measurement: %.2f MB\n", (lastRead - firstRead) / 1048576;
    printf "Disk written during measurement: %.2f MB\n", (lastWrite - firstWrite) / 1048576;
  }
' "$REPORT"

echo "Performance report: $REPORT"
