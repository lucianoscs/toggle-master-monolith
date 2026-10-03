#!/bin/bash
# toggle-recover.sh - uso: source ~/toggle-recover.sh
# Redescobre, pelos nomes/tags, os recursos dos Passos 4 a 11 e refaz o login
# no ECR. Nao grava segredos em arquivo.
export AWS_REGION=us-east-1
export AWS_DEFAULT_REGION=us-east-1
 
# 0) Credenciais validas? (senao, atualize ~/.aws/credentials)
if ! aws sts get-caller-identity >/dev/null 2>&1; then
  echo "Credenciais AWS ausentes ou expiradas."
  return 1 2>/dev/null || exit 1
fi
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGISTRY="$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"
 
# Rede
VPC_ID=$(aws ec2 describe-vpcs \
  --filters Name=tag:Name,Values=toggle-vpc \
  --query 'Vpcs[0].VpcId' --output text)
IGW_ID=$(aws ec2 describe-internet-gateways \
  --filters Name=tag:Name,Values=toggle-igw \
  --query 'InternetGateways[0].InternetGatewayId' --output text)
SUBNET_PUB=$(aws ec2 describe-subnets \
  --filters Name=tag:Name,Values=toggle-public-a \
  --query 'Subnets[0].SubnetId' --output text)
SUBNET_DB1=$(aws ec2 describe-subnets \
  --filters Name=tag:Name,Values=toggle-private-db-a \
  --query 'Subnets[0].SubnetId' --output text)
SUBNET_DB2=$(aws ec2 describe-subnets \
  --filters Name=tag:Name,Values=toggle-private-db-b \
  --query 'Subnets[0].SubnetId' --output text)
RT_PUB=$(aws ec2 describe-route-tables \
  --filters Name=tag:Name,Values=toggle-public-rt \
  --query 'RouteTables[0].RouteTableId' --output text)
RTASSOC_PUB=$(aws ec2 describe-route-tables --route-table-ids "$RT_PUB" \
  --query "RouteTables[0].Associations[?SubnetId=='$SUBNET_PUB'].RouteTableAssociationId | [0]" \
  --output text)
SG_APP=$(aws ec2 describe-security-groups \
  --filters Name=group-name,Values=toggle-app-sg Name=vpc-id,Values="$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' --output text)
SG_DB=$(aws ec2 describe-security-groups \
  --filters Name=group-name,Values=toggle-db-sg Name=vpc-id,Values="$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' --output text)
 
# Servidor e IP fixo (inclui instancia parada)
INSTANCE_ID=$(aws ec2 describe-instances \
  --filters Name=tag:Name,Values=toggle-app \
  Name=instance-state-name,Values=pending,running,stopping,stopped \
  --query 'Reservations[].Instances[].InstanceId | [0]' --output text)
ALLOC_ID=$(aws ec2 describe-addresses \
  --filters Name=instance-id,Values="$INSTANCE_ID" \
  --query 'Addresses[0].AllocationId' --output text)
EIP=$(aws ec2 describe-addresses \
  --filters Name=instance-id,Values="$INSTANCE_ID" \
  --query 'Addresses[0].PublicIp' --output text)
 
# Banco
DB_HOST=$(aws rds describe-db-instances --db-instance-identifier toggle-db \
  --query 'DBInstances[0].Endpoint.Address' --output text)
 
# Imagens: TAG = mais recente no ECR; TAG_ANTERIOR so existe apos o Passo 17
TAG=$(aws ecr describe-images --repository-name toggle-master \
  --query 'sort_by(imageDetails[?imageTags!=`null`],&imagePushedAt)[-1].imageTags[0]' \
  --output text)
TAG_ANTERIOR=$(aws ecr describe-images --repository-name toggle-master \
  --query 'sort_by(imageDetails[?imageTags!=`null`],&imagePushedAt)[-2].imageTags[0]' \
  --output text)
[ "$TAG_ANTERIOR" = "None" ] && TAG_ANTERIOR=""
 
# Chave da API (segredo do Secrets Manager; fica so nesta sessao, sem export)
API_KEY=$(aws secretsmanager get-secret-value --secret-id toggle-master/prod \
  --query SecretString --output text \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["API_KEY"])')
 
# Validacao
for v in ACCOUNT_ID VPC_ID IGW_ID SUBNET_PUB SUBNET_DB1 SUBNET_DB2 RT_PUB \
         RTASSOC_PUB SG_APP SG_DB INSTANCE_ID ALLOC_ID EIP DB_HOST TAG; do
  if [ -z "${!v}" ] || [ "${!v}" = "None" ]; then
    echo "AUSENTE: $v"
  else
    echo "OK  $v=${!v}"
  fi
done
echo "OPCIONAL TAG_ANTERIOR=${TAG_ANTERIOR:-(so existe apos o Passo 17)}"
echo "API_KEY=${API_KEY:0:4}... (oculta)"
echo "Aviso: TAG e a imagem mais recente do ECR, nao necessariamente a que"
echo "esta em execucao. No servidor: sudo docker inspect -f '{{.Config.Image}}' toggle-app"
 
# Estado dos recursos (o laboratorio pode te-los parado)
echo; echo "Estado da EC2:"
aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].State.Name' --output text
echo "Estado do RDS:"
aws rds describe-db-instances --db-instance-identifier toggle-db \
  --query 'DBInstances[0].DBInstanceStatus' --output text
# Se estiverem parados:
# aws ec2 start-instances --instance-ids "$INSTANCE_ID"
# aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"
# aws rds start-db-instance --db-instance-identifier toggle-db --no-cli-pager
# aws rds wait db-instance-available --db-instance-identifier toggle-db
 
# Login no ECR (o token do Docker tambem expira)
aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$REGISTRY"
echo "Ambiente recuperado."
