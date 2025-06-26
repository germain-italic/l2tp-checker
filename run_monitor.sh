#!/bin/bash
# Docker VPN Monitor Wrapper Script
# Simplified for container environment
#
# This script runs the main VPN monitoring loop.
# Do not run debug scripts while this is active - they will conflict.

set -e

echo "=== VPN Monitor Starting ==="
echo "Monitor PID: $$"
echo "Container hostname: $(hostname)"
echo "Start time: $(date)"
echo ""
echo "IMPORTANT: While this monitor is running, debug scripts will conflict."
echo "To run debug scripts, stop this container first:"
echo "  docker-compose down"
echo "  docker-compose run --rm vpn-monitor /app/synology_debug.sh"
echo ""

cd "$(dirname "$0")"

# Execute the VPN monitor directly with Python 3
exec python3 vpn_monitor.py "$@"