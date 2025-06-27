# VPN Monitor

A containerized VPN monitoring system that performs actual L2TP/IPSec VPN tunnel testing and logs results to a MySQL database.

## Features

- 🔒 **Full VPN tunnel testing** with native Linux VPN clients (strongSwan + xl2tpd)
- 🐳 **Containerized deployment** for consistent testing environments
- 🔐 **Complete L2TP/IPSec authentication** with username/password/shared key
- 🌐 **Network routing verification** through established VPN tunnels
- 📊 **MySQL database logging** with comprehensive metrics
- 🏥 **Container health monitoring** with built-in checks
- 🔧 **Automatic VPN client configuration** and cleanup

## Quick Start

1. **Clone and configure:**
   ```bash
   git clone git@github.com:germain-italic/l2tp-checker.git
   cd l2tp-checker
   cp .env.dist .env
   # Edit .env with your VPN servers and database credentials
   nano .env
   ```

2. **Setup database:**
   ```bash
   mysql -u your_username -p your_database < supabase/migrations/20250626084019_yellow_canyon.sql
   ```

3. **Run with Docker:**
   ```bash
   # Build and run
   docker-compose up --build
   
   # Run in background
   docker-compose up -d
   
   # View logs
   docker-compose logs -f vpn-monitor
   ```

4. **Schedule monitoring:**
   ```bash
   # Add to crontab for periodic testing
   */5 * * * * cd /path/to/l2tp-checker && docker-compose up --no-deps vpn-monitor >/dev/null 2>&1
   ```

## Configuration

### VPN Server Configuration

Configure your VPN servers in the `.env` file:

```bash
VPN_SERVERS=server1:vpn1.example.com:username:password:shared_key,server2:vpn2.example.com:user2:pass2:key2
```

### Environment Variables (.env)

```bash
# VPN Server Configuration
# Format: server_name:server_ip:username:password:shared_key
VPN_SERVERS=server1:vpn1.example.com:myuser:mypass:sharedsecret

# MySQL Database Configuration
DB_HOST=your-mysql-host.com
DB_PORT=3306
DB_NAME=vpn_monitoring
DB_USER=your_db_username
DB_PASSWORD=your_db_password

# Optional Configuration
VPN_TIMEOUT=30
MONITOR_ID=docker-monitor-01
```

## Docker Architecture

### Container Features
- **Base Image**: `debian:bookworm-slim` for optimal compatibility
- **VPN Clients**: strongSwan (IPSec) + xl2tpd (L2TP)
- **Privileges**: Runs with `NET_ADMIN` capabilities for VPN operations
- **Networking**: Uses host networking for direct VPN access
- **Persistence**: Logs stored in Docker volumes
- **Health Checks**: Built-in container health monitoring

### Security Considerations
- Container requires privileged mode for VPN operations
- Credentials stored in mounted `.env` file (not in image)
- Temporary VPN configurations cleaned up after each test
- Network isolation through Docker networking

## Platform Support

| Platform | Docker Support | VPN Testing Level |
|----------|----------------|-------------------|
| **Linux** | ✅ **Full Tunnel** | Complete L2TP/IPSec |
| **macOS** | ✅ **Full Tunnel** | Complete L2TP/IPSec |
| **Windows** | ✅ **Full Tunnel** | Complete L2TP/IPSec |

## Database Schema

The system creates two main tables:

- **vpn_test_results**: Stores individual test results
- **monitor_instances**: Tracks monitoring instances

And two views for easy reporting:

- **vpn_monitoring_summary**: 24-hour success rate summary
- **recent_failures**: Recent connection failures

## Docker Commands

### Basic Operations
```bash
# Build and run
docker-compose up --build

# Run in background
docker-compose up -d

# View logs
docker-compose logs -f vpn-monitor

# Stop container
docker-compose down

# Rebuild after changes
docker-compose build --no-cache

# Quick rebuild (uses cache)
docker-compose build

# Run one-time test
docker-compose run --rm vpn-monitor
```

### Debugging
```bash
# IMPORTANT: Stop the monitor first to avoid VPN resource conflicts
docker-compose down

# Run Synology-specific debug script
docker-compose run --rm vpn-monitor /app/synology_debug.sh

# Access container shell for manual debugging
docker-compose run --rm vpn-monitor bash

# After debugging, restart the monitor
docker-compose up -d

# Check VPN tools are available
docker-compose run --rm vpn-monitor ipsec --version
docker-compose run --rm vpn-monitor xl2tpd --version

# Manual test run
docker-compose run --rm vpn-monitor python3 /app/vpn_monitor.py

# Health check
docker-compose run --rm vpn-monitor python3 /app/vpn_monitor.py --health-check

# View real-time logs
docker-compose logs -f vpn-monitor

# View recent logs (last 50 lines)
docker-compose logs --tail=50 vpn-monitor
```

**CRITICAL:** Debug scripts require exclusive access to VPN resources. Always stop the running monitor before debugging:

```bash
# Wrong way (will fail due to resource conflicts):
docker-compose up -d
docker-compose exec vpn-monitor /app/synology_debug.sh  # ❌ FAILS

# Correct way (clean isolation):
docker-compose down
docker-compose run --rm vpn-monitor /app/synology_debug.sh  # ✅ WORKS
```

## Scheduling and Automation

### Docker Cron (Recommended)
```bash
# Add to host crontab
*/5 * * * * cd /path/to/l2tp-checker && docker-compose up --no-deps vpn-monitor >/dev/null 2>&1
```

### Docker Swarm/Kubernetes
The container can be deployed in orchestration platforms with appropriate scheduling configurations.

## Monitoring Dashboard Queries

### Success Rate by Server (Last 24 Hours)
```sql
SELECT * FROM vpn_monitoring_summary;
```

```
+-----------------+----------------+-------------+------------------+----------------------+------------------------+---------------------+-----------------+
| vpn_server_name | vpn_server_ip  | total_tests | successful_tests | success_rate_percent | avg_connection_time_ms | last_test_time      | unique_monitors |
+-----------------+----------------+-------------+------------------+----------------------+------------------------+---------------------+-----------------+
| myvpn02         | vpn2.hostname  |          27 |                1 |                 3.70 |               491.0000 | 2025-06-26 21:37:29 |               2 |
| myvpn01         | vpn1.hostname  |         183 |                6 |                 3.28 |             20547.6667 | 2025-06-27 00:51:44 |               3 |
+-----------------+----------------+-------------+------------------+----------------------+------------------------+---------------------+-----------------+
```

### Recent Failures
```sql
SELECT * FROM recent_failures;
```

```
+---------------------+-----------------------+-----------------+----------------+----------------------------------------------------+-------------------+
| test_timestamp      | computer_identifier   | vpn_server_name | vpn_server_ip  | error_message_short                                | public_ip_address |
+---------------------+-----------------------+-----------------+----------------+----------------------------------------------------+-------------------+
| 2025-06-27 00:50:20 | germain-debian12-wsl2 | myvpn01         | vpn1.hostname  | Failed to load IPSec configuration                 | 54.112.218.172    |
| 2025-06-27 00:47:45 | germain-debian12-wsl2 | myvpn01         | vpn1.hostname  | Failed to load IPSec configuration                 | 54.112.218.172    |
| 2025-06-27 00:46:35 | germain-debian12-wsl2 | myvpn01         | vpn1.hostname  | Connection failed. Technical details: No status... | 54.112.218.172    |
| 2025-06-27 00:44:08 | germain-debian12-wsl2 | myvpn01         | vpn1.hostname  | Failed to load IPSec configuration                 | 54.112.218.172    |
| 2025-06-27 00:42:27 | germain-debian12-wsl2 | myvpn01         | vpn1.hostname  | Failed to load IPSec configuration                 | 54.112.218.172    |
| 2025-06-27 00:40:09 | germain-debian12-wsl2 | myvpn01         | vpn1.hostname  | Failed to load IPSec configuration                 | 54.112.218.172    |
| 2025-06-27 00:38:46 | germain-debian12-wsl2 | myvpn01         | vpn1.hostname  | Failed to start strongSwan daemon                  | 54.112.218.172    |
| 2025-06-27 00:37:05 | germain-debian12-wsl2 | myvpn01         | vpn1.hostname  | Failed to load IPSec configuration                 | 54.112.218.172    |
| 2025-06-27 00:34:13 | germain-debian12-wsl2 | myvpn01         | vpn1.hostname  | Failed to load IPSec configuration                 | 54.112.218.172    |
| 2025-06-27 00:30:52 | germain-debian12-wsl2 | myvpn01         | vpn1.hostname  | Cannot reach VPN server vpn1.hostname              | 54.112.218.172    |
| 2025-06-27 00:26:13 | germain-debian12-wsl2 | myvpn01         | vpn1.hostname  | Failed to load IPSec configuration                 | 54.112.218.172    |
| 2025-06-27 00:25:26 | germain-debian12-wsl2 | myvpn01         | vpn1.hostname  | Failed to load IPSec configuration                 | 54.112.218.172    |
| 2025-06-27 00:22:59 | germain-debian12-wsl2 | myvpn01         | vpn1.hostname  | Failed to load IPSec configuration                 | 54.112.218.172    |
| 2025-06-27 00:20:45 | germain-debian12-wsl2 | myvpn01         | vpn1.hostname  | VPN connection timeout                             | 54.112.218.172    |
| 2025-06-27 00:18:23 | germain-debian12-wsl2 | myvpn01         | vpn1.hostname  | IPSec auto-start failed after 15s. Connection f... | 54.112.218.172    |
| 2025-06-27 00:16:06 | germain-debian12-wsl2 | myvpn01         | vpn1.hostname  | VPN tunnel establishment failed. IPSec status: ... | 54.112.218.172    |
| 2025-06-27 00:13:25 | germain-debian12-wsl2 | myvpn01         | vpn1.hostname  | IPSec tunnel not established after 20s. Server ... | 54.112.218.172    |
| 2025-06-27 00:08:55 | germain-debian12-wsl2 | myvpn01         | vpn1.hostname  | VPN tunnel establishment failed. IPSec status: ... | 54.112.218.172    |
| 2025-06-27 00:06:55 | germain-debian12-wsl2 | myvpn01         | vpn1.hostname  | VPN tunnel establishment failed. IPSec status: ... | 54.112.218.172    |
| 2025-06-27 00:05:53 | germain-debian12-wsl2 | myvpn01         | vpn1.hostname  | IPSec tunnel not established after 15s. Error: ... | 54.112.218.172    |
+---------------------+-----------------------+-----------------+----------------+----------------------------------------------------+-------------------+
```


### Monitor Health Check
```sql
SELECT 
    computer_identifier,
    system_username,
    operating_system,
    last_seen,
    total_tests_run,
    CASE 
        WHEN last_seen > DATE_SUB(NOW(), INTERVAL 10 MINUTE) THEN 'HEALTHY'
        WHEN last_seen > DATE_SUB(NOW(), INTERVAL 30 MINUTE) THEN 'WARNING'
        ELSE 'CRITICAL'
    END as health_status
FROM monitor_instances
ORDER BY last_seen DESC;
```

```
+-----------------------+-----------------+------------------------------------------+---------------------+-----------------+---------------+
| computer_identifier   | system_username | operating_system                         | last_seen           | total_tests_run | health_status |
+-----------------------+-----------------+------------------------------------------+---------------------+-----------------+---------------+
| germain-debian12-wsl2 | germain         | Linux 5.15.167.4-microsoft-standard-WSL2 | 2025-06-27 00:51:44 |             106 | WARNING       |
| germain-debian12-wsl2 | root            | Linux 5.15.167.4-microsoft-standard-WSL2 | 2025-06-26 21:56:05 |             102 | CRITICAL      |
| germain-linuxlite7.4  | germain         | Linux 6.8.0-62-generic                   | 2025-06-26 20:23:41 |               2 | CRITICAL      |
+-----------------------+-----------------+------------------------------------------+---------------------+-----------------+---------------+
```

## Troubleshooting

### Common Issues

1. **Docker Permission Issues**
   ```
   permission denied while trying to connect to the Docker daemon socket
   ```
   - **Solution**: Add user to docker group: `sudo usermod -aG docker $USER`
   - Or run with sudo: `sudo docker-compose up`

2. **Container Fails to Start**
   ```
   Error response from daemon: failed to create shim task
   ```
   - **Solution**: Check Docker daemon is running: `sudo systemctl start docker`
   - Verify Docker version compatibility

3. **Database Connection Failed**
   - Verify database credentials in .env
   - Ensure MySQL server is accessible
   - Check firewall settings
   - For Docker: Ensure network connectivity between containers

4. **VPN Connection Fails**
   - Verify VPN server addresses are correct
   - Check VPN credentials (username, password, shared key)
   - Ensure container has proper network privileges
   - Check VPN server supports L2TP/IPSec

5. **Container Health Check Fails**
   - Check container logs: `docker-compose logs vpn-monitor`
   - Verify database connectivity from container
   - Ensure VPN tools are properly installed

### Synology NAS Compatibility

**Synology DSM7 L2TP/IPSec servers:**
- If you cannot enable "SHA2-256 compatible mode" due to Windows/macOS client compatibility
- The monitor automatically uses legacy encryption (3DES/MD5) for maximum compatibility
- This configuration works with Windows 11 and macOS built-in VPN clients
- Check Synology VPN Server logs in Log Center for connection attempts
- Ensure UDP ports 500, 4500, 1701 are allowed in Synology firewall

**Debug Synology server logs:**
```bash
# SSH to your Synology NAS and monitor authentication logs in real-time
tail -f /var/log/auth.log
```
This will show live VPN connection attempts and authentication failures on the Synology server side.

### Debugging Steps

1. **Run the debug script for detailed analysis:**
   ```bash
   docker-compose down
   docker-compose run --rm vpn-monitor /app/synology_debug.sh
   ```

2. **Check VPN tools in container:**
   ```bash
   docker-compose run --rm vpn-monitor ipsec --version
   docker-compose run --rm vpn-monitor xl2tpd --version
   ```

3. **Verify database connection:**
   ```bash
   # From host
   mysql -h your-host -u your-user -p your-database
   
   # From container
   docker-compose run --rm vpn-monitor python3 -c "
   from vpn_monitor import VPNMonitor
   monitor = VPNMonitor()
   print('DB connection:', monitor.health_check())
   "
   ```

4. **Test Docker installation:**
   ```bash
   docker-compose run --rm vpn-monitor python3 /app/vpn_monitor.py --health-check
   ```

### Logs

**Docker logs:**
- Container logs: `docker-compose logs -f vpn-monitor`
- Volume logs: `/var/log/vpn-monitor/` (mounted volume)
- Health check logs: `docker-compose run --rm vpn-monitor python3 /app/vpn_monitor.py --health-check`

## File Structure

```
l2tp-checker/
├── Dockerfile                 # Docker container definition
├── docker-compose.yml         # Docker Compose configuration
├── vpn_monitor.py             # Main monitoring script
├── run_monitor.sh             # Container execution wrapper
├── synology_debug.sh          # Synology-specific debugging script
├── requirements.txt           # Python dependencies
├── .env.dist                  # Environment template
├── .env                       # Your configuration (create from .env.dist)
├── supabase/migrations/       # Database schema
│   └── 20250626084019_yellow_canyon.sql
├── LICENSE                    # MIT License
└── README.md                  # This file
```

## Security Considerations

- Store credentials securely in .env file (mounted, not in image)
- Limit database user permissions to only required tables
- Consider using SSL/TLS for database connections
- Regularly rotate VPN and database passwords
- Container isolation provides security boundaries
- VPN configurations are temporary and cleaned up after tests
- Use Docker secrets for production deployments

## Contributing

Help us improve the VPN monitor:

1. **Test on new platforms** and report compatibility
2. **Add support for new VPN protocols** (OpenVPN, WireGuard)
3. **Improve error handling** and logging
4. **Add monitoring dashboards** and alerting
5. **Optimize container size** and performance

## License

MIT License - See LICENSE file for details