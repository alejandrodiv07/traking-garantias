-- Prueba de confirmar_compra (ratifica también un soporte ya cargado) y
-- desestimar_compra (Tarea 10 de la fase 2a; spec §4.1, §4.4 y §6;
-- migración 0020).
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
CREATE FUNCTION pg_temp.orden_de(n text) RETURNS uuid LANGUAGE sql AS
  $$ SELECT id FROM public.ordenes_servicio WHERE equipo_id = pg_temp.eq(n) $$;
CREATE FUNCTION pg_temp.checklist_ok() RETURNS jsonb LANGUAGE sql AS $$
  SELECT '{"condiciones":{"factura_presentada":true,"titular_coincide":true},
           "equipo":{"serial_legible":true,"caja_original":true,"precintos_intactos":true,"contenido_completo":true},
           "senales":{"descarga_electrica":false,"liquidos":false,"altas_temperaturas":false,"golpes":false,"manipulacion_terceros":false}}'::jsonb $$;
\set QUIET off

INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES
 ('11111111-1111-1111-1111-111111111111','admin@primetelecom.com','{}'::jsonb),
 ('22222222-2222-2222-2222-222222222222','tecnico@primetelecom.com','{}'::jsonb),
 ('33333333-3333-3333-3333-333333333333','jefe@primetelecom.com','{}'::jsonb),
 ('55555555-5555-5555-5555-555555555555','recepcion@primetelecom.com','{}'::jsonb);
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
-- Tres garantías de TALLER con la factura que presentó el cliente, sin confirmar.
INSERT INTO public.equipos (numero_serie, producto_id, cliente_id, tipo_soporte, numero_soporte, fecha_emision, plazo_dias, origen)
SELECT s, pg_temp.producto_id(), c.id, 'FACTURA', 'F-' || s, public.hoy_local() - 1, 15, 'TALLER'
  FROM public.clientes c, unnest(ARRAY['EQ-A','EQ-B','EQ-C']) s;
-- Una garantía de TALLER sin soporte.
INSERT INTO public.equipos (numero_serie, producto_id, cliente_id, origen)
SELECT 'EQ-SIN', pg_temp.producto_id(), id, 'TALLER' FROM public.clientes;

-- Una orden abierta (recepción con checklist perfecto) para cada equipo.
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
SET LOCAL request.jwt.claim.session_id = '11111111-1111-1111-1111-111111111111';
SELECT public.abrir_orden(pg_temp.eq(s), 'No enciende el equipo', NULL, pg_temp.checklist_ok())
  FROM unnest(ARRAY['EQ-A','EQ-B','EQ-C','EQ-SIN']) s;
COMMIT;
RESET ROLE;

SELECT pg_temp.chk('F0 punto de partida: las órdenes de TALLER sin confirmar están POR_DETERMINAR / PENDIENTE',
  (SELECT bool_and(cobertura::text = 'POR_DETERMINAR' AND tipo_atencion = 'PENDIENTE')
     FROM public.ordenes_servicio));

-- ============ CONFIRMAR_COMPRA ============
SELECT pg_temp.chk('F1 JEFE confirma un equipo que YA tiene soporte cargado',
  pg_temp.mensaje('33333333-3333-3333-3333-333333333333',
    format($$SELECT public.confirmar_compra(%L, 'FACTURA', 'F-REAL', public.hoy_local() - 1, 15)$$, pg_temp.eq('EQ-A'))) IS NULL);
SELECT pg_temp.chk('F1b queda confirmado por el jefe, con los datos ratificados',
  (SELECT compra_confirmada_por = '33333333-3333-3333-3333-333333333333'
          AND numero_soporte = 'F-REAL'
     FROM public.equipos WHERE numero_serie = 'EQ-A'));
SELECT pg_temp.chk('F1c la orden abierta del equipo pasa a EN_GARANTIA / GARANTIA',
  (SELECT cobertura::text = 'EN_GARANTIA' AND tipo_atencion = 'GARANTIA'
     FROM public.ordenes_servicio WHERE id = pg_temp.orden_de('EQ-A')));

-- F2: presupuesto cargado antes de confirmar; al pasar a garantía la base lo limpia.
UPDATE public.ordenes_servicio SET costo_reparacion = 25 WHERE id = pg_temp.orden_de('EQ-B');
SELECT pg_temp.chk('F2 confirmar con presupuesto cargado deja la orden EN_GARANTIA sin costo',
  pg_temp.mensaje('11111111-1111-1111-1111-111111111111',
    format($$SELECT public.confirmar_compra(%L, 'FACTURA', 'F-EQ-B', public.hoy_local() - 1, 15)$$, pg_temp.eq('EQ-B'))) IS NULL);
SELECT pg_temp.chk('F2b costo_reparacion NULL y la bitácora lo anota',
  (SELECT cobertura::text = 'EN_GARANTIA' AND costo_reparacion IS NULL
     FROM public.ordenes_servicio WHERE id = pg_temp.orden_de('EQ-B'))
  AND (SELECT count(*) >= 1 FROM public.historial_ordenes
        WHERE orden_id = pg_temp.orden_de('EQ-B') AND evento = 'BITACORA'));

SELECT pg_temp.chk('F3 confirmar sin datos del soporte: 22P02',
  pg_temp.mensaje('11111111-1111-1111-1111-111111111111',
    format($$SELECT public.confirmar_compra(%L, NULL, NULL, NULL, NULL)$$, pg_temp.eq('EQ-SIN'))) ~ 'soporte');
SELECT pg_temp.chk('F3b equipo sin soporte se completa y confirma con los datos de ventas',
  pg_temp.mensaje('11111111-1111-1111-1111-111111111111',
    format($$SELECT public.confirmar_compra(%L, 'FACTURA', 'F-SIN', public.hoy_local() - 2, 7)$$, pg_temp.eq('EQ-SIN'))) IS NULL);
SELECT pg_temp.chk('F3c su orden abierta pasa a EN_GARANTIA',
  (SELECT cobertura::text = 'EN_GARANTIA' FROM public.ordenes_servicio WHERE id = pg_temp.orden_de('EQ-SIN')));
SELECT pg_temp.chk('F4 equipo inexistente: P0002',
  pg_temp.mensaje('11111111-1111-1111-1111-111111111111',
    $$SELECT public.confirmar_compra(gen_random_uuid(), 'FACTURA', 'X', public.hoy_local(), 7)$$) ~ 'inexistente');

-- ============ DESESTIMAR_COMPRA ============
SELECT pg_temp.chk('F5 motivo de 9 caracteres rechazado (22P02)',
  pg_temp.mensaje('33333333-3333-3333-3333-333333333333',
    format($$SELECT public.desestimar_compra(%L, 'nueve car')$$, pg_temp.eq('EQ-C'))) ~ 'motivo');
SELECT pg_temp.chk('F5b el rechazo no marca nada',
  (SELECT compra_desestimada_por IS NULL FROM public.equipos WHERE numero_serie = 'EQ-C'));
SELECT pg_temp.chk('F6 JEFE desestima con motivo de 10 o más caracteres',
  pg_temp.mensaje('33333333-3333-3333-3333-333333333333',
    format($$SELECT public.desestimar_compra(%L, 'El titular nunca compró esta unidad')$$, pg_temp.eq('EQ-C'))) IS NULL);
SELECT pg_temp.chk('F6b queda completo: quién, cuándo y motivo',
  (SELECT compra_desestimada_por = '33333333-3333-3333-3333-333333333333'
          AND compra_desestimada_en IS NOT NULL
          AND compra_desestimada_motivo = 'El titular nunca compró esta unidad'
     FROM public.equipos WHERE numero_serie = 'EQ-C'));
SELECT pg_temp.chk('F6c la orden abierta pasa a FUERA_DE_GARANTIA / PAGO y nada se borra',
  (SELECT cobertura::text = 'FUERA_DE_GARANTIA' AND tipo_atencion = 'PAGO'
     FROM public.ordenes_servicio WHERE id = pg_temp.orden_de('EQ-C'))
  AND (SELECT count(*) FROM public.ordenes_servicio) = 4);
SELECT pg_temp.chk('F6d buscar_equipo la muestra FUERA_DE_GARANTIA y DESESTIMADA con el motivo',
  (SELECT vigencia::text = 'FUERA_DE_GARANTIA' AND estado_compra = 'DESESTIMADA'
          AND motivo_desestimacion = 'El titular nunca compró esta unidad'
     FROM public.buscar_equipo(p_serial => 'EQ-C')));
SELECT pg_temp.chk('F7 desestimar un equipo ya confirmado rechazado',
  pg_temp.mensaje('33333333-3333-3333-3333-333333333333',
    format($$SELECT public.desestimar_compra(%L, 'Motivo suficientemente largo')$$, pg_temp.eq('EQ-A'))) ~ 'confirmada');
SELECT pg_temp.chk('F7b confirmar un equipo desestimado rechazado',
  pg_temp.mensaje('33333333-3333-3333-3333-333333333333',
    format($$SELECT public.confirmar_compra(%L, 'FACTURA', 'F-C', public.hoy_local() - 1, 15)$$, pg_temp.eq('EQ-C'))) ~ 'desestimada');
SELECT pg_temp.chk('F7c desestimar dos veces rechazado',
  pg_temp.mensaje('33333333-3333-3333-3333-333333333333',
    format($$SELECT public.desestimar_compra(%L, 'Motivo suficientemente largo')$$, pg_temp.eq('EQ-C'))) ~ 'desestimada');

-- ============ PERMISOS ============
SELECT pg_temp.chk('F8 TECNICO no confirma ni desestima (42501)',
  pg_temp.mensaje('22222222-2222-2222-2222-222222222222',
    format($$SELECT public.confirmar_compra(%L, 'FACTURA', 'F-X', public.hoy_local() - 1, 15)$$, pg_temp.eq('EQ-A'))) ~ 'Solo ADMIN'
  AND pg_temp.mensaje('22222222-2222-2222-2222-222222222222',
    format($$SELECT public.desestimar_compra(%L, 'Motivo suficientemente largo')$$, pg_temp.eq('EQ-A'))) ~ 'Solo ADMIN');
SELECT pg_temp.chk('F8b RECEPCION no confirma ni desestima (42501)',
  pg_temp.mensaje('55555555-5555-5555-5555-555555555555',
    format($$SELECT public.confirmar_compra(%L, 'FACTURA', 'F-X', public.hoy_local() - 1, 15)$$, pg_temp.eq('EQ-A'))) ~ 'Solo ADMIN'
  AND pg_temp.mensaje('55555555-5555-5555-5555-555555555555',
    format($$SELECT public.desestimar_compra(%L, 'Motivo suficientemente largo')$$, pg_temp.eq('EQ-A'))) ~ 'Solo ADMIN');
SELECT pg_temp.chk('F9 anon no puede ninguna de las dos',
  pg_temp.mensaje('anon', $$SELECT public.confirmar_compra(gen_random_uuid(), 'FACTURA', 'X', public.hoy_local(), 7)$$) ~ 'permission denied'
  AND pg_temp.mensaje('anon', $$SELECT public.desestimar_compra(gen_random_uuid(), 'Motivo suficientemente largo')$$) ~ 'permission denied');
