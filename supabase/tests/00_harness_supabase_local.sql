-- Emulación mínima de Supabase para validar la migración

CREATE SCHEMA extensions;
CREATE SCHEMA auth;
GRANT USAGE ON SCHEMA extensions TO anon, authenticated, service_role;

CREATE TABLE auth.users (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email text NOT NULL UNIQUE,
  -- `phone` NO es decorativo: `handle_new_user` lo lee en su cadena de
  -- reserva del nombre (COALESCE(..., NEW.phone, ...)). Sin la columna, el
  -- trigger revienta con "record new has no field phone" en el PRIMER INSERT
  -- y las 13 pruebas de 98_pruebas_auth_base caen en cascada.
  phone text,
  raw_user_meta_data jsonb DEFAULT '{}'::jsonb,
  created_at timestamptz DEFAULT now()
);

CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid
LANGUAGE sql STABLE AS $$
  SELECT nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;
$$;
GRANT USAGE ON SCHEMA auth TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION auth.uid() TO anon, authenticated, service_role;

-- Añadido para 96_pruebas_mfa: `auth.jwt()` real de Supabase es un coalesce
-- de `request.jwt.claims` (el objeto completo que pone PostgREST) y de los
-- ajustes `request.jwt.claim.*` sueltos. Se emula igual para poder fijar
-- `session_id` en las pruebas con SET LOCAL.
CREATE OR REPLACE FUNCTION auth.jwt() RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT coalesce(
    nullif(current_setting('request.jwt.claims', true), '')::jsonb,
    jsonb_strip_nulls(jsonb_build_object(
      'sub',        nullif(current_setting('request.jwt.claim.sub', true), ''),
      'session_id', nullif(current_setting('request.jwt.claim.session_id', true), '')
    ))
  );
$$;
GRANT EXECUTE ON FUNCTION auth.jwt() TO anon, authenticated, service_role;
