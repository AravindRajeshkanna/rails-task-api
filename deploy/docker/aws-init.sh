#!/bin/sh
# Creates the messaging resources in the local AWS mock (moto), the same shape deploy/terraform builds in AWS:
#   SNS topic task-api-events --(filter: type)--> SQS notifications (+ DLQ after 5 receives)
set -eu

aws() { command aws --endpoint-url "$AWS_ENDPOINT_URL" --region us-east-1 "$@"; }

topic_arn=$(aws sns create-topic --name task-api-events --query TopicArn --output text)
dlq_url=$(aws sqs create-queue --queue-name notifications-dlq --query QueueUrl --output text)
dlq_arn=$(aws sqs get-queue-attributes --queue-url "$dlq_url" --attribute-names QueueArn --query Attributes.QueueArn --output text)

aws sqs create-queue --queue-name notifications --attributes "{
  \"VisibilityTimeout\": \"60\",
  \"MessageRetentionPeriod\": \"345600\",
  \"RedrivePolicy\": \"{\\\"deadLetterTargetArn\\\":\\\"$dlq_arn\\\",\\\"maxReceiveCount\\\":\\\"5\\\"}\"
}" > /dev/null
queue_url=$(aws sqs get-queue-url --queue-name notifications --query QueueUrl --output text)
queue_arn=$(aws sqs get-queue-attributes --queue-url "$queue_url" --attribute-names QueueArn --query Attributes.QueueArn --output text)

aws sns subscribe --topic-arn "$topic_arn" --protocol sqs --notification-endpoint "$queue_arn" \
  --attributes '{
    "RawMessageDelivery": "true",
    "FilterPolicy": "{\"type\": [\"task.assigned\", \"task.due_soon\", \"task.completed\", \"user.password_reset_requested\"]}"
  }' > /dev/null

echo "topic:  $topic_arn"
echo "queue:  $queue_url"
