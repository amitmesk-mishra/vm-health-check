#!/usr/bin/env bash
# vm_health_check.sh
# Checks CPU, memory and root-disk utilization on Ubuntu VMs.
# Declares VM "healthy" only if ALL metrics are below THRESHOLD (default 60%).
# Usage:
#   ./vm_health_check.sh            # prints "HEALTHY" or "NOT HEALTHY" and the three metrics
#   ./vm_health_check.sh explain    # also prints explanation of metrics/reasons

set -euo pipefail

THRESHOLD=60

# Print usage
usage() {
  cat <<EOF
Usage: $0 [explain]
  explain   Print the measured values and the reason for the health decision.
EOF
  exit 2
}

# Parse args
EXPLAIN=false
if [ "$#" -gt 1 ]; then
  usage
fi
if [ "$#" -eq 1 ]; then
  if [ "$1" = "explain" ]; then
    EXPLAIN=true
  else
    usage
  fi
fi

# Get CPU utilization by reading /proc/stat twice (1s apart) and computing difference.
get_cpu_usage() {
  # Read first snapshot
  read -r cpu user nice system idle iowait irq softirq steal guest guest_nice < /proc/stat
  total1=$((user + nice + system + idle + iowait + irq + softirq + steal + guest + guest_nice))
  idle1=$((idle + iowait))

  sleep 1

  # Read second snapshot
  read -r cpu user2 nice2 system2 idle2 iowait2 irq2 softirq2 steal2 guest2 guest_nice2 < /proc/stat
  total2=$((user2 + nice2 + system2 + idle2 + iowait2 + irq2 + softirq2 + steal2 + guest2 + guest_nice2))
  idle2=$((idle2 + iowait2))

  total_delta=$((total2 - total1))
  idle_delta=$((idle2 - idle1))

  if [ "$total_delta" -le 0 ]; then
    echo "0.0"
    return
  fi

  # usage = 100 * (1 - idle_delta / total_delta)
  usage=$(awk -v td="$total_delta" -v id="$idle_delta" 'BEGIN { printf "%.1f", (1 - id/td)*100 }')
  echo "$usage"
}

# Get memory utilization: use (total - available) / total * 100
get_mem_usage() {
  # Capture fields from free -b in a portable way
  # Fields: label total used free shared buff cache available available
  set -- $(free -b | awk '/^Mem:/ {print $1, $2, $3, $4, $5, $6, $7, $7}')
  mem_total=$2
  mem_available=$8

  if [ -z "$mem_total" ] || [ "$mem_total" -eq 0 ]; then
    echo "0.0"
    return
  fi
  mem_used=$((mem_total - mem_available))
  mem_pct=$(awk -v used="$mem_used" -v tot="$mem_total" 'BEGIN { printf "%.1f", (used / tot) * 100 }')
  echo "$mem_pct"
}

# Get disk utilization for root (/) filesystem.
get_disk_usage() {
  # Use POSIX df output (-P) and parse percent for mount "/"
  pct=$(df -P / | awk 'NR==2 {gsub("%","",$5); print $5}')
  # ensure decimal format using portable checks
  if echo "$pct" | grep -E -q '^[0-9]+$'; then
    echo "${pct}.0"
  else
    # try df --output
    pct2=$(df --output=pcent / 2>/dev/null | tail -n1 | tr -dc '0-9.')
    if [ -n "$pct2" ]; then
      if echo "$pct2" | grep -q '\.'; then
        echo "$pct2"
      else
        echo "${pct2}.0"
      fi
    else
      echo "0.0"
    fi
  fi
}

# Compare float a < b ; returns 0 if true, 1 if false
float_lt() {
  awk -v a="$1" -v b="$2" 'BEGIN { exit !(a < b) }'
}

# Main
cpu_used=$(get_cpu_usage)
mem_used=$(get_mem_usage)
disk_used=$(get_disk_usage)

# Health decision:
# Healthy if ALL metrics are strictly less than THRESHOLD
is_cpu_ok=1
is_mem_ok=1
is_disk_ok=1

if float_lt "$cpu_used" "$THRESHOLD"; then
  is_cpu_ok=0
fi
if float_lt "$mem_used" "$THRESHOLD"; then
  is_mem_ok=0
fi
if float_lt "$disk_used" "$THRESHOLD"; then
  is_disk_ok=0
fi

if [ "$is_cpu_ok" -eq 0 ] && [ "$is_mem_ok" -eq 0 ] && [ "$is_disk_ok" -eq 0 ]; then
  HEALTH="HEALTHY"
  EXIT_CODE=0
else
  HEALTH="NOT HEALTHY"
  EXIT_CODE=1
fi

# Print short status
echo "$HEALTH"

# Always print measured values (CPU / Mem / Disk)
printf "CPU:    %6s%%\n" "$cpu_used"
printf "Memory: %6s%%\n" "$mem_used"
printf "Disk(/):%6s%%\n" "$disk_used"

# Explain if requested
if [ "$EXPLAIN" = true ]; then
  echo "Threshold: ${THRESHOLD}% (a metric >= ${THRESHOLD}% is considered unhealthy)"
  printf "CPU utilization:    %6s%%   -> %s\n" "$cpu_used" "$(awk -v v="$cpu_used" -v t="$THRESHOLD" 'BEGIN{print (v>=t? "EXCEEDS":"OK") }')"
  printf "Memory utilization: %6s%%   -> %s\n" "$mem_used" "$(awk -v v="$mem_used" -v t="$THRESHOLD" 'BEGIN{print (v>=t? "EXCEEDS":"OK") }')"
  printf "Disk (/) utilization: %6s%%   -> %s\n" "$disk_used" "$(awk -v v="$disk_used" -v t="$THRESHOLD" 'BEGIN{print (v>=t? "EXCEEDS":"OK") }')"

  # If not healthy, show which metric(s) caused it
  if [ "$HEALTH" = "NOT HEALTHY" ]; then
    echo "Reason(s):"
    if awk -v v="$cpu_used" -v t="$THRESHOLD" 'BEGIN{exit !(v>=t)}'; then
      echo " - CPU utilization is >= ${THRESHOLD}%"
    fi
    if awk -v v="$mem_used" -v t="$THRESHOLD" 'BEGIN{exit !(v>=t)}'; then
      echo " - Memory utilization is >= ${THRESHOLD}%"
    fi
    if awk -v v="$disk_used" -v t="$THRESHOLD" 'BEGIN{exit !(v>=t)}'; then
      echo " - Disk (/) utilization is >= ${THRESHOLD}%"
    fi
  else
    echo "All metrics are under ${THRESHOLD}%. VM is healthy."
  fi
fi

exit $EXIT_CODE
