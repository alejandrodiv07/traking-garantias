-- Prueba de `hoy_local()` y `ajustes` (Tareas 4 y 5 del plan).
\set QUIET on
CREATE OR REPLACE FUNCTION pg_temp.chk(n text, c boolean) RETURNS void
LANGUAGE plpgsql AS $$ BEGIN RAISE NOTICE '%  %', CASE WHEN c THEN 'PASA  ' ELSE '*FALLA*' END, n; END $$;
\set QUIET off

-- Semilla: admin y técnico con el segundo factor superado (convenio de 97/98).
INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES
 ('11111111-1111-1111-1111-111111111111','admin@primetelecom.com','{"full_name":"Ada Admin"}'::jsonb),
 ('22222222-2222-2222-2222-222222222222','tecnico@primetelecom.com','{"full_name":"Tito Tecnico"}'::jsonb);
DO $$
BEGIN
  IF to_regclass('public.mfa_sesiones') IS NOT NULL THEN
    INSERT INTO public.mfa_sesiones (session_id, user_id) VALUES
      ('11111111-1111-1111-1111-111111111111','11111111-1111-1111-1111-111111111111'),
      ('22222222-2222-2222-2222-222222222222','22222222-2222-2222-2222-222222222222');
  END IF;
END $$;
UPDATE public.profiles SET role='ADMIN' WHERE email='admin@primetelecom.com';

-- ============ HOY_LOCAL (zona horaria America/Caracas) ============
-- 2026-09-04 02:30+00 = 2026-09-03 22:30 en Caracas: el día local es el 3.
SELECT pg_temp.chk('A1 02:30+00 es 2026-09-03 en Caracas (23:30 alli)',
  public.hoy_local('2026-09-04 02:30+00') = DATE '2026-09-03');
-- 2026-09-04 04:00+00 = 2026-09-04 00:00 en Caracas: ya es el 4.
SELECT pg_temp.chk('A2 04:00+00 es ya 2026-09-04 en Caracas',
  public.hoy_local('2026-09-04 04:00+00') = DATE '2026-09-04');

-- ============ AJUSTES ============
SELECT pg_temp.chk('A3 umbral_critico = 3', public.ajuste('umbral_critico') = 3);
SELECT pg_temp.chk('A4 umbral_pronto = 7', public.ajuste('umbral_pronto') = 7);
SELECT pg_temp.chk('A5 sla_alerta = 7',    public.ajuste('sla_alerta') = 7);
SELECT pg_temp.chk('A6 sla_critico = 15',  public.ajuste('sla_critico') = 15);

-- ============ PERMISOS: leer los roles internos, escribir solo ADMIN ============
-- anon NO puede leer (permiso denegado: DEBE FALLAR y el archivo continúa).
BEGIN;
SET ROLE anon;
SELECT * FROM public.ajustes;  -- DEBE FALLAR
ROLLBACK;

-- Un rol interno del taller (JWT authenticated + mfa) debe poder leer.
BEGIN;
SET ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
SET LOCAL request.jwt.claim.session_id = '22222222-2222-2222-2222-222222222222';
SELECT pg_temp.chk('A7 un rol interno lee los cuatro ajustes',
  (SELECT count(*) = 4 FROM public.ajustes));
COMMIT;
RESET ROLE;

BEGIN;
SET ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
SET LOCAL request.jwt.claim.session_id = '22222222-2222-2222-2222-222222222222';
UPDATE public.ajustes SET valor = 99 WHERE clave='umbral_critico';  -- DEBE FALLAR (RLS o permiso)
ROLLBACK;
SELECT pg_temp.chk('A8 un TECNICO no puede actualizar ajustes',
  public.ajuste('umbral_critico') = 3);

BEGIN;
SET ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
SET LOCAL request.jwt.claim.session_id = '11111111-1111-1111-1111-111111111111';
UPDATE public.ajustes SET valor = 4 WHERE clave='umbral_critico';
SELECT pg_temp.chk('A9 un ADMIN sí puede ajustar los umbrales',
  public.ajuste('umbral_critico') = 4);
ROLLBACK;
SELECT pg_temp.chk('A10 el ajuste vuelve al valor sembrado',
  public.ajuste('umbral_critico') = 3);