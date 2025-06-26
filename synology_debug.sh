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

# Create Synology-optimized configuration for servers WITHOUT SHA2-256 mode
cat > /etc/ipsec.conf << EOF
config setup
    charondebug="ike 2, knl 1, cfg 1"
    strictcrlpolicy=no
    uniqueids=no
    cachecrls=no

conn synology
    type=transport
    keyexchange=ikev1
    left=%defaultroute
    leftprotoport=17/1701
    right=$SERVER_IP
    rightprotoport=17/1701
    authby=psk
    auto=add
    ike=3des-sha1-modp1024,3des-md5-modp1024,aes128-sha1-modp1024,aes128-md5-modp1024!
    esp=3des-sha1,3des-md5,aes128-sha1,aes128-md5!
    rekey=no
    leftid=%any
    rightid=$SERVER_IP
    aggressive=yes
    ikelifetime=24h
    keylife=8h
    dpdaction=clear
    dpddelay=30s
    dpdtimeout=120s
    forceencaps=yes
    margintime=9m
    rekeyfuzz=100%
    keyingtries=3
    replay_window=32
EOF

echo "✓ Created Synology-compatible IPSec configuration (legacy encryption)"
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
echo "- Using legacy encryption (3DES/MD5) for maximum compatibility"
echo "- This should work with Windows 11 and macOS built-in VPN clients"
echo "- If connection still fails, check Synology logs for specific errors"
echo "- Consider testing from different network locations"
echo ""
echo "=== Synology Debug Script Completed at $(date) ==="