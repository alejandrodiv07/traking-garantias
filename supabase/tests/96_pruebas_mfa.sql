-- =====================================================================
--  Pruebas del segundo factor por correo (migración ...0003_mfa_email)
--
--  Se ejecutan con psql sobre una base vacía, en este orden:
--    psql -f 00_harness_supabase_local.sql \
--         -f ../migrations/20260906000001_auth_base.sql \
--         -f ../migrations/20260907000003_mfa_email.sql \
--         -f 96_pruebas_mfa.sql
--  (la migración de garantías no hace falta: nada de aquí la toca)
--
--  Cada prueba nombra el ATAQUE que cierra, no la función que llama.
-- =====================================================================
\set QUIET on
CREATE OR REPLACE FUNCTION pg_temp.chk(n text, c boolean) RETURNS void LANGUAGE plpgsql AS $$
BEGIN RAISE NOTICE '%  %', CASE WHEN c THEN 'PASA  ' ELSE '*FALLA*' END, n; END $$;
\set QUIET off

INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES
 ('aaaaaaaa-0000-0000-0000-000000000001','ana@primetelecom.com','{"full_name":"Ana Analista"}'::jsonb),
 ('bbbbbbbb-0000-0000-0000-000000000002','beto@primetelecom.com','{"full_name":"Beto Bodega"}'::jsonb);

\set ANA '''aaaaaaaa-0000-0000-0000-000000000001'''
\set BETO '''bbbbbbbb-0000-0000-0000-000000000002'''
\set S1 '''11111111-aaaa-aaaa-aaaa-111111111111'''
\set S2 '''22222222-aaaa-aaaa-aaaa-222222222222'''
\set S3 '''33333333-aaaa-aaaa-aaaa-333333333333'''

-- ---------------------------------------------------------------------
--  M1  El código no se puede leer desde el navegador
-- ---------------------------------------------------------------------
SELECT pg_temp.chk('M1 authenticated NO tiene SELECT sobre email_mfa_codes',
  NOT has_table_privilege('authenticated','public.email_mfa_codes','SELECT'));
SELECT pg_temp.chk('M1b anon NO tiene SELECT sobre email_mfa_codes',
  NOT has_table_privilege('anon','public.email_mfa_codes','SELECT'));
SELECT pg_temp.chk('M1c RLS activa en email_mfa_codes y CERO politicas (denegar todo)',
  (SELECT relrowsecurity FROM pg_class WHERE oid='public.email_mfa_codes'::regclass)
  AND NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename='email_mfa_codes'));
SELECT pg_temp.chk('M1d RLS activa en mfa_sesiones y CERO politicas',
  (SELECT relrowsecurity FROM pg_class WHERE oid='public.mfa_sesiones'::regclass)
  AND NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename='mfa_sesiones'));

-- ---------------------------------------------------------------------
--  M2  generate_mfa_code() NO devuelve el codigo
--      (la desviacion 1 de la migracion, comprobada en el catalogo:
--       si alguien la reescribe para devolver varchar, esto se pone rojo)
-- ---------------------------------------------------------------------
SELECT pg_temp.chk('M2 generate_mfa_code() devuelve timestamptz, no el codigo',
  (SELECT pg_catalog.format_type(p.prorettype,NULL)='timestamp with time zone'
     FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname='generate_mfa_code'));
SELECT pg_temp.chk('M2b authenticated puede EJECUTAR generate_mfa_code()',
  has_function_privilege('authenticated','public.generate_mfa_code()','EXECUTE'));
SELECT pg_temp.chk('M2c anon NO puede ejecutar generate_mfa_code()',
  NOT has_function_privilege('anon','public.generate_mfa_code()','EXECUTE'));
SELECT pg_temp.chk('M2d nadie salvo el dueno puede ejecutar mfa_limpiar()',
  NOT has_function_privilege('authenticated','public.mfa_limpiar()','EXECUTE')
  AND NOT has_function_privilege('anon','public.mfa_limpiar()','EXECUTE'));

-- ---------------------------------------------------------------------
--  M3  Emision: una fila, 6 digitos, 5 minutos
-- ---------------------------------------------------------------------
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = :ANA;
SET LOCAL request.jwt.claim.session_id = :S1;
SELECT public.generate_mfa_code() AS caduca \gset
COMMIT;

SELECT pg_temp.chk('M3 la emision deja UNA fila viva de 6 digitos para Ana',
  (SELECT count(*)=1 FROM public.email_mfa_codes
    WHERE user_id=:ANA AND NOT is_used AND code ~ '^[0-9]{6}$'));
SELECT pg_temp.chk('M3b caduca en ~5 minutos',
  (SELECT expires_at BETWEEN now()+interval '4 minutes' AND now()+interval '6 minutes'
     FROM public.email_mfa_codes WHERE user_id=:ANA ORDER BY created_at DESC LIMIT 1));

-- Intento REAL de lectura como authenticated (M1 mira los GRANT; esto mira
-- lo que de verdad pasa al ejecutar la consulta que haria un atacante).
DO $$
DECLARE v_n integer;
BEGIN
  SET LOCAL ROLE authenticated;
  BEGIN
    SELECT count(*) INTO v_n FROM public.email_mfa_codes;
    RAISE NOTICE '*FALLA* M4 un usuario autenticado LEYO % filas de codigos', v_n;
  EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'PASA    M4 el SELECT del atacante autenticado es rechazado';
  END;
  RESET ROLE;
END $$;

-- ---------------------------------------------------------------------
--  M5  Codigo correcto -> true, consumido, sesion anclada
-- ---------------------------------------------------------------------
SELECT code AS c1 FROM public.email_mfa_codes
 WHERE user_id=:ANA AND NOT is_used ORDER BY created_at DESC LIMIT 1 \gset

BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = :ANA;
SET LOCAL request.jwt.claim.session_id = :S1;
SELECT pg_temp.chk('M5 el codigo correcto verifica',
  public.verify_mfa_code(:'c1'));
SELECT pg_temp.chk('M5b tras verificar, mfa_ok() es true en ESTA sesion',
  public.mfa_ok());
COMMIT;

SELECT pg_temp.chk('M5c el codigo queda consumido (is_used)',
  (SELECT bool_and(is_used) FROM public.email_mfa_codes WHERE user_id=:ANA));
SELECT pg_temp.chk('M5d hay UNA fila en mfa_sesiones, con el session_id del JWT',
  (SELECT count(*)=1 FROM public.mfa_sesiones WHERE user_id=:ANA AND session_id=:S1));

-- ---------------------------------------------------------------------
--  M6  Anclaje a la sesion: el mismo usuario en OTRO navegador no hereda
--      la verificacion, y un token robado antes de verificar no sirve.
-- ---------------------------------------------------------------------
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = :ANA;
SET LOCAL request.jwt.claim.session_id = :S2;
SELECT pg_temp.chk('M6 mfa_ok() es false para otra sesion del MISMO usuario',
  NOT public.mfa_ok());
COMMIT;

-- ---------------------------------------------------------------------
--  M7  Reutilizacion: un codigo se gasta una sola vez
-- ---------------------------------------------------------------------
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = :ANA;
SET LOCAL request.jwt.claim.session_id = :S2;
SELECT pg_temp.chk('M7 el codigo ya usado NO vale una segunda vez',
  NOT public.verify_mfa_code(:'c1'));
COMMIT;

-- ---------------------------------------------------------------------
--  M8  Fuerza bruta: 5 fallos y el codigo se quema, incluso para el legitimo
-- ---------------------------------------------------------------------
DELETE FROM public.email_mfa_codes WHERE user_id=:BETO;
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = :BETO;
SET LOCAL request.jwt.claim.session_id = :S3;
SELECT public.generate_mfa_code();
COMMIT;
SELECT code AS c2 FROM public.email_mfa_codes
 WHERE user_id=:BETO AND NOT is_used ORDER BY created_at DESC LIMIT 1 \gset

-- 5 intentos errados seguidos. En un DO block y no en un SELECT con FROM:
-- `chk(texto, agregado FROM ...)` no es SQL valido y el error abortaba la
-- transaccion entera, dejando los 5 intentos sin contar (y M8b en verde
-- falso). El fallo de la prueba anterior era este, no la funcion.
DO $$
DECLARE i integer; v_alguno boolean := false;
BEGIN
  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.jwt.claim.sub','bbbbbbbb-0000-0000-0000-000000000002',true);
  PERFORM set_config('request.jwt.claim.session_id','33333333-aaaa-aaaa-aaaa-333333333333',true);
  FOR i IN 1..5 LOOP
    v_alguno := v_alguno OR public.verify_mfa_code('000000');
  END LOOP;
  RESET ROLE;
  RAISE NOTICE '%  M8 5 intentos con codigo errado devuelven false',
    CASE WHEN NOT v_alguno THEN 'PASA  ' ELSE '*FALLA*' END;
END $$;

SELECT pg_temp.chk('M8a los 5 fallos quedan contados en la fila (intentos = 5)',
  (SELECT intentos = 5 FROM public.email_mfa_codes
    WHERE user_id=:BETO ORDER BY created_at DESC LIMIT 1));

BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = :BETO;
SET LOCAL request.jwt.claim.session_id = :S3;
SELECT pg_temp.chk('M8b tras 5 fallos el codigo esta quemado: ni el CORRECTO entra',
  NOT public.verify_mfa_code(:'c2'));
COMMIT;

-- ---------------------------------------------------------------------
--  M9  Expiracion: 5 minutos y fuera (se envejece la fila a mano)
-- ---------------------------------------------------------------------
DELETE FROM public.email_mfa_codes WHERE user_id=:BETO;
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = :BETO;
SET LOCAL request.jwt.claim.session_id = :S3;
SELECT public.generate_mfa_code();
COMMIT;
SELECT code AS c3 FROM public.email_mfa_codes
 WHERE user_id=:BETO AND NOT is_used ORDER BY created_at DESC LIMIT 1 \gset
UPDATE public.email_mfa_codes SET expires_at = now() - interval '1 second'
 WHERE user_id=:BETO AND NOT is_used;

BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = :BETO;
SET LOCAL request.jwt.claim.session_id = :S3;
SELECT pg_temp.chk('M9 un codigo expirado no verifica',
  NOT public.verify_mfa_code(:'c3'));
COMMIT;

-- ---------------------------------------------------------------------
--  M10  Un solo codigo vivo: "reenviar" invalida el anterior
-- ---------------------------------------------------------------------
DELETE FROM public.email_mfa_codes WHERE user_id=:BETO;
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = :BETO;
SET LOCAL request.jwt.claim.session_id = :S3;
SELECT public.generate_mfa_code();
COMMIT;
SELECT code AS c4 FROM public.email_mfa_codes
 WHERE user_id=:BETO AND NOT is_used ORDER BY created_at DESC LIMIT 1 \gset
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = :BETO;
SET LOCAL request.jwt.claim.session_id = :S3;
SELECT public.generate_mfa_code();
COMMIT;
SELECT pg_temp.chk('M10 tras reenviar solo queda UN codigo vivo',
  (SELECT count(*)=1 FROM public.email_mfa_codes WHERE user_id=:BETO AND NOT is_used));
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = :BETO;
SET LOCAL request.jwt.claim.session_id = :S3;
SELECT pg_temp.chk('M10b el codigo ANTERIOR al reenvio ya no vale',
  NOT public.verify_mfa_code(:'c4'));
COMMIT;

-- ---------------------------------------------------------------------
--  M11  Anti-mailbomb: 5 emisiones por 15 minutos y se corta
-- ---------------------------------------------------------------------
DELETE FROM public.email_mfa_codes WHERE user_id=:BETO;
DO $$
DECLARE i integer;
BEGIN
  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.jwt.claim.sub','bbbbbbbb-0000-0000-0000-000000000002',true);
  PERFORM set_config('request.jwt.claim.session_id','11111111-aaaa-aaaa-aaaa-111111111111',true);
  FOR i IN 1..5 LOOP PERFORM public.generate_mfa_code(); END LOOP;
  BEGIN
    PERFORM public.generate_mfa_code();
    RAISE NOTICE '*FALLA* M11 la sexta emision en 15 min fue permitida';
  EXCEPTION WHEN program_limit_exceeded THEN
    RAISE NOTICE 'PASA    M11 la sexta emision en 15 min se rechaza (54000)';
  END;
  RESET ROLE;
END $$;

-- ---------------------------------------------------------------------
--  M12  Sin sesion no se emite nada (SQL Editor / anon)
-- ---------------------------------------------------------------------
DO $$
BEGIN
  BEGIN
    PERFORM public.generate_mfa_code();   -- auth.uid() IS NULL aqui
    RAISE NOTICE '*FALLA* M12 se emitio un codigo sin usuario autenticado';
  EXCEPTION WHEN others THEN
    RAISE NOTICE 'PASA    M12 sin sesion no se emite codigo';
  END;
END $$;

-- ---------------------------------------------------------------------
--  M13  mi_rol() exige el segundo factor (§6: el cuello de botella)
-- ---------------------------------------------------------------------
UPDATE public.profiles SET role='ADMIN' WHERE id=:ANA;
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = :ANA;
SET LOCAL request.jwt.claim.session_id = :S2;   -- sesion SIN verificar
SELECT pg_temp.chk('M13 sin segundo factor, mi_rol() es NULL aunque seas ADMIN',
  public.mi_rol() IS NULL);
SELECT pg_temp.chk('M13b y es_admin() es false',
  NOT public.es_admin());
SELECT pg_temp.chk('M13c pero tu PROPIO perfil sigue visible (lo necesita el login)',
  (SELECT count(*)=1 FROM public.profiles WHERE id=auth.uid()));
COMMIT;
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = :ANA;
SET LOCAL request.jwt.claim.session_id = :S1;   -- la sesion verificada en M5
SELECT pg_temp.chk('M13d con el segundo factor superado, mi_rol() devuelve ADMIN',
  public.mi_rol() = 'ADMIN');
COMMIT;

-- ---------------------------------------------------------------------
--  M14  Barrido: borra por antiguedad, no por "usado"
--       (la desviacion 2: la fila usada es la evidencia del ataque)
-- ---------------------------------------------------------------------
DELETE FROM public.email_mfa_codes;
INSERT INTO public.email_mfa_codes (user_id, code, is_used, created_at, expires_at) VALUES
 (:ANA,'111111', true,  now() - interval '20 minutes', now() - interval '15 minutes'),
 (:ANA,'222222', true,  now() - interval '1 minute',   now() + interval '4 minutes'),
 (:ANA,'333333', false, now(),                         now() + interval '5 minutes');
SELECT public.mfa_limpiar() AS borradas \gset
SELECT pg_temp.chk('M14 mfa_limpiar() borra la fila de hace 20 minutos',
  (SELECT count(*)=0 FROM public.email_mfa_codes WHERE code='111111'));
SELECT pg_temp.chk('M14b y CONSERVA la usada hace 1 minuto (evidencia + cuota)',
  (SELECT count(*)=1 FROM public.email_mfa_codes WHERE code='222222'));
SELECT pg_temp.chk('M14c y no toca la viva',
  (SELECT count(*)=1 FROM public.email_mfa_codes WHERE code='333333'));

INSERT INTO public.mfa_sesiones (session_id, user_id, verificada_at)
VALUES ('99999999-9999-9999-9999-999999999999',:ANA, now() - interval '13 hours');
SELECT public.mfa_limpiar();
SELECT pg_temp.chk('M14d mfa_limpiar() caduca las sesiones de mas de 12 h',
  (SELECT count(*)=0 FROM public.mfa_sesiones WHERE session_id='99999999-9999-9999-9999-999999999999'));
