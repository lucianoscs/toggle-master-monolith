# ToggleMaster – pacote da Etapa 2 (AWS)

Conteúdo para aplicar sobre o fork do projeto (branch `etapa2-aws`). O passo a passo completo
está no documento `Lab_ToggleMaster_Etapa2_AWS.docx`.

| Arquivo | Para que serve |
|---|---|
| `app.py` | API endurecida: config por ambiente, chave de API, logs JSON, `/ready`, DELETE e paginação |
| `Dockerfile`, `entrypoint.sh` | Imagem Python 3.12, usuário não-root, sem `postgresql-client`, espera o banco com timeout |
| `requirements.in` / `requirements.txt` | Dependências diretas e *lockfile* com todas as versões fixadas |
| `docker-compose.yaml`, `.env.example` | Teste local da MESMA imagem que vai para o ECR (sem bind mount) |
| `scripts/smoke_test.sh` | Teste de fumaça (24 verificações) para uso local ou na AWS |
| `aws/user-data.sh` | Bootstrap da EC2 (instala Docker e o comando `toggle-deploy`) |
| `aws/toggle-deploy.sh` | Deploy por tag de imagem, com leitura do Parameter Store (config) e do Secrets Manager (credenciais), e rollback automático |
| `aws/app-policy.tpl.json`, `aws/trust-policy.json` | Política IAM de privilégio mínimo do servidor (trocar REGION e ACCOUNT_ID); inclui acesso ao segredo `toggle-master/prod` |
| `aws/ecr-lifecycle.json` | Mantém só as 5 imagens mais recentes no ECR |

Segredos nunca vão para o Git: `.env` está no `.gitignore`; na AWS, `DB_PASSWORD` e `API_KEY` ficam no **AWS Secrets Manager** (o resto da configuração, no SSM Parameter Store).
