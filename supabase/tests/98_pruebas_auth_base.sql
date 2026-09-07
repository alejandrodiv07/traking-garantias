\set QUIET on
CREATE OR REPLACE FUNCTION pg_temp.chk(n text, c boolean) RETURNS void LANGUAGE plpgsql AS $$
BEGIN RAISE NOTICE '%  %', CASE WHEN c THEN 'PASA  ' ELSE '*FALLA*' END, n; END $$;
\set QUIET off

INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES
 ('11111111-1111-1111-1111-111111111111','admin@primetelecom.com','{"full_name":"Ada Admin","role":"ADMIN"}'::jsonb),
 ('22222222-2222-2222-2222-222222222222','tecnico@primetelecom.com','{"full_name":"Tito Tecnico","role":"ADMIN"}'::jsonb),
 ('33333333-3333-3333-3333-333333333333','sinmeta@primetelecom.com','{}'::jsonb);
-- ---------------------------------------------------------------------
--  SEMILLA DEL SEGUNDO FACTOR  (migración ...0003_mfa_email)
-- ---------------------------------------------------------------------
-- Desde esa migración, `mi_rol()` exige `mfa_ok()`: un JWT sin código
-- verificado no tiene rol efectivo. Estas pruebas comprueban ROLES y RLS, no
-- el 2FA (eso es 96_pruebas_mfa), así que sus usuarios entran con el segundo
-- factor ya superado. Sin esta semilla, cada prueba que dependa de un rol
-- mediría el 2FA por accidente y fallaría por el motivo equivocado.
--
-- CONVENIO: el `session_id` de las pruebas ES el id del usuario. Un uuid vale
-- igual que otro para `mfa_sesiones`, y así cada transacción de abajo puede
-- fijar los dos claims con el mismo literal, sin una tabla de constantes.
--
-- El bloque se guarda con `to_regclass`: si estas pruebas se corren SOLO con
-- ...0001_auth_base (sin la migración del 2FA), no hay tabla, no hay puerta
-- que abrir, y el fichero sigue pasando igual.
DO $$
BEGIN
  IF to_regclass('public.mfa_sesiones') IS NULL THEN RETURN; END IF;
  INSERT INTO public.mfa_sesiones (session_id, user_id)
  SELECT p.id, p.id FROM public.profiles p
  ON CONFLICT (session_id) DO NOTHING;
END $$;


SELECT pg_temp.chk('R1 metadata {"role":"ADMIN"} NO escala: los 3 nacen TECNICO',
  (SELECT bool_and(role='TECNICO') FROM public.profiles));
SELECT pg_temp.chk('R1b sin full_name en metadata, cae al local-part (no "Usuario")',
  (SELECT full_name='sinmeta' FROM public.profiles WHERE id='33333333-3333-3333-3333-333333333333'));

-- Arranque en frio (SQL Editor, auth.uid() IS NULL)
UPDATE public.profiles SET role='ADMIN' WHERE email='admin@primetelecom.com';
SELECT pg_temp.chk('R2 el primer ADMIN se puede promover desde el SQL Editor',
  (SELECT role='ADMIN' FROM public.profiles WHERE email='admin@primetelecom.com'));

-- REQUISITO 1: is_active + la consulta EXACTA de authService.obtenerPerfil()
CREATE TEMP TABLE r3 AS SELECT 1 WHERE false;
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
SET LOCAL request.jwt.claim.session_id = '22222222-2222-2222-2222-222222222222';
SELECT pg_temp.chk('R3 la consulta EXACTA de obtenerPerfil() devuelve 1 fila',
  (SELECT count(*)=1 FROM (SELECT id, full_name, email, role, is_active
     FROM public.profiles WHERE id = auth.uid()) q));
SELECT pg_temp.chk('R3b sin filtro por id devolveria varias -> maybeSingle() lanzaria',
  (SELECT count(*)>1 FROM public.profiles));
COMMIT;

-- REQUISITO 2: mi_rol() con su nombre
SELECT pg_temp.chk('R4 existe mi_rol() (la RPC de AuthContext y la Edge Function)',
  EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
          WHERE n.nspname='public' AND p.proname='mi_rol'));
SELECT pg_temp.chk('R4b authenticated tiene EXECUTE sobre mi_rol()',
  has_function_privilege('authenticated','public.mi_rol()','EXECUTE'));
SELECT pg_temp.chk('R4c anon NO tiene EXECUTE sobre mi_rol()',
  NOT has_function_privilege('anon','public.mi_rol()','EXECUTE'));

-- REQUISITO 3a: el ultimo ADMIN no se auto-degrada
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
SET LOCAL request.jwt.claim.session_id = '11111111-1111-1111-1111-111111111111';
UPDATE public.profiles SET role='TECNICO' WHERE id=auth.uid();
RESET ROLE;
SELECT pg_temp.chk('R5 el ADMIN NO puede auto-degradarse',
  (SELECT count(*)=1 FROM public.profiles WHERE role='ADMIN'));
ROLLBACK;

-- REQUISITO 3b: el correo espejo es inmutable, incluso para un ADMIN
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
SET LOCAL request.jwt.claim.session_id = '11111111-1111-1111-1111-111111111111';
UPDATE public.profiles SET email='robado@x.com' WHERE id='22222222-2222-2222-2222-222222222222';
RESET ROLE;
SELECT pg_temp.chk('R6 ni un ADMIN puede reescribir profiles.email',
  (SELECT email='tecnico@primetelecom.com' FROM public.profiles WHERE id='22222222-2222-2222-2222-222222222222'));
ROLLBACK;

-- Escalada vertical y horizontal
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
SET LOCAL request.jwt.claim.session_id = '22222222-2222-2222-2222-222222222222';
UPDATE public.profiles SET role='ADMIN' WHERE id=auth.uid();
RESET ROLE;
SELECT pg_temp.chk('R7 TECNICO no puede auto-promoverse',
  (SELECT role='TECNICO' FROM public.profiles WHERE id='22222222-2222-2222-2222-222222222222'));
ROLLBACK;
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
SET LOCAL request.jwt.claim.session_id = '22222222-2222-2222-2222-222222222222';
UPDATE public.profiles SET full_name='Hackeado' WHERE id='11111111-1111-1111-1111-111111111111';
RESET ROLE;
SELECT pg_temp.chk('R8 TECNICO no edita el perfil de otro',
  (SELECT full_name='Ada Admin' FROM public.profiles WHERE id='11111111-1111-1111-1111-111111111111'));
ROLLBACK;

-- REQUISITO 4: alta con correo NULL (telefono / OAuth)
BEGIN;
INSERT INTO auth.users (id, email, phone) VALUES ('44444444-4444-4444-4444-444444444444', NULL, '+584141234567');
SELECT pg_temp.chk('R9 un alta SIN correo no rompe el registro en Auth',
  (SELECT count(*)=1 FROM public.profiles WHERE id='44444444-4444-4444-4444-444444444444'));
SELECT pg_temp.chk('R9b ...y recibe un full_name de reserva no nulo',
  (SELECT full_name IS NOT NULL FROM public.profiles WHERE id='44444444-4444-4444-4444-444444444444'));
ROLLBACK;

-- Sincronizacion del espejo
UPDATE auth.users SET email='ada.nueva@primetelecom.com' WHERE id='11111111-1111-1111-1111-111111111111';
SELECT pg_temp.chk('R10 profiles.email sigue a auth.users tras cambiar el correo',
  (SELECT email='ada.nueva@primetelecom.com' FROM public.profiles WHERE id='11111111-1111-1111-1111-111111111111'));

-- Baja logica: el usuario desactivado deja de ver su propio perfil -> el
-- frontend hace signOut. Es el mecanismo de expulsion.
UPDATE public.profiles SET is_active=false WHERE id='22222222-2222-2222-2222-222222222222';
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
SET LOCAL request.jwt.claim.session_id = '22222222-2222-2222-2222-222222222222';
SELECT pg_temp.chk('R11 un desactivado solo ve SU fila (el frontend la lee y lo expulsa)',
  (SELECT count(*)=1 FROM public.profiles));
SELECT pg_temp.chk('R11c ...y no puede enumerar al resto del personal',
  (SELECT count(*)=0 FROM public.profiles WHERE id <> auth.uid()));
SELECT pg_temp.chk('R11b ...y mi_rol() le devuelve NULL', public.mi_rol() IS NULL);
COMMIT;
UPDATE public.profiles SET is_active=true WHERE id='22222222-2222-2222-2222-222222222222';

-- anon
BEGIN;
SET LOCAL ROLE anon;
SELECT count(*) FROM public.profiles;  -- debe fallar: permiso denegado
ROLLBACK;

-- Recursion
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
SET LOCAL request.jwt.claim.session_id = '11111111-1111-1111-1111-111111111111';
SELECT pg_temp.chk('R13 ADMIN lista todos los perfiles sin recursion 42P17',
  (SELECT count(*)>=3 FROM public.profiles));
COMMIT;
