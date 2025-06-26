# VPN Monitor

A cross-platform VPN monitoring system that tests L2TP/IPSec VPN connections and logs results to a MySQL database. Compatible with Debian native, macOS, and Debian WSL2.

## Features

- 🌍 Cross-platform compatibility (Linux, macOS, WSL2)
- 🔒 Secure credential storage via environment variables
- 📊 MySQL database logging with comprehensive metrics
- ⏰ Cron-compatible for scheduled monitoring
- 🏥 Health monitoring with system information capture
- 📈 Built-in reporting views for monitoring dashboards

## Quick Start

1. **Clone and setup:**
   ```bash
   git clone <repository-url>
   cd vpn-monitor
   chmod +x setup.sh
   ./setup.sh
   ```

2. **Configure environment:**
   ```bash
   cp .env.dist .env
   # Edit .env with your VPN servers and database credentials
   nano .env
   ```

3. **Setup database:**
   ```bash
   mysql -u your_username -p your_database < database.sql
   ```

4. **Test the monitor:**
   ```bash
   python3 vpn_monitor.py
   ```

5. **Add to crontab for every 5 minutes:**
   ```bash
   crontab -e
   # Add this line:
   */5 * * * * cd /path/to/vpn-monitor && python3 vpn_monitor.py >/dev/null 2>&1
   ```

## Configuration

### Environment Variables (.env)

```bash
# VPN Server Configuration
# Format: server_name:server_ip:username:password:shared_key
VPN_SERVERS=server1:vpn1.example.com:user1:pass1:sharedkey1,server2:vpn2.example.com:user2:pass2:sharedkey2

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

Each VPN server entry should follow this format:
```
server_name:server_ip:username:password:shared_key
```

Multiple servers are separated by commas.

## Database Schema

The system creates two main tables:

- **vpn_test_results**: Stores individual test results
- **monitor_instances**: Tracks monitoring instances

And two views for easy reporting:

- **vpn_monitoring_summary**: 24-hour success rate summary
- **recent_failures**: Recent connection failures

## Platform-Specific Notes

### Linux (Debian/Ubuntu)
- Requires `ping` command (usually pre-installed)
- Works with both native and WSL2 installations

### macOS
- Uses built-in networking tools
- May require Xcode command line tools

### Dependencies

- Python 3.6+
- PyMySQL
- python-dotenv
- requests

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

1. **Database Connection Failed**
   - Verify database credentials in .env
   - Ensure MySQL server is accessible
   - Check firewall settings

2. **VPN Tests Always Fail**
   - Verify VPN server addresses are correct
   - Check network connectivity
   - Ensure VPN servers are running

3. **Permission Denied Errors**
   - Make sure the script is executable: `chmod +x vpn_monitor.py`
   - Check log file permissions in /tmp/

### Logs

Monitor logs are written to:
- `/tmp/vpn_monitor.log` (or `~/vpn-monitor-logs/` if /tmp is not writable)
- Standard output when run manually

## Security Considerations

- Store credentials securely in .env file
- Limit database user permissions to only required tables
- Consider using SSL/TLS for database connections
- Regularly rotate VPN and database passwords

## License

MIT License - See LICENSE file for details