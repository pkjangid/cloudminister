#!/bin/bash
# ============================================================
#   CloudMinister WHM Complete Auto-Setup Script
#   Version: 1.0
#   Author:  CloudMinister DevOps Team
#
#   FLOW:
#     PHASE 1 → OS-Level Setup    (pre-license)
#     PHASE 2 → License Install   (vendor selection)
#     PHASE 3 → WHM Hardening     (post-license)
# ============================================================

set -euo pipefail

# ============================================================
# COLORS & LOGGING
# ============================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

LOG_FILE="/var/log/cloudminister-whm-setup.log"
exec > >(tee -a "$LOG_FILE") 2>&1

log_info()    { echo -e "${GREEN}[INFO]${NC}    $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}    $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC}   $1"; }
log_success() { echo -e "${GREEN}${BOLD}[✓ DONE]${NC}  $1"; }
log_phase()   {
    echo ""
    echo -e "${MAGENTA}${BOLD}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${MAGENTA}${BOLD}║  $1${NC}"
    echo -e "${MAGENTA}${BOLD}╚══════════════════════════════════════════════════╝${NC}"
    echo ""
}
log_section() {
    echo ""
    echo -e "${CYAN}┌─────────────────────────────────────────────────┐${NC}"
    echo -e "${CYAN}│  $1${NC}"
    echo -e "${CYAN}└─────────────────────────────────────────────────┘${NC}"
}

# ============================================================
# GLOBAL VARS FILE
# ============================================================
VARS_FILE="/root/.cloudminister_vars"
touch "$VARS_FILE"
source "$VARS_FILE" 2>/dev/null || true

# ============================================================
# PRE-FLIGHT CHECKS
# ============================================================
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root. Use: sudo bash $0"
        exit 1
    fi
}

print_banner() {
    clear
    echo -e "${CYAN}${BOLD}"
    echo "  ██████╗██╗      ██████╗ ██╗   ██╗██████╗ "
    echo " ██╔════╝██║     ██╔═══██╗██║   ██║██╔══██╗"
    echo " ██║     ██║     ██║   ██║██║   ██║██║  ██║"
    echo " ██║     ██║     ██║   ██║██║   ██║██║  ██║"
    echo " ╚██████╗███████╗╚██████╔╝╚██████╔╝██████╔╝"
    echo "  ╚═════╝╚══════╝ ╚═════╝  ╚═════╝ ╚═════╝ "
    echo -e "${NC}"
    echo -e "${BOLD}  CloudMinister WHM Complete Auto-Setup${NC}"
    echo -e "  Server: $(hostname) | IP: $(hostname -I | awk '{print $1}') | Date: $(date)"
    echo -e "  Log: $LOG_FILE"
    echo ""
}

# ============================================================
# ============================================================
#   PHASE 1 — OS LEVEL SETUP (PRE-LICENSE)
# ============================================================
# ============================================================

phase1_os_setup() {
    log_phase "PHASE 1 — OS Level Setup (Pre-License)"

    p1_install_base_packages
    p1_setup_sar
    p1_set_timezone
    p1_change_ssh_port
    p1_install_csf_firewall
    p1_install_mysql
    p1_configure_mysql
    p1_install_mysqltuner
    p1_rename_sendmail
    p1_setup_mysql_backup_cron
    p1_setup_maique_cron

    log_success "Phase 1 complete."
}

# ----------------------------------------------------------
# P1-1: BASE PACKAGES
# ----------------------------------------------------------
p1_install_base_packages() {
    log_section "P1-1 | Installing Base Packages"
    yum -y update
    yum -y install epel-release
    yum -y install htop iotop sysstat curl wget vim net-tools \
        lsof unzip git bash-completion screen tmux \
        bind-utils mlocate nmap-ncat telnet
    log_success "Base packages installed."
}

# ----------------------------------------------------------
# P1-2: SAR
# ----------------------------------------------------------
p1_setup_sar() {
    log_section "P1-2 | Setting up SAR (sysstat)"
    yum -y install sysstat
    systemctl enable sysstat
    systemctl start sysstat
    sed -i 's/^ENABLED="false"/ENABLED="true"/' /etc/default/sysstat 2>/dev/null || true
    log_success "SAR enabled and started."
}

# ----------------------------------------------------------
# P1-3: TIMEZONE
# ----------------------------------------------------------
p1_set_timezone() {
    log_section "P1-3 | Timezone Setup"
    echo ""
    echo "  1) Asia/Kolkata  (IST - Default)"
    echo "  2) UTC"
    echo "  3) America/New_York"
    echo "  4) Europe/London"
    echo "  5) Custom"
    echo ""
    read -rp "  Select timezone [1-5, default=1]: " TZ_CHOICE
    TZ_CHOICE=${TZ_CHOICE:-1}

    case "$TZ_CHOICE" in
        1) TZ_VAL="Asia/Kolkata" ;;
        2) TZ_VAL="UTC" ;;
        3) TZ_VAL="America/New_York" ;;
        4) TZ_VAL="Europe/London" ;;
        5) read -rp "  Enter timezone (e.g. Asia/Dubai): " TZ_VAL ;;
        *) TZ_VAL="Asia/Kolkata" ;;
    esac

    timedatectl set-timezone "$TZ_VAL"
    echo "TIMEZONE=$TZ_VAL" >> "$VARS_FILE"
    log_success "Timezone set to: $TZ_VAL"
}

# ----------------------------------------------------------
# P1-4: SSH PORT
# ----------------------------------------------------------
p1_change_ssh_port() {
    log_section "P1-4 | Changing SSH Port"
    echo ""
    read -rp "  Enter new SSH port [default: 2222]: " SSH_PORT
    SSH_PORT=${SSH_PORT:-2222}

    if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || [ "$SSH_PORT" -lt 1024 ] || [ "$SSH_PORT" -gt 65535 ]; then
        log_warn "Invalid port. Using 2222."
        SSH_PORT=2222
    fi

    sed -i "s/^#Port 22$/Port $SSH_PORT/" /etc/ssh/sshd_config
    sed -i "s/^Port 22$/Port $SSH_PORT/" /etc/ssh/sshd_config
    grep -q "^Port " /etc/ssh/sshd_config || echo "Port $SSH_PORT" >> /etc/ssh/sshd_config

    # SELinux
    if command -v semanage &>/dev/null; then
        semanage port -a -t ssh_port_t -p tcp "$SSH_PORT" 2>/dev/null || \
        semanage port -m -t ssh_port_t -p tcp "$SSH_PORT" 2>/dev/null || true
    fi

    systemctl restart sshd
    echo "SSH_PORT=$SSH_PORT" >> "$VARS_FILE"
    log_warn "SSH port changed to $SSH_PORT. Do NOT close this session until firewall allows it!"
    log_success "SSH port set to: $SSH_PORT"
}

# ----------------------------------------------------------
# P1-5: CSF FIREWALL
# ----------------------------------------------------------
p1_install_csf_firewall() {
    log_section "P1-5 | Installing & Configuring CSF Firewall"

    systemctl stop firewalld 2>/dev/null || true
    systemctl disable firewalld 2>/dev/null || true

    cd /tmp
    wget -q https://download.configserver.com/csf.tgz
    tar -xzf csf.tgz
    cd csf && sh install.sh

    source "$VARS_FILE" 2>/dev/null || true
    SSH_PORT=${SSH_PORT:-2222}

    # Testing mode OFF
    sed -i 's/^TESTING = "1"/TESTING = "0"/' /etc/csf/csf.conf

    # Ports
    sed -i 's/^TCP_IN = .*/TCP_IN = "20,21,22,'"$SSH_PORT"',25,53,80,110,143,443,465,587,993,995,2077,2078,2082,2083,2086,2087,2095,2096"/' /etc/csf/csf.conf
    sed -i 's/^TCP_OUT = .*/TCP_OUT = "20,21,22,'"$SSH_PORT"',25,53,80,110,113,443,587,993,995"/' /etc/csf/csf.conf
    sed -i 's/^UDP_IN = .*/UDP_IN = "20,21,53"/' /etc/csf/csf.conf
    sed -i 's/^UDP_OUT = .*/UDP_OUT = "20,21,53,113,123"/' /etc/csf/csf.conf

    # LFD (bruteforce)
    sed -i 's/^LF_DAEMON = "0"/LF_DAEMON = "1"/' /etc/csf/csf.conf

    # Fork bomb / process tracking
    sed -i 's/^PT_USERMEM = "0"/PT_USERMEM = "512"/' /etc/csf/csf.conf
    sed -i 's/^PT_USERTIME = "0"/PT_USERTIME = "1800"/' /etc/csf/csf.conf
    sed -i 's/^PT_LOAD = "0"/PT_LOAD = "30"/' /etc/csf/csf.conf
    sed -i 's/^PT_LOAD_ACTION = "0"/PT_LOAD_ACTION = "1"/' /etc/csf/csf.conf
    sed -i 's/^PT_ALL_USERS = "0"/PT_ALL_USERS = "1"/' /etc/csf/csf.conf
    sed -i 's/^PT_USERPROC = "0"/PT_USERPROC = "100"/' /etc/csf/csf.conf

    # SMTP block
    sed -i 's/^SMTP_BLOCK = "0"/SMTP_BLOCK = "1"/' /etc/csf/csf.conf
    sed -i 's/^SMTP_ALLOWLOCAL = "0"/SMTP_ALLOWLOCAL = "1"/' /etc/csf/csf.conf

    csf -a 0.0.0.0/0 tcp "$SSH_PORT" 2>/dev/null || true
    csf -r
    systemctl enable csf lfd

    log_success "CSF Firewall installed and configured."
}

# ----------------------------------------------------------
# P1-6: MYSQL INSTALL
# ----------------------------------------------------------
p1_install_mysql() {
    log_section "P1-6 | MySQL Installation"

    if ! command -v mysql &>/dev/null; then
        rpm -Uvh https://dev.mysql.com/get/mysql80-community-release-el7-7.noarch.rpm 2>/dev/null || true
        yum -y install mysql-community-server
        systemctl enable mysqld
        systemctl start mysqld
        TEMP_PASS=$(grep 'temporary password' /var/log/mysqld.log | awk '{print $NF}' | tail -1)
        echo "MYSQL_TEMP_PASS=$TEMP_PASS" >> "$VARS_FILE"
        log_warn "MySQL temp root password: $TEMP_PASS  (saved to $VARS_FILE)"
        log_success "MySQL installed."
    else
        log_warn "MySQL already installed. Skipping install."
    fi
}

# ----------------------------------------------------------
# P1-7: MYSQL CONFIG (my.cnf + sql_mode=NULL)
# ----------------------------------------------------------
p1_configure_mysql() {
    log_section "P1-7 | MySQL Optimization (my.cnf)"

    TOTAL_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
    INNODB_BUFFER=$((TOTAL_RAM_MB * 70 / 100))M
    INNODB_LOG=$((TOTAL_RAM_MB * 10 / 100))M

    # Avoid duplicate block if re-run
    if ! grep -q "CloudMinister MySQL" /etc/my.cnf 2>/dev/null; then
        cat >> /etc/my.cnf << EOF

# ---- CloudMinister MySQL Optimisation ----
[mysqld]
sql_mode                       = ""
innodb_buffer_pool_size        = $INNODB_BUFFER
innodb_log_file_size           = $INNODB_LOG
innodb_flush_log_at_trx_commit = 2
innodb_flush_method            = O_DIRECT
max_connections                = 500
thread_cache_size              = 50
query_cache_type               = 0
query_cache_size               = 0
tmp_table_size                 = 64M
max_heap_table_size            = 64M
slow_query_log                 = 1
slow_query_log_file            = /var/log/mysql-slow.log
long_query_time                = 2
EOF
    fi

    systemctl restart mysqld 2>/dev/null || true
    log_success "MySQL configured. sql_mode=NULL | innodb_buffer=$INNODB_BUFFER"
}

# ----------------------------------------------------------
# P1-8: MYSQLTUNER
# ----------------------------------------------------------
p1_install_mysqltuner() {
    log_section "P1-8 | Installing MySQLTuner"
    curl -sL https://raw.githubusercontent.com/major/MySQLTuner-perl/master/mysqltuner.pl \
        -o /usr/local/bin/mysqltuner
    chmod +x /usr/local/bin/mysqltuner
    log_success "MySQLTuner installed. Run after 24hrs: mysqltuner"
}

# ----------------------------------------------------------
# P1-9: SENDMAIL RENAME
# ----------------------------------------------------------
p1_rename_sendmail() {
    log_section "P1-9 | Renaming Sendmail Binary"
    for SPATH in /usr/sbin/sendmail /usr/lib/sendmail /usr/local/bin/sendmail; do
        if [ -f "$SPATH" ] && [ ! -f "${SPATH}.disabled" ]; then
            mv "$SPATH" "${SPATH}.disabled"
            log_success "Renamed: $SPATH → ${SPATH}.disabled"
        fi
    done
    log_warn "Any remaining sendmail binaries will be handled post-cPanel install (Phase 3)."
}

# ----------------------------------------------------------
# P1-10: MYSQL BACKUP CRON (from Git)
# ----------------------------------------------------------
p1_setup_mysql_backup_cron() {
    log_section "P1-10 | MySQL Backup Cron (from Git)"
    echo ""
    read -rp "  Enter MySQL backup script Git URL [Enter to skip]: " GIT_BACKUP_URL

    if [ -n "$GIT_BACKUP_URL" ]; then
        mkdir -p /opt/cloudminister/scripts
        git clone "$GIT_BACKUP_URL" /opt/cloudminister/scripts/mysql-backup 2>&1
        BACKUP_SCRIPT=$(find /opt/cloudminister/scripts/mysql-backup -name "*.sh" | head -1)

        if [ -n "$BACKUP_SCRIPT" ]; then
            chmod +x "$BACKUP_SCRIPT"
            (crontab -l 2>/dev/null; echo "0 12 * * * $BACKUP_SCRIPT >> /var/log/mysql-backup.log 2>&1") | crontab -
            log_success "MySQL backup cron: daily 12:00 → $BACKUP_SCRIPT"
        else
            log_warn "No .sh found in repo. Add cron manually later."
        fi
    else
        log_warn "MySQL backup cron skipped."
    fi
}

# ----------------------------------------------------------
# P1-11: MAIQUE CRON (from Git)
# ----------------------------------------------------------
p1_setup_maique_cron() {
    log_section "P1-11 | Maique Script Cron (from Git)"
    echo ""
    read -rp "  Enter Maique script Git URL [Enter to skip]: " GIT_MAIQUE_URL

    if [ -n "$GIT_MAIQUE_URL" ]; then
        mkdir -p /opt/cloudminister/scripts
        git clone "$GIT_MAIQUE_URL" /opt/cloudminister/scripts/maique 2>&1
        MAIQUE_SCRIPT=$(find /opt/cloudminister/scripts/maique -name "*.sh" | head -1)

        if [ -n "$MAIQUE_SCRIPT" ]; then
            chmod +x "$MAIQUE_SCRIPT"
            (crontab -l 2>/dev/null; echo "0 12 * * * $MAIQUE_SCRIPT >> /var/log/maique.log 2>&1") | crontab -
            log_success "Maique cron: daily 12:00 → $MAIQUE_SCRIPT"
        else
            log_warn "No .sh found in repo. Add cron manually later."
        fi
    else
        log_warn "Maique cron skipped."
    fi
}


# ============================================================
# ============================================================
#   PHASE 2 — LICENSE INSTALLATION
# ============================================================
# ============================================================

phase2_license() {
    log_phase "PHASE 2 — cPanel/WHM License Installation"

    p2_wait_for_cpanel
    p2_select_vendor
}

# ----------------------------------------------------------
# P2-1: WAIT FOR CPANEL
# ----------------------------------------------------------
p2_wait_for_cpanel() {
    log_section "P2-1 | Checking cPanel Installation"

    if [ ! -f /usr/local/cpanel/cpanel ]; then
        echo ""
        log_warn "cPanel/WHM is NOT yet installed on this server."
        echo ""
        echo -e "  ${YELLOW}Install cPanel first using:${NC}"
        echo -e "  ${BOLD}cd /home && curl -o latest -L https://securedownloads.cpanel.net/latest && sh latest${NC}"
        echo ""
        read -rp "  Have you already installed cPanel? Press [y] to continue or [n] to exit: " CPANEL_READY
        if [[ "$CPANEL_READY" != "y" && "$CPANEL_READY" != "Y" ]]; then
            log_error "Please install cPanel first, then re-run this script and select Phase 2 or 3."
            exit 1
        fi

        # Re-check
        if [ ! -f /usr/local/cpanel/cpanel ]; then
            log_error "cPanel still not detected at /usr/local/cpanel/cpanel. Exiting."
            exit 1
        fi
    fi

    log_success "cPanel/WHM detected."
}

# ----------------------------------------------------------
# P2-2: LICENSE VENDOR MENU
# ----------------------------------------------------------
p2_select_vendor() {
    log_section "P2-2 | Select License Vendor"
    echo ""
    echo "  ┌──────────────────────────────────────────┐"
    echo "  │  1) Sumit License     (easyconfig.net)   │"
    echo "  │  2) License Monster   (licensemonster)   │"
    echo "  │  3) WHM IP Trial      (cPanel Direct)    │"
    echo "  └──────────────────────────────────────────┘"
    echo ""
    read -rp "  Select vendor [1-3]: " VENDOR_CHOICE

    case "$VENDOR_CHOICE" in
        1) p2_install_sumit ;;
        2) p2_install_licensemonster ;;
        3) p2_install_whm_trial ;;
        *)
            log_error "Invalid choice. Exiting."
            exit 1
            ;;
    esac
}

# ----------------------------------------------------------
# P2 OPTION 1: SUMIT LICENSE
# ----------------------------------------------------------
p2_install_sumit() {
    log_section "P2 | Sumit License (easyconfig.net)"

    log_info "[1/3] Running Sumit installer..."
    if curl -4 -sL https://data.easyconfig.net/installer.sh | bash -; then
        log_success "Sumit installer completed."
    else
        log_error "Sumit installer FAILED."
        log_error "Fix: Check internet, or contact Sumit support. Log: $LOG_FILE"
        exit 1
    fi

    log_info "[2/3] Enabling cPanel license..."
    if licsys cpanel enable; then
        log_success "License enabled."
    else
        log_error "licsys cpanel enable FAILED."
        log_error "Reason: Invalid key / IP mismatch / account suspended."
        log_error "Contact Sumit support with log: $LOG_FILE"
        exit 1
    fi

    log_info "[3/3] Updating license..."
    if licsys cpanel update; then
        log_success "License updated."
    else
        log_error "licsys cpanel update FAILED. Log: $LOG_FILE"
        exit 1
    fi

    p2_verify_license
}

# ----------------------------------------------------------
# P2 OPTION 2: LICENSE MONSTER
# ----------------------------------------------------------
p2_install_licensemonster() {
    log_section "P2 | License Monster"

    log_info "[1/3] Downloading License Monster installer..."
    if curl -L -o /tmp/lm-installer "https://licensemonster.xyz/lic/cpanel/installer?key=cpanel"; then
        log_success "Installer downloaded."
    else
        log_error "Download FAILED. Check URL or License Monster support."
        exit 1
    fi

    log_info "[2/3] Setting permissions..."
    chmod +x /tmp/lm-installer

    log_info "[3/3] Running installer..."
    if /tmp/lm-installer; then
        log_success "License Monster installed."
        rm -f /tmp/lm-installer
    else
        log_error "License Monster installer FAILED."
        log_error "Check license key and server IP. Log: $LOG_FILE"
        rm -f /tmp/lm-installer
        exit 1
    fi

    p2_verify_license
}

# ----------------------------------------------------------
# P2 OPTION 3: WHM IP TRIAL
# ----------------------------------------------------------
p2_install_whm_trial() {
    log_section "P2 | WHM IP-Based Trial (Direct from cPanel)"

    log_info "Running cpkeyclt..."
    if /usr/local/cpanel/cpkeyclt; then
        log_success "IP-based trial license activated."
    else
        log_error "cpkeyclt FAILED."
        log_error "Reasons: IP already used trial | network issue | cPanel not fully installed."
        log_error "Manual check: https://verify.cpanel.net"
        exit 1
    fi

    p2_verify_license
}

# ----------------------------------------------------------
# P2: VERIFY LICENSE
# ----------------------------------------------------------
p2_verify_license() {
    log_section "P2 | Verifying License"
    sleep 5

    log_info "Restarting cPanel services..."
    /scripts/restartsrv_cpsrvd 2>/dev/null || true
    sleep 3

    if curl -sk --max-time 10 https://localhost:2087 | grep -qi "whm\|cpanel\|login" 2>/dev/null; then
        log_success "WHM responding on port 2087 — LICENSE ACTIVE."
    else
        log_warn "WHM not responding yet. May take a few minutes."
        log_warn "Check manually: https://$(hostname -I | awk '{print $1}'):2087"
    fi
}


# ============================================================
# ============================================================
#   PHASE 3 — POST-LICENSE WHM HARDENING & INSTALL
# ============================================================
# ============================================================

phase3_whm_setup() {
    log_phase "PHASE 3 — WHM Hardening & Configuration (Post-License)"

    p3_check_whmapi

    p3_tmp_security
    p3_bruteforce
    p3_fork_bomb
    p3_disable_compiler
    p3_greylisting
    p3_jailed_shell
    p3_process_killer
    p3_contact_manager
    p3_backup
    p3_smtp_restriction
    p3_rename_sendmail_post
    p3_antivirus
    p3_ftp_server
    p3_easyapache
    p3_php_limits
    p3_phpfpm_limits
    p3_apache_optimization
    p3_autossl

    p3_print_summary
}

# ----------------------------------------------------------
# P3 CHECK
# ----------------------------------------------------------
p3_check_whmapi() {
    log_section "P3 | Checking WHM API Access"
    if [ ! -f /usr/local/cpanel/bin/whmapi1 ]; then
        log_error "whmapi1 not found. cPanel may not be fully installed or licensed."
        exit 1
    fi
    log_success "whmapi1 available."
}

whmapi() { /usr/local/cpanel/bin/whmapi1 "$@" 2>/dev/null || true; }

# ----------------------------------------------------------
# P3-1: TMP SECURITY
# ----------------------------------------------------------
p3_tmp_security() {
    log_section "P3-1 | TMP Security"

    if ! grep -q "tmpfs /tmp" /etc/fstab; then
        echo "tmpfs /tmp tmpfs defaults,noexec,nosuid,nodev,size=512m 0 0" >> /etc/fstab
        mount -o remount /tmp 2>/dev/null || true
    else
        mount -o remount,noexec,nosuid,nodev /tmp 2>/dev/null || true
    fi

    # Bind /var/tmp → /tmp
    if ! grep -q "/var/tmp" /etc/fstab; then
        echo "/tmp /var/tmp none bind 0 0" >> /etc/fstab
        mount --bind /tmp /var/tmp 2>/dev/null || true
    fi

    log_success "/tmp secured with noexec,nosuid,nodev."
}

# ----------------------------------------------------------
# P3-2: BRUTEFORCE (cPHulk)
# ----------------------------------------------------------
p3_bruteforce() {
    log_section "P3-2 | Bruteforce Protection (cPHulk)"
    whmapi configureservice service=cphulkd enabled=1 monitored=1
    whmapi set_tweaksetting key=cphulk value=1
    /scripts/restartsrv_cphulkd 2>/dev/null || true
    log_success "cPHulk bruteforce protection enabled."
}

# ----------------------------------------------------------
# P3-3: FORK BOMB
# ----------------------------------------------------------
p3_fork_bomb() {
    log_section "P3-3 | Fork Bomb Protection"

    if ! grep -q "CloudMinister Fork Bomb" /etc/security/limits.conf; then
        cat >> /etc/security/limits.conf << 'EOF'
# CloudMinister Fork Bomb Protection
*       soft    nproc   100
*       hard    nproc   200
nobody  soft    nproc   100
nobody  hard    nproc   200
EOF
    fi

    log_success "Fork bomb protection enabled (nproc: 100 soft / 200 hard)."
}

# ----------------------------------------------------------
# P3-4: COMPILER DISABLE
# ----------------------------------------------------------
p3_disable_compiler() {
    log_section "P3-4 | Disable Compiler Access"
    whmapi set_tweaksetting key=compilercheck value=1
    /scripts/compilercheck --enable 2>/dev/null || true
    for BIN in /usr/bin/gcc /usr/bin/cc /usr/bin/g++; do
        [ -f "$BIN" ] && chmod 0700 "$BIN" && chown root:root "$BIN" 2>/dev/null || true
    done
    log_success "Compiler access disabled for non-root users."
}

# ----------------------------------------------------------
# P3-5: GREYLISTING
# ----------------------------------------------------------
p3_greylisting() {
    log_section "P3-5 | Greylisting"
    whmapi set_tweaksetting key=greylisting value=1
    /scripts/restartsrv_exim 2>/dev/null || true
    log_success "Greylisting enabled."
}

# ----------------------------------------------------------
# P3-6: JAILED SHELL
# ----------------------------------------------------------
p3_jailed_shell() {
    log_section "P3-6 | Jailed Shell"
    whmapi set_tweaksetting key=jailedshells value=1
    /scripts/restartsrv_sshd 2>/dev/null || true
    if command -v cagefsctl &>/dev/null; then
        cagefsctl --enable-all
        log_success "CageFS enabled for all users."
    else
        log_warn "CageFS not installed. Built-in jailed shell only."
    fi
    log_success "Jailed shell enabled."
}

# ----------------------------------------------------------
# P3-7: BACKGROUND PROCESS KILLER
# ----------------------------------------------------------
p3_process_killer() {
    log_section "P3-7 | Background Process Killer"
    whmapi set_tweaksetting key=proc_watch value=1
    if [ -f /etc/csf/csf.conf ]; then
        sed -i 's/^PT_SKIP_HTTP = "1"/PT_SKIP_HTTP = "0"/' /etc/csf/csf.conf
        csf -r 2>/dev/null || true
    fi
    log_success "Background process killer enabled."
}

# ----------------------------------------------------------
# P3-8: CONTACT MANAGER
# ----------------------------------------------------------
p3_contact_manager() {
    log_section "P3-8 | Contact Manager"
    echo ""
    read -rp "  Enter admin notification email: " ADMIN_EMAIL

    if [[ "$ADMIN_EMAIL" =~ ^[^@]+@[^@]+\.[^@]+$ ]]; then
        whmapi set_tweaksetting key=contactpager value="$ADMIN_EMAIL"
        whmapi set_tweaksetting key=contactemail value="$ADMIN_EMAIL"
        log_success "Admin contact email set: $ADMIN_EMAIL"
    else
        log_warn "Invalid email format. Skipping contact setup."
    fi
}

# ----------------------------------------------------------
# P3-9: BACKUP (auto-sized)
# ----------------------------------------------------------
p3_backup() {
    log_section "P3-9 | Backup Configuration (Auto-Sized)"

    DISK_SIZE_GB=$(df -BG / | awk 'NR==2{print $2}' | tr -d 'G')
    log_info "Detected disk: ${DISK_SIZE_GB}GB"

    if   [ "$DISK_SIZE_GB" -ge 500 ]; then RETENTION=7;  DAILY=1; WEEKLY=1; MONTHLY=1
    elif [ "$DISK_SIZE_GB" -ge 200 ]; then RETENTION=3;  DAILY=1; WEEKLY=1; MONTHLY=0
    else                                   RETENTION=1;  DAILY=1; WEEKLY=0; MONTHLY=0
    fi

    whmapi backup_config_set \
        backup_enable=1 \
        backup_daily_enable="$DAILY" \
        backup_weekly_enable="$WEEKLY" \
        backup_monthly_enable="$MONTHLY" \
        backup_retention="$RETENTION" \
        backup_type=compressed \
        backup_destination=local

    log_success "Backup configured: retention=${RETENTION}d | daily=${DAILY} | weekly=${WEEKLY} | monthly=${MONTHLY}"
}

# ----------------------------------------------------------
# P3-10: SMTP RESTRICTION
# ----------------------------------------------------------
p3_smtp_restriction() {
    log_section "P3-10 | SMTP Restriction"
    whmapi set_tweaksetting key=smtpmailgidonly value=1
    whmapi set_tweaksetting key=skipsmtpchecks value=0
    if [ -f /etc/csf/csf.conf ]; then
        sed -i 's/^SMTP_BLOCK = "0"/SMTP_BLOCK = "1"/' /etc/csf/csf.conf
        csf -r 2>/dev/null || true
    fi
    log_success "SMTP restriction enabled."
}

# ----------------------------------------------------------
# P3-11: SENDMAIL RENAME (post cPanel)
# ----------------------------------------------------------
p3_rename_sendmail_post() {
    log_section "P3-11 | Sendmail Rename (Post-cPanel)"
    for SPATH in /usr/sbin/sendmail /usr/lib/sendmail /usr/local/bin/sendmail; do
        if [ -f "$SPATH" ] && [ ! -f "${SPATH}.disabled" ]; then
            mv "$SPATH" "${SPATH}.disabled"
            log_success "Renamed: $SPATH → ${SPATH}.disabled"
        fi
    done
    log_success "Sendmail binary disabled."
}

# ----------------------------------------------------------
# P3-12: ANTIVIRUS
# ----------------------------------------------------------
p3_antivirus() {
    log_section "P3-12 | Antivirus Selection"
    echo ""
    echo "  1) Imunify360"
    echo "  2) BitNinja"
    echo "  3) Skip (install manually later)"
    echo ""
    read -rp "  Select [1-3]: " AV_CHOICE

    case "$AV_CHOICE" in
        1)
            log_info "Installing Imunify360..."
            wget -q https://repo.imunify360.cloudlinux.com/defence360/imunify-antivirus/v6/i360deploy.sh -O /tmp/i360deploy.sh
            chmod +x /tmp/i360deploy.sh
            bash /tmp/i360deploy.sh
            log_warn "Imunify360 needs a separate license. Activate: WHM → Imunify360"
            log_success "Imunify360 installed."
            ;;
        2)
            log_info "Installing BitNinja..."
            curl https://get.bitninja.io/install.sh | bash
            log_warn "BitNinja needs a separate license. Run: bitninja-setup"
            log_success "BitNinja installed."
            ;;
        3) log_warn "Antivirus skipped." ;;
        *) log_warn "Invalid choice. Skipped." ;;
    esac
}

# ----------------------------------------------------------
# P3-13: FTP SERVER
# ----------------------------------------------------------
p3_ftp_server() {
    log_section "P3-13 | FTP Server Selection"
    echo ""
    echo "  1) Pure-FTPd (recommended)"
    echo "  2) ProFTPd"
    echo ""
    read -rp "  Select [1-2, default=1]: " FTP_CHOICE
    FTP_CHOICE=${FTP_CHOICE:-1}

    case "$FTP_CHOICE" in
        1)
            whmapi set_tweaksetting key=ftpserver value=pure-ftpd
            /scripts/setupftpserver pure-ftpd --force 2>/dev/null || true
            log_success "Pure-FTPd selected."
            ;;
        2)
            whmapi set_tweaksetting key=ftpserver value=proftpd
            /scripts/setupftpserver proftpd --force 2>/dev/null || true
            log_success "ProFTPd selected."
            ;;
        *) log_warn "Invalid choice. Keeping default." ;;
    esac
}

# ----------------------------------------------------------
# P3-14: EASYAPACHE4
# ----------------------------------------------------------
p3_easyapache() {
    log_section "P3-14 | EasyApache4 + PHP Setup"
    log_info "Installing PHP 7.4, 8.1, 8.2 with common extensions..."

    yum -y install \
        ea-apache24 ea-apache24-mod_ssl ea-apache24-mod_deflate \
        ea-apache24-mod_headers ea-apache24-mod_rewrite \
        ea-php74 ea-php74-php-fpm ea-php74-php-cli ea-php74-php-common \
        ea-php74-php-mysqlnd ea-php74-php-mbstring ea-php74-php-xml \
        ea-php74-php-curl ea-php74-php-gd ea-php74-php-zip ea-php74-php-bcmath \
        ea-php81 ea-php81-php-fpm ea-php81-php-cli ea-php81-php-common \
        ea-php81-php-mysqlnd ea-php81-php-mbstring ea-php81-php-xml \
        ea-php81-php-curl ea-php81-php-gd ea-php81-php-zip ea-php81-php-bcmath \
        ea-php82 ea-php82-php-fpm ea-php82-php-cli ea-php82-php-common \
        ea-php82-php-mysqlnd ea-php82-php-mbstring ea-php82-php-xml \
        ea-php82-php-curl ea-php82-php-gd ea-php82-php-zip ea-php82-php-bcmath \
        2>&1 || true

    /scripts/restartsrv_apache 2>/dev/null || true
    log_success "EasyApache4 installed: PHP 7.4, 8.1, 8.2."
}

# ----------------------------------------------------------
# P3-15: PHP LIMITS
# ----------------------------------------------------------
p3_php_limits() {
    log_section "P3-15 | PHP Limits Increase"

    for VER in ea-php74 ea-php81 ea-php82; do
        PHP_DIR="/opt/cpanel/${VER}/root/etc/php.d"
        if [ -d "$PHP_DIR" ]; then
            cat > "$PHP_DIR/99-cloudminister.ini" << 'EOF'
; CloudMinister PHP Limits
memory_limit        = 512M
upload_max_filesize = 256M
post_max_size       = 256M
max_execution_time  = 300
max_input_time      = 300
max_input_vars      = 10000
EOF
            log_success "PHP limits applied: $PHP_DIR"
        fi
    done

    /scripts/restartsrv_apache 2>/dev/null || true
}

# ----------------------------------------------------------
# P3-16: PHP-FPM LIMITS
# ----------------------------------------------------------
p3_phpfpm_limits() {
    log_section "P3-16 | PHP-FPM Pool Tuning"

    for VER in ea-php74 ea-php81 ea-php82; do
        FPM_DIR="/opt/cpanel/${VER}/root/etc/php-fpm.d"
        if [ -d "$FPM_DIR" ]; then
            find "$FPM_DIR" -name "*.conf" | while read -r POOL_CONF; do
                sed -i 's/^pm.max_children = .*/pm.max_children = 50/'       "$POOL_CONF" 2>/dev/null || true
                sed -i 's/^pm.start_servers = .*/pm.start_servers = 10/'     "$POOL_CONF" 2>/dev/null || true
                sed -i 's/^pm.min_spare_servers = .*/pm.min_spare_servers = 5/' "$POOL_CONF" 2>/dev/null || true
                sed -i 's/^pm.max_spare_servers = .*/pm.max_spare_servers = 20/' "$POOL_CONF" 2>/dev/null || true
                log_success "PHP-FPM tuned: $POOL_CONF"
            done
        fi
    done
}

# ----------------------------------------------------------
# P3-17: APACHE OPTIMISATION
# ----------------------------------------------------------
p3_apache_optimization() {
    log_section "P3-17 | Apache Global Optimisation"
    mkdir -p /etc/apache2/conf.d

    cat > /etc/apache2/conf.d/99-cloudminister.conf << 'EOF'
# CloudMinister Apache Optimisation
ServerTokens Prod
ServerSignature Off
TraceEnable Off
Timeout 300
KeepAlive On
MaxKeepAliveRequests 100
KeepAliveTimeout 5

<IfModule mpm_event_module>
    StartServers            4
    MinSpareThreads         25
    MaxSpareThreads         75
    ThreadLimit             64
    ThreadsPerChild         25
    MaxRequestWorkers       200
    MaxConnectionsPerChild  1000
</IfModule>

<IfModule mod_deflate.c>
    AddOutputFilterByType DEFLATE text/html text/plain text/xml text/css
    AddOutputFilterByType DEFLATE text/javascript application/javascript application/json
</IfModule>
EOF

    /scripts/restartsrv_apache 2>/dev/null || true
    log_success "Apache optimisation applied."
}

# ----------------------------------------------------------
# P3-18: AUTOSSL
# ----------------------------------------------------------
p3_autossl() {
    log_section "P3-18 | AutoSSL Setup"
    whmapi set_autossl_metadata provider=cPanel 2>/dev/null || true
    whmapi enable_autossl_for_all_users 2>/dev/null || true
    /scripts/autossl_check --all 2>/dev/null &
    log_success "AutoSSL enabled (cPanel provider). Running in background..."
}

# ----------------------------------------------------------
# P3 SUMMARY
# ----------------------------------------------------------
p3_print_summary() {
    echo ""
    log_phase "✅  ALL PHASES COMPLETE — CloudMinister WHM Setup"
    echo ""
    echo -e "  ${BOLD}Phase 1 - OS Setup${NC}"
    echo -e "  ${GREEN}✓${NC} Base packages + htop + SAR"
    echo -e "  ${GREEN}✓${NC} SSH port changed"
    echo -e "  ${GREEN}✓${NC} CSF Firewall (bruteforce + SMTP + fork bomb)"
    echo -e "  ${GREEN}✓${NC} MySQL installed + optimized (sql_mode=NULL)"
    echo -e "  ${GREEN}✓${NC} MySQLTuner installed"
    echo -e "  ${GREEN}✓${NC} Sendmail binary renamed"
    echo -e "  ${GREEN}✓${NC} Timezone set"
    echo -e "  ${GREEN}✓${NC} MySQL backup cron"
    echo -e "  ${GREEN}✓${NC} Maique cron"
    echo ""
    echo -e "  ${BOLD}Phase 2 - License${NC}"
    echo -e "  ${GREEN}✓${NC} cPanel license installed & verified"
    echo ""
    echo -e "  ${BOLD}Phase 3 - WHM Hardening${NC}"
    echo -e "  ${GREEN}✓${NC} TMP security (noexec/nosuid)"
    echo -e "  ${GREEN}✓${NC} cPHulk bruteforce enabled"
    echo -e "  ${GREEN}✓${NC} Fork bomb protection"
    echo -e "  ${GREEN}✓${NC} Compiler access disabled"
    echo -e "  ${GREEN}✓${NC} Greylisting enabled"
    echo -e "  ${GREEN}✓${NC} Jailed shell"
    echo -e "  ${GREEN}✓${NC} Background process killer"
    echo -e "  ${GREEN}✓${NC} Contact manager"
    echo -e "  ${GREEN}✓${NC} Backup configured (auto-sized)"
    echo -e "  ${GREEN}✓${NC} SMTP restriction"
    echo -e "  ${GREEN}✓${NC} Sendmail renamed"
    echo -e "  ${GREEN}✓${NC} Antivirus"
    echo -e "  ${GREEN}✓${NC} FTP server"
    echo -e "  ${GREEN}✓${NC} EasyApache4 + PHP 7.4 / 8.1 / 8.2"
    echo -e "  ${GREEN}✓${NC} PHP limits increased"
    echo -e "  ${GREEN}✓${NC} PHP-FPM tuned"
    echo -e "  ${GREEN}✓${NC} Apache optimised"
    echo -e "  ${GREEN}✓${NC} AutoSSL enabled"
    echo ""
    echo -e "  ${YELLOW}⚠ Reminders:${NC}"
    echo -e "  → Run MySQLTuner after 24hrs:  ${BOLD}mysqltuner${NC}"
    echo -e "  → Activate Imunify360/BitNinja license if selected"
    echo -e "  → WHM Panel: ${BOLD}https://$(hostname -I | awk '{print $1}'):2087${NC}"
    echo -e "  → Full log:  ${BOLD}$LOG_FILE${NC}"
    echo ""
}


# ============================================================
# ============================================================
#   MAIN — ENTRY POINT
# ============================================================
# ============================================================

main() {
    check_root
    print_banner

    echo -e "  ${BOLD}Select where to start:${NC}"
    echo ""
    echo "  1) Run ALL phases  (1 → 2 → 3)  — Fresh server"
    echo "  2) Phase 1 only    (OS Setup)    — Pre-license"
    echo "  3) Phase 2 only    (License)     — cPanel already installed"
    echo "  4) Phase 3 only    (WHM Setup)   — License already active"
    echo "  5) Phase 2 + 3     (License → WHM Setup)"
    echo ""
    read -rp "  Select [1-5]: " RUN_CHOICE

    case "$RUN_CHOICE" in
        1)
            phase1_os_setup
            phase2_license
            phase3_whm_setup
            ;;
        2)
            phase1_os_setup
            ;;
        3)
            phase2_license
            ;;
        4)
            phase3_whm_setup
            ;;
        5)
            phase2_license
            phase3_whm_setup
            ;;
        *)
            log_error "Invalid choice. Exiting."
            exit 1
            ;;
    esac
}

main "$@"
