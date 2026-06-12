#!/bin/bash

# ============================================================

# IOC CLEANUP SCRIPT

# Compatible: CentOS 7 / AlmaLinux 8 / Rocky / RHEL

# ============================================================

set +e

REPORT="/root/compromise_cleanup_$(date +%F_%H%M%S).log"

exec > >(tee -a "$REPORT") 2>&1

NOLOGIN=$(command -v nologin)

[ -z "$NOLOGIN" ] && NOLOGIN="/usr/sbin/nologin"

echo "=================================================="
echo "COMPROMISE CLEANUP STARTED"
echo "Date: $(date)"
echo "Host: $(hostname)"
echo "=================================================="

###############################

# STAGE 1 - EVIDENCE

###############################

echo
echo "[1/9] Evidence Collection"

cat /etc/os-release 2>/dev/null

echo
echo "UID 0 Accounts:"
awk -F: '$3==0 {print}' /etc/passwd

echo
echo "Interactive Shell Accounts:"
awk -F: '$7 ~ /(bash|sh)$/ {print $1 ":" $7}' /etc/passwd

echo
echo "Defunct Artifacts:"
find / -iname "*defunct*" 2>/dev/null

echo
echo "Authorized Keys:"
find / -name authorized_keys 2>/dev/null

echo
echo ".ssh Directories:"
find / -type d -name ".ssh" 2>/dev/null

###############################

# STAGE 2 - STOP MALWARE

###############################

echo
echo "[2/9] Stopping Malware"

systemctl stop defunct.service 2>/dev/null
systemctl disable defunct.service 2>/dev/null
systemctl mask defunct.service 2>/dev/null

pkill -9 -f "/usr/bin/defunct" 2>/dev/null

###############################

# STAGE 3 - BACKUP IOCS

###############################

echo
echo "[3/9] Backing Up IOCs"

mkdir -p /root/forensics

[ -f /usr/bin/defunct ] && cp -a /usr/bin/defunct /root/forensics/defunct.bin

[ -f /usr/lib/systemd/system/defunct.service ] && cp -a /usr/lib/systemd/system/defunct.service /root/forensics/defunct.service

[ -f /lib/systemd/system/defunct.dat ] && cp -a /lib/systemd/system/defunct.dat /root/forensics/defunct.dat

###############################

# STAGE 4 - REMOVE IOCS

###############################

echo
echo "[4/9] Removing Known IOCs"

rm -f /usr/bin/defunct
rm -f /usr/lib/systemd/system/defunct.service
rm -f /lib/systemd/system/defunct.dat

find /home /usr/local/cwpsrv -type f -name ".r.php" -delete 2>/dev/null

systemctl daemon-reload

###############################

# STAGE 5 - REMOVE SSH PERSISTENCE

###############################

echo
echo "[5/9] Removing SSH Persistence"

# Remove immutable flags from .ssh directories/files
find / -type d -name ".ssh" ! -path "/root/.ssh" -exec chattr -R -i {} \; 2>/dev/null

find / -name authorized_keys ! -path "/root/.ssh/authorized_keys" -exec chattr -i {} \; 2>/dev/null

# Remove all authorized_keys except root

find / -name authorized_keys ! -path "/root/.ssh/authorized_keys" -type f -exec cp -a {} {}.bak \; -delete 2>/dev/null

# Remove all .ssh directories except root

find / -type d -name ".ssh" ! -path "/root/.ssh" -exec rm -rf {} + 2>/dev/null

###############################

# STAGE 6 - ROOT HARDENING

###############################

echo
echo "[6/9] Root Hardening"

chown root:root /root
chmod 700 /root

if [ -d /root/.ssh ]; then
chown -R root:root /root/.ssh
chmod 700 /root/.ssh
fi

###############################

# STAGE 7 - DISABLE CUSTOMER SHELLS

###############################

echo
echo "[7/9] Disabling Customer Shell Access"

for u in $(awk -F: '$3 >= 1000 && $6 ~ /^\/home\// {print $1}' /etc/passwd)
do
usermod -s "$NOLOGIN" "$u" 2>/dev/null
done

###############################

# STAGE 8 - DISABLE SERVICE SHELLS

###############################

echo
echo "[8/9] Disabling Service Account Shells"

for u in operator mysql redis nginx named postfix dovecot dovenull chrony rpc vmail vacation amavis clamupdate clamscan zabbix bitninja bitninja-waf bitninja-waf3 bitninja-ssl-termination cpguard sshd dbus polkitd
do
    id "$u" >/dev/null 2>&1 && usermod -s "$NOLOGIN" "$u"
done

###############################

# STAGE 9 - VERIFICATION

###############################

echo
echo "[9/9] Verification"

echo
echo "Remaining defunct artifacts:"
find / -iname "*defunct*" 2>/dev/null

echo
echo "Remaining authorized_keys:"
find / -name authorized_keys 2>/dev/null

echo
echo "Remaining .ssh directories:"
find / -type d -name ".ssh" 2>/dev/null

echo
echo "Defunct processes:"
ps auxf | egrep "defunct|kstrp"

echo
echo "Customer Shell Status:"
awk -F: '$3>=1000 && $6 ~ /^\/home\// {print $1 ":" $7}' /etc/passwd

echo
echo "=================================================="
echo "Cleanup Completed"
echo "Report Saved To: $REPORT"
echo "=================================================="
