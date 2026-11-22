
set -euo pipefail

STACK=${1:?Использование: bash demo.sh <имя-стека>}
REGION=${AWS_REGION:-${AWS_DEFAULT_REGION:-eu-central-1}}

out() {
  aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text
}

ALB=$(out AlbUrl)
DLQ=$(out DlqUrl)
LOG_GROUP=$(out LogGroupName)

echo "=== 0. Health-check ==="
curl -s "$ALB/health"; echo

echo
echo "=== 1. Идемпотентность: одно и то же событие (eventId=demo-$$) дважды ==="
BODY="{\"eventId\":\"demo-$$\",\"type\":\"OrderCreated\",\"payload\":{\"orderId\":42}}"
curl -s -X POST "$ALB/publish" -H 'Content-Type: application/json' -d "$BODY"; echo
curl -s -X POST "$ALB/publish" -H 'Content-Type: application/json' -d "$BODY"; echo
sleep 8
echo "--- логи (ищите PROCESSED и DUPLICATE skipped с одним dedup_key) ---"
aws logs tail "$LOG_GROUP" --region "$REGION" --since 2m | grep "dedup_key=demo-$$" || true

echo
echo "=== 2. DLQ: ядовитое сообщение ==="
curl -s -X POST "$ALB/publish" -H 'Content-Type: application/json' \
  -d "{\"eventId\":\"poison-$$\",\"type\":\"OrderCreated\",\"payload\":{\"poison\":true}}"; echo
echo "Жду ~45 секунд: 3 неудачные попытки, потом SQS перекладывает сообщение в DLQ..."
sleep 45
echo "--- логи попыток ---"
aws logs tail "$LOG_GROUP" --region "$REGION" --since 2m | grep "poison-$$" || true
echo "--- сообщений в DLQ (должно быть 1) ---"
aws sqs get-queue-attributes --queue-url "$DLQ" --region "$REGION" \
  --attribute-names ApproximateNumberOfMessages --query 'Attributes.ApproximateNumberOfMessages' --output text
