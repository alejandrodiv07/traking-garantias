-- Prueba de registrar_revision, confirmar_compra y la matriz de permisos
-- (Tarea 12 del plan; spec §5.5 y §6).
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
 ('11111111-1111-1111-1111-111111111111','admin@primetelecom.com',   '{}'::jsonb),
 ('22222222-2222-2222-2222-222222222222','tecnico@primetelecom.com', '{}'::jsonb),
 ('33333333-3333-3333-3333-333333333333','recep@primetelecom.com',   '{}'::jsonb),
 ('55555555-5555-5555-5555-555555555555','jefe@primetelecom.com',    '{}'::jsonb),
 ('44444444-4444-4444-4444-444444444444','fantasma@x.com',           '{}'::jsonb);
DO $$
BEGIN
  IF to_regclass('public.mfa_sesiones') IS NOT NULL THEN
    INSERT INTO public.mfa_sesiones (session_id, user_id)
    SELECT p.id, p.id FROM public.profiles p ON CONFLICT (session_id) DO NOTHING;
  END IF;
END $$;
DELETE FROM public.profiles WHERE email='fantasma@x.com';
UPDATE public.profiles SET role='ADMIN'          WHERE email='admin@primetelecom.com';
UPDATE public.profiles SET role='RECEPCION'      WHERE email='recep@primetelecom.com';
UPDATE public.profiles SET role='JEFE_SERVICIO'  WHERE email='jefe@primetelecom.com';

CREATE FUNCTION pg_temp.producto_id() RETURNS uuid LANGUAGE sql AS
  $$ SELECT id FROM public.productos WHERE modelo='HG8245' $$;
CREATE FUNCTION pg_temp.cliente_id() RETURNS uuid LANGUAGE sql AS
  $$ SELECT id FROM public.clientes WHERE documento='12345678' $$;
INSERT INTO public.clientes (tipo_documento, documento, nombre) VALUES ('V','12345678','Juan Perez');

CREATE FUNCTION pg_temp.checklist_ok() RETURNS jsonb LANGUAGE sql AS $$
  SELECT '{"condiciones":{"factura_presentada":true,"titular_coincide":true},
           "equipo":{"serial_legible":true,"caja_original":true,"precintos_intactos":true,"contenido_completo":true},
           "senales":{"descarga_electrica":false,"liquidos":false,"altas_temperaturas":false,"golpes":false,"manipulacion_terceros":false}}'::jsonb $$;
CREATE FUNCTION pg_temp.checklist_golpes() RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_set(pg_temp.checklist_ok(), '{senales,golpes}', 'true') $$;

-- Registrar un ingreso bajo una identidad; devuelve 'OK' o 'ERROR: …'
CREATE FUNCTION pg_temp.crear_como(uid text, serie text, con_factura boolean) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE v text;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', uid, TRUE);
  PERFORM set_config('request.jwt.claim.session_id', uid, TRUE);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    IF con_factura THEN
      SELECT 'OK:' || cobertura::text INTO v
        FROM public.abrir_orden(serie, pg_temp.producto_id(), pg_temp.cliente_id(),
             'Falla de prueba del equipo', NULL, 'FACTURA', 'MF-1',
             DATE '2026-09-01', 7, NULL, NULL, NULL, '2026-09-02 14:00+00'::timestamptz);
    ELSE
      SELECT 'OK:' || cobertura::text INTO v
        FROM public.abrir_orden(serie, pg_temp.producto_id(), pg_temp.cliente_id(),
             'Falla de prueba del equipo', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
             '2026-09-02 14:00+00'::timestamptz);
    END IF;
  EXCEPTION WHEN OTHERS THEN v := 'ERROR: ' || SQLERRM;
  END;
  EXECUTE 'RESET ROLE';
  RETURN v;
END $$;

-- Registrar una revisión bajo una identidad
CREATE FUNCTION pg_temp.rev_como(uid text, reg uuid, tipo text, ck jsonb) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE v text;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', uid, TRUE);
  PERFORM set_config('request.jwt.claim.session_id', uid, TRUE);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    SELECT 'OK:' || cobertura::text INTO v
      FROM public.registrar_revision(reg, tipo, ck, NULL);
  EXCEPTION WHEN OTHERS THEN v := 'ERROR: ' || SQLERRM;
  END;
  EXECUTE 'RESET ROLE';
  RETURN v;
END $$;

-- Confirmar la compra de un equipo bajo una identidad
CREATE FUNCTION pg_temp.confirmar_como(uid text, eq uuid, fecha date, plazo integer) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE v text;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', uid, TRUE);
  PERFORM set_config('request.jwt.claim.session_id', uid, TRUE);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    SELECT 'OK' INTO v
      FROM public.confirmar_compra(eq, 'FACTURA', 'CF-1', fecha, plazo);
  EXCEPTION WHEN OTHERS THEN v := 'ERROR: ' || SQLERRM;
  END;
  EXECUTE 'RESET ROLE';
  RETURN v;
END $$;

-- ============ C1: CREAR REGISTRO — permitido a los CUATRO roles ============
-- OJO: el AND de SQL no garantiza orden de evaluación; la creación y la
-- comprobación van en aserciones separadas (el subselect debe ver lo
-- creado antes).
SELECT pg_temp.chk('C1 ADMIN crea registro',      pg_temp.crear_como('11111111-1111-1111-1111-111111111111','M-ADMIN-1', TRUE) ~ '^OK:EN_GARANTIA');
SELECT pg_temp.chk('C1b JEFE-SERVICIO crea',      pg_temp.crear_como('55555555-5555-5555-5555-555555555555','M-JEFE-1', TRUE) ~ '^OK');
SELECT pg_temp.chk('C1c TECNICO crea',            pg_temp.crear_como('22222222-2222-2222-2222-222222222222','M-TEC-1', TRUE) ~ '^OK');
SELECT pg_temp.chk('C1c y queda asignado al técnico',
  (SELECT tecnico_asignado_id='22222222-2222-2222-2222-222222222222'
   FROM public.ordenes_servicio JOIN public.equipos ON equipos.id=ordenes_servicio.equipo_id
   WHERE equipos.numero_serie='M-TEC-1'));
SELECT pg_temp.chk('C1d RECEPCION crea',          pg_temp.crear_como('33333333-3333-3333-3333-333333333333','M-REC-1', TRUE) ~ '^OK');
SELECT pg_temp.chk('C1d y sin técnico asignado',
  (SELECT tecnico_asignado_id IS NULL
   FROM public.ordenes_servicio JOIN public.equipos ON equipos.id=ordenes_servicio.equipo_id
   WHERE equipos.numero_serie='M-REC-1'));

-- ============ C2–C3: REVISIONES sobre el registro del ADMIN ============
CREATE FUNCTION pg_temp.reg_admin() RETURNS uuid LANGUAGE sql AS
  $$ SELECT r.id FROM public.ordenes_servicio r JOIN public.equipos e ON e.id=r.equipo_id
     WHERE e.numero_serie='M-ADMIN-1' $$;

SELECT pg_temp.chk('C2 ADMIN deja la revisión técnica',
  pg_temp.rev_como('11111111-1111-1111-1111-111111111111', pg_temp.reg_admin(),
                   'TECNICA', pg_temp.checklist_golpes()) ~ '^OK:ANULADA_POR_USO');
SELECT pg_temp.chk('C3 receppcion NO puede revisar',
  pg_temp.rev_como('33333333-3333-3333-3333-333333333333', pg_temp.reg_admin(),
                   'TECNICA', pg_temp.checklist_ok()) ~ 'no puede registrar revisiones');

-- El Jefe y el Técnico SÍ revisan
SELECT pg_temp.chk('C4 el Jefe registra revisión limpia: vuelve a EN_GARANTIA',
  pg_temp.rev_como('55555555-5555-5555-5555-555555555555', pg_temp.reg_admin(),
                   'TECNICA', pg_temp.checklist_ok()) ~ '^OK:EN_GARANTIA');
SELECT pg_temp.chk('C5 la revisión con golpes sigue guardada (solo anexar)',
  (SELECT count(*)=3 FROM public.revisiones WHERE orden_id=pg_temp.reg_admin()));
SELECT pg_temp.chk('C6 el motivo quedó limpio al volver a EN_GARANTIA',
  (SELECT cobertura::text='EN_GARANTIA' AND motivo_anulacion_cobertura IS NULL
   FROM public.ordenes_servicio WHERE id=pg_temp.reg_admin()));
-- por el TÉCNICO, con su registro asignado
-- C7: el TECNICO revisa SU registro. El resultado ya no es ANULADA_POR_USO
-- (D4/3): la fecha que el TECNICO mandó en crear_como se le ignora, el
-- registro entró HOY (fecha=now()) y la factura fija MF-1 (01/09 + 7 =
-- vence 08/09) lleva meses vencida → FUERA_DE_GARANTIA. La revisión de su
-- propio registro sí fue aceptada; la regla de golpes→ANULADA la cubre C2.
SELECT pg_temp.chk('C7 TECNICO hace revisión de su propio registro',
  pg_temp.rev_como('22222222-2222-2222-2222-222222222222',
                   (SELECT r.id FROM public.ordenes_servicio r JOIN public.equipos e ON e.id=r.equipo_id WHERE e.numero_serie='M-TEC-1'),
                   'TECNICA', pg_temp.checklist_golpes()) ~ '^OK:FUERA_DE_GARANTIA');

-- ============ C8: CONFIRMAR COMPRA ============
-- Registro sin factura: M-REC... no; creamos uno nuevo SIN factura
SELECT pg_temp.crear_como('11111111-1111-1111-1111-111111111111','SIN-FAC-1', FALSE);
CREATE FUNCTION pg_temp.eq_sinfac() RETURNS uuid LANGUAGE sql AS
  $$ SELECT id FROM public.equipos WHERE numero_serie='SIN-FAC-1' $$;
SELECT pg_temp.chk('C8 sin factura quedó POR_DETERMINAR',
  (SELECT cobertura::text='POR_DETERMINAR' FROM public.ordenes_servicio
   WHERE equipo_id=pg_temp.eq_sinfac() LIMIT 1));

SELECT pg_temp.chk('C9 confirmar_compra solo ADMIN (TÉCNICO rechazado)',
  pg_temp.confirmar_como('22222222-2222-2222-2222-222222222222', pg_temp.eq_sinfac(), DATE '2026-08-28', 7) ~* 'solo');
SELECT pg_temp.chk('C9b RECEPCION también rechazada',
  pg_temp.confirmar_como('33333333-3333-3333-3333-333333333333', pg_temp.eq_sinfac(), DATE '2026-08-28', 7) ~* 'solo');

SELECT pg_temp.chk('C10 ADMIN confirma la compra',
  pg_temp.confirmar_como('11111111-1111-1111-1111-111111111111', pg_temp.eq_sinfac(), DATE '2026-08-28', 7) = 'OK');
SELECT pg_temp.chk('C10b datos llenos, con quién y cuándo',
  (SELECT numero_soporte='CF-1' AND fecha_emision=DATE '2026-08-28'
          AND plazo_dias=7 AND vence_el=DATE '2026-09-04'
          AND compra_confirmada_en IS NOT NULL AND compra_confirmada_por IS NOT NULL
       FROM public.equipos WHERE id=pg_temp.eq_sinfac()));
-- El registro abierto del equipo pasará de POR_DETERMINAR a su cobertura real:
-- ingresó el 02/09 con vencimiento 04/09 → EN_GARANTIA
SELECT pg_temp.chk('C11 los ordenes_servicio abiertos pasaron a cobertura real',
  (SELECT cobertura::text='EN_GARANTIA' FROM public.ordenes_servicio
   WHERE equipo_id=pg_temp.eq_sinfac() LIMIT 1));

BEGIN;
UPDATE public.equipos SET numero_soporte='F-OTRA', fecha_emision=DATE '2026-09-10', plazo_dias=15
 WHERE id=pg_temp.eq_sinfac();
ROLLBACK;  -- confirmar de nuevo: DEBE FALLAR por la función
SELECT pg_temp.chk('C12 confirmar_compra sobre equipo con factura rechazado',
  pg_temp.confirmar_como('11111111-1111-1111-1111-111111111111', pg_temp.eq_sinfac(), DATE '2026-09-10', 15) ~ 'ya tiene');

-- ============ A: ANON rechazado en todo ============
SELECT pg_temp.chk('X1 anon no puede nada de esto',
  pg_temp.mensaje('anon', $$SELECT 1 FROM public.abrir_orden('X', pg_temp.producto_id(), pg_temp.cliente_id(), 'falla', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL)$$) ~ 'permission denied'
  AND pg_temp.mensaje('anon', $$SELECT 1 FROM public.registrar_revision(pg_temp.reg_admin(), 'TECNICA', pg_temp.checklist_ok(), NULL)$$) ~ 'permission denied'
  AND pg_temp.mensaje('anon', $$SELECT 1 FROM public.confirmar_compra(pg_temp.eq_sinfac(), 'FACTURA','C','2026-08-28',7)$$) ~ 'permission denied');