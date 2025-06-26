-- VPN Monitoring Database Schema
-- Compatible with MySQL 5.7+ and MariaDB 10.2+

CREATE DATABASE IF NOT EXISTS vpn_monitoring;
USE vpn_monitoring;

-- Table to store VPN connection test results
CREATE TABLE IF NOT EXISTS vpn_test_results (
    id INT AUTO_INCREMENT PRIMARY KEY,
    test_timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    computer_identifier VARCHAR(255) NOT NULL,
    system_username VARCHAR(255) NOT NULL,
    public_ip_address VARCHAR(45),  -- IPv6 compatible
    vpn_server_name VARCHAR(255) NOT NULL,
    vpn_server_ip VARCHAR(255) NOT NULL,
    connection_successful BOOLEAN NOT NULL,
    connection_time_ms INT DEFAULT NULL,  -- Connection time in milliseconds
    error_message TEXT DEFAULT NULL,
    operating_system VARCHAR(100),
    monitor_version VARCHAR(50),
    
    INDEX idx_timestamp (test_timestamp),
    INDEX idx_computer (computer_identifier),
    INDEX idx_server (vpn_server_name),
    INDEX idx_success (connection_successful)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Table to track monitor instances and their status
CREATE TABLE IF NOT EXISTS monitor_instances (
    id INT AUTO_INCREMENT PRIMARY KEY,
    computer_identifier VARCHAR(255) NOT NULL,
    system_username VARCHAR(255) NOT NULL,
    operating_system VARCHAR(100),
    last_seen TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    total_tests_run INT DEFAULT 0,
    monitor_version VARCHAR(50),
    
    UNIQUE KEY unique_instance (computer_identifier, system_username),
    INDEX idx_last_seen (last_seen)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- View for easy monitoring dashboard queries
CREATE OR REPLACE VIEW vpn_monitoring_summary AS
SELECT 
    vpn_server_name,
    vpn_server_ip,
    COUNT(*) as total_tests,
    SUM(CASE WHEN connection_successful = 1 THEN 1 ELSE 0 END) as successful_tests,
    ROUND((SUM(CASE WHEN connection_successful = 1 THEN 1 ELSE 0 END) / COUNT(*)) * 100, 2) as success_rate_percent,
    AVG(CASE WHEN connection_successful = 1 THEN connection_time_ms ELSE NULL END) as avg_connection_time_ms,
    MAX(test_timestamp) as last_test_time,
    COUNT(DISTINCT computer_identifier) as unique_monitors
FROM vpn_test_results 
WHERE test_timestamp >= DATE_SUB(NOW(), INTERVAL 24 HOUR)
GROUP BY vpn_server_name, vpn_server_ip
ORDER BY success_rate_percent DESC;

-- View for recent failures
CREATE OR REPLACE VIEW recent_failures AS
SELECT 
    test_timestamp,
    computer_identifier,
    vpn_server_name,
    vpn_server_ip,
    error_message,
    public_ip_address
FROM vpn_test_results 
WHERE connection_successful = 0 
    AND test_timestamp >= DATE_SUB(NOW(), INTERVAL 1 HOUR)
ORDER BY test_timestamp DESC;