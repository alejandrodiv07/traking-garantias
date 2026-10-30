-- Prueba de la tabla `ordenes_servicio` (Tarea 7 del plan; spec §5.2).
-- Portada de los casos que 99_pruebas_seguridad.sql tenía sobre garantías,
-- con los nombres nuevos: ordenes_servicio, historial_ordenes, notas_internas.
\set QUIET on
CREATE OR REPLACE FUNCTION pg_temp.chk(n text, c boolean) RETURNS void
LANGUAGE plpgsql AS $$ BEGIN RAISE NOTICE '%  %', CASE WHEN c THEN 'PASA  ' ELSE '*FALLA*' END, n; END $$;

-- Ejecuta una sentencia bajo una identidad y devuelve TRUE si fue rechazada
-- (por trigger o por RLS: error lanzado, o 0 filas afectadas). Copiada de 97.
CREATE FUNCTION pg_temp.rechazado(uid text, sql text) RETURNS boolean
LANGUAGE plpgsql AS $$
DECLARE n integer;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', uid, TRUE);
  PERFORM set_config('request.jwt.claim.session_id', uid, TRUE);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    EXECUTE sql;
    GET DIAGNOSTICS n = ROW_COUNT;
  EXCEPTION WHEN others THEN
    EXECUTE 'RESET ROLE'; RETURN TRUE;
  END;
  EXECUTE 'RESET ROLE';
  RETURN n = 0;
END $$;
\set QUIET off

-- Semillas: 3 usuarios (el convenio: session_id = id del usuario)
INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES
 ('11111111-1111-1111-1111-111111111111','admin@primetelecom.com','{"full_name":"Ada Admin"}'::jsonb),
 ('22222222-2222-2222-2222-222222222222','tecnico@primetelecom.com','{"full_name":"Tito Tecnico"}'::jsonb),
 ('33333333-3333-3333-3333-333333333333','recep@primetelecom.com','{"full_name":"Rosa Recepcion"}'::jsonb);
-- MFA ya superado para los tres (estas pruebas miden ordenes_servicio/RLS, no el 2FA)
DO $$
BEGIN
  IF to_regclass('public.mfa_sesiones') IS NOT NULL THEN
    INSERT INTO public.mfa_sesiones (session_id, user_id)
    SELECT p.id, p.id FROM public.profiles p
    ON CONFLICT (session_id) DO NOTHING;
  END IF;
END $$;
UPDATE public.profiles SET role='ADMIN'    WHERE email='admin@primetelecom.com';
UPDATE public.profiles SET role='RECEPCION' WHERE email='recep@primetelecom.com';

INSERT INTO public.clientes (tipo_documento, documento, nombre)
VALUES ('V','12345678','Juan Perez');
INSERT INTO public.equipos (numero_serie, producto_id, cliente_id)
SELECT 'RT5-8842-AA', p.id, c.id
FROM public.productos p, public.clientes c
WHERE p.modelo='HG8245' AND c.documento='12345678'
LIMIT 1;

CREATE FUNCTION pg_temp.equipo_id() RETURNS uuid LANGUAGE sql AS
  $$ SELECT id FROM public.equipos LIMIT 1 $$;
CREATE FUNCTION pg_temp.orden_id() RETURNS uuid LANGUAGE sql AS
  $$ SELECT id FROM public.ordenes_servicio ORDER BY fecha_ingreso LIMIT 1 $$;

-- Un registro inicial en estado RECIBIDO (punto de partida de los casos).
-- El hash del token: el RPC real lo genera en la Tarea 11; aquí lo sembramos.
INSERT INTO public.ordenes_servicio (equipo_id, falla_reportada, cobertura, creado_por, tecnico_asignado_id, consulta_token_hash)
VALUES (pg_temp.equipo_id(), 'No enciende, huele a quemado', 'EN_GARANTIA',
        '11111111-1111-1111-1111-111111111111',
        '22222222-2222-2222-2222-222222222222',
        extensions.digest('prueba-1', 'sha256'));
-- La 0017 (spec §4.5) exige la foto de la auditoría de recepción para
-- pasar a EN_DIAGNOSTICO: la orden de estas pruebas de máquina de estados
-- ya la trae (con el patrón de ruta de 15_adjuntos.sql).
INSERT INTO public.adjuntos (orden_id, tipo, etiqueta, ruta, mime, bytes)
SELECT id, 'FOTO', 'recepcion', 'ordenes/' || id || '/archivo-foto-1.png', 'image/png', 1024
  FROM public.ordenes_servicio
 WHERE falla_reportada = 'No enciende, huele a quemado';

-- ============ CORRELATIVO ============
INSERT INTO public.ordenes_servicio (equipo_id, falla_reportada, cobertura, creado_por, consulta_token_hash)
VALUES (pg_temp.equipo_id(), 'Antena floja', 'EN_GARANTIA',
        '11111111-1111-1111-1111-111111111111',
        extensions.digest('prueba-2', 'sha256'));
SELECT pg_temp.chk('C1 formato del código OS-AAAA-NNNN',
  (SELECT numero_orden ~ '^OS-[0-9]{4}-[0-9]{4}$' FROM public.ordenes_servicio LIMIT 1));
-- Aserción nueva del renombre: el DEFAULT de la 0013 genera OS- + año
-- corriente + un tramo NUMÉRICO de 4 dígitos (nada de NNNNNN heredado).
SELECT pg_temp.chk('C1b el DEFAULT genera OS- + año corriente + 4 dígitos',
  (SELECT split_part(numero_orden, '-', 2) = to_char(now(), 'YYYY')
     AND split_part(numero_orden, '-', 3) ~ '^[0-9]{4}$'
   FROM public.ordenes_servicio LIMIT 1));
SELECT pg_temp.chk('C2 dos ordenes_servicio seguidos tienen correlativos distintos',
  (SELECT count(DISTINCT numero_orden) = 2 FROM public.ordenes_servicio));

-- ============ FALLA REPORTADA: 5 a 2000 ============
BEGIN;
INSERT INTO public.ordenes_servicio (equipo_id, falla_reportada, cobertura, creado_por, consulta_token_hash)
VALUES (pg_temp.equipo_id(), 'corto', 'EN_GARANTIA', '11111111-1111-1111-1111-111111111111',
        extensions.digest('prueba-corto', 'sha256'));  -- DEBE FALLAR (5–2000)
ROLLBACK;
SELECT pg_temp.chk('C3 falla de menos de 5 caracteres rechazada',
  (SELECT count(*) FROM public.ordenes_servicio WHERE falla_reportada='corto') = 0);

-- ============ MÁQUINA DE ESTADOS ============
BEGIN;
UPDATE public.ordenes_servicio SET estado='ENTREGADO';  -- RECIBIDO -> ENTREGADO: NO EXISTE
ROLLBACK;
BEGIN;
-- Todas las transiciones se acotan al registro 1: el segundo (del correlativo)
-- permanece RECIBIDO para no engordar el historial que miden S2 y P3.
UPDATE public.ordenes_servicio SET estado='EN_DIAGNOSTICO' WHERE id=pg_temp.orden_id();
SELECT pg_temp.chk('S1 transición válida RECIBIDO -> EN_DIAGNOSTICO aceptada',
  (SELECT estado='EN_DIAGNOSTICO' FROM public.ordenes_servicio WHERE id=pg_temp.orden_id()));
SELECT pg_temp.chk('S2 el historial registra estado_anterior Y estado_nuevo',
  (SELECT count(*)=1 FROM public.historial_ordenes
   WHERE orden_id=pg_temp.orden_id()
     AND estado_anterior='RECIBIDO' AND estado_nuevo='EN_DIAGNOSTICO'));
ROLLBACK;

-- Camino completo hacia la entrega: la fecha se llena sola
BEGIN;
UPDATE public.ordenes_servicio SET estado='EN_DIAGNOSTICO' WHERE id=pg_temp.orden_id();
UPDATE public.ordenes_servicio SET estado='EN_REPARACION'  WHERE id=pg_temp.orden_id();
UPDATE public.ordenes_servicio SET estado='REPARADO'       WHERE id=pg_temp.orden_id();
SELECT pg_temp.chk('S3 llegar a REPARADO por transiciones válidas',
  (SELECT estado='REPARADO' FROM public.ordenes_servicio WHERE id=pg_temp.orden_id()));
UPDATE public.ordenes_servicio SET estado='ENTREGADO' WHERE id=pg_temp.orden_id();
SELECT pg_temp.chk('S4 ENTREGADO lleva su fecha de entrega (la llena el trigger)',
  (SELECT estado='ENTREGADO' AND fecha_entrega IS NOT NULL
   FROM public.ordenes_servicio WHERE id=pg_temp.orden_id()));
ROLLBACK;

-- ============ COHERENCIA DE COBERTURA ============
BEGIN;
UPDATE public.ordenes_servicio SET cobertura='ANULADA_POR_USO';  -- sin motivo: DEBE FALLAR
ROLLBACK;
SELECT pg_temp.chk('G1 cobertura ANULADA exige motivo',
  (SELECT count(*) FROM public.ordenes_servicio WHERE cobertura='ANULADA_POR_USO') = 0);

BEGIN;
UPDATE public.ordenes_servicio SET cobertura='EN_GARANTIA', costo_reparacion=50;  -- cobrar lo cubierto: DEBE FALLAR
ROLLBACK;
SELECT pg_temp.chk('G2 no se cobra reparación con cobertura en garantía',
  (SELECT count(*) FROM public.ordenes_servicio WHERE costo_reparacion IS NOT NULL) = 0);

-- ============ TECNICO: solo lo suyo y abierto ============
SELECT pg_temp.chk('T1 TECNICO asignado SI avanza su registro',
  NOT pg_temp.rechazado('22222222-2222-2222-2222-222222222222',
    $q$SELECT public.cambiar_estado(id, 'EN_DIAGNOSTICO') FROM public.ordenes_servicio
        WHERE tecnico_asignado_id='22222222-2222-2222-2222-222222222222'$q$));
UPDATE public.ordenes_servicio SET tecnico_asignado_id='11111111-1111-1111-1111-111111111111';
SELECT pg_temp.chk('T2 TECNICO NO asignado no modifica (0 filas)',
  pg_temp.rechazado('22222222-2222-2222-2222-222222222222',
    $q$UPDATE public.ordenes_servicio SET estado='EN_DIAGNOSTICO'
        WHERE tecnico_asignado_id='11111111-1111-1111-1111-111111111111'$q$));
UPDATE public.ordenes_servicio SET tecnico_asignado_id='22222222-2222-2222-2222-222222222222';

-- Cerrado ya no se toca: ENTREGADO sale del alcance del técnico
UPDATE public.ordenes_servicio SET estado='EN_DIAGNOSTICO' WHERE id=pg_temp.orden_id();
UPDATE public.ordenes_servicio SET estado='EN_REPARACION'  WHERE id=pg_temp.orden_id();
UPDATE public.ordenes_servicio SET estado='REPARADO'       WHERE id=pg_temp.orden_id();
UPDATE public.ordenes_servicio SET estado='ENTREGADO'      WHERE id=pg_temp.orden_id();
SELECT pg_temp.chk('T3 un registro cerrado ya no lo puede tocar su técnico',
  pg_temp.rechazado('22222222-2222-2222-2222-222222222222',
    $q$UPDATE public.ordenes_servicio SET estado='ANULADO'$q$));

-- ============ NOTAS INTERNAS ============
INSERT INTO public.notas_internas (orden_id, autor_id, nota)
VALUES (pg_temp.orden_id(), '22222222-2222-2222-2222-222222222222', 'Prueba de nota');
SELECT pg_temp.chk('N1 la nota apunta al registro y la escribió su autor',
  (SELECT count(*)=1 FROM public.notas_internas
   WHERE nota='Prueba de nota' AND orden_id=pg_temp.orden_id()));

-- ============ PERMISOS DE MESA ============
BEGIN;
SET ROLE anon;
SELECT count(*) FROM public.ordenes_servicio;  -- DEBE FALLAR
ROLLBACK;
SELECT pg_temp.chk('P1 anon no toca ordenes_servicio',
  (SELECT count(*)=2 FROM public.ordenes_servicio));

SELECT pg_temp.chk('P2 TECNICO no inserta ordenes_servicio directo (solo el RPC)',
  pg_temp.rechazado('22222222-2222-2222-2222-222222222222',
    $q$INSERT INTO public.ordenes_servicio (equipo_id, falla_reportada, cobertura, creado_por)
       VALUES (pg_temp.equipo_id(),'Prueba bypass','EN_GARANTIA', auth.uid())$q$));

BEGIN;
UPDATE public.historial_ordenes SET comentario='falsificado';  -- DEBE FALLAR
ROLLBACK;
BEGIN;
DELETE FROM public.historial_ordenes;  -- DEBE FALLAR
ROLLBACK;
SELECT pg_temp.chk('P3 historial intacto tras UPDATE/DELETE (5 de ESTADO de reg1 + 1 de reg2)',
  -- Con la 0015 el trigger de eventos añade filas BITACORA (las
  -- asignaciones de técnico de T1/T2); el conteo mide el historial de
  -- ESTADOS, que es lo que los intentos de UPDATE/DELETE no deben mover.
  (SELECT count(*)=6 FROM public.historial_ordenes WHERE evento='ESTADO'));

-- ============ P5: UPDATE POR COLUMNA ============
-- El GRANT de UPDATE es por columna: un TECNICO solo toca estado,
-- diagnostico, accesorios, costo_reparacion y recibido_por. La cobertura y
-- su motivo la escriben los triggers de revisiones; el técnico asignado lo
-- fija abrir_orden; la fecha de entrega la llena el trigger de
-- ENTREGADO; creado_por es trazabilidad y no se toca.
-- (Postgres 17 redacta este rechazo como "permission denied for table
-- ordenes_servicio", sin nombrar la columna: el nombre solo llega al mensaje en
-- el SELECT de una columna sin GRANT. La aserción exige el 42501.)
-- Devuelve el SQLERRM de una sentencia bajo una identidad (NULL si pasó).
CREATE FUNCTION pg_temp.error_msg(uid text, sql text) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE
BEGIN
  PERFORM set_config('request.jwt.claim.sub', uid, TRUE);
  PERFORM set_config('request.jwt.claim.session_id', uid, TRUE);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    EXECUTE sql;
    EXECUTE 'RESET ROLE';
    RETURN NULL;
  EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    RETURN SQLERRM;
  END;
END $$;

CREATE TEMP TABLE p5 AS
SELECT t.col, pg_temp.error_msg('22222222-2222-2222-2222-222222222222',
         format('UPDATE public.ordenes_servicio SET %I = %s WHERE id = pg_temp.orden_id()', t.col, t.nuevo)) AS err
  FROM (VALUES ('cobertura',                 '''EN_GARANTIA'''),
               ('motivo_anulacion_cobertura', '''uso indebido del equipo'''),
               ('creado_por',               'auth.uid()'),
               ('tecnico_asignado_id',      'auth.uid()'),
               ('fecha_entrega',            'now()')) AS t(col, nuevo);
SELECT pg_temp.chk('P5 las columnas criticas rechazan el UPDATE del TECNICO (permission denied)',
  (SELECT bool_and(err ~* 'permission denied') FROM p5));

-- ============ P6: SIN PERFIL NO VE NADA ============
-- Un autenticado SIN perfil (mi_rol() NULL) nació viendo todo el tablero
-- con las policies USING (TRUE). Ahora las tres exigen rol interno.
-- Usuario fantasma: lo creamos y retiramos su perfil (sin perfil no hay
-- mfa, así que mi_rol() queda NULL por partida doble).
INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES
 ('44444444-4444-4444-4444-444444444444','fantasma@x.com','{}'::jsonb);
DELETE FROM public.profiles WHERE email='fantasma@x.com';

-- Ejecuta un SELECT count(*), en la sesión del usuario dado.
CREATE FUNCTION pg_temp.filas(uid text, sql text) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE n bigint;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', uid, TRUE);
  PERFORM set_config('request.jwt.claim.session_id', uid, TRUE);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    EXECUTE sql INTO n;
  EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE'; RETURN -1;
  END;
  EXECUTE 'RESET ROLE';
  RETURN n;
END $$;

SELECT pg_temp.chk('P6 un usuario SIN perfil no ve ordenes_servicio, historial ni notas (RLS)',
  pg_temp.filas('44444444-4444-4444-4444-444444444444', 'SELECT count(*) FROM public.ordenes_servicio') = 0
  AND pg_temp.filas('44444444-4444-4444-4444-444444444444', 'SELECT count(*) FROM public.historial_ordenes') = 0
  AND pg_temp.filas('44444444-4444-4444-4444-444444444444', 'SELECT count(*) FROM public.notas_internas') = 0);

-- ============ CONSULTA PÚBLICA: consultar_registro (Tarea 8) ============
-- Portados de los casos T11 del 99 anterior (consultar_garantia).
-- Las aserciones van envueltas en helpers que CONSERVAN el estado del
-- error: si la función no existiera aún, el chk se pintaría FALLA y no
-- un error silencioso (la ausencia no puede pasar por implementado).

-- Ejecuta un SELECT count y devuelve el entero, o -1 si falló algo.
CREATE FUNCTION pg_temp.filas_o_error(q text) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE r int;
BEGIN
  EXECUTE q INTO r; RETURN r;
EXCEPTION WHEN OTHERS THEN RETURN -1;
END $$;

-- Ejecuta una sentencia y devuelve el SQLSTATE del error que lanzó, o NULL.
CREATE FUNCTION pg_temp.error_estado(q text) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE
BEGIN
  EXECUTE q; RETURN NULL;
EXCEPTION WHEN OTHERS THEN
  RETURN SQLSTATE;
END $$;

BEGIN;
-- El número se lee ANTES de cambiar de rol: anon no lee la tabla, solo la RPC.
SELECT format('SELECT count(*) FROM public.consultar_registro(%L, ''prueba-1'')', numero_orden) AS pub_q,
       format('SELECT count(*) FROM public.consultar_registro(%L, ''0000000000000000000000000000dead'')', numero_orden) AS pub_qmal
FROM public.ordenes_servicio ORDER BY fecha_ingreso LIMIT 1 \gset
SET ROLE anon;
SELECT pg_temp.chk('K1 consulta pública con token correcto devuelve 1 fila',
  pg_temp.filas_o_error(:'pub_q') = 1);
SELECT pg_temp.chk('K2 token incorrecto devuelve CERO filas (anti-enumeración)',
  pg_temp.filas_o_error(:'pub_qmal') = 0);
RESET ROLE;
COMMIT;

-- Anti-enumeración: ningún parámetro de salida expone datos internos
SELECT pg_temp.chk('K3 la respuesta pública NO expone cedula/correo/costo/tecnico/notas',
  NOT EXISTS (
    SELECT 1 FROM information_schema.parameters
     WHERE specific_schema='public' AND parameter_mode='OUT'
       AND specific_name IN (SELECT specific_name FROM information_schema.routines
                              WHERE routine_schema='public' AND routine_name='consultar_registro')
       AND parameter_name ~* 'documento|email|costo|tecnico|nota|cliente'));

-- Freno de fuerza bruta: 10 fallos en la ventana y la IP queda bloqueada
INSERT INTO public.consulta_publica_intentos (ip, numero_orden, exito)
SELECT '10.5.0.9', 'OS-XXXX-000099', FALSE FROM generate_series(1,10);
SELECT set_config('request.headers', '{"x-forwarded-for":"10.5.0.9"}', false);
SELECT pg_temp.chk('K4 la consulta desde una IP bloqueada se rechaza con 53400',
  pg_temp.error_estado('SELECT * FROM public.consultar_registro(''OS-XXXX-000099'',''tok-consulta'')') = '53400');
SELECT pg_temp.chk('K5 el intento fallido quedó registrado en la bitácora',
  (SELECT count(*)>=2 FROM public.consulta_publica_intentos WHERE NOT exito));
