# VPN Monitor v2.0.0 🚀

A major release featuring enhanced Synology NAS compatibility, improved connection reliability, and comprehensive Docker-based VPN monitoring.

## 🎯 What's New in v2.0.0

### 🔧 Enhanced Synology NAS Support
- **Optimized L2TP/IPSec configuration** specifically for Synology DSM7 servers
- **Legacy encryption support** (3DES/SHA1) for maximum client compatibility when SHA2-256 mode is disabled
- **Improved authentication flow** with proper peer ID handling to avoid format conflicts
- **Real-time server log monitoring** - Added command to monitor Synology auth logs: `tail -f /var/log/auth.log`

### 🚀 Improved Connection Reliability
- **Auto-start connection mode** - Connections now establish automatically using `auto=start`
- **Extended connection timeout** - Increased wait time to 20 seconds for better success rates
- **Robust connection verification** - Multiple checks for ESTABLISHED, CONNECTING states
- **Enhanced cleanup procedures** - Proper VPN resource management between tests

### 🐳 Docker Architecture Improvements
- **Optimized container startup** - Better charon daemon management with fallback mechanisms
- **Resource conflict prevention** - Clear separation between monitoring and debugging operations
- **Improved logging** - Comprehensive debug output with truncated messages for readability
- **Health check enhancements** - Better container health monitoring and status reporting

### 📊 Database & Monitoring Enhancements
- **Comprehensive error logging** - Detailed error messages with technical context
- **Performance metrics** - Connection time tracking in milliseconds
- **Monitor instance tracking** - Multi-instance monitoring support with unique identifiers
- **Real-time status views** - Pre-built SQL views for easy dashboard creation

## 🔑 Key Features

### 🔒 Complete VPN Testing
- **Native Linux VPN clients** (strongSwan + xl2tpd)
- **Full tunnel establishment** with L2TP/IPSec authentication
- **Network routing verification** through established VPN tunnels
- **Cross-platform Docker support** (Linux, macOS, Windows)

### 📈 Production-Ready Monitoring
- **MySQL database logging** with comprehensive metrics
- **Container health checks** for orchestration platforms
- **Cron scheduling support** for automated monitoring
- **Multi-server configuration** via environment variables

### 🛠 Advanced Debugging
- **Synology-specific debug script** with detailed compatibility testing
- **Packet capture analysis** for connection troubleshooting
- **Multiple encryption algorithm testing** (AES-256, 3DES, various modes)
- **Real-time log monitoring** with container isolation

## 🚀 Quick Start

```bash
# Clone and setup
git clone https://github.com/germain-italic/l2tp-checker.git
cd l2tp-checker
cp .env.dist .env

# Configure your VPN servers and database
nano .env

# Setup database schema
mysql -u username -p database < supabase/migrations/20250626084019_yellow_canyon.sql

# Run monitoring
docker-compose up --build

# Schedule periodic monitoring
echo "*/5 * * * * cd /path/to/l2tp-checker && docker-compose up --no-deps vpn-monitor >/dev/null 2>&1" | crontab -
```

## 🔧 Configuration Example

```bash
# VPN Server Configuration (supports multiple servers)
VPN_SERVERS=server1:nas1.domain.com:username:password:shared_key,server2:nas2.domain.com:user2:pass2:key2

# MySQL Database Configuration
DB_HOST=mysql.domain.com
DB_PORT=3306
DB_NAME=vpn_monitoring
DB_USER=vpn_monitor_user
DB_PASSWORD=secure_password

# Optional Settings
VPN_TIMEOUT=30
MONITOR_ID=production-monitor-01
```

## 📊 Monitoring Dashboard

### Success Rate Summary
```sql
SELECT * FROM vpn_monitoring_summary;
```

### Recent Failures Analysis
```sql
SELECT 
    test_timestamp,
    vpn_server_name,
    LEFT(error_message, 50) as error_short,
    public_ip_address
FROM recent_failures
ORDER BY test_timestamp DESC;
```

### Monitor Health Status
```sql
SELECT 
    computer_identifier,
    CASE 
        WHEN last_seen > DATE_SUB(NOW(), INTERVAL 10 MINUTE) THEN 'HEALTHY'
        WHEN last_seen > DATE_SUB(NOW(), INTERVAL 30 MINUTE) THEN 'WARNING'
        ELSE 'CRITICAL'
    END as health_status,
    total_tests_run
FROM monitor_instances
ORDER BY last_seen DESC;
```

## 🛠 Debugging & Troubleshooting

### Synology NAS Debugging
```bash
# Stop monitor first to avoid resource conflicts
docker-compose down

# Run comprehensive debug script
docker-compose run --rm vpn-monitor /app/synology_debug.sh

# Monitor server logs (SSH to Synology NAS)
tail -f /var/log/auth.log
```

### Container Operations
```bash
# View real-time logs
docker-compose logs -f vpn-monitor

# Health check
docker-compose run --rm vpn-monitor python3 /app/vpn_monitor.py --health-check

# Manual test run
docker-compose run --rm vpn-monitor

# Access container shell
docker-compose run --rm vpn-monitor bash
```

## 🔐 Security & Platform Support

### Platform Compatibility
| Platform | Support Level | Notes |
|----------|---------------|-------|
| **Linux** | ✅ Native | Full tunnel testing |
| **macOS** | ✅ Docker | Complete L2TP/IPSec |
| **Windows** | ✅ Docker | WSL2 recommended |

### Security Features
- 🔐 Credentials stored in mounted `.env` file (never in image)
- 🧹 Temporary VPN configurations auto-cleanup
- 🛡️ Container isolation with minimal required privileges
- 🔄 Regular credential rotation support

## 📁 Project Structure

```
l2tp-checker/
├── 🐳 docker-compose.yml         # Container orchestration
├── 📦 Dockerfile                 # Multi-stage optimized build
├── 🐍 vpn_monitor.py             # Core monitoring engine
├── 🔧 synology_debug.sh          # Comprehensive debug script
├── ⚙️ run_monitor.sh             # Container execution wrapper
├── 📋 requirements.txt           # Python dependencies
├── 🗄️ supabase/migrations/       # Database schema
├── 📄 .env.dist                  # Configuration template
└── 📖 README.md                  # Comprehensive documentation
```

## 🚀 What's Next

- **OpenVPN support** - Additional VPN protocol testing
- **WireGuard integration** - Modern VPN protocol support  
- **Web dashboard** - Real-time monitoring interface
- **Alerting system** - Email/Slack notifications for failures
- **Performance optimization** - Faster container startup and testing

## 🤝 Contributing

We welcome contributions! Areas for improvement:
- 🧪 **Testing on new platforms** and VPN servers
- 🔌 **Additional VPN protocol support**
- 📊 **Monitoring dashboard development**
- 🚨 **Alerting and notification systems**
- ⚡ **Performance optimizations**

## 📜 License

MIT License - See [LICENSE](LICENSE) file for details.

---

**Full Changelog**: Compare changes from previous versions on [GitHub](https://github.com/germain-italic/l2tp-checker)

**Docker Image**: Available on Docker Hub or build locally with `docker-compose build`

**Support**: Issues and questions welcome on [GitHub Issues](https://github.com/germain-italic/l2tp-checker/issues)