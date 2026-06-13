#!/bin/bash

set -euo pipefail

echo "===================================================="
echo " CWP Access Restriction & Service Recovery Script"
echo " Hostname: $(hostname -f 2>/dev/null || hostname)"
echo " Date: $(date)"
echo "===================================================="

ALLOWED_IPS="3.111.17.14,65.1.128.28,172.237.41.71"

echo
echo "[1/12] Checking CSF installation..."

if ! command -v csf >/dev/null 2>&1; then
    echo "ERROR: CSF is not installed."
    exit 1
fi

echo "OK: CSF is installed."

echo
echo "[2/12] Detecting SSH port..."

SSH_PORTS=$(grep -E '^Port ' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | xargs || true)

if [ -z "${SSH_PORTS:-}" ]; then
    SSH_PORTS="22"
fi

echo "Detected SSH Port(s): $SSH_PORTS"

PORTS="$SSH_PORTS 2031 2083 2087 2096"

echo
echo "[3/12] Backing up CSF files..."

cp -a /etc/csf/csf.allow "/etc/csf/csf.allow.$(date +%F-%H%M%S).bak"
cp -a /etc/csf/csf.deny "/etc/csf/csf.deny.$(date +%F-%H%M%S).bak"

echo "Backup completed."

echo
echo "[4/12] Enabling CSF..."

if systemctl list-unit-files 2>/dev/null | grep -q '^csf.service'; then
    systemctl enable csf >/dev/null 2>&1 || true
    systemctl start csf >/dev/null 2>&1 || true
fi

sed -i 's/^TESTING = "1"/TESTING = "0"/' /etc/csf/csf.conf || true

echo "CSF enabled."

echo
echo "[5/12] Cleaning malformed and old rules..."

sed -i '/^n|d=.*|d$/d' /etc/csf/csf.allow
sed -i '/^n|d=.*|d$/d' /etc/csf/csf.deny

for PORT in $PORTS; do
    sed -i "\#tcp|in|d=${PORT}|#d" /etc/csf/csf.allow
    sed -i "\#tcp|in|d=${PORT}|#d" /etc/csf/csf.deny
done

echo "Cleanup completed."

echo
echo "[6/12] Adding fresh allow/deny rules..."

for PORT in $PORTS; do
    echo "tcp|in|d=${PORT}|s=${ALLOWED_IPS}" >> /etc/csf/csf.allow
    echo "tcp|in|d=${PORT}|s=0.0.0.0/0" >> /etc/csf/csf.deny
    echo "Added rules for port ${PORT}"
done

echo
echo "[7/12] Reloading CSF..."

csf -r

echo "CSF reloaded."

echo
echo "[8/12] Checking CWP services..."

SERVICES=(
    "cwp-phpfpm"
    "cwpsrv-phpfpm"
    "cwpsrv"
)

for SERVICE in "${SERVICES[@]}"; do

    if ! systemctl list-unit-files | grep -q "^${SERVICE}.service"; then
        echo "Service not found: ${SERVICE} (skipping)"
        continue
    fi

    echo
    echo "Processing ${SERVICE}..."

    if systemctl is-enabled "${SERVICE}" 2>/dev/null | grep -q masked; then
        echo "Unmasking ${SERVICE}"
        systemctl unmask "${SERVICE}"
    fi

    if ! systemctl is-enabled "${SERVICE}" >/dev/null 2>&1; then
        echo "Enabling ${SERVICE}"
        systemctl enable "${SERVICE}"
    else
        echo "${SERVICE} already enabled"
    fi

    if ! systemctl is-active "${SERVICE}" >/dev/null 2>&1; then
        echo "Starting ${SERVICE}"
        systemctl start "${SERVICE}"
    else
        echo "${SERVICE} already running"
    fi
done

echo
echo "[9/12] Reloading systemd..."

systemctl daemon-reload

echo
echo "[10/12] Final service status..."

for SERVICE in "${SERVICES[@]}"; do
    if systemctl list-unit-files | grep -q "^${SERVICE}.service"; then
        echo -n "${SERVICE}: "
        systemctl is-active "${SERVICE}" || true
    fi
done

echo
echo "[11/12] Final CSF.ALLOW entries..."

for PORT in $PORTS; do
    grep "^tcp|in|d=${PORT}|s=" /etc/csf/csf.allow || true
done

echo
echo "[12/12] Final CSF.DENY entries..."

for PORT in $PORTS; do
    grep "^tcp|in|d=${PORT}|s=0.0.0.0/0" /etc/csf/csf.deny || true
done

echo
echo "===================================================="
echo "Allowed IPs:"
echo "$ALLOWED_IPS" | tr ',' '\n'
echo
echo "Completed successfully."
echo "Safe to run multiple times."
echo "No duplicate CSF entries will be created."
echo "===================================================="
