-- Prueba de la tabla `registros` (Tarea 7 del plan; spec §5.2).
-- Portada de los casos que 99_pruebas_seguridad.sql tenía sobre garantías,
-- con los nombres nuevos: registros, historial_registros, notas_internas.
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
-- MFA ya superado para los tres (estas pruebas miden registros/RLS, no el 2FA)
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
CREATE FUNCTION pg_temp.registro_id() RETURNS uuid LANGUAGE sql AS
  $$ SELECT id FROM public.registros ORDER BY fecha_ingreso LIMIT 1 $$;

-- Un registro inicial en estado RECIBIDO (punto de partida de los casos).
-- El hash del token: el RPC real lo genera en la Tarea 11; aquí lo sembramos.
INSERT INTO public.registros (equipo_id, falla_reportada, cobertura, creado_por, tecnico_asignado_id, consulta_token_hash)
VALUES (pg_temp.equipo_id(), 'No enciende, huele a quemado', 'EN_GARANTIA',
        '11111111-1111-1111-1111-111111111111',
        '22222222-2222-2222-2222-222222222222',
        extensions.digest('prueba-1', 'sha256'));

-- ============ CORRELATIVO ============
INSERT INTO public.registros (equipo_id, falla_reportada, cobertura, creado_por, consulta_token_hash)
VALUES (pg_temp.equipo_id(), 'Antena floja', 'EN_GARANTIA',
        '11111111-1111-1111-1111-111111111111',
        extensions.digest('prueba-2', 'sha256'));
SELECT pg_temp.chk('C1 formato del código REG-AAAA-NNNNNN',
  (SELECT numero_registro ~ '^REG-[0-9]{4}-[0-9]{6}$' FROM public.registros LIMIT 1));
SELECT pg_temp.chk('C2 dos registros seguidos tienen correlativos distintos',
  (SELECT count(DISTINCT numero_registro) = 2 FROM public.registros));

-- ============ FALLA REPORTADA: 5 a 2000 ============
BEGIN;
INSERT INTO public.registros (equipo_id, falla_reportada, cobertura, creado_por, consulta_token_hash)
VALUES (pg_temp.equipo_id(), 'corto', 'EN_GARANTIA', '11111111-1111-1111-1111-111111111111',
        extensions.digest('prueba-corto', 'sha256'));  -- DEBE FALLAR (5–2000)
ROLLBACK;
SELECT pg_temp.chk('C3 falla de menos de 5 caracteres rechazada',
  (SELECT count(*) FROM public.registros WHERE falla_reportada='corto') = 0);

-- ============ MÁQUINA DE ESTADOS ============
BEGIN;
UPDATE public.registros SET estado='ENTREGADO';  -- RECIBIDO -> ENTREGADO: NO EXISTE
ROLLBACK;
BEGIN;
-- Todas las transiciones se acotan al registro 1: el segundo (del correlativo)
-- permanece RECIBIDO para no engordar el historial que miden S2 y P3.
UPDATE public.registros SET estado='EN_DIAGNOSTICO' WHERE id=pg_temp.registro_id();
SELECT pg_temp.chk('S1 transición válida RECIBIDO -> EN_DIAGNOSTICO aceptada',
  (SELECT estado='EN_DIAGNOSTICO' FROM public.registros WHERE id=pg_temp.registro_id()));
SELECT pg_temp.chk('S2 el historial registra estado_anterior Y estado_nuevo',
  (SELECT count(*)=1 FROM public.historial_registros
   WHERE registro_id=pg_temp.registro_id()
     AND estado_anterior='RECIBIDO' AND estado_nuevo='EN_DIAGNOSTICO'));
ROLLBACK;

-- Camino completo hacia la entrega: la fecha se llena sola
BEGIN;
UPDATE public.registros SET estado='EN_DIAGNOSTICO' WHERE id=pg_temp.registro_id();
UPDATE public.registros SET estado='EN_REPARACION'  WHERE id=pg_temp.registro_id();
UPDATE public.registros SET estado='REPARADO'       WHERE id=pg_temp.registro_id();
SELECT pg_temp.chk('S3 llegar a REPARADO por transiciones válidas',
  (SELECT estado='REPARADO' FROM public.registros WHERE id=pg_temp.registro_id()));
UPDATE public.registros SET estado='ENTREGADO' WHERE id=pg_temp.registro_id();
SELECT pg_temp.chk('S4 ENTREGADO lleva su fecha de entrega (la llena el trigger)',
  (SELECT estado='ENTREGADO' AND fecha_entrega IS NOT NULL
   FROM public.registros WHERE id=pg_temp.registro_id()));
ROLLBACK;

-- ============ COHERENCIA DE COBERTURA ============
BEGIN;
UPDATE public.registros SET cobertura='ANULADA_POR_USO';  -- sin motivo: DEBE FALLAR
ROLLBACK;
SELECT pg_temp.chk('G1 cobertura ANULADA exige motivo',
  (SELECT count(*) FROM public.registros WHERE cobertura='ANULADA_POR_USO') = 0);

BEGIN;
UPDATE public.registros SET cobertura='EN_GARANTIA', costo_reparacion=50;  -- cobrar lo cubierto: DEBE FALLAR
ROLLBACK;
SELECT pg_temp.chk('G2 no se cobra reparación con cobertura en garantía',
  (SELECT count(*) FROM public.registros WHERE costo_reparacion IS NOT NULL) = 0);

-- ============ TECNICO: solo lo suyo y abierto ============
SELECT pg_temp.chk('T1 TECNICO asignado SI avanza su registro',
  NOT pg_temp.rechazado('22222222-2222-2222-2222-222222222222',
    $q$UPDATE public.registros SET estado='EN_DIAGNOSTICO'
        WHERE tecnico_asignado_id='22222222-2222-2222-2222-222222222222'$q$));
UPDATE public.registros SET tecnico_asignado_id='11111111-1111-1111-1111-111111111111';
SELECT pg_temp.chk('T2 TECNICO NO asignado no modifica (0 filas)',
  pg_temp.rechazado('22222222-2222-2222-2222-222222222222',
    $q$UPDATE public.registros SET estado='EN_DIAGNOSTICO'
        WHERE tecnico_asignado_id='11111111-1111-1111-1111-111111111111'$q$));
UPDATE public.registros SET tecnico_asignado_id='22222222-2222-2222-2222-222222222222';

-- Cerrado ya no se toca: ENTREGADO sale del alcance del técnico
UPDATE public.registros SET estado='EN_DIAGNOSTICO' WHERE id=pg_temp.registro_id();
UPDATE public.registros SET estado='EN_REPARACION'  WHERE id=pg_temp.registro_id();
UPDATE public.registros SET estado='REPARADO'       WHERE id=pg_temp.registro_id();
UPDATE public.registros SET estado='ENTREGADO'      WHERE id=pg_temp.registro_id();
SELECT pg_temp.chk('T3 un registro cerrado ya no lo puede tocar su técnico',
  pg_temp.rechazado('22222222-2222-2222-2222-222222222222',
    $q$UPDATE public.registros SET estado='ANULADO'$q$));

-- ============ NOTAS INTERNAS ============
INSERT INTO public.notas_internas (registro_id, autor_id, nota)
VALUES (pg_temp.registro_id(), '22222222-2222-2222-2222-222222222222', 'Prueba de nota');
SELECT pg_temp.chk('N1 la nota apunta al registro y la escribió su autor',
  (SELECT count(*)=1 FROM public.notas_internas
   WHERE nota='Prueba de nota' AND registro_id=pg_temp.registro_id()));

-- ============ PERMISOS DE MESA ============
BEGIN;
SET ROLE anon;
SELECT count(*) FROM public.registros;  -- DEBE FALLAR
ROLLBACK;
SELECT pg_temp.chk('P1 anon no toca registros',
  (SELECT count(*)=2 FROM public.registros));

SELECT pg_temp.chk('P2 TECNICO no inserta registros directo (solo el RPC)',
  pg_temp.rechazado('22222222-2222-2222-2222-222222222222',
    $q$INSERT INTO public.registros (equipo_id, falla_reportada, cobertura, creado_por)
       VALUES (pg_temp.equipo_id(),'Prueba bypass','EN_GARANTIA', auth.uid())$q$));

BEGIN;
UPDATE public.historial_registros SET comentario='falsificado';  -- DEBE FALLAR
ROLLBACK;
BEGIN;
DELETE FROM public.historial_registros;  -- DEBE FALLAR
ROLLBACK;
SELECT pg_temp.chk('P3 historial intacto tras UPDATE/DELETE (5 de reg1 + 1 de reg2)',
  (SELECT count(*)=6 FROM public.historial_registros));