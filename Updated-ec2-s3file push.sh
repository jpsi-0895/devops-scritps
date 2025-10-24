#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# ===============================
# CONFIG
# ===============================
REGION="us-east-1"
BACKUP_TIMESTAMP=$(date +'%Y-%m-%d_%H-%M-%S')
BACKUP_DIR="/tmp/ec2-backup-${BACKUP_TIMESTAMP}"

# Detect default user home automatically
USER_HOME=$(eval echo "~$USER")
BACKUP_SOURCE="${USER_HOME}"

# ===============================
# FUNCTIONS
# ===============================

install_awscli_if_missing() {
    if ! command -v aws &>/dev/null; then
        echo "[INFO] AWS CLI not found. Installing AWS CLI v2..."
        sudo apt update -y
        sudo apt install unzip curl -y
        curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
        unzip awscliv2.zip
        sudo ./aws/install
        rm -rf awscliv2.zip aws/
        echo "[INFO] AWS CLI v2 installed successfully."
    else
        echo "[INFO] AWS CLI already installed: $(aws --version)"
    fi
}

check_aws_credentials() {
    if ! aws sts get-caller-identity &>/dev/null; then
        echo "[WARNING] No active AWS credentials found."
        echo "Please configure your credentials:"
        aws configure
    fi
}

create_backup() {
    echo "[INFO] Creating compressed backup from ${BACKUP_SOURCE}..."
    if [ ! -d "$BACKUP_SOURCE" ]; then
        echo "[ERROR] Backup source directory '$BACKUP_SOURCE' not found!"
        exit 1
    fi

    mkdir -p "$BACKUP_DIR"
    TAR_FILE="${BACKUP_DIR}/backup-${BACKUP_TIMESTAMP}.tar.gz"
    tar -czf "$TAR_FILE" -C "$BACKUP_SOURCE" .
    echo "[INFO] Backup created at: $TAR_FILE"
}

upload_to_s3() {
    read -rp "Enter S3 bucket name: " S3_BUCKET
    if ! aws s3 ls "s3://${S3_BUCKET}" &>/dev/null; then
        echo "[INFO] Bucket not found. Creating new bucket: ${S3_BUCKET}"
        aws s3 mb "s3://${S3_BUCKET}" --region "$REGION"
    fi

    echo "[INFO] Uploading backup to s3://${S3_BUCKET}/"
    aws s3 cp "${BACKUP_DIR}/" "s3://${S3_BUCKET}/" --recursive
    echo "[SUCCESS] Backup uploaded successfully to S3!"
}

# ===============================
# MAIN EXECUTION
# ===============================
install_awscli_if_missing
check_aws_credentials
create_backup
upload_to_s3

