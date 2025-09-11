#!/bin/bash
set -e

# ================
# Logging function
# ================
log() {
  local level="$1"; shift
  local msg="$*"
  local ts
  ts=$(date +"%b %d %H:%M:%S")
  echo "$ts [$level] $msg"
}

# ==========================
# Check if package installed
# ==========================
check_package() {
  local pkg="$1"
  if dpkg -s "$pkg" >/dev/null 2>&1; then
    log INFO "Package $pkg already installed"
    return 0
  else
    return 1
  fi
}

# ==========================
# Install keepalived
# ==========================
install_keepalived() {
  if ! check_package keepalived; then
    log INFO "Installing keepalived..."
    apt-get update -y && apt-get install -y keepalived
    log INFO "keepalived installation complete"
  fi
}

# ==========================
# Install ProxySQL
# ==========================
install_proxysql() {
  if ! command -v proxysql >/dev/null 2>&1; then
    log INFO "ProxySQL not found, installing latest release from GitHub..."
    LATEST_URL=$(curl -s https://api.github.com/repos/sysown/proxysql/releases/latest \
      | grep "browser_download_url.*deb" | grep ubuntu24 | cut -d '"' -f 4 | head -n 1)

    if [[ -z "$LATEST_URL" ]]; then
      log ERROR "Could not fetch latest ProxySQL release URL"
      exit 1
    fi

    TMP_DEB="/tmp/proxysql_latest.deb"
    curl -L "$LATEST_URL" -o "$TMP_DEB"
    apt-get update -y && apt-get install -y libmariadb3
    dpkg -i "$TMP_DEB" || apt-get install -f -y
    rm -f "$TMP_DEB"
    log INFO "ProxySQL installation complete"
  else
    VERSION=$(proxysql --version 2>/dev/null || true)
    log INFO "ProxySQL already installed: $VERSION"
  fi
}

# ==========================
# Install AWS CLI v2
# ==========================
install_awscli() {
  if ! command -v aws >/dev/null 2>&1; then
    log INFO "Installing AWS CLI v2..."
    apt-get update -y && apt-get install -y unzip curl
    curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip"
    unzip -q /tmp/awscliv2.zip -d /tmp
    /tmp/aws/install --update
    rm -rf /tmp/aws /tmp/awscliv2.zip
    log INFO "AWS CLI v2 installation complete"
  else
    VERSION=$(aws --version 2>&1)
    log INFO "AWS CLI found: $VERSION"
  fi
}

# ==========================
# Deploy eni-move.sh
# ==========================
deploy_eni_script() {
  local eni_id="$1"
  cat > /etc/keepalived/eni-move.sh <<EOF
#!/bin/bash
set -e
PATH=/usr/local/bin:/usr/bin:/bin
ENI_ID=$eni_id
AWS_BIN=\$(which aws)
TOKEN=\$(curl -s -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCE_ID=\$(curl -s -H "X-aws-ec2-metadata-token: \$TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
ACTION=\$1

log() {
  ts=\$(date +"%b %d %H:%M:%S")
  echo "\$ts Keepalived: \$*"
  logger "Keepalived: \$*"
}

if [[ "\$ACTION" == "attach" ]]; then
  ATTACHMENT_ID=\$("\$AWS_BIN" ec2 describe-network-interfaces --network-interface-ids \$ENI_ID --query 'NetworkInterfaces[0].Attachment.AttachmentId' --output text)
  ATTACHED_TO=\$("\$AWS_BIN" ec2 describe-network-interfaces --network-interface-ids \$ENI_ID --query 'NetworkInterfaces[0].Attachment.InstanceId' --output text)

  if [[ "\$ATTACHED_TO" != "None" && "\$ATTACHED_TO" != "\$INSTANCE_ID" ]]; then
    log "Detaching ENI \$ENI_ID from \$ATTACHED_TO"
    "\$AWS_BIN" ec2 detach-network-interface --attachment-id \$ATTACHMENT_ID --force
    sleep 5
  fi

  log "Attaching ENI \$ENI_ID to \$INSTANCE_ID"
  "\$AWS_BIN" ec2 attach-network-interface --network-interface-id \$ENI_ID --instance-id \$INSTANCE_ID --device-index 1
elif [[ "\$ACTION" == "detach" ]]; then
  ATTACHMENT_ID=\$("\$AWS_BIN" ec2 describe-network-interfaces --network-interface-ids \$ENI_ID --query 'NetworkInterfaces[0].Attachment.AttachmentId' --output text)
  if [[ "\$ATTACHMENT_ID" != "None" ]]; then
    log "Detaching ENI \$ENI_ID"
    "\$AWS_BIN" ec2 detach-network-interface --attachment-id \$ATTACHMENT_ID --force
  fi
fi
EOF
  chmod +x /etc/keepalived/eni-move.sh
  log INFO "Deployed eni-move.sh for ENI $eni_id"
}

# ==========================
# Deploy keepalived.conf
# ==========================
deploy_keepalived_conf() {
  local vip="$1"
  local peer_ip="$2"

  cat > /etc/keepalived/keepalived.conf <<EOF
global_defs {
    script_user root
    enable_script_security
}

vrrp_script chk_proxysql {
    script "/usr/bin/nc -z 127.0.0.1 6033"
    interval 2
    timeout 2
    rise 2
    fall 2
}

vrrp_instance VI_1 {
    state MASTER
    interface ens5
    virtual_router_id 51
    priority 101
    advert_int 1
    nopreempt
    authentication {
        auth_type PASS
        auth_pass S3cR3tP@
    }
    unicast_src_ip $(hostname -I | awk '{print $1}')
    unicast_peer {
        $peer_ip
    }
    notify_master "/etc/keepalived/eni-move.sh attach"
    notify_backup "/etc/keepalived/eni-move.sh detach"
    notify_fault  "/etc/keepalived/eni-move.sh detach"
    track_script {
        chk_proxysql
    }
    virtual_ipaddress {
        $vip
    }
}
EOF
  log INFO "Deployed keepalived.conf with VIP $vip and peer $peer_ip"
}

# ==========================
# Main execution
# ==========================
log INFO "Starting setup on MASTER node"

install_keepalived
install_proxysql
install_awscli

read -rp "Enter VIP (e.g. 172.31.40.200): " VIP
read -rp "Enter ENI description: " ENI_DESC
read -rp "Enter Subnet ID: " SUBNET_ID
read -rp "Enter Security Group ID: " SG_ID
read -rp "Enter Backup node private IP: " PEER_IP

# Create ENI
ENI_ID=$(aws ec2 create-network-interface \
  --subnet-id "$SUBNET_ID" \
  --groups "$SG_ID" \
  --description "$ENI_DESC" \
  --private-ip-address "$VIP" \
  --tag-specifications 'ResourceType=network-interface,Tags=[{Key=ha:managed,Value=true}]' \
  --query 'NetworkInterface.NetworkInterfaceId' \
  --output text)

log INFO "Created ENI with ID $ENI_ID"

# Deploy configs
deploy_eni_script "$ENI_ID"
deploy_keepalived_conf "$VIP" "$PEER_IP"

# Start keepalived
log INFO "Starting keepalived service"
systemctl enable keepalived
systemctl restart keepalived

# Wait for ENI/VIP to appear
log INFO "Waiting for ENI $ENI_ID to attach with VIP $VIP..."
for i in {1..15}; do
  if ip -br a | grep -q "$VIP"; then
    log INFO "ENI $ENI_ID successfully attached, VIP $VIP is active."
    break
  fi
  sleep 2
done

log INFO "MASTER setup complete. ENI ID = $ENI_ID"
