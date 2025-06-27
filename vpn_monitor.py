#!/usr/bin/env python3
"""
Docker-based VPN Monitor
Monitors L2TP/IPSec VPN connections using native Linux VPN clients and logs results to MySQL database.
Performs actual VPN tunnel establishment and testing.
"""

import os
import sys
import time
import socket
import platform
import subprocess
import getpass
import tempfile
import shutil
import signal
from datetime import datetime
from typing import List, Dict, Tuple, Optional
import logging

# Third-party imports
try:
    import pymysql
    import requests
    from dotenv import load_dotenv
except ImportError as e:
    print(f"Missing required package: {e}")
    print("Please install requirements: pip install -r requirements.txt")
    sys.exit(1)

# Version
VERSION = "2.0.0"

# Configure logging
log_dir = "/var/log/vpn-monitor"
if not os.path.exists(log_dir):
    os.makedirs(log_dir, exist_ok=True)

logging.basicConfig(
    level=logging.DEBUG,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler(f'{log_dir}/vpn_monitor.log'),
        logging.StreamHandler(sys.stdout)
    ]
)
logger = logging.getLogger(__name__)


class VPNMonitor:
    def __init__(self):
        """Initialize the VPN Monitor."""
        load_dotenv()
        self.db_config = {
            'host': os.getenv('DB_HOST'),
            'port': int(os.getenv('DB_PORT', 3306)),
            'user': os.getenv('DB_USER'),
            'password': os.getenv('DB_PASSWORD'),
            'database': os.getenv('DB_NAME'),
            'charset': 'utf8mb4'
        }
        
        self.vpn_timeout = int(os.getenv('VPN_TIMEOUT', 30))
        self.monitor_id = os.getenv('MONITOR_ID', '')
        self.poll_interval = int(os.getenv('POLL_INTERVAL_MINUTES', 5))
        
        # WSL2 VPN bypass configuration
        self.wsl2_bypass = os.getenv('WSL2_BYPASS_VPN', 'false').lower() == 'true'
        self.physical_gateway = os.getenv('PHYSICAL_GATEWAY', '192.168.100.1')
        self.physical_interface = os.getenv('PHYSICAL_INTERFACE', 'eth0')
        
        # Parse VPN servers
        self.vpn_servers = self._parse_vpn_servers()
        
        # System information
        self.system_info = self._get_system_info()
        
        # Validate configuration
        self._validate_config()
        
        # Setup WSL2 VPN bypass if enabled
        if self.wsl2_bypass:
            self._setup_wsl2_bypass()
        
        # VPN configuration directories
        self.temp_dir = tempfile.mkdtemp(prefix="vpn_test_")

    def _setup_wsl2_bypass(self):
        """Setup routing to bypass Windows VPN for specific destinations."""
        try:
            logger.info("🔄 Setting up WSL2 VPN bypass routing...")
            
            # Check if we're in WSL2
            if not self._is_wsl2():
                logger.info("Not running in WSL2, skipping VPN bypass setup")
                return
            
            # Add routes for VPN servers through physical gateway
            for server in self.vpn_servers:
                self._add_direct_route(server['ip'])
            
            # Add routes for public IP services through physical gateway
            ip_services = ['8.8.8.8', '1.1.1.1', 'api.ipify.org', 'icanhazip.com', 'ipecho.net']
            for service in ip_services:
                if not service.replace('.', '').isdigit():
                    # Resolve hostname first
                    try:
                        import socket
                        ip = socket.gethostbyname(service)
                        self._add_direct_route(ip)
                        logger.debug(f"Added route for {service} -> {ip}")
                    except:
                        logger.debug(f"Could not resolve {service}")
                else:
                    self._add_direct_route(service)
            
            logger.info("✅ WSL2 VPN bypass routes configured")
            
        except Exception as e:
            logger.warning(f"WSL2 VPN bypass setup failed: {e}")
    
    def _is_wsl2(self) -> bool:
        """Check if running in WSL2."""
        try:
            with open('/proc/version', 'r') as f:
                version = f.read()
                return 'microsoft' in version.lower() and 'wsl2' in version.lower()
        except:
            return False
    
    def _add_direct_route(self, destination: str):
        """Add a direct route through physical gateway."""
        try:
            # Add route through physical gateway, bypassing VPN
            route_cmd = [
                'ip', 'route', 'add', destination,
                'via', self.physical_gateway,
                'dev', self.physical_interface,
                'metric', '1'
            ]
            
            # Check if route already exists
            check_cmd = ['ip', 'route', 'show', destination]
            check_result = subprocess.run(check_cmd, capture_output=True, timeout=5)
            
            if check_result.returncode == 0 and self.physical_gateway in check_result.stdout.decode():
                logger.debug(f"Route for {destination} already exists")
                return
            
            # Add the route
            route_result = subprocess.run(route_cmd, capture_output=True, timeout=5)
            if route_result.returncode == 0:
                logger.debug(f"Added direct route: {destination} via {self.physical_gateway}")
            else:
                logger.debug(f"Failed to add route for {destination}: {route_result.stderr.decode()}")
                
        except Exception as e:
            logger.debug(f"Route add error for {destination}: {e}")

    def __del__(self):
        """Cleanup temporary files."""
        self._cleanup()

    def _cleanup(self):
        """Clean up temporary files and VPN connections."""
        try:
            # Stop any running VPN connections
            self._stop_all_vpn_connections()
            
            # Remove temporary directory
            if hasattr(self, 'temp_dir') and os.path.exists(self.temp_dir):
                shutil.rmtree(self.temp_dir, ignore_errors=True)
                
        except Exception as e:
            logger.warning(f"Cleanup warning: {e}")

    def _parse_vpn_servers(self) -> List[Dict[str, str]]:
        """Parse VPN servers from environment variable."""
        servers_str = os.getenv('VPN_SERVERS', '')
        if not servers_str:
            raise ValueError("VPN_SERVERS environment variable is required")
        
        servers = []
        for server_config in servers_str.split(','):
            parts = server_config.strip().split(':')
            if len(parts) != 5:
                logger.error(f"Invalid server config format: {server_config}")
                logger.error("Required format: server_name:server_ip:username:password:shared_key")
                continue
            
            server = {
                'name': parts[0],
                'ip': parts[1],
                'username': parts[2],
                'password': parts[3],
                'shared_key': parts[4]
            }
            
            servers.append(server)
        
        return servers

    def _get_system_info(self) -> Dict[str, str]:
        """Get system information."""
        info = {
            'hostname': socket.gethostname(),
            'username': getpass.getuser(),
            'os': platform.system(),
            'os_version': platform.release(),
            'platform': platform.platform(),
            'public_ip': self._get_public_ip()
        }
        
        # Use custom monitor ID if provided
        if self.monitor_id:
            info['hostname'] = self.monitor_id
            
        return info

    def _get_public_ip(self) -> Optional[str]:
        """Get the current public IP address."""
        try:
            # Try multiple services for reliability
            services = [
                'https://api.ipify.org',
                'https://icanhazip.com',
                'https://ipecho.net/plain'
            ]
            
            for service in services:
                try:
                    response = requests.get(service, timeout=10)
                    if response.status_code == 200:
                        return response.text.strip()
                except:
                    continue
                    
        except Exception as e:
            logger.warning(f"Could not determine public IP: {e}")
            
        return None

    def _validate_config(self):
        """Validate configuration."""
        required_db_fields = ['host', 'user', 'password', 'database']
        missing_fields = [field for field in required_db_fields if not self.db_config.get(field)]
        
        if missing_fields:
            raise ValueError(f"Missing required database configuration: {', '.join(missing_fields)}")
        
        if not self.vpn_servers:
            raise ValueError("No VPN servers configured")

    def _get_db_connection(self):
        """Get database connection."""
        try:
            return pymysql.connect(**self.db_config)
        except Exception as e:
            logger.error(f"Database connection failed: {e}")
            raise

    def _stop_all_vpn_connections(self):
        """Stop all VPN connections."""
        try:
            logger.debug("Stopping all VPN connections and services")
            
            # Stop strongSwan connections first (ignore errors)
            down_result = subprocess.run(['ipsec', 'down', 'vpntest'], capture_output=True, timeout=5)
            logger.debug(f"ipsec down result: {down_result.returncode}, stdout: {down_result.stdout.decode()}, stderr: {down_result.stderr.decode()}")
            
            stop_result = subprocess.run(['ipsec', 'stop'], capture_output=True, timeout=10)
            logger.debug(f"ipsec stop result: {stop_result.returncode}, stdout: {stop_result.stdout.decode()}, stderr: {stop_result.stderr.decode()}")
            
            # Kill all VPN-related processes forcefully
            processes_to_kill = ['xl2tpd', 'pppd', 'charon', 'starter']
            for process in processes_to_kill:
                kill_result = subprocess.run(['killall', '-9', process], capture_output=True, timeout=3)
                logger.debug(f"killall {process} result: {kill_result.returncode}")
            
            # Clean up all control and PID files
            files_to_remove = [
                '/var/run/xl2tpd/l2tp-control',
                '/var/run/charon.pid',
                '/var/run/starter.charon.pid',
                '/var/run/starter.pid',
                '/var/run/charon.ctl',
                '/var/run/charon.vici',
                '/var/run/starter.charon.pid'
            ]
            
            for file_path in files_to_remove:
                if os.path.exists(file_path):
                    os.remove(file_path)
                    logger.debug(f"Removed {file_path}")
            
            # Wait for complete cleanup
            time.sleep(2)
            
        except Exception as e:
            logger.debug(f"VPN cleanup: {e}")

    def _create_ipsec_config(self, server: Dict[str, str], config_dir: str) -> str:
        """Create IPSec configuration for strongSwan."""
        logger.debug(f"Creating IPSec config for {server['name']} ({server['ip']})")
        
        config_file = '/etc/ipsec.conf'
        secrets_file = '/etc/ipsec.secrets'
        
        # EXACT configuration from working synology_debug.sh - use auto=start for immediate connection
        config_content = f"""
config setup
    charondebug="ike 2, knl 1, cfg 1"
    strictcrlpolicy=no
    uniqueids=no

conn vpntest
    type=transport
    keyexchange=ikev1
    left=%defaultroute
    leftprotoport=17/1701
    right={server['ip']}
    rightprotoport=17/1701
    authby=psk
    auto=start
    ike=aes256-sha1-modp2048,aes256-sha1-modp1024,3des-sha1-modp1024!
    esp=aes256-sha1,3des-sha1!
    rekey=no
    leftid=%any
    rightid=%any
    aggressive=no
    ikelifetime=86400s
    keylife=3600s
    dpdaction=none
    forceencaps=yes
    margintime=9m
    rekeyfuzz=100%
    closeaction=none
"""
        
        with open(config_file, 'w') as f:
            f.write(config_content)
        # Create secrets file - EXACT format from working debug script
        secrets_content = f"""# strongSwan IPsec secrets file for Synology
# FIXED: Use %any to avoid peer ID format issues
%any {server['ip']} : PSK "{server['shared_key']}"
{server['ip']} %any : PSK "{server['shared_key']}"
"""
        
        with open(secrets_file, 'w') as f:
            f.write(secrets_content)
        os.chmod(secrets_file, 0o600)
        
        logger.debug(f"Created IPSec config for {server['ip']}")
        
        return config_file

    def _create_xl2tpd_config(self, server: Dict[str, str], config_dir: str) -> str:
        """Create xl2tpd configuration."""
        config_file = '/etc/xl2tpd/xl2tpd.conf'
        
        # Ensure directory exists
        os.makedirs('/etc/xl2tpd', exist_ok=True)
        os.makedirs('/var/run/xl2tpd', exist_ok=True)
        
        config_content = f"""
[global]
port = 1701
access control = no
auth file = /etc/ppp/chap-secrets
debug avp = yes
debug network = yes
debug packet = yes
debug state = yes
debug tunnel = yes

[lac vpntest]
lns = {server['ip']}
ppp debug = yes
pppoptfile = /etc/ppp/options.l2tpd
length bit = yes
require chap = no
refuse pap = no
require authentication = no
name = {server['username']}
autodial = yes
redial = yes
redial timeout = 5
"""
        
        with open(config_file, 'w') as f:
            f.write(config_content)
        
        # Create PPP options file
        options_file = '/etc/ppp/options.l2tpd'
        
        # Ensure directory exists
        os.makedirs('/etc/ppp', exist_ok=True)
        
        options_content = f"""
ipcp-accept-local
ipcp-accept-remote
refuse-eap
require-mschap-v2
noccp
noauth
idle 1800
mtu 1410
mru 1410
nodefaultroute
usepeerdns
debug
connect-delay 5000
lock
lcp-echo-interval 30
lcp-echo-failure 4
name {server['username']}
user {server['username']}
password {server['password']}
"""
        
        with open(options_file, 'w') as f:
            f.write(options_content)
        
        # Create chap-secrets file for authentication
        chap_secrets_file = '/etc/ppp/chap-secrets'
        chap_content = f'"{server["username"]}" * "{server["password"]}" *\n'
        
        with open(chap_secrets_file, 'w') as f:
            f.write(chap_content)
        os.chmod(chap_secrets_file, 0o600)
        
        return config_file

    def _start_strongswan_daemon(self) -> bool:
        """Start strongSwan service properly."""
        try:
            logger.debug("Starting strongSwan daemon")
            
            # Clean state first
            self._ensure_clean_strongswan_state()
            
            # Use traditional ipsec start (most reliable)
            logger.debug("Starting strongSwan using ipsec start")
            start_cmd = ['ipsec', 'start']
            start_result = subprocess.run(start_cmd, capture_output=True, timeout=10)
            logger.debug(f"ipsec start result: {start_result.returncode}, stdout: {start_result.stdout.decode()}, stderr: {start_result.stderr.decode()}")
            
            if start_result.returncode == 0:
                # Wait for startup
                time.sleep(5)
                
                # Verify it's running
                if self._verify_charon_running():
                    logger.debug("strongSwan started successfully")
                    return True
                else:
                    logger.debug("strongSwan start failed verification")
                    return False
            else:
                logger.error(f"strongSwan start failed: {start_result.stderr.decode()}")
                return False
                
        except Exception as e:
            logger.error(f"Failed to start strongSwan service: {e}")
            return False

    def _load_ipsec_config(self) -> bool:
        """Load IPSec configuration."""
        try:
            logger.debug("Loading IPSec configuration")
            
            # Verify charon is running before attempting to load config
            if not self._verify_charon_running():
                logger.error("Charon not running, cannot load configuration")
                return False
            
            # Use ipsec reload to load configuration
            logger.debug("Reloading strongSwan configuration")
            reload_cmd = ['ipsec', 'reload']
            reload_result = subprocess.run(reload_cmd, capture_output=True, timeout=8)
            logger.debug(f"Reload command result: {reload_result.returncode}, stdout: {reload_result.stdout.decode()}, stderr: {reload_result.stderr.decode()}")
            
            # Wait for configuration to be processed
            time.sleep(3)
            
            # Verify configuration was loaded by checking if our connection is listed
            return self._verify_config_loaded()
                    
        except Exception as e:
            logger.error(f"Failed to load IPSec configuration: {e}")
            return False
    
    def _verify_config_loaded(self) -> bool:
        """Verify that the VPN configuration was loaded successfully."""
        try:
            # Check if our connection 'vpntest' is loaded (like debug script)
            status_cmd = ['ipsec', 'status']
            status_result = subprocess.run(status_cmd, capture_output=True, timeout=5)
            
            if status_result.returncode == 0:
                output = status_result.stdout.decode()
                logger.debug(f"Configuration status output: {output[:300]}...")
                
                # Look for our connection in the output - format is "vpntest[number]:"
                if 'vpntest[' in output or 'vpntest:' in output or 'vpntest ' in output:
                    logger.debug("Configuration 'vpntest' found in status")
                    return True
                else:
                    logger.debug("Configuration 'vpntest' not found in status output")
                    
                    # Try alternative check like debug script
                    listconns_cmd = ['ipsec', 'listconns']
                    listconns_result = subprocess.run(listconns_cmd, capture_output=True, timeout=5)
                    if listconns_result.returncode == 0:
                        listconns_output = listconns_result.stdout.decode()
                        logger.debug(f"List connections output: {listconns_output[:200]}...")
                        if 'vpntest' in listconns_output:
                            logger.debug("Configuration found via listconns")
                            return True
                    
                    return False
            else:
                logger.error(f"Status command failed: {status_result.stderr.decode()[:200]}...")
                return False
                
        except Exception as e:
            logger.error(f"Configuration verification failed: {e}")
            return False

    def _ensure_clean_strongswan_state(self):
        """Ensure strongSwan is in a clean state before starting."""
        try:
            # Kill any existing processes
            processes_to_kill = ['charon', 'starter', 'ipsec']
            for process in processes_to_kill:
                subprocess.run(['killall', '-9', process], capture_output=True, timeout=3)
            
            # Remove PID and control files
            files_to_remove = [
                '/var/run/charon.pid',
                '/var/run/starter.charon.pid', 
                '/var/run/starter.pid',
                '/var/run/charon.ctl',
                '/var/run/charon.vici'
            ]
            
            for file_path in files_to_remove:
                if os.path.exists(file_path):
                    os.remove(file_path)
                    logger.debug(f"Removed {file_path}")
            
            # Wait for cleanup
            time.sleep(1)
            
        except Exception as e:
            logger.debug(f"Cleanup warning: {e}")
    
    def _verify_charon_running(self) -> bool:
        """Verify that charon daemon is running and responding."""
        try:
            # Check if charon process exists
            pgrep_result = subprocess.run(['pgrep', 'charon'], capture_output=True, timeout=5)
            if pgrep_result.returncode != 0:
                logger.debug("Charon process not found")
                return False
            
            # Try to get status via ipsec command
            status_result = subprocess.run(['ipsec', 'status'], capture_output=True, timeout=5)
            if status_result.returncode == 0:
                logger.debug("Charon responding to status requests")
                return True
            else:
                logger.debug(f"Charon not responding: {status_result.stderr.decode()}")
                return False
                
        except Exception as e:
            logger.debug(f"Charon verification failed: {e}")
            return False

    def _load_ipsec_config(self) -> bool:
        """Load IPSec configuration."""
        try:
            logger.debug("Loading IPSec configuration")
            
            # Verify charon is running before attempting to load config
            if not self._verify_charon_running():
                logger.error("Charon not running, cannot load configuration")
                return False
            
            # Use ipsec reload to load configuration
            logger.debug("Reloading strongSwan configuration")
            reload_cmd = ['ipsec', 'reload']
            reload_result = subprocess.run(reload_cmd, capture_output=True, timeout=8)
            logger.debug(f"Reload command result: {reload_result.returncode}, stdout: {reload_result.stdout.decode()}, stderr: {reload_result.stderr.decode()}")
            
            # Wait for configuration to be processed
            time.sleep(3)
            
            # Verify configuration was loaded by checking if our connection is listed
            return self._verify_config_loaded()
                    
        except Exception as e:
            logger.error(f"Failed to load IPSec configuration: {e}")
            return False
    
    def _verify_config_loaded(self) -> bool:
        """Verify that the VPN configuration was loaded successfully."""
        try:
            # Check if our connection 'vpntest' is loaded (like debug script)
            status_cmd = ['ipsec', 'status']
            status_result = subprocess.run(status_cmd, capture_output=True, timeout=5)
            
            if status_result.returncode == 0:
                output = status_result.stdout.decode()
                logger.debug(f"Configuration status output: {output[:300]}...")
                
                # Look for our connection in the output - format is "vpntest[number]:"
                if 'vpntest[' in output or 'vpntest:' in output or 'vpntest ' in output:
                    logger.debug("Configuration 'vpntest' found in status")
                    return True
                else:
                    logger.debug("Configuration 'vpntest' not found in status output")
                    
                    # Try alternative check like debug script
                    listconns_cmd = ['ipsec', 'listconns']
                    listconns_result = subprocess.run(listconns_cmd, capture_output=True, timeout=5)
                    if listconns_result.returncode == 0:
                        listconns_output = listconns_result.stdout.decode()
                        logger.debug(f"List connections output: {listconns_output[:200]}...")
                        if 'vpntest' in listconns_output:
                            logger.debug("Configuration found via listconns")
                            return True
                    
                    return False
            else:
                logger.error(f"Status command failed: {status_result.stderr.decode()[:200]}...")
                return False
                
        except Exception as e:
            logger.error(f"Configuration verification failed: {e}")
            return False

    def _test_vpn_connection(self, server: Dict[str, str]) -> Tuple[bool, Optional[int], Optional[str]]:
        """
        Test actual VPN connection to a server.
        Returns: (success, connection_time_ms, error_message)
        """
        start_time = time.time()
        
        try:
            logger.info(f"Testing VPN connection to {server['name']} ({server['ip']})")
            
            # Create temporary configuration directory
            config_dir = os.path.join(self.temp_dir, f"vpn_{server['name']}_{int(time.time())}")
            os.makedirs(config_dir, exist_ok=True)
            
            # Test basic connectivity first
            if not self._test_basic_connectivity(server['ip']):
                connection_time = int((time.time() - start_time) * 1000)
                return False, connection_time, f"Cannot reach VPN server {server['ip']}"
            
            # Stop any existing VPN connections first
            self._stop_all_vpn_connections()
            
            # Create VPN configurations
            ipsec_config = self._create_ipsec_config(server, config_dir)
            xl2tpd_config = self._create_xl2tpd_config(server, config_dir)
            
            logger.debug(f"Starting strongSwan daemon for {server['name']}")
            
            # Start strongSwan service
            if not self._start_strongswan_daemon():
                connection_time = int((time.time() - start_time) * 1000)
                return False, connection_time, "Failed to start strongSwan daemon"
            
            # Load configuration
            if not self._load_ipsec_config():
                connection_time = int((time.time() - start_time) * 1000)
                return False, connection_time, "Failed to load IPSec configuration"
            
            # Wait for auto=start to trigger connection (like debug script)
            logger.debug(f"Waiting for auto=start connection for {server['name']}")
            time.sleep(5)  # Give more time for connection like debug script
            
            # Wait for connection establishment like debug script does
            max_wait_time = 20  # Wait up to 20 seconds like debug script
            wait_interval = 2
            waited = 0
            
            while waited < max_wait_time:
                # Check status
                status_cmd = ['ipsec', 'statusall']
                status_result = subprocess.run(status_cmd, capture_output=True, timeout=5)
                status_output = status_result.stdout.decode() if status_result.returncode == 0 else "No status available"
                
                logger.debug(f"IPSec status check (waited {waited}s): {status_output[:200]}...")
                
                if "ESTABLISHED" in status_output:
                    connection_time = int((time.time() - start_time) * 1000)
                    logger.info(f"🎉 SUCCESS: IPSec tunnel established with {server['name']} after {waited}s!")
                    return True, connection_time, None
                elif "CONNECTING" in status_output:
                    logger.debug(f"Still connecting to {server['name']}, waiting...")
                    time.sleep(wait_interval)
                    waited += wait_interval
                    continue
                else:
                    # No connection attempt visible, something went wrong
                    break
            
            # If we get here, connection failed or timed out
            connection_time = int((time.time() - start_time) * 1000)
            
            # Get final status for error analysis
            status_cmd = ['ipsec', 'statusall']
            status_result = subprocess.run(status_cmd, capture_output=True, timeout=5)
            final_status = status_result.stdout.decode() if status_result.returncode == 0 else "No status available"
            
            # Check for specific error patterns
            error_details = self._analyze_ipsec_error(final_status, final_status)
            return False, connection_time, error_details
        except subprocess.TimeoutExpired:
            connection_time = int((time.time() - start_time) * 1000)
            return False, connection_time, "VPN connection timeout"
        except Exception as e:
            connection_time = int((time.time() - start_time) * 1000)
            logger.error(f"VPN test failed for {server['name']}: {e}")
            return False, connection_time, str(e)
        finally:
            # Always cleanup
            self._stop_all_vpn_connections()

    def _test_basic_connectivity(self, ip: str) -> bool:
        """Test basic network connectivity to IP."""
        try:
            # Use same ping approach as debug script
            ping_cmd = ['ping', '-c', '3', ip]
            ping_result = subprocess.run(ping_cmd, capture_output=True, timeout=10)
            
            if ping_result.returncode == 0:
                logger.debug(f"Ping to {ip} successful")
                return True
            else:
                logger.debug(f"Ping to {ip} failed but continuing (server may block ICMP)")
                return True  # Continue like debug script does
                
        except Exception as e:
            logger.debug(f"Connectivity test error: {e}")
            return True  # Continue anyway

    def _check_ipsec_status(self) -> bool:
        """Check if IPSec tunnel is established."""
        try:
            status_cmd = ['ipsec', 'statusall']
            status_result = subprocess.run(status_cmd, capture_output=True, timeout=5)
            if status_result.returncode == 0:
                output = status_result.stdout.decode()
                # Look for established connections
                if 'ESTABLISHED' in output:
                    logger.debug("IPSec tunnel is ESTABLISHED")
                    return True
                elif 'CONNECTING' in output:
                    logger.debug("IPSec still connecting...")
                    return False
                else:
                    logger.debug(f"IPSec status: {output}")
            return False
        except Exception:
            return False

    def _verify_vpn_connection(self) -> bool:
        """Verify that VPN connection is actually established."""
        try:
            # Check strongSwan status first
            ipsec_established = self._check_ipsec_status()
            if ipsec_established:
                logger.debug("IPSec tunnel established")
            else:
                logger.debug("IPSec tunnel not established")
                return False
            
            # For L2TP/IPSec, IPSec establishment is often sufficient
            # But let's also check for L2TP indicators
            
            # Check for ppp interfaces
            ip_result = subprocess.run(['ip', 'addr', 'show'], capture_output=True, timeout=5)
            ip_output = ip_result.stdout.decode()
            if b'ppp' in ip_result.stdout:
                logger.debug("PPP interface found")
                return True
            
            # Check for VPN routes
            route_result = subprocess.run(['ip', 'route'], capture_output=True, timeout=5)
            route_output = route_result.stdout.decode()
            if b'ppp' in route_result.stdout:
                logger.debug("PPP route found")
                return True
            
            # Check for active pppd processes
            pppd_check = subprocess.run(['pgrep', 'pppd'], capture_output=True, timeout=5)
            if pppd_check.returncode == 0:
                logger.debug("PPP daemon running")
                return True
            
            # If IPSec is established, consider it a partial success
            # Some L2TP/IPSec setups only establish IPSec tunnel
            if ipsec_established:
                logger.debug("IPSec established - considering as successful connection")
                return True
            
            logger.debug(f"No VPN indicators found. IP interfaces: {ip_output[:200]}... Routes: {route_output[:200]}...")
            return False
            
        except Exception as e:
            logger.debug(f"Connection verification failed: {e}")
            return False

    def _analyze_ipsec_error(self, up_output: str, status_info: str) -> str:
        """Analyze IPSec connection errors and provide helpful error messages."""
        try:
            error_msg = "Connection failed"
            
            # Check for common error patterns
            if "no proposal chosen" in up_output.lower():
                error_msg = "Encryption algorithm mismatch - server rejected our proposals"
            elif "authentication failed" in up_output.lower():
                error_msg = "Authentication failed - likely incorrect shared key"
            elif "timeout" in up_output.lower():
                error_msg = "Connection timeout - server may be unreachable or firewall blocking"
            elif "no response" in up_output.lower():
                error_msg = "No response from server - check server configuration"
            elif "establishing connection" in up_output.lower() and "failed" in up_output.lower():
                if "retransmit" in up_output.lower():
                    error_msg = "Server not responding to handshake - possible firewall or server config issue"
                else:
                    error_msg = "Connection establishment failed"
            
            # Add technical details for debugging
            error_msg += f". Technical details: {up_output[:200]}..."
            
            return error_msg
            
        except Exception as e:
            return f"Error analysis failed: {e}. Raw output: {up_output[:100]}..."

    def _log_result(self, server: Dict[str, str], success: bool, connection_time: Optional[int], error_message: Optional[str]):
        """Log test result to database."""
        try:
            connection = self._get_db_connection()
            cursor = connection.cursor()
            
            # Insert test result
            insert_query = """
                INSERT INTO vpn_test_results 
                (computer_identifier, system_username, public_ip_address, vpn_server_name, 
                 vpn_server_ip, connection_successful, connection_time_ms, error_message, 
                 operating_system, monitor_version)
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
            """
            
            cursor.execute(insert_query, (
                self.system_info['hostname'],
                self.system_info['username'],
                self.system_info['public_ip'],
                server['name'],
                server['ip'],
                success,
                connection_time,
                error_message,
                f"{self.system_info['os']} {self.system_info['os_version']}",
                VERSION
            ))
            
            # Update monitor instance
            upsert_monitor_query = """
                INSERT INTO monitor_instances 
                (computer_identifier, system_username, operating_system, monitor_version, total_tests_run)
                VALUES (%s, %s, %s, %s, 1)
                ON DUPLICATE KEY UPDATE
                    last_seen = CURRENT_TIMESTAMP,
                    total_tests_run = total_tests_run + 1,
                    monitor_version = VALUES(monitor_version)
            """
            
            cursor.execute(upsert_monitor_query, (
                self.system_info['hostname'],
                self.system_info['username'],
                f"{self.system_info['os']} {self.system_info['os_version']}",
                VERSION
            ))
            
            connection.commit()
            cursor.close()
            connection.close()
            
            logger.info(f"Logged result for {server['name']}: {'SUCCESS' if success else 'FAILED'}")
            
        except Exception as e:
            logger.error(f"Failed to log result to database: {e}")

    def health_check(self) -> bool:
        """Perform health check for container monitoring."""
        try:
            # Test database connection
            connection = self._get_db_connection()
            cursor = connection.cursor()
            cursor.execute("SELECT 1")
            cursor.close()
            connection.close()
            
            # Test that VPN tools are available
            subprocess.run(['ipsec', '--version'], capture_output=True, timeout=5, check=True)
            subprocess.run(['xl2tpd', '--version'], capture_output=True, timeout=5)
            
            logger.info("Health check passed")
            return True
            
        except Exception as e:
            logger.error(f"Health check failed: {e}")
            return False

    def run_tests(self):
        """Run VPN tests for all configured servers."""
        logger.info(f"Starting VPN monitoring run - {len(self.vpn_servers)} servers to test")
        logger.info(f"System: {self.system_info['hostname']} ({self.system_info['os']})")
        logger.info(f"Public IP: {self.system_info['public_ip']}")
        logger.info(f"Monitor Version: {VERSION}")
        
        # Store results for summary
        results = []
        
        for server in self.vpn_servers:
            logger.info(f"Testing VPN server: {server['name']} ({server['ip']})")
            
            success, connection_time, error_message = self._test_vpn_connection(server)
            
            # Log result to database
            self._log_result(server, success, connection_time, error_message)
            
            # Store result for summary
            results.append({
                'server': server,
                'success': success,
                'connection_time': connection_time,
                'error_message': error_message
            })
            
            if success:
                logger.info(f"✓ {server['name']}: Connected successfully ({connection_time}ms)")
            else:
                logger.warning(f"✗ {server['name']}: Failed - {error_message}")
        
        logger.info("VPN monitoring run completed")
        
        # Display summary
        self._display_summary(results)
    
    def _display_summary(self, results):
        """Display a summary of test results."""
        print("\n" + "="*60)
        print("🔍 VPN MONITORING RESULTS SUMMARY")
        print("="*60)
        
        total_servers = len(results)
        successful = sum(1 for r in results if r['success'])
        failed = total_servers - successful
        
        print(f"📊 Overall Status: {successful}/{total_servers} servers successful")
        print(f"⏱️  Test completed at: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
        print()
        
        for result in results:
            server = result['server']
            if result['success']:
                print(f"✅ {server['name']} ({server['ip']})")
                print(f"   └─ Connected in {result['connection_time']}ms")
            else:
                print(f"❌ {server['name']} ({server['ip']})")
                print(f"   └─ Error: {result['error_message']}")
            print()
        
        if failed > 0:
            print("🔧 TROUBLESHOOTING:")
            print("   • Run debug script: docker-compose run --rm vpn-monitor /app/synology_debug.sh")
            print("   • Check server logs and firewall settings")
            print("   • Verify shared keys and credentials")
        
        print("="*60)
        print("📋 Results logged to database for historical tracking")
        print("="*60)

    def run_continuous_monitoring(self):
        """Run continuous VPN monitoring with configured polling interval."""
        if self.poll_interval <= 0:
            logger.info("Continuous monitoring disabled (POLL_INTERVAL_MINUTES=0), running single test")
            self.run_tests()
            return
        
        logger.info(f"🔄 Starting continuous VPN monitoring (polling every {self.poll_interval} minutes)")
        logger.info(f"📡 Monitoring {len(self.vpn_servers)} VPN servers")
        logger.info(f"🖥️  System: {self.system_info['hostname']} ({self.system_info['os']})")
        logger.info(f"🌐 Public IP: {self.system_info['public_ip']}")
        logger.info(f"📦 Version: {VERSION}")
        logger.info("🛑 Press Ctrl+C or send SIGTERM to stop gracefully")
        print()
        
        iteration = 0
        
        try:
            while True:
                iteration += 1
                current_time = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
                
                logger.info(f"🔍 Starting monitoring iteration #{iteration} at {current_time}")
                
                # Run the VPN tests
                self.run_tests()
                
                # Calculate next run time
                next_run = datetime.now()
                next_run = next_run.replace(second=0, microsecond=0)
                next_run_timestamp = next_run.timestamp() + (self.poll_interval * 60)
                next_run_formatted = datetime.fromtimestamp(next_run_timestamp).strftime('%Y-%m-%d %H:%M:%S')
                
                logger.info(f"💤 Monitoring iteration #{iteration} completed. Next run scheduled for {next_run_formatted}")
                logger.info(f"⏱️  Sleeping for {self.poll_interval} minutes...")
                print()
                
                # Sleep for the configured interval
                time.sleep(self.poll_interval * 60)
                
        except KeyboardInterrupt:
            logger.info("🛑 Continuous monitoring stopped by user (Ctrl+C)")
        except Exception as e:
            logger.error(f"💥 Fatal error in continuous monitoring: {e}")
            raise

def signal_handler(signum, frame):
    """Handle shutdown signals gracefully."""
    signal_name = "SIGTERM" if signum == signal.SIGTERM else "SIGINT" if signum == signal.SIGINT else f"Signal {signum}"
    logger.info(f"🛑 Received {signal_name}, shutting down gracefully...")
    sys.exit(0)


def main():
    """Main entry point."""
    # Set up signal handlers
    signal.signal(signal.SIGTERM, signal_handler)
    signal.signal(signal.SIGINT, signal_handler)
    
    # Check for health check argument
    if len(sys.argv) > 1 and sys.argv[1] == '--health-check':
        try:
            monitor = VPNMonitor()
            if monitor.health_check():
                print("✅ Health check passed")
                sys.exit(0)
            else:
                print("❌ Health check failed")
                sys.exit(1)
        except Exception as e:
            logger.error(f"Health check error: {e}")
            sys.exit(1)
    
    # Check for single-run mode
    if len(sys.argv) > 1 and sys.argv[1] == '--single-run':
        try:
            monitor = VPNMonitor()
            monitor.run_tests()
        except KeyboardInterrupt:
            logger.info("Single run interrupted by user")
            sys.exit(0)
        except Exception as e:
            logger.error(f"Fatal error in single run: {e}")
            sys.exit(1)
        return
    
    try:
        monitor = VPNMonitor()
        monitor.run_continuous_monitoring()
    except KeyboardInterrupt:
        logger.info("Monitoring interrupted by user")
        sys.exit(0)
    except Exception as e:
        logger.error(f"Fatal error: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()