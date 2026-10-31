-- Fase 2b, tarea 1 (migración 0023): facturas de Ventas por CSV.
--   · importar_ventas: solo ADMIN/JEFE, validación por fila, idempotente.
--   · Una garantía TALLER se confirma sola si coinciden factura + serial +
--     documento del titular + fecha; si algo difiere queda para revisión.
--   · Nunca se confirma una compra desestimada ni cambia una garantía VENTA.
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
CREATE FUNCTION pg_temp.eq(serial text) RETURNS uuid LANGUAGE sql AS
  $$ SELECT id FROM public.equipos WHERE numero_serie = serial $$;
-- Una fila del CSV de Ventas (la fecha en ISO, como la manda el navegador).
CREATE FUNCTION pg_temp.fila(factura text, dias_atras int, doc text, serial text) RETURNS jsonb
LANGUAGE sql AS $$
  SELECT jsonb_build_object('numero_factura', factura,
                            'fecha_emision', to_char(public.hoy_local() - dias_atras, 'YYYY-MM-DD'),
                            'tipo_documento', 'V', 'numero_documento', doc,
                            'nombre_cliente', 'Cliente ' || doc, 'serial', serial, 'modelo', 'HG8245') $$;
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

INSERT INTO public.clientes (tipo_documento, documento, nombre) VALUES
 ('V','12345678','Juan Perez'), ('V','87654321','Ana Lopez');

-- Garantías: el TECNICO las registra (TALLER = presentó factura, sin confirmar).
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
SET LOCAL request.jwt.claim.session_id = '22222222-2222-2222-2222-222222222222';
SELECT public.registrar_garantia(c.id, pg_temp.producto_id(), s.serial, 'FACTURA', s.factura,
                                 public.hoy_local() - s.dias, 7, s.origen)
  FROM public.clientes c,
       (VALUES ('S-100','F-100',3,'TALLER'),   -- coincide por completo
               ('S-200','F-200',3,'TALLER'),   -- Ventas dirá otro titular
               ('S-300','F-300',3,'TALLER'),   -- Ventas no la tiene
               ('S-400','F-400',3,'VENTA'),    -- VENTA: solo se informa
               ('S-500','F-500',3,'TALLER'),   -- Ventas dirá otra fecha
               ('S-800','F-800',3,'TALLER')) s(serial, factura, dias, origen)
 WHERE c.documento = '12345678';
-- S-800 ya tiene una orden abierta (POR_DETERMINAR) cuando llegue la venta.
SELECT public.abrir_orden(pg_temp.eq('S-800'), 'No enciende el equipo', NULL, pg_temp.checklist_ok());
COMMIT;
RESET ROLE;

-- ============ Permisos ============
SELECT pg_temp.chk('V1 TECNICO, RECEPCION y sin perfil no importan ventas (42501)',
  (SELECT bool_and(pg_temp.mensaje(u, $$SELECT public.importar_ventas('x.csv', '[]'::jsonb)$$) ~ 'Solo ADMIN o JEFE')
     FROM unnest(ARRAY['22222222-2222-2222-2222-222222222222','55555555-5555-5555-5555-555555555555',
                       '44444444-4444-4444-4444-444444444444']) u));
SELECT pg_temp.chk('V2 anon no ejecuta importar_ventas ni lee las tablas',
  pg_temp.mensaje('anon', $$SELECT public.importar_ventas('x.csv', '[]'::jsonb)$$) ~ 'permission denied'
  AND pg_temp.filas('anon', 'SELECT 1 FROM public.ventas_facturas') IS NULL
  AND pg_temp.filas('anon', 'SELECT 1 FROM public.lotes_importacion') IS NULL);

-- ============ Primera importación (JEFE) ============
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';
SET LOCAL request.jwt.claim.session_id = '33333333-3333-3333-3333-333333333333';
CREATE TEMP TABLE r1 AS
SELECT * FROM public.importar_ventas('ventas-1.csv', jsonb_build_array(
  pg_temp.fila('F-100', 3, '12345678', 'S-100'),          -- 1 coincide
  pg_temp.fila('F-200', 3, '87654321', 'S-200'),          -- 2 otro titular
  pg_temp.fila('F-400', 3, '12345678', 'S-400'),          -- 3 garantía VENTA
  pg_temp.fila('F-500', 9, '12345678', 'S-500'),          -- 4 otra fecha
  pg_temp.fila('F-800', 3, '12345678', 'S-800'),          -- 5 coincide (con orden)
  pg_temp.fila('F-600', 3, '12345678', 'S-600'),          -- 6 aún sin garantía
  pg_temp.fila('F-901', 3, '12345678', 'AB'),             -- 7 serial corto
  pg_temp.fila('', 3, '12345678', 'S-902'),               -- 8 sin factura
  (pg_temp.fila('F-903', 3, '12345678', 'S-903') || '{"fecha_emision":"ayer"}'::jsonb),   -- 9 fecha ilegible
  (pg_temp.fila('F-904', 3, '12345678', 'S-904') || '{"fecha_emision":"2999-01-01"}'::jsonb))); -- 10 futura
COMMIT;
RESET ROLE;

SELECT pg_temp.chk('V3 resumen: 6 nuevas, 0 actualizadas, 4 con error, 2 confirmadas',
  (SELECT nuevas = 6 AND actualizadas = 0 AND con_error = 4 AND confirmadas = 2 FROM r1));
SELECT pg_temp.chk('V4 los errores dicen fila y campo',
  (SELECT jsonb_array_length(errores) = 4
      AND errores @> '[{"fila":7,"campo":"serial"}]'::jsonb
      AND errores @> '[{"fila":8,"campo":"numero_factura"}]'::jsonb
      AND errores @> '[{"fila":9,"campo":"fecha_emision"}]'::jsonb
      AND errores @> '[{"fila":10,"campo":"fecha_emision"}]'::jsonb FROM r1));
SELECT pg_temp.chk('V5 el lote queda registrado con sus cuentas',
  (SELECT count(*) = 1 AND bool_and(archivo = 'ventas-1.csv' AND filas_total = 10
                                    AND filas_ok = 6 AND filas_error = 4
                                    AND importado_por = '33333333-3333-3333-3333-333333333333')
     FROM public.lotes_importacion));
SELECT pg_temp.chk('V6 solo las 6 filas válidas se guardaron',
  (SELECT count(*) = 6 FROM public.ventas_facturas));

-- ============ Confirmación automática ============
-- `verificacion` solo se ve con rol interno: V7–V10 leen como JEFE.
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';
SET LOCAL request.jwt.claim.session_id = '33333333-3333-3333-3333-333333333333';
SELECT pg_temp.chk('V7S-100 (coincide) quedó confirmada por la importación, vía VENTAS, y vigente',
  (SELECT e.compra_confirmada_por = '33333333-3333-3333-3333-333333333333'
      AND e.compra_confirmada_via = 'VENTAS'
      AND g.vigencia::text = 'EN_GARANTIA' AND g.verificacion = 'COINCIDE'
     FROM public.equipos e JOIN public.v_garantias g ON g.equipo_id = e.id
    WHERE e.numero_serie = 'S-100'));
SELECT pg_temp.chk('V8 S-200 (otro titular) y S-500 (otra fecha) no se confirman: DIFIEREN',
  (SELECT bool_and(e.compra_confirmada_por IS NULL AND g.verificacion = 'DIFIERE'
                   AND g.vigencia::text = 'POR_DETERMINAR')
     FROM public.equipos e JOIN public.v_garantias g ON g.equipo_id = e.id
    WHERE e.numero_serie IN ('S-200','S-500')));
SELECT pg_temp.chk('V9 S-300 (sin venta) queda SIN_VENTA y por determinar',
  (SELECT g.verificacion = 'SIN_VENTA' AND g.vigencia::text = 'POR_DETERMINAR'
     FROM public.v_garantias g WHERE g.numero_serie = 'S-300'));
SELECT pg_temp.chk('V10 S-400 (origen VENTA) solo se informa: COINCIDE, sin confirmación ni cambio',
  (SELECT e.compra_confirmada_por IS NULL AND e.compra_confirmada_via IS NULL
      AND g.verificacion = 'COINCIDE' AND g.vigencia::text = 'EN_GARANTIA'
     FROM public.equipos e JOIN public.v_garantias g ON g.equipo_id = e.id
    WHERE e.numero_serie = 'S-400'));
COMMIT;
RESET ROLE;
SELECT pg_temp.chk('V11 la orden abierta de S-800 pasó de POR_DETERMINAR a EN_GARANTIA / GARANTIA',
  (SELECT cobertura::text = 'EN_GARANTIA' AND tipo_atencion = 'GARANTIA'
     FROM public.ordenes_servicio WHERE equipo_id = pg_temp.eq('S-800')));

-- ============ Idempotencia ============
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
SET LOCAL request.jwt.claim.session_id = '11111111-1111-1111-1111-111111111111';
CREATE TEMP TABLE r2 AS
SELECT * FROM public.importar_ventas('ventas-1.csv', jsonb_build_array(
  pg_temp.fila('F-100', 3, '12345678', 'S-100'),
  pg_temp.fila(' f-200 ', 3, '87654321', 's 200'),        -- misma clave, otra escritura
  pg_temp.fila('F-400', 3, '12345678', 'S-400')));
COMMIT;
RESET ROLE;

SELECT pg_temp.chk('V13 reimportar no duplica: 0 nuevas, 3 actualizadas, 0 confirmadas nuevas (ADMIN también)',
  (SELECT nuevas = 0 AND actualizadas = 3 AND confirmadas = 0 FROM r2));
SELECT pg_temp.chk('V14 siguen 6 ventas, y la confirmación de S-100 no cambió de autor',
  (SELECT count(*) = 6 FROM public.ventas_facturas)
  AND (SELECT compra_confirmada_por = '33333333-3333-3333-3333-333333333333'
         FROM public.equipos WHERE numero_serie = 'S-100'));

-- ============ La venta ya estaba: el equipo llega después ============
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
SET LOCAL request.jwt.claim.session_id = '22222222-2222-2222-2222-222222222222';
SELECT public.registrar_garantia((SELECT id FROM public.clientes WHERE documento = '12345678'),
         pg_temp.producto_id(), 'S-600', 'FACTURA', 'F-600', public.hoy_local() - 3, 7, 'TALLER');
COMMIT;
RESET ROLE;
SELECT pg_temp.chk('V15 al registrar S-600 (venta ya importada) queda confirmada por quien la registró',
  (SELECT e.compra_confirmada_por = '22222222-2222-2222-2222-222222222222'
      AND e.compra_confirmada_via = 'VENTAS' AND g.vigencia::text = 'EN_GARANTIA'
     FROM public.equipos e JOIN public.v_garantias g ON g.equipo_id = e.id
    WHERE e.numero_serie = 'S-600'));

-- ============ Una compra desestimada nunca se confirma sola ============
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
SET LOCAL request.jwt.claim.session_id = '22222222-2222-2222-2222-222222222222';
SELECT public.registrar_garantia((SELECT id FROM public.clientes WHERE documento = '12345678'),
         pg_temp.producto_id(), 'S-700', 'FACTURA', 'F-700', public.hoy_local() - 3, 7, 'TALLER');
COMMIT;
RESET ROLE;
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';
SET LOCAL request.jwt.claim.session_id = '33333333-3333-3333-3333-333333333333';
SELECT public.desestimar_compra(pg_temp.eq('S-700'), 'La factura no corresponde a ninguna venta');
CREATE TEMP TABLE r3 AS
SELECT * FROM public.importar_ventas('ventas-2.csv', jsonb_build_array(
  pg_temp.fila('F-700', 3, '12345678', 'S-700')));
COMMIT;
RESET ROLE;
SELECT pg_temp.chk('V16 S-700 desestimada: la venta se guarda pero no se confirma',
  (SELECT nuevas = 1 AND confirmadas = 0 FROM r3)
  AND (SELECT compra_confirmada_por IS NULL AND compra_desestimada_por IS NOT NULL
         FROM public.equipos WHERE numero_serie = 'S-700'));

-- ============ Confirmación manual: la vía queda MANUAL ============
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';
SET LOCAL request.jwt.claim.session_id = '33333333-3333-3333-3333-333333333333';
SELECT public.confirmar_compra(pg_temp.eq('S-300'), 'FACTURA', 'F-300', public.hoy_local() - 3, 7);
COMMIT;
RESET ROLE;
SELECT pg_temp.chk('V17 confirmar_compra a mano deja compra_confirmada_via = MANUAL',
  (SELECT compra_confirmada_via = 'MANUAL' FROM public.equipos WHERE numero_serie = 'S-300'));

-- ============ Límites y entrada mal formada ============
SELECT pg_temp.chk('V18 más de 5000 filas se rechaza entero (22P02) y no guarda nada',
  pg_temp.mensaje('33333333-3333-3333-3333-333333333333',
    $$SELECT public.importar_ventas('grande.csv',
        (SELECT jsonb_agg(pg_temp.fila('G-' || g, 1, '12345678', 'GS-' || g)) FROM generate_series(1, 5001) g))$$) ~ '5000'
  AND (SELECT count(*) = 6 + 1 FROM public.ventas_facturas)       -- 6 + F-700
  AND (SELECT count(*) = 3 FROM public.lotes_importacion));
SELECT pg_temp.chk('V19 si p_filas no es un arreglo JSON se rechaza (22P02)',
  pg_temp.mensaje('33333333-3333-3333-3333-333333333333',
    $$SELECT public.importar_ventas('x.csv', '{"a":1}'::jsonb)$$) ~ 'arreglo');
SELECT pg_temp.chk('V20 un archivo sin nombre se rechaza',
  pg_temp.mensaje('33333333-3333-3333-3333-333333333333',
    $$SELECT public.importar_ventas('  ', '[]'::jsonb)$$) ~ 'archivo');

-- ============ Las tablas solo se leen (jefatura) ============
SELECT pg_temp.chk('V21 ADMIN y JEFE leen ventas y lotes; TECNICO y RECEPCION no ven filas',
  pg_temp.filas('33333333-3333-3333-3333-333333333333', 'SELECT 1 FROM public.ventas_facturas') = 7
  AND pg_temp.filas('11111111-1111-1111-1111-111111111111', 'SELECT 1 FROM public.lotes_importacion') = 3
  AND pg_temp.filas('22222222-2222-2222-2222-222222222222', 'SELECT 1 FROM public.ventas_facturas') = 0
  AND pg_temp.filas('55555555-5555-5555-5555-555555555555', 'SELECT 1 FROM public.lotes_importacion') = 0);
SELECT pg_temp.chk('V22 nadie escribe las tablas directo (INSERT/UPDATE/DELETE: permission denied)',
  (SELECT bool_and(pg_temp.mensaje('33333333-3333-3333-3333-333333333333', s) ~ 'permission denied')
     FROM unnest(ARRAY[
       $$INSERT INTO public.ventas_facturas (numero_factura, fecha_emision, numero_documento, numero_serie) VALUES ('X', public.hoy_local(), '1', 'XXX')$$,
       $$UPDATE public.ventas_facturas SET numero_documento = '9'$$,
       $$DELETE FROM public.ventas_facturas$$,
       $$UPDATE public.lotes_importacion SET filas_ok = 0$$]) s));
SELECT pg_temp.chk('V23 verificacion se ve para todos los roles internos y respeta la RLS de equipos',
  (SELECT bool_and(pg_temp.filas(u, 'SELECT 1 FROM public.v_garantias WHERE verificacion IS NOT NULL') >= 6)
     FROM unnest(ARRAY['22222222-2222-2222-2222-222222222222','55555555-5555-5555-5555-555555555555',
                       '33333333-3333-3333-3333-333333333333']) u)
  AND pg_temp.filas('44444444-4444-4444-4444-444444444444', 'SELECT 1 FROM public.v_garantias') = 0);
