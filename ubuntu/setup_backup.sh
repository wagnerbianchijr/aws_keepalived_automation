#!/usr/bin/env bash

# =============================================================================
# Script Name : setup_backup.sh
# Author      : Bianchi (bianchi@readyset.io)
# Version     : v0.1
# Date        : 2025-09-11
# Description : Bootstrap BACKUP node with Keepalived, ENI failover, and ProxySQL.
# =============================================================================

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

log(){ 
  echo "$(date '+%b %d %H:%M:%S') [$1] $2";
}

# =============================================================================
# In order for the Keepalived service to forward network packets properly 
# to the real servers, each router node must have IP forwarding turned on
# in the kernel.
# =============================================================================
enable_ip_forward() {
  
  if sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1; then
    
    current_value=$(sysctl -n net.ipv4.ip_forward 2>/dev/null)

    if [ "$current_value" -eq 1 ]; then
      log INFO "Setting net.ipv4.ip_forward as 1."
      return 0
    else
      log ERROR "Failed to set net.ipv4.ip_forward (current value: $current_value)"
      return 1
    fi
  else
    log ERROR "Error: could not set net.ipv4.ip_forward"
    return 1
  fi
}

# Enable the ip_forward kernel variable
enable_ip_forward || {
  log ERROR "Please enable IP forwarding manually and re-run the script."
  exit 1
}

# ---- root check
if [[ $EUID -ne 0 ]]; then
  log ERROR "This script must be run as root"
  exit 1
fi

# ---- install helpers
install_pkg(){
  local pkg="$1"
  if dpkg -s "$pkg" >/dev/null 2>&1; then
    log INFO "Package $pkg already installed"
  else
    log INFO "Installing $pkg ..."
    apt-get -qq update -y >/dev/null 2>&1
    apt-get -qq install -y "$pkg" >/dev/null 2>&1
    log INFO "Package $pkg installed"
  fi
}

install_awscli(){
  if command -v aws >/dev/null 2>&1; then
    log INFO "AWS CLI already installed: $(aws --version 2>&1)"
    return
  fi
  log INFO "Installing AWS CLI v2 ..."
  curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
  unzip -qq /tmp/awscliv2.zip -d /tmp >/dev/null 2>&1
  sudo /tmp/aws/install >/dev/null 2>&1
  log INFO "AWS CLI installed successfully"
}

install_proxysql(){
  if command -v proxysql >/dev/null 2>&1; then
    log INFO "ProxySQL already installed: $(proxysql --version)"
    return
  fi

  log INFO "ProxySQL not found, installing latest release from GitHub..."
  # robust match for any amd64 .deb
  local url
  url=$(curl -S -s https://api.github.com/repos/sysown/proxysql/releases/latest \
      | jq -r '.assets[] | select(.name | test("proxysql_.*_amd64\\.deb$")).browser_download_url' | head -n1) >/dev/null 2>&1

  if [[ -z "$url" || "$url" == "null" ]]; then
    log ERROR "Unable to determine latest ProxySQL release URL"
    exit 1
  fi

  curl -S -Ls "$url" -o /tmp/proxysql-latest.deb >/dev/null 2>&1
  apt-get -qq install -y libaio-dev >/dev/null || true
  dpkg -i /tmp/proxysql-latest.deb || apt-get -qq -f install -y >/dev/null 2>&1
  log INFO "ProxySQL installed successfully"

  if ! systemctl is-active --quiet proxysql; then
    log INFO "Starting ProxySQL service"
    systemctl enable --now proxysql >/dev/null
  else
    log INFO "ProxySQL already running"
  fi
}

# ---- install required packages
install_pkg keepalived
install_pkg curl
install_pkg jq
install_pkg unzip
install_pkg netcat-openbsd   # provides /usr/bin/nc

# ---- install AWS CLI and ProxySQL
install_awscli
install_proxysql

# ---- gather input (with sensible defaults)
read -rp $'\e[1m=> Enter ENI ID (from Master setup): \e[0m' ENI_ID

read -rp $'\e[1m=> Enter VIP (same as MASTER) (e.g. 172.31.40.200): \e[0m' VIP 
VIP=${VIP:-172.31.40.200}

read -rp $'\e[1m=> Enter MASTER node private IP (e.g. 172.31.32.209): \e[0m' PEER_IP 
PEER_IP=${PEER_IP:-172.31.32.209}

read -rp $'\e[1m=> Enter the Network Interface name (e.g. ens5): \e[0m' IFACE
IFACE=${IFACE:-ens5}

# ---- ensure keepalived dir exists
[ -d /etc/keepalived ] || install -d -m 0755 /etc/keepalived

# ---- eni-move.sh
cat >/etc/keepalived/eni-move.sh <<'EOF'
#!/usr/bin/env bash
#: Configuration created by Wagner Bianchi with Readyset.io
#: http://readyset.io, Bianchi -> bianchi@readyset.io
#: Don't edit this file directly, it will be overwritten by setup script.

set -euo pipefail

log(){ logger -t keepalived_script "Keepalived: $*"; }

ENI_ID="__ENI_ID__"
AWS_BIN=$(command -v aws || true)
if [[ -z "${AWS_BIN:-}" ]]; then
  log "ERROR: aws CLI not found in PATH"
  exit 1
fi

# IMDSv2
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)

ACTION=${1:-}

if [[ "$ACTION" == "attach" ]]; then
  ATTACHED_TO=$($AWS_BIN ec2 describe-network-interfaces \
    --network-interface-ids "$ENI_ID" \
    --query 'NetworkInterfaces[0].Attachment.InstanceId' \
    --output text 2>/dev/null || echo "None")

  if [[ "$ATTACHED_TO" != "$INSTANCE_ID" ]]; then
    ATTACHMENT_ID=$($AWS_BIN ec2 describe-network-interfaces \
      --network-interface-ids "$ENI_ID" \
      --query 'NetworkInterfaces[0].Attachment.AttachmentId' \
      --output text 2>/dev/null || echo "None")

    if [[ "$ATTACHMENT_ID" != "None" && "$ATTACHMENT_ID" != "null" ]]; then
      log "Detaching ENI $ENI_ID (Attachment $ATTACHMENT_ID)"
      $AWS_BIN ec2 detach-network-interface --attachment-id "$ATTACHMENT_ID" --force
      sleep 5
    fi

    log "Attaching ENI $ENI_ID to $INSTANCE_ID"
    $AWS_BIN ec2 attach-network-interface \
      --network-interface-id "$ENI_ID" \
      --instance-id "$INSTANCE_ID" \
      --device-index 1
  else
    log "ENI $ENI_ID already attached to this instance"
  fi
elif [[ "$ACTION" == "detach" ]]; then
  ATTACHMENT_ID=$($AWS_BIN ec2 describe-network-interfaces \
    --network-interface-ids "$ENI_ID" \
    --query 'NetworkInterfaces[0].Attachment.AttachmentId' \
    --output text 2>/dev/null || echo "None")

  if [[ "$ATTACHMENT_ID" != "None" && "$ATTACHMENT_ID" != "null" ]]; then
    log "Detaching ENI $ENI_ID (Attachment $ATTACHMENT_ID)"
    $AWS_BIN ec2 detach-network-interface --attachment-id "$ATTACHMENT_ID" --force
  else
    log "ENI $ENI_ID already detached"
  fi
fi
EOF
sed -i "s|__ENI_ID__|$ENI_ID|g" /etc/keepalived/eni-move.sh
chown root:root /etc/keepalived/eni-move.sh
chmod 0750 /etc/keepalived/eni-move.sh

# ---- keepalived.conf
cat >/etc/keepalived/keepalived.conf <<EOF
#: Configuration created by Wagner Bianchi with Readyset.io
#: http://readyset.io, Bianchi -> bianchi@readyset.io
#: Don't edit this file directly, it will be overwritten by setup script.
global_defs {
    script_user root
    enable_script_security
    max_auto_priority 1
}

vrrp_script chk_proxysql {
    script "$(which nc) -z 127.0.0.1 6033"
    interval 2
    timeout 2
    fall 3
    rise 2
}

vrrp_instance VI_1 {
    state BACKUP
    interface ${IFACE}
    virtual_router_id 51
    priority 1
    nopreempt
    advert_int 1

    authentication {
        auth_type PASS
        auth_pass S3cR3tP@
    }

    unicast_src_ip $(hostname -I | awk '{print $1}')/32
    unicast_peer {
        $PEER_IP/32
    }

    virtual_ipaddress {
        $VIP/32 dev ${IFACE}
    }

    track_script {
        chk_proxysql
    }

    notify_master "/etc/keepalived/eni-move.sh attach"
    notify_backup "/etc/keepalived/eni-move.sh detach"
    notify_fault  "/etc/keepalived/eni-move.sh detach"
}
EOF
chown root:root /etc/keepalived/keepalived.conf
chmod 0644 /etc/keepalived/keepalived.conf

# ---- services
if ! systemctl is-active --quiet proxysql; then
  log INFO "Starting ProxySQL service"
  systemctl enable --now proxysql >/dev/null 2>&1
fi

log INFO "Starting keepalived service"
sudo systemctl enable keepalived >/dev/null 2>&1
sudo systemctl restart keepalived >/dev/null 2>&1

# ---- report ENI attachment
THIS_TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
THIS_INSTANCE=$(curl -s -H "X-aws-ec2-metadata-token: $THIS_TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)

#log INFO "Checking ENI $ENI_ID attachment..."
#aws ec2 describe-network-interfaces \
#  --network-interface-ids "$ENI_ID" \
#  --query "NetworkInterfaces[0].{ENI:NetworkInterfaceId,Instance:Attachment.InstanceId,Status:Status,PrivateIp:PrivateIpAddress}" \
#  --output table || true

log INFO "This node instance-id: $THIS_INSTANCE"
log INFO "You can follow the logs with the journalctl -f -u keepalived command."
log INFO $'\e[1mBACKUP setup complete.\e[0m'
