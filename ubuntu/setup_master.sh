#!/usr/bin/env bash

# =============================================================================
# Script Name : setup_master.sh
# Author      : Bianchi (bianchi@readyset.io)
# Version     : v0.1
# Date        : 2025-09-11
# Description : Bootstrap MASTER node with Keepalived, ENI, and ProxySQL.
# =============================================================================

set -euo pipefail

# =========================
# Logging helper
# =========================
log() {
  echo "$(date '+%b %d %H:%M:%S') [$1] $2"
}

# =============================================================================
# In order for the Keepalived service to forward network packets properly 
# to the real servers, each router node must have IP forwarding turned on
# in the kernel.
# =============================================================================
enable_ip_forward() {
  # Try to set ip_forward to 1
  if sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1; then
    # Now check if it was applied successfully
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

# =========================
# Package installer
# =========================
install_pkg() {
  local pkg="$1"
  if dpkg -s "$pkg" >/dev/null 2>&1; then
    log INFO "Package $pkg already installed"
  else
    log INFO "Installing $pkg..."
    sudo apt-get -qq update -y && sudo apt-get -qq install -y "$pkg" >/dev/null 2>&1
    log INFO "Package $pkg installed successfully"
  fi
}

# =========================
# ProxySQL installer
# =========================
install_proxysql() {
  if command -v proxysql >/dev/null 2>&1; then
    log INFO "ProxySQL already installed: $(proxysql --version)"
    return
  fi

  log INFO "ProxySQL not found, installing latest release from GitHub..."

  local api_url="https://api.github.com/repos/sysown/proxysql/releases/latest"
  local latest_url
  latest_url=$(curl -S -sL "$api_url" | jq -r '.assets[] | select(.name | endswith("amd64.deb")).browser_download_url' | head -n1)

  if [[ -z "$latest_url" || "$latest_url" == "null" ]]; then
    log ERROR "Unable to determine latest ProxySQL release URL"
    exit 1
  fi

  log INFO "Downloading $latest_url"
  curl -SL -o /tmp/proxysql-latest.deb "$latest_url" >/dev/null 2>&1
  sudo apt-get -qq install -y libaio1t64 || true
  sudo dpkg -i /tmp/proxysql-latest.deb || true
  log INFO "ProxySQL installed successfully"
}

# =========================
# Main setup
# =========================
main() {
  log INFO "Starting setup on MASTER node"

  # Packages
  install_pkg keepalived
  install_pkg curl
  install_pkg jq
  install_pkg unzip
  install_pkg netcat-openbsd

  # AWS CLI
  if ! command -v aws >/dev/null 2>&1; then
    log INFO "Installing AWS CLI v2..."
    curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip >/dev/null 2>&1
    unzip -q /tmp/awscliv2.zip -d /tmp >/dev/null 2>&1
    sudo /tmp/aws/install >/dev/null 2>&1
    log INFO "AWS CLI installed successfully"
  else
    log INFO "AWS CLI found: $(aws --version 2>&1)"
  fi

  # ProxySQL
  install_proxysql

  # Gather user input with defaults
read -rp $'\e[1m=> Enter VIP (e.g. 172.31.40.200): \e[0m' VIP
VIP=${VIP:-172.31.40.200}

read -rp $'\e[1m=> Enter ENI description (e.g. Readyset.io Keepalived ENI): \e[0m' ENI_DESC
ENI_DESC=${ENI_DESC:-"Readyset.io Keepalived ENI"}

read -rp $'\e[1m=> Enter Subnet ID (e.g. subnet-1ea42441): \e[0m' SUBNET_ID
SUBNET_ID=${SUBNET_ID:-subnet-1ea42441}

read -rp $'\e[1m=> Enter Security Group ID (e.g. sg-0aba3ccd66cf6ea50): \e[0m' SG_ID
SG_ID=${SG_ID:-sg-0aba3ccd66cf6ea50}

read -rp $'\e[1m=> Enter Backup node private IP (e.g. 172.31.47.224): \e[0m' PEER_IP
PEER_IP=${PEER_IP:-172.31.47.224}

read -rp $'\e[1m=> Enter the Network Interface name (e.g. ens5): \e[0m' IFACE
IFACE=${IFACE:-ens5}

  # Get instance-id with IMDSv2
  TOKEN=$(curl -S -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
  INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)

  # Create ENI
  ENI_ID=$(aws ec2 create-network-interface \
    --subnet-id "$SUBNET_ID" \
    --groups "$SG_ID" \
    --private-ip-address "$VIP" \
    --description "$ENI_DESC" \
    --query 'NetworkInterface.NetworkInterfaceId' \
    --output text)

  log INFO "Created ENI with ID $ENI_ID"

  # Attach ENI
  aws ec2 attach-network-interface \
    --network-interface-id "$ENI_ID" \
    --instance-id "$INSTANCE_ID" \
    --device-index 1 >/dev/null

  # Wait for ENI
  log INFO "Waiting for ENI $ENI_ID to attach with VIP $VIP..."
  for i in {1..90}; do
    if ip -br a | grep -q "$VIP"; then
      log INFO "VIP $VIP detected on this node"
      break
    fi
    log INFO "Hold on, still waiting on AWS... $((i*3))s elapsed"
    sleep 3
    if [[ $i -eq 90 ]]; then
      log ERROR "Timed out after 90 seconds: ENI $ENI_ID with VIP $VIP did not attach"
      exit 1
    fi
  done

  # Ensure ProxySQL is running
  if ! pgrep -x proxysql >/dev/null; then
    log INFO "ProxySQL not running, starting service and starting it on boot..."
    sudo systemctl enable --now proxysql.service >/dev/null 2>&1
    sleep 3
  else
    log INFO "ProxySQL already running"
  fi

  # ENI move script
  cat <<'EOF' | sudo tee /etc/keepalived/eni-move.sh >/dev/null
#!/usr/bin/env bash
#: Configuration created by Wagner Bianchi with Readyset.io
#: http://readyset.io, Bianchi -> bianchi@readyset.io
#: Don't edit this file directly, it will be overwritten by setup script.

set -euo pipefail
PATH=/usr/local/bin:/usr/bin:/bin

ENI_ID="__ENI_ID__"

log() { logger "Keepalived: $*"; }

TOKEN=$(curl -s -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)

ACTION="$1"

if [[ "$ACTION" == "attach" ]]; then
  ATTACHED_TO=$(aws ec2 describe-network-interfaces --network-interface-ids "$ENI_ID" --query 'NetworkInterfaces[0].Attachment.InstanceId' --output text)
  if [[ "$ATTACHED_TO" != "$INSTANCE_ID" ]]; then
    ATTACHMENT_ID=$(aws ec2 describe-network-interfaces --network-interface-ids "$ENI_ID" --query 'NetworkInterfaces[0].Attachment.AttachmentId' --output text)
    if [[ "$ATTACHMENT_ID" != "None" && "$ATTACHMENT_ID" != "null" ]]; then
      log "Detaching ENI $ENI_ID from $ATTACHED_TO"
      aws ec2 detach-network-interface --attachment-id "$ATTACHMENT_ID" --force
      sleep 5
    fi
    log "Attaching ENI $ENI_ID to $INSTANCE_ID"
    aws ec2 attach-network-interface --network-interface-id "$ENI_ID" --instance-id "$INSTANCE_ID" --device-index 1
  else
    log "ENI $ENI_ID already attached to this instance"
  fi
elif [[ "$ACTION" == "detach" ]]; then
  ATTACHMENT_ID=$(aws ec2 describe-network-interfaces --network-interface-ids "$ENI_ID" --query 'NetworkInterfaces[0].Attachment.AttachmentId' --output text)
  if [[ "$ATTACHMENT_ID" != "None" && "$ATTACHMENT_ID" != "null" ]]; then
    log "Detaching ENI $ENI_ID (Attachment $ATTACHMENT_ID)"
    aws ec2 detach-network-interface --attachment-id "$ATTACHMENT_ID" --force
  else
    log "ENI $ENI_ID not attached, nothing to do"
  fi
fi
EOF
  sudo sed -i "s|__ENI_ID__|$ENI_ID|g" /etc/keepalived/eni-move.sh
  sudo chmod +x /etc/keepalived/eni-move.sh

  # Keepalived config
  cat <<EOF | sudo tee /etc/keepalived/keepalived.conf >/dev/null
#: Configuration created by Wagner Bianchi with Readyset.io
#: http://readyset.io, Bianchi -> bianchi@readyset.io
#: Don't edit this file directly, it will be overwritten by setup script.
global_defs {
   script_user root
   enable_script_security
   max_auto_priority 2
}

vrrp_script chk_proxysql {
    script "$(which nc) -z 127.0.0.1 6033"
    interval 3
    rise 3
    fall 3
}

vrrp_instance VI_1 {
    state MASTER
    interface ${IFACE}
    virtual_router_id 51
    priority 2
    advert_int 1
    nopreempt

    authentication {
        auth_type PASS
        auth_pass S3cR3tP@
    }

    virtual_ipaddress {
        ${VIP}/32 dev ${IFACE}
    }

    unicast_src_ip $(hostname -I | awk '{print $1}')/32
    unicast_peer {
        ${PEER_IP}/32
    }

    track_script {
        chk_proxysql
    }

    garp_master_delay 5
    garp_master_repeat 2
    garp_master_refresh 10

    notify_master "/etc/keepalived/eni-move.sh attach"
    notify_backup "/etc/keepalived/eni-move.sh detach"
    notify_fault  "/etc/keepalived/eni-move.sh detach"
}
EOF

  # Start Keepalived
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
  log INFO "MASTER setup complete. ENI ID = $ENI_ID"
}

main
