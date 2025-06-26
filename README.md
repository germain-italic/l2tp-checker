# VPN Monitor

A cross-platform VPN monitoring system that tests VPN server connectivity and logs results to a MySQL database. Compatible with Debian native, macOS, and Debian WSL2.

## Important Note About VPN Testing

**Current Version (v1.0.1)**: This version tests VPN server **connectivity only** - it verifies that the VPN server is reachable and responding on the L2TP port (1701), but does **not** establish an actual VPN tunnel or test the full L2TP/IPSec connection.

### What is Actually Tested:
- ✅ **Network connectivity** to the VPN server IP address (ping test)
- ✅ **L2TP port accessibility** (UDP port 1701 connectivity test)
- ✅ **Response time** measurement for connectivity tests
- ✅ **Server availability** monitoring over time

### What is NOT Tested:
- ❌ **Actual VPN tunnel establishment** (no L2TP/IPSec handshake)
- ❌ **Authentication** with VPN credentials
- ❌ **Traffic routing** through the VPN tunnel
- ❌ **IP address changes** after VPN connection
- ❌ **End-to-end encrypted connectivity**

This approach allows for lightweight monitoring without requiring root privileges, complex VPN client installations, or credential management. Future versions may include full tunnel testing capabilities.

## Compatibility Chart

| Operating System | Version | Status | Installation Method | Notes |
|------------------|---------|--------|-------------------|-------|
| **Linux Lite** | 7.4 (Ubuntu 24.04 LTS) | ✅ **Tested** | Virtual Environment | Automatic dependency resolution |
| **Ubuntu** | 24.04 LTS (Noble) | ✅ **Supported** | Virtual Environment | Modern externally-managed Python |
| **Ubuntu** | 22.04 LTS (Jammy) | ✅ **Supported** | Virtual Environment | Standard installation |
| **Ubuntu** | 20.04 LTS (Focal) | ✅ **Supported** | Global/Virtual Environment | Legacy Python support |
| **Debian** | 12 (Bookworm) | ✅ **Supported** | Virtual Environment | Modern Debian |
| **Debian** | 11 (Bullseye) | ✅ **Supported** | Virtual Environment | Standard installation |
| **Debian WSL2** | Any | ✅ **Supported** | Virtual Environment | Windows Subsystem for Linux |
| **macOS** | 13+ (Ventura+) | ✅ **Supported** | Homebrew/System | Requires Xcode CLI tools |
| **macOS** | 12 (Monterey) | ⚠️ **Likely** | Homebrew/System | May need manual setup |
| **CentOS/RHEL** | 8+ | ⚠️ **Untested** | DNF/YUM | Should work with dnf |
| **Fedora** | 35+ | ⚠️ **Untested** | DNF | Should work with dnf |
| **Arch Linux** | Rolling | ⚠️ **Untested** | Manual | Requires manual package installation |

### Legend
- ✅ **Tested**: Confirmed working by users
- ✅ **Supported**: Should work based on system compatibility
- ⚠️ **Likely**: Expected to work but not tested
- ⚠️ **Untested**: Not tested, may require manual configuration
- ❌ **Not Supported**: Known incompatibilities

*Help us expand this chart! Test on your system and report results.*

## Features

- 🌍 Cross-platform compatibility (Linux, macOS, WSL2)
- 🔒 Secure credential storage via environment variables
- 📊 MySQL database logging with comprehensive metrics
- ⏰ Cron-compatible for scheduled monitoring
- 🏥 Health monitoring with system information capture
- 📈 Built-in reporting views for monitoring dashboards
- 🐍 Smart dependency management with virtual environments
- 🔧 Automatic system package installation
- 📝 Easy wrapper scripts for execution

## Quick Start

1. **Clone and setup:**
   ```bash
   git clone git@github.com:germain-italic/l2tp-checker.git
   cd l2tp-checker
   chmod +x setup.sh
   ./setup.sh
   ```

2. **Configure environment:**
   ```bash
   cp .env.dist .env  # (Done automatically by setup.sh)
   # Edit .env with your VPN servers and database credentials
   nano .env
   ```

3. **Setup database:**
   ```bash
   mysql -u your_username -p your_database < supabase/migrations/20250626084019_yellow_canyon.sql
   ```

4. **Test the monitor:**
   ```bash
   # Modern systems (virtual environment):
   ./run_monitor.sh
   
   # Legacy systems (global installation):
   python3 vpn_monitor.py
   ```

5. **Setup automatic monitoring:**
   
   **Option A - Systemd Service (Recommended):**
   ```bash
   ./install_service.sh
   # Check status: sudo systemctl status vpn-monitor.timer
   # View logs: sudo journalctl -u vpn-monitor.service -f
   ```
   
   **Option B - Crontab (Traditional):**
   ```bash
   crontab -e
   # Add this line (adjust path as needed):
   */5 * * * * cd /home/user/l2tp-checker && ./run_monitor.sh >/dev/null 2>&1
   ```

## Installation Methods

The setup script automatically detects your system and chooses the best installation method:

### Virtual Environment (Recommended)
- **Used on**: Modern Debian/Ubuntu (24.04+), systems with externally-managed Python
- **Benefits**: Isolated dependencies, no system conflicts
- **Execution**: Use `./run_monitor.sh`

### Global Installation
- **Used on**: Older systems, systems without pip restrictions
- **Benefits**: Simple, direct execution
- **Execution**: Use `python3 vpn_monitor.py`

### User Installation
- **Used on**: Systems without sudo access, fallback method
- **Benefits**: No root required
- **Execution**: Use `./run_monitor.sh` or ensure `~/.local/bin` is in PATH

## Configuration

### Environment Variables (.env)

```bash
# VPN Server Configuration  
# Format: server_name:server_ip
# Note: Only server name and IP are needed for connectivity testing
VPN_SERVERS=server1:vpn1.example.com,server2:vpn2.example.com,server3:192.168.1.100

# MySQL Database Configuration
DB_HOST=your-mysql-host.com
DB_PORT=3306
DB_NAME=vpn_monitoring
DB_USER=your_db_username
DB_PASSWORD=your_db_password

# Optional Configuration
VPN_TIMEOUT=30
MONITOR_ID=custom-identifier
```

### VPN Server Format

Each VPN server entry should follow this simplified format for connectivity testing:
```
server_name:server_ip
```

Multiple servers are separated by commas. Examples:
- `office-vpn:vpn.company.com`
- `home-server:192.168.1.100`
- `backup-vpn:backup.example.org`

## Database Schema

The system creates two main tables:

- **vpn_test_results**: Stores individual test results
- **monitor_instances**: Tracks monitoring instances

And two views for easy reporting:

- **vpn_monitoring_summary**: 24-hour success rate summary
- **recent_failures**: Recent connection failures

## Platform-Specific Notes

### Linux (Debian/Ubuntu)
- **Modern systems (24.04+)**: Uses virtual environment automatically
- **Legacy systems**: May use global installation
- **WSL2**: Fully supported with virtual environment
- **Dependencies**: Automatically installs `python3-venv`, `python3-pip`

### macOS
- Uses built-in networking tools
- May require Xcode command line tools: `xcode-select --install`
- Homebrew recommended for package management

### Dependencies

**Core Requirements:**
- Python 3.6+
- python3-venv (automatically installed on Linux)
- python3-pip (automatically installed on Linux)

**Python Packages (automatically installed):**
- PyMySQL
- python-dotenv
- requests
- cryptography

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

1. **Externally Managed Environment Error**
   ```
   error: externally-managed-environment
   ```
   - **Solution**: This is normal on modern Debian/Ubuntu systems
   - The setup script automatically creates a virtual environment
   - Use `./run_monitor.sh` instead of `python3 vpn_monitor.py`

2. **Virtual Environment Creation Failed**
   ```
   The virtual environment was not created successfully because ensurepip is not available
   ```
   - **Solution**: Run `sudo apt install python3-venv python3-pip`
   - Or let the setup script handle it automatically

3. **Database Connection Failed**
   - Verify database credentials in .env
   - Ensure MySQL server is accessible
   - Check firewall settings

4. **VPN Tests Always Fail**
   - Verify VPN server addresses are correct
   - Check network connectivity
   - Ensure VPN servers are running and L2TP service is active
   - Remember: This version only tests connectivity, not full VPN functionality

5. **Permission Denied Errors**
   - Make sure scripts are executable: `chmod +x *.sh`
   - Check log file permissions

6. **Missing Dependencies**
   - Re-run setup script: `./setup.sh`
   - For manual installation: `pip install -r requirements.txt`

### Logs

Monitor logs are written to:
- **Virtual environment**: Check with `./run_monitor.sh`
- **Global installation**: `/tmp/vpn_monitor.log`
- **Systemd service**: `sudo journalctl -u vpn-monitor.service -f`
- **User logs**: `~/vpn-monitor-logs/` (if /tmp is not writable)

### Debugging

1. **Test installation:**
   ```bash
   ./run_monitor.sh --help
   ```

2. **Check virtual environment:**
   ```bash
   source venv/bin/activate  # If using venv
   python --version
   pip list
   ```

3. **Verify database connection:**
   ```bash
   mysql -h your-host -u your-user -p your-database
   ```

## File Structure

```
l2tp-checker/
├── vpn_monitor.py          # Main monitoring script
├── setup.sh               # Automated setup script
├── run_monitor.sh          # Execution wrapper (created by setup)
├── install_service.sh      # Systemd service installer (created by setup)
├── requirements.txt        # Python dependencies
├── .env.dist              # Environment template
├── .env                   # Your configuration (created by setup)
├── venv/                  # Virtual environment (created by setup)
├── supabase/migrations/   # Database schema
└── README.md              # This file
```

## Security Considerations

- Store credentials securely in .env file
- Limit database user permissions to only required tables
- Consider using SSL/TLS for database connections
- Regularly rotate VPN and database passwords
- Virtual environment isolates dependencies from system

## Contributing

Help us improve compatibility! If you test on a new system:

1. Note your OS and version
2. Run `./setup.sh` and document any issues
3. Test `./run_monitor.sh`
4. Report results by updating the compatibility chart

## License

MIT License - See LICENSE file for details