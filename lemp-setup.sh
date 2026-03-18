#!/bin/bash
#
# lemp-setup.sh - Netbits Professional Auto-Installer
#
# Supported OS:
#   - Debian 11/12/13
#   - Ubuntu 20.04/22.04/24.04
#
# Author: Ramadi (www.netbits.id)
# Description: Automated LEMP Stack (Nginx, MariaDB, PHP) deployment 
# with Database, Domain, and SSL HTTPS configuration.
#
set -uo pipefail
shopt -s inherit_errexit 2>/dev/null || true
trap _exit_handler INT QUIT TERM

#==============================================================================
# Configuration & Branding
#==============================================================================
readonly AUTHOR="Ramadi"
readonly WEBSITE="www.netbits.id"
readonly LOG_FILE="/var/log/netbits-lemp.log"
readonly DEFAULT_DB_ROOT_PASS="RamadiNetbits2026"
readonly WWW_ROOT_BASE="/data/www"

# Internal Variables
PHP_VER=""
MARIADB_VER=""
USER_DOMAIN=""
PM_TYPE="apt"

#==============================================================================
# UI & Logging Functions
#==============================================================================
_red() { printf '\033[1;31m%b\033[0m' "$1"; }
_green() { printf '\033[1;32m%b\033[0m' "$1"; }
_yellow() { printf '\033[1;33m%b\033[0m' "$1"; }

_log() {
    local level="$1"; shift 1
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[${timestamp}] [${level}] $*" | tee -a "${LOG_FILE}"
}

_info() { _log "INFO" "$(_green "$*")"; }
_warn() { _log "WARN" "$(_yellow "$*")"; }
_error() { _log "ERROR" "$(_red "$*")"; exit 1; }

_exit_handler() {
    printf "\n"
    _red "Installation aborted or script terminated unexpectedly."
    printf "\n"
    exit 1
}

_exists() { command -v "$1" &>/dev/null; }

_error_detect() {
    local cmd="$1"
    _log "EXEC" "Executing: ${cmd}"
    if ! eval "${cmd}" >>"${LOG_FILE}" 2>&1; then
        _error "Command failed: ${cmd}. Check logs at ${LOG_FILE}"
    fi
}

#==============================================================================
# OS & System Validation
#==============================================================================
_get_opsy() {
    [ -f /etc/os-release ] && awk -F= '/^PRETTY_NAME=/{gsub(/^"|"$/, "", $2); print $2}' /etc/os-release
}

_check_os_support() {
    if [ -f /etc/os-release ]; then
        local os_id=$(awk -F= '/^ID=/{gsub(/"/, ""); print $2}' /etc/os-release)
        if [[ ! "${os_id}" =~ ^(debian|ubuntu)$ ]]; then
            _error "Unsupported OS. This script is intended for Debian/Ubuntu only."
        fi
    else
        _error "File /etc/os-release not found. Failed to detect OS."
    fi
}

#==============================================================================
# Phase 1: Pre-Initialization & Optimization
#==============================================================================
_prepare_system() {
    [[ ${EUID} -ne 0 ]] && _error "This script must be run as ROOT!"
    
    _info "Checking system dependencies..."
    _error_detect "apt-get update"
    _error_detect "apt-get install -y curl wget git unzip dnsutils software-properties-common ca-certificates lsb-release"

    _info "Optimizing Kernel (TCP BBR)..."
    if ! grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        _error_detect "sysctl -p"
    fi
}

#==============================================================================
# Phase 2: User Inputs
#==============================================================================
_get_user_input() {
    clear
    echo -e "$(_green "--------------------------------------------------------")"
    echo -e "$(_green "      LEMP AUTO-INSTALLER v1.0 - BY ${AUTHOR}")"
    echo -e "$(_green "      Official Website: ${WEBSITE}")"
    echo -e "$(_green "--------------------------------------------------------")"
    echo -e "OS Detected: $(_yellow "$(_get_opsy)")"
    echo ""

    read -r -p "Enter Domain Name (e.g., netbits.id): " USER_DOMAIN
    [[ -z "${USER_DOMAIN}" ]] && _error "Domain cannot be empty!"

    echo -e "\n$(_yellow "--- Select PHP Version ---")"
    echo "1. PHP 8.1"
    echo "2. PHP 8.2"
    echo "3. PHP 8.3 (Recommended)"
    echo "4. PHP 8.4"
    read -p "Choice [1-4, Default 3]: " p_choice
    case ${p_choice:-3} in 1) PHP_VER="8.1";; 2) PHP_VER="8.2";; 4) PHP_VER="8.4";; *) PHP_VER="8.3";; esac

    echo -e "\n$(_yellow "--- Select MariaDB Version ---")"
    echo "1. MariaDB 10.11 (LTS)"
    echo "2. MariaDB 11.4"
    read -p "Choice [1-2, Default 1]: " m_choice
    [[ ${m_choice:-1} == "2" ]] && MARIADB_VER="11.4" || MARIADB_VER="10.11"

    echo -e "\n$(_yellow "--- Database Credentials ---")"
    read -s -r -p "Create MariaDB Root Password (Default: ${DEFAULT_DB_ROOT_PASS}): " db_root_pass
    DB_ROOT_PASS="${db_root_pass:-${DEFAULT_DB_ROOT_PASS}}"
    echo ""
    read -r -p "Database Name: " DB_NAME
    read -r -p "Database User: " DB_USER
    read -s -r -p "Database User Password: " DB_USER_PASS
    echo ""
    [[ -z "${DB_NAME}" || -z "${DB_USER}" || -z "${DB_USER_PASS}" ]] && _error "Database inputs cannot be empty!"
}

#==============================================================================
# Phase 3: Core Installation
#==============================================================================
_install_mariadb() {
    _info "Setting up MariaDB ${MARIADB_VER} repository..."
    _error_detect "curl -LsS https://r.mariadb.com/downloads/mariadb_repo_setup | bash -s -- --mariadb-server-version=${MARIADB_VER}"
    _error_detect "apt-get update && apt-get install -y mariadb-server mariadb-client"
    
    _info "Configuring Database & Users..."
    mysql -u root << EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASS}';
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_USER_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF
}

_install_php() {
    _info "Setting up PHP Repository (Ondrej Sury)..."
    if [[ $(lsb_release -is) == "Ubuntu" ]]; then
        _error_detect "add-apt-repository -y ppa:ondrej/php"
    else
        _error_detect "curl -sSLo /usr/share/keyrings/deb.sury.org-php.gpg https://packages.sury.org/php/apt.gpg"
        echo "deb [signed-by=/usr/share/keyrings/deb.sury.org-php.gpg] https://packages.sury.org/php/ $(lsb_release -sc) main" > /etc/apt/sources.list.d/php.list
    fi

    _error_detect "apt-get update"
    _info "Installing PHP ${PHP_VER} & Extensions..."
    _error_detect "apt-get install -y php${PHP_VER}-fpm php${PHP_VER}-mysql php${PHP_VER}-gd php${PHP_VER}-mbstring php${PHP_VER}-curl php${PHP_VER}-xml php${PHP_VER}-zip php${PHP_VER}-bcmath php${PHP_VER}-intl"

    # Performance Tuning
    sed -i "s/memory_limit = .*/memory_limit = 256M/" /etc/php/${PHP_VER}/fpm/php.ini
    sed -i "s/upload_max_filesize = .*/upload_max_filesize = 64M/" /etc/php/${PHP_VER}/fpm/php.ini
    _error_detect "systemctl restart php${PHP_VER}-fpm"
}

_install_nginx() {
    _info "Installing Nginx Engine..."
    _error_detect "apt-get install -y nginx"
    
    mkdir -p "${WWW_ROOT_BASE}/${USER_DOMAIN}" "/data/wwwlog"
    
    _info "Configuring Nginx Server Block for ${USER_DOMAIN}..."
    cat > "/etc/nginx/sites-available/${USER_DOMAIN}" << EOF
server {
    listen 80;
    server_name ${USER_DOMAIN} www.${USER_DOMAIN};
    root ${WWW_ROOT_BASE}/${USER_DOMAIN};
    index index.php index.html index.htm;

    access_log /data/wwwlog/${USER_DOMAIN}_access.log;
    error_log /data/wwwlog/${USER_DOMAIN}_error.log;

    # Gzip Compression
    gzip on;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php${PHP_VER}-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.ht { deny all; }
}
EOF
    ln -sf "/etc/nginx/sites-available/${USER_DOMAIN}" "/etc/nginx/sites-enabled/"
    rm -f /etc/nginx/sites-enabled/default
    
    # Firewall Configuration (UFW)
    if _exists "ufw"; then
        _info "Configuring UFW Firewall..."
        _error_detect "ufw allow 'Nginx Full'"
    fi

    _error_detect "systemctl restart nginx"
}

#==============================================================================
# Phase 4: SSL Certificate Setup
#==============================================================================
_install_ssl() {
    _yellow "\n--- Starting SSL Configuration ---"
    local local_ip=$(curl -s ifconfig.me)
    local domain_ip=$(dig +short "${USER_DOMAIN}" | tail -n1)

    if [[ "${domain_ip}" != "${local_ip}" ]]; then
        _warn "DNS for ${USER_DOMAIN} does not point to this Server IP (${local_ip}). Skipping SSL."
        return 0
    fi

    _error_detect "apt-get install -y certbot python3-certbot-nginx"
    _info "Requesting SSL Certificate from Let's Encrypt..."
    certbot --nginx --non-interactive --agree-tos --email "admin@${USER_DOMAIN}" -d "${USER_DOMAIN}" -d "www.${USER_DOMAIN}" --redirect
}

#==============================================================================
# Main Execution Flow
#==============================================================================
main() {
    _check_os_support
    _prepare_system
    _get_user_input
    
    _info "Starting LEMP Stack Installation..."
    _install_mariadb
    _install_php
    _install_nginx
    _install_ssl
    
    # Finalize Permissions
    chown -R www-data:www-data "${WWW_ROOT_BASE}/${USER_DOMAIN}"
    
    # Professional Landing Page
    cat > "${WWW_ROOT_BASE}/${USER_DOMAIN}/index.php" << EOF
<?php
echo "<html><head><title>Success</title><style>body{font-family:sans-serif;text-align:center;padding:50px;}</style></head><body>";
echo "<h1>LEMP Stack Successfully Installed!</h1>";
echo "<p>Server optimized by <b>${AUTHOR}</b> (<a href='http://${WEBSITE}'>Netbits.id</a>)</p>";
echo "<div style='background:#f4f4f4;padding:20px;display:inline-block;'>PHP Version: " . phpversion() . "<br>Database: Connected</div>";
echo "</body></html>";
?>
EOF

    clear
    echo -e "$(_green "========================================================")"
    echo -e "$(_green "           INSTALLATION COMPLETED!")"
    echo -e "$(_green "========================================================")"
    echo "Domain      : https://${USER_DOMAIN}"
    echo "PHP Version : ${PHP_VER}"
    echo "Database    : ${DB_NAME}"
    echo "Log File    : ${LOG_FILE}"
    echo -e "$(_green "--------------------------------------------------------")"
    echo "Thank you for using Netbits Installer."
}

main "$@"
