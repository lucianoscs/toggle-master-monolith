#!/usr/bin/env bash
# Teste de fumaça do ToggleMaster (local ou AWS).
# Uso: scripts/smoke_test.sh <URL_BASE> <API_KEY>
#   ex.: scripts/smoke_test.sh http://localhost:5000 minha-chave
#        scripts/smoke_test.sh http://54.10.20.30 "$API_KEY"
set -uo pipefail

BASE="${1:?Informe a URL base (ex.: http://localhost:5000)}"
KEY="${2:?Informe a chave de API}"
BASE="${BASE%/}"
NAME="smoke-$(date +%s)-$RANDOM"
PASS=0
FAIL=0
BODY_FILE="$(mktemp)"
trap 'rm -f "$BODY_FILE"' EXIT

ok()   { printf '  [ OK ]  %-58s %s\n' "$1" "${2:-}"; PASS=$((PASS + 1)); }
fail() { printf '  [FALHA] %-58s %s\n' "$1" "${2:-}"; FAIL=$((FAIL + 1)); }

# check "descrição" <código esperado> <argumentos do curl...>
check() {
  local desc="$1" expected="$2"
  shift 2
  local code
  code="$(curl -s -o "$BODY_FILE" -w '%{http_code}' --max-time 15 "$@")" || code="000"
  if [ "$code" = "$expected" ]; then
    ok "$desc" "HTTP $code"
  else
    fail "$desc" "esperado $expected, recebido $code"
  fi
}

# o corpo da última resposta deve (ou não) conter um texto
body_has()  { if grep -q "$1" "$BODY_FILE"; then ok "$2"; else fail "$2"; fi; }
body_lacks() { if grep -q "$1" "$BODY_FILE"; then fail "$2"; else ok "$2"; fi; }

JSON=(-H 'Content-Type: application/json')
AUTH=(-H "X-API-Key: $KEY")

echo "ToggleMaster - teste de fumaça em $BASE (flag de teste: $NAME)"
echo "--- Saúde"
check "GET /health (liveness)" 200 "$BASE/health"
check "GET /ready (readiness, consulta o banco)" 200 "$BASE/ready"

echo "--- Autenticação nos endpoints de escrita"
check "POST /flags sem chave -> 401" 401 -X POST "${JSON[@]}" -d "{\"name\":\"$NAME\"}" "$BASE/flags"
check "POST /flags com chave errada -> 401" 401 -X POST "${JSON[@]}" -H 'X-API-Key: errada' -d "{\"name\":\"$NAME\"}" "$BASE/flags"
check "PUT /flags/<nome> sem chave -> 401" 401 -X PUT "${JSON[@]}" -d '{"is_enabled":true}' "$BASE/flags/$NAME"
check "DELETE /flags/<nome> sem chave -> 401" 401 -X DELETE "$BASE/flags/$NAME"

echo "--- Fluxo principal (CRUD)"
check "POST /flags criar -> 201" 201 -X POST "${JSON[@]}" "${AUTH[@]}" -d "{\"name\":\"$NAME\",\"is_enabled\":true}" "$BASE/flags"
check "POST /flags duplicada -> 409" 409 -X POST "${JSON[@]}" "${AUTH[@]}" -d "{\"name\":\"$NAME\"}" "$BASE/flags"
check "GET /flags listar -> 200" 200 "$BASE/flags"
body_has "$NAME" "Lista contém a flag criada"
check "GET /flags/<nome> consultar -> 200" 200 "$BASE/flags/$NAME"
check "PUT /flags/<nome> desativar -> 200" 200 -X PUT "${JSON[@]}" "${AUTH[@]}" -d '{"is_enabled":false}' "$BASE/flags/$NAME"
check "GET /flags/<nome> confirma desativada -> 200" 200 "$BASE/flags/$NAME"
body_has '"is_enabled":false' "is_enabled = false"

echo "--- Validações e erros (sem vazar detalhes internos)"
check "POST sem 'name' -> 400" 400 -X POST "${JSON[@]}" "${AUTH[@]}" -d '{"is_enabled":true}' "$BASE/flags"
LONG="$(printf 'x%.0s' $(seq 1 101))"
check "POST com 'name' > 100 caracteres -> 400" 400 -X POST "${JSON[@]}" "${AUTH[@]}" -d "{\"name\":\"$LONG\"}" "$BASE/flags"
body_lacks '"details"' "Resposta de erro não expõe 'details'"
check "POST com is_enabled não booleano -> 400" 400 -X POST "${JSON[@]}" "${AUTH[@]}" -d "{\"name\":\"$NAME-x\",\"is_enabled\":\"sim\"}" "$BASE/flags"
check "PUT com is_enabled não booleano -> 400" 400 -X PUT "${JSON[@]}" "${AUTH[@]}" -d '{"is_enabled":"false"}' "$BASE/flags/$NAME"
check "GET flag inexistente -> 404" 404 "$BASE/flags/nao-existe-$NAME"
check "GET /flags?limit=0 -> 400" 400 "$BASE/flags?limit=0"
check "GET /flags?limit=1&offset=0 (paginação) -> 200" 200 "$BASE/flags?limit=1&offset=0"

echo "--- Limpeza"
check "DELETE /flags/<nome> -> 200" 200 -X DELETE "${AUTH[@]}" "$BASE/flags/$NAME"
check "DELETE novamente -> 404" 404 -X DELETE "${AUTH[@]}" "$BASE/flags/$NAME"

echo
echo "Resultado: $PASS verificações OK, $FAIL falhas."
[ "$FAIL" -eq 0 ]
