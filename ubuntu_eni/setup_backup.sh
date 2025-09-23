#!/usr/bin/env bash

# =============================================================================
# Script Name : setup_backup.sh
# Author      : Bianchi (bianchi@readyset.io)
# Version     : v0.1
# Date        : 2025-09-11
# Language    : bash
# Description : Bootstrap BACKUP node with Keepalived, ENI hooks, and ProxySQL.
# =============================================================================

set -euo pipefail

log() {
  echo "$(date '+%b %d %H:%M:%S') [$1] $2"
}

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
enable_ip_forward || {
  log ERROR "Please enable IP forwarding manually and re-run the script."
  exit 1
}

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

  curl -SL -o /tmp/proxysql-latest.deb "$latest_url" >/dev/null 2>&1
  sudo apt-get -qq install -y libaio1t64 >/dev/null 2>&1
  sudo dpkg -i /tmp/proxysql-latest.deb >/dev/null 2>&1 
  log INFO "ProxySQL installed successfully"
}

main() {
  log INFO "Starting setup on BACKUP node"

  # Packages
  install_pkg keepalived
  install_pkg curl
  install_pkg jq
  install_pkg unzip
  install_pkg netcat-openbsd
  install_pkg mariadb-client-core

  # AWS CLI
  if ! command -v aws >/dev/null 2>&1; then
    log INFO "Installing AWS CLI v2..."
    curl -Ss "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
    unzip -q /tmp/awscliv2.zip -d /tmp
    sudo /tmp/aws/install >/dev/null
    rm -rf /tmp/aws*
    log INFO "AWS CLI installed successfully"
    aws --version
  else
    log INFO "AWS CLI found: $(aws --version 2>&1)"
  fi

  # ProxySQL
  install_proxysql || {
    log ERROR "ProxySQL installation failed, exiting."
    exit 1
  }

  # Ensure ProxySQL is running
  if ! pgrep -x proxysql >/dev/null; then
    log INFO "ProxySQL not running, starting service and enabling on boot..."
    sudo systemctl enable --now proxysql.service >/dev/null 2>&1
    sleep 3
  else
    log INFO "ProxySQL already running"
  fi

  # Function to ask for required input
  ask_input() {
    local prompt="$1"
    local varname="$2"
    local default="${3:-}"

    while true; do
      if [[ -n "$default" ]]; then
        read -rp $'\e[1m'"$prompt [$default]: "$'\e[0m' input
        input="${input:-$default}"
      else
        read -rp $'\e[1m'"$prompt: "$'\e[0m' input
      fi

      if [[ -n "$input" ]]; then
        eval "$varname=\"\$input\""
        break
      else
        echo "The $varname cannot be empty. Please try again."
      fi
    done
  }

  # Defaults
  REGION=${REGION:-us-east-1}
  VIP=${VIP:-172.31.40.200}
  ALLOC_ID=${ALLOC_ID:-eipalloc-0f7ce09357b2dec5e}
  ENI_ID=${ENI_ID:-eni-xxxxxxxx}    # Must be provided by user
  PEER_IP=${PEER_IP:-172.31.37.44}
  IFACE=${IFACE:-ens5}
  SUBNET_MASK=${SUBNET_MASK:-20}

  # Gather user input with defaults
  ask_input "Enter AWS Region (e.g. us-east-1)" REGION
  ask_input "Enter VIP (e.g. 172.31.40.200)" VIP
  ask_input "Enter the EIP Allocation ID (e.g. eipalloc-xxxxxx)" ALLOC_ID
  ask_input "Enter the ENI ID created by the MASTER (e.g. eni-xxxxxx)" ENI_ID
  ask_input "Enter Backup node private IP (e.g. 172.31.37.44)" PEER_IP
  ask_input "Enter the Primary NIC Interface name (e.g. ens5)" IFACE
  ask_input "Enter the Primary NIC Subnet Mask (e.g. 20)" SUBNET_MASK

# Show all inputs
cat <<EOF

Please confirm the following inputs:
  AWS Region              : $REGION
  VIP                     : $VIP
  EIP Allocation ID       : $ALLOC_ID
  ENI ID (from MASTER)    : $ENI_ID
  Backup node Private IP  : $PEER_IP
  Primary NIC Interface   : $IFACE
  Subnet Mask / CIDR      : $SUBNET_MASK

EOF

read -rp "Continue with these values? (y/N): " CONFIRM
CONFIRM=${CONFIRM,,}
if [[ "$CONFIRM" != "y" ]]; then
  echo "Aborted by user."
  exit 1
fi

log INFO "Inputs confirmed, starting setup..."

  # ENI move script
  cat <<'EOF' | sudo tee /etc/keepalived/eni-move.sh >/dev/null
#!/usr/bin/env bash
set -euo pipefail
PATH=/usr/local/bin:/usr/bin:/bin

ENI_ID="__ENI_ID__"
REGION="__REGION__"
VIP="__VIP__"
ALLOC_ID="__ALLOC_ID__"
SUBNET_MASK="__SUBNET_MASK__"

log() { logger "Keepalived: $*"; }

TOKEN=$(curl -s -X PUT http://169.254.169.254/latest/api/token \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)

ACTION="$1"

if [[ "$ACTION" == "attach" ]]; then
  ATTACHED_TO=$(aws ec2 describe-network-interfaces --region "$REGION" \
    --network-interface-ids "$ENI_ID" \
    --query 'NetworkInterfaces[0].Attachment.InstanceId' --output text)

  if [[ "$ATTACHED_TO" != "$INSTANCE_ID" ]]; then
    ATTACHMENT_ID=$(aws ec2 describe-network-interfaces --region "$REGION" \
      --network-interface-ids "$ENI_ID" \
      --query 'NetworkInterfaces[0].Attachment.AttachmentId' --output text)

    if [[ "$ATTACHMENT_ID" != "None" && "$ATTACHMENT_ID" != "null" ]]; then
      log "Detaching ENI $ENI_ID from $ATTACHED_TO"
      aws ec2 detach-network-interface --region "$REGION" \
        --attachment-id "$ATTACHMENT_ID" --force
      sleep 5
    fi

    log "Attaching ENI $ENI_ID to $INSTANCE_ID"
    aws ec2 attach-network-interface --region "$REGION" \
      --network-interface-id "$ENI_ID" \
      --instance-id "$INSTANCE_ID" \
      --device-index 1
    sleep 5
  else
    log "ENI $ENI_ID already attached to this instance"
  fi

  IFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -v lo | sort | tail -n1)
  ip link set "$IFACE" up || true

  if ! ip -br a show dev "$IFACE" | grep -q "$VIP"; then
    ip addr add "$VIP/$SUBNET_MASK" dev "$IFACE"
    log "Assigned VIP $VIP/$SUBNET_MASK to $IFACE"
  else
    log "VIP $VIP/$SUBNET_MASK already present on $IFACE"
  fi

  log "Associating EIP allocation $ALLOC_ID with ENI $ENI_ID and private IP $VIP"
  aws ec2 associate-address --region "$REGION" \
    --allocation-id "$ALLOC_ID" \
    --network-interface-id "$ENI_ID" \
    --private-ip-address "$VIP" || true

elif [[ "$ACTION" == "detach" ]]; then
  ATTACHMENT_ID=$(aws ec2 describe-network-interfaces --region "$REGION" \
    --network-interface-ids "$ENI_ID" \
    --query 'NetworkInterfaces[0].Attachment.AttachmentId' --output text)

  if [[ "$ATTACHMENT_ID" != "None" && "$ATTACHMENT_ID" != "null" ]]; then
    log "Detaching ENI $ENI_ID (Attachment $ATTACHMENT_ID)"
    aws ec2 detach-network-interface --region "$REGION" \
      --attachment-id "$ATTACHMENT_ID" --force
  else
    log "ENI $ENI_ID not attached, nothing to do"
  fi
fi
EOF

sudo sed -i "s|__ENI_ID__|$ENI_ID|g" /etc/keepalived/eni-move.sh
sudo sed -i "s|__REGION__|$REGION|g" /etc/keepalived/eni-move.sh
sudo sed -i "s|__VIP__|$VIP|g" /etc/keepalived/eni-move.sh
sudo sed -i "s|__ALLOC_ID__|$ALLOC_ID|g" /etc/keepalived/eni-move.sh
sudo sed -i "s|__SUBNET_MASK__|$SUBNET_MASK|g" /etc/keepalived/eni-move.sh
sudo chmod +x /etc/keepalived/eni-move.sh

  # Keepalived config
  cat <<EOF | sudo tee /etc/keepalived/keepalived.conf >/dev/null
global_defs {
   script_user root
   enable_script_security
   max_auto_priority 2
}

vrrp_script chk_proxysql {
    script "$(which nc) -z 127.0.0.1 6033"
    interval 2
    rise 1
    fall 2
}

vrrp_instance VI_1 {
    state BACKUP
    interface ${IFACE}
    virtual_router_id 51
    priority 1
    advert_int 1

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

    nopreempt

    garp_master_delay 5
    garp_master_repeat 2
    garp_master_refresh 10

    notify_master "/etc/keepalived/eni-move.sh attach"
    notify_backup "/etc/keepalived/eni-move.sh detach"
    notify_fault  "/etc/keepalived/eni-move.sh detach"
}
EOF

  log INFO "Starting keepalived service"
  sudo systemctl enable keepalived >/dev/null 2>&1
  sudo systemctl restart keepalived >/dev/null 2>&1

  log INFO "BACKUP setup complete. ENI ID = $ENI_ID (Region: $REGION)"
}

main
