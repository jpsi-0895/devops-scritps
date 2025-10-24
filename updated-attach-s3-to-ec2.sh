#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# ----------------------
# CONFIGURATION DEFAULTS
# ----------------------
REGION="us-east-1"
AWS_PROFILE=""
INSTANCE_TYPE="t3.micro"
INSTANCE_NAME="ec2-backup-instance"
CREATE_SNAPSHOTS="yes"
SNAPSHOT_TAG="AutoBackup"
BACKUP_DIR="/backup"

# ----------------------
# ASK USER INPUT
# ----------------------
read -rp "Enter existing S3 bucket name (press Enter to create a new one): " BUCKET_NAME
read -rp "Enter existing EC2 instance ID (press Enter to create a new one): " USER_INSTANCE_ID

TIMESTAMP=$(date +%s)
if [ -z "${BUCKET_NAME}" ]; then
  BUCKET_NAME="ec2-backups-${TIMESTAMP}"
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

# ----------------------
# HELPER FUNCTIONS
# ----------------------
AWS_CLI=(aws --region "${REGION}")
if [ -n "${AWS_PROFILE}" ]; then
  AWS_CLI+=(--profile "${AWS_PROFILE}")
fi
aws_run() { "${AWS_CLI[@]}" "$@"; }

# Requirements check
for cmd in aws jq; do
  ifexit 1mand -v "$cmd" >/dev/null 2>&1; then
  fiecho "ERROR: Missing $cmd. Please install it and rerun."
done

echo "AWS Region: ${REGION}"
echo "Bucket: ${BUCKET_NAME}"
echo "Instance ID: ${USER_INSTANCE_ID:-'(new will be created)'}"
echo

# ----------------------
# 0) Get latest Amazon Linux 2 AMI
# ----------------------
if [ "${CREATE_NEW_INSTANCE}" = "yes" ]; then
  echo "Fetching latest Amazon Linux 2 AMI..."
  AMI_ID=$(aws_run ec2 describe-images \
    --owners 137112412989 \
    --filters "Name=name,Values=amzn2-ami-hvm-*-x86_64-gp2" "Name=state,Values=available" \
if [ "${CREATE_NEW_INSTANCE}" = "yes" ]; then
  echo "Fetching latest Amazon Linux 2 AMI..."
  AM--query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
    --output text)2412989 \
  echo "Using AMI: ${AMI_ID}"es=amzn2-ami-hvm-*-x86_64-gp2" "Name=state,Values=available" \
  echo
fi

# ----------------------
# 1) Create S3 Bucket (if needed)
# ----------------------
if [ "${CREATE_NEW_BUCKET}" = "yes" ]; then
  echo "Creating S3 bucket: ${BUCKET_NAME} ..."
  if [ "${REGION}" = "us-east-1" ]; then
    aws_run s3api create-bucket --bucket "${BUCKET_NAME}"
  else
    aws_run s3api create-bucket --bucket "${BUCKET_NAME}" \
      --create-bucket-configuration LocationConstraint="${REGION}"
  fi
    --versioning-configuration Status=Enabled
  aws_run s3api put-bucket-encryption \
    --bucket "${BUCKET_NAME}" \
    --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
  echo "✅ Bucket created with versioning & encryption."
  echo
else
  echo "Using existing S3 bucket: ${BUCKET_NAME}"
  echo
fi

# ----------------------
# 2) IAM Role & Policy
# ----------------------
echo "Creating IAM role for EC2 -> S3 backup..."
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
aws_run iam create-role --role-name "${IAM_ROLE_NAME}" \
  --assume-role-policy-document "file://${TRUST_FILE}" >/dev/null
ROLE_ARN=$(aws_run iam get-role --role-name "${IAM_ROLE_NAME}" --query 'Role.Arn' --output text)
rm -f "${TRUST_FILE}"

POLICY_FILE=$(mktemp)
cat > "${POLICY_FILE}" <<EOF
{ "Statement": [
  "V{rsion": "2012-10-17",
      "Effect":"Allow",
      "Action":[ "s3:*" ],
      "Resource":[
        "arn:aws:s3:::${BUCKET_NAME}",
        "arn:aws:s3:::${BUCKET_NAME}/*"
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
echo "✅ IAM role and instance profile ready."
echo

sleep 10  # allow propagation

# ----------------------
# 3) If instance not given, create new EC2
# ----------------------
if [ "${CREATE_NEW_INSTANCE}" = "yes" ]; then
  echo "Creating security group..."
  VPC_ID=$(aws_run ec2 describe-vpcs --query 'Vpcs[0].VpcId' --output text)
  SG_ID=$(aws_run ec2 create-security-group \
    --group-name "${SEC_GROUP_NAME}" \
    --description "Backup SG" \
    --vpc-id "${VPC_ID}" \
    --query 'GroupId' --output text)
  aws_run ec2 authorize-security-group-ingress --group-id "${SG_ID}" \
    --protocol tcp --port 22 --cidr 0.0.0.0/0 || true

  echo "Creating key pair..."
  aws_run ec2 create-key-pair \
    --key-name "${KEY_NAME}" \
    --query 'KeyMaterial' --output text > "${KEY_NAME}.pem"
  echo "Launching EC2 instance..."
#!/bin/bash_FILE=$(mktemp)
set -e> "${USER_DATA_FILE}" <<EOF
yum install -y awscli jq tar gzip
mkdir -p ${BACKUP_DIR}
tar --exclude=/proc --exclude=/sys --exclude=/dev --exclude=/tmp --exclude=/run -czpf ${BACKUP_DIR}/system-backup.tar.gz /
aws s3 cp ${BACKUP_DIR}/system-backup.tar.gz s3://${BUCKET_NAME}/
EOF
 INSTANCE_JSON=$(aws_run ec2 run-instances \
    --image-id "${AMI_ID}" \
    --instance-type "${INSTANCE_TYPE}" \
    --key-name "${KEY_NAME}" \
    --security-group-ids "${SG_ID}" \
    --iam-instance-profile Name="${INSTANCE_PROFILE_NAME}" \
    --user-data file://"${USER_DATA_FILE}" \
  echo "Using existing EC2 instance ID: ${USER_INSTANCE_ID}"ame,Value=${INSTANCE_NAME}}]" \
  echoquery 'Instances[0]' --output json)
fi
echo "EC2 Instance: ${USER_INSTANCE_ID}"ON}" | jq -r '.InstanceId')
echo "IAM Role    : ${IAM_ROLE_NAME}" | jq -r '.PublicIpAddress // "N/A"')
echommary EC2 created: ${USER_INSTANCE_ID} (Public IP: ${PUBLIC_IP})"
if [ "${CREATE_NEW_INSTANCE}" = "yes" ]; then
ececho "To SSH in: ssh -i ${KEY_NAME}.pem ec2-user@${PUBLIC_IP}"
fiho "S3 Bucket   : ${BUCKET_NAME}"
