#!/bin/bash
# ==========================================================
# Setup script for MASTER node
# - Creates ENI
# - Configures Keepalived with ENI failover and ProxySQL check
# - Written by Wagner Bianchi - bianchi@readyset.io
# ==========================================================

set -euo pipefail

echo "Enter the VIP (e.g., 172.31.38.213):"
read VIP
echo "Enter ENI description:"
read ENI_DESC
echo "Enter Subnet ID (e.g., subnet-xxxx):"
read SUBNET_ID
echo "Enter Security Group ID (e.g., sg-xxxx):"
read SG_ID
echo "Enter the PEER IP (Backup Node private IP):"
read PEER_IP

ROLE_NAME="KeepalivedENIRole"
AUTH_PASS="S3cR3tP@"   # strong 8-char password

# ----------------------------------------------------------
# Get instance metadata (IMDSv2)
# ----------------------------------------------------------
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)
LOCAL_IP=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/local-ipv4)

# ----------------------------------------------------------
# Package check and install
# ----------------------------------------------------------
for pkg in keepalived awscli proxysql; do
  if dpkg -l | grep -qw "$pkg"; then
    echo "✅ Package '$pkg' already installed, moving on..."
  else
    echo "⚠️  Package '$pkg' is missing."
    read -p "Do you want to install '$pkg'? (yes/no): " choice
    if [[ "$choice" == "yes" ]]; then
      sudo apt update
      sudo apt install -y "$pkg"
      echo "✅ Installed '$pkg'."
    else
      echo "❌ Package '$pkg' is required. Exiting."
      exit 1
    fi
  fi
done

# ----------------------------------------------------------
# Create ENI
# ----------------------------------------------------------
ENI_ID=$(aws ec2 create-network-interface \
  --subnet-id "$SUBNET_ID" \
  --groups "$SG_ID" \
  --description "$ENI_DESC" \
  --private-ip-address "$VIP" \
  --query "NetworkInterface.NetworkInterfaceId" \
  --output text)
echo "Created ENI: $ENI_ID"

# ----------------------------------------------------------
# IAM Role attachment
# ----------------------------------------------------------
aws iam create-instance-profile --instance-profile-name "$ROLE_NAME" || true
aws iam add-role-to-instance-profile --instance-profile-name "$ROLE_NAME" --role-name "$ROLE_NAME" || true
aws ec2 associate-iam-instance-profile --instance-id "$INSTANCE_ID" --iam-instance-profile Name="$ROLE_NAME" || true

# ----------------------------------------------------------
# eni-move.sh
# ----------------------------------------------------------
sudo tee /etc/keepalived/eni-move.sh > /dev/null <<EOF
#!/bin/bash
set -e
export PATH=/usr/local/bin:/usr/bin:/bin
ENI_ID="$ENI_ID"
AWS_BIN=\$(which aws)
TOKEN=\$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCE_ID=\$(curl -s -H "X-aws-ec2-metadata-token: \$TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
ACTION=\$1
if [ "\$ACTION" = "attach" ]; then
  ATTACHMENT_ID=\$(\$AWS_BIN ec2 describe-network-interfaces --network-interface-ids \$ENI_ID --query 'NetworkInterfaces[0].Attachment.AttachmentId' --output text)
  ATTACHED_TO=\$(\$AWS_BIN ec2 describe-network-interfaces --network-interface-ids \$ENI_ID --query 'NetworkInterfaces[0].Attachment.InstanceId' --output text)
  if [ "\$ATTACHED_TO" != "None" ] && [ "\$ATTACHED_TO" != "\$INSTANCE_ID" ]; then
    \$AWS_BIN ec2 detach-network-interface --attachment-id \$ATTACHMENT_ID --force
    sleep 5
  fi
  \$AWS_BIN ec2 attach-network-interface --network-interface-id \$ENI_ID --instance-id \$INSTANCE_ID --device-index 1
elif [ "\$ACTION" = "detach" ]; then
  ATTACHMENT_ID=\$(\$AWS_BIN ec2 describe-network-interfaces --network-interface-ids \$ENI_ID --query 'NetworkInterfaces[0].Attachment.AttachmentId' --output text)
  if [ "\$ATTACHMENT_ID" != "None" ]; then
    \$AWS_BIN ec2 detach-network-interface --attachment-id \$ATTACHMENT_ID --force
  fi
fi
exit 0
EOF
sudo chmod 755 /etc/keepalived/eni-move.sh

# ----------------------------------------------------------
# ProxySQL health check
# ----------------------------------------------------------
sudo tee /usr/local/bin/check-proxysql.sh > /dev/null <<'EOF'
#!/bin/bash
if nc -z 127.0.0.1 6033; then
  exit 0
else
  exit 1
fi
EOF
sudo chmod 755 /usr/local/bin/check-proxysql.sh

# ----------------------------------------------------------
# keepalived.conf
# ----------------------------------------------------------
sudo tee /etc/keepalived/keepalived.conf > /dev/null <<EOF
global_defs {
    script_user root
    enable_script_security
}

vrrp_script chk_proxysql {
    script "/usr/local/bin/check-proxysql.sh"
    interval 2
    timeout 2
    fall 2
    rise 2
    weight -30
    user root
}

vrrp_instance VI_1 {
    state BACKUP
    interface ens5
    virtual_router_id 51
    priority 101
    advert_int 2
    nopreempt
    garp_master_delay 5

    authentication {
        auth_type PASS
        auth_pass $AUTH_PASS
    }

    unicast_src_ip $LOCAL_IP
    unicast_peer {
        $PEER_IP
    }

    virtual_ipaddress {
        $VIP dev ens5
    }

    track_interface { ens5 }
    track_script { chk_proxysql }

    notify_master "/etc/keepalived/eni-move.sh attach"
    notify_backup "/etc/keepalived/eni-move.sh detach"
    notify_fault  "/etc/keepalived/eni-move.sh detach"
}
EOF

# ----------------------------------------------------------
# Service start
# ----------------------------------------------------------
sudo systemctl daemon-reload
sudo systemctl enable keepalived
sudo systemctl restart keepalived

# ----------------------------------------------------------
# Summary
# ----------------------------------------------------------
echo "--------------------------------------------------"
echo " MASTER NODE SETUP COMPLETE"
echo " Instance ID : $INSTANCE_ID"
echo " Local IP    : $LOCAL_IP"
echo " Peer IP     : $PEER_IP"
echo " VIP / ENI   : $VIP / $ENI_ID"
echo " Keepalived  : priority 101, nopreempt"
echo "--------------------------------------------------"

