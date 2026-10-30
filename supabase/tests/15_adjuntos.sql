-- Prueba de `adjuntos` y del bucket privado `registros` (Tarea 10 del plan; spec §5.4).
\set QUIET on
CREATE OR REPLACE FUNCTION pg_temp.chk(n text, c boolean) RETURNS void
LANGUAGE plpgsql AS $$ BEGIN RAISE NOTICE '%  %', CASE WHEN c THEN 'PASA  ' ELSE '*FALLA*' END, n; END $$;

CREATE FUNCTION pg_temp.mensaje(uid text, sql text) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE
BEGIN
  IF uid IS NOT NULL THEN
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

-- Semillas
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
UPDATE public.profiles SET role='ADMIN' WHERE email='admin@primetelecom.com';
-- El usuario 44444444 queda SIN PERFIL (es el "usuario sin rol" de A13):
-- el trigger handle_new_user le acaba de crear uno TECNICO; lo retiramos.
DELETE FROM public.profiles WHERE email='fantasma@x.com';

INSERT INTO public.clientes (tipo_documento, documento, nombre) VALUES ('V','12345678','Juan Perez');
INSERT INTO public.equipos (numero_serie, producto_id, cliente_id)
SELECT 'RT5-8842-AA', p.id, c.id FROM public.productos p, public.clientes c
WHERE p.modelo='HG8245' AND c.documento='12345678' LIMIT 1;
INSERT INTO public.registros (equipo_id, falla_reportada, cobertura, creado_por, consulta_token_hash)
VALUES ((SELECT id FROM public.equipos LIMIT 1), 'No enciende, huele a quemado',
        'EN_GARANTIA', '11111111-1111-1111-1111-111111111111', extensions.digest('adj-test','sha256'));

CREATE FUNCTION pg_temp.registro_id() RETURNS uuid LANGUAGE sql AS
  $$ SELECT id FROM public.registros ORDER BY fecha_ingreso LIMIT 1 $$;
CREATE FUNCTION pg_temp.registro_id2() RETURNS uuid LANGUAGE sql AS
  $$ SELECT id FROM public.registros ORDER BY fecha_ingreso DESC LIMIT 1 $$;

-- ============ FOTOS: MIMES ADMITIDOS ============
INSERT INTO public.adjuntos (registro_id, tipo, etiqueta, ruta, mime, bytes, subido_por)
VALUES (pg_temp.registro_id(), 'FOTO', 'frontal', 'registros/' || pg_temp.registro_id() || '/frontal.jpg', 'image/jpeg', 1000, '11111111-1111-1111-1111-111111111111');
INSERT INTO public.adjuntos (registro_id, tipo, etiqueta, ruta, mime, bytes, subido_por)
VALUES (pg_temp.registro_id(), 'FOTO', 'trasera', 'registros/' || pg_temp.registro_id() || '/trasera.png', 'image/png', 1000, '11111111-1111-1111-1111-111111111111');
INSERT INTO public.adjuntos (registro_id, tipo, etiqueta, ruta, mime, bytes, subido_por)
VALUES (pg_temp.registro_id(), 'FOTO', 'lateral', 'registros/' || pg_temp.registro_id() || '/lateral.webp', 'image/webp', 1000, '11111111-1111-1111-1111-111111111111');
SELECT pg_temp.chk('A1 JPG, PNG y WEBP como foto aceptadas',
  (SELECT count(*)=3 FROM public.adjuntos WHERE tipo='FOTO'));

-- ============ FOTOS: MIMES RECHAZADOS ============
SELECT pg_temp.chk('A2 image/heic como foto rechazada con mensaje JPG/PNG/WEBP',
  pg_temp.mensaje(NULL, $q$INSERT INTO public.adjuntos (registro_id, tipo, etiqueta, ruta, mime, bytes, subido_por)
    VALUES (pg_temp.registro_id(), 'FOTO', 'x', 'registros/' || pg_temp.registro_id() || '/x.heic', 'image/heic', 1000, '11111111-1111-1111-1111-111111111111')$q$) ~ 'JPG, PNG o WEBP');
SELECT pg_temp.chk('A3 application/pdf como foto rechazada con mensaje claro',
  pg_temp.mensaje(NULL, $q$INSERT INTO public.adjuntos (registro_id, tipo, etiqueta, ruta, mime, bytes, subido_por)
    VALUES (pg_temp.registro_id(), 'FOTO', 'x', 'registros/' || pg_temp.registro_id() || '/x.pdf', 'application/pdf', 1000, '11111111-1111-1111-1111-111111111111')$q$) ~ 'JPG, PNG o WEBP');

-- ============ TAMAÑO Y LÍMITES ============
SELECT pg_temp.chk('A4 foto de 8 MB + 1 rechazada con mensaje de 8 MB',
  pg_temp.mensaje(NULL, $q$INSERT INTO public.adjuntos (registro_id, tipo, etiqueta, ruta, mime, bytes, subido_por)
    VALUES (pg_temp.registro_id(), 'FOTO', 'pesada', 'registros/' || pg_temp.registro_id() || '/pesada.jpg', 'image/jpeg', 8*1024*1024+1, '11111111-1111-1111-1111-111111111111')$q$) ~ '8 MB');

-- 5 fotos más (ya hay 3): el noveno intento (foto 9) debe rechazarse
INSERT INTO public.adjuntos (registro_id, tipo, etiqueta, ruta, mime, bytes, subido_por)
SELECT pg_temp.registro_id(), 'FOTO', 'f' || g, 'registros/' || pg_temp.registro_id() || '/f' || g || '.jpg',
       'image/jpeg', 10, '11111111-1111-1111-1111-111111111111'
FROM generate_series(4,8) g;
SELECT pg_temp.chk('A5 el noveno FOTO del mismo registro rechazado',
  pg_temp.mensaje(NULL, $q$INSERT INTO public.adjuntos (registro_id, tipo, etiqueta, ruta, mime, bytes, subido_por)
    VALUES (pg_temp.registro_id(), 'FOTO', 'f9', 'registros/' || pg_temp.registro_id() || '/f9.jpg', 'image/jpeg', 10, '11111111-1111-1111-1111-111111111111')$q$) ~ '8');

-- 6 documentos admitidos; el séptimo rechazado
INSERT INTO public.adjuntos (registro_id, tipo, etiqueta, ruta, mime, bytes, subido_por)
SELECT pg_temp.registro_id(), 'DOCUMENTO', 'd' || g, 'registros/' || pg_temp.registro_id() || '/d' || g || '.pdf',
       'application/pdf', 10, '11111111-1111-1111-1111-111111111111'
FROM generate_series(1,6) g;
SELECT pg_temp.chk('A6 el séptimo DOCUMENTO del mismo registro rechazado',
  pg_temp.mensaje(NULL, $q$INSERT INTO public.adjuntos (registro_id, tipo, etiqueta, ruta, mime, bytes, subido_por)
    VALUES (pg_temp.registro_id(), 'DOCUMENTO', 'd7', 'registros/' || pg_temp.registro_id() || '/d7.pdf', 'application/pdf', 10, '11111111-1111-1111-1111-111111111111')$q$) ~ '6');

-- ============ INMUTABILIDAD ============
SET ROLE service_role;
SELECT pg_temp.chk('A7 UPDATE de adjuntos bloqueado (service_role)',
  pg_temp.mensaje(NULL, $$UPDATE public.adjuntos SET etiqueta='cambiada'$$) ~ 'solo de anexar');
RESET ROLE;

SELECT pg_temp.chk('A8 DELETE de adjuntos bloqueado (propietario)',
  pg_temp.mensaje(NULL, 'DELETE FROM public.adjuntos') ~ 'solo de anexar');

SELECT pg_temp.chk('A9 TRUNCATE de adjuntos bloqueado (propietario)',
  pg_temp.mensaje(NULL, 'TRUNCATE public.adjuntos') ~ 'solo de anexar');

-- ============ PERMISOS ============
BEGIN;
SET ROLE anon;
SELECT count(*) FROM public.adjuntos;  -- DEBE FALLAR (sin GRANT)
ROLLBACK;
SELECT pg_temp.chk('A10 anon no lee adjuntos',
  (SELECT count(*)=14 FROM public.adjuntos));

BEGIN;
SET ROLE anon;
INSERT INTO public.adjuntos (registro_id, tipo, etiqueta, ruta, mime, bytes, subido_por)
VALUES (pg_temp.registro_id(), 'FOTO', 'anon', 'x.jpg', 'image/jpeg', 1, NULL);  -- DEBE FALLAR
ROLLBACK;
SELECT pg_temp.chk('A11 anon no inserta adjuntos',
  (SELECT count(*)=14 FROM public.adjuntos));

-- ============ STORAGE: BUCKET Y POLÍTICAS POR RUTA ============
SELECT pg_temp.chk('A12 el bucket "registros" NO es público',
  (SELECT NOT public FROM storage.buckets WHERE id='registros'));

-- Un usuario sin rol (sin perfil activo ni mfa) no sube al bucket
SELECT pg_temp.chk('A13 usuario sin rol no sube a storage',
  pg_temp.mensaje('44444444-4444-4444-4444-444444444444',
    $q$INSERT INTO storage.objects (bucket_id, name)
       VALUES ('registros', 'sin-permiso/foto.jpg')$q$) ~ 'row-level security');

-- La ruta REAL del sistema es registros/{registro_id}/… (spec §5.4): la
-- app sube dentro de la carpeta "registros" del bucket, con el id del
-- registro como SEGUNDO segmento.
SELECT pg_temp.chk('A14 rol interno sube a registros/<registro_id>/…',
  pg_temp.mensaje('22222222-2222-2222-2222-222222222222',
    $q$INSERT INTO storage.objects (bucket_id, name)
       VALUES ('registros', 'registros/' || pg_temp.registro_id()::text || '/fotos/ok.jpg')$q$) IS NULL);

-- ...y NO fuera del patrón registros/{registro_id}/…: ni otra carpeta raíz,
-- ni un segundo segmento que no sea el id de un registro existente.
SELECT pg_temp.chk('A15 rol interno NO sube fuera de la ruta de un registro',
  pg_temp.mensaje('22222222-2222-2222-2222-222222222222',
    $q$INSERT INTO storage.objects (bucket_id, name)
       VALUES ('registros', 'otra-cosa/foto.jpg')$q$) ~ 'row-level security');

SELECT pg_temp.chk('A15b segundo segmento no-uuid de la ruta rechazado',
  pg_temp.mensaje('22222222-2222-2222-2222-222222222222',
    $q$INSERT INTO storage.objects (bucket_id, name)
       VALUES ('registros', 'registros/otra-cosa/foto.jpg')$q$) ~ 'row-level security');

-- El INSERT de la app omite subido_por: la columna se llena con el usuario
-- de la sesión (DEFAULT auth.uid()) y la política lo acepta. Va en un
-- registro aparte (el primero ya agotó sus 8 fotos y 6 documentos).
INSERT INTO public.registros (equipo_id, falla_reportada, cobertura, creado_por, consulta_token_hash)
VALUES ((SELECT id FROM public.equipos LIMIT 1), 'Equipo para adjuntos sin subido_por',
        'EN_GARANTIA', '11111111-1111-1111-1111-111111111111',
        extensions.digest('adj-test-2','sha256'));
-- INSERT y comprobación van en sentencias distintas: dentro de una misma
-- sentencia la subconsulta usaría una instantánea anterior y no vería la fila.
CREATE TEMP TABLE a16 AS SELECT pg_temp.mensaje('22222222-2222-2222-2222-222222222222',
    $q$INSERT INTO public.adjuntos (registro_id, tipo, etiqueta, ruta, mime, bytes)
       VALUES (pg_temp.registro_id2(), 'DOCUMENTO', 'de-la-sesion',
               'registros/' || pg_temp.registro_id2() || '/auto.pdf', 'application/pdf', 10)$q$) AS msg;
SELECT pg_temp.chk('A16 INSERT sin subido_por queda atribuido al usuario de la sesión',
  (SELECT msg IS NULL FROM a16)
  AND (SELECT subido_por = '22222222-2222-2222-2222-222222222222'
       FROM public.adjuntos WHERE etiqueta='de-la-sesion'));