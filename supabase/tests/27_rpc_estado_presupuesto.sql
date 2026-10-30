-- Prueba de cambiar_estado, asignar_tecnico y registrar_presupuesto
-- (Tarea 11 de la fase 2a; spec §4.4, §4.5, §6 y §7; migración 0021).
-- OJO con el orden de evaluación: el AND de SQL no lo garantiza, así que
-- cada llamada que cambia datos va en su propia aserción.
\set QUIET on
CREATE OR REPLACE FUNCTION pg_temp.chk(n text, c boolean) RETURNS void
LANGUAGE plpgsql AS $$ BEGIN RAISE NOTICE '%  %', CASE WHEN c THEN 'PASA  ' ELSE '*FALLA*' END, n; END $$;

CREATE FUNCTION pg_temp.mensaje(uid text, sql text) RETURNS text
LANGUAGE plpgsql AS $$
BEGIN
  IF uid = 'anon' THEN
    EXECUTE 'SET LOCAL ROLE anon';
  ELSIF uid IS NOT NULL THEN
    PERFORM set_config('request.jwt.claim.sub', uid, TRUE);
    PERFORM set_config('request.jwt.claim.session_id', uid, TRUE);
    EXECUTE 'SET LOCAL ROLE authenticated';
  END IF;
  BEGIN
    EXECUTE sql;
    IF uid IS NOT NULL THEN EXECUTE 'RESET ROLE'; END IF;
    RETURN NULL;
  EXCEPTION WHEN OTHERS THEN
    IF uid IS NOT NULL THEN EXECUTE 'RESET ROLE'; END IF;
    RETURN SQLERRM;
  END;
END $$;

CREATE FUNCTION pg_temp.producto_id() RETURNS uuid LANGUAGE sql AS
  $$ SELECT id FROM public.productos WHERE modelo='HG8245' $$;
CREATE FUNCTION pg_temp.eq(n text) RETURNS uuid LANGUAGE sql AS
  $$ SELECT id FROM public.equipos WHERE numero_serie = n $$;
CREATE FUNCTION pg_temp.ord(n text) RETURNS uuid LANGUAGE sql AS
  $$ SELECT id FROM public.ordenes_servicio WHERE equipo_id = pg_temp.eq(n) $$;
CREATE FUNCTION pg_temp.checklist_ok() RETURNS jsonb LANGUAGE sql AS $$
  SELECT '{"condiciones":{"factura_presentada":true,"titular_coincide":true},
           "equipo":{"serial_legible":true,"caja_original":true,"precintos_intactos":true,"contenido_completo":true},
           "senales":{"descarga_electrica":false,"liquidos":false,"altas_temperaturas":false,"golpes":false,"manipulacion_terceros":false}}'::jsonb $$;
-- Cambia el estado de la orden del equipo `n` bajo la identidad `uid`.
CREATE FUNCTION pg_temp.paso(uid text, n text, estado text, comentario text DEFAULT NULL, motivo text DEFAULT NULL)
RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.mensaje(uid, format('SELECT public.cambiar_estado(%L, %L, %L, %L)',
                                     pg_temp.ord(n), estado, comentario, motivo)) $$;
CREATE FUNCTION pg_temp.presupuesto(uid text, n text, monto numeric) RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.mensaje(uid, format('SELECT public.registrar_presupuesto(%L, %L)', pg_temp.ord(n), monto)) $$;
CREATE FUNCTION pg_temp.adjunto(n text, tipo text, nombre text) RETURNS void LANGUAGE sql AS $$
  INSERT INTO public.adjuntos (orden_id, tipo, etiqueta, ruta, mime, bytes)
  VALUES (pg_temp.ord(n), tipo, 'prueba', 'ordenes/' || pg_temp.ord(n) || '/' || nombre, 'image/png', 1024) $$;
\set QUIET off

INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES
 ('11111111-1111-1111-1111-111111111111','admin@primetelecom.com','{"full_name":"Ada"}'::jsonb),
 ('22222222-2222-2222-2222-222222222222','tecnico@primetelecom.com','{"full_name":"Tito"}'::jsonb),
 ('33333333-3333-3333-3333-333333333333','jefe@primetelecom.com','{"full_name":"Jefe"}'::jsonb),
 ('55555555-5555-5555-5555-555555555555','recepcion@primetelecom.com','{"full_name":"Rita"}'::jsonb),
 ('66666666-6666-6666-6666-666666666666','tecnico2@primetelecom.com','{"full_name":"Tomas"}'::jsonb);
DO $$
BEGIN
  IF to_regclass('public.mfa_sesiones') IS NOT NULL THEN
    INSERT INTO public.mfa_sesiones (session_id, user_id)
    SELECT p.id, p.id FROM public.profiles p ON CONFLICT (session_id) DO NOTHING;
  END IF;
END $$;
UPDATE public.profiles SET role='ADMIN'         WHERE email='admin@primetelecom.com';
UPDATE public.profiles SET role='JEFE_SERVICIO' WHERE email='jefe@primetelecom.com';
UPDATE public.profiles SET role='RECEPCION'     WHERE email='recepcion@primetelecom.com';

INSERT INTO public.clientes (tipo_documento, documento, nombre) VALUES ('V','12345678','Juan Perez');
-- EQ-G: en garantía · EQ-P: factura vencida (pago) · EQ-T: de taller sin confirmar (pendiente)
INSERT INTO public.equipos (numero_serie, producto_id, cliente_id, tipo_soporte, numero_soporte, fecha_emision, plazo_dias)
SELECT 'EQ-G', pg_temp.producto_id(), id, 'FACTURA', 'F-G', public.hoy_local() - 1, 15 FROM public.clientes;
INSERT INTO public.equipos (numero_serie, producto_id, cliente_id, tipo_soporte, numero_soporte, fecha_emision, plazo_dias)
SELECT 'EQ-P', pg_temp.producto_id(), id, 'FACTURA', 'F-P', public.hoy_local() - 30, 7 FROM public.clientes;
INSERT INTO public.equipos (numero_serie, producto_id, cliente_id, tipo_soporte, numero_soporte, fecha_emision, plazo_dias, origen)
SELECT 'EQ-T', pg_temp.producto_id(), id, 'FACTURA', 'F-T', public.hoy_local() - 1, 15, 'TALLER' FROM public.clientes;

-- Las tres órdenes las abre el TECNICO (queda asignado).
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
SET LOCAL request.jwt.claim.session_id = '22222222-2222-2222-2222-222222222222';
SELECT public.abrir_orden(pg_temp.eq(s), 'No enciende el equipo', NULL, pg_temp.checklist_ok())
  FROM unnest(ARRAY['EQ-G','EQ-P','EQ-T']) s;
COMMIT;
RESET ROLE;

-- ============ S1-S2: reglas de avance por la RPC (equipo de TALLER sin confirmar) ============
SELECT pg_temp.chk('S1 EN_DIAGNOSTICO sin foto rechazado',
  pg_temp.paso('22222222-2222-2222-2222-222222222222', 'EQ-T', 'EN_DIAGNOSTICO') ~ 'foto');
SELECT pg_temp.adjunto('EQ-T', 'FOTO', 'foto-1.png');
SELECT pg_temp.chk('S1b con foto pero sin el documento presentado, rechazado',
  pg_temp.paso('22222222-2222-2222-2222-222222222222', 'EQ-T', 'EN_DIAGNOSTICO') ~ 'documento');
SELECT pg_temp.adjunto('EQ-T', 'DOCUMENTO', 'factura-1.png');
SELECT pg_temp.chk('S1c con foto y documento avanza',
  pg_temp.paso('22222222-2222-2222-2222-222222222222', 'EQ-T', 'EN_DIAGNOSTICO') IS NULL);
SELECT pg_temp.chk('S2 una atención PENDIENTE no pasa a EN_REPARACION hasta resolver la cobertura',
  pg_temp.paso('22222222-2222-2222-2222-222222222222', 'EQ-T', 'EN_REPARACION') IS NOT NULL
  AND (SELECT estado FROM public.ordenes_servicio WHERE id = pg_temp.ord('EQ-T')) = 'EN_DIAGNOSTICO');

-- ============ S3: presupuesto ============
SELECT pg_temp.chk('S3 presupuestar una GARANTIA rechazado',
  pg_temp.presupuesto('22222222-2222-2222-2222-222222222222', 'EQ-G', 50) ~ 'servicio pago');
SELECT pg_temp.chk('S3b presupuestar una atención PENDIENTE rechazado',
  pg_temp.presupuesto('22222222-2222-2222-2222-222222222222', 'EQ-T', 50) ~ 'servicio pago');
SELECT pg_temp.chk('S3c monto negativo rechazado',
  pg_temp.presupuesto('22222222-2222-2222-2222-222222222222', 'EQ-P', -1) ~ 'monto');
SELECT pg_temp.chk('S3d RECEPCION no registra presupuesto (42501)',
  pg_temp.presupuesto('55555555-5555-5555-5555-555555555555', 'EQ-P', 80) ~ 'no puede');
SELECT pg_temp.chk('S3e un TECNICO no asignado a la orden no registra presupuesto',
  pg_temp.presupuesto('66666666-6666-6666-6666-666666666666', 'EQ-P', 80) ~ 'asignado');

-- ============ S4: flujo PAGO completo por RPC ============
SELECT pg_temp.adjunto('EQ-P', 'FOTO', 'foto-1.png');
SELECT pg_temp.chk('S4a PAGO: RECIBIDO → EN_DIAGNOSTICO',
  pg_temp.paso('22222222-2222-2222-2222-222222222222', 'EQ-P', 'EN_DIAGNOSTICO') IS NULL);
SELECT pg_temp.chk('S4b PAGO: EN_DIAGNOSTICO → PRESUPUESTADO sin monto rechazado',
  pg_temp.paso('22222222-2222-2222-2222-222222222222', 'EQ-P', 'PRESUPUESTADO') ~ 'monto');
SELECT pg_temp.chk('S4c PAGO: EN_DIAGNOSTICO → EN_REPARACION directo rechazado (debe presupuestar)',
  pg_temp.paso('22222222-2222-2222-2222-222222222222', 'EQ-P', 'EN_REPARACION') ~ 'PRESUPUESTADO');
SELECT pg_temp.chk('S4d el técnico asignado registra el presupuesto',
  pg_temp.presupuesto('22222222-2222-2222-2222-222222222222', 'EQ-P', 120.50) IS NULL);
SELECT pg_temp.chk('S4e el monto quedó en la orden',
  (SELECT costo_reparacion = 120.50 FROM public.ordenes_servicio WHERE id = pg_temp.ord('EQ-P')));
SELECT pg_temp.chk('S4f PAGO: → PRESUPUESTADO',
  pg_temp.paso('22222222-2222-2222-2222-222222222222', 'EQ-P', 'PRESUPUESTADO') IS NULL);
SELECT pg_temp.chk('S4g RECEPCION registra la decisión del cliente: PRESUPUESTADO → EN_REPARACION',
  pg_temp.paso('55555555-5555-5555-5555-555555555555', 'EQ-P', 'EN_REPARACION', 'Cliente aceptó por teléfono') IS NULL);
SELECT pg_temp.chk('S4h el comentario llega a la bitácora del cambio de estado',
  (SELECT count(*) = 1 FROM public.historial_ordenes
    WHERE orden_id = pg_temp.ord('EQ-P') AND estado_nuevo = 'EN_REPARACION'
      AND comentario = 'Cliente aceptó por teléfono'));
SELECT pg_temp.chk('S4i RECEPCION no avanza la reparación (42501)',
  pg_temp.paso('55555555-5555-5555-5555-555555555555', 'EQ-P', 'REPARADO') ~ 'no puede');
SELECT pg_temp.chk('S4j el técnico repara',
  pg_temp.paso('22222222-2222-2222-2222-222222222222', 'EQ-P', 'REPARADO') IS NULL);
SELECT pg_temp.chk('S4k RECEPCION entrega',
  pg_temp.paso('55555555-5555-5555-5555-555555555555', 'EQ-P', 'ENTREGADO') IS NULL);
SELECT pg_temp.chk('S4l el historial tiene las 6 filas de estado (alta incluida) y el evento del presupuesto',
  (SELECT count(*) FILTER (WHERE evento = 'ESTADO') = 6 AND count(*) FILTER (WHERE evento = 'BITACORA') >= 1
     FROM public.historial_ordenes WHERE orden_id = pg_temp.ord('EQ-P')));
SELECT pg_temp.chk('S4m una orden ENTREGADA ya no admite presupuesto',
  pg_temp.presupuesto('22222222-2222-2222-2222-222222222222', 'EQ-P', 10) IS NOT NULL);

-- ============ S5-S6: rechazo y transiciones inexistentes (EQ-G, en garantía) ============
SELECT pg_temp.chk('S6 transición inexistente RECIBIDO → ENTREGADO rechazada',
  pg_temp.paso('33333333-3333-3333-3333-333333333333', 'EQ-G', 'ENTREGADO') ~ 'no permitida');
SELECT pg_temp.chk('S5 rechazar sin motivo rechazado',
  pg_temp.paso('33333333-3333-3333-3333-333333333333', 'EQ-G', 'RECHAZADO') ~ 'motivo');
SELECT pg_temp.chk('S5b rechazar con motivo de 9 caracteres rechazado',
  pg_temp.paso('33333333-3333-3333-3333-333333333333', 'EQ-G', 'RECHAZADO', NULL, 'nueve car') ~ 'motivo');
SELECT pg_temp.chk('S5c el TECNICO no rechaza (42501)',
  pg_temp.paso('22222222-2222-2222-2222-222222222222', 'EQ-G', 'RECHAZADO', NULL, 'El equipo muestra golpes graves') ~ 'no puede');
SELECT pg_temp.chk('S5d el JEFE rechaza con motivo',
  pg_temp.paso('33333333-3333-3333-3333-333333333333', 'EQ-G', 'RECHAZADO', NULL, 'El equipo muestra golpes graves') IS NULL);
SELECT pg_temp.chk('S5e el motivo queda en la orden',
  (SELECT estado = 'RECHAZADO' AND motivo_rechazo = 'El equipo muestra golpes graves'
     FROM public.ordenes_servicio WHERE id = pg_temp.ord('EQ-G')));
SELECT pg_temp.chk('S5f RECEPCION entrega el RECHAZADO (devolución sin reparar) y el motivo persiste',
  pg_temp.paso('55555555-5555-5555-5555-555555555555', 'EQ-G', 'ENTREGADO') IS NULL);
SELECT pg_temp.chk('S5g motivo_rechazo intacto tras ENTREGADO',
  (SELECT motivo_rechazo = 'El equipo muestra golpes graves'
     FROM public.ordenes_servicio WHERE id = pg_temp.ord('EQ-G')));

-- ============ S7-S8: asignar técnico (EQ-T sigue abierta) ============
SELECT pg_temp.chk('S7 el TECNICO no asigna (42501)',
  pg_temp.mensaje('22222222-2222-2222-2222-222222222222',
    format($$SELECT public.asignar_tecnico(%L, %L)$$, pg_temp.ord('EQ-T'), '66666666-6666-6666-6666-666666666666')) ~ 'Solo ADMIN');
SELECT pg_temp.chk('S7b RECEPCION no asigna (42501)',
  pg_temp.mensaje('55555555-5555-5555-5555-555555555555',
    format($$SELECT public.asignar_tecnico(%L, %L)$$, pg_temp.ord('EQ-T'), '66666666-6666-6666-6666-666666666666')) ~ 'Solo ADMIN');
SELECT pg_temp.chk('S7c el ADMIN reasigna a otro técnico',
  pg_temp.mensaje('11111111-1111-1111-1111-111111111111',
    format($$SELECT public.asignar_tecnico(%L, %L)$$, pg_temp.ord('EQ-T'), '66666666-6666-6666-6666-666666666666')) IS NULL);
SELECT pg_temp.chk('S7d queda asignado y la bitácora lo anota con el nombre',
  (SELECT tecnico_asignado_id = '66666666-6666-6666-6666-666666666666'
     FROM public.ordenes_servicio WHERE id = pg_temp.ord('EQ-T'))
  AND (SELECT count(*) >= 1 FROM public.historial_ordenes
        WHERE orden_id = pg_temp.ord('EQ-T') AND evento = 'BITACORA' AND comentario ~ 'Tomas'));
SELECT pg_temp.chk('S7e el técnico anterior ya no puede cambiar el estado de esa orden',
  pg_temp.paso('22222222-2222-2222-2222-222222222222', 'EQ-T', 'IRREPARABLE') ~ 'asignado');
SELECT pg_temp.chk('S8 asignar a alguien que no es técnico rechazado (22P02)',
  pg_temp.mensaje('11111111-1111-1111-1111-111111111111',
    format($$SELECT public.asignar_tecnico(%L, %L)$$, pg_temp.ord('EQ-T'), '55555555-5555-5555-5555-555555555555')) ~ 'técnico');

-- ============ S9: anon ============
SELECT pg_temp.chk('S9 anon no puede ninguna de las tres',
  pg_temp.mensaje('anon', format($$SELECT public.cambiar_estado(%L, 'EN_DIAGNOSTICO')$$, pg_temp.ord('EQ-T'))) ~ 'permission denied'
  AND pg_temp.mensaje('anon', format($$SELECT public.asignar_tecnico(%L, NULL)$$, pg_temp.ord('EQ-T'))) ~ 'permission denied'
  AND pg_temp.mensaje('anon', format($$SELECT public.registrar_presupuesto(%L, 1)$$, pg_temp.ord('EQ-T'))) ~ 'permission denied');
