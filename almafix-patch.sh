#!/bin/bash
# ============================================================
# Server Hardening Script - CloudMinister DevOps Team
# Compatible: AlmaLinux 8/9, CentOS, RHEL, Ubuntu/Debian
# Tasks:
#   1. Add WHM Host Access Control List rules
#   2. Change SSH port to 22587
#   3. Block malicious IPs via CSF
#   4. Remove ~/.ssh/authorized_keys
#   5. Set random 20-character root password
# ============================================================

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()    { echo -e "${GREEN}[✔] $1${NC}"; }
warn()   { echo -e "${YELLOW}[!] $1${NC}"; }
error()  { echo -e "${RED}[✘] $1${NC}"; }
section(){ echo -e "\n${BLUE}========== $1 ==========${NC}"; }

# Must run as root
if [[ $EUID -ne 0 ]]; then
  error "This script must be run as root."
  exit 1
fi

# ============================================================
# SECTION 0: Run cPanel Firewall Configuration (AlmaLinux)
# Must run before Host Access Control to ensure firewall rules
# are in place before TCP Wrappers restrictions are applied
# ============================================================
section "cPanel Firewall Configuration"

if [[ -f /scripts/configure_firewall_for_cpanel ]]; then
  if /scripts/configure_firewall_for_cpanel; then
    log "cPanel firewall configured successfully"
  else
    warn "configure_firewall_for_cpanel exited with errors — continuing anyway"
  fi
else
  warn "/scripts/configure_firewall_for_cpanel not found — skipping (non-cPanel or path missing)"
fi

# ============================================================
# SECTION 1: WHM Host Access Control
# AlmaLinux 8/9: Uses nftables (port-based) via whmapi1
# Ports: 22587=SSH, 2087=WHM, 2083=cPanel, 2086=cPanel (non-SSL)
# Allow: 3.111.17.14 (CM IP), 65.1.28.228 (BM VPN IP), 163.227.92.110 (Client IP)
# Deny:  ALL others
# ============================================================
section "WHM Host Access Control List Rules (nftables/port-based)"

CM_IP="3.111.17.14"
BM_VPN_IP="65.1.28.228"
CLIENT_IP="163.227.92.110"

ALLOWED_IPS=("$CM_IP" "$BM_VPN_IP" "$CLIENT_IP")

# Port map: port => description
# 22587 = SSH (custom port set above)
# 2087  = WHM (whostmgrd)
# 2083  = cPanel SSL (cpaneld)
# 2086  = cPanel non-SSL (cpaneld)
# 2082  = cPanel non-SSL alt
declare -A PORT_LABELS
PORT_LABELS[22587]="SSH"
PORT_LABELS[2087]="WHM"
PORT_LABELS[2083]="cPanel SSL"
PORT_LABELS[2086]="cPanel non-SSL"
PORT_LABELS[2082]="cPanel non-SSL alt"

PORTS=(22587 2087 2083 2086 2082)

if command -v whmapi1 &>/dev/null; then
  log "AlmaLinux detected — applying port-based Host Access Control via whmapi1"

  # Clear all existing HAC rules first to avoid duplicates
  EXISTING_JSON=$(whmapi1 --output=json hostaccess listrules 2>/dev/null || echo "")
  if echo "$EXISTING_JSON" | grep -q '"handle"'; then
    HANDLES=$(echo "$EXISTING_JSON" | grep -oP '"handle"\s*:\s*"\K[^"]+' 2>/dev/null || true)
    for handle in $HANDLES; do
      whmapi1 hostaccess delrule handle="$handle" &>/dev/null || true
    done
    log "Cleared existing HAC rules"
  else
    log "No existing HAC rules to clear"
  fi

  # For each port: add ACCEPT for each whitelisted IP, then DROP for all others
  for port in "${PORTS[@]}"; do
    label="${PORT_LABELS[$port]}"

    for ip in "${ALLOWED_IPS[@]}"; do
      if whmapi1 hostaccess addrule port="$port" host="$ip" protocol="tcp" action="ACCEPT" &>/dev/null; then
        log "ACCEPT port $port ($label) : $ip"
      else
        warn "Failed ACCEPT port $port : $ip"
      fi
    done

    # DROP all others on this port (must come after ACCEPT rules)
    if whmapi1 hostaccess addrule port="$port" host="0.0.0.0/0" protocol="tcp" action="DROP" &>/dev/null; then
      log "DROP   port $port ($label) : ALL others"
    else
      warn "Failed DROP on port $port"
    fi

  done

  log "Host Access Control rules applied — verify in WHM > Security Center > Host Access Control"

else
  # Fallback: Ubuntu/Debian with tcp_wrappers
  warn "whmapi1 not found — falling back to hosts.allow/hosts.deny"

  DAEMONS=("whostmgrd" "cpaneld" "sshd")
  HOSTS_ALLOW="/etc/hosts.allow"
  HOSTS_DENY="/etc/hosts.deny"
  touch "$HOSTS_ALLOW" "$HOSTS_DENY"

  cp "$HOSTS_ALLOW" "${HOSTS_ALLOW}.bak.$(date +%F-%H%M%S)" 2>/dev/null || true
  cp "$HOSTS_DENY"  "${HOSTS_DENY}.bak.$(date +%F-%H%M%S)"  2>/dev/null || true

  sed -i '/# BEGIN CloudMinister HAC Rules/,/# END CloudMinister HAC Rules/d' "$HOSTS_ALLOW"
  sed -i '/# BEGIN CloudMinister HAC Rules/,/# END CloudMinister HAC Rules/d' "$HOSTS_DENY"

  {
    echo ""
    echo "# BEGIN CloudMinister HAC Rules"
    for daemon in "${DAEMONS[@]}"; do
      echo "$daemon : $CM_IP    : allow   # CM IP"
      echo "$daemon : $BM_VPN_IP : allow   # BM VPN IP"
      echo "$daemon : $CLIENT_IP : allow   # Client IP"
    done
    echo "# END CloudMinister HAC Rules"
  } >> "$HOSTS_ALLOW"

  {
    echo ""
    echo "# BEGIN CloudMinister HAC Rules"
    for daemon in "${DAEMONS[@]}"; do
      echo "$daemon : ALL : deny"
    done
    echo "# END CloudMinister HAC Rules"
  } >> "$HOSTS_DENY"

  log "hosts.allow / hosts.deny rules written"
fi

# ============================================================
# SECTION 2: Change SSH Port to 22587
# ============================================================
section "Changing SSH Port to 22587"

SSHD_CONFIG="/etc/ssh/sshd_config"
NEW_SSH_PORT=22587

cp "$SSHD_CONFIG" "${SSHD_CONFIG}.bak.$(date +%F-%H%M%S)"

# Replace or insert Port directive
if grep -qE "^#?Port " "$SSHD_CONFIG"; then
  sed -i "s/^#\?Port .*/Port $NEW_SSH_PORT/" "$SSHD_CONFIG"
else
  echo "Port $NEW_SSH_PORT" >> "$SSHD_CONFIG"
fi

log "SSH port set to $NEW_SSH_PORT in $SSHD_CONFIG"

# SELinux: allow new SSH port (AlmaLinux/RHEL has SELinux enabled by default)
if command -v semanage &>/dev/null; then
  if ! semanage port -l 2>/dev/null | grep -q "${NEW_SSH_PORT}.*ssh"; then
    semanage port -a -t ssh_port_t -p tcp $NEW_SSH_PORT 2>/dev/null \
      && log "SELinux: port $NEW_SSH_PORT allowed for SSH" \
      || warn "SELinux port add failed (may already exist)"
  else
    warn "SELinux: port $NEW_SSH_PORT already allowed"
  fi
else
  # Try to install semanage if missing
  if command -v dnf &>/dev/null; then
    warn "semanage not found — installing policycoreutils-python-utils..."
    dnf install -y policycoreutils-python-utils &>/dev/null && \
      semanage port -a -t ssh_port_t -p tcp $NEW_SSH_PORT 2>/dev/null && \
      log "SELinux: port $NEW_SSH_PORT allowed for SSH" || \
      warn "SELinux config skipped — do manually: semanage port -a -t ssh_port_t -p tcp $NEW_SSH_PORT"
  fi
fi

# Allow new port in CSF before restarting SSH
if command -v csf &>/dev/null; then
  CSF_CONF="/etc/csf/csf.conf"
  if [[ -f "$CSF_CONF" ]]; then
    if ! grep -qP "TCP_IN\s*=.*\b${NEW_SSH_PORT}\b" "$CSF_CONF"; then
      sed -i "/^TCP_IN\s*=/ s/\"$/,${NEW_SSH_PORT}\"/" "$CSF_CONF"
      log "Added port $NEW_SSH_PORT to CSF TCP_IN"
    else
      warn "Port $NEW_SSH_PORT already in CSF TCP_IN"
    fi
  fi
fi

# Allow in firewalld (AlmaLinux default firewall)
if command -v firewall-cmd &>/dev/null && firewall-cmd --state &>/dev/null 2>&1; then
  firewall-cmd --permanent --add-port=${NEW_SSH_PORT}/tcp &>/dev/null \
    && log "firewalld: port $NEW_SSH_PORT added" \
    || warn "firewalld: port may already exist"
  firewall-cmd --reload &>/dev/null
fi

# Restart SSH (service name differs across distros)
if systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null; then
  log "sshd restarted successfully on port $NEW_SSH_PORT"
else
  error "sshd restart failed — check $SSHD_CONFIG for errors"
  exit 1
fi

# ============================================================
# SECTION 3: Block IPs via CSF
# ============================================================
section "Blocking Malicious IPs via CSF"

BLOCK_IPS=(
  "80.75.212.14"
  "43.173.160.125"
  "212.107.31.89"
  "64.83.33.194"
  "68.233.238.100"
  "104.28.163.54"
  "167.88.180.94"
  "13.229.76.73"
  "15.235.188.154"
)

if ! command -v csf &>/dev/null; then
  error "CSF is not installed or not in PATH. Skipping IP blocks."
else
  for ip in "${BLOCK_IPS[@]}"; do
    if csf -d "$ip" 2>/dev/null; then
      log "Blocked: $ip"
    else
      warn "Could not block $ip (may already be blocked)"
    fi
  done
  csf -r &>/dev/null && log "CSF restarted and rules applied"
fi

# ============================================================
# SECTION 4: Remove ~/.ssh/authorized_keys (root and all users)
# ============================================================
section "Removing authorized_keys"

ROOT_AK="/root/.ssh/authorized_keys"
if [[ -f "$ROOT_AK" ]]; then
  cp "$ROOT_AK" "${ROOT_AK}.bak.$(date +%F-%H%M%S)"
  > "$ROOT_AK"
  log "Cleared $ROOT_AK (backup saved)"
else
  warn "$ROOT_AK does not exist — skipping"
fi

# Clear for all human users (UID >= 1000)
while IFS=: read -r username _ uid _ _ homedir _; do
  if [[ "$uid" -ge 1000 && -d "$homedir" ]]; then
    AK="$homedir/.ssh/authorized_keys"
    if [[ -f "$AK" ]]; then
      cp "$AK" "${AK}.bak.$(date +%F-%H%M%S)"
      > "$AK"
      log "Cleared $AK for user: $username"
    fi
  fi
done < /etc/passwd

# ============================================================
# SECTION 5: Set Random 20-Character Root Password
# ============================================================
section "Generating & Setting Random Root Password"

# Pure bash substring — zero pipes, zero blocking, works everywhere
RAND_HEX=$(openssl rand -hex 16)
NEW_ROOT_PASS="${RAND_HEX:0:20}"

if echo "root:${NEW_ROOT_PASS}" | chpasswd; then
  log "Root password updated successfully"
else
  error "Failed to update root password"
  exit 1
fi

# ============================================================
# SUMMARY
# ============================================================
section "Hardening Complete — Summary"
echo ""
echo "  [1] Host Access Control rules applied:"
echo "      Allow: $CM_IP (CM IP), $BM_VPN_IP (BM VPN IP), $CLIENT_IP (Client IP)"
echo "      Deny ALL for: whostmgrd, cpaneld, sshd"
echo ""
echo "  [2] SSH port changed to: $NEW_SSH_PORT"
echo "      ⚠  Make sure firewall/CSF allows port $NEW_SSH_PORT before disconnecting!"
echo ""
echo "  [3] CSF blocked IPs:"
for ip in "${BLOCK_IPS[@]}"; do
  echo "      - $ip"
done
echo ""
echo "  [4] authorized_keys cleared for root and all system users"
echo "      Backups saved with .bak.<timestamp> suffix"
echo ""
echo "  [5] Root password updated (20-character random)"
echo ""
echo -e "${RED}╔══════════════════════════════════════════╗${NC}"
echo -e "${RED}║         !! SAVE THIS PASSWORD !!         ║${NC}"
echo -e "${RED}╠══════════════════════════════════════════╣${NC}"
echo -e "${RED}║${NC}  New Root Password: ${YELLOW}${NEW_ROOT_PASS}${NC}"
echo -e "${RED}║${NC}  SSH Port         : ${YELLOW}22587${NC}"
echo -e "${RED}╚══════════════════════════════════════════╝${NC}"
echo ""
warn "IMPORTANT: Open a new SSH session on port $NEW_SSH_PORT with the new password to verify access before closing this session."
echo ""
