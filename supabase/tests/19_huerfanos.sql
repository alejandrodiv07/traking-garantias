-- Prueba de `listar_huerfanos` (Tarea 14 del plan; spec §5.7).
\set QUIET on
CREATE OR REPLACE FUNCTION pg_temp.chk(n text, c boolean) RETURNS void
LANGUAGE plpgsql AS $$ BEGIN RAISE NOTICE '%  %', CASE WHEN c THEN 'PASA  ' ELSE '*FALLA*' END, n; END $$;

-- Mensaje de error de una sentencia bajo una identidad (patrón de 14/15)
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
\pset pager off

-- Escenario en el bucket: 4 objetos con edades y referencias distintas.
-- El bucket `registros` ya lo creó la migración ...0008; solo importa el otro.
INSERT INTO storage.buckets (id, name, public)
VALUES ('registros','registros',false), ('otro','otro',false)
ON CONFLICT (id) DO NOTHING;

-- El usuario que se sembrará como propietario del registro de referencia.
INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES
 ('11111111-1111-1111-1111-111111111111','admin@primetelecom.com','{}'::jsonb);
DO $$
BEGIN
  IF to_regclass('public.mfa_sesiones') IS NOT NULL THEN
    INSERT INTO public.mfa_sesiones (session_id, user_id)
    VALUES ('11111111-1111-1111-1111-111111111111','11111111-1111-1111-1111-111111111111');
  END IF;
END $$;

-- Semillas de dominio primero (la ruta del objeto referenciado lleva el id)
INSERT INTO public.clientes (tipo_documento, documento, nombre) VALUES ('V','12345678','Juan Perez');
INSERT INTO public.equipos (numero_serie, producto_id, cliente_id)
SELECT 'RT5-8842-AA', p.id, c.id FROM public.productos p, public.clientes c
WHERE p.modelo='HG8245' AND c.documento='12345678' LIMIT 1;
INSERT INTO public.registros (equipo_id, falla_reportada, cobertura, creado_por, consulta_token_hash)
VALUES ((SELECT id FROM public.equipos LIMIT 1), 'No enciende, huele a quemado',
        'EN_GARANTIA', '11111111-1111-1111-1111-111111111111', extensions.digest('hu-test','sha256'));

CREATE FUNCTION pg_temp.registro_id() RETURNS uuid LANGUAGE sql AS
  $$ SELECT id FROM public.registros ORDER BY fecha_ingreso LIMIT 1 $$;
CREATE FUNCTION pg_temp.ruta_refer() RETURNS text LANGUAGE sql AS
  $$ SELECT 'registros/' || pg_temp.registro_id() || '/refer.jpg' $$;

INSERT INTO storage.objects (bucket_id, name, created_at) VALUES
  ('registros', 'hu25.jpg', now() - interval '25 hours'),   -- sin fila, 25 h  → SÍ
  ('registros', 'hu23.jpg', now() - interval '23 hours'),   -- sin fila, 23 h  → NO (subida en curso)
  ('registros', pg_temp.ruta_refer(), now() - interval '48 hours'),  -- CON fila → NO
  ('otro',    'otrobucket.jpg', now() - interval '48 hours');-- otro bucket   → NO

-- El objeto referenciado tiene su fila en adjuntos (la misma ruta)
INSERT INTO public.adjuntos (registro_id, tipo, etiqueta, ruta, mime, bytes, subido_por)
VALUES (pg_temp.registro_id(), 'FOTO','ref',
        pg_temp.ruta_refer(), 'image/jpeg', 10, '11111111-1111-1111-1111-111111111111');

SELECT pg_temp.chk('H1 lista el objeto sin fila de 25 h',
  (SELECT EXISTS (SELECT 1 FROM public.listar_huerfanos() WHERE nombre='hu25.jpg')));
SELECT pg_temp.chk('H2 no lista el de 23 h (ventana de gracia)',
  (SELECT NOT EXISTS (SELECT 1 FROM public.listar_huerfanos() WHERE nombre='hu23.jpg')));
SELECT pg_temp.chk('H3 no lista el que tiene fila en adjuntos',
  (SELECT NOT EXISTS (SELECT 1 FROM public.listar_huerfanos() WHERE nombre = pg_temp.ruta_refer())));
SELECT pg_temp.chk('H4 no lista objetos de otro bucket',
  (SELECT NOT EXISTS (SELECT 1 FROM public.listar_huerfanos() WHERE nombre='otrobucket.jpg')));
SELECT pg_temp.chk('H5 el total de huérfanos es exactamente 1',
  (SELECT count(*) = 1 FROM public.listar_huerfanos()));

SELECT pg_temp.chk('H6 authenticated no puede ejecutarla',
  (SELECT mensaje ~ 'permission denied' FROM (SELECT pg_temp.mensaje('22222222-2222-2222-2222-222222222222', $$SELECT count(*) FROM public.listar_huerfanos()$$) AS mensaje) x));