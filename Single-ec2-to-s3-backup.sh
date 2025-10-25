#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# =======================================================
# EC2 FULL BACKUP & S3 UPLOAD SCRIPT (MERGED VERSION)
# =======================================================

REGION="us-east-1"
AWS_PROFILE=""
INSTANCE_TYPE="t3.micro"
INSTANCE_NAME="ec2-backup-instance"
BACKUP_DIR="/tmp/ec2-backup"
BACKUP_TIMESTAMP=$(date +'%Y-%m-%d_%H-%M-%S')
USER_HOME=$(eval echo "~$USER")
BACKUP_SOURCE="${USER_HOME}"
CREATE_SNAPSHOTS="yes"
SNAPSHOT_TAG="AutoBackup"

# =======================================================
# 0. System Preparation
# =======================================================
echo "[INFO] Updating and upgrading the system..."
sudo apt update -y && sudo apt upgrade -y

# =======================================================
# 1. Install AWS CLI if missing
# =======================================================
if ! command -v aws &>/dev/null; then
    echo "[INFO] Installing AWS CLI v2..."
    sudo apt install unzip curl -y
    curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
    unzip awscliv2.zip
    sudo ./aws/install
    rm -rf awscliv2.zip aws/
else
    echo "[INFO] AWS CLI already installed: $(aws --version)"
fi

# =======================================================
# 2. Verify AWS credentials
# =======================================================
if ! aws sts get-caller-identity &>/dev/null; then
    echo "[WARNING] AWS credentials not configured."
    aws configure
fi

# =======================================================
# 3. User Input
# =======================================================
read -rp "Enter existing S3 bucket name (press Enter to create new): " S3_BUCKET
read -rp "Enter existing EC2 instance ID (press Enter to create new one): " USER_INSTANCE_ID

TIMESTAMP=$(date +%s)
if [ -z "${S3_BUCKET}" ]; then
    S3_BUCKET="ec2-backups-${TIMESTAMP}"
    CREATE_NEW_BUCKET="yes"
else
    CREATE_NEW_BUCKET="no"
fi

if [ -z "${USER_INSTANCE_ID}" ]; then
    CREATE_NEW_INSTANCE="yes"
else
    CREATE_NEW_INSTANCE="no"
fi

IAM_ROLE_NAME="EC2_S3_Backup_Role_${TIMESTAMP}"
INSTANCE_PROFILE_NAME="${IAM_ROLE_NAME}-profile"
SEC_GROUP_NAME="ec2-backup-sg-${TIMESTAMP}"
KEY_NAME="ec2-backup-key-${TIMESTAMP}"

AWS_CLI=(aws --region "${REGION}")
if [ -n "${AWS_PROFILE}" ]; then
  AWS_CLI+=(--profile "${AWS_PROFILE}")
fi
aws_run() { "${AWS_CLI[@]}" "$@"; }

# =======================================================
# 4. Create S3 Bucket (if needed)
# =======================================================
if [ "${CREATE_NEW_BUCKET}" = "yes" ]; then
    echo "[INFO] Creating S3 bucket: ${S3_BUCKET}"
    if [ "${REGION}" = "us-east-1" ]; then
        aws_run s3api create-bucket --bucket "${S3_BUCKET}"
    else
        aws_run s3api create-bucket --bucket "${S3_BUCKET}" \
            --create-bucket-configuration LocationConstraint="${REGION}"
    fi
    aws_run s3api put-bucket-versioning \
        --bucket "${S3_BUCKET}" \
        --versioning-configuration Status=Enabled
    aws_run s3api put-bucket-encryption \
        --bucket "${S3_BUCKET}" \
        --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
    echo "[SUCCESS] S3 bucket created with versioning and encryption."
else
    echo "[INFO] Using existing S3 bucket: ${S3_BUCKET}"
fi

# =======================================================
# 5. Create IAM Role and Instance Profile (if new EC2)
# =======================================================
if [ "${CREATE_NEW_INSTANCE}" = "yes" ]; then
    echo "[INFO] Creating IAM Role for EC2 -> S3 backup..."
    TRUST_FILE=$(mktemp)
    cat > "${TRUST_FILE}" <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect":"Allow",
      "Principal":{"Service":"ec2.amazonaws.com"},
      "Action":"sts:AssumeRole"
    }
  ]
}
JSON
    aws_run iam create-role --role-name "${IAM_ROLE_NAME}" \
        --assume-role-policy-document "file://${TRUST_FILE}" >/dev/null
    ROLE_ARN=$(aws_run iam get-role --role-name "${IAM_ROLE_NAME}" --query 'Role.Arn' --output text)
    rm -f "${TRUST_FILE}"

    POLICY_FILE=$(mktemp)
    cat > "${POLICY_FILE}" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect":"Allow",
      "Action":[ "s3:*" ],
      "Resource":[
        "arn:aws:s3:::${S3_BUCKET}",
        "arn:aws:s3:::${S3_BUCKET}/*"
      ]
    },
    {
      "Effect":"Allow",
      "Action":[
        "ec2:CreateSnapshot","ec2:Describe*","ec2:CreateTags"
      ],
      "Resource":"*"
    }
  ]
}
EOF

    aws_run iam put-role-policy \
        --role-name "${IAM_ROLE_NAME}" \
        --policy-name "${IAM_ROLE_NAME}-policy" \
        --policy-document file://"${POLICY_FILE}"
    rm -f "${POLICY_FILE}"

    aws_run iam create-instance-profile --instance-profile-name "${INSTANCE_PROFILE_NAME}" >/dev/null
    aws_run iam add-role-to-instance-profile \
        --instance-profile-name "${INSTANCE_PROFILE_NAME}" \
        --role-name "${IAM_ROLE_NAME}" >/dev/null

    echo "[SUCCESS] IAM role and instance profile created."
    sleep 10
fi

# =======================================================
# 6. Create EC2 Instance (if needed)
# =======================================================
if [ "${CREATE_NEW_INSTANCE}" = "yes" ]; then
    echo "[INFO] Creating security group..."
    VPC_ID=$(aws_run ec2 describe-vpcs --query 'Vpcs[0].VpcId' --output text)
    SG_ID=$(aws_run ec2 create-security-group \
        --group-name "${SEC_GROUP_NAME}" \
        --description "Backup SG" \
        --vpc-id "${VPC_ID}" \
        --query 'GroupId' --output text)
    aws_run ec2 authorize-security-group-ingress \
        --group-id "${SG_ID}" --protocol tcp --port 22 --cidr 0.0.0.0/0 || true

    echo "[INFO] Creating key pair..."
    aws_run ec2 create-key-pair \
        --key-name "${KEY_NAME}" \
        --query 'KeyMaterial' --output text > "${KEY_NAME}.pem"
    chmod 400 "${KEY_NAME}.pem"

    echo "[INFO] Fetching latest Amazon Linux 2 AMI..."
    AMI_ID=$(aws_run ec2 describe-images \
        --owners 137112412989 \
        --filters "Name=name,Values=amzn2-ami-hvm-*-x86_64-gp2" "Name=state,Values=available" \
        --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
        --output text)

    echo "[INFO] Launching new EC2 instance..."
    USER_DATA_FILE=$(mktemp)
    cat > "${USER_DATA_FILE}" <<EOF
#!/bin/bash
yum install -y awscli jq tar gzip
mkdir -p ${BACKUP_DIR}
tar --exclude=/proc --exclude=/sys --exclude=/dev --exclude=/tmp --exclude=/run -czpf ${BACKUP_DIR}/system-backup.tar.gz /
aws s3 cp ${BACKUP_DIR}/system-backup.tar.gz s3://${S3_BUCKET}/
EOF

    INSTANCE_JSON=$(aws_run ec2 run-instances \
        --image-id "${AMI_ID}" \
        --instance-type "${INSTANCE_TYPE}" \
        --key-name "${KEY_NAME}" \
        --security-group-ids "${SG_ID}" \
        --iam-instance-profile Name="${INSTANCE_PROFILE_NAME}" \
        --user-data file://"${USER_DATA_FILE}" \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${INSTANCE_NAME}}]" \
        --query 'Instances[0]' --output json)

    USER_INSTANCE_ID=$(echo "$INSTANCE_JSON" | jq -r '.InstanceId')
    PUBLIC_IP=$(echo "$INSTANCE_JSON" | jq -r '.PublicIpAddress // "N/A"')

    echo "[SUCCESS] EC2 Instance created: ${USER_INSTANCE_ID} (Public IP: ${PUBLIC_IP})"
    echo "To SSH: ssh -i ${KEY_NAME}.pem ec2-user@${PUBLIC_IP}"
fi

# =======================================================
# 7. Local Backup and Upload
# =======================================================
echo "[INFO] Creating compressed backup from ${BACKUP_SOURCE}..."
mkdir -p "${BACKUP_DIR}"
TAR_FILE="${BACKUP_DIR}/backup-${BACKUP_TIMESTAMP}.tar.gz"
tar -czf "${TAR_FILE}" -C "${BACKUP_SOURCE}" .
echo "[INFO] Uploading local backup to s3://${S3_BUCKET}/"
aws s3 cp "${TAR_FILE}" "s3://${S3_BUCKET}/"
echo "[SUCCESS] Backup completed and uploaded successfully!"

# =======================================================
# END
# =======================================================
echo "[DONE] Backup process completed successfully!"
