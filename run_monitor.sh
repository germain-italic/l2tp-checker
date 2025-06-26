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
echo "Running single VPN test cycle..."
echo ""

cd "$(dirname "$0")"

# Execute the VPN monitor directly with Python 3
python3 vpn_monitor.py "$@"

echo ""
echo "=== VPN Monitor Completed ==="
echo "End time: $(date)"
echo "Check database for results"