-- Prueba de abrir_orden por equipo (Tarea 9 de la fase 2a; spec §5.1 y §6;
-- migración 0019): la orden y su auditoría de recepción en UNA transacción,
-- idempotencia por clave de envío y cobertura puesta por la base.
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
CREATE FUNCTION pg_temp.checklist_ok() RETURNS jsonb LANGUAGE sql AS $$
  SELECT '{"condiciones":{"factura_presentada":true,"titular_coincide":true},
           "equipo":{"serial_legible":true,"caja_original":true,"precintos_intactos":true,"contenido_completo":true},
           "senales":{"descarga_electrica":false,"liquidos":false,"altas_temperaturas":false,"golpes":false,"manipulacion_terceros":false}}'::jsonb $$;
CREATE FUNCTION pg_temp.checklist_golpe() RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_set(pg_temp.checklist_ok(), '{senales,golpes}', 'true') $$;
\set QUIET off

INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES
 ('11111111-1111-1111-1111-111111111111','admin@primetelecom.com','{}'::jsonb),
 ('22222222-2222-2222-2222-222222222222','tecnico@primetelecom.com','{}'::jsonb),
 ('55555555-5555-5555-5555-555555555555','recepcion@primetelecom.com','{}'::jsonb);
DO $$
BEGIN
  IF to_regclass('public.mfa_sesiones') IS NOT NULL THEN
    INSERT INTO public.mfa_sesiones (session_id, user_id)
    SELECT p.id, p.id FROM public.profiles p ON CONFLICT (session_id) DO NOTHING;
  END IF;
END $$;
UPDATE public.profiles SET role='ADMIN'     WHERE email='admin@primetelecom.com';
UPDATE public.profiles SET role='RECEPCION' WHERE email='recepcion@primetelecom.com';

INSERT INTO public.clientes (tipo_documento, documento, nombre) VALUES ('V','12345678','Juan Perez');
-- Equipos (INSERT directo: la creación pública es registrar_garantia, ya probada en 24).
INSERT INTO public.equipos (numero_serie, producto_id, cliente_id, tipo_soporte, numero_soporte, fecha_emision, plazo_dias)
SELECT 'EQ-VIGENTE', pg_temp.producto_id(), id, 'FACTURA', 'F-1', public.hoy_local() - 1, 15 FROM public.clientes;
INSERT INTO public.equipos (numero_serie, producto_id, cliente_id, tipo_soporte, numero_soporte, fecha_emision, plazo_dias, origen)
SELECT 'EQ-TALLER', pg_temp.producto_id(), id, 'FACTURA', 'F-2', public.hoy_local() - 1, 15, 'TALLER' FROM public.clientes;

-- ============ O1-O3: abrir la orden ============
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
SET LOCAL request.jwt.claim.session_id = '22222222-2222-2222-2222-222222222222';
CREATE TEMP TABLE t_o1 AS
SELECT * FROM public.abrir_orden(pg_temp.eq('EQ-VIGENTE'), 'No enciende, huele a quemado',
                                 'cargador', pg_temp.checklist_ok());
COMMIT;
RESET ROLE;

SELECT pg_temp.chk('O1 crea UNA orden OS-AAAA-NNNN y su revisión de RECEPCION',
  (SELECT numero_orden ~ '^OS-[0-9]{4}-[0-9]{4}$' FROM t_o1)
  AND (SELECT count(*) FROM public.ordenes_servicio) = 1
  AND (SELECT count(*) FROM public.revisiones WHERE orden_id = (SELECT orden_id FROM t_o1) AND tipo = 'RECEPCION') = 1);
SELECT pg_temp.chk('O2 token de 32 hex y en la base solo su hash',
  (SELECT consulta_token ~ '^[0-9a-f]{32}$' FROM t_o1)
  AND (SELECT consulta_token_hash = extensions.digest((SELECT consulta_token FROM t_o1), 'sha256')
         FROM public.ordenes_servicio WHERE id = (SELECT orden_id FROM t_o1)));
SELECT pg_temp.chk('O3 cobertura y tipo_atencion devueltos = los de la fila (EN_GARANTIA / GARANTIA)',
  (SELECT t.cobertura = o.cobertura AND t.tipo_atencion = o.tipo_atencion
          AND t.cobertura::text = 'EN_GARANTIA' AND t.tipo_atencion = 'GARANTIA'
     FROM t_o1 t JOIN public.ordenes_servicio o ON o.id = t.orden_id));
SELECT pg_temp.chk('O3b el TECNICO que abre la orden queda asignado',
  (SELECT tecnico_asignado_id = '22222222-2222-2222-2222-222222222222'
     FROM public.ordenes_servicio WHERE id = (SELECT orden_id FROM t_o1)));

-- ============ O4: idempotencia ============
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
SET LOCAL request.jwt.claim.session_id = '22222222-2222-2222-2222-222222222222';
CREATE TEMP TABLE t_k1 AS
SELECT * FROM public.abrir_orden(pg_temp.eq('EQ-VIGENTE'), 'Otra falla distinta', NULL, pg_temp.checklist_ok(),
                                 NULL, 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
CREATE TEMP TABLE t_k2 AS
SELECT * FROM public.abrir_orden(pg_temp.eq('EQ-VIGENTE'), 'Otra falla distinta', NULL, pg_temp.checklist_ok(),
                                 NULL, 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
CREATE TEMP TABLE t_k3 AS
SELECT * FROM public.abrir_orden(pg_temp.eq('EQ-VIGENTE'), 'Otra falla distinta', NULL, pg_temp.checklist_ok(),
                                 NULL, 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb');
COMMIT;
RESET ROLE;
SELECT pg_temp.chk('O4 misma clave dos veces: UNA orden y la segunda respuesta es la original sin token',
  (SELECT k1.orden_id = k2.orden_id AND k1.numero_orden = k2.numero_orden
          AND length(k1.consulta_token) = 32 AND k2.consulta_token IS NULL
     FROM t_k1 k1, t_k2 k2)
  AND (SELECT count(*) FROM public.ordenes_servicio WHERE id = (SELECT orden_id FROM t_k1)) = 1
  AND (SELECT count(*) FROM public.revisiones WHERE orden_id = (SELECT orden_id FROM t_k1)) = 1);
SELECT pg_temp.chk('O4b claves distintas: dos órdenes',
  (SELECT k1.orden_id <> k3.orden_id FROM t_k1 k1, t_k3 k3));

-- ============ O5-O7: errores y permisos ============
SELECT pg_temp.chk('O5 equipo inexistente: P0002',
  pg_temp.mensaje('22222222-2222-2222-2222-222222222222',
    $$SELECT * FROM public.abrir_orden(gen_random_uuid(), 'Falla cualquiera', NULL, NULL)$$) ~ 'equipo');
SELECT pg_temp.chk('O6 falla de menos de 5 caracteres: 22P02',
  pg_temp.mensaje('22222222-2222-2222-2222-222222222222',
    $$SELECT * FROM public.abrir_orden(pg_temp.eq('EQ-VIGENTE'), 'abc', NULL, NULL)$$) ~ 'falla');
SELECT pg_temp.chk('O6b la falla inválida no deja orden',
  (SELECT count(*) FROM public.ordenes_servicio) = 3);
SELECT pg_temp.chk('O7 anon no puede abrir_orden',
  pg_temp.mensaje('anon',
    $$SELECT * FROM public.abrir_orden(pg_temp.eq('EQ-VIGENTE'), 'Falla cualquiera', NULL, NULL)$$) ~ 'permission denied');

-- ============ O8-O11: roles, golpe, fecha y taller sin confirmar ============
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '55555555-5555-5555-5555-555555555555';
SET LOCAL request.jwt.claim.session_id = '55555555-5555-5555-5555-555555555555';
CREATE TEMP TABLE t_o8 AS
SELECT * FROM public.abrir_orden(pg_temp.eq('EQ-VIGENTE'), 'Con golpes visibles', NULL, pg_temp.checklist_golpe(),
                                 NULL, NULL, now() - interval '30 days');
COMMIT;
RESET ROLE;
SELECT pg_temp.chk('O8 RECEPCION sí abre orden (y no queda como técnico asignado)',
  (SELECT tecnico_asignado_id IS NULL FROM public.ordenes_servicio WHERE id = (SELECT orden_id FROM t_o8)));
SELECT pg_temp.chk('O9 checklist con golpes: ANULADA_POR_USO y servicio de PAGO',
  (SELECT cobertura::text = 'ANULADA_POR_USO' AND tipo_atencion = 'PAGO' FROM t_o8));
SELECT pg_temp.chk('O10 la fecha de ingreso pasada de RECEPCION se ignora (solo la manda el ADMIN)',
  (SELECT fecha_ingreso >= now() - interval '1 minute'
     FROM public.ordenes_servicio WHERE id = (SELECT orden_id FROM t_o8)));

BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
SET LOCAL request.jwt.claim.session_id = '22222222-2222-2222-2222-222222222222';
CREATE TEMP TABLE t_o11 AS
SELECT * FROM public.abrir_orden(pg_temp.eq('EQ-TALLER'), 'Equipo registrado en el taller', NULL, pg_temp.checklist_ok());
COMMIT;
RESET ROLE;
SELECT pg_temp.chk('O11 equipo TALLER sin confirmar: POR_DETERMINAR y atención PENDIENTE',
  (SELECT cobertura::text = 'POR_DETERMINAR' AND tipo_atencion = 'PENDIENTE' FROM t_o11));
