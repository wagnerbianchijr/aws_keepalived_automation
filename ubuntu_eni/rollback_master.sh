#!/usr/bin/env bash

# =============================================================================
# Script Name : rollback_master.sh
# Author      : Bianchi (bianchi@readyset.io)
# Version     : v0.1
# Date        : 2025-09-11
# Description : Roll back MASTER setup (Keepalived/ProxySQL/AWS CLI, optional ENI delete).
# =============================================================================

set -euo pipefail

# =========================
# Logging helper
# =========================
log() {
  echo "$(date '+%b %d %H:%M:%S') [$1] $2"
}

# =========================
# Rollback steps
# =========================

# 1. Stop and disable Keepalived
if systemctl is-active --quiet keepalived; then
  log INFO "Stopping Keepalived..."
  sudo systemctl stop keepalived 2>/dev/null || true
fi
if systemctl is-enabled --quiet keepalived; then
  log INFO "Disabling Keepalived..."
  sudo systemctl disable keepalived 2>/dev/null || true
fi

# 2. Remove Keepalived config and scripts
if [[ -f /etc/keepalived/keepalived.conf ]]; then
  log INFO "Removing /etc/keepalived/keepalived.conf"
  sudo rm -f /etc/keepalived/keepalived.conf || true
fi
if [[ -f /etc/keepalived/eni-move.sh ]]; then
  log INFO "Removing /etc/keepalived/eni-move.sh"
  sudo rm -f /etc/keepalived/eni-move.sh || true
fi

# 3. Delete ENI (requires ENI_ID)
if [[ $# -ge 1 ]]; then
  ENI_ID="$1"
  log INFO "Attempting to delete ENI $ENI_ID"
  ATTACHMENT_ID=$(aws ec2 describe-network-interfaces \
    --network-interface-ids "$ENI_ID" \
    --query "NetworkInterfaces[0].Attachment.AttachmentId" \
    --output text 2>/dev/null || echo "None")

  if [[ "$ATTACHMENT_ID" != "None" && "$ATTACHMENT_ID" != "null" ]]; then
    log INFO "Detaching ENI $ENI_ID (Attachment $ATTACHMENT_ID)"
    aws ec2 detach-network-interface --attachment-id "$ATTACHMENT_ID" --force || true
    sleep 5
  fi

  log INFO "Deleting ENI $ENI_ID"
  aws ec2 delete-network-interface --network-interface-id "$ENI_ID" || {
    log ERROR "Failed to delete ENI $ENI_ID"
  }
else
  log INFO "No ENI_ID provided, skipping ENI deletion"
  log INFO "Usage: $0 <eni-id>"
fi

# 4. Optional cleanup of packages
read -rp "Do you want to purge ProxySQL, Keepalived, and AWS CLI packages? [y/N]: " yn
if [[ $yn =~ ^[Yy]$ ]]; then
  log INFO "Purging ProxySQL and Keepalived (apt packages)..."
  sudo apt purge -y -qq proxysql keepalived >/dev/null 2>&1 || true
  sudo apt autoremove -y -qq >/dev/null 2>&1 || true

  # Handle AWS CLI (apt and manual install)
  if command -v aws &>/dev/null; then
    AWS_PATH=$(command -v aws)
    if dpkg -l | grep -q awscli; then
      log INFO "Removing AWS CLI installed via apt..."
      sudo apt purge -y awscli || true
    elif [[ "$AWS_PATH" == "/usr/local/bin/aws" ]]; then
      log INFO "Removing AWS CLI v2 installed via zip..."
      sudo rm -rf /usr/local/aws-cli /usr/local/bin/aws /tmp/aws /tmp/awscli* 2>/dev/null || true
    else
      log INFO "AWS CLI found at $AWS_PATH (not managed by apt), leaving it in place"
    fi
  else
    log INFO "AWS CLI not found on this system"
  fi
else
  log INFO "Leaving ProxySQL, Keepalived, and AWS CLI installed"
fi

log INFO "Rollback complete."
