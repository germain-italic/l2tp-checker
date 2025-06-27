# Multi-stage Dockerfile optimized for build speed and caching
FROM debian:bookworm-slim as base

# Set environment variables early for better caching
ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1

# Install system dependencies in a single layer with cleanup
# This layer changes rarely, so it will be cached effectively
RUN apt-get update && apt-get install -y \
    # Core system tools
    iproute2 \
    curl \
    iputils-ping \
    netcat-openbsd \
    # VPN clients
    strongswan \
    xl2tpd \
    ppp \
    # Python and build dependencies
    python3 \
    python3-pip \
    default-libmysqlclient-dev \
    gcc \
    libffi-dev \
    libssl-dev \
    pkg-config \
    # Debug tools (comment out for production to reduce image size)
    tcpdump \
    strace \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get clean

# Create working directory early
WORKDIR /app

# Copy and install Python dependencies FIRST (changes less frequently)
# This layer will be cached unless requirements.txt changes
COPY requirements.txt /tmp/requirements.txt
RUN pip3 install --no-cache-dir --break-system-packages -r /tmp/requirements.txt && \
    pip3 install --no-cache-dir --break-system-packages mysqlclient && \
    rm /tmp/requirements.txt

# Create necessary directories and set permissions
# This layer rarely changes
RUN mkdir -p /etc/ipsec.d /var/run/xl2tpd /var/log/vpn-monitor && \
    chmod 755 /etc/ipsec.d

# Copy configuration template (changes rarely)
COPY .env.dist /app/

# Copy shell scripts (change less frequently than Python code)
COPY run_monitor.sh /app/
COPY synology_debug.sh /app/

# Copy main Python application (changes most frequently - do this last)
COPY vpn_monitor.py /app/

# Make all scripts executable in a single layer
RUN chmod +x /app/run_monitor.sh /app/vpn_monitor.py /app/synology_debug.sh

# Default command
CMD ["/app/run_monitor.sh"]