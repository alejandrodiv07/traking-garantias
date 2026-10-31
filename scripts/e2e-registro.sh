#!/usr/bin/env bash
# Prueba de punta a punta de la fase 2a (spec §9), contra el Postgres de Docker.
# Un TECNICO registra la garantía de RT5-8842-AA (plazo 7) → la consulta por
# serial la muestra vigente → abre la orden con la auditoría de recepción →
# una revisión con golpes la deja ANULADA_POR_USO (atención de PAGO) → la
# revisión no se puede editar → el JEFE rechaza la orden (sin motivo falla,
# con motivo pasa) → la entrega sin reparar conserva el motivo → (fase 2b)
# una garantía TALLER pasa sola a EN_GARANTIA al importar la venta.
# Sale 1 ante CUALQUIER desvío.
set -euo pipefail
cd "$(dirname "$0")/.."

TECNICO='22222222-2222-2222-2222-222222222222'
JEFE='33333333-3333-3333-3333-333333333333'

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
# SEMILLA DE ACTORES: técnico y jefe con su segundo factor superado
# ---------------------------------------------------------------------
psql -v ON_ERROR_STOP=1 >/dev/null <<SQL
INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES
 ('$TECNICO','tecnico@primetelecom.com','{}'::jsonb),
 ('$JEFE','jefe@primetelecom.com','{}'::jsonb)
ON CONFLICT (id) DO NOTHING;
DO \$\$
BEGIN
  IF to_regclass('public.mfa_sesiones') IS NOT NULL THEN
    INSERT INTO public.mfa_sesiones (session_id, user_id)
    VALUES ('$TECNICO','$TECNICO'), ('$JEFE','$JEFE');
  END IF;
END \$\$;
UPDATE public.profiles SET role='JEFE_SERVICIO' WHERE id='$JEFE';
SQL

FALLOS=0
PASAN=0

chk() { # chk <nombre> <sql-booleano>
  if [ "$(psql -tA -c "SELECT CASE WHEN $2 THEN 'S' ELSE 'N' END" | tail -1)" = "S" ]; then
    PASAN=$((PASAN+1)); echo "PASA   $1"
  else
    FALLOS=$((FALLOS+1)); echo "*FALLA*  $1"
  fi
}

# como <uid> <sql>: ejecuta una sentencia con la identidad de un usuario
# interno (la RPC exige el rol del JWT). Devuelve 0 si la sentencia pasó.
como() {
  psql -v ON_ERROR_STOP=1 -tA >/dev/null 2>&1 <<SQL
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '$1';
SET LOCAL request.jwt.claim.session_id = '$1';
$2
COMMIT;
SQL
}

# 1) El titular y la garantía de la venta (plazo 7, factura de hoy)
CLIENTE=$(psql -tA -c "SELECT public.guardar_cliente('V','12345678','Juan Perez','04141234567','juan@ejemplo.com',NULL);")
PRODUCTO=$(psql -tA -c "SELECT id FROM public.productos WHERE modelo='HG8245';")

como "$TECNICO" "SELECT public.registrar_garantia('$CLIENTE','$PRODUCTO','RT5-8842-AA','FACTURA','F-2026-88', public.hoy_local(), 7);" \
  && chk "e1 el técnico registró la garantía (origen VENTA, sin orden)" \
    "(SELECT origen = 'VENTA' AND registrado_por = '$TECNICO' FROM public.equipos WHERE numero_serie='RT5-8842-AA')
     AND (SELECT count(*) = 0 FROM public.ordenes_servicio)" \
  || { FALLOS=$((FALLOS+1)); echo "*FALLA*  e1 registrar_garantia"; }

# 2) La Consulta por serial (y por factura) la muestra vigente
chk "e2 la consulta por serial: EN_GARANTIA, 7 días, compra CONFIRMADA" \
  "(SELECT vigencia::text = 'EN_GARANTIA' AND dias_restantes = 7 AND estado_compra = 'CONFIRMADA'
      FROM public.buscar_equipo(p_serial => 'rt5 8842 aa'))"
chk "e3 la consulta por factura halla el mismo equipo" \
  "(SELECT count(*) = 1 FROM public.buscar_equipo(p_factura => 'f-2026-88'))"
chk "e4 el tablero de garantías la lista con su titular" \
  "(SELECT titular = 'Juan Perez' AND vigencia::text = 'EN_GARANTIA' FROM public.v_garantias WHERE numero_serie='RT5-8842-AA')"

# 3) Abrir la orden con la auditoría de recepción en regla
EQUIPO=$(psql -tA -c "SELECT id FROM public.equipos WHERE numero_serie='RT5-8842-AA';")
como "$TECNICO" "SELECT public.abrir_orden('$EQUIPO','No enciende al conectar el transformador','cargador y manual',
  '{\"condiciones\":{\"factura_presentada\":true,\"titular_coincide\":true},
    \"equipo\":{\"serial_legible\":true,\"caja_original\":true,\"precintos_intactos\":true,\"contenido_completo\":true},
    \"senales\":{\"descarga_electrica\":false,\"liquidos\":false,\"altas_temperaturas\":false,\"golpes\":false,\"manipulacion_terceros\":false}}'::jsonb);" \
  || { FALLOS=$((FALLOS+1)); echo "*FALLA*  e5 abrir_orden"; }
ORDEN=$(psql -tA -c "SELECT id FROM public.ordenes_servicio LIMIT 1;")
chk "e5 la orden OS-AAAA-NNNN nace EN_GARANTIA / GARANTIA con su revisión de recepción" \
  "(SELECT numero_orden ~ '^OS-[0-9]{4}-[0-9]{4}\$' AND cobertura::text = 'EN_GARANTIA' AND tipo_atencion = 'GARANTIA'
      AND tecnico_asignado_id = '$TECNICO' FROM public.ordenes_servicio WHERE id='$ORDEN')
   AND (SELECT count(*) = 1 FROM public.revisiones WHERE orden_id='$ORDEN' AND tipo='RECEPCION')"
chk "e6 la orden aparece en v_tablero" \
  "(SELECT count(*) = 1 FROM public.v_tablero WHERE serial='RT5-8842-AA')"

# 4) Auditoría posterior con mal uso: golpes → ANULADA_POR_USO (atención de PAGO)
como "$TECNICO" "SELECT public.registrar_revision('$ORDEN','TECNICA',
  '{\"condiciones\":{\"factura_presentada\":true,\"titular_coincide\":true},
    \"equipo\":{\"serial_legible\":true,\"caja_original\":true,\"precintos_intactos\":true,\"contenido_completo\":true},
    \"senales\":{\"descarga_electrica\":false,\"liquidos\":false,\"altas_temperaturas\":false,\"golpes\":true,
               \"manipulacion_terceros\":false}}'::jsonb,
  'Equipo con golpes en la carcasa');" \
  || { FALLOS=$((FALLOS+1)); echo "*FALLA*  e7 registrar_revision"; }
chk "e7 la revisión con golpes dejó la orden ANULADA_POR_USO y de PAGO" \
  "(SELECT cobertura::text = 'ANULADA_POR_USO' AND tipo_atencion = 'PAGO' AND motivo_anulacion_cobertura ~ 'golpes'
      FROM public.ordenes_servicio WHERE id='$ORDEN')"

# 5) La revisión no se puede editar (solo de anexar)
if psql -c "UPDATE public.revisiones SET observaciones='falsificado' WHERE orden_id='$ORDEN';" >/dev/null 2>&1; then
  echo "*FALLA*  e8 el UPDATE de una revisión DEBE fallar (solo de anexar)"
  FALLOS=$((FALLOS+1))
else
  echo "PASA   e8 el UPDATE de una revisión está bloqueado"
  PASAN=$((PASAN+1))
fi

# 6) El estado solo cambia por la RPC; el rechazo exige motivo
if como "$TECNICO" "UPDATE public.ordenes_servicio SET estado='EN_DIAGNOSTICO' WHERE id='$ORDEN';"; then
  echo "*FALLA*  e9 el UPDATE directo del estado DEBE estar denegado"
  FALLOS=$((FALLOS+1))
else
  echo "PASA   e9 el UPDATE directo del estado está denegado"
  PASAN=$((PASAN+1))
fi
if como "$JEFE" "SELECT public.cambiar_estado('$ORDEN','RECHAZADO');"; then
  echo "*FALLA*  e10 rechazar SIN motivo DEBE fallar"
  FALLOS=$((FALLOS+1))
else
  echo "PASA   e10 rechazar sin motivo falla"
  PASAN=$((PASAN+1))
fi
como "$JEFE" "SELECT public.cambiar_estado('$ORDEN','RECHAZADO','Rechazada tras la auditoría','El equipo muestra golpes: la garantía no aplica');" \
  || { FALLOS=$((FALLOS+1)); echo "*FALLA*  e11 rechazar con motivo"; }
chk "e11 el JEFE rechazó con motivo y quedó en la orden y en la bitácora" \
  "(SELECT estado = 'RECHAZADO' AND motivo_rechazo ~ 'golpes' FROM public.ordenes_servicio WHERE id='$ORDEN')
   AND (SELECT count(*) = 1 FROM public.historial_ordenes WHERE orden_id='$ORDEN' AND estado_nuevo='RECHAZADO' AND comentario = 'Rechazada tras la auditoría')"

# 7) Devolución sin reparar: RECHAZADO → ENTREGADO conserva el motivo
como "$JEFE" "SELECT public.cambiar_estado('$ORDEN','ENTREGADO');" \
  || { FALLOS=$((FALLOS+1)); echo "*FALLA*  e12 entregar"; }
chk "e12 entregada: motivo intacto, fecha de entrega llena y fuera de lo abierto" \
  "(SELECT estado = 'ENTREGADO' AND fecha_entrega IS NOT NULL AND motivo_rechazo ~ 'golpes'
      FROM public.ordenes_servicio WHERE id='$ORDEN')
   AND (SELECT NOT abierto FROM public.v_tablero WHERE serial='RT5-8842-AA')"

# 8) Fase 2b: una garantía TALLER (factura sin confirmar) pasa sola a
#    EN_GARANTIA cuando el jefe importa la venta que la respalda.
como "$TECNICO" "SELECT public.registrar_garantia('$CLIENTE','$PRODUCTO','RT5-9000-BB','FACTURA','F-2026-90', public.hoy_local() - 3, 7, 'TALLER');"   || { FALLOS=$((FALLOS+1)); echo "*FALLA*  e13 registrar garantía TALLER"; }
chk "e13 la garantía TALLER nace POR_DETERMINAR, PENDIENTE y sin venta que la respalde"   "(SELECT vigencia::text = 'POR_DETERMINAR' AND estado_compra = 'PENDIENTE' FROM public.v_garantias WHERE numero_serie='RT5-9000-BB')"

FILA="jsonb_build_array(jsonb_build_object('numero_factura','F-2026-90','fecha_emision',to_char(public.hoy_local() - 3,'YYYY-MM-DD'),
  'tipo_documento','V','numero_documento','12345678','nombre_cliente','Juan Perez','serial','RT5-9000-BB','modelo','HG8245'))"
como "$JEFE" "SELECT * FROM public.importar_ventas('ventas.csv', $FILA);"   || { FALLOS=$((FALLOS+1)); echo "*FALLA*  e14 importar_ventas"; }
chk "e14 la importación confirmó la garantía sola (vía VENTAS) y quedó EN_GARANTIA"   "(SELECT vigencia::text = 'EN_GARANTIA' AND estado_compra = 'CONFIRMADA' AND compra_confirmada_via = 'VENTAS'
      FROM public.v_garantias WHERE numero_serie='RT5-9000-BB')"

como "$JEFE" "SELECT * FROM public.importar_ventas('ventas.csv', $FILA);"   || { FALLOS=$((FALLOS+1)); echo "*FALLA*  e15 reimportar"; }
chk "e15 reimportar es idempotente: sigue una sola fila de venta"   "(SELECT count(*) = 1 FROM public.ventas_facturas WHERE numero_serie = 'RT5-9000-BB')"

echo
echo "PASA $PASAN · FALLA $FALLOS"
if [ "$FALLOS" -gt 0 ] || [ "$PASAN" -eq 0 ]; then
  echo "HAY DESVÍOS"
  exit 1
fi
