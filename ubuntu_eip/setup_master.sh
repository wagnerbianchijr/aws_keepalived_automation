#!/usr/bin/env bash

# =============================================================================
# Script Name : setup_master.sh
# Author      : Bianchi (bianchi@readyset.io)
# Version     : v1.1-eip-eni
# Date        : 2025-09-15
# Language    : bash
# Description : Bootstrap MASTER node with Keepalived, Elastic IP, ProxySQL,
#               and a dedicated ENI for HA project.
# =============================================================================

set -euo pipefail

#: Constants
EIP_TAG_NAME="Readyset.io HA Elastic IP"

log() {
  echo "$(date '+%b %d %H:%M:%S') [$1] $2"
}

enable_ip_forward() {
  sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
  current_value=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)
  if [ "$current_value" -ne 1 ]; then
    log ERROR "Could not enable ip_forward. Please check manually."
    exit 1
  fi
}

install_pkg() {
  local pkg="$1"
  if ! dpkg -s "$pkg" >/dev/null 2>&1; then
    log INFO "Installing and configuring $pkg..."
    sudo apt-get -qq update -y && sudo apt-get -qq install -y "$pkg" >/dev/null 2>&1
  fi
}

install_proxysql() {
  if ! command -v proxysql >/dev/null 2>&1; then
    log INFO "Installing and configuring ProxySQL..."
    local api_url="https://api.github.com/repos/sysown/proxysql/releases/latest"
    local latest_url
    latest_url=$(curl -sL "$api_url" | jq -r '.assets[] | select(.name | endswith("amd64.deb")).browser_download_url' | head -n1)
    curl -sSL -o /tmp/proxysql.deb "$latest_url" >/dev/null 2>&1
    sudo apt-get -qq install -y libaio1t64 >/dev/null 2>&1 || true
    sudo dpkg -i /tmp/proxysql.deb >/dev/null 2>&1 || true
    log INFO "ProxySQL installed successfully"
  fi
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

main() {
  log INFO "Starting setup MASTER with dedicated ENI + EIP"

  enable_ip_forward
  install_pkg keepalived
  install_pkg curl
  install_pkg jq
  install_pkg unzip
  install_pkg netcat-openbsd

  if ! command -v aws >/dev/null 2>&1; then
    log INFO "Installing AWS CLI v2..."
    curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
    unzip -q /tmp/awscliv2.zip -d /tmp
    sudo /tmp/aws/install
  fi

  install_proxysql

# Collect inputs
ask_input "=> Enter AWS Region (e.g. us-east-1)" REGION
ask_input "=> Enter Subnet ID for Project ENI (e.g. subnet-1ea42441)" SUBNET_ID
ask_input "=> Enter Security Group ID for Project ENI (e.g. sg-0aba3ccd66cf6ea50)" SG_ID
ask_input "=> Enter Backup node Private IP (e.g. 172.31.45.2)" PEER_IP
ask_input "=> Enter the Primary Network Interface name (e.g. ens3)" IFACE
ask_input "=> Enter the Allocation ID of existing EIP (e.g. eipalloc-0c9600a9215acbfb0)" ALLOCATION_ID

# Show all inputs
cat <<EOF

Please confirm the following inputs:
  AWS Region              : $REGION
  Subnet ID               : $SUBNET_ID
  Security Group ID       : $SG_ID
  Backup node Private IP  : $PEER_IP
  Primary NIC Interface   : $IFACE
  Allocation ID (EIP)     : $ALLOCATION_ID

EOF

read -rp "Continue with these values? (y/N): " CONFIRM
CONFIRM=${CONFIRM,,}  # lowercase
if [[ "$CONFIRM" != "y" ]]; then
  echo "Aborted by user."
  exit 1
fi

  log INFO "Inputs confirmed, checking the Elastic IP $ALLOCATION_ID..."

  EXISTS=$(aws ec2 describe-addresses \
    --allocation-ids "$ALLOCATION_ID" \
    --region "$REGION" \
    --query 'Addresses[0].AllocationId' \
    --output text 2>/dev/null || true)

if [[ -z "$EXISTS" || "$EXISTS" == "None" ]]; then
  log ERROR "Elastic IP $ALLOCATION_ID not found in $REGION"
  exit 1
fi

if ! CREATE_TAGS_OUTPUT=$(aws ec2 create-tags \
  --resources "$ALLOCATION_ID" \
  --tags Key=Name,Value="$EIP_TAG_NAME" \
  --region "$REGION" 2>&1); then
  log ERROR "Failed to update tag for $ALLOCATION_ID. AWS CLI output: $CREATE_TAGS_OUTPUT"
  exit 1
fi

log INFO "The Tag:Name was set to '$EIP_TAG_NAME' for Elastic IP $ALLOCATION_ID"

  TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
  INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
    http://169.254.169.254/latest/meta-data/instance-id)

  # Ensure project ENI exists
  PROJECT_ENI=$(aws ec2 describe-instances --instance-id "$INSTANCE_ID" --region "$REGION" \
    --query 'Reservations[0].Instances[0].NetworkInterfaces[?Attachment.DeviceIndex==`1`].NetworkInterfaceId' \
    --output text 2>/dev/null)

  if [[ -z "$PROJECT_ENI" || "$PROJECT_ENI" == "None" ]]; then
    log INFO "Creating new dedicated ENI for the HA project..."
    PROJECT_ENI=$(aws ec2 create-network-interface \
      --region "$REGION" --subnet-id "$SUBNET_ID" \
      --groups "$SG_ID" --description "Project HA ENI" \
      --query 'NetworkInterface.NetworkInterfaceId' --output text 2>/dev/null)
    aws ec2 attach-network-interface \
      --region "$REGION" --network-interface-id "$PROJECT_ENI" \
      --instance-id "$INSTANCE_ID" --device-index 1 >/dev/null 2>&1
    log INFO "Dedicated ENI created and attached: $PROJECT_ENI"
  else
    log INFO "Reusing existing ENI for project: $PROJECT_ENI"
  fi
  echo "$PROJECT_ENI" | sudo tee /etc/keepalived/project-eni-id >/dev/null

  # Allocate EIP if needed
  if [[ -z "$ALLOCATION_ID" ]]; then
    ALLOCATION_ID=$(aws ec2 allocate-address --domain vpc --region "$REGION" \
      --query 'AllocationId' --output text )
    log INFO "Allocated new EIP AllocationId: $ALLOCATION_ID"
  else
    log INFO "Using provided AllocationId: $ALLOCATION_ID"
  fi

  # Initial association to project ENI
  CURRENT_ASSOC=$(aws ec2 describe-addresses --region "$REGION" \
    --allocation-ids "$ALLOCATION_ID" \
    --query 'Addresses[0].AssociationId' --output text || echo "None") 2>/dev/null
  if [[ "$CURRENT_ASSOC" != "None" && "$CURRENT_ASSOC" != "null" ]]; then
    aws ec2 disassociate-address --region "$REGION" --association-id "$CURRENT_ASSOC" || true
  fi
  aws ec2 associate-address --region "$REGION" \
    --allocation-id "$ALLOCATION_ID" \
    --network-interface-id "$PROJECT_ENI" >/dev/null 2>&1

  # Ensure ProxySQL is up
  if ! pgrep -x proxysql >/dev/null; then
    sudo systemctl enable --now proxysql >/dev/null 2>&1
    sleep 3
  fi

  # eip-move.sh
  cat <<'EOF' | sudo tee /etc/keepalived/eip-move.sh >/dev/null
#!/usr/bin/env bash
set -euo pipefail
PATH=/usr/local/bin:/usr/bin:/bin

ALLOCATION_ID="__ALLOCATION_ID__"
REGION="__REGION__"
PROJECT_ENI=$(cat /etc/keepalived/project-eni-id)

log() { logger "Keepalived: $*"; }

ACTION="${1:-attach}"

if [[ "$ACTION" == "attach" ]]; then
  CURRENT_ASSOC=$(aws ec2 describe-addresses --region "$REGION" \
      --allocation-ids "$ALLOCATION_ID" \
      --query 'Addresses[0].AssociationId' --output text || echo "None")
  if [[ "$CURRENT_ASSOC" != "None" && "$CURRENT_ASSOC" != "null" ]]; then
    log "Disassociating old EIP association $CURRENT_ASSOC"
    aws ec2 disassociate-address --region "$REGION" --association-id "$CURRENT_ASSOC" || true
    sleep 2
  fi
  log "Associating EIP to ENI $PROJECT_ENI"
  aws ec2 associate-address --region "$REGION" \
      --allocation-id "$ALLOCATION_ID" \
      --network-interface-id "$PROJECT_ENI"
elif [[ "$ACTION" == "detach" ]]; then
  CURRENT_ASSOC=$(aws ec2 describe-addresses --region "$REGION" \
      --allocation-ids "$ALLOCATION_ID" \
      --query 'Addresses[0].AssociationId' --output text || echo "None")
  if [[ "$CURRENT_ASSOC" != "None" && "$CURRENT_ASSOC" != "null" ]]; then
    log "Detaching EIP association $CURRENT_ASSOC"
    aws ec2 disassociate-address --region "$REGION" --association-id "$CURRENT_ASSOC" || true
  fi
else
  log "Unknown action: $ACTION"
  exit 1
fi
EOF
  sudo sed -i "s|__ALLOCATION_ID__|$ALLOCATION_ID|g" /etc/keepalived/eip-move.sh
  sudo sed -i "s|__REGION__|$REGION|g" /etc/keepalived/eip-move.sh
  sudo chmod +x /etc/keepalived/eip-move.sh

  # keepalived.conf
  cat <<EOF | sudo tee /etc/keepalived/keepalived.conf >/dev/null
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

    unicast_src_ip $(hostname -I | awk '{print $1}')/32
    unicast_peer {
        ${PEER_IP}/32
    }

    track_script {
        chk_proxysql
    }

    notify_master "/etc/keepalived/eip-move.sh attach"
    notify_backup "/etc/keepalived/eip-move.sh detach"
    notify_fault  "/etc/keepalived/eip-move.sh detach"
}
EOF

  sudo systemctl enable keepalived >/dev/null 2>&1
  sudo systemctl restart keepalived >/dev/null 2>&1

  log INFO "Setup complete. Dedicated ENI: $PROJECT_ENI, EIP: $ALLOCATION_ID"
}

main
