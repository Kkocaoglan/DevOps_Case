#!/usr/bin/env bash
# Kullanım: deploy.sh <ecr-imaj-adresi:tag>
# GitHub Actions içinden çalışır. Nginx sunucusunu bulur, SSM ile şu komutları
# çalıştırır: ECR login → pull → eski container'ı sil → yenisini başlat → sağlık kontrolü.
set -euo pipefail

IMAGE="$1"
REGISTRY="${IMAGE%%/*}"
REGION="${AWS_DEFAULT_REGION:-eu-north-1}"

INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=case1-app" "Name=instance-state-name,Values=running" \
  --query "Reservations[0].Instances[0].InstanceId" --output text)

if [ "$INSTANCE_ID" = "None" ] || [ -z "$INSTANCE_ID" ]; then
  echo "HATA: Çalışan bir case1-app sunucusu bulunamadı."
  exit 1
fi
echo "Hedef sunucu: $INSTANCE_ID"

cat > /tmp/params.json <<JSON
{
  "commands": [
    "set -e",
    "aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $REGISTRY",
    "docker pull $IMAGE",
    "docker rm -f web || true",
    "docker run -d --name web --restart unless-stopped -p 80:80 $IMAGE",
    "sleep 3",
    "curl -fsS -o /dev/null http://localhost && echo SAGLIK_KONTROLU_OK",
    "docker image prune -af"
  ]
}
JSON

CMD_ID=$(aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --comment "deploy $IMAGE" \
  --parameters file:///tmp/params.json \
  --query "Command.CommandId" --output text)
echo "SSM komut ID: $CMD_ID"

aws ssm wait command-executed --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" || true

STATUS=$(aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
  --query "Status" --output text)
echo "----- sunucudaki çıktı -----"
aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
  --query "[StandardOutputContent, StandardErrorContent]" --output text
echo "----------------------------"
echo "Durum: $STATUS"
test "$STATUS" = "Success"
