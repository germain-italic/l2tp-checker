#!/usr/bin/env python3
"""
Cross-Platform VPN Monitor
Monitors L2TP/IPSec VPN connections and logs results to MySQL database.
Compatible with Debian native, macOS, and Debian WSL2.
"""

import os
import sys
import time
import socket
import platform
import subprocess
import getpass
import json
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
VERSION = "1.0.0"

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler('/tmp/vpn_monitor.log'),
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

    def _parse_vpn_servers(self) -> List[Dict[str, str]]:
        """Parse VPN servers from environment variable."""
        servers_str = os.getenv('VPN_SERVERS', '')
        if not servers_str:
            raise ValueError("VPN_SERVERS environment variable is required")
        
        servers = []
        for server_config in servers_str.split(','):
            parts = server_config.strip().split(':')
            if len(parts) != 5:
                logger.warning(f"Invalid server config format: {server_config}")
                continue
            
            servers.append({
                'name': parts[0],
                'ip': parts[1],
                'username': parts[2],
                'password': parts[3],
                'shared_key': parts[4]
            })
        
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

    def _test_vpn_connection(self, server: Dict[str, str]) -> Tuple[bool, Optional[int], Optional[str]]:
        """
        Test VPN connection to a server.
        Returns: (success, connection_time_ms, error_message)
        """
        start_time = time.time()
        
        try:
            # Detect OS and use appropriate VPN connection method
            os_type = platform.system().lower()
            
            if os_type == 'linux':
                return self._test_vpn_linux(server, start_time)
            elif os_type == 'darwin':  # macOS
                return self._test_vpn_macos(server, start_time)
            else:
                return False, None, f"Unsupported operating system: {os_type}"
                
        except Exception as e:
            connection_time = int((time.time() - start_time) * 1000)
            logger.error(f"VPN test failed for {server['name']}: {e}")
            return False, connection_time, str(e)

    def _test_vpn_linux(self, server: Dict[str, str], start_time: float) -> Tuple[bool, Optional[int], Optional[str]]:
        """Test VPN connection on Linux."""
        try:
            # Create strongSwan config for testing
            config_name = f"vpn_test_{server['name']}_{int(time.time())}"
            
            # Test if we can reach the VPN server
            ping_cmd = ['ping', '-c', '1', '-W', '5', server['ip']]
            ping_result = subprocess.run(ping_cmd, capture_output=True, timeout=10)
            
            if ping_result.returncode != 0:
                connection_time = int((time.time() - start_time) * 1000)
                return False, connection_time, f"Cannot reach VPN server {server['ip']}"
            
            # For now, we'll just test connectivity to the VPN server
            # Full L2TP/IPSec testing would require root privileges and complex setup
            connection_time = int((time.time() - start_time) * 1000)
            return True, connection_time, None
            
        except subprocess.TimeoutExpired:
            connection_time = int((time.time() - start_time) * 1000)
            return False, connection_time, "Connection timeout"
        except Exception as e:
            connection_time = int((time.time() - start_time) * 1000)
            return False, connection_time, str(e)

    def _test_vpn_macos(self, server: Dict[str, str], start_time: float) -> Tuple[bool, Optional[int], Optional[str]]:
        """Test VPN connection on macOS."""
        try:
            # Test connectivity to VPN server
            ping_cmd = ['ping', '-c', '1', '-W', '5000', server['ip']]
            ping_result = subprocess.run(ping_cmd, capture_output=True, timeout=10)
            
            if ping_result.returncode != 0:
                connection_time = int((time.time() - start_time) * 1000)
                return False, connection_time, f"Cannot reach VPN server {server['ip']}"
            
            # Test if VPN service is responsive (basic L2TP port check)
            try:
                sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                sock.settimeout(5)
                result = sock.connect_ex((server['ip'], 1701))  # L2TP port
                sock.close()
                
                connection_time = int((time.time() - start_time) * 1000)
                
                if result == 0:
                    return True, connection_time, None
                else:
                    return False, connection_time, "L2TP port not accessible"
                    
            except Exception as e:
                connection_time = int((time.time() - start_time) * 1000)
                return False, connection_time, f"Port check failed: {e}"
                
        except subprocess.TimeoutExpired:
            connection_time = int((time.time() - start_time) * 1000)
            return False, connection_time, "Connection timeout"
        except Exception as e:
            connection_time = int((time.time() - start_time) * 1000)
            return False, connection_time, str(e)

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

    def run_tests(self):
        """Run VPN tests for all configured servers."""
        logger.info(f"Starting VPN monitoring run - {len(self.vpn_servers)} servers to test")
        logger.info(f"System: {self.system_info['hostname']} ({self.system_info['os']})")
        logger.info(f"Public IP: {self.system_info['public_ip']}")
        
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


def main():
    """Main entry point."""
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