#!/bin/bash
# Synology Exact Match Configuration Test
# This script tries to match EXACTLY what Synology expects from Windows clients

set -e

echo "=== Synology Exact Match Configuration Test ==="
echo "Started at: $(date)"
echo ""

# Get server info from environment
SERVER_INFO=$(python3 -c "
import os
from dotenv import load_dotenv
load_dotenv()
servers = os.getenv('VPN_SERVERS', '').split(',')
if servers and servers[0]:
    parts = servers[0].strip().split(':')
    if len(parts) >= 5:
        print(f'{parts[0]} {parts[1]} {parts[2]} {parts[4]}')
    else:
        print('server1 example.com user key')
else:
    print('server1 example.com user key')
")

SERVER_NAME=$(echo $SERVER_INFO | cut -d' ' -f1)
SERVER_IP=$(echo $SERVER_INFO | cut -d' ' -f2)
USERNAME=$(echo $SERVER_INFO | cut -d' ' -f3)
SHARED_KEY=$(echo $SERVER_INFO | cut -d' ' -f4)

echo "Testing server: $SERVER_NAME ($SERVER_IP)"
echo "Username: $USERNAME"
echo "Shared key length: ${#SHARED_KEY} characters"
echo ""

# Stop any existing VPN services
echo "=== Cleanup ==="
ipsec stop 2>/dev/null || true
killall -9 charon starter xl2tpd pppd 2>/dev/null || true
sleep 2

# Test 1: Windows 11 exact configuration
echo "=== Test 1: Windows 11 Exact Match ==="
cat > /etc/ipsec.conf << EOF
config setup
    charondebug="ike 1, knl 1, cfg 0"
    strictcrlpolicy=no
    uniqueids=no

conn L2TP-PSK
    type=transport
    keyexchange=ikev1
    left=%defaultroute
    leftprotoport=17/1701
    right=$SERVER_IP
    rightprotoport=17/1701
    authby=psk
    auto=add
    ike=3des-sha1-modp1024!
    esp=3des-sha1!
    rekey=no
    leftid=
    rightid=$SERVER_IP
    aggressive=yes
    ikelifetime=480m
    keylife=60m
    dpdaction=none
    margintime=9m
    rekeyfuzz=100%
EOF

# Create secrets with exact Windows format
cat > /etc/ipsec.secrets << EOF
# Windows 11 L2TP/IPSec format
: PSK "$SHARED_KEY"
$SERVER_IP %any : PSK "$SHARED_KEY"
%any $SERVER_IP : PSK "$SHARED_KEY"
EOF

chmod 600 /etc/ipsec.secrets

echo "Starting strongSwan..."
ipsec start
sleep 3

echo "Attempting Windows 11 exact connection..."
timeout 20 ipsec up L2TP-PSK 2>&1 | tee /tmp/windows11_test.log

if grep -qi "ESTABLISHED" /tmp/windows11_test.log; then
    echo "🎉 SUCCESS: Windows 11 exact match worked!"
    ipsec statusall
else
    echo "❌ Windows 11 exact match failed"
fi

ipsec stop
sleep 2

# Test 2: Empty leftid (let strongSwan decide)
echo ""
echo "=== Test 2: Empty Left ID ==="
cat > /etc/ipsec.conf << EOF
config setup
    charondebug="ike 1, knl 1, cfg 0"
    strictcrlpolicy=no
    uniqueids=no

conn L2TP-PSK-EMPTY
    type=transport
    keyexchange=ikev1
    left=%defaultroute
    leftprotoport=17/1701
    right=$SERVER_IP
    rightprotoport=17/1701
    authby=psk
    auto=add
    ike=3des-sha1-modp1024!
    esp=3des-sha1!
    rekey=no
    rightid=$SERVER_IP
    aggressive=yes
    ikelifetime=480m
    keylife=60m
    dpdaction=none
EOF

echo "Starting strongSwan..."
ipsec start
sleep 3

echo "Attempting empty leftid connection..."
timeout 20 ipsec up L2TP-PSK-EMPTY 2>&1 | tee /tmp/empty_leftid_test.log

if grep -qi "ESTABLISHED" /tmp/empty_leftid_test.log; then
    echo "🎉 SUCCESS: Empty leftid worked!"
    ipsec statusall
else
    echo "❌ Empty leftid failed"
fi

ipsec stop
sleep 2

# Test 3: Use username as leftid (without @)
echo ""
echo "=== Test 3: Username as Left ID ==="
cat > /etc/ipsec.conf << EOF
config setup
    charondebug="ike 1, knl 1, cfg 0"
    strictcrlpolicy=no
    uniqueids=no

conn L2TP-PSK-USER
    type=transport
    keyexchange=ikev1
    left=%defaultroute
    leftprotoport=17/1701
    right=$SERVER_IP
    rightprotoport=17/1701
    authby=psk
    auto=add
    ike=3des-sha1-modp1024!
    esp=3des-sha1!
    rekey=no
    leftid=$USERNAME
    rightid=$SERVER_IP
    aggressive=yes
    ikelifetime=480m
    keylife=60m
    dpdaction=none
EOF

echo "Starting strongSwan..."
ipsec start
sleep 3

echo "Attempting username leftid connection..."
timeout 20 ipsec up L2TP-PSK-USER 2>&1 | tee /tmp/username_leftid_test.log

if grep -qi "ESTABLISHED" /tmp/username_leftid_test.log; then
    echo "🎉 SUCCESS: Username leftid worked!"
    ipsec statusall
else
    echo "❌ Username leftid failed"
fi

ipsec stop

echo ""
echo "=== Test Results Summary ==="
echo "Windows 11 exact: $(grep -qi "ESTABLISHED" /tmp/windows11_test.log 2>/dev/null && echo "✅ SUCCESS" || echo "❌ FAILED")"
echo "Empty leftid: $(grep -qi "ESTABLISHED" /tmp/empty_leftid_test.log 2>/dev/null && echo "✅ SUCCESS" || echo "❌ FAILED")"
echo "Username leftid: $(grep -qi "ESTABLISHED" /tmp/username_leftid_test.log 2>/dev/null && echo "✅ SUCCESS" || echo "❌ FAILED")"
echo ""
echo "=== Next Steps ==="
echo "If all tests failed, the issue is likely on the Synology server side:"
echo "1. Check Synology VPN Server logs for the exact error"
echo "2. Verify the shared key is exactly correct"
echo "3. Check if Synology is configured to accept connections from any client"
echo "4. Try enabling 'SHA2-256 compatible mode' on Synology temporarily"
echo ""
echo "Completed at: $(date)"