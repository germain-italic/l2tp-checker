#!/bin/bash
# Docker VPN Monitor Continuous Wrapper Script
# Runs VPN monitoring continuously with internal scheduling
#
# This script runs the VPN monitor in continuous mode with internal polling.
# The container stays running and monitors VPN connections at regular intervals.

set -e

echo "=== Continuous VPN Monitor Starting ==="
echo "Monitor PID: $$"
echo "Container hostname: $(hostname)"
echo "Start time: $(date)"
echo ""
echo "ℹ️  This container runs continuous VPN monitoring with internal scheduling."
echo "ℹ️  Check .env file for POLL_INTERVAL_MINUTES configuration."
echo ""
echo "🔧 To run debug scripts, stop this container first:"
echo "  docker-compose down"
echo "  docker-compose run --rm vpn-monitor /app/synology_debug.sh"
echo ""
echo "📊 To run a single test (no continuous monitoring):"
echo "  docker-compose run --rm vpn-monitor python3 /app/vpn_monitor.py --single-run"
echo ""

cd "$(dirname "$0")"

# Execute the VPN monitor in continuous mode
exec python3 vpn_monitor.py "$@"