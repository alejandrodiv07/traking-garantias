#!/usr/bin/env bash
# Prueba de punta a punta del Hito 1 (Tarea 22 del plan).
# Como un TECNICO: guardar_cliente → registrar_ingreso con RT5-8842-AA y
# plazo 7 → el registro aparece en v_tablero → registrar_revision con
# golpes=true → el registro queda ANULADA_POR_USO → el UPDATE de la
# revisión falla. Sale 1 ante CUALQUIER desvío.
set -euo pipefail
cd "$(dirname "$0")/.."

TECNICO='22222222-2222-2222-2222-222222222222'
ADMIN='11111111-1111-1111-1111-111111111111'

container=""
trap '[ -n "$container" ] && docker rm -f "$container" >/dev/null 2>&1 || true' EXIT

container=$(docker run --rm -d -e POSTGRES_PASSWORD=postgres postgres:17)
listo=false
for _ in $(seq 1 120); do
  if docker exec "$container" psql -U postgres -c "SELECT 1" >/dev/null 2>&1; then listo=true; break; fi
  sleep 1
done
[ "$listo" = true ] || { echo "Postgres no arrancó"; exit 1; }

psql() {
  docker exec -i "$container" psql -U postgres -d postgres "$@"
}

# Roles emulados de Supabase
psql -q <<'SQL' >/dev/null
CREATE ROLE anon NOLOGIN;
CREATE ROLE authenticated NOLOGIN;
CREATE ROLE service_role NOLOGIN BYPASSRLS;
SQL

# Harness + migraciones + seed (cortes estrictos), como el ejecutor.
for f in supabase/tests/00_harness_supabase_local.sql supabase/migrations/*.sql supabase/seed.sql; do
  case "$(basename "$f")" in _*) continue ;; esac
  psql -v ON_ERROR_STOP=1 -f - < "$f" >/dev/null || { echo "FALLA aplicar $f"; exit 1; }
done

# ---------------------------------------------------------------------
# SEMILLA DEL ACTOR: el técnico con su segundo factor superado
# ---------------------------------------------------------------------
psql -v ON_ERROR_STOP=1 >/dev/null <<SQL
INSERT INTO auth.users (id, email, raw_user_meta_data)
VALUES ('$TECNICO','tecnico@primetelecom.com','{}'::jsonb)
ON CONFLICT (id) DO NOTHING;
DO \$\$
BEGIN
  IF to_regclass('public.mfa_sesiones') IS NOT NULL THEN
    INSERT INTO public.mfa_sesiones (session_id, user_id)
    VALUES ('$TECNICO','$TECNICO');
  END IF;
END \$\$;
SQL

# ---------------------------------------------------------------------
# EL FLUJO COMO TECNICO
# ---------------------------------------------------------------------
FALLOS=0
PASAN=0

chk() { # chk <nombre> <sql-booleano>
  if [ "$(psql -tA -c "SELECT CASE WHEN $2 THEN 'S' ELSE 'N' END" | tail -1)" = "S" ]; then
    PASAN=$((PASAN+1)); echo "PASA   $1"
  else
    FALLOS=$((FALLOS+1)); echo "*FALLA*  $1"
  fi
}

# 1) guardar_cliente
CLIENTE=$(psql -tA -c "SELECT public.guardar_cliente('V','12345678','Juan Perez',NULL,NULL,NULL);")

# 2) registrar_ingreso con RT5-8842-AA y plazo 7: factura de HOY, vence en 7
#    (corre como el técnico: la RPC exige el rol del JWT)
INGRESO=$(psql -tA <<SQL
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '$TECNICO';
SET LOCAL request.jwt.claim.session_id = '$TECNICO';
SELECT 'RES' AS marca, i.registro_id, i.numero_registro, i.consulta_token, i.cobertura
FROM (SELECT * FROM public.registrar_ingreso(
    'RT5-8842-AA',
    (SELECT id FROM public.productos WHERE modelo='HG8245'),
    '$CLIENTE',
    'No enciende al conectar el transformador',
    'cargador y manual',
    'FACTURA', 'F-2026-88', public.hoy_local(), 7, 'Tienda Prime', NULL, NULL,
    now())) i;
COMMIT;
SQL
)
REGISTRO=$(printf '%s\n' "$INGRESO" | awk -F'|' '/^RES\|/{print $2}')
NUMREG=$(printf '%s\n' "$INGRESO" | awk -F'|' '/^RES\|/{print $3}')
TOKEN=$(printf '%s\n' "$INGRESO" | awk -F'|' '/^RES\|/{print $4}')

chk "e1 el ingreso creó el registro con código legible" \
  "((SELECT numero_registro = '$NUMREG' AND numero_registro ~ '^REG-[0-9]{4}-[0-9]{6}\$' FROM public.registros WHERE id='$REGISTRO') IS TRUE)"
chk "e2 el hash guardado corresponde al token (que no está en claro)" \
  "((SELECT encode(consulta_token_hash,'hex') = encode(extensions.digest('$TOKEN','sha256'),'hex') FROM public.registros WHERE id='$REGISTRO') IS TRUE)"
chk "e3 hay revisión de recepción para el registro" \
  "(SELECT count(*)=1 FROM public.revisiones WHERE registro_id='$REGISTRO' AND tipo='RECEPCION')"
chk "e4 el técnico que registró quedó asignado" \
  "(SELECT tecnico_asignado_id='$TECNICO' FROM public.registros WHERE id='$REGISTRO')"

# 3) v_tablero lo muestra: la fila existe con el serial y su vencimiento
chk "e5 el registro aparece en v_tablero (RT5-8842-AA)" \
  "(SELECT count(*)=1 FROM public.v_tablero WHERE serial='RT5-8842-AA')"
chk "e6 v_tablero lo muestra con SUS 7 días de vigencia futuros" \
  "(SELECT dias_restantes = 7 FROM public.v_tablero WHERE serial='RT5-8842-AA')"

# 4) registrar_revision golpes=true → ANULADA_POR_USO
psql -tA >/dev/null <<SQL
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '$TECNICO';
SET LOCAL request.jwt.claim.session_id = '$TECNICO';
SELECT public.registrar_revision('$REGISTRO','TECNICA',
  '{"condiciones":{"factura_presentada":true,"titular_coincide":true},
    "equipo":{"serial_legible":true,"caja_original":true,"precintos_intactos":true,"contenido_completo":true},
    "senales":{"descarga_electrica":false,"liquidos":false,"altas_temperaturas":false,"golpes":true,
               "manipulacion_terceros":false}}'::jsonb,
  'Equipo con golpes en la carcasa');
COMMIT;
SQL
chk "e7 la revisión con golpes dejó el registro ANULADA_POR_USO" \
  "(SELECT cobertura::text='ANULADA_POR_USO' FROM public.registros WHERE id='$REGISTRO')"
chk "e8 el motivo de anulación menciona golpes" \
  "(SELECT motivo_anulacion_cobertura ~ 'golpes' FROM public.registros WHERE id='$REGISTRO')"

# 5) la revisión no se puede editar (solo de anexar)
if psql -c "UPDATE public.revisiones SET observaciones='falsificado' WHERE registro_id='$REGISTRO';" >/dev/null 2>&1; then
  echo "*FALLA*  e9 el UPDATE de una revisión DEBE fallar (solo de anexar)"
  FALLOS=$((FALLOS+1))
else
  echo "PASA   e9 el UPDATE de una revisión está bloqueado"
  PASAN=$((PASAN+1))
fi

echo
echo "PASA $PASAN · FALLA $FALLOS"
if [ "$FALLOS" -gt 0 ] || [ "$PASAN" -eq 0 ]; then
  echo "HAY DESVÍOS"
  exit 1
fi
echo "PUNTA A PUNTA COMPLETO"