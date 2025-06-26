#!/bin/bash
# Synology DSM7 L2TP/IPSec Debug Script
# Specifically designed for Synology NAS VPN servers

set -e

echo "=== Synology DSM7 VPN Debug Script Started at $(date) ==="
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

echo "=== Testing Synology Server: $SERVER_NAME ($SERVER_IP) ==="
echo ""

echo "=== Basic Connectivity Test ==="
ping -c 3 $SERVER_IP || echo "Ping failed - server may be unreachable"
echo ""

echo "=== Stopping all VPN services ==="
ipsec stop 2>/dev/null || echo "IPSec already stopped"
killall -9 charon starter xl2tpd pppd 2>/dev/null || echo "No VPN processes to kill"
sleep 2
echo ""

echo "=== Creating Synology-Compatible IPSec Configuration ==="

# Create Synology-optimized configuration
cat > /etc/ipsec.conf << EOF
config setup
    charondebug="ike 2, knl 1, cfg 1"
    strictcrlpolicy=no
    uniqueids=no

conn synology
    type=transport
    keyexchange=ikev1
    left=%defaultroute
    leftprotoport=17/1701
    right=$SERVER_IP
    rightprotoport=17/1701
    authby=psk
    auto=add
    ike=3des-sha1-modp1024,aes128-sha1-modp1024!
    esp=3des-sha1,aes128-sha1!
    rekey=no
    leftid=%any
    rightid=$SERVER_IP
    aggressive=yes
    ikelifetime=8h
    keylife=1h
    dpdaction=clear
    dpddelay=300s
    dpdtimeout=90s
    forceencaps=yes
EOF

echo "✓ Created Synology-compatible IPSec configuration"
echo ""

echo "=== Creating IPSec Secrets ==="
# Create secrets file using Python (same as monitor does)
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
        secrets_content = f'''# strongSwan IPsec secrets file for Synology
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
"

chmod 600 /etc/ipsec.secrets
echo ""

echo "=== Starting strongSwan for Synology ==="
ipsec start
sleep 5
echo ""

echo "=== Loading Synology Configuration ==="
ipsec reload
sleep 3
echo ""

echo "=== Checking Configuration ==="
ipsec statusall
echo ""

echo "=== Testing Connection with Synology-Compatible Settings ==="
echo "Starting packet capture..."
timeout 30 tcpdump -i any -n host $SERVER_IP and port 500 -w /tmp/synology_debug.pcap 2>/dev/null &
TCPDUMP_PID=$!
sleep 2

echo "Attempting connection with Synology-compatible parameters..."
timeout 25 ipsec up synology 2>&1 | tee /tmp/synology_up_output.log

sleep 5

echo ""
echo "=== Connection Status ==="
ipsec statusall
echo ""

# Stop tcpdump
if [ ! -z "$TCPDUMP_PID" ]; then
    kill $TCPDUMP_PID 2>/dev/null || true
    wait $TCPDUMP_PID 2>/dev/null || true
fi

echo "=== Packet Analysis ==="
if [ -f /tmp/synology_debug.pcap ]; then
    PACKET_COUNT=$(tcpdump -r /tmp/synology_debug.pcap -n 2>/dev/null | wc -l)
    echo "Total packets: $PACKET_COUNT"
    
    if [ "$PACKET_COUNT" -gt 0 ]; then
        echo "Packet details:"
        tcpdump -r /tmp/synology_debug.pcap -n 2>/dev/null | head -10
        echo ""
        
        OUTGOING=$(tcpdump -r /tmp/synology_debug.pcap -n 2>/dev/null | grep ".*> $SERVER_IP" | wc -l)
        INCOMING=$(tcpdump -r /tmp/synology_debug.pcap -n 2>/dev/null | grep "$SERVER_IP.*>" | wc -l)
        
        echo "Outgoing packets: $OUTGOING"
        echo "Incoming packets: $INCOMING"
        
        if [ "$INCOMING" -gt 0 ]; then
            echo "✅ Server is responding! Showing responses:"
            tcpdump -r /tmp/synology_debug.pcap -n 2>/dev/null | grep "$SERVER_IP.*>" | head -3
        else
            echo "❌ Server not responding to IKE requests"
        fi
    fi
fi
echo ""

echo "=== Connection Attempt Analysis ==="
if [ -f /tmp/synology_up_output.log ]; then
    echo "Connection output:"
    cat /tmp/synology_up_output.log
    echo ""
    
    if grep -qi "ESTABLISHED" /tmp/synology_up_output.log; then
        echo "🎉 SUCCESS: IPSec tunnel established with Synology!"
    elif grep -qi "no proposal chosen" /tmp/synology_up_output.log; then
        echo "❌ Still getting 'no proposal chosen' - may need even weaker encryption"
        echo "   Try enabling 'SHA2-256 compatible mode' on Synology server"
    elif grep -qi "authentication failed" /tmp/synology_up_output.log; then
        echo "❌ Authentication failed - check shared key"
    elif grep -qi "timeout\|retransmit" /tmp/synology_up_output.log; then
        echo "❌ Server still not responding"
    else
        echo "⚠️ Unknown result"
    fi
fi
echo ""

echo "=== Testing Alternative Synology Configurations ==="
echo ""

echo "1. Testing with even weaker encryption (for older Synology):"
cat > /etc/ipsec.conf << EOF
config setup
    charondebug="ike 2, knl 1, cfg 1"
    strictcrlpolicy=no
    uniqueids=no

conn synology_weak
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
    ikelifetime=8h
    keylife=1h
    dpdaction=clear
    dpddelay=300s
    dpdtimeout=90s
    forceencaps=yes
EOF

ipsec reload
sleep 2
echo "Trying weakest encryption (3DES-MD5)..."
timeout 15 ipsec up synology_weak 2>&1 | head -10

echo ""
echo "2. Testing without aggressive mode:"
cat > /etc/ipsec.conf << EOF
config setup
    charondebug="ike 2, knl 1, cfg 1"
    strictcrlpolicy=no
    uniqueids=no

conn synology_main
    type=transport
    keyexchange=ikev1
    left=%defaultroute
    leftprotoport=17/1701
    right=$SERVER_IP
    rightprotoport=17/1701
    authby=psk
    auto=add
    ike=3des-sha1-modp1024,aes128-sha1-modp1024!
    esp=3des-sha1,aes128-sha1!
    rekey=no
    leftid=%any
    rightid=$SERVER_IP
    aggressive=no
    ikelifetime=8h
    keylife=1h
    dpdaction=clear
    dpddelay=300s
    dpdtimeout=90s
    forceencaps=yes
EOF

ipsec reload
sleep 2
echo "Trying main mode (non-aggressive)..."
timeout 15 ipsec up synology_main 2>&1 | head -10

echo ""
echo "=== Cleanup ==="
ipsec stop
echo ""

echo "=== Synology-Specific Recommendations ==="
echo ""
echo "Based on your Synology DSM7 configuration:"
echo ""
echo "CRITICAL SYNOLOGY SETTINGS TO CHECK:"
echo "1. ✅ L2TP/IPSec is enabled"
echo "2. ✅ Authentication is MS-CHAP v2"
echo "3. ❌ 'Enable SHA2-256 compatible mode (96 bit)' is DISABLED"
echo ""
echo "IMMEDIATE ACTIONS:"
echo "A. Enable SHA2-256 mode on Synology:"
echo "   - Go to VPN Server > L2TP/IPSec"
echo "   - Check 'Enable SHA2-256 compatible mode (96 bit)'"
echo "   - Click Apply"
echo ""
echo "B. Alternative: Use weaker encryption (less secure):"
echo "   - Keep SHA2-256 mode disabled"
echo "   - Client must use 3DES-SHA1 or 3DES-MD5"
echo ""
echo "C. Check Synology firewall:"
echo "   - Control Panel > Security > Firewall"
echo "   - Ensure UDP ports 500, 4500, 1701 are allowed"
echo ""
echo "D. Check Synology VPN logs:"
echo "   - Log Center > VPN Server"
echo "   - Look for connection attempts and errors"
echo ""
echo "MOST LIKELY SOLUTION:"
echo "Enable 'SHA2-256 compatible mode' on your Synology server!"
echo ""
echo "=== Synology Debug Script Completed at $(date) ==="