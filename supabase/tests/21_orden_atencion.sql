-- Prueba de la migración 0015 (Tarea 5 de la fase 2a; spec §4.3 y §4.6):
-- `tipo_atencion` GENERADA de la cobertura, el `motivo_rechazo` que persiste
-- y la bitácora de eventos (BITACORA) en `historial_ordenes`.
-- Las órdenes se crean SIEMPRE vía `abrir_orden` (RPC); las revisiones
-- posteriores van como INSERT directo (superuser) con checklist, como
-- `14_revisiones.sql`: el trigger de revisiones escribe la cobertura y la
-- columna generada `tipo_atencion` la sigue sola.
\set QUIET on
CREATE OR REPLACE FUNCTION pg_temp.chk(n text, c boolean) RETURNS void
LANGUAGE plpgsql AS $$ BEGIN RAISE NOTICE '%  %', CASE WHEN c THEN 'PASA  ' ELSE '*FALLA*' END, n; END $$;

-- Mensaje de error de una sentencia bajo una identidad (o postgres si uid NULL)
CREATE FUNCTION pg_temp.mensaje(uid text, sql text) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE
BEGIN
  IF uid IS NOT NULL THEN
    PERFORM set_config('request.jwt.claim.sub', uid, TRUE);
    PERFORM set_config('request.jwt.claim.session_id', uid, TRUE);
    EXECUTE 'SET LOCAL ROLE authenticated';
  END IF;
  BEGIN
    EXECUTE sql;
    IF uid IS NOT NULL THEN EXECUTE 'RESET ROLE'; END IF;
    RETURN NULL;   -- la sentencia que debía fallar, no falló
  EXCEPTION WHEN OTHERS THEN
    IF uid IS NOT NULL THEN EXECUTE 'RESET ROLE'; END IF;
    RETURN SQLERRM;
  END;
END $$;
\set QUIET off

-- Semillas
INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES
 ('11111111-1111-1111-1111-111111111111','admin@primetelecom.com','{"full_name":"Ada"}'::jsonb),
 ('22222222-2222-2222-2222-222222222222','tecnico@primetelecom.com','{"full_name":"Tito"}'::jsonb);
DO $$
BEGIN
  IF to_regclass('public.mfa_sesiones') IS NOT NULL THEN
    INSERT INTO public.mfa_sesiones (session_id, user_id)
    VALUES ('11111111-1111-1111-1111-111111111111','11111111-1111-1111-1111-111111111111'),
           ('22222222-2222-2222-2222-222222222222','22222222-2222-2222-2222-222222222222');
  END IF;
END $$;
INSERT INTO public.clientes (tipo_documento, documento, nombre)
VALUES ('V','12345678','Juan Perez');

CREATE FUNCTION pg_temp.producto_id() RETURNS uuid LANGUAGE sql AS
  $$ SELECT id FROM public.productos WHERE modelo='HG8245' $$;
CREATE FUNCTION pg_temp.cliente_id() RETURNS uuid LANGUAGE sql AS
  $$ SELECT id FROM public.clientes LIMIT 1 $$;
CREATE FUNCTION pg_temp.orden_id() RETURNS uuid LANGUAGE sql AS
  $$ SELECT id FROM public.ordenes_servicio ORDER BY fecha_ingreso LIMIT 1 $$;
CREATE FUNCTION pg_temp.checklist_ok() RETURNS jsonb LANGUAGE sql AS $$
  SELECT '{"condiciones":{"factura_presentada":true,"titular_coincide":true},
           "equipo":{"serial_legible":true,"caja_original":true,"precintos_intactos":true,"contenido_completo":true},
           "senales":{"descarga_electrica":false,"liquidos":false,"altas_temperaturas":false,"golpes":false,"manipulacion_terceros":false}}'::jsonb $$;
CREATE FUNCTION pg_temp.checklist_golpes() RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_set(pg_temp.checklist_ok(), '{senales,golpes}', 'true') $$;
-- Checklist completo pero con la factura sin presentar: la condición
-- incumplida manda la cobertura a POR_DETERMINAR (precedencia §4.2).
CREATE FUNCTION pg_temp.checklist_sin_factura() RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_set(pg_temp.checklist_ok(), '{condiciones,factura_presentada}', 'false') $$;

-- La orden nace SIEMPRE por la RPC: equipo con factura vigente
-- (emisión HOY + 365 días) y su revisión de RECEPCION con checklist bueno
-- → cobertura EN_GARANTIA.
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
SET LOCAL request.jwt.claim.session_id = '22222222-2222-2222-2222-222222222222';
CREATE TEMP TABLE t_orden AS
SELECT * FROM public.abrir_orden(
    'OA-001', pg_temp.producto_id(), pg_temp.cliente_id(),
    'No enciende, huele a quemado', NULL,
    'FACTURA', 'F-OA', CURRENT_DATE, 365, NULL,
    pg_temp.checklist_ok(), NULL);
COMMIT;
RESET ROLE;

-- ============ tipo_atencion: la columna generada de la cobertura (§4.3) ============
SELECT pg_temp.chk('A1 la orden en garantía lleva tipo_atencion GARANTIA',
  (SELECT tipo_atencion = 'GARANTIA'
     FROM public.ordenes_servicio WHERE id = pg_temp.orden_id()));

-- La revisión con señales de uso anula la cobertura; la generada sigue sola.
INSERT INTO public.revisiones (orden_id, tipo, revisado_por, checklist)
VALUES (pg_temp.orden_id(), 'TECNICA', '22222222-2222-2222-2222-222222222222',
        pg_temp.checklist_golpes());
SELECT pg_temp.chk('A2 cobertura ANULADA_POR_USO (señales de uso) → tipo_atencion PAGO',
  (SELECT cobertura = 'ANULADA_POR_USO' AND tipo_atencion = 'PAGO'
     FROM public.ordenes_servicio WHERE id = pg_temp.orden_id()));

-- Revisión con condición incumplida: la cobertura vuelve a POR_DETERMINAR.
INSERT INTO public.revisiones (orden_id, tipo, revisado_por, checklist)
VALUES (pg_temp.orden_id(), 'TECNICA', '22222222-2222-2222-2222-222222222222',
        pg_temp.checklist_sin_factura());
SELECT pg_temp.chk('A3 cobertura POR_DETERMINAR → tipo_atencion PENDIENTE',
  (SELECT cobertura = 'POR_DETERMINAR' AND tipo_atencion = 'PENDIENTE'
     FROM public.ordenes_servicio WHERE id = pg_temp.orden_id()));

-- ============ motivo_rechazo persiste (§5.2; A4) ============
-- El estado RECHAZADO llega con la 0016; hoy cualquiera puede escribir el
-- motivo (el CHECK ck_rechazo_motivado no exige nada si estado <> RECHAZADO).
UPDATE public.ordenes_servicio
   SET motivo_rechazo = 'Rechazado por manipulación posterior del equipo'
 WHERE id = pg_temp.orden_id();
SELECT pg_temp.chk('A4a escribir el motivo con la orden abierta es aceptado',
  (SELECT motivo_rechazo = 'Rechazado por manipulación posterior del equipo'
     FROM public.ordenes_servicio WHERE id = pg_temp.orden_id()));

SELECT pg_temp.chk('A4b limpiar el motivo de una fila que lo tiene rechazado',
  pg_temp.mensaje(NULL,
    $$UPDATE public.ordenes_servicio SET motivo_rechazo = NULL
       WHERE id = pg_temp.orden_id()$$) ~ 'no se puede alterar');
SELECT pg_temp.chk('A4c cambiar el motivo por otro también rechazado',
  pg_temp.mensaje(NULL,
    $$UPDATE public.ordenes_servicio SET motivo_rechazo = 'Otra causa inventada'
       WHERE id = pg_temp.orden_id()$$) ~ 'no se puede alterar');
-- Tras los intentos fallidos el motivo queda intacto.
SELECT pg_temp.chk('A4d el motivo sigue en la fila tras los rechazos',
  (SELECT motivo_rechazo = 'Rechazado por manipulación posterior del equipo'
     FROM public.ordenes_servicio WHERE id = pg_temp.orden_id()));

-- ============ Bitácora de eventos (§4.3 del plan; A5/A6) ============
-- Fila BITACORA por INSERT directo (superuser): sin cambio de estado.
INSERT INTO public.historial_ordenes
    (orden_id, estado_anterior, estado_nuevo, evento, comentario)
SELECT pg_temp.orden_id(), NULL, o.estado, 'BITACORA', 'Nota manual de la bitácora de prueba'
  FROM public.ordenes_servicio o WHERE o.id = pg_temp.orden_id();
SELECT pg_temp.chk('A5 la fila BITACORA directa (estado_nuevo = estado actual) es aceptada',
  (SELECT count(*) = 1 FROM public.historial_ordenes
   WHERE orden_id = pg_temp.orden_id() AND evento = 'BITACORA'
     AND comentario = 'Nota manual de la bitácora de prueba'));

-- La guardia combinada: una BITACORA cuyo estado_nuevo NO es el estado
-- actual de la orden está mintiendo: rechazada por ck_historial_evento.
SELECT pg_temp.chk('A6a BITACORA con estado_nuevo distinto del actual rechazada',
  pg_temp.mensaje(NULL,
    $$INSERT INTO public.historial_ordenes
        (orden_id, evento, comentario, estado_nuevo)
      SELECT id, 'BITACORA', 'Comentario con estado mentiroso', 'ANULADO'
        FROM public.ordenes_servicio WHERE id = pg_temp.orden_id()$$)
    ~ 'ck_historial_evento');
-- Y sin comentario no hay anotación: rechazada por el CHECK propio.
SELECT pg_temp.chk('A6b BITACORA sin comentario rechazada',
  pg_temp.mensaje(NULL,
    $$INSERT INTO public.historial_ordenes
        (orden_id, evento, estado_nuevo)
      SELECT id, 'BITACORA', estado
        FROM public.ordenes_servicio WHERE id = pg_temp.orden_id()$$)
    ~ 'ck_historial_bitacora_con_comentario');
-- Tras los dos rechazos sigue habiendo UNA sola BITACORA manual.
SELECT pg_temp.chk('A6c el rechazo no dejó filas',
  (SELECT count(*) = 1 FROM public.historial_ordenes
   WHERE orden_id = pg_temp.orden_id() AND evento = 'BITACORA'
     AND comentario = 'Nota manual de la bitácora de prueba'));

-- ============ El trigger de eventos anota la cobertura (A7) ============
-- Camino de la orden hasta EN_REPARACION (transiciones válidas) y luego un
-- UPDATE de cobertura DIRECTO: el trigger debe dejar la fila BITACORA nueva.
UPDATE public.ordenes_servicio SET estado='EN_DIAGNOSTICO' WHERE id = pg_temp.orden_id();
UPDATE public.ordenes_servicio SET estado='EN_REPARACION'  WHERE id = pg_temp.orden_id();
UPDATE public.ordenes_servicio
   SET cobertura = 'EN_GARANTIA', motivo_anulacion_cobertura = NULL
 WHERE id = pg_temp.orden_id();
SELECT pg_temp.chk('A7 el UPDATE de cobertura con la orden en EN_REPARACION deja la fila BITACORA',
  (SELECT count(*) = 1 FROM public.historial_ordenes
   WHERE orden_id = pg_temp.orden_id() AND evento = 'BITACORA'
     AND comentario = 'La cobertura cambió a EN_GARANTIA con la orden en EN_REPARACION'
     AND estado_anterior IS NULL AND estado_nuevo = 'EN_REPARACION'));

-- El disparo en seco no anota: UPDATE sin cambio de valor NO deja BITACORA
-- (la apertura por RPC ya dejó una con 'a EN_GARANTIA'; se cuenta por el
-- comentario COMPLETO para que solo la fila de A7 matchee).
UPDATE public.ordenes_servicio SET cobertura = 'EN_GARANTIA' WHERE id = pg_temp.orden_id();
SELECT pg_temp.chk('A8 UPDATE que no cambia el valor no anota BITACORA',
  (SELECT count(*) = 1 FROM public.historial_ordenes
   WHERE orden_id = pg_temp.orden_id()
     AND comentario = 'La cobertura cambió a EN_GARANTIA con la orden en EN_REPARACION'));