#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# =======================================================
# 🧩 EC2 + S3 Full Backup Utility (Dynamic Interactive)
# =======================================================
# Version: 3.2
# Date: $(date +'%Y-%m-%d')
# Note: Handles both files and directories in backup source.
# =======================================================

# --------------------------
# 🧾 Global Configuration
# --------------------------
REGION_DEFAULT="us-east-1"
INSTANCE_TYPE_DEFAULT="t3.micro"
BACKUP_BASE_DIR="/tmp/ec2-backup"
TIMESTAMP=$(date +'%Y%m%d%H%M%S')
LOG_FILE="${BACKUP_BASE_DIR}/backup_${TIMESTAMP}.log"
AWS_PROFILE_DEFAULT="default"

# --------------------------
# 🎨 Colors
# --------------------------
C_RESET="\033[0m"
C_GREEN="\033[1;32m"
C_RED="\033[1;31m"
C_BLUE="\033[1;34m"
C_YELLOW="\033[1;33m"
C_CYAN="\033[1;36m"

log() { echo -e "${C_BLUE}[$(date '+%H:%M:%S')]${C_RESET} $*" | tee -a "$LOG_FILE"; }
success() { echo -e "${C_GREEN}[SUCCESS]${C_RESET} $*" | tee -a "$LOG_FILE"; }
warn() { echo -e "${C_YELLOW}[WARN]${C_RESET} $*" | tee -a "$LOG_FILE"; }
error() { echo -e "${C_RED}[ERROR]${C_RESET} $*" | tee -a "$LOG_FILE"; }

# --------------------------
# Cleanup
# --------------------------
TMP_FILES=()
cleanup() {
  for f in "${TMP_FILES[@]:-}"; do
    [[ -f "$f" ]] && rm -f "$f"
  done
}
trap cleanup EXIT

# =======================================================
# 🔧 System & Dependency Setup
# =======================================================
prepare_system() {
    mkdir -p "$BACKUP_BASE_DIR"
    : > "$LOG_FILE"

    log "Checking dependencies..."
    sudo apt update -y >/dev/null

    if ! command -v aws &>/dev/null; then
        log "Installing AWS CLI v2..."
        sudo apt install -y unzip curl >/dev/null
        curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
        unzip -q awscliv2.zip
        sudo ./aws/install
        rm -rf awscliv2.zip aws/
        success "AWS CLI installed."
    else
        success "AWS CLI detected: $(aws --version 2>&1 | head -n1)"
    fi

    if ! command -v jq &>/dev/null; then
        log "Installing jq..."
        sudo apt install -y jq >/dev/null
    fi
}

# =======================================================
# 🧍 User Configuration Wizard
# =======================================================
user_config() {
    echo -e "\n${C_CYAN}===== AWS BACKUP CONFIGURATION =====${C_RESET}"
    read -rp "AWS Region [${REGION_DEFAULT}]: " REGION
    REGION="${REGION:-$REGION_DEFAULT}"

    read -rp "AWS CLI Profile [${AWS_PROFILE_DEFAULT}]: " AWS_PROFILE
    AWS_PROFILE="${AWS_PROFILE:-$AWS_PROFILE_DEFAULT}"

    read -rp "Enter existing S3 bucket (or leave blank to create new): " S3_BUCKET
    read -rp "Enter EC2 instance ID (or leave blank to create new): " INSTANCE_ID
    read -rp "Backup source path [${HOME}]: " BACKUP_SOURCE
    BACKUP_SOURCE="${BACKUP_SOURCE:-$HOME}"

    # ✅ Validate backup source path
    if [[ ! -e "$BACKUP_SOURCE" ]]; then
        error "Backup source '$BACKUP_SOURCE' does not exist."
        exit 1
    fi

    read -rp "Enable EBS Snapshots (yes/no) [yes]: " ENABLE_SNAP
    ENABLE_SNAP="${ENABLE_SNAP:-yes}"

    read -rp "Compress backup before upload (yes/no) [yes]: " ENABLE_COMPRESS
    ENABLE_COMPRESS="${ENABLE_COMPRESS:-yes}"

    echo ""
    log "Configuration Summary:"
    echo "  Region          : $REGION"
    echo "  AWS Profile     : $AWS_PROFILE"
    echo "  S3 Bucket       : ${S3_BUCKET:-<create new>}"
    echo "  EC2 Instance ID : ${INSTANCE_ID:-<create new>}"
    echo "  Backup Source   : ${BACKUP_SOURCE}"
    echo "  Snapshots       : ${ENABLE_SNAP}"
    echo "  Compression     : ${ENABLE_COMPRESS}"
    echo ""
    read -rp "Proceed with these settings? (y/n): " CONFIRM
    [[ "${CONFIRM,,}" == "y" ]] || { error "User aborted."; exit 1; }
}

# =======================================================
# 🧱 AWS Helper
# =======================================================
aws_cmd() {
    local args=("$@")
    if [[ -n "${AWS_PROFILE:-}" ]]; then
        aws --region "$REGION" --profile "$AWS_PROFILE" "${args[@]}"
    else
        aws --region "$REGION" "${args[@]}"
    fi
}

# =======================================================
# ☁️ Create S3 Bucket
# =======================================================
create_s3_bucket() {
    if [[ -z "${S3_BUCKET}" ]]; then
        S3_BUCKET="ec2-backup-${TIMESTAMP}"
        log "Creating S3 bucket: ${S3_BUCKET}"
        if [[ "$REGION" == "us-east-1" ]]; then
            aws_cmd s3api create-bucket --bucket "$S3_BUCKET" >/dev/null
        else
            aws_cmd s3api create-bucket --bucket "$S3_BUCKET" \
                --create-bucket-configuration LocationConstraint="$REGION" >/dev/null
        fi
        aws_cmd s3api put-bucket-versioning --bucket "$S3_BUCKET" \
            --versioning-configuration Status=Enabled >/dev/null
        aws_cmd s3api put-bucket-encryption --bucket "$S3_BUCKET" \
            --server-side-encryption-configuration \
            '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}' >/dev/null
        success "S3 bucket created and secured."
    else
        success "Using existing S3 bucket: $S3_BUCKET"
    fi
}

# =======================================================
# 💾 Local Backup + S3 Upload
# =======================================================
perform_backup() {
    mkdir -p "$BACKUP_BASE_DIR"
    local TAR_FILE="${BACKUP_BASE_DIR}/backup_${TIMESTAMP}"

    log "Creating backup from ${BACKUP_SOURCE}..."

    # ✅ Detect file or directory
    if [[ -f "$BACKUP_SOURCE" ]]; then
        SRC_TYPE="file"
    elif [[ -d "$BACKUP_SOURCE" ]]; then
        SRC_TYPE="directory"
    else
        error "Invalid source type: $BACKUP_SOURCE"
        exit 1
    fi

    if [[ "${ENABLE_COMPRESS,,}" == "yes" ]]; then
        TAR_FILE="${TAR_FILE}.tar.gz"
        if [[ "$SRC_TYPE" == "file" ]]; then
            tar -czf "$TAR_FILE" -C "$(dirname "$BACKUP_SOURCE")" "$(basename "$BACKUP_SOURCE")"
        else
            tar -czf "$TAR_FILE" -C "$BACKUP_SOURCE" .
        fi
    else
        TAR_FILE="${TAR_FILE}.tar"
        if [[ "$SRC_TYPE" == "file" ]]; then
            tar -cf "$TAR_FILE" -C "$(dirname "$BACKUP_SOURCE")" "$(basename "$BACKUP_SOURCE")"
        else
            tar -cf "$TAR_FILE" -C "$BACKUP_SOURCE" .
        fi
    fi

    local S3_KEY="$(basename "$TAR_FILE")"
    log "Uploading to s3://${S3_BUCKET}/${S3_KEY} ..."
    aws_cmd s3 cp "$TAR_FILE" "s3://${S3_BUCKET}/${S3_KEY}" --only-show-errors
    success "Backup uploaded successfully to s3://${S3_BUCKET}/${S3_KEY}."
}

# =======================================================
# 📸 Optional Snapshot
# =======================================================
create_snapshots() {
    if [[ "${ENABLE_SNAP,,}" != "yes" ]]; then
        log "Skipping EBS snapshots."
        return 0
    fi

    log "Creating snapshots for instance: ${INSTANCE_ID}"
    local VOL_IDS
    VOL_IDS=$(aws_cmd ec2 describe-instances --instance-ids "$INSTANCE_ID" \
        --query "Reservations[].Instances[].BlockDeviceMappings[].Ebs.VolumeId" --output text)
    for VOL_ID in $VOL_IDS; do
        SNAP_ID=$(aws_cmd ec2 create-snapshot --volume-id "$VOL_ID" \
            --description "AutoBackup-${TIMESTAMP}" \
            --query 'SnapshotId' --output text)
        aws_cmd ec2 create-tags --resources "$SNAP_ID" \
            --tags Key=Name,Value="AutoBackup-${TIMESTAMP}" >/dev/null
        success "Snapshot created: ${SNAP_ID}"
    done
}

# =======================================================
# 🚀 Main
# =======================================================
main() {
    prepare_system
    user_config
    create_s3_bucket
    perform_backup
    create_snapshots
    success "✅ All operations completed successfully!"
    echo -e "${C_GREEN}Logs stored at:${C_RESET} ${LOG_FILE}"
}

main "$@"
