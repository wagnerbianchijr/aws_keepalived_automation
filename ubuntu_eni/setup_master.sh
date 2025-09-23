#!/usr/bin/env bash

# =============================================================================
# Script Name : setup_master.sh
# Author      : Bianchi (bianchi@readyset.io)
# Version     : v0.1
# Date        : 2025-09-11
# Language    : bash
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

  #log INFO "Downloading $latest_url"
  curl -SL -o /tmp/proxysql-latest.deb "$latest_url" >/dev/null 2>&1
  sudo apt-get -qq install -y libaio1t64 >/dev/null 2>&1
  sudo dpkg -i /tmp/proxysql-latest.deb >/dev/null 2>&1 
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
  ENI_DESC=${ENI_DESC:-"Readyset.io Keepalived ENI"}
  SUBNET_ID=${SUBNET_ID:-subnet-1ea42441}
  SG_ID=${SG_ID:-sg-0aba3ccd66cf6ea50}
  ALLOC_ID=${ALLOC_ID:-eipalloc-0f7ce09357b2dec5e}
  PEER_IP=${PEER_IP:-172.31.37.44}
  IFACE=${IFACE:-ens5}
  SUBNET_MASK=${SUBNET_MASK:-20}

  # Gather user input with defaults
  ask_input "Enter AWS Region (e.g. us-east-1)" REGION
  ask_input "Enter VIP (e.g. 172.31.40.200)" VIP
  ask_input "Enter the EIP Allocation ID (e.g. eipalloc-0f7ce09357b2dec5e)" ALLOC_ID
  ask_input "Enter Subnet ID (e.g. subnet-1ea42441)" SUBNET_ID
  ask_input "Enter Security Group ID (e.g. sg-0aba3ccd66cf6ea50)" SG_ID
  ask_input "Enter Backup node private IP (e.g. 172.31.37.44)" PEER_IP
  ask_input "Enter the Primary NIC Interface name (e.g. ens5)" IFACE
  ask_input "Enter the Primary NIC Subnet Mask (e.g. 20)" SUBNET_MASK

# Show all inputs
cat <<EOF

Please confirm the following inputs:
  AWS Region              : $REGION
  VIP                     : $VIP
  EIP Allocation ID       : $ALLOC_ID
  Subnet ID               : $SUBNET_ID
  Security Group ID       : $SG_ID
  Backup node Private IP  : $PEER_IP
  Primary NIC Interface   : $IFACE
  Subnet Mask / CIDR      : $SUBNET_MASK

EOF

read -rp "Continue with these values? (y/N): " CONFIRM
CONFIRM=${CONFIRM,,}  # lowercase
if [[ "$CONFIRM" != "y" ]]; then
  echo "Aborted by user."
  exit 1
fi

log INFO "Inputs confirmed, let's rock it..."

  # Get instance-id with IMDSv2
  TOKEN=$(curl -S -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
  INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)

  # Create ENI
  ENI_ID=$(aws ec2 create-network-interface \
    --region "$REGION" \
    --subnet-id "$SUBNET_ID" \
    --groups "$SG_ID" \
    --private-ip-address "$VIP" \
    --description "$ENI_DESC" \
    --query 'NetworkInterface.NetworkInterfaceId' \
    --output text)
  
    #: Tagging the ENI
  aws ec2 create-tags \
    --resources "$ENI_ID" \
    --tags Key=Name,Value="Readyset.io HA Dedicated ENI" \
    --region "$REGION" >/dev/null 2>&1

  log INFO "Created and tagged the new ENI with ID $ENI_ID"

  # Attach ENI - he we can have an issue if the ENI secondary is already attached
  aws ec2 attach-network-interface \
    --region "$REGION" \
    --network-interface-id "$ENI_ID" \
    --instance-id "$INSTANCE_ID" \
    --device-index 1 >/dev/null 2>&1 || {
      log ERROR "Failed to attach ENI $ENI_ID to instance $INSTANCE_ID. Please check AWS Console."
      exit 1
    }

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
    log INFO "ProxySQL not running, starting service and enabling on boot..."
    sudo systemctl enable --now proxysql.service >/dev/null 2>&1
    sleep 3
  else
    log INFO "ProxySQL already running"
  fi

  # ENI move script
  cat <<'EOF' | sudo tee /etc/keepalived/eni-move.sh >/dev/null
#!/usr/bin/env bash
set -euo pipefail
PATH=/usr/local/bin:/usr/bin:/bin

ENI_ID="__ENI_ID__"
REGION="__REGION__"
VIP="__VIP__"
ALLOC_ID="__ALLOC_ID__"   # Elastic IP allocation-id

log() { logger "Keepalived: $*"; }

# Use IMDSv2 token
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

  # Ensure NIC is up and VIP is assigned
  IFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -v lo | sort | tail -n1)
  ip link set "$IFACE" up || true

  if ! ip -br a show dev "$IFACE" | grep -q "$VIP"; then
    ip addr add "$VIP/$SUBNET_MASK" dev "$IFACE"
    log "Assigned VIP $VIP/$SUBNET_MASK to $IFACE"
  else
    log "VIP $VIP/$SUBNET_MASK already present on $IFACE"
  fi

  # --- Ensure EIP is associated with ENI+VIP ---
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
    priority 2
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

    #: Do not preempt the MASTER role, even if this node has a higher priority.
    nopreempt

    #: This sets a delay (in seconds) after becoming MASTER before sending the first GARP. Default is 0.
    garp_master_delay 5

    #: Number of GARP packets to send when transitioning to MASTER. Default is 1.
    #: This is useful when you have multiple VIPs and want to ensure all ARP caches
    #: in the network are updated.
    garp_master_repeat 2

    #: Interval (in seconds) between GARP packets.
    #: The total time to send GARP packets is garp_master_delay + (garp_master_repeat * garp_master_refresh)
    #: e.g. with the current settings: 5 + (2 * 10) = 25 seconds total
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

  log INFO "MASTER setup complete. ENI ID = $ENI_ID (Region: $REGION)"
}

main
