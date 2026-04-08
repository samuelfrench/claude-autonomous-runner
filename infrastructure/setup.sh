#!/bin/bash
set -euo pipefail

REGION="us-east-1"
ACCOUNT_ID="${AWS_ACCOUNT_ID:?Set AWS_ACCOUNT_ID}"
QUEUE_NAME="clawd-bot-tasks"
DLQ_NAME="clawd-bot-tasks-dlq"
CODEX_QUEUE_NAME="clawd-bot-tasks-codex"
CODEX_DLQ_NAME="clawd-bot-tasks-codex-dlq"
DYNAMO_TABLE="clawd-bot-tasks"
SG_NAME="clawd-bot-sg"
ROLE_NAME="clawd-bot-role"
PROFILE_NAME="clawd-bot-profile"
KEY_NAME="clawd-bot"
INSTANCE_TYPE="t3a.medium"
VPC_ID="${AWS_VPC_ID:?Set AWS_VPC_ID}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
log() { echo -e "${GREEN}[clawd-bot]${NC} $1"; }
warn() { echo -e "${YELLOW}[clawd-bot]${NC} $1"; }

# --- Step 1: SQS Dead Letter Queue ---
log "Creating DLQ: $DLQ_NAME"
DLQ_URL=$(aws sqs create-queue \
    --queue-name "$DLQ_NAME" \
    --attributes '{"MessageRetentionPeriod":"1209600"}' \
    --region "$REGION" \
    --query 'QueueUrl' --output text)
DLQ_ARN=$(aws sqs get-queue-attributes \
    --queue-url "$DLQ_URL" \
    --attribute-names QueueArn \
    --region "$REGION" \
    --query 'Attributes.QueueArn' --output text)
log "DLQ: $DLQ_URL"

# --- Step 2: Main SQS Queue ---
log "Creating queue: $QUEUE_NAME"
REDRIVE="{\\\"deadLetterTargetArn\\\":\\\"${DLQ_ARN}\\\",\\\"maxReceiveCount\\\":\\\"3\\\"}"
QUEUE_URL=$(aws sqs create-queue \
    --queue-name "$QUEUE_NAME" \
    --attributes "{\"VisibilityTimeout\":\"7200\",\"MessageRetentionPeriod\":\"1209600\",\"RedrivePolicy\":\"${REDRIVE}\"}" \
    --region "$REGION" \
    --query 'QueueUrl' --output text)
log "Queue: $QUEUE_URL"

# --- Step 2b: Codex SQS Queues ---
log "Creating Codex DLQ: $CODEX_DLQ_NAME"
CODEX_DLQ_URL=$(aws sqs create-queue \
    --queue-name "$CODEX_DLQ_NAME" \
    --attributes '{"MessageRetentionPeriod":"1209600"}' \
    --region "$REGION" \
    --query 'QueueUrl' --output text)
CODEX_DLQ_ARN=$(aws sqs get-queue-attributes \
    --queue-url "$CODEX_DLQ_URL" \
    --attribute-names QueueArn \
    --region "$REGION" \
    --query 'Attributes.QueueArn' --output text)
log "Codex DLQ: $CODEX_DLQ_URL"

log "Creating Codex queue: $CODEX_QUEUE_NAME"
CODEX_REDRIVE="{\\\"deadLetterTargetArn\\\":\\\"${CODEX_DLQ_ARN}\\\",\\\"maxReceiveCount\\\":\\\"3\\\"}"
CODEX_QUEUE_URL=$(aws sqs create-queue \
    --queue-name "$CODEX_QUEUE_NAME" \
    --attributes "{\"VisibilityTimeout\":\"7200\",\"MessageRetentionPeriod\":\"1209600\",\"RedrivePolicy\":\"${CODEX_REDRIVE}\"}" \
    --region "$REGION" \
    --query 'QueueUrl' --output text)
log "Codex Queue: $CODEX_QUEUE_URL"

# --- Step 2c: DynamoDB Table ---
log "Creating DynamoDB table: $DYNAMO_TABLE"
aws dynamodb create-table \
    --table-name "$DYNAMO_TABLE" \
    --attribute-definitions '[{"AttributeName":"task_id","AttributeType":"S"},{"AttributeName":"provider","AttributeType":"S"},{"AttributeName":"submitted_at","AttributeType":"S"}]' \
    --key-schema '[{"AttributeName":"task_id","KeyType":"HASH"}]' \
    --global-secondary-indexes '[{"IndexName":"provider-submitted-index","KeySchema":[{"AttributeName":"provider","KeyType":"HASH"},{"AttributeName":"submitted_at","KeyType":"RANGE"}],"Projection":{"ProjectionType":"ALL"}}]' \
    --billing-mode PAY_PER_REQUEST \
    --region "$REGION" 2>/dev/null || warn "DynamoDB table already exists"
log "DynamoDB table ready"

# --- Step 3: Security Group ---
log "Creating security group: $SG_NAME"
MY_IP=$(curl -s https://checkip.amazonaws.com)
SG_ID=$(aws ec2 create-security-group \
    --group-name "$SG_NAME" \
    --description "Clawd-bot SSH access" \
    --vpc-id "$VPC_ID" \
    --region "$REGION" \
    --query 'GroupId' --output text 2>/dev/null || \
    aws ec2 describe-security-groups \
        --filters "Name=group-name,Values=$SG_NAME" \
        --region "$REGION" \
        --query 'SecurityGroups[0].GroupId' --output text)
aws ec2 authorize-security-group-ingress \
    --group-id "$SG_ID" --protocol tcp --port 22 \
    --cidr "${MY_IP}/32" --region "$REGION" 2>/dev/null || true
log "Security group: $SG_ID (SSH from $MY_IP)"

# --- Step 4: EC2 Key Pair ---
KEY_FILE="$SCRIPT_DIR/../clawd-bot.pem"
if ! aws ec2 describe-key-pairs --key-names "$KEY_NAME" --region "$REGION" &>/dev/null; then
    log "Creating key pair: $KEY_NAME"
    aws ec2 create-key-pair \
        --key-name "$KEY_NAME" \
        --key-type ed25519 \
        --query 'KeyMaterial' --output text \
        --region "$REGION" > "$KEY_FILE"
    chmod 600 "$KEY_FILE"
    log "Private key saved: $KEY_FILE"
else
    warn "Key pair '$KEY_NAME' already exists"
    if [ ! -f "$KEY_FILE" ]; then
        warn "Private key file not found at $KEY_FILE — you'll need it to SSH in"
    fi
fi

# --- Step 5: IAM Role + Instance Profile ---
log "Creating IAM role: $ROLE_NAME"
TRUST_POLICY='{
    "Version": "2012-10-17",
    "Statement": [{
        "Effect": "Allow",
        "Principal": {"Service": "ec2.amazonaws.com"},
        "Action": "sts:AssumeRole"
    }]
}'
aws iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document "$TRUST_POLICY" 2>/dev/null || true

POLICY=$(cat <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "sqs:ReceiveMessage",
                "sqs:DeleteMessage",
                "sqs:SendMessage",
                "sqs:ChangeMessageVisibility",
                "sqs:GetQueueAttributes",
                "sqs:GetQueueUrl"
            ],
            "Resource": "arn:aws:sqs:${REGION}:${ACCOUNT_ID}:clawd-bot-*"
        },
        {
            "Effect": "Allow",
            "Action": ["ses:SendEmail", "ses:SendRawEmail"],
            "Resource": "*"
        },
        {
            "Effect": "Allow",
            "Action": ["ssm:GetParameter"],
            "Resource": "arn:aws:ssm:${REGION}:${ACCOUNT_ID}:parameter/clawd-bot/*"
        },
        {
            "Effect": "Allow",
            "Action": [
                "dynamodb:PutItem",
                "dynamodb:UpdateItem",
                "dynamodb:GetItem",
                "dynamodb:Query"
            ],
            "Resource": "arn:aws:dynamodb:${REGION}:${ACCOUNT_ID}:table/clawd-bot-tasks*"
        }
    ]
}
EOF
)
aws iam put-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-name "clawd-bot-policy" \
    --policy-document "$POLICY"

aws iam create-instance-profile \
    --instance-profile-name "$PROFILE_NAME" 2>/dev/null || true
aws iam add-role-to-instance-profile \
    --instance-profile-name "$PROFILE_NAME" \
    --role-name "$ROLE_NAME" 2>/dev/null || true
log "IAM role + instance profile ready"

# --- Step 6: Store GitHub SSH Key in SSM ---
log "Storing GitHub SSH key in SSM"
SSH_KEY_PATH="${HOME}/.ssh/id_ed25519"
if [ ! -f "$SSH_KEY_PATH" ]; then
    echo "ERROR: GitHub SSH key not found at $SSH_KEY_PATH"
    exit 1
fi
aws ssm put-parameter \
    --name "/clawd-bot/github-ssh-key" \
    --type SecureString \
    --value "file://${SSH_KEY_PATH}" \
    --overwrite \
    --region "$REGION"
log "SSH key stored in SSM"

# --- Step 7: Get AMI ---
AMI_ID=$(aws ssm get-parameter \
    --name "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64" \
    --query 'Parameter.Value' --output text \
    --region "$REGION")
log "AMI: $AMI_ID"

# --- Step 8: Wait for IAM propagation ---
log "Waiting 15s for IAM propagation..."
sleep 15

# --- Step 9: Launch Instance ---
log "Launching instance ($INSTANCE_TYPE)..."
USER_DATA=$(base64 -w0 "$SCRIPT_DIR/user-data.sh")

INSTANCE_ID=$(aws ec2 run-instances \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --security-group-ids "$SG_ID" \
    --iam-instance-profile "Name=$PROFILE_NAME" \
    --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":16,"VolumeType":"gp3"}}]' \
    --user-data "$USER_DATA" \
    --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=clawd-bot}]' \
    --region "$REGION" \
    --query 'Instances[0].InstanceId' --output text)
log "Instance: $INSTANCE_ID"

# --- Step 10: Wait for Public IP ---
log "Waiting for instance to start..."
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$REGION"
PUBLIC_IP=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text --region "$REGION")

# --- Save config ---
cat > "$SCRIPT_DIR/../.env" <<EOF
CLAWD_QUEUE_URL=$QUEUE_URL
CLAWD_DLQ_URL=$DLQ_URL
CLAWD_CODEX_QUEUE_URL=$CODEX_QUEUE_URL
CLAWD_CODEX_DLQ_URL=$CODEX_DLQ_URL
CLAWD_DYNAMO_TABLE=$DYNAMO_TABLE
CLAWD_INSTANCE_ID=$INSTANCE_ID
CLAWD_PUBLIC_IP=$PUBLIC_IP
CLAWD_REGION=$REGION
EOF

log "================================================"
log "Clawd-bot is running!"
log ""
log "  Instance:  $INSTANCE_ID"
log "  Public IP: $PUBLIC_IP"
log "  Queue:     $QUEUE_URL"
log ""
log "Next steps (wait ~3 min for bootstrap):"
log "  1. ssh -i clawd-bot.pem ec2-user@$PUBLIC_IP"
log "  2. claude auth login"
log "  3. sudo systemctl start clawd-runner"
log "  4. ./client/clawd my-project 'Read TODO.md'"
log "================================================"
