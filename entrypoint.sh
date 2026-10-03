#!/bin/sh
# Entrypoint do ToggleMaster (Etapa 2).
#  - valida a configuração obrigatória (falha cedo);
#  - espera o banco aceitar conexões TCP, com timeout;
#  - sem argumentos (ou "serve"): inicia o Gunicorn;
#  - com argumentos: executa o comando informado (ex.: tarefa pontual "flask --app app init-db").
set -eu

: "${DB_HOST:?Variável DB_HOST não definida}"
: "${DB_NAME:?Variável DB_NAME não definida}"
: "${DB_USER:?Variável DB_USER não definida}"
: "${DB_PASSWORD:?Variável DB_PASSWORD não definida}"

DB_PORT="${DB_PORT:-5432}"
PORT="${PORT:-5000}"
DB_WAIT_TIMEOUT="${DB_WAIT_TIMEOUT:-60}"

echo "Aguardando o banco de dados em ${DB_HOST}:${DB_PORT} (timeout de ${DB_WAIT_TIMEOUT}s)..."
python - "$DB_HOST" "$DB_PORT" "$DB_WAIT_TIMEOUT" <<'PY'
import socket
import sys
import time

host, port, timeout = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
deadline = time.time() + timeout
while True:
    try:
        socket.create_connection((host, port), timeout=3).close()
        break
    except OSError:
        if time.time() >= deadline:
            print(f"Erro: banco de dados indisponível em {host}:{port} após {timeout}s", file=sys.stderr)
            sys.exit(1)
        time.sleep(1)
PY
echo "Banco de dados acessível."

if [ "$#" -eq 0 ] || [ "$1" = "serve" ]; then
  # Opt-in: cria a tabela ao iniciar (útil no desenvolvimento local; na AWS é uma tarefa separada).
  if [ "${RUN_INIT_DB:-false}" = "true" ]; then
    echo "RUN_INIT_DB=true: executando flask init-db..."
    flask --app app init-db
  fi
  echo "Iniciando o Gunicorn em 0.0.0.0:${PORT} com ${WEB_CONCURRENCY:-2} worker(s)..."
  exec gunicorn --bind "0.0.0.0:${PORT}" \
    --workers "${WEB_CONCURRENCY:-2}" \
    --timeout 30 --graceful-timeout 30 \
    --error-logfile - \
    app:app
fi

exec "$@"
