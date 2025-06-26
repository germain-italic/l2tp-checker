#!/bin/bash
# Comprehensive VPN Debug Script for L2TP/IPSec testing
# This script performs manual testing and debugging of VPN connections

set -e

echo "=== VPN Debug Script Started at $(date) ==="
echo ""

# Get server info from environment
SERVER_INFO=$(python3 -c "
import os
from dotenv import load_dotenv
load_dotenv()
servers = os.getenv('VPN_SERVERS', '').split(',')
if servers and servers[0]:
    parts = servers[0].strip().split(':')
    if len(parts) >= 2:
        print(f'{parts[0]} {parts[1]}')
    else:
        print('server1 example.com')
else:
    print('server1 example.com')
")

SERVER_NAME=$(echo $SERVER_INFO | cut -d' ' -f1)
SERVER_IP=$(echo $SERVER_INFO | cut -d' ' -f2)

echo "=== Testing Server: $SERVER_NAME ($SERVER_IP) ==="
echo ""

echo "=== Basic Connectivity Test ==="
ping -c 3 $SERVER_IP || echo "Ping failed - server may be unreachable"
echo ""

echo "=== Port Connectivity Test ==="
echo "Testing UDP port 500 (IKE):"
timeout 5 nc -u -v $SERVER_IP 500 2>&1 || echo "UDP 500 connection failed"
echo ""
echo "Testing UDP port 4500 (NAT-T):"
timeout 5 nc -u -v $SERVER_IP 4500 2>&1 || echo "UDP 4500 connection failed"
echo ""
echo "Testing UDP port 1701 (L2TP):"
timeout 5 nc -u -v $SERVER_IP 1701 2>&1 || echo "UDP 1701 connection failed"
echo ""

echo "=== Current IPSec Configuration ==="
if [ -f /etc/ipsec.conf ]; then
    cat /etc/ipsec.conf
else
    echo "No IPSec configuration found"
fi
echo ""

echo "=== IPSec Secrets (first line) ==="
if [ -f /etc/ipsec.secrets ]; then
    echo "Secrets file exists, showing first 5 lines (masking actual keys):"
    head -5 /etc/ipsec.secrets | sed 's/PSK "[^"]*"/PSK "***MASKED***"/g'
else
    echo "No IPSec secrets found"
fi
echo ""

echo "=== Stopping all VPN services ==="
ipsec stop 2>/dev/null || echo "IPSec already stopped"
killall -9 charon starter xl2tpd pppd 2>/dev/null || echo "No VPN processes to kill"
sleep 2
echo ""

echo "=== Starting strongSwan manually ==="
echo "Starting strongSwan service..."
ipsec start
sleep 5
echo ""

echo "=== Checking strongSwan Status ==="
ipsec status
echo ""

echo "=== Detailed strongSwan Status ==="
ipsec statusall
echo ""

echo "=== Reloading Configuration ==="
ipsec reload
sleep 3
echo ""

echo "=== Configuration Check After Reload ==="
ipsec statusall
echo ""

echo "=== Environment Variables Check ==="
echo "VPN_SERVERS (first 50 chars): ${VPN_SERVERS:0:50}..."
echo "DB_HOST: $DB_HOST"
echo "Monitor ID: $MONITOR_ID"
echo ""

echo "=== Python Environment Test ==="
python3 -c "
import os
from dotenv import load_dotenv
load_dotenv()
servers = os.getenv('VPN_SERVERS', '')
print(f'VPN_SERVERS from Python: {servers[:50]}...')
if servers:
    parts = servers.split(',')[0].split(':')
    print(f'First server parts count: {len(parts)}')
    if len(parts) >= 5:
        print(f'Server name: {parts[0]}')
        print(f'Server IP: {parts[1]}')
        print(f'Username: {parts[2]}')
        print(f'Shared key length: {len(parts[4])} chars')
    else:
        print('Invalid server configuration format')
else:
    print('No VPN_SERVERS found')
"
echo ""

echo "=== Manual Connection Attempt ==="
echo "Attempting to bring up connection 'vpntest'..."

# Start tcpdump in background to capture traffic
echo "Starting packet capture..."
timeout 30 tcpdump -i any -n host $SERVER_IP and port 500 -w /tmp/vpn_debug.pcap &
TCPDUMP_PID=$!

# Wait for tcpdump to start
sleep 2

# Try to bring up the connection
echo "Executing: ipsec up vpntest"
ipsec up vpntest 2>&1 | tee /tmp/ipsec_up_output.log

# Wait a bit for connection attempt
sleep 10

# Check status
echo ""
echo "=== Connection Status After Up Command ==="
ipsec statusall
echo ""

# Stop tcpdump
kill $TCPDUMP_PID 2>/dev/null || echo "tcpdump already stopped"
wait $TCPDUMP_PID 2>/dev/null || true

echo "=== Packet Capture Analysis ==="
if [ -f /tmp/vpn_debug.pcap ]; then
    echo "Packets captured:"
    tcpdump -r /tmp/vpn_debug.pcap -n | head -20
    echo ""
    echo "Packet count by type:"
    tcpdump -r /tmp/vpn_debug.pcap -n | cut -d' ' -f1-5 | sort | uniq -c
else
    echo "No packet capture file found"
fi
echo ""

echo "=== System Network Information ==="
echo "Network interfaces:"
ip addr show | grep -E "(inet|UP|DOWN)"
echo ""
echo "Routing table:"
ip route
echo ""

echo "=== Process Information ==="
echo "VPN-related processes:"
ps aux | grep -E "(ipsec|charon|xl2tpd|pppd)" | grep -v grep || echo "No VPN processes found"
echo ""

echo "=== Log Analysis ==="
echo "Recent strongSwan logs from syslog:"
if [ -f /var/log/syslog ]; then
    tail -20 /var/log/syslog | grep -E "(ipsec|charon|strongswan)" || echo "No recent strongSwan logs"
elif [ -f /var/log/messages ]; then
    tail -20 /var/log/messages | grep -E "(ipsec|charon|strongswan)" || echo "No recent strongSwan logs"
else
    echo "No system log files found"
fi
echo ""

echo "=== Testing Different IKE Versions ==="
echo "Current configuration uses IKEv1. Let's test if server supports IKEv2..."

# Create a temporary IKEv2 configuration
cat > /tmp/ipsec_ikev2.conf << EOF
config setup
    charondebug="ike 2, knl 1, cfg 1"
    strictcrlpolicy=no
    uniqueids=no

conn vpntest_ikev2
    type=transport
    keyexchange=ikev2
    left=%defaultroute
    leftprotoport=17/1701
    right=$SERVER_IP
    rightprotoport=17/1701
    authby=psk
    auto=add
    ike=aes256-sha256-modp2048,aes128-sha256-modp2048!
    esp=aes256-sha256,aes128-sha256!
    rekey=no
    leftid=%any
    rightid=$SERVER_IP
EOF

echo "Testing with IKEv2 configuration..."
cp /tmp/ipsec_ikev2.conf /etc/ipsec.conf
ipsec reload
sleep 3
echo "Attempting IKEv2 connection:"
timeout 15 ipsec up vpntest_ikev2 2>&1 || echo "IKEv2 connection failed"
echo ""

echo "=== Testing Different Encryption Algorithms ==="
# Test with weaker encryption (some older servers only support this)
cat > /tmp/ipsec_weak.conf << EOF
config setup
    charondebug="ike 2, knl 1, cfg 1"
    strictcrlpolicy=no
    uniqueids=no

conn vpntest_weak
    type=transport
    keyexchange=ikev1
    left=%defaultroute
    leftprotoport=17/1701
    right=$SERVER_IP
    rightprotoport=17/1701
    authby=psk
    auto=add
    ike=3des-md5-modp1024!
    esp=3des-md5!
    rekey=no
    leftid=%any
    rightid=$SERVER_IP
    aggressive=yes
EOF

echo "Testing with weaker encryption (3DES-MD5)..."
cp /tmp/ipsec_weak.conf /etc/ipsec.conf
ipsec reload
sleep 3
echo "Attempting weak encryption connection:"
timeout 15 ipsec up vpntest_weak 2>&1 || echo "Weak encryption connection failed"
echo ""

echo "=== Cleanup ==="
echo "Stopping all VPN connections..."
ipsec down vpntest 2>/dev/null || true
ipsec down vpntest_ikev2 2>/dev/null || true
ipsec down vpntest_weak 2>/dev/null || true
ipsec stop
echo ""

echo "=== Debug Files Created ==="
echo "- /tmp/ipsec_up_output.log - IPSec up command output"
echo "- /tmp/vpn_debug.pcap - Network packet capture"
echo "- /tmp/ipsec_ikev2.conf - IKEv2 test configuration"
echo "- /tmp/ipsec_weak.conf - Weak encryption test configuration"
echo ""

echo "=== Recommendations ==="
echo "Based on the debug output above:"
echo "1. Check if ping to $SERVER_IP works (basic connectivity)"
echo "2. Check if UDP ports 500, 4500, 1701 are reachable"
echo "3. Look for 'ESTABLISHED' in strongSwan status output"
echo "4. Check packet capture for IKE responses from server"
echo "5. Review strongSwan logs for authentication errors"
echo "6. Verify shared key is correct in .env file"
echo ""

echo "=== VPN Debug Script Completed at $(date) ==="