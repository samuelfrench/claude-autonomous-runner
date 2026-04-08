#!/bin/bash
set -euo pipefail

REGION="us-east-1"
ACCOUNT_ID="${AWS_ACCOUNT_ID:?Set AWS_ACCOUNT_ID}"
LAMBDA_ROLE_NAME="lambda-clawd-bot-role"
API_NAME="clawd-bot-api"
S3_BUCKET="clawd-bot-web-${ACCOUNT_ID}"
DYNAMO_TABLE="clawd-bot-tasks"
CLAUDE_QUEUE_URL="https://sqs.us-east-1.amazonaws.com/${ACCOUNT_ID}/clawd-bot-tasks"
CODEX_QUEUE_URL="https://sqs.us-east-1.amazonaws.com/${ACCOUNT_ID}/clawd-bot-tasks-codex"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WEB_DIR="$SCRIPT_DIR/../web"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
log() { echo -e "${GREEN}[clawd-web]${NC} $1"; }
warn() { echo -e "${YELLOW}[clawd-web]${NC} $1"; }

# Generate API key for auth
API_KEY=$(openssl rand -hex 24)
log "Generated API key: $API_KEY"

# --- Step 1: Lambda IAM Role ---
log "Creating Lambda IAM role: $LAMBDA_ROLE_NAME"
LAMBDA_TRUST='{
    "Version": "2012-10-17",
    "Statement": [{
        "Effect": "Allow",
        "Principal": {"Service": "lambda.amazonaws.com"},
        "Action": "sts:AssumeRole"
    }]
}'
aws iam create-role \
    --role-name "$LAMBDA_ROLE_NAME" \
    --assume-role-policy-document "$LAMBDA_TRUST" 2>/dev/null || warn "Role already exists"

LAMBDA_POLICY=$(cat <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "dynamodb:PutItem",
                "dynamodb:UpdateItem",
                "dynamodb:GetItem",
                "dynamodb:Query",
                "dynamodb:Scan"
            ],
            "Resource": "arn:aws:dynamodb:${REGION}:${ACCOUNT_ID}:table/${DYNAMO_TABLE}*"
        },
        {
            "Effect": "Allow",
            "Action": ["sqs:SendMessage"],
            "Resource": "arn:aws:sqs:${REGION}:${ACCOUNT_ID}:clawd-bot-*"
        },
        {
            "Effect": "Allow",
            "Action": [
                "logs:CreateLogGroup",
                "logs:CreateLogStream",
                "logs:PutLogEvents"
            ],
            "Resource": "arn:aws:logs:${REGION}:${ACCOUNT_ID}:*"
        }
    ]
}
EOF
)
aws iam put-role-policy \
    --role-name "$LAMBDA_ROLE_NAME" \
    --policy-name "lambda-clawd-bot-policy" \
    --policy-document "$LAMBDA_POLICY"

LAMBDA_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${LAMBDA_ROLE_NAME}"
log "Lambda role ready"

# Wait for IAM propagation
log "Waiting 10s for IAM propagation..."
sleep 10

# --- Step 2: Package and Create Lambda Functions ---
PROJECTS_LIST=$(jq -c 'keys' "$SCRIPT_DIR/../config/projects.json")

LAMBDA_ENV="{\"Variables\":{\"DYNAMO_TABLE\":\"$DYNAMO_TABLE\",\"CLAUDE_QUEUE_URL\":\"$CLAUDE_QUEUE_URL\",\"CODEX_QUEUE_URL\":\"$CODEX_QUEUE_URL\",\"API_KEY\":\"$API_KEY\",\"PROJECTS\":$(echo "$PROJECTS_LIST" | jq -Rs .)}}"

TMPDIR=$(mktemp -d)

for FUNC in submit tasks projects; do
    log "Deploying Lambda: clawd-bot-${FUNC}"
    cp "$WEB_DIR/api/${FUNC}.py" "$TMPDIR/lambda_function.py"
    (cd "$TMPDIR" && zip -q "function.zip" "lambda_function.py")

    # Create or update
    if aws lambda get-function --function-name "clawd-bot-${FUNC}" --region "$REGION" &>/dev/null; then
        aws lambda update-function-code \
            --function-name "clawd-bot-${FUNC}" \
            --zip-file "fileb://$TMPDIR/function.zip" \
            --region "$REGION" > /dev/null
        sleep 2
        aws lambda update-function-configuration \
            --function-name "clawd-bot-${FUNC}" \
            --environment "$LAMBDA_ENV" \
            --region "$REGION" > /dev/null
    else
        aws lambda create-function \
            --function-name "clawd-bot-${FUNC}" \
            --runtime python3.12 \
            --handler "lambda_function.handler" \
            --role "arn:aws:iam::${ACCOUNT_ID}:role/${LAMBDA_ROLE_NAME}" \
            --zip-file "fileb://$TMPDIR/function.zip" \
            --environment "$LAMBDA_ENV" \
            --timeout 30 \
            --memory-size 128 \
            --region "$REGION" > /dev/null
    fi
    rm -f "$TMPDIR/lambda_function.py" "$TMPDIR/function.zip"
done
rm -rf "$TMPDIR"
log "Lambda functions deployed"

# --- Step 3: API Gateway HTTP API ---
log "Creating API Gateway: $API_NAME"

EXISTING_API=$(aws apigatewayv2 get-apis --region "$REGION" \
    --query "Items[?Name=='$API_NAME'].ApiId" --output text 2>/dev/null || echo "")

if [ -n "$EXISTING_API" ] && [ "$EXISTING_API" != "None" ]; then
    API_ID="$EXISTING_API"
    warn "API already exists: $API_ID"
else
    API_ID=$(aws apigatewayv2 create-api \
        --name "$API_NAME" \
        --protocol-type HTTP \
        --cors-configuration '{
            "AllowOrigins": ["*"],
            "AllowMethods": ["GET","POST","OPTIONS"],
            "AllowHeaders": ["Content-Type","x-api-key"],
            "MaxAge": 86400
        }' \
        --region "$REGION" \
        --query 'ApiId' --output text)
fi
log "API Gateway: $API_ID"

# Create integrations and routes
for FUNC in submit tasks projects; do
    FUNC_ARN="arn:aws:lambda:${REGION}:${ACCOUNT_ID}:function:clawd-bot-${FUNC}"

    INTEGRATION_ID=$(aws apigatewayv2 create-integration \
        --api-id "$API_ID" \
        --integration-type AWS_PROXY \
        --integration-uri "$FUNC_ARN" \
        --payload-format-version "2.0" \
        --region "$REGION" \
        --query 'IntegrationId' --output text)

    case "$FUNC" in
        submit)
            aws apigatewayv2 create-route --api-id "$API_ID" \
                --route-key "POST /tasks" \
                --target "integrations/$INTEGRATION_ID" \
                --region "$REGION" > /dev/null
            ;;
        tasks)
            aws apigatewayv2 create-route --api-id "$API_ID" \
                --route-key "GET /tasks" \
                --target "integrations/$INTEGRATION_ID" \
                --region "$REGION" > /dev/null
            aws apigatewayv2 create-route --api-id "$API_ID" \
                --route-key 'GET /tasks/{task_id}' \
                --target "integrations/$INTEGRATION_ID" \
                --region "$REGION" > /dev/null
            ;;
        projects)
            aws apigatewayv2 create-route --api-id "$API_ID" \
                --route-key "GET /projects" \
                --target "integrations/$INTEGRATION_ID" \
                --region "$REGION" > /dev/null
            ;;
    esac

    # Grant API Gateway permission to invoke Lambda
    aws lambda add-permission \
        --function-name "clawd-bot-${FUNC}" \
        --statement-id "apigateway-${FUNC}-${API_ID}" \
        --action "lambda:InvokeFunction" \
        --principal "apigateway.amazonaws.com" \
        --source-arn "arn:aws:execute-api:${REGION}:${ACCOUNT_ID}:${API_ID}/*" \
        --region "$REGION" 2>/dev/null || true
done

# Create default stage with auto-deploy
aws apigatewayv2 create-stage \
    --api-id "$API_ID" \
    --stage-name '$default' \
    --auto-deploy \
    --region "$REGION" 2>/dev/null || true

API_URL="https://${API_ID}.execute-api.${REGION}.amazonaws.com"
log "API Gateway URL: $API_URL"

# --- Step 4: S3 Bucket for Static Site ---
log "Creating S3 bucket: $S3_BUCKET"
aws s3api create-bucket \
    --bucket "$S3_BUCKET" \
    --region "$REGION" 2>/dev/null || warn "Bucket already exists"

aws s3api put-public-access-block \
    --bucket "$S3_BUCKET" \
    --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" \
    --region "$REGION"

if [ -f "$WEB_DIR/index.html" ]; then
    sed "s|__API_URL__|${API_URL}|g" "$WEB_DIR/index.html" | \
    aws s3 cp - "s3://${S3_BUCKET}/index.html" \
        --content-type "text/html" \
        --region "$REGION"
    log "Uploaded index.html to S3"
else
    warn "web/index.html not found — upload it later"
fi

# --- Step 5: CloudFront Distribution ---
log "Creating CloudFront distribution..."

OAC_ID=$(aws cloudfront create-origin-access-control \
    --origin-access-control-config "{
        \"Name\": \"clawd-bot-oac\",
        \"OriginAccessControlOriginType\": \"s3\",
        \"SigningBehavior\": \"always\",
        \"SigningProtocol\": \"sigv4\"
    }" \
    --query 'OriginAccessControl.Id' --output text 2>/dev/null || \
    aws cloudfront list-origin-access-controls \
        --query "OriginAccessControlList.Items[?Name=='clawd-bot-oac'].Id" --output text)

CF_CONFIG=$(cat <<CFEOF
{
    "CallerReference": "clawd-bot-$(date +%s)",
    "DefaultRootObject": "index.html",
    "Origins": {
        "Quantity": 1,
        "Items": [{
            "Id": "s3-${S3_BUCKET}",
            "DomainName": "${S3_BUCKET}.s3.${REGION}.amazonaws.com",
            "OriginAccessControlId": "${OAC_ID}",
            "S3OriginConfig": {
                "OriginAccessIdentity": ""
            }
        }]
    },
    "DefaultCacheBehavior": {
        "TargetOriginId": "s3-${S3_BUCKET}",
        "ViewerProtocolPolicy": "redirect-to-https",
        "AllowedMethods": {
            "Quantity": 2,
            "Items": ["GET", "HEAD"]
        },
        "CachePolicyId": "658327ea-f89d-4fab-a63d-7e88639e58f6",
        "Compress": true
    },
    "Enabled": true,
    "Comment": "Clawd-bot web dashboard"
}
CFEOF
)

EXISTING_CF=$(aws cloudfront list-distributions \
    --query "DistributionList.Items[?Comment=='Clawd-bot web dashboard'].Id" \
    --output text 2>/dev/null || echo "")

if [ -n "$EXISTING_CF" ] && [ "$EXISTING_CF" != "None" ]; then
    CF_ID="$EXISTING_CF"
    CF_DOMAIN=$(aws cloudfront get-distribution --id "$CF_ID" \
        --query 'Distribution.DomainName' --output text)
    warn "CloudFront distribution already exists: $CF_ID ($CF_DOMAIN)"
else
    CF_RESULT=$(aws cloudfront create-distribution \
        --distribution-config "$CF_CONFIG" \
        --output json)
    CF_ID=$(echo "$CF_RESULT" | jq -r '.Distribution.Id')
    CF_DOMAIN=$(echo "$CF_RESULT" | jq -r '.Distribution.DomainName')

    BUCKET_POLICY=$(cat <<BPEOF
{
    "Version": "2012-10-17",
    "Statement": [{
        "Effect": "Allow",
        "Principal": {"Service": "cloudfront.amazonaws.com"},
        "Action": "s3:GetObject",
        "Resource": "arn:aws:s3:::${S3_BUCKET}/*",
        "Condition": {
            "StringEquals": {
                "AWS:SourceArn": "arn:aws:cloudfront::${ACCOUNT_ID}:distribution/${CF_ID}"
            }
        }
    }]
}
BPEOF
    )
    aws s3api put-bucket-policy --bucket "$S3_BUCKET" --policy "$BUCKET_POLICY"
fi

log "CloudFront: $CF_DOMAIN"

# --- Save web config ---
cat >> "$SCRIPT_DIR/../.env" <<EOF

# Web dashboard
CLAWD_API_URL=$API_URL
CLAWD_API_KEY=$API_KEY
CLAWD_API_ID=$API_ID
CLAWD_S3_BUCKET=$S3_BUCKET
CLAWD_CF_ID=$CF_ID
CLAWD_CF_DOMAIN=$CF_DOMAIN
CLAWD_LAMBDA_ROLE=$LAMBDA_ROLE_NAME
EOF

log "================================================"
log "Web dashboard deployed!"
log ""
log "  Dashboard:  https://${CF_DOMAIN}"
log "  API:        ${API_URL}"
log "  API Key:    ${API_KEY}"
log ""
log "CloudFront may take 5-10 min to propagate."
log "API Key is required in x-api-key header."
log "================================================"
