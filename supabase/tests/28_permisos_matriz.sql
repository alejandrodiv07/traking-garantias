-- Matriz de permisos de la fase 2a (spec §7) por UPDATE directo y por
-- RPC, más el cierre total de `anon` (Tarea 11; migración 0021).
-- Las celdas ya cubiertas con detalle en 24 (plazo), 26 (confirmar y
-- desestimar) y 27 (estados, presupuesto, asignación) no se repiten aquí.
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

-- Cuántas filas ve una identidad en una consulta (NULL si falla).
CREATE FUNCTION pg_temp.filas(uid text, consulta text) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE n bigint;
BEGIN
  IF uid = 'anon' THEN EXECUTE 'SET LOCAL ROLE anon';
  ELSE
    PERFORM set_config('request.jwt.claim.sub', uid, TRUE);
    PERFORM set_config('request.jwt.claim.session_id', uid, TRUE);
    EXECUTE 'SET LOCAL ROLE authenticated';
  END IF;
  BEGIN
    EXECUTE 'SELECT count(*) FROM (' || consulta || ') x' INTO n;
  EXCEPTION WHEN OTHERS THEN n := NULL;
  END;
  EXECUTE 'RESET ROLE';
  RETURN n;
END $$;

CREATE FUNCTION pg_temp.producto_id() RETURNS uuid LANGUAGE sql AS
  $$ SELECT id FROM public.productos WHERE modelo='HG8245' $$;
CREATE FUNCTION pg_temp.checklist_ok() RETURNS jsonb LANGUAGE sql AS $$
  SELECT '{"condiciones":{"factura_presentada":true,"titular_coincide":true},
           "equipo":{"serial_legible":true,"caja_original":true,"precintos_intactos":true,"contenido_completo":true},
           "senales":{"descarga_electrica":false,"liquidos":false,"altas_temperaturas":false,"golpes":false,"manipulacion_terceros":false}}'::jsonb $$;
CREATE FUNCTION pg_temp.orden() RETURNS uuid LANGUAGE sql AS $$ SELECT id FROM public.ordenes_servicio LIMIT 1 $$;
\set QUIET off

INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES
 ('11111111-1111-1111-1111-111111111111','admin@primetelecom.com','{}'::jsonb),
 ('22222222-2222-2222-2222-222222222222','tecnico@primetelecom.com','{}'::jsonb),
 ('33333333-3333-3333-3333-333333333333','jefe@primetelecom.com','{}'::jsonb),
 ('55555555-5555-5555-5555-555555555555','recepcion@primetelecom.com','{}'::jsonb),
 ('44444444-4444-4444-4444-444444444444','fantasma@x.com','{}'::jsonb);
DO $$
BEGIN
  IF to_regclass('public.mfa_sesiones') IS NOT NULL THEN
    INSERT INTO public.mfa_sesiones (session_id, user_id)
    SELECT p.id, p.id FROM public.profiles p ON CONFLICT (session_id) DO NOTHING;
  END IF;
END $$;
DELETE FROM public.profiles WHERE email = 'fantasma@x.com';
UPDATE public.profiles SET role='ADMIN'         WHERE email='admin@primetelecom.com';
UPDATE public.profiles SET role='JEFE_SERVICIO' WHERE email='jefe@primetelecom.com';
UPDATE public.profiles SET role='RECEPCION'     WHERE email='recepcion@primetelecom.com';

INSERT INTO public.clientes (tipo_documento, documento, nombre) VALUES ('V','12345678','Juan Perez');
INSERT INTO public.equipos (numero_serie, producto_id, cliente_id, tipo_soporte, numero_soporte, fecha_emision, plazo_dias)
SELECT 'EQ-M', pg_temp.producto_id(), id, 'FACTURA', 'F-M', public.hoy_local() - 1, 15 FROM public.clientes;
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
SET LOCAL request.jwt.claim.session_id = '22222222-2222-2222-2222-222222222222';
SELECT public.abrir_orden((SELECT id FROM public.equipos WHERE numero_serie = 'EQ-M'),
                          'No enciende el equipo', NULL, pg_temp.checklist_ok());
COMMIT;
RESET ROLE;

-- ============ Lecturas: los cuatro roles internos sí; sin perfil y anon no ============
SELECT pg_temp.chk('M1 los cuatro roles leen v_tablero, ordenes, revisiones y v_garantias',
  (SELECT bool_and(pg_temp.filas(u, t) >= 1)
     FROM unnest(ARRAY['11111111-1111-1111-1111-111111111111','22222222-2222-2222-2222-222222222222',
                       '33333333-3333-3333-3333-333333333333','55555555-5555-5555-5555-555555555555']) u,
          unnest(ARRAY['SELECT 1 FROM public.v_tablero','SELECT 1 FROM public.ordenes_servicio',
                       'SELECT 1 FROM public.revisiones','SELECT 1 FROM public.v_garantias',
                       'SELECT 1 FROM public.historial_ordenes']) t));
SELECT pg_temp.chk('M2 un usuario sin perfil no ve ninguna fila',
  (SELECT bool_and(pg_temp.filas('44444444-4444-4444-4444-444444444444', t) = 0)
     FROM unnest(ARRAY['SELECT 1 FROM public.ordenes_servicio','SELECT 1 FROM public.v_garantias',
                       'SELECT 1 FROM public.revisiones','SELECT 1 FROM public.historial_ordenes']) t));
SELECT pg_temp.chk('M3 anon no lee nada (permiso denegado)',
  (SELECT bool_and(pg_temp.filas('anon', t) IS NULL)
     FROM unnest(ARRAY['SELECT 1 FROM public.ordenes_servicio','SELECT 1 FROM public.v_garantias',
                       'SELECT 1 FROM public.v_tablero','SELECT 1 FROM public.equipos',
                       'SELECT 1 FROM public.historial_ordenes','SELECT 1 FROM public.revisiones',
                       'SELECT 1 FROM public.adjuntos']) t));

-- ============ UPDATE directo de estado y costo: denegado a los cuatro roles ============
SELECT pg_temp.chk('M4 ningún rol cambia estado por UPDATE directo (permission denied)',
  (SELECT bool_and(pg_temp.mensaje(u, format($$UPDATE public.ordenes_servicio SET estado = 'EN_DIAGNOSTICO' WHERE id = %L$$, pg_temp.orden())) ~ 'permission denied')
     FROM unnest(ARRAY['11111111-1111-1111-1111-111111111111','22222222-2222-2222-2222-222222222222',
                       '33333333-3333-3333-3333-333333333333','55555555-5555-5555-5555-555555555555']) u));
SELECT pg_temp.chk('M5 ningún rol fija costo_reparacion por UPDATE directo (permission denied)',
  (SELECT bool_and(pg_temp.mensaje(u, format($$UPDATE public.ordenes_servicio SET costo_reparacion = 5 WHERE id = %L$$, pg_temp.orden())) ~ 'permission denied')
     FROM unnest(ARRAY['11111111-1111-1111-1111-111111111111','22222222-2222-2222-2222-222222222222',
                       '33333333-3333-3333-3333-333333333333','55555555-5555-5555-5555-555555555555']) u));
SELECT pg_temp.chk('M6 la asignación tampoco se cambia por UPDATE directo',
  pg_temp.mensaje('11111111-1111-1111-1111-111111111111',
    format($$UPDATE public.ordenes_servicio SET tecnico_asignado_id = NULL WHERE id = %L$$, pg_temp.orden())) ~ 'permission denied');

-- ============ Revisión técnica posterior: no RECEPCION ============
SELECT pg_temp.chk('M7 RECEPCION no registra revisión técnica',
  pg_temp.mensaje('55555555-5555-5555-5555-555555555555',
    format($$SELECT public.registrar_revision(%L, 'TECNICA', pg_temp.checklist_ok(), NULL)$$, pg_temp.orden())) IS NOT NULL);
SELECT pg_temp.chk('M7b JEFE_SERVICIO sí',
  pg_temp.mensaje('33333333-3333-3333-3333-333333333333',
    format($$SELECT public.registrar_revision(%L, 'TECNICA', pg_temp.checklist_ok(), NULL)$$, pg_temp.orden())) IS NULL);

-- ============ Cualquier rol interno abre orden y registra garantía ============
SELECT pg_temp.chk('M8 los cuatro roles registran una garantía (plazo 7)',
  (SELECT bool_and(pg_temp.mensaje(u, format($$SELECT public.registrar_garantia(%L, %L, %L, 'FACTURA', %L, public.hoy_local(), 7)$$,
                      (SELECT id FROM public.clientes LIMIT 1), pg_temp.producto_id(), 'SN-' || left(u, 2), 'F-' || left(u, 2))) IS NULL)
     FROM unnest(ARRAY['11111111-1111-1111-1111-111111111111','22222222-2222-2222-2222-222222222222',
                       '33333333-3333-3333-3333-333333333333','55555555-5555-5555-5555-555555555555']) u));
SELECT pg_temp.chk('M9 un usuario sin perfil no registra garantía ni abre orden (42501)',
  pg_temp.mensaje('44444444-4444-4444-4444-444444444444',
    format($$SELECT public.registrar_garantia(%L, %L, 'SN-FANT', NULL, NULL, NULL, NULL)$$,
           (SELECT id FROM public.clientes LIMIT 1), pg_temp.producto_id())) ~ 'Su rol'
  AND pg_temp.mensaje('44444444-4444-4444-4444-444444444444',
    format($$SELECT public.abrir_orden(%L, 'Falla cualquiera')$$,
           (SELECT id FROM public.equipos LIMIT 1))) ~ 'Su rol');

-- ============ anon: ninguna RPC nueva ============
SELECT pg_temp.chk('M10 anon no ejecuta ninguna RPC de la fase',
  (SELECT bool_and(pg_temp.mensaje('anon', s) ~ 'permission denied')
     FROM unnest(ARRAY[
       $$SELECT public.registrar_garantia(gen_random_uuid(), gen_random_uuid(), 'SN-ANON', NULL, NULL, NULL, NULL)$$,
       $$SELECT * FROM public.buscar_equipo(p_serial => 'X')$$,
       $$SELECT public.abrir_orden(gen_random_uuid(), 'Falla cualquiera')$$,
       $$SELECT public.confirmar_compra(gen_random_uuid(), 'FACTURA', 'X', public.hoy_local(), 7)$$,
       $$SELECT public.desestimar_compra(gen_random_uuid(), 'Motivo suficientemente largo')$$,
       $$SELECT public.cambiar_estado(gen_random_uuid(), 'EN_DIAGNOSTICO')$$,
       $$SELECT public.asignar_tecnico(gen_random_uuid(), NULL)$$,
       $$SELECT public.registrar_presupuesto(gen_random_uuid(), 1)$$]) s));
