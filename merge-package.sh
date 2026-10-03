#!/usr/bin/env bash
# Uso: bash merge-package.sh <zip-original> <zip-de-atualizacao> <zip-de-saida>
# Ex.:  bash merge-package.sh toggle-master-etapa2.ORIGINAL.zip toggle-master-etapa2-aws-update.zip toggle-master-etapa2.zip
set -euo pipefail
ORIG="${1:?zip original}"; UPD="${2:?zip de atualizacao}"; OUT="${3:?zip de saida}"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
unzip -q -o "$ORIG" -d "$WORK"
unzip -q -o "$UPD" -d "$WORK"
( cd "$WORK" && zip -qr "$OLDPWD/$OUT" toggle-master-etapa2 )
echo "Gerado: $OUT"
unzip -l "$OUT" | tail -n +4 | head -40
