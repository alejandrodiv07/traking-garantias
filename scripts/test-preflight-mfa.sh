#!/usr/bin/env bash
#
# Test de integración del preflight CORS de `mfa-enviar-codigo`.
#
# Reproduce el preflight EXACTO que hace un navegador cuando
# `supabase.functions.invoke` llama a la función: pide permiso para TODAS
# las cabeceras que supabase-js envía — authorization, content-type,
# apikey, x-client-info (del propio paquete) Y x-application-name (header
# global configurado en supabaseClient.js). Si la respuesta no las permite
# todas, el navegador bloquea el POST real y la UI ve un "CORS error"
# aunque el preflight devuelva 200 (bugs del 29-30/10/2026).
#
# Uso:
#   bash scripts/test-preflight-mfa.sh [BASE_URL]
#     BASE_URL por defecto: la URL de producción de la función
#     (también acepta http://127.0.0.1:54321/... con `supabase functions serve`)
#
set -euo pipefail

ORIGEN="${ORIGEN:-http://localhost:5173}"
BASE_URL="${1:-https://przkjfyatficximekvow.supabase.co/functions/v1/mfa-enviar-codigo}"

CABECERAS_NECESARIAS="authorization content-type apikey x-client-info x-application-name"

fallas=0

# ── Caso 1: el preflight del navegador debe permitir TODAS las cabeceras ──
echo "· Preflight del navegador (Origin: $ORIGEN) contra $BASE_URL"
RESP=$(curl -s -D - -o /dev/null -X OPTIONS "$BASE_URL" \
  -H "Origin: $ORIGEN" \
  -H "Access-Control-Request-Method: POST" \
  -H "Access-Control-Request-Headers: authorization, content-type, apikey, x-client-info, x-application-name" \
  --max-time 30)

peticion="authorization, content-type, apikey, x-client-info"
for cabecera in $CABECERAS_NECESARIAS; do
  # La respuesta puede listar las cabeceras en cualquier orden y con
  # mayúsculas distintas: se compara sin distinción de mayúsculas.
  permitidas=$(printf '%s' "$RESP" | grep -i '^access-control-allow-headers:' | head -1)
  if printf '%s' "$permitidas" | grep -qi "$cabecera"; then
    echo "  ✓ permite $cabecera"
  else
    echo "  ✗ NO permite $cabecera (el navegador bloquearía el POST)"
    echo "    respondió: $permitidas"
    fallas=$((fallas + 1))
  fi
done

acao=$(printf '%s' "$RESP" | grep -i '^access-control-allow-origin:' | head -1)
if printf '%s' "$acao" | grep -qi "$(printf '%s' "$ORIGEN" | sed 's/:/\\:/g')"; then
  echo "  ✓ ACAO ecos del origen"
else
  echo "  ✗ ACAO no coincide con el origen: respondió '$acao'"
  fallas=$((fallas + 1))
fi

acam=$(printf '%s' "$RESP" | grep -i '^access-control-allow-methods:' | head -1) || true
if printf '%s' "$acam" | grep -qi 'POST' && printf '%s' "$acam" | grep -qi 'OPTIONS'; then
  echo "  ✓ ACAM incluye POST y OPTIONS"
else
  echo "  ✗ ACAM incompleto: respondió '$acam'"
  fallas=$((fallas + 1))
fi

# ── Caso 2: un rechazo DE LA FUNCIÓN (401 con bearer sin sub) también ──
#    debe salir con cabeceras CORS: es la respuesta que el navegador lee
#    en el flujo real cuando el token llega vencido.
echo "· POST con bearer sin sub (401 de la propia función)"
RESP2=$(curl -s -D - -o /dev/null -X POST "$BASE_URL" \
  -H "Origin: $ORIGEN" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer token-falso-para-401" \
  --max-time 30)

if printf '%s' "$RESP2" | grep -qi '^access-control-allow-origin:'; then
  echo "  ✓ 401 lleva ACAO"
else
  echo "  ✗ 401 sin ACAO (el navegador no podría leer el rechazo)"
  fallas=$((fallas + 1))
fi

if [ "$fallas" -eq 0 ]; then
  echo "OK — preflight y respuestas de error cumplen CORS"
  exit 0
else
  echo "FALLO — $fallas comprobación(es) incumplida(s)"
  exit 1
fi