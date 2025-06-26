# VPN Monitor

A containerized VPN monitoring system that performs actual L2TP/IPSec VPN tunnel testing and logs results to a MySQL database. Now available in both native cross-platform and Docker-based versions.

## Version Information

### v2.0.0 (Docker-based) - Full VPN Tunnel Testing
- ✅ **Actual VPN tunnel establishment** using native Linux VPN clients (strongSwan + xl2tpd)
- ✅ **Complete L2TP/IPSec handshake** with authentication
- ✅ **Traffic routing verification** through established tunnels
- ✅ **Containerized environment** for consistent testing across platforms
- ✅ **Backward compatibility** with v1.x connectivity-only testing

### v1.0.1 (Native) - Connectivity Testing Only
- ✅ **Network connectivity** to VPN servers (ping test)
- ✅ **L2TP port accessibility** (UDP port 1701 connectivity test)
- ✅ **Cross-platform compatibility** (Linux, macOS, WSL2)
- ✅ **Lightweight installation** without VPN client dependencies

## Quick Start (Docker - Recommended)

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
   */5 * * * * cd /path/to/l2tp-checker && docker-compose up --no-deps vpn-monitor
   ```

## Quick Start (Native Installation)

For lightweight connectivity testing without Docker:

1. **Clone and setup:**
   ```bash
   git clone git@github.com:germain-italic/l2tp-checker.git
   cd l2tp-checker
   chmod +x setup.sh
   ./setup.sh
   ```

2. **Configure and test:**
   ```bash
   # Edit .env with your configuration
   nano .env
   
   # Test the monitor
   ./run_monitor.sh
   ```

## Configuration

### VPN Server Configuration

The system supports two configuration formats:

**Connectivity Testing Only (v1.x compatible):**
```bash
VPN_SERVERS=server1:vpn1.example.com,server2:192.168.1.100
```

**Full Tunnel Testing (v2.0+ Docker):**
```bash
VPN_SERVERS=server1:vpn1.example.com:username:password:shared_key,server2:vpn2.example.com:user2:pass2:key2
```

### Environment Variables (.env)

```bash
# VPN Server Configuration
# Format for connectivity testing: server_name:server_ip
# Format for full tunnel testing: server_name:server_ip:username:password:shared_key
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

## Compatibility Chart

| Platform | Version | Docker Support | Native Support | VPN Testing Level |
|----------|---------|----------------|----------------|-------------------|
| **Docker** | Any with Docker 20.10+ | ✅ **Full Tunnel** | N/A | Complete L2TP/IPSec |
| **Linux** | Ubuntu 20.04+ | ✅ **Full Tunnel** | ✅ **Connectivity** | Docker: Full / Native: Basic |
| **Linux** | Debian 11+ | ✅ **Full Tunnel** | ✅ **Connectivity** | Docker: Full / Native: Basic |
| **Linux** | CentOS/RHEL 8+ | ✅ **Full Tunnel** | ⚠️ **Connectivity** | Docker: Full / Native: Untested |
| **macOS** | 13+ (Ventura+) | ✅ **Full Tunnel** | ✅ **Connectivity** | Docker: Full / Native: Basic |
| **Windows** | WSL2 + Docker | ✅ **Full Tunnel** | ✅ **Connectivity** | Docker: Full / Native: Basic |
| **Windows** | Docker Desktop | ✅ **Full Tunnel** | ❌ | Docker: Full |

### Legend
- ✅ **Full Tunnel**: Complete VPN tunnel establishment and testing
- ✅ **Connectivity**: Basic server reachability and port testing
- ⚠️ **Untested**: Should work but not verified
- ❌ **Not Supported**: Known incompatibilities

## Features

### Docker Version (v2.0+)
- 🔒 **Full VPN tunnel testing** with native Linux VPN clients
- 🐳 **Containerized deployment** for consistent environments
- 🔐 **Complete L2TP/IPSec authentication** testing
- 🌐 **Network routing verification** through VPN tunnels
- 📊 **Advanced connection metrics** and tunnel analysis
- 🏥 **Container health monitoring** with built-in checks
- 🔧 **Automatic VPN client configuration** and cleanup

### Native Version (v1.x)
- 🌍 **Cross-platform compatibility** (Linux, macOS, WSL2)
- 🚀 **Lightweight installation** without complex dependencies
- 📡 **Basic connectivity testing** without root privileges
- 🐍 **Smart dependency management** with virtual environments

### Common Features
- 🔒 Secure credential storage via environment variables
- 📊 MySQL database logging with comprehensive metrics
- ⏰ Cron-compatible for scheduled monitoring
- 📈 Built-in reporting views for monitoring dashboards
- 🏥 Health monitoring with system information capture

## Database Schema

The system creates two main tables:

- **vpn_test_results**: Stores individual test results
- **monitor_instances**: Tracks monitoring instances

And two views for easy reporting:

- **vpn_monitoring_summary**: 24-hour success rate summary
- **recent_failures**: Recent connection failures

## Platform-Specific Notes

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

# Run one-time test
docker-compose run --rm vpn-monitor
```

### Debugging
```bash
# Access container shell
docker-compose exec vpn-monitor bash

# Check VPN tools
docker-compose exec vpn-monitor ipsec --version
docker-compose exec vpn-monitor xl2tpd --version

# Manual test run
docker-compose exec vpn-monitor python3 vpn_monitor.py

# Health check
docker-compose exec vpn-monitor python3 vpn_monitor.py --health-check
```

## Scheduling and Automation

### Docker Cron (Recommended)
```bash
# Add to host crontab
*/5 * * * * cd /path/to/l2tp-checker && docker-compose up --no-deps vpn-monitor >/dev/null 2>&1
```

### Docker Swarm/Kubernetes
The container can be deployed in orchestration platforms with appropriate scheduling configurations.

### Native Systemd (v1.x)
```bash
./install_service.sh
sudo systemctl status vpn-monitor.timer
```

## Monitoring Dashboard Queries

### Success Rate by Server (Last 24 Hours)
```sql
SELECT * FROM vpn_monitoring_summary;
```

### Recent Failures
```sql
SELECT * FROM recent_failures;
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

6. **Native Installation Issues (v1.x)**
   - See previous troubleshooting section in README
   - Consider using Docker version for full functionality

### Logs

**Docker logs:**
- Container logs: `docker-compose logs -f vpn-monitor`
- Volume logs: `/var/log/vpn-monitor/` (mounted volume)
- Health check logs: `docker-compose exec vpn-monitor python3 vpn_monitor.py --health-check`

**Native logs (v1.x):**
- Virtual environment: Check with `./run_monitor.sh`
- Systemd service: `sudo journalctl -u vpn-monitor.service -f`

### Debugging

1. **Test Docker installation:**
   ```bash
   docker-compose exec vpn-monitor python3 vpn_monitor.py --health-check
   ```

2. **Check VPN tools in container:**
   ```bash
   docker-compose exec vpn-monitor ipsec --version
   docker-compose exec vpn-monitor xl2tpd --version
   ```

3. **Verify database connection:**
   ```bash
   # From host
   mysql -h your-host -u your-user -p your-database
   
   # From container
   docker-compose exec vpn-monitor python3 -c "
   from vpn_monitor import VPNMonitor
   monitor = VPNMonitor()
   print('DB connection:', monitor.health_check())
   "
   ```

## File Structure

```
l2tp-checker/
├── Dockerfile             # Docker container definition
├── docker-compose.yml     # Docker Compose configuration
├── vpn_monitor.py         # Main monitoring script (v2.0)
├── run_monitor.sh         # Execution wrapper
├── requirements.txt        # Python dependencies
├── .env.dist             # Environment template
├── .env                  # Your configuration
├── .dockerignore         # Docker ignore file
├── .gitignore            # Git ignore file
├── setup.sh              # Native installation script (v1.x)
├── supabase/migrations/   # Database schema
└── README.md              # This file
```

## Security Considerations

- Store credentials securely in .env file (mounted, not in image)
- Limit database user permissions to only required tables
- Consider using SSL/TLS for database connections
- Regularly rotate VPN and database passwords
- Container isolation provides security boundaries
- VPN configurations are temporary and cleaned up after tests
- Use Docker secrets for production deployments

## Migration from v1.x

To upgrade from native installation to Docker:

1. **Backup your configuration:**
   ```bash
   cp .env .env.backup
   ```

2. **Update VPN server format** (if using full tunnel testing):
   ```bash
   # Old format (v1.x): server_name:server_ip
   # New format (v2.0): server_name:server_ip:username:password:shared_key
   ```

3. **Switch to Docker:**
   ```bash
   docker-compose up --build
   ```

4. **Update scheduling:**
   ```bash
   # Replace systemd service with Docker cron
   sudo systemctl disable vpn-monitor.timer
   # Add Docker cron job as shown above
   ```

## Contributing

Help us improve the VPN monitor:

1. **Test on new platforms** and report compatibility
2. **Add support for new VPN protocols** (OpenVPN, WireGuard)
3. **Improve error handling** and logging
4. **Add monitoring dashboards** and alerting
5. **Optimize container size** and performance

## License

MIT License - See LICENSE file for details