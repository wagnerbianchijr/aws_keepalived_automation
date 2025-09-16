#!/usr/bin/env bash

# =============================================================================
# Script Name : rollback_backup.sh
# Author      : Bianchi (bianchi@readyset.io)
# Version     : v1.0-lite-clean
# Date        : 2025-09-16
# Description : Rollback only local resources created by setup_backup.sh.
#               Leaves IAM role/profile and the EIP allocation intact.
# =============================================================================

set -euo pipefail

log() {
  echo "$(date '+%b %d %H:%M:%S') [$1] $2"
}

REGION=${REGION:-us-east-1}
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
       -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
       http://169.254.169.254/latest/meta-data/instance-id)

PROJECT_ENI=$(test -f /etc/keepalived/project-eni-id && cat /etc/keepalived/project-eni-id || echo "")
ALLOCATION_ID=${ALLOCATION_ID:-""}

# -----------------------------------------------------------------------------
# 1. Stop and remove services/configs
# -----------------------------------------------------------------------------
log INFO "Stopping Keepalived and ProxySQL..."
sudo systemctl stop keepalived >/dev/null 2>&1 || true
sudo systemctl disable keepalived >/dev/null 2>&1 || true
sudo systemctl stop proxysql >/dev/null 2>&1 || true
sudo systemctl disable proxysql >/dev/null 2>&1 || true

log INFO "Removing Keepalived custom configs/scripts..."
sudo rm -f /etc/keepalived/eip-move.sh \
            /etc/keepalived/project-eni-id \
            /etc/keepalived/keepalived.conf

# -----------------------------------------------------------------------------
# 2. Uninstall packages we installed
# -----------------------------------------------------------------------------
log INFO "Removing keepalived, awscli, proxysql packages..."
sudo apt-get -y remove --purge keepalived awscli proxysql >/dev/null 2>&1 || true
sudo apt-get -y autoremove >/dev/null 2>&1 || true

# -----------------------------------------------------------------------------
# 3. AWS: Disassociate the EIP (if it ended here on failover)
# -----------------------------------------------------------------------------
if [[ -n "$ALLOCATION_ID" ]]; then
  ASSOC_ID=$(aws ec2 describe-addresses --region "$REGION" \
    --allocation-ids "$ALLOCATION_ID" \
    --query 'Addresses[0].AssociationId' \
    --output text 2>/dev/null || echo "None")
  if [[ "$ASSOC_ID" != "None" && "$ASSOC_ID" != "null" ]]; then
    log INFO "Disassociating EIP AllocationId $ALLOCATION_ID"
    aws ec2 disassociate-address --region "$REGION" \
      --association-id "$ASSOC_ID" >/dev/null 2>&1 || true
  else
    log INFO "EIP not associated, skipping disassociation"
  fi
else
  log WARN "No AllocationId provided, skipping EIP disassociation"
fi

# -----------------------------------------------------------------------------
# 4. AWS: Detach and delete the ENI
# -----------------------------------------------------------------------------
if [[ -n "$PROJECT_ENI" ]]; then
  ATTACHMENT_ID=$(aws ec2 describe-network-interfaces --region "$REGION" \
    --network-interface-ids "$PROJECT_ENI" \
    --query 'NetworkInterfaces[0].Attachment.AttachmentId' \
    --output text 2>/dev/null || echo "None")
  if [[ "$ATTACHMENT_ID" != "None" && "$ATTACHMENT_ID" != "null" ]]; then
    log INFO "Detaching ENI $PROJECT_ENI"
    aws ec2 detach-network-interface --region "$REGION" \
      --attachment-id "$ATTACHMENT_ID" --force >/dev/null 2>&1 || true
    sleep 3
  fi
  log INFO "Deleting ENI $PROJECT_ENI"
  aws ec2 delete-network-interface --region "$REGION" \
    --network-interface-id "$PROJECT_ENI" >/dev/null 2>&1 || true
else
  log WARN "No project ENI recorded, skipping ENI cleanup"
fi

log INFO "Rollback complete. EIP ($ALLOCATION_ID) preserved."
