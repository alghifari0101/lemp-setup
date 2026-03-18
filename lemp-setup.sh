#!/bin/bash
#
# lemp-setup.sh - Netbits Professional Auto-Installer
#
# Platform: Debian 11/12, Ubuntu 20.04/22.04/24.04
# Author: Ramadi (www.netbits.id)
#
# Deskripsi: Script otomasi LEMP Stack (Nginx, MariaDB, PHP) 
# Lengkap dengan setup Database, Domain, dan SSL HTTPS.
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

# Internal Variables
PHP_VER=""
MARIADB_VER=""
USER_DOMAIN=""

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
    _red "Instalasi dibatalkan oleh pengguna."
    printf "\n"
    exit 1
}

_exists() { command -v "$1" &>/dev/null; }

_error_detect() {
    local cmd="$1"
    _log "EXEC" "Menjalankan: ${cmd}"
    if ! eval "${cmd}" >>"${LOG_FILE}" 2>&1; then
        _error "Gagal mengeksekusi: ${cmd}. Cek log di ${LOG_FILE}"
    fi
}

#==============================================================================
# Phase 1: System Optimization
#==============================================================================
_prepare_system() {
    [[ ${EUID} -ne 0 ]] && _error "Script ini harus dijalankan sebagai ROOT!"
    
    _info "Mengoptimalkan Kernel (TCP BBR) & Networking..."
    if ! grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p >/dev/null 2>&1
    fi
    
    _error_detect "apt-get update"
    _error_detect "apt-get install -y curl wget git unzip dnsutils software-properties-common"
}

#==============================================================================
# Phase 2: User Inputs
#==============================================================================
_get_user_input() {
    clear
    _green "========================================================\n"
    _green "   LEMP AUTO-INSTALLER v1.0 - BY ${AUTHOR}\n"
    _green "   Official Website: ${WEBSITE}\n"
    _green "========================================================\n"

    # 1. Domain Input
    _yellow "--- 1. Setup Domain Website ---"
    read -r -p "Masukkan Nama Domain (contoh: netbits.id): " USER_DOMAIN
    [[ -z "${USER_DOMAIN}" ]] && _error "Domain tidak boleh kosong!"

    # 2. Version Selection
    _yellow "\n--- 2. Pilihan Versi Stack ---"
    _info "Pilih PHP: 1. PHP 8.1 | 2. PHP 8.2 | 3. PHP 8.3 | 4. PHP 8.4"
    read -r -p "Pilihan [1-4]: " p_choice
    case $p_choice in 1) PHP_VER="8.1";; 2) PHP_VER="8.2";; 4) PHP_VER="8.4";; *) PHP_VER="8.3";; esac

    _info "Pilih MariaDB: 1. MariaDB 10.11 (LTS) | 2. MariaDB 11.4"
    read -r -p "Pilihan [1-2]: " m_choice
    [[ $m_choice == "2" ]] && MARIADB_VER="11.4" || MARIADB_VER="10.11"

    # 3. DB Credentials
    _yellow "\n--- 3. Database & User Setup ---"
    read -s -r -p "Buat Password Root MariaDB (Default: ${DEFAULT_DB_ROOT_PASS}): " db_root_pass
    DB_ROOT_PASS="${db_root_pass:-${DEFAULT_DB_ROOT_PASS}}"
    echo ""
    read -r -p "Nama Database Baru: " DB_NAME
    read -r -p "User Database Baru: " DB_USER
    read -s -r -p "Password User Database Baru: " DB_USER_PASS
    echo ""
    [[ -z "${DB_NAME}" || -z "${DB_USER}" || -z "${DB_USER_PASS}" ]] && _error "Input Database tidak boleh kosong!"
}

#==============================================================================
# Phase 3: Core Installation
#==============================================================================
_install_stack() {
    # 1. MariaDB Setup
    _info "Menginstal MariaDB ${MARIADB_VER} & Membuat Database..."
    _error_detect "curl -LsS https://r.mariadb.com/downloads/mariadb_repo_setup | bash -s -- --mariadb-server-version=${MARIADB_VER}"
    _error_detect "apt-get update && apt-get install -y mariadb-server"
    
    mysql -u root << EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASS}';
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_USER_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF

    # 2. PHP-FPM Setup
    _info "Menginstal PHP ${PHP_VER} & Extensions..."
    if [[ $(lsb_release -is) == "Ubuntu" ]]; then
        _error_detect "add-apt-repository -y ppa:ondrej/php"
    else
        _error_detect "curl -sSLo /usr/share/keyrings/deb.sury.org-php.gpg https://packages.sury.org/php/apt.gpg"
        echo "deb [signed-by=/usr/share/keyrings/deb.sury.org-php.gpg] https://packages.sury.org/php/ $(lsb_release -sc) main" > /etc/apt/sources.list.d/php.list
    fi
    _error_detect "apt-get update"
    _error_detect "apt-get install -y php${PHP_VER}-fpm php${PHP_VER}-mysql php${PHP_VER}-gd php${PHP_VER}-mbstring php${PHP_VER}-curl php${PHP_VER}-xml php${PHP_VER}-zip"

    # 3. Nginx Setup
    _info "Menginstal Nginx & Konfigurasi Virtual Host..."
    _error_detect "apt-get install -y nginx"
    mkdir -p "/data/www/${USER_DOMAIN}" "/data/wwwlog"
    
    cat > "/etc/nginx/sites-available/${USER_DOMAIN}" << EOF
server {
    listen 80;
    server_name ${USER_DOMAIN} www.${USER_DOMAIN};
    root /data/www/${USER_DOMAIN};
    index index.php index.html;

    access_log /data/wwwlog/${USER_DOMAIN}_access.log;
    error_log /data/wwwlog/${USER_DOMAIN}_error.log;

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
    systemctl restart nginx
}

#==============================================================================
# Phase 4: SSL Certificate Setup
#==============================================================================
_install_ssl() {
    _yellow "\n--- 4. Konfigurasi SSL (HTTPS) ---"
    local local_ip=$(curl -s ifconfig.me)
    local domain_ip=$(dig +short "${USER_DOMAIN}" | tail -n1)

    if [[ "${domain_ip}" != "${local_ip}" ]]; then
        _warn "Domain ${USER_DOMAIN} belum diarahkan ke IP ${local_ip}. Skip SSL."
        return 0
    fi

    _info "Menginstal Certbot & Meminta Sertifikat Let's Encrypt..."
    _error_detect "apt-get install -y certbot python3-certbot-nginx"
    certbot --nginx --non-interactive --agree-tos --email "admin@${USER_DOMAIN}" -d "${USER_DOMAIN}" -d "www.${USER_DOMAIN}" --redirect
}

#==============================================================================
# Main Execution
#==============================================================================
main() {
    _prepare_system
    _get_user_input
    
    _install_stack
    _install_ssl
    
    # Finalize Permissions & Web Content
    chown -R www-data:www-data "/data/www/${USER_DOMAIN}"
    cat > "/data/www/${USER_DOMAIN}/index.php" << EOF
<?php
echo "<h1>Welcome to ${USER_DOMAIN}</h1>";
echo "<p>Server Optimized by <b>${AUTHOR}</b> from <b><a href='http://${WEBSITE}'>Netbits.id</a></b></p>";
echo "<h3>Database Status: Connected</h3>";
phpinfo();
?>
EOF

    clear
    _green "========================================================\n"
    _green "   INSTALASI LEMP BERHASIL SELESAI!\n"
    _green "========================================================\n"
    echo "Domain      : https://${USER_DOMAIN}"
    echo "Root Path   : /data/www/${USER_DOMAIN}"
    echo "DB Name     : ${DB_NAME}"
    echo "DB User     : ${DB_USER}"
    echo "PHP Version : ${PHP_VER}"
    echo "Log File    : ${LOG_FILE}"
    _green "--------------------------------------------------------\n"
    _green "Terima kasih telah menggunakan layanan Netbits.id\n"
}

main "$@"
