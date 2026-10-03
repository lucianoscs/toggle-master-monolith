# toggle-master-etapa2 – pacote de atualização (laboratório AWS / Learner Lab)

Este pacote traz os arquivos **atualizados** do laboratório da Etapa 2 (guia
`Lab_ToggleMaster_Etapa2_AWS_Modelo.docx`). Ele é um *complemento* do
`toggle-master-etapa2.zip` original: não contém o código da aplicação.

## O que está incluído

| Arquivo | Mudança |
|---|---|
| `aws/user-data.sh` | `toggle-deploy` embutido com `wait_ready` limitado a 60 s de relógio (`curl --max-time 3`). |
| `aws/toggle-deploy.sh` | Cópia avulsa do mesmo script (idêntico ao embutido no user-data). |
| `aws/toggle-recover.sh` | Novo: recupera as variáveis do laboratório após queda da sessão (Anexo H). |
| `aws/app-policy.tpl.json` | Política IAM do servidor (Anexo E, Trilha A). |
| `aws/trust-policy.json` | Política de confiança da EC2 (Anexo E). |
| `aws/ecr-lifecycle.json` | Mantém as 5 imagens com tag mais recentes (ignora manifestos sem tag do buildx). |
| `postman/toggle-master.postman_collection.json` | Coleção: 21 requisições, 25 verificações, nome de flag único por execução. |
| `postman/toggle-master-aws.postman_environment.json` | Ambiente AWS (`base_url` vazio, `api_key` tipo secret). |
| `postman/toggle-master-local.postman_environment.json` | Ambiente local (`http://localhost:5000`). |

## Não incluído (vem do zip original)

`app.py`, `Dockerfile`, `entrypoint.sh`, `requirements.txt`, `docker-compose.yaml`,
`.env.example`, `.gitignore`, `scripts/smoke_test.sh`, `scripts/provision.sh`.

## Como gerar o `toggle-master-etapa2.zip` completo e atualizado

Na pasta do Vagrantfile (host), com os dois zips lado a lado:

```bash
cp toggle-master-etapa2.zip toggle-master-etapa2.ORIGINAL.zip   # backup
mkdir -p /tmp/merge && cd /tmp/merge
unzip -q -o <caminho>/toggle-master-etapa2.ORIGINAL.zip
unzip -q -o <caminho>/toggle-master-etapa2-aws-update.zip       # sobrescreve aws/ e postman/
zip -qr <caminho>/toggle-master-etapa2.zip toggle-master-etapa2
```

(ou execute `bash merge-package.sh` – veja o script nesta pasta.)

## Validação feita neste pacote

* `bash -n` nos três scripts; o `toggle-deploy` embutido no `user-data.sh` é idêntico ao avulso.
* `wait_ready` testado contra um servidor que aceita a conexão e nunca responde: retorna por tempo, sem travar.
* Coleção Postman executada com Newman contra um servidor simulado: 21 requisições, 25 verificações, 0 falhas.
  (Não foi testada contra a aplicação real nem contra a AWS: faça isso no Passo 13.3.)
