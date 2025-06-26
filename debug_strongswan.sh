#!/bin/bash
# Debug script for strongSwan issues

echo "=== strongSwan Debug Information ==="
echo "Date: $(date)"
echo ""

echo "=== System Information ==="
echo "Kernel: $(uname -r)"
echo "OS: $(cat /etc/os-release | grep PRETTY_NAME)"
echo ""

echo "=== strongSwan Version ==="
ipsec --version
echo ""

echo "=== Process Information ==="
echo "strongSwan processes:"
ps aux | grep -E "(ipsec|charon|starter)" | grep -v grep
echo ""

echo "=== PID Files ==="
echo "Checking PID files:"
ls -la /var/run/ | grep -E "(ipsec|charon|starter)" || echo "No strongSwan PID files found"
echo ""

echo "=== Configuration Files ==="
echo "IPSec config exists: $(test -f /etc/ipsec.conf && echo 'YES' || echo 'NO')"
echo "IPSec secrets exists: $(test -f /etc/ipsec.secrets && echo 'YES' || echo 'NO')"
echo ""

if [ -f /etc/ipsec.conf ]; then
    echo "=== IPSec Configuration ==="
    cat /etc/ipsec.conf
    echo ""
fi

if [ -f /etc/ipsec.secrets ]; then
    echo "=== IPSec Secrets (first line only) ==="
    head -1 /etc/ipsec.secrets
    echo ""
fi

echo "=== strongSwan Status ==="
ipsec status 2>&1
echo ""

echo "=== strongSwan Detailed Status ==="
ipsec statusall 2>&1
echo ""

echo "=== Network Interfaces ==="
ip addr show
echo ""

echo "=== Routing Table ==="
ip route
echo ""

echo "=== Kernel Modules ==="
echo "IPSec related modules:"
lsmod | grep -E "(esp|ah|xfrm|ipsec)" || echo "No IPSec modules loaded"
echo ""

echo "=== Log Files ==="
echo "Recent strongSwan logs:"
if [ -f /var/log/syslog ]; then
    tail -20 /var/log/syslog | grep -E "(ipsec|charon|strongswan)" || echo "No recent strongSwan logs in syslog"
elif [ -f /var/log/messages ]; then
    tail -20 /var/log/messages | grep -E "(ipsec|charon|strongswan)" || echo "No recent strongSwan logs in messages"
else
    echo "No system log files found"
fi
echo ""

echo "=== Manual Start Test ==="
echo "Attempting to start strongSwan manually..."
ipsec stop >/dev/null 2>&1
sleep 2
echo "Starting with debug output:"
timeout 10s ipsec start --nofork --debug-more 2>&1 | head -50
echo ""

echo "=== End Debug Information ==="