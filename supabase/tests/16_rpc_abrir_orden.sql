-- Prueba de guardar_cliente, buscar_equipo y abrir_orden
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
-- El de 1111 entra como ADMIN (mfa en banda): estos ficheros miden el RPC,
-- no la promoción (eso es 97/98). TZ necesita un ADMIN de veras.
UPDATE public.profiles SET role='ADMIN' WHERE email='admin@primetelecom.com';

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
SELECT * FROM public.abrir_orden(
    'RT5-8842-AA', pg_temp.producto_id(), public.guardar_cliente('V','12345678','Juan Perez', NULL, NULL, NULL),
    'No enciende, huele a quemado', 'cargador y manual',
    'FACTURA', 'F-200', DATE '2026-09-01', 7, 'Tienda C.C.', NULL, NULL,
    '2026-09-02 14:00+00'::timestamptz);  -- la fecha la manda EL ADMIN únicamente: al TECNICO se le ignora
COMMIT;
RESET ROLE;

SELECT pg_temp.chk('I4 TECNICO crea ingreso: equipo, registro y revision de recepcion',
  (SELECT (SELECT count(*) FROM public.equipos e WHERE e.numero_serie='RT5-8842-AA') = 1
      AND (SELECT count(*) FROM public.ordenes_servicio r WHERE r.numero_orden = (SELECT numero_orden FROM t_ing1)) = 1
      AND (SELECT count(*) FROM public.revisiones v WHERE v.orden_id = (SELECT orden_id FROM t_ing1) AND v.tipo='RECEPCION') = 1));
SELECT pg_temp.chk('I5 el TECNICO que registra queda asignado',
  (SELECT tecnico_asignado_id = '22222222-2222-2222-2222-222222222222' FROM public.ordenes_servicio WHERE id = (SELECT orden_id FROM t_ing1)));
SELECT pg_temp.chk('I6 token devuelto de 32 caracteres, guardado solo el hash',
  (SELECT length(consulta_token)=32 FROM t_ing1)
  AND NOT EXISTS (SELECT 1 FROM public.ordenes_servicio r, t_ing1
                  WHERE extensions.digest(t_ing1.consulta_token,'sha256') <> r.consulta_token_hash));
SELECT pg_temp.chk('I7 la fecha pedida por el TECNICO se ignora (factura vieja + fecha de hoy: FUERA)',
  (SELECT cobertura::text='FUERA_DE_GARANTIA' FROM t_ing1));

-- ============ REUTILIZAR EL EQUIPO ============
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
SET LOCAL request.jwt.claim.session_id = '22222222-2222-2222-2222-222222222222';
CREATE TEMP TABLE t_ing2 AS
SELECT * FROM public.abrir_orden(
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
   $$SELECT * FROM public.abrir_orden('rt5-8842-aa', pg_temp.producto_id(),
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
     $$SELECT * FROM public.abrir_orden('SERIAL-ROTO', pg_temp.producto_id(),
        (SELECT id FROM public.clientes LIMIT 1), 'Falla de prueba', NULL,
        'FACTURA','F-9','2026-09-01',7,NULL,'{"senales":{"golpes":"si"}}',NULL)$$) IS NOT NULL)
  AND (SELECT count(*) FROM public.equipos WHERE numero_serie='SERIAL-ROTO') = 0);

-- ============ SIN FACTURA ============
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
SET LOCAL request.jwt.claim.session_id = '22222222-2222-2222-2222-222222222222';
CREATE TEMP TABLE t_nofact AS
SELECT * FROM public.abrir_orden(
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
-- La fecha de ingreso la manda solo el ADMIN (backoffice, corrida a media
-- noche): los demás roles reciben el DEFAULT now() y no pueden cambiarla.
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
SET LOCAL request.jwt.claim.session_id = '11111111-1111-1111-1111-111111111111';
CREATE TEMP TABLE t_tz1 AS
SELECT * FROM public.abrir_orden(
    'TZ-MAÑANA', pg_temp.producto_id(), public.guardar_cliente('V','12345678','Juan Perez', NULL, NULL, NULL),
    'No conecta a internet', NULL, 'FACTURA','TZ-F','2026-08-27',7,NULL,NULL,NULL,
    '2026-09-04 02:30+00'::timestamptz);

CREATE TEMP TABLE t_tz2 AS
SELECT * FROM public.abrir_orden(
    'TZ-PASADO', pg_temp.producto_id(), public.guardar_cliente('V','12345678','Juan Perez', NULL, NULL, NULL),
    'No conecta a internet', NULL, 'FACTURA','TZ-F2','2026-08-27',7,NULL,NULL,NULL,
    '2026-09-04 04:00+00'::timestamptz);
COMMIT;
RESET ROLE;
SELECT pg_temp.chk('TZ1 ingreso 02:30+00 evalúa el día 2026-09-03 (EN_GARANTIA)',
  (SELECT cobertura::text='EN_GARANTIA' FROM t_tz1));
SELECT pg_temp.chk('TZ2 ingreso 04:00+00 evalúa el día 2026-09-04 (FUERA_DE_GARANTIA)',
  (SELECT cobertura::text='FUERA_DE_GARANTIA' FROM t_tz2));

-- TZ3: un TECNICO manda una fecha pasada: se le IGNORA (silencioso) y el
-- registro queda con fecha_ingreso ≈ now().
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
SET LOCAL request.jwt.claim.session_id = '22222222-2222-2222-2222-222222222222';
CREATE TEMP TABLE t_tz3 AS
SELECT * FROM public.abrir_orden(
    'TZ-TECNICO', pg_temp.producto_id(), public.guardar_cliente('V','12345678','Juan Perez', NULL, NULL, NULL),
    'No conecta a internet', NULL, 'FACTURA','TZ-F3','2026-08-27',7,NULL,NULL,NULL,
    '2026-08-27 14:00+00'::timestamptz);
COMMIT;
RESET ROLE;
SELECT pg_temp.chk('TZ3 la fecha pasada del TECNICO se ignora: queda fecha_ingreso ≈ now()',
  (SELECT r.fecha_ingreso >= now() - interval '1 minute'
     AND r.fecha_ingreso <= now() + interval '5 seconds'
     FROM public.ordenes_servicio r WHERE r.id = (SELECT orden_id FROM t_tz3)));

-- ============ HISTORIAL EN BUSCAR_EQUIPO ============
SELECT pg_temp.chk('B3 buscar_equipo incluye el historial de ordenes_servicio del equipo',
  (SELECT jsonb_array_length(ordenes_servicio) >= 1
   FROM public.buscar_equipo('RT5-8842-AA')
   WHERE producto_id = pg_temp.producto_id() LIMIT 1));

-- ============ PERMISOS ============
SELECT pg_temp.chk('X1 anon no puede llamar abrir_orden',
  pg_temp.mensaje('anon', $$SELECT 1 FROM public.abrir_orden('X', pg_temp.producto_id(), NULL, 'falla', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL)$$) ~ 'permission denied');
SELECT pg_temp.chk('X2 usuario sin perfil rechazado (42501)',
  pg_temp.mensaje('44444444-4444-4444-4444-444444444444',
    $$SELECT * FROM public.abrir_orden('X-2', pg_temp.producto_id(),
       (SELECT id FROM public.clientes LIMIT 1), 'Falla', NULL, NULL,NULL,NULL,NULL,NULL,NULL,NULL)$$) ~ 'Su rol');
SELECT pg_temp.chk('X3 buscar_equipo también exige sesión interna',
  pg_temp.mensaje('anon', $$SELECT 1 FROM public.buscar_equipo('RT5-8842-AA')$$) ~ 'permission denied');

-- ============ IDEMPOTENCIA (clave de envío) ============
-- Un doble clic o un reintento tras un timeout manda la MISMA clave: debe
-- devolver el registro original, no crear otro. El token en claro solo
-- existe en la primera respuesta (la base guarda únicamente el hash).
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
SET LOCAL request.jwt.claim.session_id = '22222222-2222-2222-2222-222222222222';
CREATE TEMP TABLE t_k1 AS
SELECT * FROM public.abrir_orden(
    'IDEM-001', pg_temp.producto_id(), public.guardar_cliente('V','12345678','Juan Perez', NULL, NULL, NULL),
    'No enciende', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
CREATE TEMP TABLE t_k2 AS
SELECT * FROM public.abrir_orden(
    'IDEM-001', pg_temp.producto_id(), public.guardar_cliente('V','12345678','Juan Perez', NULL, NULL, NULL),
    'No enciende', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
COMMIT;
RESET ROLE;
SELECT pg_temp.chk('K1 misma clave dos veces: el MISMO registro',
  (SELECT k1.orden_id = k2.orden_id AND k1.numero_orden = k2.numero_orden
     FROM t_k1 k1, t_k2 k2));
SELECT pg_temp.chk('K2 la repetición no crea otro registro ni otra revisión',
  (SELECT count(*) FROM public.ordenes_servicio WHERE id = (SELECT orden_id FROM t_k1)) = 1
  AND (SELECT count(*) FROM public.ordenes_servicio r JOIN public.equipos e ON e.id = r.equipo_id
        WHERE e.numero_serie = 'IDEM-001') = 1
  AND (SELECT count(*) FROM public.revisiones WHERE orden_id = (SELECT orden_id FROM t_k1)) = 1);
SELECT pg_temp.chk('K3 la primera respuesta trae el token; la repetición NO (solo existe el hash)',
  (SELECT length(consulta_token) = 32 FROM t_k1) AND (SELECT consulta_token IS NULL FROM t_k2));
SELECT pg_temp.chk('K4 la repetición conserva cobertura y equipo del original',
  (SELECT k1.equipo_id = k2.equipo_id AND k1.cobertura = k2.cobertura AND NOT k2.equipo_nuevo
     FROM t_k1 k1, t_k2 k2));

-- Otra clave = otro envío legítimo (p. ej. un segundo ingreso del mismo equipo)
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
SET LOCAL request.jwt.claim.session_id = '22222222-2222-2222-2222-222222222222';
CREATE TEMP TABLE t_k3 AS
SELECT * FROM public.abrir_orden(
    'IDEM-001', pg_temp.producto_id(), public.guardar_cliente('V','12345678','Juan Perez', NULL, NULL, NULL),
    'Otra falla distinta', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
    'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb');
COMMIT;
RESET ROLE;
SELECT pg_temp.chk('K5 clave distinta: registro nuevo',
  (SELECT k3.orden_id <> k1.orden_id FROM t_k3 k3, t_k1 k1));

-- La clave pertenece a quien la usó: otro usuario con la misma clave NO recibe el registro ajeno
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
SET LOCAL request.jwt.claim.session_id = '11111111-1111-1111-1111-111111111111';
CREATE TEMP TABLE t_k4 AS
SELECT * FROM public.abrir_orden(
    'IDEM-001', pg_temp.producto_id(), (SELECT id FROM public.clientes LIMIT 1),
    'Falla del admin', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
COMMIT;
RESET ROLE;
SELECT pg_temp.chk('K6 la misma clave de OTRO usuario crea su propio registro (no filtra el ajeno)',
  (SELECT k4.orden_id <> k1.orden_id FROM t_k4 k4, t_k1 k1)
  AND (SELECT creado_por = '11111111-1111-1111-1111-111111111111'
         FROM public.ordenes_servicio WHERE id = (SELECT orden_id FROM t_k4)));

-- Sin clave (NULL) se conserva el comportamiento anterior: cada llamada es un registro
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
SET LOCAL request.jwt.claim.session_id = '22222222-2222-2222-2222-222222222222';
CREATE TEMP TABLE t_n1 AS
SELECT * FROM public.abrir_orden(
    'IDEM-NULL', pg_temp.producto_id(), public.guardar_cliente('V','12345678','Juan Perez', NULL, NULL, NULL),
    'Sin clave uno', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);
CREATE TEMP TABLE t_n2 AS
SELECT * FROM public.abrir_orden(
    'IDEM-NULL', pg_temp.producto_id(), public.guardar_cliente('V','12345678','Juan Perez', NULL, NULL, NULL),
    'Sin clave dos', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);
COMMIT;
RESET ROLE;
SELECT pg_temp.chk('K7 sin clave: dos llamadas = dos ordenes_servicio (compatibilidad)',
  (SELECT n1.orden_id <> n2.orden_id FROM t_n1 n1, t_n2 n2));
