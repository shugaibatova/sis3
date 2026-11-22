
set -euo pipefail

STACK=${1:?Использование: bash deploy.sh <имя-стека>   например: bash deploy.sh sis3-main}
REGION=${AWS_REGION:-${AWS_DEFAULT_REGION:-eu-central-1}}
TAG=$(git rev-parse --short HEAD)
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)

echo ">> Стек: $STACK | регион: $REGION | тег образа: $TAG"

if [ -n "$(git status --porcelain)" ]; then
  echo "!! Внимание: есть незакоммиченные изменения. Сделайте git commit, иначе тег образа не отражает код."
fi

VPC=$(aws ec2 describe-vpcs --region "$REGION" --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
if [ "$VPC" = "None" ]; then echo "Нет default VPC в регионе $REGION"; exit 1; fi
SUBNETS=$(aws ec2 describe-subnets --region "$REGION" \
  --filters Name=vpc-id,Values="$VPC" Name=default-for-az,Values=true \
  --query 'Subnets[*].SubnetId' --output text | tr '\t' ',')

out() {
  aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text
}

deploy() {
  aws cloudformation deploy \
    --stack-name "$STACK" \
    --template-file template.yaml \
    --capabilities CAPABILITY_IAM \
    --region "$REGION" \
    --no-fail-on-empty-changeset \
    --parameter-overrides VpcId="$VPC" SubnetIds="$SUBNETS" ImageTag="$TAG" DesiredCount="$1"
}

STATUS=$(aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" \
  --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo NONE)
if [ "$STATUS" = "ROLLBACK_COMPLETE" ]; then
  echo ">> Удаляю неудачный стек $STACK"
  aws cloudformation delete-stack --stack-name "$STACK" --region "$REGION"
  aws cloudformation wait stack-delete-complete --stack-name "$STACK" --region "$REGION"
fi

echo ">> Шаг 1/3: создаю инфраструктуру (задач пока 0, образа ещё нет)"
deploy 0

REPO=$(out RepoUri)
REPO_NAME=${REPO#*/}

echo ">> Шаг 2/3: собираю и отправляю Docker-образ в ECR"
aws ecr get-login-password --region "$REGION" | \
  docker login --username AWS --password-stdin "$ACCOUNT.dkr.ecr.$REGION.amazonaws.com"
if aws ecr describe-images --region "$REGION" --repository-name "$REPO_NAME" --image-ids imageTag="$TAG" >/dev/null 2>&1; then
  echo "   образ с тегом $TAG уже есть в ECR, пропускаю (теги неизменяемые)"
else
  docker build --platform linux/amd64 -t "$REPO:$TAG" .
  docker push "$REPO:$TAG"
fi

echo ">> Шаг 3/3: запускаю сервис (1 задача)"
deploy 1

echo ">> Жду, пока сервис стабилизируется..."
CLUSTER=$(aws cloudformation describe-stack-resources --stack-name "$STACK" --region "$REGION" \
  --logical-resource-id Cluster --query 'StackResources[0].PhysicalResourceId' --output text)
SERVICE=$(aws cloudformation describe-stack-resources --stack-name "$STACK" --region "$REGION" \
  --logical-resource-id Service --query 'StackResources[0].PhysicalResourceId' --output text)
aws ecs wait services-stable --cluster "$CLUSTER" --services "$SERVICE" --region "$REGION"

echo
echo "ГОТОВО. Адрес приложения: $(out AlbUrl)"
echo "Проверка:  curl $(out AlbUrl)/health"
echo "Демо:      bash demo.sh $STACK"
