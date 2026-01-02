#!/bin/bash
# Script to enable EventBridge notifications on an existing S3 bucket
# Usage: ./enable-eventbridge.sh <bucket-name>

BUCKET_NAME=$1

if [ -z "$BUCKET_NAME" ]; then
    echo "Error: Bucket name is required"
    echo "Usage: ./enable-eventbridge.sh <bucket-name>"
    exit 1
fi

echo "Enabling EventBridge notifications on bucket: $BUCKET_NAME"

aws s3api put-bucket-notification-configuration \
    --bucket "$BUCKET_NAME" \
    --notification-configuration '{
        "EventBridgeConfiguration": {}
    }'

if [ $? -eq 0 ]; then
    echo "✅ EventBridge notifications enabled successfully on bucket: $BUCKET_NAME"
    echo ""
    echo "You can now deploy the CloudFormation stack with:"
    echo "  ExistingDataSourceBucket=$BUCKET_NAME"
else
    echo "❌ Failed to enable EventBridge notifications"
    exit 1
fi
