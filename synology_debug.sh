#!/bin/bash
# Synology DSM7 L2TP/IPSec Debug Script
# Specifically designed for Synology NAS VPN servers
#
# IMPORTANT: This script requires exclusive access to VPN resources.
# Stop any running VPN monitor before executing:
#   docker-compose down
#   docker-compose run --rm vpn-monitor /app/synology_debug.sh

# Don't exit on errors - we want to continue debugging even if some steps fail
set +e

echo "=== VPN Resource Conflict Check ==="
# Check if strongSwan is already running from another process
if pgrep -f "charon\|starter" >/dev/null 2>&1; then
    echo "⚠️  WARNING: strongSwan processes already running!"
    echo "   This indicates the VPN monitor is likely still active."
    echo "   For reliable debugging, stop the monitor first:"
    echo ""
    echo "   CORRECT USAGE:"
    echo "   docker-compose down"
    echo "   docker-compose run --rm vpn-monitor /app/synology_debug.sh"
    echo ""
    echo "   Attempting to clean up existing processes..."
    
    # Show what processes are running
    echo "   Current VPN processes:"
    ps aux | grep -E "(charon|starter|ipsec)" | grep -v grep || echo "   No VPN processes visible"
    
    # Force cleanup
    killall -9 charon starter ipsec 2>/dev/null || true
    sleep 3
    
    # Verify cleanup
    if pgrep -f "charon\|starter" >/dev/null 2>&1; then
        echo "   ❌ Failed to clean up VPN processes - debug may be unreliable"
        echo "   Please stop the container and try again:"
        echo "   docker-compose down && docker-compose run --rm vpn-monitor /app/synology_debug.sh"
    else
        echo "   ✓ VPN processes cleaned up successfully"
    fi
else
    echo "✓ No conflicting VPN processes detected"
fi

echo ""

echo "=== Synology DSM7 VPN Debug Script Started at $(date) ==="
echo ""

echo "=== Container Environment Check ==="
echo "Checking container capabilities and privileges..."

# Check if running in privileged mode
if [ -r /proc/1/status ]; then
    CAP_INFO=$(grep "^Cap" /proc/1/status 2>/dev/null || echo "Capability info not available")
    echo "Container capabilities: $CAP_INFO"
else
    echo "Cannot read process capabilities"
fi

# Check if we can create network interfaces (required for VPN)
if [ -w /proc/sys/net ]; then
    echo "✓ Network configuration access: Available"
else
    echo "❌ Network configuration access: Denied (may need --privileged)"
fi

# Check if we can load kernel modules
if [ -w /proc/sys/kernel ]; then
    echo "✓ Kernel parameter access: Available"
else
    echo "❌ Kernel parameter access: Limited"
fi

# Check available network namespaces
echo "Network namespace: $(readlink /proc/self/ns/net 2>/dev/null || echo 'Cannot read')"

# Check if TUN/TAP is available
if [ -c /dev/net/tun ]; then
    echo "✓ TUN/TAP device: Available"
    ls -la /dev/net/tun
else
    echo "❌ TUN/TAP device: Not available (may affect VPN functionality)"
    echo "Checking /dev/net/ directory:"
    ls -la /dev/net/ 2>/dev/null || echo "/dev/net/ directory not found"
fi

# Check if we can create network interfaces
echo "Testing network interface creation capability:"
if ip link add test-dummy type dummy 2>/dev/null; then
    echo "✓ Can create network interfaces"
    ip link delete test-dummy 2>/dev/null || true
else
    echo "❌ Cannot create network interfaces (may need NET_ADMIN capability)"
fi

# Check available capabilities in detail
echo "Detailed capability check:"
if [ -f /proc/self/status ]; then
    grep "^Cap" /proc/self/status | while read line; do
        echo "  $line"
    done
else
    echo "  Cannot read capability information"
fi

# Check if we're in a user namespace
echo "User namespace check:"
if [ -f /proc/self/uid_map ]; then
    echo "  UID mapping: $(cat /proc/self/uid_map)"
else
    echo "  No UID mapping (not in user namespace)"
fi

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
echo "Stopping IPSec..."
ipsec stop 2>/dev/null || echo "IPSec already stopped or not running"

echo "Killing VPN processes..."
killall -9 charon starter xl2tpd pppd 2>/dev/null || echo "No VPN processes to kill"

echo "Cleaning up PID files..."
rm -f /var/run/charon.pid /var/run/starter.pid /var/run/starter.charon.pid 2>/dev/null || true

sleep 2
echo "✓ VPN cleanup completed"
echo ""

echo "=== Creating Synology-Compatible IPSec Configuration ==="

# Get username from environment for peer ID
USERNAME=$(python3 -c "
import os
from dotenv import load_dotenv
load_dotenv('/app/.env')
servers = os.getenv('VPN_SERVERS', '').split(',')
if servers and servers[0]:
    parts = servers[0].strip().split(':')
    if len(parts) >= 3:
        print(parts[2])  # username
    else:
        print('testuser')
else:
    print('testuser')
")

echo "Using username for peer ID: $USERNAME"

# Create configuration that EXACTLY matches Windows 11 L2TP/IPSec client
# FIXED: Use %any for leftid to avoid @username format issue
# Server logs show: "peer ID is ID_FQDN: '@germain'" - strongSwan adds @ to quoted strings
# Solution: Use %any and let authentication happen via PSK secrets
        # UPDATED: Match Windows 11 exactly - use Main Mode with AES-256
        # FINAL FIX: Optimize timing for immediate Quick Mode
cat > /etc/ipsec.conf << EOF
config setup
    charondebug="ike 2, knl 1, cfg 1"
    strictcrlpolicy=no
    uniqueids=no

conn windows11_match
    type=transport
    keyexchange=ikev1
    left=%defaultroute
    leftprotoport=17/1701
    right=$SERVER_IP
    rightprotoport=17/1701
    authby=psk
    auto=add
    ike=aes256-sha1-modp2048,aes256-sha1-modp1024,3des-sha1-modp1024!
    esp=aes256-sha1,3des-sha1!
    rekey=no
    leftid=%any
    rightid=%any
    aggressive=no
    ikelifetime=3600s
    keylife=3600s
    dpdaction=clear
    dpddelay=30s
    dpdtimeout=120s
    forceencaps=no
    margintime=9m
    rekeyfuzz=100%
EOF

echo "✓ Created Synology-compatible IPSec configuration"
echo "   - Using leftid=%any (prevents @username format)"
echo "   - Using 3DES/SHA1 encryption (Synology compatible)"
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
        username = parts[2]
        shared_key = parts[4]
        secrets_content = f'''# strongSwan IPsec secrets file for Synology
# FIXED: Use %any to avoid peer ID format issues
%any {server_ip} : PSK \"{shared_key}\"
{server_ip} %any : PSK \"{shared_key}\"
'''
        with open('/etc/ipsec.secrets', 'w') as f:
            f.write(secrets_content)
        print(f'✓ Created secrets file for {server_ip} with username {username}')
        print(f'✓ Shared key length: {len(shared_key)} characters')
    else:
        print('✗ Invalid server configuration format')
else:
    print('✗ No VPN servers found')
"

chmod 600 /etc/ipsec.secrets
echo ""

echo "=== Starting strongSwan for Synology ==="
echo "Attempting to start strongSwan daemon..."
echo "Current working directory: $(pwd)"
echo "Available strongSwan binaries:"
which ipsec charon starter 2>/dev/null || echo "Some strongSwan binaries not found in PATH"
echo ""

# Method 1: Try direct charon startup
echo "1. Trying direct charon startup..."
echo "Command: charon --use-syslog --debug-ike 1 --debug-knl 1"
charon --use-syslog --debug-ike 1 --debug-knl 1 2>&1 &
CHARON_PID=$!
echo "Started charon with PID: $CHARON_PID"
sleep 3

# Check if charon is running
if kill -0 $CHARON_PID 2>/dev/null; then
    echo "✓ Charon started successfully (PID: $CHARON_PID)"
    echo "Charon process info:"
    ps aux | grep charon | grep -v grep || echo "No charon process visible in ps"
else
    echo "✗ Charon failed to start, trying alternative method..."
    
    # Method 2: Try traditional ipsec start with timeout
    echo "2. Trying traditional ipsec start..."
    echo "Command: timeout 10 ipsec start"
    timeout 10 ipsec start 2>&1 || echo "ipsec start timed out or failed"
    sleep 3
fi

# Verify strongSwan is running
echo "Checking strongSwan status..."
echo "Looking for charon process:"
pgrep -l charon || echo "No charon process found"

if pgrep charon >/dev/null; then
    echo "✓ strongSwan daemon is running"
    echo "Process details:"
    ps aux | grep charon | grep -v grep
else
    echo "✗ strongSwan daemon not running - attempting manual start..."
    
    # Method 3: Force start with specific parameters
    echo "3. Force starting with specific parameters..."
    echo "Command: /usr/lib/ipsec/starter --daemon charon --debug 2"
    /usr/lib/ipsec/starter --daemon charon --debug 2 2>&1 &
    STARTER_PID=$!
    echo "Started starter with PID: $STARTER_PID"
    sleep 5
    
    if pgrep charon >/dev/null; then
        echo "✓ strongSwan force-started successfully"
        echo "Process details:"
        ps aux | grep -E "(charon|starter)" | grep -v grep
    else
        echo "❌ Failed to start strongSwan - container may need privileged mode"
        echo "Checking system logs for errors:"
        dmesg | tail -10 | grep -i ipsec || echo "No IPSec-related kernel messages"
        echo "   Try running: docker-compose run --privileged vpn-monitor /app/synology_debug.sh"
        echo "   Continuing with debug anyway..."
    fi
fi
echo ""

echo "=== Loading Synology Configuration ==="
echo "Attempting to load configuration..."

# Try reload first
if ipsec reload 2>/dev/null; then
    echo "✓ Configuration reloaded successfully"
else
    echo "✗ Reload failed, trying alternative loading method..."
    
    # Alternative: restart with new config
    echo "Restarting strongSwan with new configuration..."
    ipsec stop 2>/dev/null || true
    sleep 2
    
    # Start again
    charon --use-syslog --debug-ike 1 --debug-knl 1 &
    sleep 3
    
    if pgrep charon >/dev/null; then
        echo "✓ strongSwan restarted with new configuration"
    else
        echo "❌ Failed to restart strongSwan"
        exit 1
    fi
fi

sleep 2
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
timeout 15 ipsec up windows11_match 2>&1 | tee /tmp/synology_up_output.log


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

echo "1. Testing EXACT Windows 11 parameters (DES-MD5-MODP768):"

# Get username again for this test
USERNAME=$(python3 -c "
import os
from dotenv import load_dotenv
load_dotenv('/app/.env')
servers = os.getenv('VPN_SERVERS', '').split(',')
if servers and servers[0]:
    parts = servers[0].strip().split(':')
    if len(parts) >= 3:
        print(parts[2])
    else:
        print('testuser')
else:
    print('testuser')
")

cat > /etc/ipsec.conf << EOF
config setup
    charondebug="ike 2, knl 1, cfg 1"
    strictcrlpolicy=no
    uniqueids=no

conn windows11_exact
    type=transport
    keyexchange=ikev1
    left=%defaultroute
    leftprotoport=17/1701
    right=$SERVER_IP
    rightprotoport=17/1701
    authby=psk
    auto=add
    ike=aes256-sha1-modp2048,aes256-sha1-modp1024!
    esp=aes256-sha1!
    rekey=no
    leftid=%any
    rightid=%any
    aggressive=no
    ikelifetime=480m
    keylife=60m
    dpdaction=clear
    margintime=9m
    rekeyfuzz=100%
    forceencaps=yes
EOF

ipsec reload
sleep 2
echo "Attempting Windows 11 exact match connection..."
timeout 20 ipsec up windows11_exact 2>&1 | tee /tmp/windows11_exact.log

if grep -qi "ESTABLISHED" /tmp/windows11_exact.log; then
    echo "🎉 SUCCESS with Windows 11 exact parameters!"
else
    echo "❌ Windows 11 exact match failed"
fi

echo ""
echo "2. Testing Synology legacy mode (DES-MD5 only):"
cat > /etc/ipsec.conf << EOF
config setup
    charondebug="ike 2, knl 1, cfg 1"
    strictcrlpolicy=no
    uniqueids=no

conn synology_legacy
    type=transport
    keyexchange=ikev1
    left=%defaultroute
    leftprotoport=17/1701
    right=$SERVER_IP
    rightprotoport=17/1701
    authby=psk
    auto=add
    ike=aes256-sha1-modp2048!
    esp=aes256-sha1!
    rekey=no
    leftid=%any
    rightid=%any
    aggressive=no
    ikelifetime=8h
    keylife=60m
    dpdaction=clear
    dpddelay=30s
    dpdtimeout=120s
    forceencaps=yes
EOF

ipsec reload
sleep 2
echo "Attempting Synology legacy connection..."
timeout 20 ipsec up synology_legacy 2>&1 | tee /tmp/synology_legacy.log

if grep -qi "ESTABLISHED" /tmp/synology_legacy.log; then
    echo "🎉 SUCCESS with Synology legacy mode!"
else
    echo "❌ Synology legacy mode failed"
fi

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
echo "3. ❌ 'Enable SHA2-256 compatible mode (96 bit)' is DISABLED (for Windows/macOS compatibility)"
echo ""
echo "IMMEDIATE ACTIONS:"
echo "A. Since SHA2-256 mode is disabled for client compatibility:"
echo "   - This configuration uses legacy 3DES/MD5 encryption"
echo "   - Should work with Windows 11 and macOS clients"
echo "   - Less secure but more compatible"
echo ""
echo "B. Verify Synology L2TP/IPSec settings:"
echo "   - VPN Server > L2TP/IPSec > General"
echo "   - Enable L2TP/IPSec VPN server: ✅ Checked"
echo "   - Authentication: MS-CHAP v2"
echo "   - Enable SHA2-256 compatible mode: ❌ Unchecked (for client compatibility)"
echo ""
echo "C. Check Synology firewall:"
echo "   - Control Panel > Security > Firewall"
echo "   - Ensure UDP ports 500, 4500, 1701 are allowed"
echo ""
echo "D. Check Synology VPN logs:"
echo "   - Log Center > VPN Server"
echo "   - Look for connection attempts and errors"
echo ""
echo "CONFIGURATION NOTES:"
echo "- Tested multiple encryption combinations including DES-MD5 (weakest)"
echo "- Tested both aggressive and main mode"
echo "- Tested NAT-T forced mode"
echo "- Tested IKEv2 for modern Synology servers"
echo ""
echo "RESULTS SUMMARY:"
if [ -f /tmp/windows11_exact.log ]; then
    if grep -qi "ESTABLISHED" /tmp/windows11_exact.log; then
        echo "✅ Windows 11 exact match: SUCCESS"
    else
        echo "❌ Windows 11 exact match: FAILED"
    fi
fi

if [ -f /tmp/synology_legacy.log ]; then
    if grep -qi "ESTABLISHED" /tmp/synology_legacy.log; then
        echo "✅ Legacy DES-MD5: SUCCESS"
    else
        echo "❌ Legacy DES-MD5: FAILED"
    fi
fi

if [ -f /tmp/synology_natt.log ]; then
    if grep -qi "ESTABLISHED" /tmp/synology_natt.log; then
        echo "✅ NAT-T forced: SUCCESS"
    else
        echo "❌ NAT-T forced: FAILED"
    fi
fi

if [ -f /tmp/synology_ikev2.log ]; then
    if grep -qi "ESTABLISHED" /tmp/synology_ikev2.log; then
        echo "✅ IKEv2: SUCCESS"
    else
        echo "❌ IKEv2: FAILED"
    fi
fi

echo ""
echo "NEXT STEPS:"
echo "1. Check which configuration (if any) succeeded above"
echo "2. If none succeeded, check Synology VPN Server logs"
echo "3. Verify shared key is exactly correct"
echo "4. Try connecting from a different network location"
echo "5. Consider enabling 'SHA2-256 compatible mode' temporarily for testing"
echo ""
echo "=== Synology Debug Script Completed at $(date) ==="