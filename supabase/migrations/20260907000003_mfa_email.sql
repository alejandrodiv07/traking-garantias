-- =====================================================================
--  Prime Telecom · Track Garantía
--  Migración 3 de 3 — SEGUNDO FACTOR POR CORREO (OTP de 6 dígitos)
--  PostgreSQL / Supabase · 2026-09-07
--
--  ORDEN OBLIGATORIO
--    1. ...0001_auth_base.sql      -> profiles, mi_rol(), RLS
--    2. ...0002_garantias.sql      -> dominio
--    3. este fichero               -> segundo factor
--  Depende de `extensions.gen_random_bytes` (pgcrypto, §0 de la migración 1)
--  y de `public.mi_rol()`, que se REDEFINE aquí (§6).
--
--  =====================================================================
--  TRES DESVIACIONES DELIBERADAS DEL DISEÑO PEDIDO. LÉELAS ANTES DE EJECUTAR.
--  =====================================================================
--
--  (1) `generate_mfa_code()` NO DEVUELVE EL CÓDIGO.
--      Devolver el código a quien lo pide anula el segundo factor por
--      completo. El atacante que ya tiene la contraseña —el único escenario
--      contra el que existe este flujo— autentica, llama a la RPC, lee el
--      código en la pestaña Network de las DevTools y verifica. No necesita
--      el correo. El factor "algo que tengo" se convierte en "algo que
--      cualquiera puede pedir".
--      Aquí la función devuelve `expires_at` (lo único que la interfaz
--      necesita para pintar el contador). El código se queda en la base y
--      solo lo lee el emisor del correo, con `service_role`, del lado del
--      servidor. Ver §7 para las dos formas de conectar Resend.
--
--  (2) EL JOB DE pg_cron NO BORRA POR `expires_at < now() OR is_used`.
--      Borra por `created_at < now() - 15 min`. La razón: la fila usada o
--      expirada es la ÚNICA evidencia de un intento de fuerza bruta y el
--      contador de la ventana anti-mailbomb (§4). Borrarla al minuto le
--      regala al atacante un contador de intentos que se reinicia solo.
--      Un código usado ya es inerte (`is_used = true` lo invalida), así que
--      conservarlo 15 minutos no abre nada y cierra dos cosas.
--
--  (3) LA EXTENSIÓN SE LLAMA `pg_cron`, NO `pgcron`. Y verificar el código
--      en la interfaz no basta: §6 conecta el segundo factor a la RLS. Sin
--      esa sección, `signInWithPassword` ya devolvió un JWT válido y la
--      pantalla del código es decorativa —quien la salte puede consultar
--      PostgREST con ese token igual que si hubiera verificado.
-- =====================================================================

BEGIN;

-- =====================================================================
--  1. TABLA DE CÓDIGOS
-- =====================================================================
-- El código se guarda EN CLARO, a propósito. Hashearlo es teatro: solo hay
-- 10^6 preimágenes y cualquier GPU las recorre en menos de un parpadeo, así
-- que un hash no protege un OTP de 6 dígitos frente a quien ya puede leer la
-- tabla. Lo que la protege es que nadie puede leerla: sin GRANT para `anon`
-- ni `authenticated` (§5), con RLS activa y CERO políticas (§5), y con una
-- vida de 5 minutos.
CREATE TABLE public.email_mfa_codes (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    code        VARCHAR(6) NOT NULL CHECK (code ~ '^[0-9]{6}$'),

    -- Intentos fallidos contra ESTE código. A los 5 se quema (§3). Sin este
    -- contador, 10^6 combinaciones y 5 minutos de vida son ~3.300 intentos
    -- por segundo de trabajo para un script: perfectamente alcanzable.
    intentos    SMALLINT NOT NULL DEFAULT 0 CHECK (intentos >= 0),

    expires_at  TIMESTAMPTZ NOT NULL DEFAULT now() + INTERVAL '5 minutes',
    is_used     BOOLEAN NOT NULL DEFAULT FALSE,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.email_mfa_codes IS
'OTP de correo. Nadie salvo service_role y las funciones SECURITY DEFINER de esta migración la leen. El código nunca viaja al navegador.';

-- Índice para la única consulta caliente: el código vivo más reciente de un
-- usuario (`verify_mfa_code`).
CREATE INDEX idx_mfa_codes_vivo ON public.email_mfa_codes (user_id, created_at DESC)
    WHERE NOT is_used;
-- Para la ventana anti-mailbomb y para el barrido de pg_cron.
CREATE INDEX idx_mfa_codes_created ON public.email_mfa_codes (created_at);


-- =====================================================================
--  2. SESIONES CON SEGUNDO FACTOR SUPERADO
-- =====================================================================
-- Esta tabla es la que hace que el 2FA signifique algo. `verify_mfa_code`
-- no "desbloquea la interfaz": ancla la verificación al `session_id` del
-- JWT que la pidió. Consecuencias, todas buscadas:
--   · Un token robado ANTES de verificar no sirve: le falta su fila.
--   · Cerrar sesión y volver a entrar exige código nuevo (session_id nuevo).
--   · La verificación no es una propiedad del usuario, es una propiedad de
--     ESTA sesión. Verificar en el móvil no valida la del portátil.
CREATE TABLE public.mfa_sesiones (
    session_id    UUID PRIMARY KEY,
    user_id       UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    verificada_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.mfa_sesiones IS
'Una fila = una sesión que superó el segundo factor. Caduca a las 12 h, el mismo plazo que ofrece el checkbox "Mantener la sesión 12 h" del login.';

CREATE INDEX idx_mfa_sesiones_verificada ON public.mfa_sesiones (verificada_at);


-- =====================================================================
--  3. FUNCIONES
-- =====================================================================

-- ---------------------------------------------------------------------
--  3.1  generate_mfa_code()  ->  expires_at
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.generate_mfa_code()
RETURNS TIMESTAMPTZ
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_uid      UUID := auth.uid();
    v_emitidos INTEGER;
    v_bytes    BYTEA;
    v_code     VARCHAR(6);
    v_expira   TIMESTAMPTZ;
BEGIN
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'No hay sesión activa: la contraseña se valida primero';
    END IF;

    -- Ventana anti-mailbomb. El destinatario del correo es una persona real
    -- de la empresa; sin este techo, cualquiera con una contraseña filtrada
    -- puede llenarle la bandeja y quemar la cuota de Resend. 5 por 15 min
    -- cubre de sobra el "no me llegó, reenvía" legítimo.
    SELECT count(*) INTO v_emitidos
      FROM public.email_mfa_codes
     WHERE user_id = v_uid
       AND created_at > now() - INTERVAL '15 minutes';

    IF v_emitidos >= 5 THEN
        -- 54000 = program_limit_exceeded. Llega al cliente como un error
        -- distinguible sin tener que comparar cadenas de texto.
        RAISE EXCEPTION 'Demasiadas solicitudes de código. Espera unos minutos.'
            USING ERRCODE = '54000';
    END IF;

    -- UN SOLO CÓDIGO VIVO POR USUARIO. Pedir uno nuevo invalida el anterior;
    -- si no, cada "reenviar" añade una llave más a la puerta y el atacante
    -- acumula ventanas de 5 minutos solapadas.
    UPDATE public.email_mfa_codes
       SET is_used = TRUE
     WHERE user_id = v_uid AND NOT is_used;

    -- `random()` NO vale aquí: es un PRNG sembrado, no un CSPRNG. pgcrypto sí.
    -- 40 bits -> el sesgo del módulo es de 1 en un millón; irrelevante.
    v_bytes := extensions.gen_random_bytes(5);
    v_code  := lpad(((
          (get_byte(v_bytes,0)::BIGINT << 32)
        + (get_byte(v_bytes,1)::BIGINT << 24)
        + (get_byte(v_bytes,2)::BIGINT << 16)
        + (get_byte(v_bytes,3)::BIGINT <<  8)
        +  get_byte(v_bytes,4)::BIGINT
    ) % 1000000)::TEXT, 6, '0');

    INSERT INTO public.email_mfa_codes (user_id, code)
    VALUES (v_uid, v_code)
    RETURNING expires_at INTO v_expira;

    -- Se devuelve CUÁNDO caduca, no QUÉ código es. Ver desviación (1).
    RETURN v_expira;
END;
$$;

COMMENT ON FUNCTION public.generate_mfa_code() IS
'Emite un OTP y devuelve su caducidad. El código NO se devuelve: lo lee el emisor del correo con service_role.';


-- ---------------------------------------------------------------------
--  3.2  verify_mfa_code(p_code)  ->  boolean
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.verify_mfa_code(p_code VARCHAR)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_uid UUID := auth.uid();
    v_sid UUID;
    v_fila public.email_mfa_codes;
BEGIN
    IF v_uid IS NULL THEN
        RETURN FALSE;
    END IF;

    v_sid := nullif(auth.jwt() ->> 'session_id', '')::UUID;
    IF v_sid IS NULL THEN
        -- Falla RUIDOSAMENTE, y eso es deliberado. Si un día el JWT deja de
        -- traer `session_id`, `mfa_ok()` devolvería false para todo el mundo
        -- y el sistema quedaría cerrado en silencio, sin pista alguna.
        RAISE EXCEPTION 'El JWT no trae session_id: no se puede anclar el segundo factor';
    END IF;

    -- FOR UPDATE serializa los intentos concurrentes: sin el bloqueo, N
    -- peticiones en paralelo leen `intentos` a la vez y el techo de 5 se
    -- convierte en 5 por hilo.
    SELECT * INTO v_fila
      FROM public.email_mfa_codes
     WHERE user_id = v_uid
       AND NOT is_used
       AND expires_at > now()
     ORDER BY created_at DESC
     LIMIT 1
     FOR UPDATE;

    IF NOT FOUND THEN
        RETURN FALSE;   -- sin código vivo: no se distingue de código errado
    END IF;

    IF v_fila.intentos >= 5 THEN
        UPDATE public.email_mfa_codes SET is_used = TRUE WHERE id = v_fila.id;
        RETURN FALSE;
    END IF;

    IF v_fila.code IS DISTINCT FROM btrim(coalesce(p_code, '')) THEN
        UPDATE public.email_mfa_codes
           SET intentos = intentos + 1,
               is_used  = (intentos + 1 >= 5)   -- al quinto fallo se quema
         WHERE id = v_fila.id;
        RETURN FALSE;
    END IF;

    -- Un código se consume UNA vez. El UPDATE va antes de conceder nada.
    UPDATE public.email_mfa_codes SET is_used = TRUE WHERE id = v_fila.id;

    INSERT INTO public.mfa_sesiones (session_id, user_id)
    VALUES (v_sid, v_uid)
    ON CONFLICT (session_id)
    DO UPDATE SET verificada_at = now(), user_id = EXCLUDED.user_id;

    RETURN TRUE;
END;
$$;

COMMENT ON FUNCTION public.verify_mfa_code(VARCHAR) IS
'Consume el OTP vivo del usuario autenticado y marca ESTA sesión como verificada. Devuelve false ante cualquier fallo, sin decir cuál.';


-- ---------------------------------------------------------------------
--  3.3  mfa_ok()  ->  boolean     (el guardia que leen la RLS y la SPA)
-- ---------------------------------------------------------------------
-- STABLE para que el planificador la evalúe una vez por sentencia y no una
-- vez por fila. La caducidad se comprueba AQUÍ y no solo en el barrido de
-- pg_cron: si el cron se detiene, el permiso caduca igual.
CREATE OR REPLACE FUNCTION public.mfa_ok()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT EXISTS (
        SELECT 1
          FROM public.mfa_sesiones s
         WHERE s.user_id    = auth.uid()
           AND s.session_id = nullif(auth.jwt() ->> 'session_id', '')::UUID
           AND s.verificada_at > now() - INTERVAL '12 hours'
    );
$$;


-- ---------------------------------------------------------------------
--  3.4  mfa_limpiar()  ->  filas borradas   (lo que ejecuta pg_cron)
-- ---------------------------------------------------------------------
-- Es una función y no SQL suelto dentro de `cron.schedule` para poder
-- probarla sin pg_cron instalado, que es justo lo que hace 96_pruebas_mfa.
CREATE OR REPLACE FUNCTION public.mfa_limpiar()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_borradas INTEGER;
BEGIN
    DELETE FROM public.email_mfa_codes
     WHERE created_at < now() - INTERVAL '15 minutes';
    GET DIAGNOSTICS v_borradas = ROW_COUNT;

    DELETE FROM public.mfa_sesiones
     WHERE verificada_at < now() - INTERVAL '12 hours';

    RETURN v_borradas;
END;
$$;


-- =====================================================================
--  5. GRANTS Y RLS — cerrar antes de abrir
-- =====================================================================
-- Supabase tiene ALTER DEFAULT PRIVILEGES que concede permisos sobre cada
-- tabla NUEVA de `public` a anon y authenticated. La migración 1 revocó lo
-- que existía ENTONCES; estas dos tablas nacen después, así que hay que
-- revocarlas explícitamente. Sin esto, `select * from email_mfa_codes`
-- desde el navegador devuelve los códigos de todo el mundo.
REVOKE ALL ON public.email_mfa_codes FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.mfa_sesiones    FROM PUBLIC, anon, authenticated;

-- RLS activa y CERO políticas = denegar todo. Doble capa: aunque un GRANT
-- se cuele en el futuro, no hay política que devuelva una sola fila.
-- Las funciones de §3 son SECURITY DEFINER y su dueño no está sujeto a RLS.
ALTER TABLE public.email_mfa_codes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.mfa_sesiones    ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON FUNCTION public.generate_mfa_code()          FROM PUBLIC;
REVOKE ALL ON FUNCTION public.verify_mfa_code(VARCHAR)     FROM PUBLIC;
REVOKE ALL ON FUNCTION public.mfa_ok()                     FROM PUBLIC;
REVOKE ALL ON FUNCTION public.mfa_limpiar()                FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.generate_mfa_code()       TO authenticated;
GRANT EXECUTE ON FUNCTION public.verify_mfa_code(VARCHAR)  TO authenticated;
GRANT EXECUTE ON FUNCTION public.mfa_ok()                  TO authenticated;
-- `mfa_limpiar()` a nadie: la ejecuta pg_cron como `postgres`. Un usuario
-- con permiso de limpieza es un usuario que puede borrar la evidencia.
-- `anon` no recibe nada: sin sesión no hay segundo factor que emitir.


-- =====================================================================
--  6. CONEXIÓN CON LA RLS — lo que convierte la pantalla en seguridad
-- =====================================================================
-- `mi_rol()` es el cuello de botella de TODO el esquema: las 20 políticas
-- de `...0002_garantias.sql` preguntan por él a través de `tiene_rol()` y
-- `es_admin()`. Añadirle `mfa_ok()` cierra el sistema entero con una línea,
-- sin tocar ni una política.
--
-- EFECTO INMEDIATO AL EJECUTAR ESTO, para que no te sorprenda:
--   · Toda sesión abierta pasa a tener rol NULL hasta que verifique un
--     código. Los paneles se ven vacíos, no dan error.
--   · `profiles` sigue devolviendo TU PROPIA fila (la política
--     `prof_select` la concede por `id = auth.uid()`, sin pasar por
--     `mi_rol()`). Es imprescindible: es lo que deja al frontend leer el
--     perfil y decidir a qué panel llevarte DESPUÉS de verificar.
--   · El SQL Editor y `service_role` no se ven afectados: allí `auth.uid()`
--     es NULL y ya bypasseaban la RLS.
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
       AND p.is_active
       AND public.mfa_ok()   -- sin segundo factor no hay rol efectivo
     LIMIT 1;
$$;

COMMIT;


-- =====================================================================
--  7. pg_cron  (FUERA de la transacción: CREATE EXTENSION toca el clúster)
-- =====================================================================
-- El nombre es `pg_cron`. En Supabase se habilita desde
-- Database -> Extensions, o con este SQL si tu rol lo permite. El bloque
-- está guardado con `pg_available_extensions` para que las pruebas locales
-- con psql (donde pg_cron no existe) no aborten la migración.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_cron') THEN
        RAISE NOTICE 'pg_cron no está disponible en este clúster: se omite el job. La caducidad NO depende de él (ver mfa_ok / verify_mfa_code).';
        RETURN;
    END IF;

    EXECUTE 'CREATE EXTENSION IF NOT EXISTS pg_cron';

    -- cron.schedule con nombre es idempotente desde pg_cron 1.4: volver a
    -- correr la migración reprograma el job en vez de duplicarlo.
    PERFORM cron.schedule(
        'mfa_limpiar',
        '* * * * *',
        'SELECT public.mfa_limpiar()'
    );
END;
$$;


-- =====================================================================
--  POST-INSTALACIÓN  (manual)
-- =====================================================================
--
-- 1) VERIFICAR QUE EL CÓDIGO NO SE ESCAPA. Con la anon key y un JWT de
--    usuario, estas dos deben fallar o devolver cero filas:
--        select * from email_mfa_codes;
--        select * from mfa_sesiones;
--    Y esta debe devolver un timestamp, NUNCA un número de 6 cifras:
--        select generate_mfa_code();
--
-- 2) MIENTRAS RESEND NO ESTÉ CONECTADO, el código se lee aquí:
--        select code, expires_at from email_mfa_codes
--         where user_id = (select id from auth.users where email = 'tu@correo')
--         order by created_at desc limit 1;
--    Es el modo de pruebas de este paso: el flujo completo funciona, el
--    "canal" eres tú leyendo el SQL Editor.
--
-- 3) LAS DOS FORMAS DE CONECTAR RESEND, y ninguna pasa por el navegador:
--
--    a) Edge Function `mfa-enviar-codigo` (recomendada, y el patrón que ya
--       usa `admin-crear-usuario`). Dos clientes dentro de la función:
--         · uno con la anon key + el header Authorization del que llama,
--           para invocar `generate_mfa_code()` -> así `auth.uid()` es el
--           usuario real y la RPC aplica su propio límite de emisión;
--         · uno con service_role, para leer el `code` recién insertado y
--           mandarlo a la API de Resend.
--       RESEND_API_KEY va en los secretos de la función. Y la función NO
--       registra el código en el log: un `console.log` ahí lo deja escrito
--       en los logs de Supabase, donde no caduca a los 5 minutos.
--
--    b) `pg_net` + Vault, sin Edge Function: guardas la clave con
--       `vault.create_secret('re_...', 'resend_api_key')` y `generate_mfa_code`
--       termina con un `net.http_post` a la API de Resend. Menos piezas,
--       pero el correo se manda dentro de la transacción del login y los
--       fallos de red se te aparecen como fallos de la RPC.
--
-- 4) EL CANAL ES EL LÍMITE HONESTO DE ESTE DISEÑO. Este segundo factor
--    protege contra contraseña filtrada, reutilizada o adivinada, que es el
--    vector real en un B2B cerrado. NO protege contra un buzón corporativo
--    comprometido: quien lee el correo recibe el código, y además puede
--    pedir un "olvidé mi contraseña". Si algún día hace falta subir ese
--    techo, lo que toca es un SEGUNDO CANAL (WhatsApp), no otro correo.
--    El TOTP quedó descartado por directiva del proyecto (ADR-004).
--
-- 5) SPF, DKIM y DMARC del dominio en Resend antes de producción. Un OTP
--    que cae en spam es una puerta cerrada para el usuario legítimo, y el
--    remedio que la gente improvisa —reenviar diez veces— choca con el
--    límite del punto 3.
-- =====================================================================
