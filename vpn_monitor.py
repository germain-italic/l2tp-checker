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
import json
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
        self.cleanup_handlers = []

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
            if len(parts) < 2:
                logger.warning(f"Invalid server config format: {server_config}")
                continue
            
            server = {
                'name': parts[0],
                'ip': parts[1]
            }
            
            # Support both old format (with credentials) and new format (IP only)
            if len(parts) >= 5:
                server.update({
                    'username': parts[2],
                    'password': parts[3],
                    'shared_key': parts[4]
                })
            
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
            # Stop strongSwan connections
            subprocess.run(['ipsec', 'down', 'vpntest'], capture_output=True, timeout=10)
            subprocess.run(['ipsec', 'stop'], capture_output=True, timeout=10)
            
            # Stop xl2tpd
            subprocess.run(['killall', 'xl2tpd'], capture_output=True, timeout=5)
            
        except Exception as e:
            logger.debug(f"VPN cleanup: {e}")

    def _create_ipsec_config(self, server: Dict[str, str], config_dir: str) -> str:
        """Create IPSec configuration for strongSwan."""
        config_file = os.path.join(config_dir, 'ipsec.conf')
        secrets_file = os.path.join(config_dir, 'ipsec.secrets')
        
        # Basic IPSec configuration for L2TP/IPSec
        config_content = f"""
config setup
    charondebug="ike 2, knl 2, cfg 2, net 2, esp 2, dmn 2, mgr 2"

conn vpntest
    type=transport
    keyexchange=ikev1
    left=%defaultroute
    leftprotoport=17/1701
    right={server['ip']}
    rightprotoport=17/1701
    authby=secret
    auto=add
    ike=aes256-sha1-modp1024!
    esp=aes256-sha1!
"""
        
        with open(config_file, 'w') as f:
            f.write(config_content)
        
        # Create secrets file if credentials are available
        if 'shared_key' in server:
            secrets_content = f"{server['ip']} : PSK \"{server['shared_key']}\"\n"
            with open(secrets_file, 'w') as f:
                f.write(secrets_content)
            os.chmod(secrets_file, 0o600)
        
        return config_file

    def _create_xl2tpd_config(self, server: Dict[str, str], config_dir: str) -> str:
        """Create xl2tpd configuration."""
        config_file = os.path.join(config_dir, 'xl2tpd.conf')
        
        config_content = f"""
[global]
port = 1701

[lac vpntest]
lns = {server['ip']}
ppp debug = yes
pppoptfile = {config_dir}/options.l2tpd
length bit = yes
"""
        
        with open(config_file, 'w') as f:
            f.write(config_content)
        
        # Create PPP options file
        options_file = os.path.join(config_dir, 'options.l2tpd')
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
defaultroute
usepeerdns
debug
connect-delay 5000
"""
        
        if 'username' in server and 'password' in server:
            options_content += f"""
name {server['username']}
password {server['password']}
"""
        
        with open(options_file, 'w') as f:
            f.write(options_content)
        
        return config_file

    def _test_vpn_connection(self, server: Dict[str, str]) -> Tuple[bool, Optional[int], Optional[str]]:
        """
        Test actual VPN connection to a server.
        Returns: (success, connection_time_ms, error_message)
        """
        start_time = time.time()
        
        try:
            logger.info(f"Testing VPN connection to {server['name']} ({server['ip']})")
            
            # If no credentials, fall back to connectivity test
            if 'username' not in server or 'shared_key' not in server:
                logger.info(f"No credentials provided for {server['name']}, performing connectivity test only")
                return self._test_connectivity_only(server, start_time)
            
            # Create temporary configuration directory
            config_dir = os.path.join(self.temp_dir, f"vpn_{server['name']}_{int(time.time())}")
            os.makedirs(config_dir, exist_ok=True)
            
            # Test basic connectivity first
            if not self._test_basic_connectivity(server['ip']):
                connection_time = int((time.time() - start_time) * 1000)
                return False, connection_time, f"Cannot reach VPN server {server['ip']}"
            
            # Create VPN configurations
            ipsec_config = self._create_ipsec_config(server, config_dir)
            xl2tpd_config = self._create_xl2tpd_config(server, config_dir)
            
            # Start strongSwan with custom config
            ipsec_cmd = ['ipsec', 'start', '--config', ipsec_config]
            ipsec_result = subprocess.run(ipsec_cmd, capture_output=True, timeout=15)
            
            if ipsec_result.returncode != 0:
                connection_time = int((time.time() - start_time) * 1000)
                return False, connection_time, f"IPSec start failed: {ipsec_result.stderr.decode()}"
            
            # Load connection
            load_cmd = ['ipsec', 'up', 'vpntest']
            load_result = subprocess.run(load_cmd, capture_output=True, timeout=15)
            
            # Start xl2tpd
            xl2tpd_cmd = ['xl2tpd', '-c', xl2tpd_config, '-C', '/tmp/xl2tpd-control']
            xl2tpd_process = subprocess.Popen(xl2tpd_cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            
            # Wait a moment for services to start
            time.sleep(2)
            
            # Attempt L2TP connection
            l2tp_cmd = ['echo', 'c vpntest']
            l2tp_result = subprocess.run(l2tp_cmd, capture_output=True, timeout=10)
            
            # Check if connection was established
            connection_time = int((time.time() - start_time) * 1000)
            
            # Verify connection by checking interfaces or routes
            if self._verify_vpn_connection():
                return True, connection_time, None
            else:
                return False, connection_time, "VPN tunnel establishment failed"
                
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

    def _test_connectivity_only(self, server: Dict[str, str], start_time: float) -> Tuple[bool, Optional[int], Optional[str]]:
        """Test basic connectivity when no credentials are provided."""
        try:
            # Test basic connectivity
            if not self._test_basic_connectivity(server['ip']):
                connection_time = int((time.time() - start_time) * 1000)
                return False, connection_time, f"Cannot reach VPN server {server['ip']}"
            
            # Test L2TP port
            try:
                sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                sock.settimeout(5)
                result = sock.connect_ex((server['ip'], 1701))
                sock.close()
                
                connection_time = int((time.time() - start_time) * 1000)
                
                if result == 0:
                    return True, connection_time, "Connectivity test passed (no tunnel test)"
                else:
                    return False, connection_time, "L2TP port not accessible"
                    
            except Exception as e:
                connection_time = int((time.time() - start_time) * 1000)
                return False, connection_time, f"Port check failed: {e}"
                
        except Exception as e:
            connection_time = int((time.time() - start_time) * 1000)
            return False, connection_time, str(e)

    def _test_basic_connectivity(self, ip: str) -> bool:
        """Test basic network connectivity to IP."""
        try:
            ping_cmd = ['ping', '-c', '1', '-W', '5', ip]
            ping_result = subprocess.run(ping_cmd, capture_output=True, timeout=10)
            return ping_result.returncode == 0
        except:
            return False

    def _verify_vpn_connection(self) -> bool:
        """Verify that VPN connection is actually established."""
        try:
            # Check for ppp interfaces
            ip_result = subprocess.run(['ip', 'addr', 'show'], capture_output=True, timeout=5)
            if b'ppp' in ip_result.stdout:
                return True
            
            # Check for VPN routes
            route_result = subprocess.run(['ip', 'route'], capture_output=True, timeout=5)
            if b'ppp' in route_result.stdout:
                return True
                
            return False
            
        except Exception:
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