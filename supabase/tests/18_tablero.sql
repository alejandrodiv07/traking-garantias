-- Prueba de la vista `v_tablero` (Tarea 13 del plan; spec §4.5, §4.6 y §5.6).
\set QUIET on
CREATE OR REPLACE FUNCTION pg_temp.chk(n text, c boolean) RETURNS void
LANGUAGE plpgsql AS $$ BEGIN RAISE NOTICE '%  %', CASE WHEN c THEN 'PASA  ' ELSE '*FALLA*' END, n; END $$;

CREATE FUNCTION pg_temp.mensaje(uid text, sql text) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE
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
\set QUIET off

INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES
 ('11111111-1111-1111-1111-111111111111','admin@primetelecom.com','{}'::jsonb),
 ('22222222-2222-2222-2222-222222222222','tecnico@primetelecom.com','{}'::jsonb);
DO $$
BEGIN
  IF to_regclass('public.mfa_sesiones') IS NOT NULL THEN
    INSERT INTO public.mfa_sesiones (session_id, user_id)
    SELECT p.id, p.id FROM public.profiles p ON CONFLICT (session_id) DO NOTHING;
  END IF;
END $$;
UPDATE public.profiles SET role='ADMIN' WHERE email='admin@primetelecom.com';
INSERT INTO public.clientes (tipo_documento, documento, nombre) VALUES ('V','12345678','Juan Perez');

CREATE FUNCTION pg_temp.producto_id() RETURNS uuid LANGUAGE sql AS
  $$ SELECT id FROM public.productos WHERE modelo='HG8245' $$;
CREATE FUNCTION pg_temp.cliente_id() RETURNS uuid LANGUAGE sql AS
  $$ SELECT id FROM public.clientes WHERE documento='12345678' $$;
CREATE FUNCTION pg_temp.checklist_ok() RETURNS jsonb LANGUAGE sql AS $$
  SELECT '{"condiciones":{"factura_presentada":true,"titular_coincide":true},
           "equipo":{"serial_legible":true,"caja_original":true,"precintos_intactos":true,"contenido_completo":true},
           "senales":{"descarga_electrica":false,"liquidos":false,"altas_temperaturas":false,"golpes":false,"manipulacion_terceros":false}}'::jsonb $$;

-- ============ SEMILLA ============
-- Cada caso: (serie, emision, plazo, ingreso) → nivel esperado.
--   vigencia: 8→NORMAL 7→PRONTO 4→PRONTO 3→CRITICA 1→CRITICA 0→HOY −1→VENCIDA sin fecha→PENDIENTE
-- Con fecha_ingreso fija de HOY (mediodía local), la vigencia manda y el
-- SLA es NORMAL (0 días en taller).
DO $$
DECLARE
  hoy date := public.hoy_local();
  mediodia timestamptz := (((hoy)::text || ' 12:00')::timestamp) AT TIME ZONE 'America/Caracas';
BEGIN
  EXECUTE 'SET LOCAL ROLE authenticated';
  PERFORM set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', TRUE);
  PERFORM set_config('request.jwt.claim.session_id', '11111111-1111-1111-1111-111111111111', TRUE);

  -- SIN FACTURA → PENDIENTE
  PERFORM public.test_ingreso('TAB-VP', pg_temp.producto_id(), pg_temp.cliente_id(),
    'Falla del tablero en el equipo', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);

  -- Con factura: (serie, emision, plazo)
  PERFORM public.test_ingreso('TAB-V8', pg_temp.producto_id(), pg_temp.cliente_id(),
    'Falla del tablero en el equipo', NULL, 'FACTURA', 'F-V8', hoy, 8, NULL, NULL, NULL, mediodia);
  PERFORM public.test_ingreso('TAB-V7', pg_temp.producto_id(), pg_temp.cliente_id(),
    'Falla del tablero en el equipo', NULL, 'FACTURA', 'F-V7', hoy, 7, NULL, NULL, NULL, mediodia);
  PERFORM public.test_ingreso('TAB-V4', pg_temp.producto_id(), pg_temp.cliente_id(),
    'Falla del tablero en el equipo', NULL, 'FACTURA', 'F-V4', hoy, 4, NULL, NULL, NULL, mediodia);
  PERFORM public.test_ingreso('TAB-V3', pg_temp.producto_id(), pg_temp.cliente_id(),
    'Falla del tablero en el equipo', NULL, 'FACTURA', 'F-V3', hoy, 3, NULL, NULL, NULL, mediodia);
  PERFORM public.test_ingreso('TAB-V1', pg_temp.producto_id(), pg_temp.cliente_id(),
    'Falla del tablero en el equipo', NULL, 'FACTURA', 'F-V1', hoy, 1, NULL, NULL, NULL, mediodia);
  PERFORM public.test_ingreso('TAB-V0', pg_temp.producto_id(), pg_temp.cliente_id(),
    'Falla del tablero en el equipo', NULL, 'FACTURA', 'F-V0', hoy - 1, 1, NULL, NULL, NULL, mediodia);
  PERFORM public.test_ingreso('TAB-Vm1', pg_temp.producto_id(), pg_temp.cliente_id(),
    'Falla del tablero en el equipo', NULL, 'FACTURA', 'F-Vm1', hoy - 2, 1, NULL, NULL, NULL, mediodia);
  EXECUTE 'RESET ROLE';
END $$;

-- ============ NIVELES DE VIGENCIA ============
DO $$
DECLARE
  caso RECORD;
BEGIN
  FOR caso IN SELECT * FROM (VALUES
    ('TAB-V8',  'NORMAL'),   ('TAB-V7', 'PRONTO'),  ('TAB-V4', 'PRONTO'),
    ('TAB-V3',  'CRITICA'),  ('TAB-V1', 'CRITICA'), ('TAB-V0', 'HOY'),
    ('TAB-Vm1', 'VENCIDA'),  ('TAB-VP', 'PENDIENTE')) t(serie, nivel)
  LOOP
    PERFORM pg_temp.chk('Nivel vigencia ' || caso.serie || ' → ' || caso.nivel,
      (SELECT nivel_vigencia = caso.nivel FROM public.v_tablero WHERE serial = caso.serie));
  END LOOP;
END $$;

-- ============ NIVELES DE SLA: 6→NORMAL, 7→ALERTA, 14→ALERTA, 15→CRÍTICO ============
DO $$
DECLARE
  hoy date := public.hoy_local();
  caso RECORD;
BEGIN
  EXECUTE 'SET LOCAL ROLE authenticated';
  PERFORM set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', TRUE);
  PERFORM set_config('request.jwt.claim.session_id', '11111111-1111-1111-1111-111111111111', TRUE);
  FOR caso IN SELECT * FROM (VALUES
    ('SLA6',  6,  'NORMAL'), ('SLA7',  7,  'ALERTA'),
    ('SLA14', 14, 'ALERTA'), ('SLA15', 15, 'CRITICO')) t(serie, dias, nivel)
  LOOP
    -- el taller le lleva `dias` días: ingresa `dias` días atrás (mediodía, para
    -- fijar el día local exacto). Con factura vigente: cobertura EN_GARANTIA —
    -- la 0017 (spec §4.5) solo deja reparar a un servicio GARANTIA desde
    -- EN_DIAGNOSTICO, y TAB-SLA15 se cierra al final de este archivo.
    PERFORM public.test_ingreso('TAB-' || caso.serie, pg_temp.producto_id(), pg_temp.cliente_id(),
      'Falla del tablero en el equipo', NULL, 'FACTURA', 'F-' || caso.serie, hoy, 365,
      NULL, NULL, NULL,
      ((((public.hoy_local() - caso.dias)::text) || ' 12:00')::timestamp AT TIME ZONE 'America/Caracas'));
    PERFORM pg_temp.chk('Nivel SLA ' || caso.serie || ' (' || caso.dias || ' días) → ' || caso.nivel,
      (SELECT nivel_sla = caso.nivel FROM public.v_tablero WHERE serial = 'TAB-' || caso.serie));
  END LOOP;
  EXECUTE 'RESET ROLE';
END $$;

-- ============ CASO DEL SPEC §4.6: la urgencia combinada ============
-- El técnico recién ingresado con garantía vencida (FUERA_DE_GARANTIA)
-- NO desplaza al que lleva 15 días en taller EN_GARANTIA:
--   rank(FRESH-VENCIDO) = 0   (cobertura FUERA: la vigencia no cuenta)
--   rank(SLA15)         = 2   (SLA crítico)
DO $$
DECLARE
  hoy date := public.hoy_local();
  rank_fresco integer;
  rank_pateado integer;
BEGIN
  EXECUTE 'SET LOCAL ROLE authenticated';
  PERFORM set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', TRUE);
  PERFORM set_config('request.jwt.claim.session_id', '11111111-1111-1111-1111-111111111111', TRUE);
  -- recién ingresado, garantía vencida hace 2 días
  PERFORM public.test_ingreso('SPEC-FRESH', pg_temp.producto_id(), pg_temp.cliente_id(),
    'Falla del tablero en el equipo', NULL, 'FACTURA', 'F-SF', hoy - 2, 1, NULL, NULL, NULL, ((((hoy)::text) || ' 12:00')::timestamp AT TIME ZONE 'America/Caracas'));
  -- 15 días en taller, en garantía
  PERFORM public.test_ingreso('SPEC-SLA15', pg_temp.producto_id(), pg_temp.cliente_id(),
    'Falla del tablero en el equipo', NULL, 'FACTURA', 'F-S15', hoy, 15, NULL, NULL, NULL,
    ((((public.hoy_local() - 15)::text) || ' 12:00')::timestamp AT TIME ZONE 'America/Caracas'));
  SELECT urgencia_rank INTO rank_fresco FROM public.v_tablero WHERE serial='SPEC-FRESH';
  SELECT urgencia_rank INTO rank_pateado FROM public.v_tablero WHERE serial='SPEC-SLA15';
  PERFORM pg_temp.chk('El recién ingresado fuera de garantía NO desplaza al de 15 días en taller',
    rank_fresco < rank_pateado);
  PERFORM pg_temp.chk('el rank del fresco con garantía vencida es 0 (informativo)',
    rank_fresco = 0);
  EXECUTE 'RESET ROLE';
END $$;

-- Cerrado: ENTREGADO sale del alcance del Tablero (rank −1). La fecha de
-- entrega NO se fija a mano (el UPDATE por columnas ya no la permite): la
-- llena el trigger del estado ENTREGADO con now(). Para que
-- fecha_entrega >= fecha_ingreso no dependa de la hora de la corrida, se
-- cierra el registro con 15 días en taller (ingresó el mediodía de hace
-- 15 días: now() siempre le lleva horas de ventaja).
-- La 0017 (spec §4.5) exige la foto de la auditoría de recepción para que
-- la orden avance a EN_DIAGNOSTICO: se sube antes del cierre.
INSERT INTO public.adjuntos (orden_id, tipo, etiqueta, ruta, mime, bytes)
SELECT r.id, 'FOTO', 'recepcion', 'ordenes/' || r.id || '/archivo-foto-1.png', 'image/png', 1024
  FROM public.ordenes_servicio r
  JOIN public.equipos e ON e.id = r.equipo_id
 WHERE e.numero_serie = 'TAB-SLA15';
DO $$
BEGIN
  EXECUTE 'SET LOCAL ROLE authenticated';
  PERFORM set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', TRUE);
  PERFORM set_config('request.jwt.claim.session_id', '11111111-1111-1111-1111-111111111111', TRUE);
  PERFORM public.cambiar_estado((SELECT r.id FROM public.ordenes_servicio r JOIN public.equipos e ON e.id=r.equipo_id WHERE e.numero_serie='TAB-SLA15'), 'EN_DIAGNOSTICO');
  PERFORM public.cambiar_estado((SELECT r.id FROM public.ordenes_servicio r JOIN public.equipos e ON e.id=r.equipo_id WHERE e.numero_serie='TAB-SLA15'), 'EN_REPARACION');
  PERFORM public.cambiar_estado((SELECT r.id FROM public.ordenes_servicio r JOIN public.equipos e ON e.id=r.equipo_id WHERE e.numero_serie='TAB-SLA15'), 'REPARADO');
  PERFORM public.cambiar_estado((SELECT r.id FROM public.ordenes_servicio r JOIN public.equipos e ON e.id=r.equipo_id WHERE e.numero_serie='TAB-SLA15'), 'ENTREGADO');
  EXECUTE 'RESET ROLE';
END $$;
SELECT pg_temp.chk('el cierre sin fecha a mano respeta entrega >= ingreso',
  (SELECT fecha_entrega >= fecha_ingreso FROM public.ordenes_servicio r
    JOIN public.equipos e ON e.id = r.equipo_id WHERE e.numero_serie='TAB-SLA15'));
SELECT pg_temp.chk('cerrado ENTREGADO tiene rank -1',
  (SELECT urgencia_rank = -1 FROM public.v_tablero WHERE serial='TAB-SLA15'));
SELECT pg_temp.chk('cerrado ENTREGADO con abierto = false',
  (SELECT NOT abierto FROM public.v_tablero WHERE serial='TAB-SLA15'));

-- ============ PERMISOS ============
SELECT pg_temp.chk('X1 anon no lee la vista',
  pg_temp.mensaje('anon', $$SELECT count(*) FROM public.v_tablero$$) IS NOT NULL);
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
SET LOCAL request.jwt.claim.session_id = '22222222-2222-2222-2222-222222222222';
SELECT pg_temp.chk('X2 un TECNICO ve los 14 ordenes_servicio del taller',
  (SELECT count(*) = 14 FROM public.v_tablero));
COMMIT;
SELECT pg_temp.chk('X3 la vista tiene las columnas del tablero (18, con numero_soporte)',
  (SELECT count(*) = 18 FROM information_schema.columns
   WHERE table_schema='public' AND table_name='v_tablero'
     AND column_name IN ('orden_id','numero_orden','estado','estado_nombre','cobertura',
                         'serial','producto','cliente','documento','fecha_ingreso','vence_el',
                         'dias_restantes','nivel_vigencia','dias_en_taller','nivel_sla',
                         'numero_soporte','urgencia_rank','abierto')));