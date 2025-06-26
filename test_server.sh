#!/bin/bash
# Simple server connectivity test script
# Tests various aspects of VPN server connectivity
#
# This script only tests network connectivity and doesn't require VPN resources.
# It can be run alongside the VPN monitor without conflicts.

set -e

if [ $# -eq 0 ]; then
    echo "Usage: $0 <server_ip_or_hostname>"
    echo "Example: $0 nas1.italic.fr"
    exit 1
fi

SERVER="$1"
echo "=== Testing VPN Server: $SERVER ==="
echo "Started at: $(date)"
echo ""

# Resolve hostname if needed
echo "=== DNS Resolution ==="
if [[ "$SERVER" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    SERVER_IP="$SERVER"
    echo "Using IP address directly: $SERVER_IP"
else
    echo "Resolving hostname: $SERVER"
    SERVER_IP=$(dig +short "$SERVER" | head -1)
    if [ -z "$SERVER_IP" ]; then
        echo "❌ DNS resolution failed for $SERVER"
        exit 1
    else
        echo "✅ Resolved to: $SERVER_IP"
    fi
fi
echo ""

# Basic connectivity
echo "=== Basic Connectivity ==="
if ping -c 3 -W 5 "$SERVER_IP" >/dev/null 2>&1; then
    echo "✅ ICMP ping successful"
    ping -c 1 "$SERVER_IP" | grep "time="
else
    echo "❌ ICMP ping failed"
fi
echo ""

# Port testing
echo "=== VPN Port Testing ==="
declare -A VPN_PORTS=(
    ["500"]="IKE (Internet Key Exchange)"
    ["4500"]="IPSec NAT-T"
    ["1701"]="L2TP"
    ["1723"]="PPTP (alternative)"
)

for port in "${!VPN_PORTS[@]}"; do
    echo -n "Testing UDP $port (${VPN_PORTS[$port]}): "
    if timeout 3 bash -c "echo -n | nc -u $SERVER_IP $port" 2>/dev/null; then
        echo "✅ Responds"
    else
        echo "❌ No response"
    fi
done
echo ""

# TCP ports (some servers use TCP for control)
echo "=== TCP Port Testing ==="
declare -A TCP_PORTS=(
    ["500"]="IKE TCP"
    ["4500"]="IPSec TCP"
    ["1701"]="L2TP TCP"
)

for port in "${!TCP_PORTS[@]}"; do
    echo -n "Testing TCP $port (${TCP_PORTS[$port]}): "
    if timeout 3 bash -c "echo -n | nc $SERVER_IP $port" 2>/dev/null; then
        echo "✅ Responds"
    else
        echo "❌ No response"
    fi
done
echo ""

# Traceroute to see network path
echo "=== Network Path Analysis ==="
echo "Traceroute to $SERVER_IP (first 10 hops):"
traceroute -n -m 10 "$SERVER_IP" 2>/dev/null | head -12 || echo "Traceroute not available"
echo ""

# MTU discovery
echo "=== MTU Discovery ==="
echo "Testing different packet sizes to detect MTU issues:"
for size in 1500 1400 1300 1200 1000; do
    if ping -c 1 -M do -s $((size-28)) "$SERVER_IP" >/dev/null 2>&1; then
        echo "✅ $size bytes: OK"
        break
    else
        echo "❌ $size bytes: Failed (may indicate MTU limit)"
    fi
done
echo ""

# Check if server responds to IKE probes
echo "=== IKE Protocol Testing ==="
echo "Attempting to send IKE probe packets..."

# Create a simple IKE_SA_INIT packet probe
timeout 5 bash -c "
    # Send a basic UDP packet to port 500 and see if we get any response
    exec 3<>/dev/udp/$SERVER_IP/500
    echo -n 'test' >&3
    read -t 2 response <&3 2>/dev/null && echo 'Got response' || echo 'No response'
    exec 3<&-
    exec 3>&-
" 2>/dev/null || echo "IKE probe test failed"
echo ""

echo "=== Summary ==="
echo "Server: $SERVER ($SERVER_IP)"
echo "Basic connectivity: $(ping -c 1 -W 2 "$SERVER_IP" >/dev/null 2>&1 && echo "✅ Working" || echo "❌ Failed")"
echo "UDP 500 (IKE): $(timeout 2 bash -c "echo -n | nc -u $SERVER_IP 500" 2>/dev/null && echo "✅ Responds" || echo "❌ No response")"
echo "UDP 4500 (NAT-T): $(timeout 2 bash -c "echo -n | nc -u $SERVER_IP 4500" 2>/dev/null && echo "✅ Responds" || echo "❌ No response")"
echo "UDP 1701 (L2TP): $(timeout 2 bash -c "echo -n | nc -u $SERVER_IP 1701" 2>/dev/null && echo "✅ Responds" || echo "❌ No response")"
echo ""
echo "=== Recommendations ==="
if timeout 2 bash -c "echo -n | nc -u $SERVER_IP 500" 2>/dev/null; then
    echo "✅ Server appears to be responding on VPN ports"
    echo "   - Try different IKE parameters or authentication"
    echo "   - Check shared key configuration"
    echo "   - Verify server supports your client type"
else
    echo "❌ Server not responding on VPN ports"
    echo "   - Check server firewall configuration"
    echo "   - Verify server is running VPN service"
    echo "   - Contact server administrator"
    echo "   - Try connecting from different network"
fi
echo ""
echo "Completed at: $(date)"