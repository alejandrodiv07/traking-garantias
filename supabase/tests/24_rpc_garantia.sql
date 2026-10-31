-- Prueba de registrar_garantia y buscar_equipo multicriterio
-- (Tarea 8 de la fase 2a; spec §4.1 y §6; migración 0018).
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
CREATE FUNCTION pg_temp.producto_id2() RETURNS uuid LANGUAGE sql AS
  $$ SELECT id FROM public.productos WHERE modelo='Archer C6' $$;
CREATE FUNCTION pg_temp.cliente_id() RETURNS uuid LANGUAGE sql AS
  $$ SELECT id FROM public.clientes WHERE documento='12345678' $$;
\set QUIET off

-- Semillas: un usuario por rol interno (todos con segundo factor en banda).
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

INSERT INTO public.clientes (tipo_documento, documento, nombre, email, telefono)
VALUES ('V','12345678','Juan Perez','juan@ejemplo.com','04141234567');

-- ============ REGISTRAR_GARANTIA ============
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
SET LOCAL request.jwt.claim.session_id = '22222222-2222-2222-2222-222222222222';
CREATE TEMP TABLE t_g1 AS
SELECT * FROM public.registrar_garantia(
    pg_temp.cliente_id(), pg_temp.producto_id(), 'RT5-8842-AA',
    'FACTURA', 'F-100', public.hoy_local() - 2, 7);
COMMIT;
RESET ROLE;

SELECT pg_temp.chk('G1 TECNICO con plazo 7 crea la garantía de origen VENTA, sin orden',
  (SELECT (SELECT equipo_nuevo FROM t_g1)
      AND (SELECT vence_el FROM t_g1) = public.hoy_local() + 5
      AND (SELECT origen::text FROM public.equipos WHERE id = (SELECT equipo_id FROM t_g1)) = 'VENTA'
      AND (SELECT registrado_por FROM public.equipos WHERE id = (SELECT equipo_id FROM t_g1))
          = '22222222-2222-2222-2222-222222222222'
      AND (SELECT count(*) FROM public.ordenes_servicio) = 0));

SELECT pg_temp.chk('G2 TECNICO con plazo 30 rechazado (42501)',
  pg_temp.mensaje('22222222-2222-2222-2222-222222222222',
    $$SELECT * FROM public.registrar_garantia(pg_temp.cliente_id(), pg_temp.producto_id(),
        'SN-PLAZO-T','FACTURA','F-101', public.hoy_local(), 30)$$) ~ 'plazos distintos');
SELECT pg_temp.chk('G3 RECEPCION con plazo 30 rechazado (42501)',
  pg_temp.mensaje('55555555-5555-5555-5555-555555555555',
    $$SELECT * FROM public.registrar_garantia(pg_temp.cliente_id(), pg_temp.producto_id(),
        'SN-PLAZO-R','FACTURA','F-102', public.hoy_local(), 30)$$) ~ 'plazos distintos');
SELECT pg_temp.chk('G3b el rechazo no deja equipo',
  (SELECT count(*) FROM public.equipos WHERE numero_serie IN ('SN-PLAZO-T','SN-PLAZO-R')) = 0);
SELECT pg_temp.chk('G4 JEFE_SERVICIO con plazo 30 aceptado',
  pg_temp.mensaje('33333333-3333-3333-3333-333333333333',
    $$SELECT * FROM public.registrar_garantia(pg_temp.cliente_id(), pg_temp.producto_id(),
        'SN-PLAZO-J','FACTURA','F-103', public.hoy_local(), 30)$$) IS NULL);
SELECT pg_temp.chk('G4a el equipo del jefe quedó con plazo 30',
  (SELECT plazo_dias FROM public.equipos WHERE numero_serie='SN-PLAZO-J') = 30);
SELECT pg_temp.chk('G4b ADMIN con plazo 45 aceptado',
  pg_temp.mensaje('11111111-1111-1111-1111-111111111111',
    $$SELECT * FROM public.registrar_garantia(pg_temp.cliente_id(), pg_temp.producto_id(),
        'SN-PLAZO-A','FACTURA','F-104', public.hoy_local(), 45)$$) IS NULL);

BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '55555555-5555-5555-5555-555555555555';
SET LOCAL request.jwt.claim.session_id = '55555555-5555-5555-5555-555555555555';
CREATE TEMP TABLE t_g5 AS
SELECT * FROM public.registrar_garantia(
    pg_temp.cliente_id(), pg_temp.producto_id(), 'rt5 8842 aa',
    'FACTURA', 'F-999', public.hoy_local(), 15);
COMMIT;
RESET ROLE;
SELECT pg_temp.chk('G5 repetir el serial (otro formato) devuelve el mismo equipo y no lo pisa',
  (SELECT NOT equipo_nuevo AND equipo_id = (SELECT equipo_id FROM t_g1) FROM t_g5)
  AND (SELECT numero_soporte FROM public.equipos WHERE id = (SELECT equipo_id FROM t_g1)) = 'F-100');

BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '55555555-5555-5555-5555-555555555555';
SET LOCAL request.jwt.claim.session_id = '55555555-5555-5555-5555-555555555555';
CREATE TEMP TABLE t_g6 AS
SELECT * FROM public.registrar_garantia(
    pg_temp.cliente_id(), pg_temp.producto_id(), 'SN-TALLER-1',
    'FACTURA', 'F-TALLER', public.hoy_local() - 1, 7, 'TALLER');
COMMIT;
RESET ROLE;
SELECT pg_temp.chk('G6 origen TALLER queda sin confirmar y sin orden',
  (SELECT e.origen::text = 'TALLER' AND e.compra_confirmada_por IS NULL
     FROM public.equipos e WHERE e.id = (SELECT equipo_id FROM t_g6))
  AND (SELECT count(*) FROM public.ordenes_servicio) = 0);

SELECT pg_temp.chk('G7 origen inválido rechazado (22P02)',
  pg_temp.mensaje('22222222-2222-2222-2222-222222222222',
    $$SELECT * FROM public.registrar_garantia(pg_temp.cliente_id(), pg_temp.producto_id(),
        'SN-ORIGEN','FACTURA','F-105', public.hoy_local(), 7, 'OTRO')$$) ~ 'origen');
SELECT pg_temp.chk('G7b serial de 2 caracteres rechazado (22P02)',
  pg_temp.mensaje('22222222-2222-2222-2222-222222222222',
    $$SELECT * FROM public.registrar_garantia(pg_temp.cliente_id(), pg_temp.producto_id(),
        'AB','FACTURA','F-106', public.hoy_local(), 7)$$) ~ 'serial');
SELECT pg_temp.chk('G7c soporte incompleto (número sin fecha ni plazo) rechazado',
  pg_temp.mensaje('22222222-2222-2222-2222-222222222222',
    $$SELECT * FROM public.registrar_garantia(pg_temp.cliente_id(), pg_temp.producto_id(),
        'SN-INCOMPLETO','FACTURA','F-107', NULL, NULL)$$) IS NOT NULL);
SELECT pg_temp.chk('G7d garantía sin soporte permitida (POR_DETERMINAR luego)',
  pg_temp.mensaje('22222222-2222-2222-2222-222222222222',
    $$SELECT * FROM public.registrar_garantia(pg_temp.cliente_id(), pg_temp.producto_id(),
        'SN-SIN-FACTURA')$$) IS NULL);
SELECT pg_temp.chk('G8 anon no puede registrar_garantia',
  pg_temp.mensaje('anon',
    $$SELECT * FROM public.registrar_garantia(pg_temp.cliente_id(), pg_temp.producto_id(),
        'SN-ANON','FACTURA','F-108', public.hoy_local(), 7)$$) ~ 'permission denied');

-- ============ BUSCAR_EQUIPO ============
-- Una orden abierta del primer equipo (INSERT directo: esta prueba no
-- depende de la firma de abrir_orden, que cambia en la 0019).
INSERT INTO public.ordenes_servicio (equipo_id, falla_reportada, creado_por, consulta_token_hash)
VALUES ((SELECT equipo_id FROM t_g1), 'No enciende el equipo',
        '22222222-2222-2222-2222-222222222222', '\x01');
-- Mismo serial en OTRO producto.
INSERT INTO public.equipos (numero_serie, producto_id, cliente_id)
VALUES ('RT5 8842 AA', pg_temp.producto_id2(), pg_temp.cliente_id());

SELECT pg_temp.chk('K1 por serial en cualquier formato (en dos productos: ambas filas)',
  (SELECT count(*) = 2 FROM public.buscar_equipo(p_serial => 'rt5  8842-aa')));
SELECT pg_temp.chk('K2 por documento del titular devuelve sus equipos',
  (SELECT count(DISTINCT equipo_id) >= 5 FROM public.buscar_equipo(p_documento => '12345678')));
SELECT pg_temp.chk('K3 por factura (sin importar mayúsculas ni espacios)',
  (SELECT count(*) = 1 AND min(numero_serie) = 'RT5-8842-AA'
     FROM public.buscar_equipo(p_factura => ' f-100 ')));
SELECT pg_temp.chk('K4 por número de orden exacto',
  (SELECT count(*) = 1 AND min(numero_serie) = 'RT5-8842-AA'
     FROM public.buscar_equipo(p_orden => (SELECT numero_orden FROM public.ordenes_servicio LIMIT 1))));
SELECT pg_temp.chk('K5 criterio inexistente: 0 filas',
  (SELECT count(*) = 0 FROM public.buscar_equipo(p_serial => 'NO-EXISTE-999')));
SELECT pg_temp.chk('K6 sin criterios: 0 filas',
  (SELECT count(*) = 0 FROM public.buscar_equipo()));
SELECT pg_temp.chk('K7 dos criterios que apuntan al mismo equipo no lo duplican',
  (SELECT count(*) = 1 FROM public.buscar_equipo(p_serial => 'SN-TALLER-1', p_factura => 'F-TALLER')));

SELECT pg_temp.chk('K11 devuelve el tipo de documento del titular (V-12345678)',
  (SELECT bool_and(tipo_documento::text = 'V') FROM public.buscar_equipo(p_documento => '12345678')));

SELECT pg_temp.chk('K8 equipo de VENTA con factura vigente: EN_GARANTIA y compra CONFIRMADA',
  (SELECT vigencia::text = 'EN_GARANTIA' AND estado_compra = 'CONFIRMADA'
     FROM public.buscar_equipo(p_serial => 'RT5-8842-AA') WHERE producto_id = pg_temp.producto_id()));
SELECT pg_temp.chk('K9 equipo de TALLER sin confirmar: POR_DETERMINAR y compra PENDIENTE',
  (SELECT vigencia::text = 'POR_DETERMINAR' AND estado_compra = 'PENDIENTE'
     FROM public.buscar_equipo(p_serial => 'SN-TALLER-1')));
INSERT INTO public.equipos (numero_serie, producto_id, cliente_id, tipo_soporte, numero_soporte, fecha_emision, plazo_dias)
VALUES ('SN-VENCIDA', pg_temp.producto_id(), pg_temp.cliente_id(), 'FACTURA', 'F-OLD', DATE '2026-01-10', 7);
SELECT pg_temp.chk('K10 factura vencida: FUERA_DE_GARANTIA y días restantes negativos',
  (SELECT vigencia::text = 'FUERA_DE_GARANTIA' AND dias_restantes < 0
     FROM public.buscar_equipo(p_serial => 'SN-VENCIDA')));
UPDATE public.equipos
   SET compra_desestimada_por = (SELECT id FROM public.profiles WHERE email='admin@primetelecom.com'),
       compra_desestimada_en = now(),
       compra_desestimada_motivo = 'El titular nunca compro esta unidad'
 WHERE numero_serie = 'SN-TALLER-1';
SELECT pg_temp.chk('K11 compra desestimada: FUERA_DE_GARANTIA, DESESTIMADA y trae el motivo',
  (SELECT vigencia::text = 'FUERA_DE_GARANTIA' AND estado_compra = 'DESESTIMADA'
          AND motivo_desestimacion = 'El titular nunca compro esta unidad'
     FROM public.buscar_equipo(p_serial => 'SN-TALLER-1')));
SELECT pg_temp.chk('K12 trae titular, correo, teléfono y las órdenes del equipo',
  (SELECT titular = 'Juan Perez' AND email = 'juan@ejemplo.com' AND telefono = '04141234567'
          AND jsonb_array_length(ordenes) = 1
          AND ordenes->0->>'numero_orden' LIKE 'OS-%'
          AND ordenes->0->>'tipo_atencion' IN ('GARANTIA','PAGO','PENDIENTE')
     FROM public.buscar_equipo(p_serial => 'RT5-8842-AA') WHERE producto_id = pg_temp.producto_id()));

SELECT pg_temp.chk('K13 anon no puede buscar_equipo',
  pg_temp.mensaje('anon', $$SELECT 1 FROM public.buscar_equipo(p_serial => 'RT5-8842-AA')$$) ~ 'permission denied');
SELECT pg_temp.chk('K14 usuario interno (RECEPCION) sí puede',
  pg_temp.mensaje('55555555-5555-5555-5555-555555555555',
    $$SELECT 1 FROM public.buscar_equipo(p_serial => 'RT5-8842-AA')$$) IS NULL);

-- ============ V_GARANTIAS (tablero de garantías) ============
SELECT pg_temp.chk('V1 v_garantias: una fila por equipo con vigencia y estado de compra',
  (SELECT count(*) = (SELECT count(*) FROM public.equipos) FROM public.v_garantias)
  AND (SELECT vigencia::text = 'EN_GARANTIA' AND estado_compra = 'CONFIRMADA'
              AND titular = 'Juan Perez' AND documento = '12345678' AND origen::text = 'VENTA'
         FROM public.v_garantias
        WHERE numero_serie = 'RT5-8842-AA' AND producto_id = pg_temp.producto_id()));
SELECT pg_temp.chk('V2 v_garantias: anon no ve nada',
  pg_temp.mensaje('anon', $$SELECT 1 FROM public.v_garantias$$) ~ 'permission denied');
