#!/bin/bash
set -euo pipefail

log() {
  LEVEL=$1; shift
  echo "[$LEVEL] $*"
}

REGION="us-east-1"   # adjust as needed

# ===============================
# STEP 1 - Ensure AWS CLI installed
# ===============================
if ! command -v aws >/dev/null 2>&1; then
  log WARN "aws CLI not found. Installing AWS CLI v2..."

  # Amazon Linux / Ubuntu compatible installer
  TMP_DIR=$(mktemp -d)
  cd "$TMP_DIR"
  curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
  unzip -q awscliv2.zip
  sudo ./aws/install

  cd -
  rm -rf "$TMP_DIR"

  if ! command -v aws >/dev/null 2>&1; then
    log ERROR "Failed to install aws CLI. Please install manually."
    exit 1
  fi
  log INFO "aws CLI installed successfully."
else
  log INFO "aws CLI is installed: $(aws --version)"
fi

# ===============================
# STEP 2 - Get Instance Metadata
# ===============================
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 60")

INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)

ROLE_NAME=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/iam/security-credentials/ || true)

if [[ -z "$ROLE_NAME" ]]; then
  log ERROR "No IAM role attached to this instance."
  exit 1
fi

log INFO "Instance ID: $INSTANCE_ID"
log INFO "Attached IAM Role (from metadata): $ROLE_NAME"

# ===============================
# STEP 3 - Resolve role policies
# ===============================
ROLE_ARN=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --region "$REGION" \
  --query "Reservations[0].Instances[0].IamInstanceProfile.Arn" \
  --output text)

if [[ "$ROLE_ARN" == "None" ]]; then
  log ERROR "Could not retrieve IAM instance profile ARN."
  exit 1
fi

INSTANCE_PROFILE_NAME=$(basename "$ROLE_ARN")

IAM_ROLE_NAME=$(aws iam get-instance-profile \
  --instance-profile-name "$INSTANCE_PROFILE_NAME" \
  --query "InstanceProfile.Roles[0].RoleName" \
  --output text)

log INFO "Resolved IAM Role Name: $IAM_ROLE_NAME"
log INFO "Fetching role policy contents..."

# Inline policies
INLINE_POLICIES=$(aws iam list-role-policies \
  --role-name "$IAM_ROLE_NAME" \
  --query "PolicyNames[]" \
  --output text)

if [[ -n "$INLINE_POLICIES" ]]; then
  for P in $INLINE_POLICIES; do
    log INFO "Inline Policy: $P"
    aws iam get-role-policy \
      --role-name "$IAM_ROLE_NAME" \
      --policy-name "$P" \
      --query "PolicyDocument" \
      --output json | jq .
  done
else
  log INFO "No inline policies found for role $IAM_ROLE_NAME"
fi

# Attached managed policies
ATTACHED_POLICIES=$(aws iam list-attached-role-policies \
  --role-name "$IAM_ROLE_NAME" \
  --query "AttachedPolicies[].PolicyArn" \
  --output text)

if [[ -n "$ATTACHED_POLICIES" ]]; then
  for PARN in $ATTACHED_POLICIES; do
    log INFO "Attached Managed Policy: $PARN"
    VERSION=$(aws iam get-policy \
      --policy-arn "$PARN" \
      --query "Policy.DefaultVersionId" \
      --output text)
    aws iam get-policy-version \
      --policy-arn "$PARN" \
      --version-id "$VERSION" \
      --query "PolicyVersion.Document" \
      --output json | jq .
  done
else
  log INFO "No attached managed policies found for role $IAM_ROLE_NAME"
fi

log INFO "Role check complete."
