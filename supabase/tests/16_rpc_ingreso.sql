-- Prueba de guardar_cliente, buscar_equipo y registrar_ingreso
-- (Tarea 11 del plan; spec §5.5 y §6).
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

-- Semillas: técnico y admin con mfa; usuario fantasma sin perfil
INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES
 ('11111111-1111-1111-1111-111111111111','admin@primetelecom.com','{}'::jsonb),
 ('22222222-2222-2222-2222-222222222222','tecnico@primetelecom.com','{}'::jsonb),
 ('44444444-4444-4444-4444-444444444444','fantasma@x.com','{}'::jsonb);
DO $$
BEGIN
  IF to_regclass('public.mfa_sesiones') IS NOT NULL THEN
    INSERT INTO public.mfa_sesiones (session_id, user_id)
    SELECT p.id, p.id FROM public.profiles p ON CONFLICT (session_id) DO NOTHING;
  END IF;
END $$;
DELETE FROM public.profiles WHERE email='fantasma@x.com';

CREATE FUNCTION pg_temp.producto_id() RETURNS uuid LANGUAGE sql AS
  $$ SELECT id FROM public.productos WHERE modelo='HG8245' $$;
CREATE FUNCTION pg_temp.producto_id2() RETURNS uuid LANGUAGE sql AS
  $$ SELECT id FROM public.productos WHERE modelo='Archer C6' $$;

-- ============ GUARDAR_CLIENTE ============
SELECT pg_temp.chk('I1 un TECNICO guarda un cliente nuevo',
  public.guardar_cliente('V','12345678','Juan Perez', NULL, NULL, NULL) IS NOT NULL);
SELECT pg_temp.chk('I2 la segunda llamada devuelve EL MISMO cliente',
  public.guardar_cliente('V','12345678','Juan Perez', NULL, NULL, NULL) = public.guardar_cliente('V','12345678','Juan Perez', NULL, NULL, NULL));
SELECT pg_temp.chk('I3 documento de 4 dígitos rechazado (clientes exige 5–15)',
  pg_temp.mensaje('22222222-2222-2222-2222-222222222222',
    $q$SELECT public.guardar_cliente('V','1234','Corto',NULL,NULL,NULL)$q$) ~ 'documento');

-- ============ REGISTRAR_INGRESO (la primera vez, como TECNICO) ============
-- La RPC exige rol del JWT: cada llamada corre como el técnico con su
-- segundo factor ya superado (convenio session_id = id del usuario).
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
SET LOCAL request.jwt.claim.session_id = '22222222-2222-2222-2222-222222222222';
CREATE TEMP TABLE t_ing1 AS
SELECT * FROM public.registrar_ingreso(
    'RT5-8842-AA', pg_temp.producto_id(), public.guardar_cliente('V','12345678','Juan Perez', NULL, NULL, NULL),
    'No enciende, huele a quemado', 'cargador y manual',
    'FACTURA', 'F-200', DATE '2026-09-01', 7, 'Tienda C.C.', NULL, NULL,
    '2026-09-02 14:00+00'::timestamptz);  -- ingresó el 02/09, factura del 01/09 + 7 días
COMMIT;
RESET ROLE;

SELECT pg_temp.chk('I4 TECNICO crea ingreso: equipo, registro y revision de recepcion',
  (SELECT (SELECT count(*) FROM public.equipos e WHERE e.numero_serie='RT5-8842-AA') = 1
      AND (SELECT count(*) FROM public.registros r WHERE r.numero_registro = (SELECT numero_registro FROM t_ing1)) = 1
      AND (SELECT count(*) FROM public.revisiones v WHERE v.registro_id = (SELECT registro_id FROM t_ing1) AND v.tipo='RECEPCION') = 1));
SELECT pg_temp.chk('I5 el TECNICO que registra queda asignado',
  (SELECT tecnico_asignado_id = '22222222-2222-2222-2222-222222222222' FROM public.registros WHERE id = (SELECT registro_id FROM t_ing1)));
SELECT pg_temp.chk('I6 token devuelto de 32 caracteres, guardado solo el hash',
  (SELECT length(consulta_token)=32 FROM t_ing1)
  AND NOT EXISTS (SELECT 1 FROM public.registros r, t_ing1
                  WHERE extensions.digest(t_ing1.consulta_token,'sha256') <> r.consulta_token_hash));
SELECT pg_temp.chk('I7 cobertura = EN_GARANTIA (compra 01/09 + 7 = vence 08/09)',
  (SELECT cobertura::text='EN_GARANTIA' FROM t_ing1));

-- ============ REUTILIZAR EL EQUIPO ============
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
SET LOCAL request.jwt.claim.session_id = '22222222-2222-2222-2222-222222222222';
CREATE TEMP TABLE t_ing2 AS
SELECT * FROM public.registrar_ingreso(
    'RT5 8842 AA', pg_temp.producto_id(), public.guardar_cliente('V','12345678','Juan Perez', NULL, NULL, NULL),
    'Antena floja', NULL, 'FACTURA', 'F-451', DATE '2026-09-10', 15, NULL, NULL, NULL);
COMMIT;
RESET ROLE;
SELECT pg_temp.chk('I8 segundo ingreso con otro formato: equipo_nuevo = false',
  (SELECT NOT equipo_nuevo FROM t_ing2));
SELECT pg_temp.chk('I8b el equipo NO duplica la factura (sigue la original)',
  (SELECT numero_soporte = 'F-200' AND fecha_emision = DATE '2026-09-01' FROM public.equipos
   WHERE id = (SELECT equipo_id FROM t_ing2)));
SELECT pg_temp.chk('I9 dos ingresos seguidos con el mismo serial sin error de unicidad',
  pg_temp.mensaje('22222222-2222-2222-2222-222222222222',
   $$SELECT * FROM public.registrar_ingreso('rt5-8842-aa', pg_temp.producto_id(),
       (SELECT id FROM public.clientes LIMIT 1), 'Chirrido en ventilador', NULL,
       'NOTA_ENTREGA','ND-9','2026-09-20',7,NULL,NULL,NULL)$$) IS NULL);

-- ============ BUSCAR_EQUIPO ============
SELECT pg_temp.chk('B1 buscar_equipo encuentra el equipo en CUALQUIER formato',
  (SELECT count(*) = 1 FROM public.buscar_equipo('rt5  8842-aa')));
INSERT INTO public.equipos (numero_serie, producto_id, cliente_id)
VALUES ('RT5 8842 AA', pg_temp.producto_id2(), (SELECT id FROM public.clientes LIMIT 1));
SELECT pg_temp.chk('B2 mismo serial en dos productos: devuelve AMBAS filas',
  (SELECT count(*) = 2 FROM public.buscar_equipo('RT5-8842-AA')));

-- ============ ATOMICIDAD ============
SELECT pg_temp.chk('D1 un checklist inválido no deja equipo ni registro',
  (pg_temp.mensaje('22222222-2222-2222-2222-222222222222',
     $$SELECT * FROM public.registrar_ingreso('SERIAL-ROTO', pg_temp.producto_id(),
        (SELECT id FROM public.clientes LIMIT 1), 'Falla de prueba', NULL,
        'FACTURA','F-9','2026-09-01',7,NULL,'{"senales":{"golpes":"si"}}',NULL)$$) IS NOT NULL)
  AND (SELECT count(*) FROM public.equipos WHERE numero_serie='SERIAL-ROTO') = 0);

-- ============ SIN FACTURA ============
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
SET LOCAL request.jwt.claim.session_id = '22222222-2222-2222-2222-222222222222';
CREATE TEMP TABLE t_nofact AS
SELECT * FROM public.registrar_ingreso(
    'EQ-SIN-FAC', pg_temp.producto_id(), public.guardar_cliente('V','12345678','Juan Perez', NULL, NULL, NULL),
    'Se reinicia solo', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);
COMMIT;
RESET ROLE;
SELECT pg_temp.chk('F1 sin factura: cobertura POR_DETERMINAR y vence_el NULL',
  (SELECT cobertura::text='POR_DETERMINAR' FROM t_nofact)
  AND (SELECT vence_el IS NULL FROM public.equipos WHERE id=(SELECT equipo_id FROM t_nofact)));

-- ============ MEDIANOCHE EN CARACAS (foco de revisión 3) ============
-- Equipo con vencimiento el 2026-09-03. Ingresando a las 02:30+00 (23:30 en
-- Caracas del día 3) la cobertura debe evaluarse con el día 3: EN_GARANTIA.
-- A las 04:00+00 ya es el día 4: FUERA_DE_GARANTIA.
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
SET LOCAL request.jwt.claim.session_id = '22222222-2222-2222-2222-222222222222';
CREATE TEMP TABLE t_tz1 AS
SELECT * FROM public.registrar_ingreso(
    'TZ-MAÑANA', pg_temp.producto_id(), public.guardar_cliente('V','12345678','Juan Perez', NULL, NULL, NULL),
    'No conecta a internet', NULL, 'FACTURA','TZ-F','2026-08-27',7,NULL,NULL,NULL,
    '2026-09-04 02:30+00'::timestamptz);

CREATE TEMP TABLE t_tz2 AS
SELECT * FROM public.registrar_ingreso(
    'TZ-PASADO', pg_temp.producto_id(), public.guardar_cliente('V','12345678','Juan Perez', NULL, NULL, NULL),
    'No conecta a internet', NULL, 'FACTURA','TZ-F2','2026-08-27',7,NULL,NULL,NULL,
    '2026-09-04 04:00+00'::timestamptz);
COMMIT;
RESET ROLE;
SELECT pg_temp.chk('TZ1 ingreso 02:30+00 evalúa el día 2026-09-03 (EN_GARANTIA)',
  (SELECT cobertura::text='EN_GARANTIA' FROM t_tz1));
SELECT pg_temp.chk('TZ2 ingreso 04:00+00 evalúa el día 2026-09-04 (FUERA_DE_GARANTIA)',
  (SELECT cobertura::text='FUERA_DE_GARANTIA' FROM t_tz2));

-- ============ HISTORIAL EN BUSCAR_EQUIPO ============
SELECT pg_temp.chk('B3 buscar_equipo incluye el historial de registros del equipo',
  (SELECT jsonb_array_length(registros) >= 1
   FROM public.buscar_equipo('RT5-8842-AA')
   WHERE producto_id = pg_temp.producto_id() LIMIT 1));

-- ============ PERMISOS ============
SELECT pg_temp.chk('X1 anon no puede llamar registrar_ingreso',
  pg_temp.mensaje('anon', $$SELECT 1 FROM public.registrar_ingreso('X', pg_temp.producto_id(), NULL, 'falla', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL)$$) ~ 'permission denied');
SELECT pg_temp.chk('X2 usuario sin perfil rechazado (42501)',
  pg_temp.mensaje('44444444-4444-4444-4444-444444444444',
    $$SELECT * FROM public.registrar_ingreso('X-2', pg_temp.producto_id(),
       (SELECT id FROM public.clientes LIMIT 1), 'Falla', NULL, NULL,NULL,NULL,NULL,NULL,NULL,NULL)$$) ~ 'Su rol');
SELECT pg_temp.chk('X3 buscar_equipo también exige sesión interna',
  pg_temp.mensaje('anon', $$SELECT 1 FROM public.buscar_equipo('RT5-8842-AA')$$) ~ 'permission denied');
