"""ToggleMaster (monolito) - versão Etapa 2 (AWS).

Melhorias em relação à versão original (ver Parte II do guia da Etapa 1):
  - configuração 100% por variáveis de ambiente (inclui DB_PORT e SSL), com falha
    imediata se algo obrigatório faltar;
  - autenticação por chave de API (cabeçalho X-API-Key) nos endpoints de escrita;
  - erros 5xx nunca expõem detalhes internos (o detalhe vai para o log);
  - validação de entrada (tamanho/tipo de "name" e tipo de "is_enabled");
  - logs estruturados em JSON (stdout), com log de acesso e request id;
  - /health (liveness) e /ready (readiness, consulta o banco);
  - DELETE /flags/<nome> e paginação em GET /flags.
"""
import hmac
import json
import logging
import os
import sys
import time
import uuid
from contextlib import contextmanager
from functools import wraps

import psycopg2
from flask import Flask, g, jsonify, request
from psycopg2.extras import RealDictCursor
from werkzeug.exceptions import HTTPException

# --------------------------------------------------------------------------
# Configuração (Fator III: tudo vem do ambiente)
# --------------------------------------------------------------------------
def _env(name, default=None):
    value = os.getenv(name)
    return value if value not in (None, "") else default


DB_HOST = _env("DB_HOST")
DB_PORT = int(_env("DB_PORT", "5432"))
DB_NAME = _env("DB_NAME")
DB_USER = _env("DB_USER")
DB_PASSWORD = _env("DB_PASSWORD")
DB_SSLMODE = _env("DB_SSLMODE", "prefer")  # na AWS: "require" (ou "verify-full")
DB_SSLROOTCERT = _env("DB_SSLROOTCERT")  # opcional (necessário para verify-full)
DB_CONNECT_TIMEOUT = int(_env("DB_CONNECT_TIMEOUT", "5"))

API_KEY = _env("API_KEY")
AUTH_DISABLED = _env("AUTH_DISABLED", "false").lower() == "true"  # só para desenvolvimento

MAX_NAME_LENGTH = 100
DEFAULT_LIMIT = 100
MAX_LIMIT = 500


def validate_config():
    """Falha cedo (Fator IX) se faltar configuração obrigatória."""
    required = {
        "DB_HOST": DB_HOST,
        "DB_NAME": DB_NAME,
        "DB_USER": DB_USER,
        "DB_PASSWORD": DB_PASSWORD,
    }
    if not AUTH_DISABLED:
        required["API_KEY"] = API_KEY
    missing = [name for name, value in required.items() if not value]
    if missing:
        raise RuntimeError(
            "Variáveis de ambiente obrigatórias ausentes: " + ", ".join(missing)
        )


validate_config()

app = Flask(__name__)
app.json.ensure_ascii = False  # acentos legíveis no JSON

# --------------------------------------------------------------------------
# Logs estruturados (Fator XI): JSON em stdout
# --------------------------------------------------------------------------
class JsonFormatter(logging.Formatter):
    EXTRA_FIELDS = ("request_id", "method", "path", "status", "duration_ms", "remote_addr")

    def format(self, record):
        payload = {
            "ts": self.formatTime(record, "%Y-%m-%dT%H:%M:%S%z"),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
        }
        for field in self.EXTRA_FIELDS:
            if hasattr(record, field):
                payload[field] = getattr(record, field)
        if record.exc_info:
            payload["exc"] = self.formatException(record.exc_info)
        return json.dumps(payload, ensure_ascii=False)


logger = logging.getLogger("toggle")
logger.setLevel(_env("LOG_LEVEL", "INFO").upper())
if not logger.handlers:
    _handler = logging.StreamHandler(sys.stdout)
    _handler.setFormatter(JsonFormatter())
    logger.addHandler(_handler)
    logger.propagate = False


@app.before_request
def _start_request():
    g.start = time.perf_counter()
    g.request_id = request.headers.get("X-Request-ID") or uuid.uuid4().hex[:12]


@app.after_request
def _log_request(response):
    duration_ms = round((time.perf_counter() - g.get("start", time.perf_counter())) * 1000, 1)
    quiet = request.path in ("/health", "/ready")  # checagens frequentes: só em DEBUG
    logger.log(
        logging.DEBUG if quiet else logging.INFO,
        "request",
        extra={
            "request_id": g.get("request_id"),
            "method": request.method,
            "path": request.path,
            "status": response.status_code,
            "duration_ms": duration_ms,
            "remote_addr": request.headers.get("X-Forwarded-For", request.remote_addr),
        },
    )
    response.headers["X-Request-ID"] = g.get("request_id", "")
    return response


# --------------------------------------------------------------------------
# Banco de dados
# --------------------------------------------------------------------------
def get_db_connection():
    params = dict(
        host=DB_HOST,
        port=DB_PORT,
        dbname=DB_NAME,
        user=DB_USER,
        password=DB_PASSWORD,
        sslmode=DB_SSLMODE,
        connect_timeout=DB_CONNECT_TIMEOUT,
    )
    if DB_SSLROOTCERT:
        params["sslrootcert"] = DB_SSLROOTCERT
    return psycopg2.connect(**params)


@contextmanager
def db_cursor(dict_rows=False, commit=False):
    """Abre conexão + cursor, faz commit/rollback e sempre fecha tudo."""
    conn = get_db_connection()
    try:
        cur = conn.cursor(cursor_factory=RealDictCursor) if dict_rows else conn.cursor()
        try:
            yield cur
            if commit:
                conn.commit()
        finally:
            cur.close()
    except Exception:
        if not conn.closed:
            conn.rollback()
        raise
    finally:
        if not conn.closed:
            conn.close()


def init_db():
    with db_cursor(commit=True) as cur:
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS flags (
                id SERIAL PRIMARY KEY,
                name VARCHAR(100) UNIQUE NOT NULL,
                is_enabled BOOLEAN NOT NULL DEFAULT false,
                created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
            );
            """
        )


@app.cli.command("init-db")
def init_db_command():
    """Cria a tabela 'flags' (tarefa administrativa pontual - Fator XII)."""
    logger.info("Inicializando a tabela 'flags'...")
    try:
        init_db()
    except Exception:
        logger.exception("Falha ao inicializar o banco de dados")
        raise SystemExit(1)
    logger.info("Tabela 'flags' pronta.")


# --------------------------------------------------------------------------
# Autenticação e tratamento de erros
# --------------------------------------------------------------------------
def require_api_key(view):
    @wraps(view)
    def wrapper(*args, **kwargs):
        if not AUTH_DISABLED:
            provided = request.headers.get("X-API-Key", "")
            if not API_KEY or not hmac.compare_digest(provided.encode(), API_KEY.encode()):
                return jsonify({"error": "Não autorizado"}), 401
        return view(*args, **kwargs)

    return wrapper


@app.errorhandler(HTTPException)
def handle_http_error(err):
    return jsonify({"error": err.description}), err.code


@app.errorhandler(psycopg2.OperationalError)
def handle_db_unavailable(err):
    logger.error("Banco de dados indisponível: %s", err, extra={"request_id": g.get("request_id")})
    return jsonify({"error": "Serviço temporariamente indisponível"}), 503


@app.errorhandler(Exception)
def handle_unexpected_error(err):
    # O detalhe da exceção vai para o log; o cliente recebe apenas uma mensagem genérica.
    logger.exception("Erro não tratado", extra={"request_id": g.get("request_id")})
    return jsonify({"error": "Erro interno no servidor"}), 500


# --------------------------------------------------------------------------
# Rotas
# --------------------------------------------------------------------------
@app.route("/health", methods=["GET"])
def health_check():
    """Liveness: o processo web está de pé (não consulta o banco)."""
    return jsonify({"status": "ok"}), 200


@app.route("/ready", methods=["GET"])
def readiness_check():
    """Readiness: consegue falar com o banco?"""
    try:
        with db_cursor() as cur:
            cur.execute("SELECT 1")
    except Exception as err:  # noqa: BLE001
        logger.error("Readiness falhou: %s", err, extra={"request_id": g.get("request_id")})
        return jsonify({"status": "unavailable"}), 503
    return jsonify({"status": "ready"}), 200


def _validate_name(value):
    if not isinstance(value, str) or not value.strip():
        return "O campo 'name' é obrigatório"
    if len(value) > MAX_NAME_LENGTH:
        return f"O campo 'name' deve ter no máximo {MAX_NAME_LENGTH} caracteres"
    return None


@app.route("/flags", methods=["POST"])
@require_api_key
def create_flag():
    data = request.get_json(silent=True)
    if not isinstance(data, dict) or "name" not in data:
        return jsonify({"error": "O campo 'name' é obrigatório"}), 400

    error = _validate_name(data["name"])
    if error:
        return jsonify({"error": error}), 400

    name = data["name"]
    is_enabled = data.get("is_enabled", False)
    if not isinstance(is_enabled, bool):
        return jsonify({"error": "O campo 'is_enabled' deve ser booleano"}), 400

    try:
        with db_cursor(commit=True) as cur:
            cur.execute(
                "INSERT INTO flags (name, is_enabled) VALUES (%s, %s)", (name, is_enabled)
            )
    except psycopg2.IntegrityError:
        return jsonify({"error": f"A flag '{name}' já existe"}), 409
    return jsonify({"message": f"Flag '{name}' criada com sucesso"}), 201


@app.route("/flags", methods=["GET"])
def get_flags():
    try:
        limit = int(request.args.get("limit", DEFAULT_LIMIT))
        offset = int(request.args.get("offset", 0))
    except ValueError:
        return jsonify({"error": "Os parâmetros 'limit' e 'offset' devem ser inteiros"}), 400
    if not 1 <= limit <= MAX_LIMIT or offset < 0:
        return jsonify({"error": f"'limit' deve estar entre 1 e {MAX_LIMIT} e 'offset' deve ser >= 0"}), 400

    with db_cursor(dict_rows=True) as cur:
        cur.execute("SELECT COUNT(*) AS total FROM flags")
        total = cur.fetchone()["total"]
        cur.execute(
            "SELECT name, is_enabled FROM flags ORDER BY name LIMIT %s OFFSET %s",
            (limit, offset),
        )
        flags = cur.fetchall()

    response = jsonify(flags)
    response.headers["X-Total-Count"] = str(total)
    return response, 200


@app.route("/flags/<string:name>", methods=["GET"])
def get_flag_status(name):
    with db_cursor(dict_rows=True) as cur:
        cur.execute("SELECT name, is_enabled FROM flags WHERE name = %s", (name,))
        flag = cur.fetchone()
    if flag:
        return jsonify(flag), 200
    return jsonify({"error": "Flag não encontrada"}), 404


@app.route("/flags/<string:name>", methods=["PUT"])
@require_api_key
def update_flag(name):
    data = request.get_json(silent=True)
    if not isinstance(data, dict) or not isinstance(data.get("is_enabled"), bool):
        return jsonify({"error": "O campo 'is_enabled' (booleano) é obrigatório"}), 400

    with db_cursor(commit=True) as cur:
        cur.execute(
            "UPDATE flags SET is_enabled = %s WHERE name = %s", (data["is_enabled"], name)
        )
        updated = cur.rowcount
    if updated == 0:
        return jsonify({"error": "Flag não encontrada"}), 404
    return jsonify({"message": f"Flag '{name}' atualizada"}), 200


@app.route("/flags/<string:name>", methods=["DELETE"])
@require_api_key
def delete_flag(name):
    with db_cursor(commit=True) as cur:
        cur.execute("DELETE FROM flags WHERE name = %s", (name,))
        deleted = cur.rowcount
    if deleted == 0:
        return jsonify({"error": "Flag não encontrada"}), 404
    return jsonify({"message": f"Flag '{name}' removida"}), 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(_env("PORT", "5000")))
