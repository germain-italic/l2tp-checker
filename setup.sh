#!/bin/bash

# VPN Monitor Setup Script
# Compatible with Debian native, macOS, and Debian WSL2

set -e

echo "🔧 Setting up VPN Monitor..."

# Detect OS
OS="$(uname -s)"
case "${OS}" in
    Linux*)     MACHINE=Linux;;
    Darwin*)    MACHINE=Mac;;
    *)          MACHINE="UNKNOWN:${OS}"
esac

echo "📋 Detected OS: $MACHINE"

# Check if Python 3 is installed
if ! command -v python3 &> /dev/null; then
    echo "❌ Python 3 is required but not installed"
    echo "Please install Python 3 and try again"
    exit 1
fi

echo "✓ Python 3 found: $(python3 --version)"

# Check if pip is installed
if ! command -v pip3 &> /dev/null; then
    echo "❌ pip3 is required but not installed"
    echo "Please install pip3 and try again"
    exit 1
fi

echo "✓ pip3 found"

# Install Python requirements
echo "📦 Installing Python dependencies..."
pip3 install -r requirements.txt

# Create .env file from template if it doesn't exist
if [ ! -f .env ]; then
    echo "📝 Creating .env file from template..."
    cp .env.dist .env
    echo "⚠️  Please edit .env file with your actual configuration before running the monitor"
else
    echo "✓ .env file already exists"
fi

# Make the Python script executable
chmod +x vpn_monitor.py

# Create log directory
sudo mkdir -p /var/log/vpn-monitor 2>/dev/null || mkdir -p ~/vpn-monitor-logs
echo "✓ Log directory created"

echo ""
echo "🎉 Setup completed successfully!"
echo ""
echo "Next steps:"
echo "1. Edit the .env file with your VPN servers and database configuration"
echo "2. Import the database schema: mysql -u username -p database_name < database.sql"
echo "3. Test the monitor: python3 vpn_monitor.py"
echo "4. Add to crontab for automatic monitoring:"
echo "   */5 * * * * cd $(pwd) && python3 vpn_monitor.py >/dev/null 2>&1"
echo ""