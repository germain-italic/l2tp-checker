# VPN Monitor v2.1.0 🚀

A significant update introducing **continuous monitoring with internal scheduling**, eliminating the need for host cron jobs and providing a much simpler deployment experience.

## 🎯 What's New in v2.1.0

### 🔄 **Continuous Monitoring Architecture**
- **Internal scheduling** - Container now manages its own polling schedule
- **Configurable intervals** - Set monitoring frequency via `POLL_INTERVAL_MINUTES` environment variable
- **No more host cron jobs** - Simplified deployment with `docker-compose up -d`
- **Automatic restart** - Container restarts automatically on host reboot (`restart: unless-stopped`)

### 🐳 **Enhanced Container Operations**
- **Background operation** - Run with `docker-compose up -d` for persistent monitoring
- **Real-time logging** - Monitor activity with `docker-compose logs -f vpn-monitor`
- **Graceful shutdown** - Proper signal handling for clean container stops
- **Health check improvements** - Better container health monitoring (30s start period)

### 🔧 **Operational Improvements**
- **Single-run mode** - Use `--single-run` flag for one-time testing
- **Simplified commands** - Clear separation between continuous and debug operations
- **Enhanced error messages** - Better troubleshooting guidance
- **Improved logging** - More informative status messages with emojis for better readability

### 🐛 **Critical Bug Fixes**
- **Fixed Python syntax errors** - Resolved `IndentationError` that prevented container startup
- **Missing method implementations** - Added `_load_ipsec_config()` and `_verify_config_loaded()` methods
- **strongSwan startup reliability** - Improved VPN daemon initialization process

## 🚀 **Migration from v2.0.0**

### **Old Approach (Cron-based):**
```bash
# Required host cron job
*/5 * * * * cd /path/to/l2tp-checker && docker-compose up --no-deps vpn-monitor
```

### **New Approach (Continuous):**
```bash
# Simple one-time setup
docker-compose up -d

# That's it! Monitor runs continuously with automatic restart
```

## ⚙️ **Configuration Options**

Add to your `.env` file:

```bash
# Continuous monitoring configuration
POLL_INTERVAL_MINUTES=5        # Check every 5 minutes (recommended)
POLL_INTERVAL_MINUTES=1        # Intensive monitoring (every minute)
POLL_INTERVAL_MINUTES=15       # Light monitoring (every 15 minutes)
POLL_INTERVAL_MINUTES=0        # Disable continuous mode (single run only)
```

## 🔧 **New Usage Patterns**

### **Continuous Monitoring (Recommended)**
```bash
# Start background monitoring
docker-compose up -d

# View real-time logs
docker-compose logs -f vpn-monitor

# Check status
docker-compose ps

# Stop monitoring
docker-compose down
```

### **Testing and Debugging**
```bash
# Stop continuous monitoring first
docker-compose down

# Run single test
docker-compose run --rm vpn-monitor python3 /app/vpn_monitor.py --single-run

# Run comprehensive debug
docker-compose run --rm vpn-monitor /app/synology_debug.sh

# Health check
docker-compose run --rm vpn-monitor python3 /app/vpn_monitor.py --health-check
```

### **Development and Troubleshooting**
```bash
# Rebuild after configuration changes
docker-compose build

# Restart with new settings
docker-compose restart vpn-monitor

# View recent logs (last 50 lines)
docker-compose logs --tail=50 vpn-monitor
```

## 📊 **Enhanced Monitoring Output**

The new continuous monitoring provides clear status updates:

```
🔄 Starting continuous VPN monitoring (polling every 5 minutes)
📡 Monitoring 2 VPN servers
🖥️  System: production-monitor (Linux)
🌐 Public IP: 203.0.113.42
📦 Version: 2.1.0
🛑 Press Ctrl+C or send SIGTERM to stop gracefully

🔍 Starting monitoring iteration #1 at 2025-06-27 10:00:00
✅ nas1 (nas1.example.com): Connected successfully (1250ms)
✅ nas2 (nas2.example.com): Connected successfully (987ms)

💤 Monitoring iteration #1 completed. Next run scheduled for 2025-06-27 10:05:00
⏱️  Sleeping for 5 minutes...
```

## 🏗️ **Docker Architecture Improvements**

### **Container Lifecycle**
- **Persistent operation** - Container stays running for continuous monitoring
- **Resource management** - Proper cleanup between VPN tests
- **Signal handling** - Graceful shutdown on SIGTERM/SIGINT
- **Health monitoring** - Extended startup period for reliable health checks

### **Network Operations**
- **Improved VPN startup** - More reliable strongSwan daemon initialization
- **Better error handling** - Enhanced connection failure analysis
- **Resource conflict prevention** - Clear separation between monitoring and debugging

## 🚨 **Breaking Changes**

### **Default Behavior Change**
- **v2.0.0**: Required external cron job for scheduling
- **v2.1.0**: Runs continuously by default with internal scheduling

### **Command Changes**
- **Old**: `docker-compose run --rm vpn-monitor` (for one-time tests)
- **New**: `docker-compose run --rm vpn-monitor python3 /app/vpn_monitor.py --single-run`

### **Environment Variables**
- **New**: `POLL_INTERVAL_MINUTES` controls continuous monitoring behavior
- **Migration**: Add `POLL_INTERVAL_MINUTES=5` to your `.env` file

## 🔐 **Security & Compatibility**

### **Platform Support**
| Platform | Support Level | Notes |
|----------|---------------|-------|
| **Linux** | ✅ Native | Full continuous monitoring |
| **macOS** | ✅ Docker | Complete operation |
| **Windows** | ✅ Docker | WSL2 recommended |

### **Security Enhancements**
- 🔐 Credentials remain secure in mounted `.env` file
- 🧹 Automatic VPN configuration cleanup
- 🛡️ Container isolation with minimal privileges
- 🔄 Regular security updates with continuous monitoring

## 📁 **Updated Project Structure**

```
l2tp-checker/
├── 🐳 docker-compose.yml         # Enhanced container orchestration
├── 📦 Dockerfile                 # Optimized build configuration
├── 🐍 vpn_monitor.py             # Core monitoring with continuous mode
├── 🔧 run_monitor.sh             # Continuous operation wrapper
├── 🛠️ synology_debug.sh          # Comprehensive debug script
├── ⚙️ .env.dist                  # Updated configuration template
├── 📋 requirements.txt           # Python dependencies
├── 🗄️ supabase/migrations/       # Database schema
└── 📖 README.md                  # Updated documentation
```

## 🚀 **Quick Start for v2.1.0**

```bash
# 1. Clone and configure
git clone https://github.com/your-username/l2tp-checker.git
cd l2tp-checker
cp .env.dist .env
nano .env

# 2. Setup database
mysql -u username -p database < supabase/migrations/20250626084019_yellow_canyon.sql

# 3. Start continuous monitoring
docker-compose up -d

# 4. Monitor logs
docker-compose logs -f vpn-monitor

# Done! VPN monitoring now runs continuously with automatic restart
```

## 🔄 **Upgrade Instructions**

### **From v2.0.0:**
1. **Update configuration:**
   ```bash
   echo "POLL_INTERVAL_MINUTES=5" >> .env
   ```

2. **Remove host cron jobs:**
   ```bash
   # Remove old cron entries for VPN monitoring
   crontab -e
   ```

3. **Deploy new version:**
   ```bash
   docker-compose down
   docker-compose pull
   docker-compose up -d
   ```

4. **Verify operation:**
   ```bash
   docker-compose logs -f vpn-monitor
   ```

## 📈 **Performance & Reliability**

### **Monitoring Efficiency**
- ⚡ **Faster startup** - Improved strongSwan initialization
- 🔄 **Resource optimization** - Better cleanup between tests
- 📊 **Consistent intervals** - Precise polling schedule management
- 🛡️ **Error resilience** - Enhanced error handling and recovery

### **Container Reliability**
- 🔧 **Health checks** - Extended startup period for stable operation
- 🔄 **Automatic restart** - Survives host reboots and Docker restarts
- 📝 **Comprehensive logging** - Detailed operation tracking
- 🚨 **Graceful shutdown** - Clean resource cleanup on stop

## 🤝 **Contributing**

We welcome contributions! Areas for improvement:
- 🧪 **Testing on additional platforms** and VPN server types
- 🔌 **Additional VPN protocol support** (OpenVPN, WireGuard)
- 📊 **Web dashboard development** for real-time monitoring
- 🚨 **Alerting integrations** (Slack, email, webhook notifications)
- ⚡ **Performance optimizations** and memory usage improvements

## 🐛 **Known Issues & Solutions**

### **Common Deployment Issues**
1. **Container fails to start:**
   - Check `.env` file configuration
   - Verify database connectivity
   - Ensure Docker has sufficient privileges

2. **VPN connections fail:**
   - Run debug script: `docker-compose run --rm vpn-monitor /app/synology_debug.sh`
   - Verify VPN server credentials
   - Check network connectivity and firewall settings

3. **Continuous monitoring stops:**
   - Check container logs: `docker-compose logs vpn-monitor`
   - Verify resource availability
   - Restart with: `docker-compose restart vpn-monitor`

## 📜 **License**

MIT License - See [LICENSE](LICENSE) file for details.

---

**Full Changelog**: [v2.0.0...v2.1.0](https://github.com/your-username/l2tp-checker/compare/v2.0.0...v2.1.0)

**Docker Image**: Build locally with `docker-compose build`

**Support**: Issues and questions welcome on [GitHub Issues](https://github.com/your-username/l2tp-checker/issues)

---

## 🎉 **Thank You**

Thanks to all users who provided feedback on v2.0.0! This release addresses the main request for **simplified deployment without host cron jobs** while maintaining all the powerful VPN testing capabilities.

**Happy monitoring!** 🔍🔒