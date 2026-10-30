-- =====================================================================
--  Prime Telecom · Track Garantía
--  Migración inicial — Supabase / PostgreSQL 15
--  Fecha: 2026-09-06
--
--  Decisión de arquitectura vigente: la identidad la provee Supabase Auth.
--  El módulo `prime.identity` (Flask/SQLAlchemy) queda ARCHIVADO. Ninguna
--  tabla de este esquema referencia `prime.users`; la única fuente de
--  verdad sobre "quién es quién" es `auth.users` + `public.profiles`.
--
--  Trade-off aceptado y documentado en la tesis: se pierde el OTP por
--  correo obligatorio en cada login (directiva CISO nº 6). Supabase Auth
--  ofrece MFA por TOTP como sustituto; se habilita para ADMIN y
--  JEFE_SERVICIO desde el panel, no desde este esquema.
--
--  ORDEN DE EJECUCIÓN: este fichero es idempotente en su cabecera pero
--  NO en su totalidad. Ejecutar una sola vez sobre una base limpia.
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

CREATE TYPE public.tipo_documento AS ENUM (
    'V',  -- cédula venezolana
    'E',  -- cédula de extranjero
    'J',  -- RIF jurídico
    'G',  -- RIF gubernamental
    'P'   -- pasaporte
);

CREATE TYPE public.cobertura_garantia AS ENUM (
    'POR_DETERMINAR',    -- estado inicial: aún no se evaluó
    'EN_GARANTIA',       -- cubierta por el fabricante
    'FUERA_DE_GARANTIA', -- vencida por fecha
    'ANULADA_POR_USO'    -- vigente por fecha, pero anulada (golpe, humedad, apertura)
);

-- NOTA sobre `estado`: deliberadamente NO es un ENUM.
-- Un ENUM de Postgres no permite borrar ni reordenar valores, y este
-- catálogo va a crecer. Se modela como tabla + FK (§4).


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
--  4. CATÁLOGOS
-- =====================================================================

-- ---------------------------------------------------------------------
--  4.1  Estados de la garantía  (tabla, no ENUM)
-- ---------------------------------------------------------------------
CREATE TABLE public.estados_garantia (
    codigo      TEXT PRIMARY KEY CHECK (codigo = upper(codigo) AND codigo ~ '^[A-Z_]{3,40}$'),
    nombre      TEXT NOT NULL,
    descripcion TEXT,
    orden       SMALLINT NOT NULL,       -- para ordenar en la UI
    es_final    BOOLEAN NOT NULL DEFAULT FALSE,  -- estado terminal: sin transiciones de salida
    activo      BOOLEAN NOT NULL DEFAULT TRUE
);

INSERT INTO public.estados_garantia (codigo, nombre, descripcion, orden, es_final) VALUES
    ('RECIBIDO',              'Recibido',               'El equipo ingresó al taller y se generó la orden',       10, FALSE),
    ('EN_DIAGNOSTICO',        'En diagnóstico',         'Un técnico está evaluando la falla',                     20, FALSE),
    ('PRESUPUESTADO',         'Presupuestado',          'Diagnóstico listo; se espera aprobación del cliente',    30, FALSE),
    ('EN_ESPERA_REPUESTO',    'En espera de repuesto',  'Aprobado, pero falta una pieza',                         40, FALSE),
    ('EN_REPARACION',         'En reparación',          'Trabajo en curso',                                       50, FALSE),
    ('REPARADO',              'Reparado',               'Listo para entrega',                                     60, FALSE),
    ('IRREPARABLE',           'Irreparable',            'No tiene solución; se devuelve sin reparar',             70, FALSE),
    ('RECHAZADO_POR_CLIENTE', 'Rechazado por cliente',  'El cliente no aprobó el presupuesto',                    80, FALSE),
    ('ENTREGADO',             'Entregado',              'El equipo salió del taller. Fin del ciclo',              90, TRUE),
    ('ANULADO',               'Anulado',                'Orden creada por error o abandonada',                    99, TRUE);


-- ---------------------------------------------------------------------
--  4.2  Máquina de estados
-- ---------------------------------------------------------------------
-- HALLAZGO CORREGIDO: en el DDL anterior nada impedía pasar de ENTREGADO
-- a RECIBIDO, ni entregar un equipo sin haberlo diagnosticado. El estado
-- era un campo libre con nombre bonito.
-- ---------------------------------------------------------------------
CREATE TABLE public.transiciones_estado (
    desde         TEXT NOT NULL REFERENCES public.estados_garantia(codigo) ON DELETE RESTRICT,
    hasta         TEXT NOT NULL REFERENCES public.estados_garantia(codigo) ON DELETE RESTRICT,
    -- NULL = cualquier rol con permiso de UPDATE sobre la fila
    roles_permitidos public.app_role[] NULL,
    PRIMARY KEY (desde, hasta),
    CHECK (desde <> hasta)
);

INSERT INTO public.transiciones_estado (desde, hasta, roles_permitidos) VALUES
    ('RECIBIDO',           'EN_DIAGNOSTICO',        NULL),
    ('RECIBIDO',           'ANULADO',               ARRAY['ADMIN','JEFE_SERVICIO']::public.app_role[]),

    ('EN_DIAGNOSTICO',     'PRESUPUESTADO',         NULL),
    ('EN_DIAGNOSTICO',     'EN_REPARACION',         NULL),   -- cubierta por garantía: no se presupuesta
    ('EN_DIAGNOSTICO',     'IRREPARABLE',           NULL),
    ('EN_DIAGNOSTICO',     'ANULADO',               ARRAY['ADMIN','JEFE_SERVICIO']::public.app_role[]),

    ('PRESUPUESTADO',      'EN_ESPERA_REPUESTO',    NULL),
    ('PRESUPUESTADO',      'EN_REPARACION',         NULL),
    ('PRESUPUESTADO',      'RECHAZADO_POR_CLIENTE', NULL),
    ('PRESUPUESTADO',      'IRREPARABLE',           NULL),

    ('EN_ESPERA_REPUESTO', 'EN_REPARACION',         NULL),
    ('EN_ESPERA_REPUESTO', 'IRREPARABLE',           NULL),
    ('EN_ESPERA_REPUESTO', 'RECHAZADO_POR_CLIENTE', NULL),

    ('EN_REPARACION',      'REPARADO',              NULL),
    ('EN_REPARACION',      'IRREPARABLE',           NULL),
    ('EN_REPARACION',      'EN_ESPERA_REPUESTO',    NULL),   -- apareció otra pieza faltante

    ('REPARADO',              'ENTREGADO',          ARRAY['ADMIN','JEFE_SERVICIO','RECEPCION']::public.app_role[]),
    ('IRREPARABLE',           'ENTREGADO',          ARRAY['ADMIN','JEFE_SERVICIO','RECEPCION']::public.app_role[]),
    ('RECHAZADO_POR_CLIENTE', 'ENTREGADO',          ARRAY['ADMIN','JEFE_SERVICIO','RECEPCION']::public.app_role[]);
-- ENTREGADO y ANULADO no tienen salidas: son terminales por construcción.


-- ---------------------------------------------------------------------
--  4.3  Marcas y productos
-- ---------------------------------------------------------------------
-- HALLAZGO CORREGIDO: `equipo` y `marca_modelo` como texto libre hacen
-- imposible el reporte "qué modelo falla más", que es justamente el valor
-- de negocio del sistema. Con texto libre, "Samsung A54", "samsung a-54"
-- y "SAMSUNG  A54" son tres productos distintos.
-- ---------------------------------------------------------------------
CREATE TABLE public.marcas (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    nombre     TEXT NOT NULL CHECK (length(btrim(nombre)) BETWEEN 2 AND 60),
    activo     BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX uq_marcas_nombre ON public.marcas (lower(btrim(nombre)));

CREATE TABLE public.productos (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    marca_id        UUID NOT NULL REFERENCES public.marcas(id) ON DELETE RESTRICT,
    modelo          TEXT NOT NULL CHECK (length(btrim(modelo)) BETWEEN 1 AND 80),
    categoria       TEXT NOT NULL,       -- 'ROUTER', 'ONT', 'DECODIFICADOR', 'TELEFONO', ...
    -- Meses de garantía del fabricante. Es el insumo del cálculo de
    -- cobertura: sin este dato, "¿está en garantía?" no tiene respuesta.
    meses_garantia  SMALLINT NOT NULL DEFAULT 12 CHECK (meses_garantia BETWEEN 0 AND 120),
    activo          BOOLEAN NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX uq_productos_marca_modelo
    ON public.productos (marca_id, lower(btrim(modelo)));
CREATE INDEX idx_productos_categoria ON public.productos (categoria) WHERE activo;

CREATE TRIGGER trg_productos_updated_at
    BEFORE UPDATE ON public.productos
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


-- =====================================================================
--  5. CLIENTES
-- =====================================================================
-- HALLAZGO CORREGIDO: cliente_nombre / cliente_documento / cliente_email
-- estaban denormalizados dentro de cada garantía. El segundo equipo del
-- mismo cliente duplicaba y divergía los datos, y "todas las garantías de
-- Juan" solo salía bien si Juan había escrito su nombre igual las dos veces.
-- =====================================================================
CREATE TABLE public.clientes (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tipo_documento  public.tipo_documento NOT NULL DEFAULT 'V',
    -- Solo dígitos, normalizado por la aplicación y verificado aquí.
    documento       TEXT NOT NULL CHECK (documento ~ '^[0-9]{5,15}$'),
    nombre          TEXT NOT NULL CHECK (length(btrim(nombre)) BETWEEN 3 AND 160),
    telefono        TEXT CHECK (telefono IS NULL OR telefono ~ '^[0-9+][0-9]{6,19}$'),
    email           TEXT CHECK (email IS NULL OR (email = lower(email) AND email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$')),
    direccion       TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT uq_clientes_documento UNIQUE (tipo_documento, documento)
);

CREATE INDEX idx_clientes_nombre_trgm ON public.clientes (lower(nombre) text_pattern_ops);

CREATE TRIGGER trg_clientes_updated_at
    BEFORE UPDATE ON public.clientes
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


-- =====================================================================
--  6. GARANTÍAS
-- =====================================================================

-- Numeración legible y secuencial. HALLAZGO CORREGIDO: el
-- 'ORD-' || md5(random()) del DDL anterior colisionaba (paradoja del
-- cumpleaños sobre 16.7M valores ⇒ choques con unos pocos miles de
-- órdenes) y, siendo UNIQUE, cada colisión era un error en la cara del
-- recepcionista. Además nadie dicta "ORD-a3f9c1" por teléfono sin
-- equivocarse.
CREATE SEQUENCE public.garantias_numero_seq;

CREATE TABLE public.garantias (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    numero_orden    TEXT NOT NULL UNIQUE
                    DEFAULT ('ORD-' || to_char(now(), 'YYYY') || '-'
                             || lpad(nextval('public.garantias_numero_seq')::text, 6, '0')),

    -- ===== SECRETO DE CONSULTA PÚBLICA =====
    -- HALLAZGO CORREGIDO: antes el cliente consultaba con su cédula. Una
    -- cédula no es un secreto: es corta, enumerable y de dominio público.
    -- Con ella cualquiera listaba nombre, correo, equipo y número de serie
    -- de todas las garantías de esa persona.
    -- Ahora hace falta el par (numero_orden + token de 128 bits), y el
    -- token SOLO se guarda hasheado: un volcado de esta tabla no permite
    -- consultar nada. El texto plano existe una única vez, en el valor que
    -- devuelve public.crear_garantia(), y se imprime en el comprobante.
    consulta_token_hash BYTEA NOT NULL UNIQUE,

    cliente_id      UUID NOT NULL REFERENCES public.clientes(id) ON DELETE RESTRICT,
    producto_id     UUID NOT NULL REFERENCES public.productos(id) ON DELETE RESTRICT,

    numero_serie    TEXT CHECK (numero_serie IS NULL OR length(btrim(numero_serie)) BETWEEN 3 AND 60),
    accesorios      TEXT,                 -- "cargador, caja, cable"
    falla_reportada TEXT NOT NULL CHECK (length(btrim(falla_reportada)) BETWEEN 5 AND 2000),
    diagnostico     TEXT,                 -- lo que encontró el técnico (visible al cliente)

    -- ===== COBERTURA: el corazón del dominio, que antes no existía =====
    fecha_compra          DATE NOT NULL CHECK (fecha_compra >= DATE '2000-01-01'),
    numero_factura        TEXT,
    -- Calculada por trigger a partir de fecha_compra + producto.meses_garantia.
    garantia_vence_el     DATE NOT NULL,
    cobertura             public.cobertura_garantia NOT NULL DEFAULT 'POR_DETERMINAR',
    motivo_anulacion_cobertura TEXT,       -- obligatorio si cobertura = ANULADA_POR_USO
    costo_reparacion      NUMERIC(12,2) CHECK (costo_reparacion IS NULL OR costo_reparacion >= 0),

    estado          TEXT NOT NULL DEFAULT 'RECIBIDO'
                    REFERENCES public.estados_garantia(codigo) ON DELETE RESTRICT,

    tecnico_asignado_id UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
    creado_por          UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,

    fecha_ingreso   TIMESTAMPTZ NOT NULL DEFAULT now(),
    fecha_entrega   TIMESTAMPTZ,
    recibido_por    TEXT,                 -- quién retiró el equipo, si no fue el titular

    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),

    -- ===== Coherencia temporal y de negocio =====
    CONSTRAINT ck_entrega_posterior_al_ingreso
        CHECK (fecha_entrega IS NULL OR fecha_entrega >= fecha_ingreso),
    CONSTRAINT ck_entregado_tiene_fecha
        CHECK ((estado = 'ENTREGADO') = (fecha_entrega IS NOT NULL)),
    CONSTRAINT ck_anulacion_cobertura_justificada
        CHECK ((cobertura = 'ANULADA_POR_USO') = (motivo_anulacion_cobertura IS NOT NULL)),
    CONSTRAINT ck_costo_solo_si_no_cubierta
        CHECK (costo_reparacion IS NULL OR cobertura <> 'EN_GARANTIA')
);

COMMENT ON TABLE public.garantias IS
'Nunca se borran filas. Una orden creada por error pasa a estado ANULADO.';


-- ---------------------------------------------------------------------
--  6.1  Notas internas — tabla aparte, a propósito
-- ---------------------------------------------------------------------
-- HALLAZGO CORREGIDO: `notas_internas` vivía como columna de `garantias`.
-- Un SELECT * mal filtrado, una policy floja o el propio endpoint de
-- consulta pública la habrían expuesto al cliente. Separada, ninguna ruta
-- que lea `garantias` puede filtrarla por accidente.
-- ---------------------------------------------------------------------
CREATE TABLE public.notas_internas (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    garantia_id UUID NOT NULL REFERENCES public.garantias(id) ON DELETE CASCADE,
    autor_id    UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
    nota        TEXT NOT NULL CHECK (length(btrim(nota)) BETWEEN 1 AND 4000),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);


-- ---------------------------------------------------------------------
--  6.2  Cálculo de la cobertura
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.calcular_vencimiento_garantia()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
    v_meses SMALLINT;
BEGIN
    SELECT p.meses_garantia INTO v_meses
      FROM public.productos p
     WHERE p.id = NEW.producto_id;

    NEW.garantia_vence_el := NEW.fecha_compra + (v_meses || ' months')::interval;

    -- Solo se auto-decide mientras nadie la haya evaluado a mano.
    IF NEW.cobertura = 'POR_DETERMINAR' THEN
        NEW.cobertura := CASE
            WHEN NEW.fecha_ingreso::date <= NEW.garantia_vence_el
                THEN 'EN_GARANTIA'::public.cobertura_garantia
            ELSE 'FUERA_DE_GARANTIA'::public.cobertura_garantia
        END;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_garantias_cobertura
    BEFORE INSERT OR UPDATE OF fecha_compra, producto_id ON public.garantias
    FOR EACH ROW EXECUTE FUNCTION public.calcular_vencimiento_garantia();

CREATE TRIGGER trg_garantias_updated_at
    BEFORE UPDATE ON public.garantias
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


-- =====================================================================
--  7. HISTORIAL — automático e inmutable
-- =====================================================================
-- HALLAZGO CORREGIDO (doble):
--   (a) El historial dependía de que la aplicación se acordara de
--       insertarlo. Un olvido en un solo caso de uso y la auditoría
--       miente en silencio. Ahora lo escribe un trigger: no hay forma de
--       cambiar el estado sin dejar rastro.
--   (b) Solo se guardaba `estado_nuevo`. Sin `estado_anterior` no se
--       reconstruyen las transiciones sin ordenar por fecha y asumir.
-- =====================================================================
CREATE TABLE public.historial_garantias (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    garantia_id     UUID NOT NULL REFERENCES public.garantias(id) ON DELETE CASCADE,
    estado_anterior TEXT REFERENCES public.estados_garantia(codigo) ON DELETE RESTRICT,  -- NULL = alta
    estado_nuevo    TEXT NOT NULL REFERENCES public.estados_garantia(codigo) ON DELETE RESTRICT,
    -- NULL cuando la acción la ejecuta service_role (migración, job).
    modificado_por  UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
    comentario      TEXT,
    creado_en       TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (estado_anterior IS DISTINCT FROM estado_nuevo)
);


-- ---------------------------------------------------------------------
--  7.1  Validación de la transición  (BEFORE)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.validar_transicion_estado()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_roles public.app_role[];
    v_ok    BOOLEAN;
    v_rol   public.app_role;
BEGIN
    IF NEW.estado IS NOT DISTINCT FROM OLD.estado THEN
        RETURN NEW;
    END IF;

    SELECT TRUE, t.roles_permitidos INTO v_ok, v_roles
      FROM public.transiciones_estado t
     WHERE t.desde = OLD.estado AND t.hasta = NEW.estado;

    IF NOT coalesce(v_ok, FALSE) THEN
        RAISE EXCEPTION
            'Transición de estado no permitida: % -> %', OLD.estado, NEW.estado
            USING ERRCODE = '23514';
    END IF;

    IF v_roles IS NOT NULL THEN
        v_rol := public.mi_rol();
        -- service_role (jobs, migraciones) no tiene perfil: se le permite.
        IF v_rol IS NOT NULL AND NOT (v_rol = ANY(v_roles)) THEN
            RAISE EXCEPTION
                'El rol % no puede ejecutar la transición % -> %', v_rol, OLD.estado, NEW.estado
                USING ERRCODE = '42501';
        END IF;
    END IF;

    -- Efectos de borde de la entrega.
    IF NEW.estado = 'ENTREGADO' AND NEW.fecha_entrega IS NULL THEN
        NEW.fecha_entrega := now();
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_validar_transicion
    BEFORE UPDATE OF estado ON public.garantias
    FOR EACH ROW EXECUTE FUNCTION public.validar_transicion_estado();


-- ---------------------------------------------------------------------
--  7.2  Escritura del historial  (AFTER)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.registrar_historial_garantia()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO public.historial_garantias
            (garantia_id, estado_anterior, estado_nuevo, modificado_por, comentario)
        VALUES (NEW.id, NULL, NEW.estado, auth.uid(), 'Orden creada');
        RETURN NEW;
    END IF;

    IF NEW.estado IS DISTINCT FROM OLD.estado THEN
        INSERT INTO public.historial_garantias
            (garantia_id, estado_anterior, estado_nuevo, modificado_por, comentario)
        VALUES (NEW.id, OLD.estado, NEW.estado, auth.uid(),
                nullif(btrim(coalesce(NEW.diagnostico, '')), ''));
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_historial_garantia
    AFTER INSERT OR UPDATE OF estado ON public.garantias
    FOR EACH ROW EXECUTE FUNCTION public.registrar_historial_garantia();


-- ---------------------------------------------------------------------
--  7.3  Inmutabilidad del historial
-- ---------------------------------------------------------------------
-- Dos capas: la RLS no concede UPDATE ni DELETE a nadie (§11), y este
-- trigger lo bloquea incluso para service_role y para el propio postgres,
-- que sí bypassean RLS. Una bitácora editable no es una bitácora.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.historial_es_inmutable()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
    RAISE EXCEPTION 'historial_garantias es de solo anexado: % no está permitido', TG_OP
        USING ERRCODE = '42501';
END;
$$;

CREATE TRIGGER trg_historial_inmutable
    BEFORE UPDATE OR DELETE ON public.historial_garantias
    FOR EACH ROW EXECUTE FUNCTION public.historial_es_inmutable();


-- =====================================================================
--  8. ÍNDICES
-- =====================================================================
-- Postgres NO indexa las claves foráneas automáticamente. Sin estos
-- índices, cada UPDATE/DELETE en clientes, productos o profiles hace un
-- seq scan de garantias.

CREATE INDEX idx_gar_cliente        ON public.garantias (cliente_id);
CREATE INDEX idx_gar_producto       ON public.garantias (producto_id);
CREATE INDEX idx_gar_creado_por     ON public.garantias (creado_por);
CREATE INDEX idx_gar_ingreso        ON public.garantias (fecha_ingreso DESC);

-- PARCIALES: la bandeja de trabajo solo mira órdenes abiertas. El índice
-- excluye los terminales, que con el tiempo serán el 95% de la tabla.
CREATE INDEX idx_gar_abiertas_por_tecnico
    ON public.garantias (tecnico_asignado_id, fecha_ingreso DESC)
    WHERE estado NOT IN ('ENTREGADO', 'ANULADO');

CREATE INDEX idx_gar_abiertas_por_estado
    ON public.garantias (estado, fecha_ingreso DESC)
    WHERE estado NOT IN ('ENTREGADO', 'ANULADO');

CREATE INDEX idx_gar_sin_asignar
    ON public.garantias (fecha_ingreso)
    WHERE tecnico_asignado_id IS NULL AND estado NOT IN ('ENTREGADO', 'ANULADO');

CREATE INDEX idx_hist_garantia      ON public.historial_garantias (garantia_id, creado_en DESC);
CREATE INDEX idx_hist_autor         ON public.historial_garantias (modificado_por, creado_en DESC);
CREATE INDEX idx_notas_garantia     ON public.notas_internas (garantia_id, created_at DESC);
CREATE INDEX idx_notas_autor        ON public.notas_internas (autor_id);
CREATE INDEX idx_profiles_role      ON public.profiles (role) WHERE is_active;


-- =====================================================================
--  9. CONSULTA PÚBLICA  — sin acceso a tablas, solo por RPC
-- =====================================================================
-- El rol `anon` NO recibe ni un GRANT sobre ninguna tabla (§11). La única
-- superficie pública es esta función, que devuelve un subconjunto de
-- columnas elegido a mano: sin correo, sin cédula, sin notas internas,
-- sin costos, sin identidad del técnico.
-- =====================================================================

CREATE TABLE public.consulta_publica_intentos (
    id           BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ip           INET,
    numero_orden TEXT,
    exito        BOOLEAN NOT NULL,
    intentado_en TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_cpi_ip_tiempo ON public.consulta_publica_intentos (ip, intentado_en DESC)
    WHERE NOT exito;

CREATE OR REPLACE FUNCTION public.consultar_garantia(
    p_numero_orden TEXT,
    p_token        TEXT
)
RETURNS TABLE (
    numero_orden    TEXT,
    estado          TEXT,
    estado_nombre   TEXT,
    equipo          TEXT,
    falla_reportada TEXT,
    diagnostico     TEXT,
    cobertura       public.cobertura_garantia,
    fecha_ingreso   TIMESTAMPTZ,
    fecha_entrega   TIMESTAMPTZ,
    actualizado_en  TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_ip       INET;
    v_fallos   INTEGER;
    v_gid      UUID;
BEGIN
    -- IP real del cliente. PostgREST expone las cabeceras del request.
    BEGIN
        v_ip := nullif(btrim(split_part(
                    coalesce(current_setting('request.headers', TRUE)::json ->> 'x-forwarded-for', ''),
                    ',', 1)), '')::inet;
    EXCEPTION WHEN OTHERS THEN
        v_ip := NULL;
    END;

    -- Freno de fuerza bruta. No sustituye a un rate limit en el borde
    -- (Cloudflare / Edge Function), lo complementa: este sobrevive a un
    -- reinicio y cuenta aunque el atacante rote de ruta.
    SELECT count(*) INTO v_fallos
      FROM public.consulta_publica_intentos c
     WHERE c.ip = v_ip
       AND NOT c.exito
       AND c.intentado_en > now() - interval '15 minutes';

    IF v_ip IS NOT NULL AND v_fallos >= 10 THEN
        INSERT INTO public.consulta_publica_intentos (ip, numero_orden, exito)
        VALUES (v_ip, p_numero_orden, FALSE);
        RAISE EXCEPTION 'Demasiadas consultas fallidas. Intente de nuevo en 15 minutos.'
            USING ERRCODE = '53400';
    END IF;

    -- Búsqueda POR EL HASH (indexado y único): no hay oráculo temporal
    -- sobre la existencia del número de orden.
    SELECT g.id INTO v_gid
      FROM public.garantias g
     WHERE g.consulta_token_hash = extensions.digest(coalesce(p_token, ''), 'sha256')
       AND g.numero_orden = upper(btrim(coalesce(p_numero_orden, '')));

    INSERT INTO public.consulta_publica_intentos (ip, numero_orden, exito)
    VALUES (v_ip, p_numero_orden, v_gid IS NOT NULL);

    IF v_gid IS NULL THEN
        -- SE DEVUELVE VACÍO, NO SE LANZA EXCEPCIÓN.
        -- Un RAISE aquí abortaría la transacción y con ella el INSERT en
        -- consulta_publica_intentos de tres líneas más arriba: el contador
        -- de fallos volvería siempre a cero y el freno de fuerza bruta
        -- sería puramente decorativo. (Postgres no tiene transacciones
        -- autónomas; la única forma de que el registro sobreviva es no
        -- abortar.) Cero filas es además la respuesta idéntica para
        -- "no existe" y para "token incorrecto": anti-enumeración intacta.
        RETURN;
    END IF;

    RETURN QUERY
    SELECT g.numero_orden,
           g.estado,
           e.nombre,
           (m.nombre || ' ' || pr.modelo)::TEXT,
           g.falla_reportada,
           g.diagnostico,
           g.cobertura,
           g.fecha_ingreso,
           g.fecha_entrega,
           g.updated_at
      FROM public.garantias g
      JOIN public.estados_garantia e ON e.codigo = g.estado
      JOIN public.productos pr       ON pr.id = g.producto_id
      JOIN public.marcas m           ON m.id = pr.marca_id
     WHERE g.id = v_gid;
END;
$$;

REVOKE ALL ON FUNCTION public.consultar_garantia(TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.consultar_garantia(TEXT, TEXT) TO anon, authenticated;


-- ---------------------------------------------------------------------
--  9.1  Alta de orden — único camino de creación
-- ---------------------------------------------------------------------
-- No existe policy de INSERT sobre `garantias` (§11). Se crea solo por
-- aquí, porque es el único punto donde el token en claro existe y puede
-- devolverse exactamente una vez.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.crear_garantia(
    p_cliente_id      UUID,
    p_producto_id     UUID,
    p_fecha_compra    DATE,
    p_falla_reportada TEXT,
    p_numero_serie    TEXT DEFAULT NULL,
    p_numero_factura  TEXT DEFAULT NULL,
    p_accesorios      TEXT DEFAULT NULL
)
RETURNS TABLE (
    garantia_id    UUID,
    numero_orden   TEXT,
    consulta_token TEXT,   -- TEXTO PLANO. Se devuelve UNA vez. Imprimir y olvidar.
    cobertura      public.cobertura_garantia,
    vence_el       DATE
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_token TEXT;
    v_actor UUID := auth.uid();
BEGIN
    IF NOT public.tiene_rol('ADMIN', 'JEFE_SERVICIO', 'RECEPCION') THEN
        RAISE EXCEPTION 'Su rol no puede registrar órdenes' USING ERRCODE = '42501';
    END IF;

    -- 128 bits del CSPRNG del sistema.
    v_token := encode(extensions.gen_random_bytes(16), 'hex');

    RETURN QUERY
    INSERT INTO public.garantias (
        consulta_token_hash, cliente_id, producto_id, fecha_compra,
        falla_reportada, numero_serie, numero_factura, accesorios,
        garantia_vence_el, creado_por
    )
    VALUES (
        extensions.digest(v_token, 'sha256'),
        p_cliente_id, p_producto_id, p_fecha_compra,
        btrim(p_falla_reportada), nullif(btrim(coalesce(p_numero_serie, '')), ''),
        nullif(btrim(coalesce(p_numero_factura, '')), ''),
        nullif(btrim(coalesce(p_accesorios, '')), ''),
        p_fecha_compra,          -- el trigger 6.2 lo recalcula
        v_actor
    )
    RETURNING garantias.id, garantias.numero_orden, v_token,
              garantias.cobertura, garantias.garantia_vence_el;
END;
$$;

REVOKE ALL ON FUNCTION public.crear_garantia(UUID, UUID, DATE, TEXT, TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.crear_garantia(UUID, UUID, DATE, TEXT, TEXT, TEXT, TEXT) TO authenticated;


-- =====================================================================
--  10. GRANTS  — cerrar antes de abrir
-- =====================================================================
-- Por defecto Postgres concede a PUBLIC sobre lo nuevo. Se revoca todo y
-- se concede tabla por tabla. `anon` no toca ninguna tabla, jamás.

REVOKE ALL ON ALL TABLES    IN SCHEMA public FROM PUBLIC, anon, authenticated;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM PUBLIC, anon, authenticated;
-- `FROM PUBLIC` NO basta: Supabase configura ALTER DEFAULT PRIVILEGES que
-- concede EXECUTE **directamente** a anon y authenticated sobre cada función
-- nueva del esquema. Un REVOKE que solo apunta a PUBLIC deja esa concesión
-- directa intacta, y el fichero mentiría sobre lo que hace. Se nombran.
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC, anon, authenticated;

GRANT USAGE ON SCHEMA public TO anon, authenticated;

-- Las funciones se re-conceden AQUÍ, después del REVOKE de arriba. Las
-- secciones 3 y 9 ya concedían, pero este REVOKE es posterior y las anulaba:
-- el orden importa, y el efecto era un "permission denied for function
-- mi_rol" en la primera consulta de cualquier usuario.
GRANT EXECUTE ON FUNCTION public.mi_rol()                       TO authenticated;
GRANT EXECUTE ON FUNCTION public.tiene_rol(public.app_role[])   TO authenticated;
GRANT EXECUTE ON FUNCTION public.es_admin()                     TO authenticated;
GRANT EXECUTE ON FUNCTION public.consultar_garantia(TEXT, TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.crear_garantia(UUID, UUID, DATE, TEXT, TEXT, TEXT, TEXT)
                                                                TO authenticated;

GRANT SELECT                         ON public.estados_garantia          TO authenticated;
GRANT SELECT                         ON public.transiciones_estado       TO authenticated;
GRANT SELECT                         ON public.profiles                  TO authenticated;
GRANT UPDATE                         ON public.profiles                  TO authenticated;
GRANT SELECT, INSERT, UPDATE         ON public.clientes                  TO authenticated;
GRANT SELECT, INSERT, UPDATE         ON public.marcas                    TO authenticated;
GRANT SELECT, INSERT, UPDATE         ON public.productos                 TO authenticated;
GRANT SELECT, UPDATE                 ON public.garantias                 TO authenticated;
GRANT SELECT                         ON public.historial_garantias       TO authenticated;
GRANT SELECT, INSERT                 ON public.notas_internas            TO authenticated;
-- Sin DELETE en ninguna tabla, para ningún rol de aplicación.


-- =====================================================================
--  11. ROW LEVEL SECURITY
-- =====================================================================
-- HALLAZGO CORREGIDO: el DDL anterior hacía ENABLE ROW LEVEL SECURITY y
-- no escribía ni una policy. Con RLS activo y cero políticas, `anon` y
-- `authenticated` no ven NADA: la aplicación solo funciona con la clave
-- `service_role`, que bypassea RLS por completo. Si esa clave termina en
-- el frontend —y termina— la base queda abierta y el RLS es decoración.
--
-- IMPORTANTE: en ninguna tabla se usa FORCE ROW LEVEL SECURITY. El dueño
-- (postgres) debe poder saltarse la RLS para que las funciones
-- SECURITY DEFINER de §3 no entren en recursión.
-- =====================================================================

ALTER TABLE public.profiles                  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.clientes                  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.marcas                    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.productos                 ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.garantias                 ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.historial_garantias       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notas_internas            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.estados_garantia          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.transiciones_estado       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.consulta_publica_intentos ENABLE ROW LEVEL SECURITY;
-- consulta_publica_intentos queda con RLS y CERO policies a propósito:
-- solo la función SECURITY DEFINER de §9 la escribe y la lee.

-- ---------- profiles ----------
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
-- Qué columnas puede tocar lo decide el trigger §2.2, no la policy.

CREATE POLICY prof_update_admin ON public.profiles
    FOR UPDATE TO authenticated
    USING (public.es_admin())
    WITH CHECK (public.es_admin());
-- Sin INSERT (lo hace el trigger de auth) y sin DELETE (baja lógica).

-- ---------- catálogos ----------
CREATE POLICY est_select ON public.estados_garantia
    FOR SELECT TO authenticated USING (TRUE);

CREATE POLICY tra_select ON public.transiciones_estado
    FOR SELECT TO authenticated USING (TRUE);

CREATE POLICY marcas_select ON public.marcas
    FOR SELECT TO authenticated USING (TRUE);
CREATE POLICY marcas_write ON public.marcas
    FOR INSERT TO authenticated WITH CHECK (public.tiene_rol('ADMIN', 'JEFE_SERVICIO'));
CREATE POLICY marcas_update ON public.marcas
    FOR UPDATE TO authenticated
    USING (public.tiene_rol('ADMIN', 'JEFE_SERVICIO'))
    WITH CHECK (public.tiene_rol('ADMIN', 'JEFE_SERVICIO'));

CREATE POLICY prod_select ON public.productos
    FOR SELECT TO authenticated USING (TRUE);
CREATE POLICY prod_insert ON public.productos
    FOR INSERT TO authenticated WITH CHECK (public.tiene_rol('ADMIN', 'JEFE_SERVICIO'));
CREATE POLICY prod_update ON public.productos
    FOR UPDATE TO authenticated
    USING (public.tiene_rol('ADMIN', 'JEFE_SERVICIO'))
    WITH CHECK (public.tiene_rol('ADMIN', 'JEFE_SERVICIO'));

-- ---------- clientes ----------
CREATE POLICY cli_select ON public.clientes
    FOR SELECT TO authenticated USING (TRUE);
CREATE POLICY cli_insert ON public.clientes
    FOR INSERT TO authenticated
    WITH CHECK (public.tiene_rol('ADMIN', 'JEFE_SERVICIO', 'RECEPCION'));
CREATE POLICY cli_update ON public.clientes
    FOR UPDATE TO authenticated
    USING (public.tiene_rol('ADMIN', 'JEFE_SERVICIO', 'RECEPCION'))
    WITH CHECK (public.tiene_rol('ADMIN', 'JEFE_SERVICIO', 'RECEPCION'));

-- ---------- garantias ----------
-- Lectura: todo el personal interno ve todas las órdenes. Son cuatro
-- personas en un taller; ocultarle órdenes a un técnico solo genera
-- llamadas al jefe. La restricción real está en la ESCRITURA.
CREATE POLICY gar_select ON public.garantias
    FOR SELECT TO authenticated USING (TRUE);

-- Un TECNICO solo modifica lo que tiene asignado, y no puede reasignarlo
-- ni a sí mismo ni a otro.
CREATE POLICY gar_update_tecnico ON public.garantias
    FOR UPDATE TO authenticated
    USING (
        public.tiene_rol('TECNICO')
        AND tecnico_asignado_id = auth.uid()
        AND estado NOT IN ('ENTREGADO', 'ANULADO')
    )
    WITH CHECK (
        public.tiene_rol('TECNICO')
        AND tecnico_asignado_id = auth.uid()
    );

CREATE POLICY gar_update_supervision ON public.garantias
    FOR UPDATE TO authenticated
    USING (public.tiene_rol('ADMIN', 'JEFE_SERVICIO'))
    WITH CHECK (public.tiene_rol('ADMIN', 'JEFE_SERVICIO'));

-- RECEPCION solo cierra la entrega; el trigger §7.1 limita la transición.
CREATE POLICY gar_update_recepcion ON public.garantias
    FOR UPDATE TO authenticated
    USING (public.tiene_rol('RECEPCION') AND estado IN ('REPARADO', 'IRREPARABLE', 'RECHAZADO_POR_CLIENTE'))
    WITH CHECK (public.tiene_rol('RECEPCION'));

-- Sin policy de INSERT: se crea por public.crear_garantia() (§9.1).
-- Sin policy de DELETE: se anula, no se borra.

-- ---------- historial ----------
CREATE POLICY hist_select ON public.historial_garantias
    FOR SELECT TO authenticated USING (TRUE);
-- Sin INSERT/UPDATE/DELETE para nadie. Lo escribe el trigger §7.2.

-- ---------- notas internas ----------
CREATE POLICY notas_select ON public.notas_internas
    FOR SELECT TO authenticated USING (TRUE);
CREATE POLICY notas_insert ON public.notas_internas
    FOR INSERT TO authenticated WITH CHECK (autor_id = auth.uid());
-- Sin UPDATE ni DELETE: una nota interna escrita es una nota interna.


-- =====================================================================
--  12. SEMILLAS MÍNIMAS
-- =====================================================================
INSERT INTO public.marcas (nombre) VALUES
    ('Huawei'), ('ZTE'), ('TP-Link'), ('Nokia'), ('Genérico')
ON CONFLICT DO NOTHING;

COMMIT;


-- =====================================================================
--  POST-INSTALACIÓN  (fuera de la transacción, manual)
-- =====================================================================
--
-- 1) PRIMER ADMIN. El trigger fuerza TECNICO a todo el mundo, así que el
--    primer administrador se promueve a mano, una sola vez, desde el SQL
--    Editor del panel de Supabase:
--
--      UPDATE public.profiles
--         SET role = 'ADMIN'
--       WHERE email = 'samuel.silva@ea2technology.com';
--
-- 2) DESACTIVAR EL REGISTRO PÚBLICO. En Authentication → Providers →
--    Email, apagar "Enable Sign Ups". No hay auto-servicio de alta: las
--    cuentas las crea un ADMIN por invitación. Es una superficie de
--    ataque menos, igual que en el blueprint original.
--
-- 3) MFA (TOTP). Authentication → Multi-Factor. Obligatorio para ADMIN y
--    JEFE_SERVICIO. Es el sustituto del OTP por correo que se sacrificó.
--
-- 4) LA CLAVE service_role NUNCA VA AL FRONTEND. Bypassea toda la RLS de
--    §11. En el navegador solo la anon key.
--
-- 5) PURGA. `consulta_publica_intentos` crece sin techo. Programar un
--    cron (pg_cron) semanal:
--      DELETE FROM public.consulta_publica_intentos
--       WHERE intentado_en < now() - interval '90 days';
--
-- 6) VERIFICACIÓN. Con la anon key, estas tres deben fallar:
--      select * from garantias;                      -- 0 filas / permiso denegado
--      select * from profiles;                       -- 0 filas / permiso denegado
--      select consultar_garantia('ORD-2026-000001','xx');  -- excepción genérica
--    Y con un JWT de TECNICO:
--      update garantias set estado='ENTREGADO' where id='...';  -- debe fallar
-- =====================================================================
