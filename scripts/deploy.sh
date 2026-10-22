#!/usr/bin/env bash
# Kullanım: deploy.sh <imaj-digest>      örnek: deploy.sh sha256:3f1c...e9
# GitHub Actions içinden çalışır. Uygulama sunucusunu bulur ve SSM üzerinden
# case1-deploy-app dokümanını çalıştırır. Doküman sunucuda şunları yapar:
# ECR login → digest ile pull → eski container'ı sil → yenisini başlat → sağlık kontrolü.
# Sunucuya serbest komut gönderilmiyor; tek parametre digest ve doküman onu regex ile doğruluyor.
set -euo pipefail

DIGEST="${1:-}"
DOCUMENT="${DEPLOY_DOCUMENT:-case1-deploy-app}"
POLL_INTERVAL=10   # saniye
POLL_MAX=30        # 30 x 10 sn = en fazla ~5 dk

if [[ ! "$DIGEST" =~ ^sha256:[a-f0-9]{64}$ ]]; then
  echo "HATA: Geçersiz digest: '$DIGEST' (beklenen: sha256:<64 hex>)"
  exit 1
fi

INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=case1-app" "Name=instance-state-name,Values=running" \
  --query "Reservations[0].Instances[0].InstanceId" --output text)

if [ "$INSTANCE_ID" = "None" ] || [ -z "$INSTANCE_ID" ]; then
  echo "HATA: Çalışan bir case1-app sunucusu bulunamadı."
  exit 1
fi
echo "Hedef sunucu: $INSTANCE_ID"
echo "Doküman: $DOCUMENT"
echo "Digest: $DIGEST"

CMD_ID=$(aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "$DOCUMENT" \
  --comment "deploy $DIGEST" \
  --parameters "{\"ImageDigest\":[\"$DIGEST\"]}" \
  --query "Command.CommandId" --output text)
echo "SSM komut ID: $CMD_ID"

# "aws ssm wait command-executed" ~100 sn sonra vazgeçiyor. Onun yerine durumu
# kendimiz sorguluyoruz: komut bitene (Pending/InProgress/Delayed/Cancelling dışı) kadar.
# Komut gönderildikten hemen sonra invocation henüz oluşmamış olabilir
# (InvocationDoesNotExist); bunu da "bekliyor" sayıyoruz.
STATUS="Pending"
for i in $(seq 1 "$POLL_MAX"); do
  sleep "$POLL_INTERVAL"
  STATUS=$(aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
    --query "Status" --output text 2>/dev/null || echo "Pending")
  echo "[$i/$POLL_MAX] Durum: $STATUS"
  case "$STATUS" in
    Pending|InProgress|Delayed|Cancelling) ;;
    *) break ;;
  esac
done

echo "----- sunucudaki çıktı -----"
aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
  --query "[StandardOutputContent, StandardErrorContent]" --output text || true
echo "----------------------------"
echo "Durum: $STATUS"

if [ "$STATUS" != "Success" ]; then
  echo "HATA: Deploy başarısız ya da zaman aşımı (durum: $STATUS)."
  exit 1
fi
