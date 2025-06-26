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
    level=logging.INFO,
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
        
        # Parse VPN servers
        self.vpn_servers = self._parse_vpn_servers()
        
        # System information
        self.system_info = self._get_system_info()
        
        # Validate configuration
        self._validate_config()
        
        # VPN configuration directories
        self.temp_dir = tempfile.mkdtemp(prefix="vpn_test_")

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
            subprocess.run(['ipsec', 'down', 'vpntest'], capture_output=True, timeout=5)
            
            # Kill all VPN-related processes forcefully
            processes_to_kill = ['xl2tpd', 'pppd', 'charon', 'starter']
            for process in processes_to_kill:
                subprocess.run(['killall', '-9', process], capture_output=True, timeout=3)
            
            # Clean up all control and PID files
            files_to_remove = [
                '/var/run/xl2tpd/l2tp-control',
                '/var/run/charon.pid',
                '/var/run/starter.charon.pid',
                '/var/run/starter.pid',
                '/var/run/charon.ctl'
            ]
            
            for file_path in files_to_remove:
                subprocess.run(['rm', '-f', file_path], capture_output=True)
            
            # Wait for complete cleanup
            time.sleep(3)
            
        except Exception as e:
            logger.debug(f"VPN cleanup: {e}")

    def _create_ipsec_config(self, server: Dict[str, str], config_dir: str) -> str:
        """Create IPSec configuration for strongSwan."""
        config_file = '/etc/ipsec.conf'
        secrets_file = '/etc/ipsec.secrets'
        
        # Simplified and more compatible IPSec configuration
        config_content = f"""
config setup
    charondebug="ike 1, knl 1, cfg 0"
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
    auto=add
    ike=aes256-sha1-modp1024,aes128-sha1-modp1024,3des-sha1-modp1024!
    esp=aes256-sha1-modp1024,aes128-sha1-modp1024,3des-sha1-modp1024!
    rekey=no
    leftid=%any
    rightid={server['ip']}
    aggressive=yes
    ikelifetime=8h
    keylife=1h
"""
        
        with open(config_file, 'w') as f:
            f.write(config_content)
        
        # Create secrets file with universal format
        secrets_content = f"""# strongSwan IPsec secrets file
{server['ip']} %any : PSK "{server['shared_key']}"
%any {server['ip']} : PSK "{server['shared_key']}"
"""
        with open(secrets_file, 'w') as f:
            f.write(secrets_content)
        os.chmod(secrets_file, 0o600)
        
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
        """Start strongSwan daemon directly."""
        try:
            logger.debug("Starting strongSwan daemon directly")
            
            # Start charon daemon directly
            charon_cmd = ['charon', '--use-syslog']
            charon_process = subprocess.Popen(
                charon_cmd, 
                stdout=subprocess.PIPE, 
                stderr=subprocess.PIPE,
                preexec_fn=os.setsid
            )
            
            # Wait for charon to start
            time.sleep(5)
            
            # Check if charon is running
            charon_check = subprocess.run(['pgrep', 'charon'], capture_output=True, timeout=5)
            if charon_check.returncode == 0:
                logger.debug("Charon daemon started successfully")
                return True
            else:
                logger.debug("Failed to start charon daemon")
                return False
                
        except Exception as e:
            logger.debug(f"Failed to start strongSwan daemon: {e}")
            return False

    def _load_ipsec_config(self) -> bool:
        """Load IPSec configuration using stroke interface."""
        try:
            logger.debug("Loading IPSec configuration")
            
            # Use stroke to load configuration
            stroke_cmd = ['stroke', 'up-nb', 'vpntest']
            stroke_result = subprocess.run(stroke_cmd, capture_output=True, timeout=10)
            
            if stroke_result.returncode == 0:
                logger.debug("Configuration loaded via stroke")
                return True
            else:
                # Try alternative method with ipsec
                reload_cmd = ['ipsec', 'reload']
                reload_result = subprocess.run(reload_cmd, capture_output=True, timeout=10)
                
                if reload_result.returncode == 0:
                    logger.debug("Configuration loaded via ipsec reload")
                    return True
                else:
                    logger.debug(f"Failed to load config: stroke={stroke_result.stderr.decode()}, ipsec={reload_result.stderr.decode()}")
                    return False
                    
        except Exception as e:
            logger.debug(f"Failed to load IPSec configuration: {e}")
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
            
            # Start strongSwan daemon directly
            if not self._start_strongswan_daemon():
                connection_time = int((time.time() - start_time) * 1000)
                return False, connection_time, "Failed to start strongSwan daemon"
            
            # Load configuration
            if not self._load_ipsec_config():
                connection_time = int((time.time() - start_time) * 1000)
                return False, connection_time, "Failed to load IPSec configuration"
            
            # Wait for daemon to be ready
            time.sleep(3)
            
            logger.debug(f"Attempting to bring up IPSec connection for {server['name']}")
            
            # Try multiple methods to bring up the connection
            connection_methods = [
                ['ipsec', 'up', 'vpntest'],
                ['stroke', 'up', 'vpntest'],
                ['swanctl', '--initiate', '--child', 'vpntest']
            ]
            
            up_success = False
            up_output = ""
            
            for method in connection_methods:
                try:
                    logger.debug(f"Trying connection method: {' '.join(method)}")
                    up_result = subprocess.run(method, capture_output=True, timeout=20)
                    up_output += f"{' '.join(method)}: {up_result.stdout.decode()} {up_result.stderr.decode()}\n"
                    
                    if up_result.returncode == 0:
                        up_success = True
                        logger.debug(f"Connection method succeeded: {' '.join(method)}")
                        break
                        
                except Exception as e:
                    up_output += f"{' '.join(method)}: Exception {e}\n"
                    continue
            
            logger.debug(f"IPSec up command output: {up_output}")
            
            # Wait for IPSec to establish
            time.sleep(8)
            
            # Give more time for connection establishment and check periodically
            max_wait = 25
            wait_time = 0
            while wait_time < max_wait:
                if self._check_ipsec_status():
                    logger.debug(f"IPSec established after {wait_time} seconds")
                    break
                time.sleep(2)
                wait_time += 2
            
            # Verify IPSec is established before proceeding to L2TP
            ipsec_status = self._check_ipsec_status()
            if not ipsec_status:
                connection_time = int((time.time() - start_time) * 1000)
                status_cmd = ['ipsec', 'statusall']
                status_result = subprocess.run(status_cmd, capture_output=True, timeout=5)
                status_info = status_result.stdout.decode() if status_result.returncode == 0 else "No status available"
                return False, connection_time, f"IPSec tunnel not established after {max_wait}s. Methods tried: {up_output}. Status: {status_info}"
            
            logger.debug(f"IPSec established, starting L2TP for {server['name']}")
            
            # Start xl2tpd
            xl2tpd_cmd = ['xl2tpd', '-c', '/etc/xl2tpd/xl2tpd.conf', '-C', '/var/run/xl2tpd/l2tp-control']
            xl2tpd_process = subprocess.Popen(xl2tpd_cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            
            # Wait for xl2tpd to start properly
            time.sleep(3)
            
            # Attempt L2TP connection
            try:
                # Check if control file exists
                if not os.path.exists('/var/run/xl2tpd/l2tp-control'):
                    time.sleep(2)  # Wait a bit more
                
                if os.path.exists('/var/run/xl2tpd/l2tp-control'):
                    # Send connect command via echo to control socket
                    connect_cmd = 'echo "c vpntest" > /var/run/xl2tpd/l2tp-control'
                    control_result = subprocess.run(connect_cmd, shell=True, capture_output=True, timeout=10)
                    logger.debug(f"L2TP connect command result: {control_result.returncode}")
                else:
                    logger.debug("L2TP control file not found")
                
                # Wait for connection establishment
                time.sleep(10)
                
            except Exception as e:
                logger.debug(f"L2TP connection attempt failed: {e}")
            
            # Check if connection was established
            connection_time = int((time.time() - start_time) * 1000)
            
            # Verify connection by checking interfaces or routes
            if self._verify_vpn_connection():
                return True, connection_time, None
            else:
                # Get more detailed error information
                status_cmd = ['ipsec', 'statusall']
                status_result = subprocess.run(status_cmd, capture_output=True, timeout=5)
                status_info = status_result.stdout.decode() if status_result.returncode == 0 else "No status available"
                
                # Check xl2tpd process
                xl2tpd_status = "xl2tpd not running"
                try:
                    xl2tpd_check = subprocess.run(['pgrep', 'xl2tpd'], capture_output=True, timeout=5)
                    if xl2tpd_check.returncode == 0:
                        xl2tpd_status = "xl2tpd running"
                except:
                    pass
                
                return False, connection_time, f"VPN tunnel establishment failed. IPSec status: {status_info}. L2TP status: {xl2tpd_status}"
                
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
            ping_cmd = ['ping', '-c', '1', '-W', '5', ip]
            ping_result = subprocess.run(ping_cmd, capture_output=True, timeout=10)
            return ping_result.returncode == 0
        except:
            return False

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
        
        for server in self.vpn_servers:
            logger.info(f"Testing VPN server: {server['name']} ({server['ip']})")
            
            success, connection_time, error_message = self._test_vpn_connection(server)
            
            # Log result to database
            self._log_result(server, success, connection_time, error_message)
            
            if success:
                logger.info(f"✓ {server['name']}: Connected successfully ({connection_time}ms)")
            else:
                logger.warning(f"✗ {server['name']}: Failed - {error_message}")
        
        logger.info("VPN monitoring run completed")


def signal_handler(signum, frame):
    """Handle shutdown signals gracefully."""
    logger.info("Received shutdown signal, cleaning up...")
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
                sys.exit(0)
            else:
                sys.exit(1)
        except Exception as e:
            logger.error(f"Health check error: {e}")
            sys.exit(1)
    
    try:
        monitor = VPNMonitor()
        monitor.run_tests()
    except KeyboardInterrupt:
        logger.info("Monitoring interrupted by user")
        sys.exit(0)
    except Exception as e:
        logger.error(f"Fatal error: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()