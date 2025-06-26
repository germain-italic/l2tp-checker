#!/bin/bash
# Docker VPN Monitor Wrapper Script
# Simplified for container environment

set -e

cd "$(dirname "$0")"

# Execute the VPN monitor directly with Python 3
exec python3 vpn_monitor.py "$@"