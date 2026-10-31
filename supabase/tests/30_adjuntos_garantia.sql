-- Fase 2b+: documentos vinculados a la garantía (migración 0024).
--   · un adjunto cuelga de una orden O de un equipo, nunca de ambos ni de ninguno
--   · la ruta (ordenes/ o equipos/) debe coincidir con el id de su fila
--   · topes y formatos por destino; solo de anexar; storage por ruta
\set QUIET on
CREATE OR REPLACE FUNCTION pg_temp.chk(n text, c boolean) RETURNS void
LANGUAGE plpgsql AS $$ BEGIN RAISE NOTICE '%  %', CASE WHEN c THEN 'PASA  ' ELSE '*FALLA*' END, n; END $$;

CREATE FUNCTION pg_temp.mensaje(uid text, sql text) RETURNS text
LANGUAGE plpgsql AS $$
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

CREATE FUNCTION pg_temp.filas(uid text, consulta text) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE n bigint;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', uid, TRUE);
  PERFORM set_config('request.jwt.claim.session_id', uid, TRUE);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    EXECUTE 'SELECT count(*) FROM (' || consulta || ') x' INTO n;
  EXCEPTION WHEN OTHERS THEN n := NULL;
  END;
  EXECUTE 'RESET ROLE';
  RETURN n;
END $$;
\set QUIET off

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
DELETE FROM public.profiles WHERE email='fantasma@x.com';

INSERT INTO public.clientes (tipo_documento, documento, nombre) VALUES ('V','12345678','Juan Perez');
INSERT INTO public.equipos (numero_serie, producto_id, cliente_id)
SELECT s, p.id, c.id FROM public.productos p, public.clientes c, (VALUES ('RT5-1'), ('RT5-2')) v(s)
WHERE p.modelo='HG8245' AND c.documento='12345678';
INSERT INTO public.ordenes_servicio (equipo_id, falla_reportada, cobertura, creado_por, consulta_token_hash)
VALUES ((SELECT id FROM public.equipos WHERE numero_serie='RT5-1'), 'No enciende, huele a quemado',
        'EN_GARANTIA', '11111111-1111-1111-1111-111111111111', extensions.digest('adj-gar','sha256'));

CREATE FUNCTION pg_temp.eq(s text) RETURNS uuid LANGUAGE sql AS $$ SELECT id FROM public.equipos WHERE numero_serie = s $$;
CREATE FUNCTION pg_temp.orden() RETURNS uuid LANGUAGE sql AS $$ SELECT id FROM public.ordenes_servicio LIMIT 1 $$;

-- ============ DESTINO: equipo u orden, no ambos ni ninguno ============
INSERT INTO public.adjuntos (equipo_id, tipo, etiqueta, ruta, mime, bytes, subido_por)
VALUES (pg_temp.eq('RT5-1'), 'DOCUMENTO', 'factura', 'equipos/' || pg_temp.eq('RT5-1') || '/factura.pdf', 'application/pdf', 1000, '11111111-1111-1111-1111-111111111111');
SELECT pg_temp.chk('G1 un documento se vincula al equipo (garantía)',
  (SELECT count(*) = 1 FROM public.adjuntos WHERE equipo_id = pg_temp.eq('RT5-1') AND orden_id IS NULL));

INSERT INTO public.adjuntos (orden_id, tipo, etiqueta, ruta, mime, bytes, subido_por)
VALUES (pg_temp.orden(), 'FOTO', 'frente', 'ordenes/' || pg_temp.orden() || '/frente.jpg', 'image/jpeg', 1000, '11111111-1111-1111-1111-111111111111');
SELECT pg_temp.chk('G2 los adjuntos de orden siguen funcionando igual',
  (SELECT count(*) = 1 FROM public.adjuntos WHERE orden_id = pg_temp.orden()));

SELECT pg_temp.chk('G3 sin equipo ni orden se rechaza',
  pg_temp.mensaje(NULL, $q$INSERT INTO public.adjuntos (tipo, ruta, mime, bytes, subido_por)
    VALUES ('DOCUMENTO', 'equipos/x/y.pdf', 'application/pdf', 10, '11111111-1111-1111-1111-111111111111')$q$) ~ 'adjuntos_(un_destino|ruta_destino)');
SELECT pg_temp.chk('G4 con equipo Y orden a la vez se rechaza',
  pg_temp.mensaje(NULL, $q$INSERT INTO public.adjuntos (orden_id, equipo_id, tipo, ruta, mime, bytes, subido_por)
    VALUES (pg_temp.orden(), pg_temp.eq('RT5-1'), 'DOCUMENTO', 'equipos/' || pg_temp.eq('RT5-1') || '/z.pdf', 'application/pdf', 10, '11111111-1111-1111-1111-111111111111')$q$) ~ 'adjuntos_un_destino');

-- ============ RUTA ============
SELECT pg_temp.chk('G5 la ruta de equipo debe llevar el id de ESE equipo',
  pg_temp.mensaje(NULL, $q$INSERT INTO public.adjuntos (equipo_id, tipo, ruta, mime, bytes, subido_por)
    VALUES (pg_temp.eq('RT5-1'), 'DOCUMENTO', 'equipos/' || pg_temp.eq('RT5-2') || '/ajeno.pdf', 'application/pdf', 10, '11111111-1111-1111-1111-111111111111')$q$) ~ 'adjuntos_ruta_destino');
SELECT pg_temp.chk('G6 una ruta de otra carpeta se rechaza',
  pg_temp.mensaje(NULL, $q$INSERT INTO public.adjuntos (equipo_id, tipo, ruta, mime, bytes, subido_por)
    VALUES (pg_temp.eq('RT5-1'), 'DOCUMENTO', 'otros/' || pg_temp.eq('RT5-1') || '/x.pdf', 'application/pdf', 10, '11111111-1111-1111-1111-111111111111')$q$) ~ 'adjuntos_ruta_check');

-- ============ FORMATO Y TOPES POR DESTINO ============
SELECT pg_temp.chk('G7 un documento HEIC para el equipo se rechaza con el mensaje de formato',
  pg_temp.mensaje(NULL, $q$INSERT INTO public.adjuntos (equipo_id, tipo, ruta, mime, bytes, subido_por)
    VALUES (pg_temp.eq('RT5-1'), 'DOCUMENTO', 'equipos/' || pg_temp.eq('RT5-1') || '/x.heic', 'image/heic', 10, '11111111-1111-1111-1111-111111111111')$q$) ~ 'PDF, JPG o PNG');
INSERT INTO public.adjuntos (equipo_id, tipo, etiqueta, ruta, mime, bytes, subido_por)
SELECT pg_temp.eq('RT5-1'), 'DOCUMENTO', 'd' || g, 'equipos/' || pg_temp.eq('RT5-1') || '/d' || g || '.pdf', 'application/pdf', 10, '11111111-1111-1111-1111-111111111111'
FROM generate_series(2,6) g;
SELECT pg_temp.chk('G8 el séptimo documento DEL EQUIPO se rechaza (tope 6)',
  pg_temp.mensaje(NULL, $q$INSERT INTO public.adjuntos (equipo_id, tipo, ruta, mime, bytes, subido_por)
    VALUES (pg_temp.eq('RT5-1'), 'DOCUMENTO', 'equipos/' || pg_temp.eq('RT5-1') || '/d7.pdf', 'application/pdf', 10, '11111111-1111-1111-1111-111111111111')$q$) ~ '6 documentos');
SELECT pg_temp.chk('G9 el tope es por destino: otro equipo y la orden siguen admitiendo',
  pg_temp.mensaje(NULL, $q$INSERT INTO public.adjuntos (equipo_id, tipo, ruta, mime, bytes, subido_por)
    VALUES (pg_temp.eq('RT5-2'), 'DOCUMENTO', 'equipos/' || pg_temp.eq('RT5-2') || '/a.pdf', 'application/pdf', 10, '11111111-1111-1111-1111-111111111111')$q$) IS NULL
  AND pg_temp.mensaje(NULL, $q$INSERT INTO public.adjuntos (orden_id, tipo, ruta, mime, bytes, subido_por)
    VALUES (pg_temp.orden(), 'DOCUMENTO', 'ordenes/' || pg_temp.orden() || '/a.pdf', 'application/pdf', 10, '11111111-1111-1111-1111-111111111111')$q$) IS NULL);

-- ============ SOLO DE ANEXAR ============
SELECT pg_temp.chk('G10 los documentos del equipo no se editan ni se borran',
  pg_temp.mensaje(NULL, 'DELETE FROM public.adjuntos WHERE equipo_id IS NOT NULL') ~ 'solo de anexar'
  AND pg_temp.mensaje(NULL, $$UPDATE public.adjuntos SET etiqueta='x' WHERE equipo_id IS NOT NULL$$) ~ 'solo de anexar');

-- ============ LECTURA (RLS) ============
SELECT pg_temp.chk('G11 un rol interno lee los documentos del equipo; sin rol no ve nada',
  pg_temp.filas('22222222-2222-2222-2222-222222222222', 'SELECT 1 FROM public.adjuntos WHERE equipo_id IS NOT NULL') = 7
  AND pg_temp.filas('44444444-4444-4444-4444-444444444444', 'SELECT 1 FROM public.adjuntos WHERE equipo_id IS NOT NULL') = 0);

-- ============ STORAGE ============
SELECT pg_temp.chk('G12 rol interno sube a equipos/<equipo_id>/…',
  pg_temp.mensaje('22222222-2222-2222-2222-222222222222',
    $q$INSERT INTO storage.objects (bucket_id, name)
       VALUES ('ordenes', 'equipos/' || pg_temp.eq('RT5-1') || '/factura.pdf')$q$) IS NULL);
SELECT pg_temp.chk('G13 un equipo inexistente, una carpeta ajena o un usuario sin rol no suben',
  pg_temp.mensaje('22222222-2222-2222-2222-222222222222',
    $q$INSERT INTO storage.objects (bucket_id, name)
       VALUES ('ordenes', 'equipos/99999999-9999-9999-9999-999999999999/x.pdf')$q$) ~ 'row-level security'
  AND pg_temp.mensaje('22222222-2222-2222-2222-222222222222',
    $q$INSERT INTO storage.objects (bucket_id, name)
       VALUES ('ordenes', 'otros/' || pg_temp.eq('RT5-1') || '/x.pdf')$q$) ~ 'row-level security'
  AND pg_temp.mensaje('44444444-4444-4444-4444-444444444444',
    $q$INSERT INTO storage.objects (bucket_id, name)
       VALUES ('ordenes', 'equipos/' || pg_temp.eq('RT5-1') || '/y.pdf')$q$) ~ 'row-level security');
SELECT pg_temp.chk('G14 un segmento que no es uuid se rechaza por RLS, no por error de sintaxis',
  pg_temp.mensaje('22222222-2222-2222-2222-222222222222',
    $q$INSERT INTO storage.objects (bucket_id, name) VALUES ('ordenes', 'equipos/no-es-uuid/x.pdf')$q$) ~ 'row-level security');
SELECT pg_temp.chk('G15 un rol interno ve el archivo del equipo; sin rol no',
  pg_temp.filas('22222222-2222-2222-2222-222222222222', $q$SELECT 1 FROM storage.objects WHERE bucket_id='ordenes' AND name LIKE 'equipos/%'$q$) = 1
  AND pg_temp.filas('44444444-4444-4444-4444-444444444444', $q$SELECT 1 FROM storage.objects WHERE bucket_id='ordenes' AND name LIKE 'equipos/%'$q$) = 0);
