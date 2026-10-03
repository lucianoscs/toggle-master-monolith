#!/bin/bash
# User data da EC2 do ToggleMaster (Amazon Linux 2023).
# Instala o Docker e o comando "toggle-deploy" (usado no Passo de deploy).
# Saída deste script: /var/log/cloud-init-output.log
set -euxo pipefail
 
dnf install -y docker
systemctl enable --now docker
usermod -aG docker ec2-user
 
mkdir -p /etc/toggle
cat > /usr/local/bin/toggle-deploy <<'DEPLOY_EOF'
#!/usr/bin/env bash
# toggle-deploy - publica uma versão (tag de imagem do ECR) do ToggleMaster nesta instância EC2.
#
# Uso: sudo toggle-deploy <tag> [--init-db]
#   <tag>       tag da imagem no ECR (SHA curto do commit, ex.: a1b2c3d)
#   --init-db   executa antes a tarefa pontual "flask init-db" (necessário no 1º deploy)
#
# Configuração: os valores não sensíveis vêm do SSM Parameter Store (/toggle-master/prod/*);
# DB_PASSWORD e API_KEY vêm de um segredo no AWS Secrets Manager (toggle-master/prod) – nunca
# ficam em texto claro em parâmetro, log ou arquivo permanente. Alternativa para contas sem
# acesso a esses dois serviços: arquivo local /etc/toggle/app.env (ver Anexo D).
# Se a nova versão não ficar pronta (/ready), volta automaticamente para a versão anterior.
set -euo pipefail
export HOME="${HOME:-/root}"
 
TAG="${1:?Uso: toggle-deploy <tag> [--init-db]}"
INIT_DB="nao"
if [ "${2:-}" = "--init-db" ]; then INIT_DB="sim"; fi
 
ECR_REPO="${ECR_REPO:-toggle-master}"
SSM_PATH="${SSM_PATH:-/toggle-master/prod}"
SECRET_ID="${SECRET_ID:-toggle-master/prod}"
LOG_GROUP="${LOG_GROUP:-/toggle-master/app}"
LOCAL_ENV_FILE="/etc/toggle/app.env"
CONTAINER="toggle-app"
 
# Região (IMDSv2) e conta
TOKEN="$(curl -sf -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')"
REGION="$(curl -sf -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/region)"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text --region "$REGION")"
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
IMAGE="${REGISTRY}/${ECR_REPO}:${TAG}"
 
echo ">> Login no ECR e download da imagem ${IMAGE}"
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$REGISTRY" > /dev/null
docker pull "$IMAGE"
 
# Configuração da aplicação -> arquivo temporário (somente root), removido ao final
ENV_FILE="$(mktemp /run/toggle-env.XXXXXX)"
trap 'rm -f "$ENV_FILE"' EXIT
chmod 600 "$ENV_FILE"
if [ -f "$LOCAL_ENV_FILE" ]; then
  echo ">> Configuração e segredos lidos de ${LOCAL_ENV_FILE}"
  cat "$LOCAL_ENV_FILE" > "$ENV_FILE"
else
  echo ">> Configuração (não sensível) lida do SSM Parameter Store (${SSM_PATH})"
  aws ssm get-parameters-by-path --path "$SSM_PATH" --region "$REGION" \
      --query 'Parameters[].[Name,Value]' --output text \
    | while IFS=$'\t' read -r name value; do printf '%s=%s\n' "${name##*/}" "$value"; done > "$ENV_FILE"
 
  echo ">> Segredos lidos do AWS Secrets Manager (${SECRET_ID}) – o valor nunca é exibido"
  SECRET_JSON="$(aws secretsmanager get-secret-value --secret-id "$SECRET_ID" --region "$REGION" \
      --query SecretString --output text)"
  SECRET_JSON="$SECRET_JSON" python3 -c '
import json, os
for k, v in json.loads(os.environ["SECRET_JSON"]).items():
    print(f"{k}={v}")
' >> "$ENV_FILE"
  unset SECRET_JSON
fi
for var in DB_HOST DB_NAME DB_USER DB_PASSWORD API_KEY; do
  grep -q "^${var}=" "$ENV_FILE" || { echo "ERRO: parâmetro ${var} ausente na configuração."; exit 1; }
done
 
run_container() { # $1 = imagem
  docker run -d --name "$CONTAINER" --restart unless-stopped \
    --env-file "$ENV_FILE" -p 80:5000 \
    --log-driver awslogs \
    --log-opt awslogs-region="$REGION" \
    --log-opt awslogs-group="$LOG_GROUP" \
    --log-opt awslogs-stream="$(hostname)/${CONTAINER}" \
    "$1" > /dev/null
}
 
wait_ready() {
  local deadline=$((SECONDS + 60))
  while [ "$SECONDS" -lt "$deadline" ]; do
    curl -sf --max-time 3 http://127.0.0.1/ready > /dev/null && return 0
    sleep 2
  done
  return 1
}
 
if [ "$INIT_DB" = "sim" ]; then
  echo ">> Tarefa pontual: flask init-db"
  docker run --rm --env-file "$ENV_FILE" "$IMAGE" flask --app app init-db
fi
 
PREVIOUS="$(docker inspect -f '{{.Config.Image}}' "$CONTAINER" 2> /dev/null || true)"
echo ">> Versão anterior: ${PREVIOUS:-nenhuma}"
docker rm -f "$CONTAINER" > /dev/null 2>&1 || true
echo ">> Iniciando ${IMAGE}"
run_container "$IMAGE"
 
if wait_ready; then
  echo ">> OK: ${IMAGE} respondendo em /ready."
  exit 0
fi
 
echo "ERRO: a nova versão não ficou pronta em 60s. Últimas linhas do log do container:"
docker logs --tail 20 "$CONTAINER" 2>&1 || true
docker rm -f "$CONTAINER" > /dev/null 2>&1 || true
if [ -n "$PREVIOUS" ] && [ "$PREVIOUS" != "$IMAGE" ]; then
  echo ">> Rollback para ${PREVIOUS}"
  run_container "$PREVIOUS"
  if wait_ready; then echo ">> Rollback concluído."; else echo ">> ATENÇÃO: o rollback também não ficou pronto."; fi
fi
exit 1
DEPLOY_EOF
chmod 755 /usr/local/bin/toggle-deploy
 
echo "bootstrap concluído em $(date -u +%FT%TZ)" > /etc/toggle/bootstrap.done
