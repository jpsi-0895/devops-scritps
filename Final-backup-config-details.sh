REGION="us-east-1"
AWS_PROFILE="default"
S3_BUCKET="auto-create"   # if bucket is alrady exsist that replace S3 name with auto-create 
INSTANCE_ID="auto-detect"
BACKUP_SOURCE="/home/ubuntu"
ENABLE_SNAPSHOTS="yes"
COMPRESS_BEFORE_UPLOAD="yes"


#  aws configure command for iam roles if not avalable

# command for execute 
# ./ec2_s3_backup.sh /home/ubuntu/backup.conf 
