\set QUIET on
CREATE OR REPLACE FUNCTION pg_temp.chk(n text, c boolean) RETURNS void LANGUAGE plpgsql AS $$
BEGIN RAISE NOTICE '%  %', CASE WHEN c THEN 'PASA  ' ELSE '*FALLA*' END, n; END $$;
-- Ejecuta un UPDATE bajo una identidad y devuelve TRUE si fue RECHAZADO
CREATE OR REPLACE FUNCTION pg_temp.rechazado(uid text, sql text) RETURNS boolean
LANGUAGE plpgsql AS $$
DECLARE n integer;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', uid, TRUE);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    EXECUTE sql;
    -- OJO: EXECUTE no actualiza FOUND en plpgsql. Hay que leer ROW_COUNT.
    GET DIAGNOSTICS n = ROW_COUNT;
  EXCEPTION WHEN others THEN
    EXECUTE 'RESET ROLE'; RETURN TRUE;   -- lanzo -> rechazado por trigger
  END;
  EXECUTE 'RESET ROLE';
  RETURN n = 0;                          -- 0 filas -> rechazado por RLS
END $$;
\set QUIET off

INSERT INTO auth.users (id, email) VALUES
 ('11111111-1111-1111-1111-111111111111','admin@primetelecom.com'),
 ('22222222-2222-2222-2222-222222222222','tecnico@primetelecom.com');
UPDATE public.profiles SET role='ADMIN' WHERE email='admin@primetelecom.com';

BEGIN;
SELECT pg_temp.chk('R5 el unico ADMIN NO puede auto-degradarse',
  pg_temp.rechazado('11111111-1111-1111-1111-111111111111',
    $q$UPDATE public.profiles SET role='TECNICO' WHERE id='11111111-1111-1111-1111-111111111111'$q$));
ROLLBACK;

BEGIN;
SELECT pg_temp.chk('R6 ni un ADMIN puede reescribir profiles.email',
  pg_temp.rechazado('11111111-1111-1111-1111-111111111111',
    $q$UPDATE public.profiles SET email='robado@x.com' WHERE id='22222222-2222-2222-2222-222222222222'$q$));
ROLLBACK;

BEGIN;
SELECT pg_temp.chk('R7 un TECNICO no puede auto-promoverse a ADMIN',
  pg_temp.rechazado('22222222-2222-2222-2222-222222222222',
    $q$UPDATE public.profiles SET role='ADMIN' WHERE id='22222222-2222-2222-2222-222222222222'$q$));
ROLLBACK;

BEGIN;
SELECT pg_temp.chk('R7b un TECNICO no puede desactivar a un ADMIN',
  pg_temp.rechazado('22222222-2222-2222-2222-222222222222',
    $q$UPDATE public.profiles SET is_active=false WHERE id='11111111-1111-1111-1111-111111111111'$q$));
ROLLBACK;

-- Contraprueba: un ADMIN SI puede promover a OTRO (si no, el sistema no sirve)
BEGIN;
SELECT pg_temp.chk('R14 un ADMIN SI puede promover a otro usuario (contraprueba)',
  NOT pg_temp.rechazado('11111111-1111-1111-1111-111111111111',
    $q$UPDATE public.profiles SET role='JEFE_SERVICIO' WHERE id='22222222-2222-2222-2222-222222222222'$q$));
ROLLBACK;

-- Contraprueba: cualquiera puede cambiarse el nombre
BEGIN;
SELECT pg_temp.chk('R15 un TECNICO SI puede cambiarse su propio nombre (contraprueba)',
  NOT pg_temp.rechazado('22222222-2222-2222-2222-222222222222',
    $q$UPDATE public.profiles SET full_name='Tito Tecnico Jr' WHERE id='22222222-2222-2222-2222-222222222222'$q$));
ROLLBACK;
