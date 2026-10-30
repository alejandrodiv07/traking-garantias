-- Prueba de la tabla `equipos` y `normalizar_serie` (Tarea 6 del plan; spec §5.1).
\set QUIET on
CREATE OR REPLACE FUNCTION pg_temp.chk(n text, c boolean) RETURNS void
LANGUAGE plpgsql AS $$ BEGIN RAISE NOTICE '%  %', CASE WHEN c THEN 'PASA  ' ELSE '*FALLA*' END, n; END $$;
\set QUIET off

INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES
 ('22222222-2222-2222-2222-222222222222','tecnico@primetelecom.com','{"full_name":"Tito Tecnico"}'::jsonb);
DO $$
BEGIN
  IF to_regclass('public.mfa_sesiones') IS NOT NULL THEN
    INSERT INTO public.mfa_sesiones (session_id, user_id)
    VALUES ('22222222-2222-2222-2222-222222222222','22222222-2222-2222-2222-222222222222');
  END IF;
END $$;
INSERT INTO public.clientes (tipo_documento, documento, nombre)
VALUES ('V','12345678','Juan Perez');

\set QUIET on
-- Productos fijos por modelo: los del seed comparten created_at, y un
-- ORDER BY por created_at no es determinista para OFFSET 1.
CREATE FUNCTION pg_temp.producto_id() RETURNS uuid LANGUAGE sql AS
  $$ SELECT id FROM public.productos WHERE modelo='HG8245' $$;
CREATE FUNCTION pg_temp.producto_id2() RETURNS uuid LANGUAGE sql AS
  $$ SELECT id FROM public.productos WHERE modelo='Archer C6' $$;
CREATE FUNCTION pg_temp.cliente_id() RETURNS uuid LANGUAGE sql AS
  $$ SELECT id FROM public.clientes LIMIT 1 $$;
\set QUIET off

-- ============ NORMALIZAR SERIE ============
SELECT pg_temp.chk('E1 rt5-8842-aa == RT5 8842 AA',
  public.normalizar_serie('rt5-8842-aa') = public.normalizar_serie('RT5 8842 AA'));
SELECT pg_temp.chk('E2 00123 != 123 (los ceros a la izquierda cuentan)',
  public.normalizar_serie('00123') <> public.normalizar_serie('123'));
SELECT pg_temp.chk('E3 normalizar no borra los guiones internos del serial',
  public.normalizar_serie('RT5 8842 AA') = 'RT58842AA');

-- ============ VALIDACIONES DE SERIE ============
BEGIN;
INSERT INTO public.equipos (numero_serie, producto_id, cliente_id)
VALUES (NULL, pg_temp.producto_id(), pg_temp.cliente_id());  -- DEBE FALLAR
ROLLBACK;
SELECT pg_temp.chk('E4 sin serie rechazado', (SELECT count(*) FROM public.equipos) = 0);

BEGIN;
INSERT INTO public.equipos (numero_serie, producto_id, cliente_id)
VALUES ('AB', pg_temp.producto_id(), pg_temp.cliente_id());  -- 2 caracteres: DEBE FALLAR
ROLLBACK;
SELECT pg_temp.chk('E5 serie de 2 caracteres rechazada', (SELECT count(*) FROM public.equipos) = 0);

BEGIN;
INSERT INTO public.equipos (numero_serie, producto_id, cliente_id)
VALUES (repeat('X',61), pg_temp.producto_id(), pg_temp.cliente_id());  -- 61: DEBE FALLAR
ROLLBACK;
SELECT pg_temp.chk('E6 serie de 61 caracteres rechazada', (SELECT count(*) FROM public.equipos) = 0);

-- ============ UNICIDAD POR PRODUCTO ============
INSERT INTO public.equipos (numero_serie, producto_id, cliente_id)
VALUES ('rt5-8842-aa', pg_temp.producto_id(), pg_temp.cliente_id());
SELECT pg_temp.chk('E7 primer equipo aceptado',
  (SELECT count(*) FROM public.equipos) = 1);

BEGIN;
INSERT INTO public.equipos (numero_serie, producto_id, cliente_id)
VALUES ('RT5 8842 AA', pg_temp.producto_id(), pg_temp.cliente_id());  -- mismo producto: DEBE FALLAR
ROLLBACK;
SELECT pg_temp.chk('E8 misma serie normalizada y mismo producto rechazado',
  (SELECT count(*) FROM public.equipos) = 1);

INSERT INTO public.equipos (numero_serie, producto_id, cliente_id)
VALUES ('RT5 8842 AA', pg_temp.producto_id2(), pg_temp.cliente_id());
SELECT pg_temp.chk('E9 mismo serial en OTRO producto: permitido',
  (SELECT count(*) FROM public.equipos) = 2);

-- ============ VENCIMIENTO GENERADO ============
INSERT INTO public.equipos (numero_serie, producto_id, cliente_id,
  tipo_soporte, numero_soporte, fecha_emision, plazo_dias)
VALUES ('EQ-FAC-001', pg_temp.producto_id(), pg_temp.cliente_id(),
  'FACTURA', 'F-777', DATE '2026-09-01', 7);
SELECT pg_temp.chk('E10 vence_el = fecha_emision + plazo (2026-09-01 + 7 = 09-08)',
  (SELECT vence_el = DATE '2026-09-08' FROM public.equipos WHERE numero_serie='EQ-FAC-001'));

-- ============ PLAZO Y FECHAS ============
BEGIN;
INSERT INTO public.equipos (numero_serie, producto_id, cliente_id, tipo_soporte, numero_soporte, fecha_emision, plazo_dias)
VALUES ('EQ-P0', pg_temp.producto_id(), pg_temp.cliente_id(), 'FACTURA','F-1', DATE '2026-09-01', 0);  -- DEBE FALLAR
ROLLBACK;
SELECT pg_temp.chk('E11 plazo 0 rechazado', (SELECT count(*) FROM public.equipos WHERE numero_serie='EQ-P0') = 0);

BEGIN;
INSERT INTO public.equipos (numero_serie, producto_id, cliente_id, tipo_soporte, numero_soporte, fecha_emision, plazo_dias)
VALUES ('EQ-P366', pg_temp.producto_id(), pg_temp.cliente_id(), 'FACTURA','F-1', DATE '2026-09-01', 366);  -- DEBE FALLAR
ROLLBACK;
SELECT pg_temp.chk('E12 plazo 366 rechazado', (SELECT count(*) FROM public.equipos WHERE numero_serie='EQ-P366') = 0);

BEGIN;
INSERT INTO public.equipos (numero_serie, producto_id, cliente_id, tipo_soporte, numero_soporte, fecha_emision)
VALUES ('EQ-SP', pg_temp.producto_id(), pg_temp.cliente_id(), 'FACTURA','F-1', DATE '2026-09-01');  -- sin plazo: DEBE FALLAR
ROLLBACK;
SELECT pg_temp.chk('E13 fecha de emision sin plazo rechazada (van juntos)',
  (SELECT count(*) FROM public.equipos WHERE numero_serie='EQ-SP') = 0);

BEGIN;
INSERT INTO public.equipos (numero_serie, producto_id, cliente_id, tipo_soporte, numero_soporte, fecha_emision, plazo_dias)
VALUES ('EQ-VIEJA', pg_temp.producto_id(), pg_temp.cliente_id(), 'FACTURA','F-1', DATE '1999-12-31', 15);  -- DEBE FALLAR
ROLLBACK;
SELECT pg_temp.chk('E14 fecha anterior a 2000-01-01 rechazada',
  (SELECT count(*) FROM public.equipos WHERE numero_serie='EQ-VIEJA') = 0);

BEGIN;
INSERT INTO public.equipos (numero_serie, producto_id, cliente_id, tipo_soporte, numero_soporte, fecha_emision, plazo_dias)
VALUES ('EQ-FUT', pg_temp.producto_id(), pg_temp.cliente_id(), 'FACTURA','F-1', DATE '2099-01-01', 15);  -- DEBE FALLAR
ROLLBACK;
SELECT pg_temp.chk('E15 fecha de emision futura rechazada',
  (SELECT count(*) FROM public.equipos WHERE numero_serie='EQ-FUT') = 0);

INSERT INTO public.equipos (numero_serie, producto_id, cliente_id)
VALUES ('EQ-NOSOP', pg_temp.producto_id(), pg_temp.cliente_id());
SELECT pg_temp.chk('E16 sin soporte: tipos, numero, fecha, plazo y vence vacias',
  (SELECT tipo_soporte IS NULL AND numero_soporte IS NULL
          AND fecha_emision IS NULL AND plazo_dias IS NULL AND vence_el IS NULL
   FROM public.equipos WHERE numero_serie='EQ-NOSOP'));

-- ============ PERMISOS ============
BEGIN;
SET ROLE anon;
SELECT count(*) FROM public.equipos;  -- DEBE FALLAR
ROLLBACK;
BEGIN;
SET ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
SET LOCAL request.jwt.claim.session_id = '22222222-2222-2222-2222-222222222222';
SELECT pg_temp.chk('E17 un rol interno SI lee equipos',
  (SELECT count(*) >= 4 FROM public.equipos));
BEGIN;
INSERT INTO public.equipos (numero_serie, producto_id, cliente_id)
VALUES ('EQ-BYPASS', pg_temp.producto_id(), pg_temp.cliente_id());  -- sin GRANT: DEBE FALLAR
ROLLBACK;
COMMIT;
SELECT pg_temp.chk('E18 ningún rol interno inserta equipos directo',
  (SELECT count(*) FROM public.equipos WHERE numero_serie='EQ-BYPASS') = 0);