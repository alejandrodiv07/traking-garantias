-- =====================================================================
--  Prime Telecom · Track Garantía
--  Migración 1 de 2 — BASE DE AUTENTICACIÓN (roles + perfiles + RLS)
--  PostgreSQL / Supabase · 2026-09-06
--
--  Extracto EXACTO de `20260906000001_esquema_inicial.sql`: las secciones
--  0-3 recortadas verbatim (ni una línea reescrita a mano), más los índices,
--  GRANT y políticas RLS que corresponden a `profiles`.
--
--  Propósito: levantar lo mínimo indispensable para probar que el login de
--  React autentica y redirige, sin arrastrar todavía el dominio de garantías.
--
--  ORDEN OBLIGATORIO
--    1. este fichero                    -> autenticación funcionando
--    2. ...0002_garantias.sql           -> clientes, productos, garantías
--  La parte 2 asume que esta ya corrió: referencia `profiles`, `mi_rol()` y
--  `set_updated_at()`, definidos aquí.
--
--  LO QUE ESTE FICHERO CONSERVA, Y QUE UNA VERSIÓN "SIMPLIFICADA" PIERDE
--   · `profiles.is_active` — la columna que consulta `authService`. Sin ella
--     TODO login autentica y es expulsado acto seguido.
--   · `mi_rol()` con ese nombre exacto — es la RPC que invocan `AuthContext`
--     y la Edge Function. Renombrarla devuelve 403 a todo el mundo.
--   · `proteger_columnas_de_profile` — impide que el último ADMIN se
--     auto-degrade (bloqueo permanente) y que se reescriba el correo espejo.
--   · `handle_new_user` tolerante a `NEW.email` NULL — en Supabase real
--     `auth.users.email` es nullable, y una excepción aquí aborta el alta.
--   · `sincronizar_email_de_profile` — mantiene el espejo al día.
-- =====================================================================

BEGIN;

-- =====================================================================
--  0. EXTENSIONES
-- =====================================================================
-- pgcrypto vive en el esquema `extensions` en Supabase. Todas las
-- llamadas van SCHEMA-CUALIFICADAS (extensions.digest, etc.) para no
-- tener que meter ese esquema en el search_path de las funciones
-- SECURITY DEFINER: un search_path corto es un search_path seguro.
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

-- =====================================================================
--  1. TIPOS
-- =====================================================================

CREATE TYPE public.app_role AS ENUM (
    'ADMIN',          -- gestiona usuarios y catálogos
    'JEFE_SERVICIO',  -- asigna técnicos, anula órdenes, ve todo
    'TECNICO',        -- solo trabaja las órdenes asignadas a él
    'RECEPCION'       -- crea órdenes y atiende al cliente, no diagnostica
);
-- =====================================================================
--  2. PERFILES  (extensión de auth.users)
-- =====================================================================

CREATE TABLE public.profiles (
    id          UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    full_name   TEXT NOT NULL CHECK (length(btrim(full_name)) BETWEEN 3 AND 120),

    -- Copia DENORMALIZADA de auth.users.email, mantenida por trigger
    -- (§2.3). Existe solo porque PostgREST no puede unir contra el
    -- esquema `auth` desde el cliente. La fuente de verdad sigue siendo
    -- auth.users; esta columna es un espejo, nunca se edita a mano.
    -- NULLABLE a propósito: en Supabase `auth.users.email` lo es (altas por
    -- teléfono, algunos OAuth). Con NOT NULL aquí, el trigger de alta lanza
    -- y ABORTA la creación del usuario en Auth — el sistema entero deja de
    -- poder dar de alta a nadie por ese camino. La unicidad se conserva con
    -- un índice parcial, que ignora los NULL.
    email       TEXT CHECK (email IS NULL OR email = lower(email)),

    role        public.app_role NOT NULL DEFAULT 'TECNICO',
    is_active   BOOLEAN NOT NULL DEFAULT TRUE,  -- baja lógica; jamás DELETE

    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Unicidad del correo con índice PARCIAL: los NULL quedan fuera, así que
-- varias cuentas sin correo pueden convivir sin chocar entre sí.
CREATE UNIQUE INDEX uq_profiles_email ON public.profiles (email) WHERE email IS NOT NULL;

COMMENT ON COLUMN public.profiles.role IS
'NUNCA se asigna desde raw_user_meta_data. El alta fuerza TECNICO; solo un ADMIN promueve.';


-- ---------------------------------------------------------------------
--  2.1  Alta de usuario — trigger blindado
-- ---------------------------------------------------------------------
-- HALLAZGO CORREGIDO (escalada de privilegios):
--   La versión anterior hacía
--     COALESCE((NEW.raw_user_meta_data->>'role')::app_role, 'TECNICO')
--   y `raw_user_meta_data` lo controla el cliente en el signUp. Cualquiera
--   que se registrara con {"role":"ADMIN"} era administrador.
--   Aquí el rol es una CONSTANTE. El metadata solo aporta el nombre, y
--   pasa por validación de longitud.
--
-- HALLAZGO CORREGIDO (search_path):
--   `SECURITY DEFINER` sin `SET search_path` permite que un atacante con
--   permiso de CREATE en algún esquema del path anteponga su propia
--   función `digest()` o su propio operador y ejecute código como el
--   dueño de la función. Se fija a `public, pg_temp` y punto.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_nombre TEXT;
BEGIN
    v_nombre := btrim(coalesce(NEW.raw_user_meta_data ->> 'full_name', ''));

    -- Cadena de reserva que TERMINA EN UN LITERAL. `split_part(NULL,...)`
    -- devuelve NULL, y `full_name` es NOT NULL: sin el último eslabón, un
    -- alta sin correo aborta el registro en Auth con un 500 opaco.
    IF length(v_nombre) < 3 THEN
        v_nombre := coalesce(
            nullif(split_part(coalesce(NEW.email, ''), '@', 1), ''),
            NEW.phone,
            'Usuario ' || left(NEW.id::text, 8)
        );
    END IF;

    INSERT INTO public.profiles (id, full_name, email, role, is_active)
    VALUES (
        NEW.id,
        left(v_nombre, 120),
        lower(NEW.email),
        'TECNICO'::public.app_role,   -- CONSTANTE. No se lee del metadata.
        TRUE
    );

    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.handle_new_user() FROM PUBLIC;

CREATE TRIGGER on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();


-- ---------------------------------------------------------------------
--  2.2  Anti-autoescalada en UPDATE de profiles
-- ---------------------------------------------------------------------
-- La política RLS deja a un usuario editar SU propia fila (para cambiar
-- su nombre). Sin este trigger, ese mismo UPDATE podría llevar
-- role='ADMIN'. La RLS decide QUÉ FILA se toca; este trigger decide QUÉ
-- COLUMNAS. Hacen falta los dos.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.proteger_columnas_de_profile()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_rol_actor public.app_role;
BEGIN
    -- El id y el email jamás se editan desde la aplicación.
    IF NEW.id IS DISTINCT FROM OLD.id THEN
        RAISE EXCEPTION 'El identificador del perfil es inmutable';
    END IF;

    -- El correo solo lo mueve el trigger de sincronización (§2.3), que se
    -- identifica con una marca local a la transacción. Sin esta excepción los
    -- dos triggers se pelean: cambiar el correo en Supabase Auth dispara la
    -- sincronización, que hace UPDATE sobre profiles, que dispara ESTE
    -- trigger, que aborta — y el cambio de correo falla en Auth.
    IF NEW.email IS DISTINCT FROM OLD.email
       AND coalesce(current_setting('pt.sync_email', TRUE), '') <> '1' THEN
        RAISE EXCEPTION 'El correo se cambia en Supabase Auth, no en profiles';
    END IF;

    IF NEW.role IS NOT DISTINCT FROM OLD.role
       AND NEW.is_active IS NOT DISTINCT FROM OLD.is_active THEN
        NEW.updated_at := now();
        RETURN NEW;   -- cambio inocuo (nombre): pasa
    END IF;

    -- A partir de aquí se intenta tocar rol o estado de la cuenta.
    --
    -- ARRANQUE EN FRÍO: sin esta salida el sistema nace muerto. Promover
    -- exige ser ADMIN, y el trigger de alta fuerza TECNICO a todo el
    -- mundo: no existiría jamás un primer ADMIN. `auth.uid()` es NULL
    -- cuando no hay JWT de usuario, es decir en el SQL Editor del panel,
    -- en una migración y en service_role. Esos contextos ya bypassean la
    -- RLS por definición, así que la salida no concede nada nuevo: solo
    -- evita que el trigger contradiga a la RLS. Un `authenticated` SIEMPRE
    -- trae `sub`, y `anon` no tiene GRANT de UPDATE sobre profiles.
    IF auth.uid() IS NULL THEN
        NEW.updated_at := now();
        RETURN NEW;
    END IF;

    SELECT p.role INTO v_rol_actor
      FROM public.profiles p
     WHERE p.id = auth.uid();

    IF v_rol_actor IS DISTINCT FROM 'ADMIN' THEN
        RAISE EXCEPTION 'Solo un ADMIN puede cambiar el rol o activar/desactivar cuentas';
    END IF;

    IF NEW.id = auth.uid() AND NEW.role IS DISTINCT FROM OLD.role THEN
        RAISE EXCEPTION 'Un ADMIN no puede cambiar su propio rol (evita quedarse sin ADMIN)';
    END IF;

    NEW.updated_at := now();
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_proteger_profile
    BEFORE UPDATE ON public.profiles
    FOR EACH ROW EXECUTE FUNCTION public.proteger_columnas_de_profile();


-- ---------------------------------------------------------------------
--  2.3  Sincronización del correo espejo
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.sincronizar_email_de_profile()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    -- Marca LOCAL a la transacción (tercer argumento TRUE): se borra sola al
    -- terminar, así que no queda un permiso colgando para el resto de la
    -- sesión. Es la llave que `proteger_columnas_de_profile` reconoce.
    PERFORM set_config('pt.sync_email', '1', TRUE);

    UPDATE public.profiles
       SET email = lower(NEW.email), updated_at = now()
     WHERE id = NEW.id
       AND email IS DISTINCT FROM lower(NEW.email);

    PERFORM set_config('pt.sync_email', '', TRUE);
    RETURN NEW;
END;
$$;

-- Se dispara con AFTER para no interferir con el flujo de confirmación
-- de correo de Supabase.
CREATE TRIGGER on_auth_user_email_changed
    AFTER UPDATE OF email ON auth.users
    FOR EACH ROW
    WHEN (OLD.email IS DISTINCT FROM NEW.email)
    EXECUTE FUNCTION public.sincronizar_email_de_profile();


-- =====================================================================
--  3. FUNCIONES DE ROL  — prevención de recursión infinita en RLS
-- =====================================================================
-- EL PROBLEMA: toda política que diga "si soy ADMIN" necesita leer
-- public.profiles. Si esa lectura la hace el usuario invocante, la RLS
-- de profiles se evalúa otra vez, y esa evaluación vuelve a leer
-- profiles: Postgres aborta con
--   ERROR 42P17: infinite recursion detected in policy for relation "profiles"
--
-- LA SOLUCIÓN: una función SECURITY DEFINER. Se ejecuta como su dueño
-- (postgres), que es dueño de la tabla, y el dueño NO está sujeto a RLS
-- salvo que se declare FORCE ROW LEVEL SECURITY. Por eso este esquema
-- NUNCA usa FORCE sobre profiles: rompería estas funciones.
--
-- Se marcan STABLE para que el planificador las evalúe una vez por
-- sentencia y no una vez por fila.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.mi_rol()
RETURNS public.app_role
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT p.role
      FROM public.profiles p
     WHERE p.id = auth.uid()
       AND p.is_active          -- una cuenta desactivada no tiene rol efectivo
     LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.tiene_rol(VARIADIC roles public.app_role[])
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT coalesce(public.mi_rol() = ANY(roles), FALSE);
$$;

CREATE OR REPLACE FUNCTION public.es_admin()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT public.tiene_rol('ADMIN');
$$;

REVOKE ALL ON FUNCTION public.mi_rol()                          FROM PUBLIC;
REVOKE ALL ON FUNCTION public.tiene_rol(public.app_role[])      FROM PUBLIC;
REVOKE ALL ON FUNCTION public.es_admin()                        FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.mi_rol()                       TO authenticated;
GRANT EXECUTE ON FUNCTION public.tiene_rol(public.app_role[])   TO authenticated;
GRANT EXECUTE ON FUNCTION public.es_admin()                     TO authenticated;


-- ---------------------------------------------------------------------
--  3.1  Utilidad: updated_at
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;




-- =====================================================================
--  4. ÍNDICE
-- =====================================================================
CREATE INDEX idx_profiles_role ON public.profiles (role) WHERE is_active;


-- =====================================================================
--  5. GRANTS — cerrar antes de abrir
-- =====================================================================
-- Supabase configura ALTER DEFAULT PRIVILEGES que concede permisos sobre
-- cada tabla y función NUEVA del esquema `public` a `anon` y
-- `authenticated`. Eso deja la RLS como ÚNICA capa. Aquí se revoca primero
-- —nombrando a esos dos roles, porque un REVOKE a PUBLIC no toca una
-- concesión directa— y se concede solo lo necesario. Así son dos capas.
-- `anon` no recibe nada: nadie sin sesión tiene por qué tocar el personal.

REVOKE ALL ON ALL TABLES    IN SCHEMA public FROM PUBLIC, anon, authenticated;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC, anon, authenticated;

GRANT USAGE ON SCHEMA public TO anon, authenticated;
GRANT SELECT, UPDATE ON public.profiles TO authenticated;
GRANT EXECUTE ON FUNCTION public.mi_rol()                     TO authenticated;
GRANT EXECUTE ON FUNCTION public.tiene_rol(public.app_role[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.es_admin()                   TO authenticated;
-- Sin INSERT: los perfiles los crea el trigger `handle_new_user`.
-- Sin DELETE: baja lógica con `is_active`; borrar rompe la auditoría.


-- =====================================================================
--  6. ROW LEVEL SECURITY
-- =====================================================================
-- IMPORTANTE: NO se usa FORCE ROW LEVEL SECURITY. El dueño de la tabla
-- (postgres) debe poder saltarse la RLS para que las funciones
-- SECURITY DEFINER de la sección 3 no entren en recursión infinita (42P17).

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

-- Tu propia fila SIEMPRE es visible: es lo que permite al frontend leer
-- `is_active = false` y expulsarte. Las de los demás solo si tienes un rol
-- efectivo (`mi_rol()` devuelve NULL para una cuenta desactivada), así que
-- una cuenta dada de baja no puede seguir enumerando al personal.
CREATE POLICY prof_select ON public.profiles
    FOR SELECT TO authenticated
    USING (id = auth.uid() OR public.mi_rol() IS NOT NULL);

CREATE POLICY prof_update_propio ON public.profiles
    FOR UPDATE TO authenticated
    USING (id = auth.uid())
    WITH CHECK (id = auth.uid());
-- QUÉ FILA se puede tocar lo decide esta policy; QUÉ COLUMNAS lo decide el
-- trigger `proteger_columnas_de_profile` (§2.2). Hacen falta las dos: una
-- policy que solo mire el rol del actor deja que un ADMIN se degrade solo.

CREATE POLICY prof_update_admin ON public.profiles
    FOR UPDATE TO authenticated
    USING (public.es_admin())
    WITH CHECK (public.es_admin());

-- Sin policy de INSERT (lo hace el trigger de auth) y sin policy de DELETE.

COMMIT;


-- =====================================================================
--  POST-INSTALACIÓN  (manual, fuera de la transacción)
-- =====================================================================
--
-- 1) PRIMER ADMIN. El trigger fuerza TECNICO a todo el mundo, así que el
--    primero se promueve a mano, una sola vez, desde este mismo SQL Editor.
--    Funciona porque aquí `auth.uid()` es NULL y el trigger §2.2 tiene esa
--    salida de arranque en frío declarada:
--
--      UPDATE public.profiles
--         SET role = 'ADMIN'
--       WHERE email = 'samuel.silva@ea2technology.com';
--
-- 2) DESACTIVAR EL REGISTRO PÚBLICO. Authentication -> Providers -> Email,
--    apagar "Enable Sign Ups". Sin eso, cualquiera con la anon key se crea
--    una cuenta TECNICO y entra al sistema.
--
-- 3) LA CLAVE service_role NUNCA EN EL FRONTEND. Bypassea toda esta RLS.
--    En el navegador solo la anon / publishable key.
--
-- 4) VERIFICACIÓN. Con la anon key, esto debe dar permiso denegado:
--        select * from profiles;
--    Con un JWT de TECNICO, esto debe fallar:
--        update profiles set role='ADMIN' where id = auth.uid();
-- =====================================================================
