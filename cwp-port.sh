#!/bin/bash

set -euo pipefail

VPN_IPS=(
    "3.111.17.14"
    "65.1.28.228"
    "172.237.41.71"
    "52.66.128.52"
)

CLIENT_IP="${1:-}"

echo "===================================================="
echo " CWP Access Restriction & Service Recovery Script"
echo " Hostname: $(hostname -f 2>/dev/null || hostname)"
echo " Date: $(date)"
echo "===================================================="

if ! command -v csf >/dev/null 2>&1; then
    echo "ERROR: CSF is not installed."
    exit 1
fi

SSH_PORT=$(grep -E '^[[:space:]]*Port[[:space:]]+' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1)
[ -z "${SSH_PORT:-}" ] && SSH_PORT="22"

PORTS=(
    "$SSH_PORT"
    "2031"
    "2083"
    "2087"
    "2096"
)

########################################
# ADD-ONLY MODE
########################################

if [ -n "$CLIENT_IP" ]; then
    echo
    echo "ADD-ONLY MODE"
    echo "Adding IP: $CLIENT_IP"

    for PORT in "${PORTS[@]}"; do
        RULE="tcp|in|d=${PORT}|s=${CLIENT_IP}"

        if grep -Fxq "$RULE" /etc/csf/csf.allow 2>/dev/null; then
            echo "Port ${PORT}: already present"
        else
            echo "$RULE" >> /etc/csf/csf.allow
            echo "Port ${PORT}: added"
        fi
    done

    csf -e >/dev/null 2>&1 || true
    csf -r

    echo
    echo "Completed."
    exit 0
fi

########################################
# FULL RESTRICTION MODE
########################################

echo
echo "[1/10] Backing up CSF configuration..."

cp -a /etc/csf/csf.allow "/etc/csf/csf.allow.$(date +%F-%H%M%S).bak"
cp -a /etc/csf/csf.deny "/etc/csf/csf.deny.$(date +%F-%H%M%S).bak"

echo "Backup completed."

echo
echo "[2/10] Enabling CSF..."

systemctl unmask csf.service >/dev/null 2>&1 || true
systemctl daemon-reload
systemctl reset-failed csf.service >/dev/null 2>&1 || true
systemctl enable csf.service >/dev/null 2>&1 || true
systemctl start csf.service >/dev/null 2>&1 || true

sed -i 's/^TESTING = "1"/TESTING = "0"/' /etc/csf/csf.conf || true

# Enable CSF/LFD if disabled
csf -e >/dev/null 2>&1 || true

systemctl enable lfd >/dev/null 2>&1 || true
systemctl start lfd >/dev/null 2>&1 || true

echo
echo "[3/10] Cleaning old management rules..."

sed -i '/^n|d=.*|d$/d' /etc/csf/csf.allow || true
sed -i '/^n|d=.*|d$/d' /etc/csf/csf.deny || true

for PORT in "${PORTS[@]}"; do
    sed -i "\#^tcp|in|d=${PORT}|s=#d" /etc/csf/csf.allow || true
    sed -i "\#^tcp|in|d=${PORT}|s=0.0.0.0/0#d" /etc/csf/csf.deny || true
done

echo
echo "[4/10] Creating fresh management rules..."

for PORT in "${PORTS[@]}"; do
    for IP in "${VPN_IPS[@]}"; do
        echo "tcp|in|d=${PORT}|s=${IP}" >> /etc/csf/csf.allow
    done

    echo "tcp|in|d=${PORT}|s=0.0.0.0/0" >> /etc/csf/csf.deny
    echo "Configured port ${PORT}"
done

echo
echo "[5/10] Reloading CSF..."

csf -e >/dev/null 2>&1 || true
csf -r

echo
echo "[6/10] Unmasking and starting CWP services..."

SERVICES=(
    "cwp-phpfpm"
    "cwpsrv-phpfpm"
    "cwpsrv"
)

for SERVICE in "${SERVICES[@]}"; do
    UNIT="${SERVICE}.service"

    echo "Processing ${UNIT}..."

    systemctl unmask "$UNIT" >/dev/null 2>&1 || true
    systemctl daemon-reload
    systemctl reset-failed "$UNIT" >/dev/null 2>&1 || true

    echo "Enabling ${UNIT}..."
    systemctl enable "$UNIT" >/dev/null 2>&1 || true

    echo "Starting ${UNIT}..."
    systemctl restart "$UNIT" >/dev/null 2>&1 || \
    systemctl start "$UNIT" >/dev/null 2>&1 || true

    printf "%-20s : " "$SERVICE"
    systemctl is-active "$UNIT" 2>/dev/null || true
done

echo
echo "[7/10] Reloading systemd..."
systemctl daemon-reload

echo
echo "[8/10] Service Status"

for SERVICE in "${SERVICES[@]}"; do
    UNIT="${SERVICE}.service"
    printf "%-20s : " "$SERVICE"
    systemctl is-active "$UNIT" 2>/dev/null || true
done

echo
echo "[9/10] Final CSF Allow Rules"

for PORT in "${PORTS[@]}"; do
    grep "^tcp|in|d=${PORT}|s=" /etc/csf/csf.allow || true
done

echo
echo "[10/10] Final CSF Deny Rules"

for PORT in "${PORTS[@]}"; do
    grep "^tcp|in|d=${PORT}|s=0.0.0.0/0" /etc/csf/csf.deny || true
done

echo
echo "===================================================="
echo "Completed Successfully"
echo
echo "Restricted ports:"
echo "  - SSH (${SSH_PORT})"
echo "  - CWP Panel (2031)"
echo "  - WHM (2087)"
echo "  - cPanel SSL (2083)"
echo "  - Webmail SSL (2096)"
echo
echo "Allowed VPN IPs:"
printf '  - %s\n' "${VPN_IPS[@]}"
echo
echo "Usage:"
echo "  ./cwp-port.sh"
echo "  ./cwp-port.sh <client_ip>"
echo
echo "Examples:"
echo "  ./cwp-port.sh"
echo "  ./cwp-port.sh 49.36.242.111"
echo "===================================================="
