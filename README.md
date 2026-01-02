# AWS Bedrock Knowledge Base with S3 Vector Storage

CloudFormation template for deploying an Amazon Bedrock Knowledge Base with S3 data source and S3 Vector storage, featuring automatic synchronization when documents change.

## What This Template Does

This CloudFormation template (`template.yaml`) creates a complete serverless knowledge base infrastructure:

### Core Components

1. **Bedrock Knowledge Base**: Vector-based knowledge base using your choice of embedding models (Amazon Titan or Cohere)
2. **S3 Data Source**: Source bucket for your documents (can use existing bucket or create new)
3. **S3 Vector Storage**: S3 Vectors bucket with index for storing document embeddings
4. **IAM Roles & Permissions**: Properly scoped permissions for Bedrock to access S3 and embedding models

### Chunking Strategies

Choose from four document chunking strategies:

- **Fixed-Size**: Splits documents into chunks of fixed token size with configurable overlap
- **Hierarchical**: Creates parent and child chunks for better context preservation
- **Semantic**: Uses AI to identify natural semantic boundaries for chunking
- **None**: No chunking (use entire documents)

### Auto-Sync Feature

When enabled (default), automatically keeps your knowledge base in sync with S3:

- **EventBridge Integration**: Captures S3 object creation and deletion events
- **SQS Buffering**: Batches multiple file changes with configurable delay (0-300 seconds)
- **Lambda Processor**: Triggers Bedrock ingestion jobs intelligently
- **Dead Letter Queue**: Captures failed events for troubleshooting

## Deployment

### Prerequisites

- AWS CLI configured with appropriate credentials
- Permissions to create CloudFormation stacks, S3 buckets, Lambda functions, IAM roles, and Bedrock resources
- Access to Bedrock embedding models in your region

### Option 1: Deploy with New S3 Bucket (Recommended for Testing)

Deploy the stack and let CloudFormation create a new S3 bucket:

```bash
aws cloudformation deploy \
  --template-file template.yaml \
  --stack-name my-knowledge-base \
  --parameter-overrides \
    KnowledgeBaseName=MyKnowledgeBase \
    ChunkingStrategy=SEMANTIC \
    EnableAutoSync=true \
    AutoSyncDelaySeconds=60 \
  --capabilities CAPABILITY_NAMED_IAM
```

After deployment, upload documents to the created bucket:

```bash
# Get the bucket name from stack outputs
BUCKET_NAME=$(aws cloudformation describe-stacks \
  --stack-name my-knowledge-base \
  --query 'Stacks[0].Outputs[?OutputKey==`DataSourceBucketName`].OutputValue' \
  --output text)

# Upload your documents
aws s3 cp my-document.pdf s3://${BUCKET_NAME}/
```

### Option 2: Deploy with Existing S3 Bucket

If you have an existing bucket with documents:

#### Step 1: Enable EventBridge on Your Existing Bucket

For auto-sync to work with an existing bucket, you must enable EventBridge notifications:

```bash
./enable-eventbridge.sh your-existing-bucket-name
```

Or manually via AWS CLI:

```bash
aws s3api put-bucket-notification-configuration \
  --bucket your-existing-bucket-name \
  --notification-configuration '{
    "EventBridgeConfiguration": {}
  }'
```

#### Step 2: Deploy the Stack

```bash
aws cloudformation deploy \
  --template-file template.yaml \
  --stack-name my-knowledge-base \
  --parameter-overrides \
    KnowledgeBaseName=MyKnowledgeBase \
    ExistingDataSourceBucket=your-existing-bucket-name \
    ChunkingStrategy=SEMANTIC \
    EnableAutoSync=true \
  --capabilities CAPABILITY_NAMED_IAM
```

### Option 3: Deploy via AWS Console

1. Open the [CloudFormation Console](https://console.aws.amazon.com/cloudformation)
2. Click **Create stack** > **With new resources**
3. Upload `template.yaml`
4. Fill in parameters:
   - **KnowledgeBaseName**: Name for your knowledge base
   - **ExistingDataSourceBucket**: (Optional) Leave empty to create new bucket
   - **EmbeddingModelId**: Choose embedding model
   - **ChunkingStrategy**: Choose chunking approach
   - **EnableAutoSync**: Enable automatic synchronization
   - Configure chunking parameters based on selected strategy
5. Click through to **Create stack**

### Configuration Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `KnowledgeBaseName` | MyKnowledgeBase | Name for the knowledge base |
| `ExistingDataSourceBucket` | (empty) | Optional existing S3 bucket name |
| `EmbeddingModelId` | amazon.titan-embed-text-v2:0 | Bedrock embedding model |
| `ChunkingStrategy` | SEMANTIC | FIXED_SIZE, HIERARCHICAL, SEMANTIC, or NONE |
| `EnableAutoSync` | true | Enable automatic sync on S3 changes |
| `AutoSyncDelaySeconds` | 60 | Delay before triggering sync (0-300 seconds) |
| Fixed-size parameters | 300 tokens, 20% overlap | When using FIXED_SIZE |
| Hierarchical parameters | 1500/300 tokens, 60 overlap | When using HIERARCHICAL |
| Semantic parameters | 300 tokens, buffer 1, threshold 95 | When using SEMANTIC |

## How Knowledge Base Auto-Sync Works

The auto-sync feature automatically updates your knowledge base when documents are added or removed from S3. Here's the complete flow:

### Architecture

```
S3 Bucket → EventBridge → SQS Queue → Lambda Function → Bedrock Ingestion Job
                                ↓
                          Dead Letter Queue (DLQ)
```

### Event Flow

1. **S3 Event Generation**
   - When you upload, modify, or delete a file in the source bucket
   - S3 generates EventBridge events: `Object Created` or `Object Deleted`

2. **EventBridge Capture**
   - EventBridge rule filters for events from your specific bucket
   - Matched events are sent to SQS queue

3. **SQS Buffering**
   - SQS accumulates multiple events
   - `MaximumBatchingWindowInSeconds` (configurable 0-300s) buffers events
   - Batches up to 10 events together
   - This prevents triggering a sync for every single file upload

4. **Lambda Processing** (Concurrency Limited to 1)
   - Lambda function limited to single concurrent execution (prevents race conditions)
   - Receives batch of up to 10 events from SQS
   - Checks if an ingestion job is already running via `list_ingestion_jobs`

   **If sync is already running:**
   - Logs: "Ingestion job is IN_PROGRESS"
   - Sends a **single retry message** to SQS with 5-minute delay (`DelaySeconds=300`)
   - Acknowledges current batch (messages auto-deleted on success)
   - This ensures files added during sync are caught in next sync

   **If no sync is running:**
   - Checks queue for pending messages via `get_queue_attributes`
     - Counts visible messages + delayed messages
     - Only purges queue if messages exist (avoids SQS 60-second purge cooldown)
   - **Purges the queue** to remove redundant S3 events and retry messages
     - Since sync processes ALL bucket objects, individual event messages are redundant
     - Prevents message accumulation and retry storms
   - Starts new ingestion job via `start_ingestion_job`
   - Returns job ID and status

5. **Error Handling**
   - Failed messages are retried up to 10 times
   - After 10 failures, messages move to Dead Letter Queue (DLQ)
   - DLQ retains messages for 14 days for troubleshooting

### Sync Logic Features

**Intelligent Batching**: Multiple file uploads within the delay window trigger only one sync

```
Upload file1.pdf (time 0s)
Upload file2.pdf (time 10s)
Upload file3.pdf (time 30s)
→ Single sync triggered at time 60s (if delay = 60s)
```

**Queue Purging**: Before starting each sync, the Lambda purges all messages from the queue
- Bedrock sync processes ALL objects in the bucket, making individual S3 event messages redundant
- Prevents accumulation of stale messages and retry storms
- Smart purging: only purges if messages exist (avoids SQS 60-second purge cooldown)

**Collision Prevention**: If sync is running when new files arrive:
- Current batch is acknowledged (messages auto-deleted)
- Single retry message scheduled with 5-minute delay
- Concurrency limit (1) ensures only one Lambda execution at a time
- Prevents duplicate concurrent syncs and race conditions

**Controlled Retry Loop**: Delayed retry messages prevent busy loops
- While sync runs, new S3 events trigger Lambda (batched every ~60s)
- Each batch sends one retry message with 5-minute delay (`DelaySeconds=300`)
- Retry messages don't trigger Lambda until delay expires
- When retry finally triggers and sync completes, queue is purged and new sync starts
- Idempotent syncs mean extra syncs are harmless (just redundant)

**Retry Strategy**: Failed Lambda executions are retried up to 10 times before moving to DLQ

### Technical Details

**Why Queue Purging is Safe**:
- Bedrock's `start_ingestion_job` scans the entire S3 bucket
- Individual S3 event messages only track which files changed, but sync processes everything anyway
- Purging before sync ensures no redundant messages accumulate
- If purge fails (60-second cooldown), sync proceeds anyway (fault-tolerant design)

**Concurrency Control Benefits**:
- `ReservedConcurrentExecutions: 1` ensures sequential Lambda execution
- Prevents race condition where two Lambdas might start duplicate syncs
- Messages queue up in SQS and process one batch at a time
- Each execution is quick (~100ms for status check, ~1s to start sync)

**Edge Cases Handled**:
- **Fast syncs (<60s)**: Queue check before purge avoids hitting 60-second cooldown
- **Purge failure**: Lambda logs warning and continues with sync (graceful degradation)
- **Sync completes during retry delay**: Next retry triggers new sync (redundant but harmless)
- **Many files during sync**: Batching (60s window) prevents Lambda spam

### Monitoring Auto-Sync

Check sync function logs:
```bash
FUNCTION_NAME=$(aws cloudformation describe-stacks \
  --stack-name my-knowledge-base \
  --query 'Stacks[0].Outputs[?OutputKey==`AutoSyncFunctionArn`].OutputValue' \
  --output text | cut -d: -f7)

aws logs tail /aws/lambda/${FUNCTION_NAME} --follow
```

Check for failed events in DLQ:
```bash
DLQ_URL=$(aws cloudformation describe-stacks \
  --stack-name my-knowledge-base \
  --query 'Stacks[0].Outputs[?OutputKey==`SyncEventDLQUrl`].OutputValue' \
  --output text)

aws sqs receive-message --queue-url ${DLQ_URL}
```

List recent ingestion jobs:
```bash
KB_ID=$(aws cloudformation describe-stacks \
  --stack-name my-knowledge-base \
  --query 'Stacks[0].Outputs[?OutputKey==`KnowledgeBaseId`].OutputValue' \
  --output text)

DS_ID=$(aws cloudformation describe-stacks \
  --stack-name my-knowledge-base \
  --query 'Stacks[0].Outputs[?OutputKey==`DataSourceId`].OutputValue' \
  --output text)

aws bedrock-agent list-ingestion-jobs \
  --knowledge-base-id ${KB_ID} \
  --data-source-id ${DS_ID}
```

## Testing Your Knowledge Base

After deployment and document upload:

1. **Check ingestion status** (if auto-sync is enabled, this happens automatically):
```bash
aws bedrock-agent list-ingestion-jobs \
  --knowledge-base-id ${KB_ID} \
  --data-source-id ${DS_ID}
```

2. **Manually trigger sync** (optional, if auto-sync is disabled):
```bash
aws bedrock-agent start-ingestion-job \
  --knowledge-base-id ${KB_ID} \
  --data-source-id ${DS_ID}
```

3. **Query the knowledge base**:
```bash
aws bedrock-agent-runtime retrieve-and-generate \
  --input '{"text":"Your question here"}' \
  --retrieve-and-generate-configuration '{
    "type":"KNOWLEDGE_BASE",
    "knowledgeBaseConfiguration":{
      "knowledgeBaseId":"'${KB_ID}'",
      "modelArn":"arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-3-sonnet-20240229-v1:0"
    }
  }'
```

## Cleanup

Delete the stack and all resources:

```bash
aws cloudformation delete-stack --stack-name my-knowledge-base
```

**Note**: If you used an existing S3 bucket, it will not be deleted. The vector storage bucket is managed by CloudFormation and will be deleted.
