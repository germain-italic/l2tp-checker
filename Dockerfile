FROM debian:bookworm-slim

# Set environment variables
ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1

# Install system dependencies for VPN clients and Python
RUN apt-get update && apt-get install -y \
    iproute2 \
    strongswan \
    xl2tpd \
    python3 \
    python3-pip \
    default-libmysqlclient-dev \
    gcc \
    libffi-dev \
    libssl-dev \
    ppp \
    curl \
    iputils-ping \
    && rm -rf /var/lib/apt/lists/*

# Install Python dependencies
COPY requirements.txt /tmp/requirements.txt
RUN pip3 install --no-cache-dir -r /tmp/requirements.txt && \
    pip3 install --no-cache-dir mysqlclient

# Create working directory
WORKDIR /app

# Copy application files
COPY vpn_monitor.py /app/
COPY run_monitor.sh /app/
COPY .env.dist /app/

# Make scripts executable
RUN chmod +x /app/run_monitor.sh /app/vpn_monitor.py

# Create directories for VPN configurations
RUN mkdir -p /etc/ipsec.d /var/run/xl2tpd /var/log/vpn-monitor

# Set up proper permissions for VPN services
RUN chmod 755 /etc/ipsec.d

# Default command
CMD ["/app/run_monitor.sh"]