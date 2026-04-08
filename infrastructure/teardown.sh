#!/bin/bash
set -euo pipefail

REGION="us-east-1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../.env"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'
log() { echo -e "${GREEN}[clawd-bot]${NC} $1"; }

[ -f "$ENV_FILE" ] && source "$ENV_FILE"

echo -e "${RED}This will destroy ALL clawd-bot AWS resources.${NC}"
read -p "Type 'yes' to confirm: " CONFIRM
[ "$CONFIRM" != "yes" ] && echo "Aborted." && exit 0

# Terminate instance
if [ -n "${CLAWD_INSTANCE_ID:-}" ]; then
    log "Terminating instance $CLAWD_INSTANCE_ID..."
    aws ec2 terminate-instances --instance-ids "$CLAWD_INSTANCE_ID" --region "$REGION" 2>/dev/null || true
    aws ec2 wait instance-terminated --instance-ids "$CLAWD_INSTANCE_ID" --region "$REGION" 2>/dev/null || true
fi

# Delete SQS queues
for Q in clawd-bot-tasks clawd-bot-tasks-dlq clawd-bot-tasks-codex clawd-bot-tasks-codex-dlq; do
    URL=$(aws sqs get-queue-url --queue-name "$Q" --region "$REGION" --query 'QueueUrl' --output text 2>/dev/null) || continue
    log "Deleting queue: $Q"
    aws sqs delete-queue --queue-url "$URL" --region "$REGION" 2>/dev/null || true
done

# Delete security group
SG_ID=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=clawd-bot-sg" \
    --region "$REGION" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null) || true
if [ -n "$SG_ID" ] && [ "$SG_ID" != "None" ]; then
    log "Deleting security group $SG_ID"
    sleep 5
    aws ec2 delete-security-group --group-id "$SG_ID" --region "$REGION" 2>/dev/null || true
fi

# Delete key pair
log "Deleting key pair"
aws ec2 delete-key-pair --key-name clawd-bot --region "$REGION" 2>/dev/null || true
rm -f "$SCRIPT_DIR/../clawd-bot.pem"

# Delete IAM resources
log "Cleaning up IAM"
aws iam remove-role-from-instance-profile \
    --instance-profile-name clawd-bot-profile --role-name clawd-bot-role 2>/dev/null || true
aws iam delete-instance-profile --instance-profile-name clawd-bot-profile 2>/dev/null || true
aws iam delete-role-policy --role-name clawd-bot-role --policy-name clawd-bot-policy 2>/dev/null || true
aws iam delete-role --role-name clawd-bot-role 2>/dev/null || true

# Delete SSM parameters
log "Deleting SSM parameters"
aws ssm delete-parameter --name "/clawd-bot/github-ssh-key" --region "$REGION" 2>/dev/null || true
aws ssm delete-parameter --name "/clawd-bot/openai-api-key" --region "$REGION" 2>/dev/null || true

# Delete DynamoDB table
log "Deleting DynamoDB table"
aws dynamodb delete-table --table-name clawd-bot-tasks --region "$REGION" 2>/dev/null || true

# Delete Lambda functions and IAM role
log "Cleaning up Lambda"
for FUNC in submit tasks projects; do
    aws lambda delete-function --function-name "clawd-bot-${FUNC}" --region "$REGION" 2>/dev/null || true
done
aws iam delete-role-policy --role-name lambda-clawd-bot-role --policy-name lambda-clawd-bot-policy 2>/dev/null || true
aws iam delete-role --role-name lambda-clawd-bot-role 2>/dev/null || true

# Delete API Gateway
if [ -n "${CLAWD_API_ID:-}" ]; then
    log "Deleting API Gateway $CLAWD_API_ID"
    aws apigatewayv2 delete-api --api-id "$CLAWD_API_ID" --region "$REGION" 2>/dev/null || true
fi

# Delete CloudFront distribution (must be disabled first)
if [ -n "${CLAWD_CF_ID:-}" ]; then
    log "Disabling CloudFront distribution $CLAWD_CF_ID (manual deletion may be needed)"
    echo "CloudFront distributions must be disabled before deletion — check the AWS console"
fi

# Delete S3 bucket
if [ -n "${CLAWD_S3_BUCKET:-}" ]; then
    log "Deleting S3 bucket $CLAWD_S3_BUCKET"
    aws s3 rb "s3://$CLAWD_S3_BUCKET" --force --region "$REGION" 2>/dev/null || true
fi

rm -f "$ENV_FILE"
log "All clawd-bot resources destroyed."
