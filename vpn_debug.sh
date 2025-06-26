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
echo "Checking if .env file exists:"
if [ -f /app/.env ]; then
    echo "✓ .env file found at /app/.env"
    echo "File size: $(stat -c%s /app/.env) bytes"
    echo "First few lines (non-sensitive):"
    head -3 /app/.env | grep -v "PASSWORD\|KEY" || echo "No non-sensitive lines to show"
else
    echo "✗ .env file NOT found at /app/.env"
    echo "Available files in /app/:"
    ls -la /app/
fi
echo ""
echo "Environment variables from shell:"
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

# Create a proper secrets file using Python (same as monitor does)
echo "=== Creating Secrets File with Python ==="
python3 -c "
import os
from dotenv import load_dotenv
load_dotenv('/app/.env')
servers = os.getenv('VPN_SERVERS', '').split(',')
if servers and servers[0]:
    parts = servers[0].strip().split(':')
    if len(parts) >= 5:
        server_ip = parts[1]
        shared_key = parts[4]
        secrets_content = f'''# strongSwan IPsec secrets file
{server_ip} %any : PSK \"{shared_key}\"
%any {server_ip} : PSK \"{shared_key}\"
'''
        with open('/etc/ipsec.secrets', 'w') as f:
            f.write(secrets_content)
        print(f'✓ Created secrets file for {server_ip}')
        print(f'✓ Shared key length: {len(shared_key)} characters')
    else:
        print('✗ Invalid server configuration format')
else:
    print('✗ No VPN servers found')
" 2>/dev/null || echo "Failed to create secrets file with Python"

# Set proper permissions
chmod 600 /etc/ipsec.secrets

echo ""
echo "=== Secrets File After Python Creation ==="
if [ -f /etc/ipsec.secrets ]; then
    echo "Secrets file content (with masked keys):"
    cat /etc/ipsec.secrets | sed 's/PSK "[^"]*"/PSK "***MASKED***"/g'
else
    echo "No secrets file found"
fi
echo ""

# Start tcpdump in background to capture traffic
echo "Starting packet capture..."
timeout 30 tcpdump -i any -n host $SERVER_IP and \( port 500 or port 4500 or port 1701 \) -w /tmp/vpn_debug.pcap 2>/dev/null &
TCPDUMP_PID=$!

# Wait for tcpdump to start
sleep 2

# Reload strongSwan to pick up new secrets
echo "Reloading strongSwan with new secrets..."
ipsec reload
sleep 2

# Try to bring up the connection
echo "Executing: ipsec up vpntest"
timeout 20 ipsec up vpntest 2>&1 | tee /tmp/ipsec_up_output.log

# Wait a bit for connection attempt
sleep 5

# Check status
echo ""
echo "=== Connection Status After Up Command ==="
ipsec statusall
echo ""

# Stop tcpdump
if [ ! -z "$TCPDUMP_PID" ]; then
    kill $TCPDUMP_PID 2>/dev/null || echo "tcpdump already stopped"
    wait $TCPDUMP_PID 2>/dev/null || true
fi

echo "=== Packet Capture Analysis ==="
if [ -f /tmp/vpn_debug.pcap ]; then
    echo "Total packets captured:"
    tcpdump -r /tmp/vpn_debug.pcap -n 2>/dev/null | wc -l
    echo ""
    echo "First 10 packets:"
    tcpdump -r /tmp/vpn_debug.pcap -n 2>/dev/null | head -10
    echo ""
    echo "Packet summary by port:"
    tcpdump -r /tmp/vpn_debug.pcap -n 2>/dev/null | grep -E "(500|4500|1701)" | cut -d' ' -f1-5 | sort | uniq -c
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
echo "Skipping IKE version tests for now - focusing on basic connection"
echo ""

echo "=== Connection Attempt Results Analysis ==="
if [ -f /tmp/ipsec_up_output.log ]; then
    echo "IPSec up command output:"
    cat /tmp/ipsec_up_output.log
    echo ""
    
    # Analyze common error patterns
    if grep -q "no proposal chosen" /tmp/ipsec_up_output.log; then
        echo "❌ ISSUE: Encryption algorithm mismatch"
        echo "   The server rejected our encryption proposals"
    elif grep -q "authentication failed" /tmp/ipsec_up_output.log; then
        echo "❌ ISSUE: Authentication failed"
        echo "   Likely incorrect shared key"
    elif grep -q "timeout" /tmp/ipsec_up_output.log; then
        echo "❌ ISSUE: Connection timeout"
        echo "   Server may be unreachable or firewall blocking"
    elif grep -q "ESTABLISHED" /tmp/ipsec_up_output.log; then
        echo "✅ SUCCESS: IPSec tunnel established!"
    else
        echo "⚠️  Unknown result - check output above"
    fi
else
    echo "No connection attempt log found"
fi
echo ""

echo "=== Cleanup ==="
echo "Stopping all VPN connections..."
timeout 5 ipsec down vpntest 2>/dev/null || true
ipsec stop
echo ""

echo "=== Debug Files Created ==="
echo "- /tmp/ipsec_up_output.log - IPSec up command output"
echo "- /tmp/vpn_debug.pcap - Network packet capture"
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