#!/bin/bash

set -euo pipefail

echo "===================================================="
echo " CSF SSH/CWP Access Restriction Script"
echo " Hostname: $(hostname -f 2>/dev/null || hostname)"
echo " Date: $(date)"
echo "===================================================="

# Allowed IPs
ALLOWED_IPS="3.111.17.14,65.1.128.28,172.237.41.71"

echo
echo "[1/10] Checking CSF installation..."

if ! command -v csf >/dev/null 2>&1; then
    echo "ERROR: CSF is not installed on this server."
    exit 1
fi

echo "OK: CSF is installed."

echo
echo "[2/10] Detecting SSH port(s)..."

# Preferred method
SSH_PORTS=$(sshd -T 2>/dev/null | awk '/^port / {print $2}' | sort -u | xargs || true)

# Fallback
if [ -z "${SSH_PORTS:-}" ]; then
    SSH_PORTS=$(grep -i '^Port' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | sort -u | xargs || true)
fi

# Final fallback
[ -z "${SSH_PORTS:-}" ] && SSH_PORTS="22"

echo "Detected SSH Port(s): $SSH_PORTS"

# Ports to restrict
PORTS="$SSH_PORTS 2031 2083 2087 2096"

echo
echo "[3/10] Ports to be restricted:"
for PORT in $PORTS; do
    echo " - $PORT"
done

echo
echo "[4/10] Backing up CSF files..."

cp -a /etc/csf/csf.allow "/etc/csf/csf.allow.$(date +%F-%H%M%S).bak"
cp -a /etc/csf/csf.deny "/etc/csf/csf.deny.$(date +%F-%H%M%S).bak"

echo "Backup completed."

echo
echo "[5/10] Enabling and starting CSF..."

if systemctl list-unit-files 2>/dev/null | grep -q '^csf.service'; then
    systemctl enable csf >/dev/null 2>&1 || true
    systemctl start csf >/dev/null 2>&1 || true
    echo "CSF service enabled and started."
else
    echo "WARNING: csf.service not found. Continuing..."
fi

echo
echo "[6/10] Disabling TESTING mode..."

sed -i 's/^TESTING = "1"/TESTING = "0"/' /etc/csf/csf.conf || true

echo "TESTING mode disabled."

echo
echo "[7/10] Cleaning malformed and existing management rules..."

# Remove malformed entries
sed -i '/^n|d=.*|d$/d' /etc/csf/csf.allow
sed -i '/^n|d=.*|d$/d' /etc/csf/csf.deny

# Remove existing rules for protected ports
for PORT in $PORTS; do
    sed -i "\#tcp|in|d=${PORT}|#d" /etc/csf/csf.allow
    sed -i "\#tcp|in|d=${PORT}|#d" /etc/csf/csf.deny
done

echo "Cleanup completed."

echo
echo "[8/10] Adding fresh allow/deny rules..."

for PORT in $PORTS; do
    echo "tcp|in|d=${PORT}|s=${ALLOWED_IPS}" >> /etc/csf/csf.allow
    echo "tcp|in|d=${PORT}|s=0.0.0.0/0" >> /etc/csf/csf.deny
    echo "Added rules for port ${PORT}"
done

echo
echo "[9/10] Reloading CSF..."

csf -r

echo "CSF reloaded."

echo
echo "[10/10] Final verification..."

echo
echo "================ CSF.ALLOW ================"
for PORT in $PORTS; do
    grep "^tcp|in|d=${PORT}|s=" /etc/csf/csf.allow || true
done

echo
echo "================ CSF.DENY ================="
for PORT in $PORTS; do
    grep "^tcp|in|d=${PORT}|s=0.0.0.0/0" /etc/csf/csf.deny || true
done

echo
echo "================ ALLOWED IPS =============="
echo "$ALLOWED_IPS" | tr ',' '\n'

echo
echo "===================================================="
echo " Completed successfully."
echo " Safe to run multiple times."
echo " No duplicate entries will be created."
echo "===================================================="
