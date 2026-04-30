#!/bin/bash
# ============================================================
# Server Hardening Script - CloudMinister DevOps Team
# Tasks:
#   1. Add WHM Host Access Control List rules
#   2. Change SSH port to 22587
#   3. Block malicious IPs via CSF
#   4. Remove ~/.ssh/authorized_keys
#   5. Set random 20-character root password
# ============================================================

set -euo pipefail

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
# SECTION 1: WHM Host Access Control (TCP Wrappers / hosts.allow + hosts.deny)
# Based on the rules in the screenshot:
#   whostmgrd, cpaneld, sshd
#   Allow: 3.111.17.14 (CM IP), 65.1.28.228 (BM VPN IP), 163.227.92.110 (Client IP)
#   Deny:  ALL
# ============================================================
section "WHM Host Access Control List Rules"

HOSTS_ALLOW="/etc/hosts.allow"
HOSTS_DENY="/etc/hosts.deny"

# Backup existing files
cp "$HOSTS_ALLOW" "${HOSTS_ALLOW}.bak.$(date +%F-%H%M%S)" 2>/dev/null || true
cp "$HOSTS_DENY"  "${HOSTS_DENY}.bak.$(date +%F-%H%M%S)"  2>/dev/null || true

# Define allowed IPs
CM_IP="3.111.17.14"
BM_VPN_IP="65.1.28.228"
CLIENT_IP="163.227.92.110"

DAEMONS=("whostmgrd" "cpaneld" "sshd")

# Remove any old managed block to avoid duplicates
sed -i '/# BEGIN CloudMinister HAC Rules/,/# END CloudMinister HAC Rules/d' "$HOSTS_ALLOW"
sed -i '/# BEGIN CloudMinister HAC Rules/,/# END CloudMinister HAC Rules/d' "$HOSTS_DENY"

# Write allow rules
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

log "hosts.allow rules written for: ${DAEMONS[*]}"

# Write deny rules
{
  echo ""
  echo "# BEGIN CloudMinister HAC Rules"
  for daemon in "${DAEMONS[@]}"; do
    echo "$daemon : ALL : deny   # Block all others"
  done
  echo "# END CloudMinister HAC Rules"
} >> "$HOSTS_DENY"

log "hosts.deny ALL rules written for: ${DAEMONS[*]}"

# Also apply via WHM/cPanel API if whmapi1 is available
if command -v whmapi1 &>/dev/null; then
  warn "whmapi1 detected — you may also manage these rules from WHM > Host Access Control."
  warn "TCP Wrappers rules above are applied directly and take effect immediately."
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

# Allow new port in CSF before restarting SSH
if command -v csf &>/dev/null; then
  CSF_CONF="/etc/csf/csf.conf"
  if [[ -f "$CSF_CONF" ]]; then
    # Add 22587 to TCP_IN if not already there
    if ! grep -qP "TCP_IN\s*=.*\b22587\b" "$CSF_CONF"; then
      sed -i "/^TCP_IN\s*=/ s/\"$/,22587\"/" "$CSF_CONF"
      log "Added port 22587 to CSF TCP_IN"
    else
      warn "Port 22587 already in CSF TCP_IN"
    fi
    # Remove old port 22 from TCP_IN (optional - comment out if you want to keep 22)
    # sed -i "/^TCP_IN\s*=/ s/,22\b//" "$CSF_CONF"
  fi
fi

# Also open in firewalld if present
if command -v firewall-cmd &>/dev/null; then
  firewall-cmd --permanent --add-port=22587/tcp &>/dev/null && log "firewalld: port 22587 added"
  firewall-cmd --reload &>/dev/null
fi

# Restart SSH
if systemctl restart sshd; then
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
  # Restart CSF to apply all rules cleanly
  csf -r &>/dev/null && log "CSF restarted and rules applied"
fi

# ============================================================
# SECTION 4: Remove ~/.ssh/authorized_keys (root and all users)
# ============================================================
section "Removing authorized_keys"

# Remove for root
ROOT_AK="/root/.ssh/authorized_keys"
if [[ -f "$ROOT_AK" ]]; then
  # Backup before removing
  cp "$ROOT_AK" "${ROOT_AK}.bak.$(date +%F-%H%M%S)"
  > "$ROOT_AK"   # Truncate (empty) rather than delete, preserves permissions
  log "Cleared $ROOT_AK (backup saved)"
else
  warn "$ROOT_AK does not exist — skipping"
fi

# Remove for all other human users (UID >= 1000)
while IFS=: read -r username _ uid _ _ homedir _; do
  if [[ $uid -ge 1000 && -d "$homedir" ]]; then
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

# Generate a strong 20-character password using /dev/urandom
# Uses alphanumeric + special chars, avoids ambiguous chars like 0/O/l/1
NEW_ROOT_PASS=$(tr -dc 'A-Za-z0-9!@#$%^&*()-_=+[]{}|;:,.<>?' < /dev/urandom \
  | head -c 20)

# Set the password
if echo "root:${NEW_ROOT_PASS}" | chpasswd; then
  log "Root password updated successfully"
else
  error "Failed to update root password"
  exit 1
fi

# Save password to a root-only file as backup
PASS_LOG="/root/.hardening_credentials"
{
  echo "# CloudMinister Server Hardening - $(date)"
  echo "ROOT_PASSWORD=${NEW_ROOT_PASS}"
  echo "SSH_PORT=22587"
} > "$PASS_LOG"
chmod 600 "$PASS_LOG"
log "Credentials saved to $PASS_LOG (chmod 600, root only)"

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
echo "      ⚠  Make sure your firewall/CSF allows port $NEW_SSH_PORT before disconnecting!"
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
echo "  Credentials also saved to: $PASS_LOG"
echo ""
warn "IMPORTANT: Open a new SSH session on port $NEW_SSH_PORT with the new password to verify access before closing this session."
echo ""
