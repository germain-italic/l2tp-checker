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

# Check if we need to create a virtual environment (for newer Python installations)
VENV_DIR="venv"
USE_VENV=false

# Check if pip3 is available and if we're in an externally managed environment
if command -v pip3 &> /dev/null; then
    echo "✓ pip3 found"
    
    # Test if we can install packages globally by checking for externally managed environment
    if pip3 list &> /dev/null && ! pip3 install --dry-run --quiet --no-deps requests 2>&1 | grep -q "externally-managed-environment"; then
        echo "✓ Can install packages globally"
    else
        echo "⚠️  Externally managed Python environment detected"
        USE_VENV=true
    fi
else
    echo "❌ pip3 not found, checking for python3 -m pip..."
    if python3 -m pip --version &> /dev/null; then
        echo "✓ python3 -m pip found"
        USE_VENV=true
    else
        echo "❌ pip is required but not installed"
        echo "Please install pip3 and try again"
        exit 1
    fi
fi

# Create virtual environment if needed
if [ "$USE_VENV" = true ]; then
    echo "🐍 Setting up Python virtual environment..."
    
    # First, check if python3-venv is available by trying to create a test venv
    if ! python3 -m venv --help &> /dev/null 2>&1; then
        echo "❌ python3-venv module is not available"
        echo "🔧 Attempting to install python3-venv..."
        
        # Detect Python version for package name
        PYTHON_VERSION=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
        VENV_PACKAGE="python${PYTHON_VERSION}-venv"
        
        # Try to install python3-venv automatically
        if command -v apt &> /dev/null; then
            # Debian/Ubuntu systems
            echo "📦 Installing $VENV_PACKAGE using apt..."
            if sudo apt update && sudo apt install -y "$VENV_PACKAGE"; then
                echo "✓ $VENV_PACKAGE installed successfully"
            else
                echo "❌ Failed to install $VENV_PACKAGE automatically"
                echo "Please run manually: sudo apt install $VENV_PACKAGE"
                exit 1
            fi
        elif command -v yum &> /dev/null; then
            # RHEL/CentOS systems
            echo "📦 Installing python3-venv using yum..."
            if sudo yum install -y python3-venv; then
                echo "✓ python3-venv installed successfully"
            else
                echo "❌ Failed to install python3-venv automatically"
                echo "Please run manually: sudo yum install python3-venv"
                exit 1
            fi
        elif command -v dnf &> /dev/null; then
            # Modern Fedora systems
            echo "📦 Installing python3-venv using dnf..."
            if sudo dnf install -y python3-venv; then
                echo "✓ python3-venv installed successfully"
            else
                echo "❌ Failed to install python3-venv automatically"
                echo "Please run manually: sudo dnf install python3-venv"
                exit 1
            fi
        else
            echo "❌ Cannot automatically install python3-venv on this system"
            echo "Please install it manually and run this script again"
            echo "For Debian/Ubuntu: sudo apt install $VENV_PACKAGE"
            exit 1
        fi
    fi
    
    # Now try to create the virtual environment
    echo "🐍 Creating Python virtual environment..."
    
    # Remove existing venv if it exists and is broken
    if [ -d "$VENV_DIR" ]; then
        echo "🗑️  Removing existing virtual environment..."
        rm -rf "$VENV_DIR"
    fi
    
    # Create virtual environment
    if python3 -m venv "$VENV_DIR"; then
        echo "✓ Virtual environment created in $VENV_DIR/"
    else
        echo "❌ Failed to create virtual environment"
        echo "This might be due to missing python3-venv package"
        echo "Please install it manually and try again"
        exit 1
    fi
    
    # Activate virtual environment
    source "$VENV_DIR/bin/activate"
    echo "✓ Virtual environment activated"
    
    # Upgrade pip in virtual environment
    echo "📦 Upgrading pip in virtual environment..."
    pip install --upgrade pip
fi

# Install Python requirements
echo "📦 Installing Python dependencies..."
if [ "$USE_VENV" = true ]; then
    pip install -r requirements.txt
else
    pip3 install -r requirements.txt
fi

# Create .env file from template if it doesn't exist
if [ ! -f .env ]; then
    echo "📝 Creating .env file from template..."
    cp .env.dist .env
    echo "⚠️  Please edit .env file with your actual configuration before running the monitor"
else
    echo "✓ .env file already exists"
fi

# Create a wrapper script for easy execution
if [ "$USE_VENV" = true ]; then
    echo "📝 Creating wrapper script..."
    cat > run_monitor.sh << 'EOF'
#!/bin/bash
# VPN Monitor Wrapper Script
cd "$(dirname "$0")"
source venv/bin/activate
python3 vpn_monitor.py "$@"
EOF
    chmod +x run_monitor.sh
    echo "✓ Wrapper script created: run_monitor.sh"
fi

# Make the Python script executable
chmod +x vpn_monitor.py

# Create log directory
if [ -w /var/log ]; then
    sudo mkdir -p /var/log/vpn-monitor 2>/dev/null || true
    echo "✓ System log directory created"
else
    mkdir -p ~/vpn-monitor-logs
    echo "✓ User log directory created"
fi

echo ""
echo "🎉 Setup completed successfully!"
echo ""
echo "Next steps:"
echo "1. Edit the .env file with your VPN servers and database configuration"
echo "2. Import the database schema: mysql -u username -p database_name < supabase/migrations/20250626084019_yellow_canyon.sql"

if [ "$USE_VENV" = true ]; then
    echo "3. Test the monitor: ./run_monitor.sh"
    echo "4. Add to crontab for automatic monitoring:"
    echo "   */5 * * * * cd $(pwd) && ./run_monitor.sh >/dev/null 2>&1"
else
    echo "3. Test the monitor: python3 vpn_monitor.py"
    echo "4. Add to crontab for automatic monitoring:"
    echo "   */5 * * * * cd $(pwd) && python3 vpn_monitor.py >/dev/null 2>&1"
fi
echo ""

if [ "$USE_VENV" = true ]; then
    echo "📝 Note: A virtual environment was created. Use './run_monitor.sh' to run the monitor"
    echo "   or activate the environment manually with: source venv/bin/activate"
fi