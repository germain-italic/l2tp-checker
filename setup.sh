#!/bin/bash

# VPN Monitor Setup Script
# Compatible with Debian native, macOS, and Debian WSL2
# Handles all dependency installation scenarios

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

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to check if a Python module can be imported
python_module_exists() {
    python3 -c "import $1" 2>/dev/null
}

# Function to install system packages
install_system_packages() {
    local packages=("$@")
    
    if command_exists apt; then
        echo "📦 Installing system packages with apt: ${packages[*]}"
        sudo apt update
        sudo apt install -y "${packages[@]}"
    elif command_exists yum; then
        echo "📦 Installing system packages with yum: ${packages[*]}"
        sudo yum install -y "${packages[@]}"
    elif command_exists dnf; then
        echo "📦 Installing system packages with dnf: ${packages[*]}"
        sudo dnf install -y "${packages[@]}"
    elif command_exists brew; then
        echo "📦 Installing system packages with brew: ${packages[*]}"
        brew install "${packages[@]}"
    else
        echo "❌ No supported package manager found"
        echo "Please install these packages manually: ${packages[*]}"
        return 1
    fi
}

# Check if Python 3 is installed
if ! command_exists python3; then
    echo "❌ Python 3 is required but not installed"
    if [[ "$MACHINE" == "Linux" ]]; then
        echo "🔧 Attempting to install Python 3..."
        install_system_packages python3 python3-pip python3-venv
    else
        echo "Please install Python 3 and try again"
        exit 1
    fi
fi

echo "✓ Python 3 found: $(python3 --version)"

# Get Python version for package names
PYTHON_VERSION=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
echo "📋 Python version: $PYTHON_VERSION"

# Check and install required Python system packages
MISSING_PACKAGES=()

# For Ubuntu 24.04+ and modern Debian, we need different packages
UBUNTU_VERSION=""
if command_exists lsb_release; then
    UBUNTU_VERSION=$(lsb_release -rs 2>/dev/null || echo "")
fi
# Check for pip
if ! command_exists pip3 && ! python_module_exists pip; then
    echo "❌ pip not found"
    MISSING_PACKAGES+=("python3-pip")
fi

# Check for venv module
if ! python_module_exists venv; then
    echo "❌ venv module not found"
    MISSING_PACKAGES+=("python3-venv")
fi

# Check for ensurepip (needed for venv creation)
if ! python_module_exists ensurepip; then
    echo "❌ ensurepip module not found"
    # On Ubuntu 24.04+, ensurepip is usually included with python3-venv
    # But we might need additional packages
    if [[ "$MACHINE" == "Linux" ]]; then
        MISSING_PACKAGES+=("python3-venv")  # This often includes ensurepip
    fi
fi

# Install missing system packages
if [ ${#MISSING_PACKAGES[@]} -gt 0 ]; then
    echo "🔧 Installing missing Python packages: ${MISSING_PACKAGES[*]}"
    install_system_packages "${MISSING_PACKAGES[@]}"
    
    # Verify installations
    echo "🔍 Verifying installations..."
    if ! python_module_exists venv; then
        echo "❌ venv module still not available after installation"
        echo "This is unusual - python3-venv should provide the venv module"
    fi
    
    if ! python_module_exists ensurepip; then
        echo "❌ ensurepip module still not available"
        echo "This is expected on some systems - we'll use alternative methods"
    fi
fi

# Final verification
echo "🔍 Final verification of Python modules..."
VERIFICATION_FAILED=false

if ! python_module_exists venv; then
    echo "❌ venv module verification failed"
    VERIFICATION_FAILED=true
fi

if ! python_module_exists ensurepip; then
    echo "❌ ensurepip module verification failed"
    VERIFICATION_FAILED=true
fi

if [ "$VERIFICATION_FAILED" = true ]; then
    echo ""
    echo "❌ Some Python modules are still missing after installation attempts"
    echo "This might be due to:"
    echo "1. Incomplete Python installation"
    echo "2. Different package names on your distribution"
    echo "3. Permission issues"
    echo ""
    echo "Please try installing manually:"
    echo "  sudo apt install python3 python3-pip python3-venv python3-distutils"
    echo "  # or for your specific Python version:"
    echo "  sudo apt install python3-venv python3-distutils python3-setuptools"
    echo ""
    echo "Continuing with fallback installation method..."
fi

# Determine installation method
VENV_DIR="venv"
USE_VENV=false
INSTALL_METHOD=""

# Check if we can install globally
if command_exists pip3; then
    echo "✓ pip3 found"
    
    # Test if we can install packages globally
    if pip3 install --dry-run --quiet --no-deps requests 2>&1 | grep -q "externally-managed-environment"; then
        echo "⚠️  Externally managed Python environment detected"
        USE_VENV=true
        INSTALL_METHOD="venv"
    else
        echo "✓ Can install packages globally"
        INSTALL_METHOD="global"
    fi
elif python3 -m pip --version &> /dev/null; then
    echo "✓ python3 -m pip found"
    USE_VENV=true
    INSTALL_METHOD="venv"
else
    echo "❌ No pip installation method found"
    echo "Attempting to bootstrap pip installation..."
    
    # Try to bootstrap pip
    if command_exists curl; then
        echo "📥 Downloading get-pip.py..."
        curl -sS https://bootstrap.pypa.io/get-pip.py -o get-pip.py
        echo "🔧 Installing pip..."
        python3 get-pip.py --user
        rm -f get-pip.py
        
        # Add user bin to PATH if not already there
        USER_BIN="$HOME/.local/bin"
        if [[ ":$PATH:" != *":$USER_BIN:"* ]]; then
            export PATH="$USER_BIN:$PATH"
            echo "export PATH=\"$USER_BIN:\$PATH\"" >> ~/.bashrc
            echo "✓ Added $USER_BIN to PATH"
        fi
        
        USE_VENV=true
        INSTALL_METHOD="user"
    else
        echo "❌ Cannot bootstrap pip installation (curl not found)"
        exit 1
    fi
fi

echo "📋 Installation method: $INSTALL_METHOD"

# Create virtual environment if needed
if [ "$USE_VENV" = true ] && [ "$INSTALL_METHOD" = "venv" ]; then
    echo "🐍 Setting up Python virtual environment..."
    
    # Remove existing venv if it exists
    if [ -d "$VENV_DIR" ]; then
        echo "🗑️  Removing existing virtual environment..."
        rm -rf "$VENV_DIR"
    fi
    
    # Try different methods to create virtual environment
    VENV_CREATED=false
    
    # Method 1: Standard venv module
    if python_module_exists venv && python_module_exists ensurepip; then
        echo "🔧 Creating virtual environment with venv module..."
        if python3 -m venv "$VENV_DIR"; then
            VENV_CREATED=true
            echo "✓ Virtual environment created successfully"
        else
            echo "❌ Standard venv creation failed"
        fi
    fi
    
    # Method 2: venv without pip (then install pip manually)
    if [ "$VENV_CREATED" = false ] && python_module_exists venv; then
        echo "🔧 Creating virtual environment without pip..."
        if python3 -m venv --without-pip "$VENV_DIR"; then
            echo "✓ Virtual environment created without pip"
            
            # Manually install pip in the venv
            source "$VENV_DIR/bin/activate"
            echo "📥 Installing pip in virtual environment..."
            
            if command_exists curl; then
                curl -sS https://bootstrap.pypa.io/get-pip.py | python
                VENV_CREATED=true
                echo "✓ pip installed in virtual environment"
            else
                echo "❌ Cannot install pip in venv (curl not found)"
                rm -rf "$VENV_DIR"
            fi
        fi
    fi
    
    # Method 3: Use virtualenv as fallback
    if [ "$VENV_CREATED" = false ]; then
        echo "🔧 Trying virtualenv as fallback..."
        
        # Install virtualenv using user pip
        if python3 -m pip install --user virtualenv; then
            if python3 -m virtualenv "$VENV_DIR"; then
                VENV_CREATED=true
                echo "✓ Virtual environment created with virtualenv"
            fi
        fi
    fi
    
    if [ "$VENV_CREATED" = false ]; then
        echo "❌ Failed to create virtual environment with all methods"
        echo "Falling back to user installation..."
        USE_VENV=false
        INSTALL_METHOD="user"
    else
        # Activate virtual environment
        source "$VENV_DIR/bin/activate"
        echo "✓ Virtual environment activated"
        
        # Upgrade pip in virtual environment
        echo "📦 Upgrading pip in virtual environment..."
        pip install --upgrade pip
    fi
fi

# Install Python requirements
echo "📦 Installing Python dependencies..."

case "$INSTALL_METHOD" in
    "global")
        pip3 install -r requirements.txt
        ;;
    "venv")
        pip install -r requirements.txt
        ;;
    "user")
        python3 -m pip install --user -r requirements.txt
        ;;
    *)
        echo "❌ Unknown installation method: $INSTALL_METHOD"
        exit 1
        ;;
esac

echo "✓ Python dependencies installed"

# Create .env file from template if it doesn't exist
if [ ! -f .env ]; then
    echo "📝 Creating .env file from template..."
    cp .env.dist .env
    echo "⚠️  Please edit .env file with your actual configuration before running the monitor"
else
    echo "✓ .env file already exists"
fi

# Create wrapper scripts for easy execution
echo "📝 Creating wrapper scripts..."

# Create run_monitor.sh
cat > run_monitor.sh << EOF
#!/bin/bash
# VPN Monitor Wrapper Script
cd "\$(dirname "\$0")"

case "$INSTALL_METHOD" in
    "venv")
        source venv/bin/activate
        python3 vpn_monitor.py "\$@"
        ;;
    "user")
        export PATH="\$HOME/.local/bin:\$PATH"
        python3 vpn_monitor.py "\$@"
        ;;
    "global")
        python3 vpn_monitor.py "\$@"
        ;;
esac
EOF

chmod +x run_monitor.sh

# Create install_service.sh for systemd service installation
cat > install_service.sh << 'EOF'
#!/bin/bash
# Install VPN Monitor as a systemd service

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_NAME="vpn-monitor"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

echo "🔧 Installing VPN Monitor as systemd service..."

# Create systemd service file
sudo tee "$SERVICE_FILE" > /dev/null << EOL
[Unit]
Description=VPN Monitor Service
After=network.target

[Service]
Type=oneshot
User=$USER
WorkingDirectory=$SCRIPT_DIR
ExecStart=$SCRIPT_DIR/run_monitor.sh
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOL

# Create systemd timer file
sudo tee "/etc/systemd/system/${SERVICE_NAME}.timer" > /dev/null << EOL
[Unit]
Description=Run VPN Monitor every 5 minutes
Requires=${SERVICE_NAME}.service

[Timer]
OnCalendar=*:0/5
Persistent=true

[Install]
WantedBy=timers.target
EOL

# Reload systemd and enable the timer
sudo systemctl daemon-reload
sudo systemctl enable "${SERVICE_NAME}.timer"
sudo systemctl start "${SERVICE_NAME}.timer"

echo "✓ VPN Monitor service installed and started"
echo "📊 Check status with: sudo systemctl status ${SERVICE_NAME}.timer"
echo "📋 View logs with: sudo journalctl -u ${SERVICE_NAME}.service -f"
EOF

chmod +x install_service.sh

# Make the Python script executable
chmod +x vpn_monitor.py

# Create log directory
if [ -w /var/log ] 2>/dev/null; then
    sudo mkdir -p /var/log/vpn-monitor 2>/dev/null || true
    echo "✓ System log directory created"
else
    mkdir -p ~/vpn-monitor-logs
    echo "✓ User log directory created"
fi

echo ""
echo "🎉 Setup completed successfully!"
echo ""
echo "📋 Installation Summary:"
echo "   Method: $INSTALL_METHOD"
echo "   Python: $(python3 --version)"
if [ "$USE_VENV" = true ] && [ "$INSTALL_METHOD" = "venv" ]; then
    echo "   Virtual Environment: $VENV_DIR/"
fi
echo ""
echo "Next steps:"
echo "1. Edit the .env file with your VPN servers and database configuration:"
echo "   nano .env"
echo ""
echo "2. Import the database schema:"
echo "   mysql -u username -p database_name < supabase/migrations/20250626084019_yellow_canyon.sql"
echo ""
echo "3. Test the monitor:"
echo "   ./run_monitor.sh"
echo ""
echo "4. Set up automatic monitoring (choose one):"
echo ""
echo "   Option A - Crontab (traditional):"
echo "   crontab -e"
echo "   # Add this line:"
echo "   */5 * * * * cd $(pwd) && ./run_monitor.sh >/dev/null 2>&1"
echo ""
echo "   Option B - Systemd service (recommended):"
echo "   ./install_service.sh"
echo ""
echo "📝 Files created:"
echo "   - run_monitor.sh (main execution script)"
echo "   - install_service.sh (systemd service installer)"
echo "   - .env (configuration file)"
echo ""