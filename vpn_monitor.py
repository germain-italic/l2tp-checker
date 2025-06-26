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
            # Stop strongSwan connections more thoroughly
            subprocess.run(['ipsec', 'auto', '--down', 'vpntest'], capture_output=True, timeout=5)
            # Stop strongSwan connections and service
            subprocess.run(['ipsec', 'down', 'vpntest'], capture_output=True, timeout=5)
            subprocess.run(['ipsec', 'stop'], capture_output=True, timeout=10)
            
            # Also try to stop starter directly
            subprocess.run(['killall', 'starter'], capture_output=True, timeout=5)
            subprocess.run(['killall', 'charon'], capture_output=True, timeout=5)
            
            # Stop xl2tpd processes
            subprocess.run(['killall', 'xl2tpd'], capture_output=True, timeout=5)
            
            # Clean up any ppp interfaces
            subprocess.run(['killall', 'pppd'], capture_output=True, timeout=5)
            
        except Exception as e:
            logger.debug(f"VPN cleanup: {e}")

    def _create_ipsec_config(self, server: Dict[str, str], config_dir: str) -> str:
        """Create IPSec configuration for strongSwan."""
        # Use system directories that strongSwan expects
        config_file = '/etc/ipsec.conf'
        secrets_file = '/etc/ipsec.secrets'
        
        # Try multiple IPSec configurations for better compatibility
        # This configuration is more aggressive and tries multiple cipher combinations
        config_content = f"""
config setup
    charondebug="ike 2, knl 2, cfg 2, net 2, asn 2, enc 2, lib 2, esp 2, tls 2, tnc 2, imc 2, imv 2, pts 2"
    strictcrlpolicy=no
    uniqueids=no
    cachecrls=no

conn vpntest
    type=transport
    keyexchange=ikev1
    left=%defaultroute
    leftprotoport=17/1701
    right={server['ip']}
    rightprotoport=17/1701
    authby=psk
    auto=add
    ike=aes256-sha1-modp1024,aes128-sha1-modp1024,3des-sha1-modp1024,aes256-md5-modp1024,aes128-md5-modp1024,3des-md5-modp1024!
    esp=aes256-sha1,aes128-sha1,3des-sha1,aes256-md5,aes128-md5,3des-md5!
    pfs=no
    rekey=no
    leftid=
    rightid=
    aggressive=yes
    compress=no
"""
        
        with open(config_file, 'w') as f:
            f.write(config_content)
        
        # Create secrets file
        secrets_content = f"""# /etc/ipsec.secrets - strongSwan IPsec secrets file
%any %any : PSK "{server['shared_key']}"
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
        
        config_content = f"""
[global]
port = 1701
access control = no
auth file = /etc/ppp/chap-secrets
debug avp = no
debug network = no
debug packet = no
debug state = no
debug tunnel = no

[lac vpntest]
lns = {server['ip']}
ppp debug = no
pppoptfile = /etc/ppp/options.l2tpd
length bit = yes
require chap = yes
refuse pap = yes
require authentication = no
name = {server['username']}
ppp debug = no
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
idle 0
mtu 1410
mru 1410
nodefaultroute
usepeerdns
nodebug
connect-delay 5000
lock
proxyarp
lcp-echo-interval 30
lcp-echo-failure 4
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
            
            # Wait a moment for cleanup
            time.sleep(1)
            
            # Create VPN configurations
            ipsec_config = self._create_ipsec_config(server, config_dir)
            xl2tpd_config = self._create_xl2tpd_config(server, config_dir)
            
            logger.debug(f"Starting IPSec for {server['name']}")
            
            # Start strongSwan properly - need to start the starter daemon first
            # First, make sure any existing processes are stopped
            subprocess.run(['ipsec', 'stop'], capture_output=True, timeout=10)
            time.sleep(1)
            
            # Start strongSwan with proper initialization
            ipsec_cmd = ['ipsec', 'start', '--nofork']
            ipsec_result = subprocess.run(ipsec_cmd, capture_output=True, timeout=15)
            
            logger.debug(f"IPSec start result: {ipsec_result.returncode}")
            logger.debug(f"IPSec start stdout: {ipsec_result.stdout.decode()}")
            logger.debug(f"IPSec start stderr: {ipsec_result.stderr.decode()}")
            
            # If nofork fails, try regular start
            if ipsec_result.returncode != 0:
                logger.debug("Trying regular IPSec start")
                ipsec_cmd = ['ipsec', 'start']
                ipsec_result = subprocess.run(ipsec_cmd, capture_output=True, timeout=15)
                
                logger.debug(f"IPSec regular start result: {ipsec_result.returncode}")
                logger.debug(f"IPSec regular start stdout: {ipsec_result.stdout.decode()}")
                logger.debug(f"IPSec regular start stderr: {ipsec_result.stderr.decode()}")
                
                if ipsec_result.returncode != 0:
                    connection_time = int((time.time() - start_time) * 1000)
                    error_msg = ipsec_result.stderr.decode() + " " + ipsec_result.stdout.decode()
                    return False, connection_time, f"IPSec start failed: {error_msg.strip()}"
            
            # Wait for strongSwan to initialize and check if it's running
            time.sleep(2)
            
            # Verify strongSwan is actually running
            check_cmd = ['ipsec', 'status']
            check_result = subprocess.run(check_cmd, capture_output=True, timeout=5)
            logger.debug(f"IPSec status check: {check_result.returncode}")
            logger.debug(f"IPSec status output: {check_result.stdout.decode()}")
            
            if check_result.returncode != 0:
                # Try alternative startup method
                logger.debug("Trying alternative strongSwan startup")
                alt_cmd = ['starter', '--nofork']
                alt_result = subprocess.run(alt_cmd, capture_output=True, timeout=10)
                logger.debug(f"Starter result: {alt_result.returncode}")
                time.sleep(2)
            
            # Reload configuration and bring up connection
            logger.debug(f"Reloading IPSec configuration for {server['name']}")
            reload_cmd = ['ipsec', 'reload']
            reload_result = subprocess.run(reload_cmd, capture_output=True, timeout=10)
            
            logger.debug(f"IPSec reload result: {reload_result.returncode}")
            logger.debug(f"IPSec reload stdout: {reload_result.stdout.decode()}")
            logger.debug(f"IPSec reload stderr: {reload_result.stderr.decode()}")
            
            if reload_result.returncode != 0:
                # If reload fails, try to add the connection directly
                logger.debug("Reload failed, trying to add connection directly")
                add_cmd = ['ipsec', 'auto', '--add', 'vpntest']
                add_result = subprocess.run(add_cmd, capture_output=True, timeout=10)
                logger.debug(f"IPSec add result: {add_result.returncode}")
                logger.debug(f"IPSec add stdout: {add_result.stdout.decode()}")
                logger.debug(f"IPSec add stderr: {add_result.stderr.decode()}")
            
            logger.debug(f"Bringing up IPSec connection for {server['name']}")
            
            # Try both 'up' and 'auto --up' commands
            up_cmd = ['ipsec', 'auto', '--up', 'vpntest']
            up_result = subprocess.run(up_cmd, capture_output=True, timeout=15)
            
            logger.debug(f"IPSec up result: {up_result.returncode}")
            logger.debug(f"IPSec up stdout: {up_result.stdout.decode()}")
            logger.debug(f"IPSec up stderr: {up_result.stderr.decode()}")
            
            if up_result.returncode != 0:
                # Try the traditional 'up' command
                logger.debug("Trying traditional ipsec up command")
                up_cmd_alt = ['ipsec', 'up', 'vpntest']
                up_result_alt = subprocess.run(up_cmd_alt, capture_output=True, timeout=15)
                
                logger.debug(f"IPSec up alt result: {up_result_alt.returncode}")
                logger.debug(f"IPSec up alt stdout: {up_result_alt.stdout.decode()}")
                logger.debug(f"IPSec up alt stderr: {up_result_alt.stderr.decode()}")
                
                if up_result_alt.returncode != 0:
                    connection_time = int((time.time() - start_time) * 1000)
                    error_msg = up_result_alt.stderr.decode() + " " + up_result_alt.stdout.decode()
                    
                    # Get status for debugging
                    status_cmd = ['ipsec', 'status']
                    status_result = subprocess.run(status_cmd, capture_output=True, timeout=5)
                    status_info = status_result.stdout.decode() if status_result.returncode == 0 else "No status available"
                    
                    # Also get statusall for more detailed info
                    statusall_cmd = ['ipsec', 'statusall']
                    statusall_result = subprocess.run(statusall_cmd, capture_output=True, timeout=5)
                    statusall_info = statusall_result.stdout.decode() if statusall_result.returncode == 0 else "No detailed status available"
                    
                    logger.error(f"IPSec connection failed. Detailed status: {statusall_info}")
                    
                    return False, connection_time, f"IPSec connection failed: {error_msg.strip()}. Status: {status_info}"
            
            # Wait for IPSec to establish
            time.sleep(5)
            
            # Verify IPSec is established before proceeding to L2TP
            ipsec_status = self._check_ipsec_status()
            if not ipsec_status:
                connection_time = int((time.time() - start_time) * 1000)
                status_cmd = ['ipsec', 'status']
                status_result = subprocess.run(status_cmd, capture_output=True, timeout=5)
                status_info = status_result.stdout.decode() if status_result.returncode == 0 else "No status available"
                return False, connection_time, f"IPSec tunnel not established. Status: {status_info}"
            
            logger.debug(f"IPSec established, starting L2TP for {server['name']}")
            
            # Start xl2tpd
            xl2tpd_cmd = ['xl2tpd', '-c', '/etc/xl2tpd/xl2tpd.conf', '-C', '/var/run/xl2tpd/l2tp-control']
            xl2tpd_process = subprocess.Popen(xl2tpd_cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            
            # Wait for xl2tpd to start
            time.sleep(2)
            
            # Create control directory
            os.makedirs('/var/run/xl2tpd', exist_ok=True)
            
            # Attempt L2TP connection
            try:
                # Send connect command via echo to control socket
                connect_cmd = f'echo "c vpntest" > /var/run/xl2tpd/l2tp-control'
                control_result = subprocess.run(connect_cmd, shell=True, capture_output=True, timeout=10)
                
                # Wait for connection establishment
                time.sleep(8)
                
            except Exception as e:
                logger.debug(f"L2TP connection attempt failed: {e}")
            
            # Check if connection was established
            connection_time = int((time.time() - start_time) * 1000)
            
            # Verify connection by checking interfaces or routes
            if self._verify_vpn_connection():
                return True, connection_time, None
            else:
                # Get more detailed error information
                status_cmd = ['ipsec', 'status']
                status_result = subprocess.run(status_cmd, capture_output=True, timeout=5)
                status_info = status_result.stdout.decode() if status_result.returncode == 0 else "No status available"
                
                return False, connection_time, f"VPN tunnel establishment failed. IPSec status: {status_info}"
                
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
            logger.debug(f"Ping to {ip}: {ping_result.returncode}")
            if ping_result.returncode != 0:
                logger.debug(f"Ping failed: {ping_result.stderr.decode()}")
            return ping_result.returncode == 0
        except:
            return False

    def _check_ipsec_status(self) -> bool:
        """Check if IPSec tunnel is established."""
        try:
            # Check multiple status commands for better debugging
            status_cmd = ['ipsec', 'status']
            status_result = subprocess.run(status_cmd, capture_output=True, timeout=5)
            
            statusall_cmd = ['ipsec', 'statusall']
            statusall_result = subprocess.run(statusall_cmd, capture_output=True, timeout=5)
            
            logger.debug(f"IPSec status: {status_result.stdout.decode()}")
            logger.debug(f"IPSec statusall: {statusall_result.stdout.decode()}")
            
            if status_result.returncode == 0:
                output = status_result.stdout.decode()
                # Look for established connections
                if 'ESTABLISHED' in output or 'INSTALLED' in output:
                    logger.debug("IPSec tunnel found as ESTABLISHED/INSTALLED")
                    return True
                    
            # Also check if there are any active connections
            if statusall_result.returncode == 0:
                statusall_output = statusall_result.stdout.decode()
                if 'ESTABLISHED' in statusall_output or 'INSTALLED' in statusall_output:
                    logger.debug("IPSec tunnel found in statusall")
                    return True
                    
            logger.debug("No established IPSec tunnel found")
            return False
        except Exception:
            return False

    def _verify_vpn_connection(self) -> bool:
        """Verify that VPN connection is actually established."""
        try:
            # Check strongSwan status first
            if self._check_ipsec_status():
                logger.debug("IPSec tunnel established")
            else:
                logger.debug("IPSec tunnel not established")
                return False
            
            # Check for ppp interfaces
            ip_result = subprocess.run(['ip', 'addr', 'show'], capture_output=True, timeout=5)
            if b'ppp' in ip_result.stdout:
                logger.debug("PPP interface found")
                return True
            
            # Check for VPN routes
            route_result = subprocess.run(['ip', 'route'], capture_output=True, timeout=5)
            if b'ppp' in route_result.stdout:
                logger.debug("PPP route found")
                return True
            
            # Check for active pppd processes
            pppd_check = subprocess.run(['pgrep', 'pppd'], capture_output=True, timeout=5)
            if pppd_check.returncode == 0:
                logger.debug("PPP daemon running")
                return True
                
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