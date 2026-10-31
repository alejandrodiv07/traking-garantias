-- Track Garantía: migraciones 20261030000004 a 20261030000023, en orden.
-- Pegar en el SQL Editor de Supabase. Va en UNA transacción: si algo falla, no se aplica nada.
BEGIN;

-- =================== 20261030000004_ajustes_y_cobertura.sql ===================
-- =====================================================================
--  20261030000004_ajustes_y_cobertura.sql
--  Cimientos del hito "registro y control de garantía": zona horaria del
--  taller, umbrales de urgencia/SLA editables solo por ADMIN, y (en la
--  tarea siguiente) la función única de cobertura.
--  Spec: docs/superpowers/specs/2026-10-29-registro-y-control-de-garantia-design.md §4.1, §4.5
-- =====================================================================

-- ---------------------------------------------------------------------
--  1. HOY_LOCAL  —  el día del taller, no el día del servidor
-- ---------------------------------------------------------------------
-- "Hoy" se evalúa en la zona horaria del taller (America/Caracas, UTC−4)
-- para que el cambio de día no dependa de dónde corra Postgres. Toda la
-- vigencia (días restantes, niveles de urgencia) pasa por esta función.
CREATE OR REPLACE FUNCTION public.hoy_local(p_ahora timestamptz DEFAULT now())
RETURNS date
LANGUAGE sql STABLE AS $$
  SELECT (p_ahora AT TIME ZONE 'America/Caracas')::date;
$$;

GRANT EXECUTE ON FUNCTION public.hoy_local(timestamptz)
  TO anon, authenticated, service_role;

-- ---------------------------------------------------------------------
--  2. AJUSTES  —  umbrales del Tablero y del SLA
-- ---------------------------------------------------------------------
-- Los niveles de urgencia (crítica = 1–3 días, pronto = 4–7) y de SLA
-- (alerta = 7, crítico = 15 días en taller) son ajustes, no reglas
-- cocinadas en el código: el ADMIN los afina con el taller.
CREATE TABLE public.ajustes (
    clave  TEXT PRIMARY KEY,
    valor  INTEGER NOT NULL
);

INSERT INTO public.ajustes (clave, valor) VALUES
  ('umbral_critico', 3),
  ('umbral_pronto',  7),
  ('sla_alerta',     7),
  ('sla_critico',    15)
ON CONFLICT (clave) DO NOTHING;

ALTER TABLE public.ajustes ENABLE ROW LEVEL SECURITY;

-- Leer: los roles internos del taller (todos ven el Tablero).
CREATE POLICY ajustes_lectura ON public.ajustes
    FOR SELECT TO authenticated
    USING (public.mi_rol() IN ('ADMIN', 'JEFE_SERVICIO', 'TECNICO', 'RECEPCION'));

-- Escribir: solo el ADMIN edita los umbrales.
CREATE POLICY ajustes_admin ON public.ajustes
    FOR UPDATE TO authenticated
    USING (public.mi_rol() = 'ADMIN')
    WITH CHECK (public.mi_rol() = 'ADMIN');

REVOKE ALL ON public.ajustes FROM anon;
GRANT SELECT ON public.ajustes TO authenticated;
GRANT UPDATE ON public.ajustes TO authenticated;

-- Lector de conveniencia, STABLE para que el planner la evalúe como constante
-- dentro de las funciones que calculan urgencia.
CREATE OR REPLACE FUNCTION public.ajuste(p_clave text) RETURNS integer
LANGUAGE sql STABLE AS $$
  SELECT valor FROM public.ajustes WHERE clave = p_clave;
$$;

GRANT EXECUTE ON FUNCTION public.ajuste(text) TO authenticated, service_role;

-- ---------------------------------------------------------------------
--  3. CALCULAR_COBERTURA  —  la única fuente de verdad (spec §4.2)
-- ---------------------------------------------------------------------
-- Función PURA: ningún trigger ni columna generada la duplica. La UI la
-- llama en vivo (paso Verificación del asistente) y la base la aplica al
-- guardar la revisión. El resultado lo emite SIEMPRE la base; el cliente
-- solo aporta la lista de verificación.
--
-- Estructura del checklist (spec §4.3):
--   {"condiciones":{"factura_presentada":true,"titular_coincide":true},
--    "equipo":{"serial_legible":true,"caja_original":true,
--              "precintos_intactos":true,"contenido_completo":true},
--    "senales":{"descarga_electrica":false,"liquidos":false,
--               "altas_temperaturas":false,"golpes":false,
--               "manipulacion_terceros":false}}
-- En `condiciones` y `equipo` el FALSE es un incumplimiento; en `senales`
-- el TRUE es una señal observada.
CREATE OR REPLACE FUNCTION public.calcular_cobertura(
    p_vence_el      date,
    p_fecha_ingreso date,
    p_checklist     jsonb DEFAULT NULL)
RETURNS public.cobertura_garantia
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_terms     jsonb := '["serial_legible","caja_original","precintos_intactos","contenido_completo"]'::jsonb;
    v_condiciones jsonb := '["factura_presentada","titular_coincide"]'::jsonb;
    v_senales   jsonb := '["descarga_electrica","liquidos","altas_temperaturas","golpes","manipulacion_terceros"]'::jsonb;
    k text;
    incumple_termino    boolean := false;
    senal_observada     boolean := false;
    incumple_condicion  boolean := false;
BEGIN
    -- 1. Sin fecha de vencimiento: se recibió sin factura.
    IF p_vence_el IS NULL THEN
        RETURN 'POR_DETERMINAR';
    END IF;
    -- 2. Entró después de que la garantía terminara.
    IF p_fecha_ingreso > p_vence_el THEN
        RETURN 'FUERA_DE_GARANTIA';
    END IF;

    IF p_checklist IS NOT NULL THEN
        IF p_checklist ? 'senales' THEN
            FOR k IN SELECT jsonb_array_elements_text(v_senales) LOOP
                IF (p_checklist #>> ARRAY['senales', k])::boolean = true THEN
                    senal_observada := true;
                END IF;
            END LOOP;
        END IF;
        IF p_checklist ? 'equipo' THEN
            FOR k IN SELECT jsonb_array_elements_text(v_terms) LOOP
                IF (p_checklist #>> ARRAY['equipo', k])::boolean = false THEN
                    incumple_termino := true;
                END IF;
            END LOOP;
        END IF;
        IF senal_observada OR incumple_termino THEN
            RETURN 'ANULADA_POR_USO';
        END IF;

        IF p_checklist ? 'condiciones' THEN
            FOR k IN SELECT jsonb_array_elements_text(v_condiciones) LOOP
                IF (p_checklist #>> ARRAY['condiciones', k])::boolean = false THEN
                    incumple_condicion := true;
                END IF;
            END LOOP;
        END IF;
        IF incumple_condicion THEN
            RETURN 'POR_DETERMINAR';
        END IF;
    END IF;

    RETURN 'EN_GARANTIA';
END $$;

GRANT EXECUTE ON FUNCTION public.calcular_cobertura(date, date, jsonb)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------
--  4. MOTIVO_ANULACION  —  el texto que la anulación exige (motivo
--     obligatorio): nombra las señales observadas y los términos
--     incumplidos del checklist.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.motivo_anulacion(p_checklist jsonb)
RETURNS text
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_senales     jsonb := '["golpes","descarga_electrica","liquidos","altas_temperaturas","manipulacion_terceros"]'::jsonb;
    v_terms       jsonb := '["precintos_intactos","serial_legible","caja_original","contenido_completo"]'::jsonb;
    k             text;
    observaciones text[] := ARRAY[]::text[];
BEGIN
    IF p_checklist IS NULL THEN
        RETURN NULL;
    END IF;
    IF p_checklist ? 'senales' THEN
        FOR k IN SELECT jsonb_array_elements_text(v_senales) LOOP
            IF coalesce((p_checklist #>> ARRAY['senales', k])::boolean, false) THEN
                observaciones := observaciones || (k || ' (señal de causa externa)');
            END IF;
        END LOOP;
    END IF;
    IF p_checklist ? 'equipo' THEN
        FOR k IN SELECT jsonb_array_elements_text(v_terms) LOOP
            IF coalesce((p_checklist #>> ARRAY['equipo', k])::boolean, false) = false THEN
                observaciones := observaciones || (k || ' (término incumplido)');
            END IF;
        END LOOP;
    END IF;
    IF array_length(observaciones, 1) IS NULL THEN
        RETURN NULL;
    END IF;
    RETURN array_to_string(observaciones, '; ');
END $$;

GRANT EXECUTE ON FUNCTION public.motivo_anulacion(jsonb) TO authenticated, service_role;

-- ---------------------------------------------------------------------
--  5. CHECKLIST_ES_VALIDO  —  claves exactas y valores booleanos
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.checklist_es_valido(p_checklist jsonb)
RETURNS boolean
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_condiciones jsonb := '["factura_presentada","titular_coincide"]'::jsonb;
    v_equipo      jsonb := '["serial_legible","caja_original","precintos_intactos","contenido_completo"]'::jsonb;
    v_senales     jsonb := '["descarga_electrica","liquidos","altas_temperaturas","golpes","manipulacion_terceros"]'::jsonb;
    grupo text;
    k     text;
BEGIN
    IF p_checklist IS NULL THEN
        RETURN true;
    END IF;
    FOR grupo IN SELECT unnest(ARRAY['condiciones','equipo','senales']) LOOP
        IF NOT (p_checklist ? grupo) THEN
            RETURN false;  -- falta el grupo entero
        END IF;
        FOR k IN SELECT jsonb_array_elements_text(CASE grupo
                    WHEN 'condiciones' THEN v_condiciones
                    WHEN 'equipo'      THEN v_equipo
                    ELSE v_senales END) LOOP
            -- falta la clave, o está pero no es booleana
            IF (p_checklist -> grupo -> k IS NULL) OR (jsonb_typeof(p_checklist -> grupo -> k) <> 'boolean') THEN
                RETURN false;
            END IF;
        END LOOP;
    END LOOP;
    RETURN true;
END $$;

GRANT EXECUTE ON FUNCTION public.checklist_es_valido(jsonb) TO authenticated, service_role;

-- =================== 20261030000005_equipos.sql ===================
-- =====================================================================
--  20261030000005_equipos.sql
--  Tabla `equipos`: la unidad física identificada por serial (spec §5.1).
--  La unicidad es POR PRODUCTO: dos fabricantes pueden emitir el mismo
--  serial corto. Para no perder la protección contra errores de
--  transcripción, buscar_equipo(serial) busca en todos los productos.
-- =====================================================================

-- Mayúsculas, sin espacios ni guiones. Los ceros a la izquierda se
-- conservan ('00123' ≠ '123'). IMMUTABLE para poder usarla en la columna
-- generada y en índices.
CREATE OR REPLACE FUNCTION public.normalizar_serie(p_serie text)
RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT upper(regexp_replace(p_serie, '[ -]', '', 'g'));
$$;

CREATE TABLE public.equipos (
    id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    numero_serie          TEXT NOT NULL
        CHECK (length(btrim(numero_serie)) BETWEEN 3 AND 60),
    serie_normalizada     TEXT GENERATED ALWAYS AS
        (upper(regexp_replace(numero_serie, '[ -]', '', 'g'))) STORED,
    producto_id           UUID NOT NULL REFERENCES public.productos(id) ON DELETE RESTRICT,
    -- El titular de la factura: es lo que el trámite exige coincidir.
    cliente_id            UUID NOT NULL REFERENCES public.clientes(id) ON DELETE RESTRICT,
    -- Soporte de compra: FACTURA o NOTA_ENTREGA; vacío si no hay soporte.
    tipo_soporte          TEXT
        CHECK (tipo_soporte IS NULL OR tipo_soporte IN ('FACTURA', 'NOTA_ENTREGA')),
    numero_soporte        TEXT,
    fecha_emision         DATE
        CHECK (fecha_emision IS NULL
               OR (fecha_emision >= DATE '2000-01-01' AND fecha_emision <= public.hoy_local())),
    -- El plazo que indica la factura (7 o 15 días en práctica; el sistema
    -- admite de 1 a 365). NOTA: un CHECK no garantiza exactitud de fecha
    -- bajo desfase horario extremo; hoy_local() es STABLE a propósito.
    plazo_dias            SMALLINT
        CHECK (plazo_dias IS NULL OR plazo_dias BETWEEN 1 AND 365),
    vendedor              TEXT,
    vence_el              DATE GENERATED ALWAYS AS (fecha_emision + plazo_dias) STORED,
    compra_confirmada_por UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
    compra_confirmada_en  TIMESTAMPTZ,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at            TIMESTAMPTZ NOT NULL DEFAULT now(),

    -- El número, la fecha y el plazo van juntos o ninguno.
    CHECK ((numero_soporte IS NULL AND fecha_emision IS NULL AND plazo_dias IS NULL)
           OR (numero_soporte IS NOT NULL AND fecha_emision IS NOT NULL AND plazo_dias IS NOT NULL)),
    CHECK ((tipo_soporte IS NULL) = (numero_soporte IS NULL)),

    CONSTRAINT uq_equipos_producto_serie UNIQUE (producto_id, serie_normalizada)
);

-- Consulta por serial en TODOS los productos (buscar_equipo).
CREATE INDEX idx_equipos_serie_norm ON public.equipos (serie_normalizada);

CREATE TRIGGER trg_equipos_updated_at
    BEFORE UPDATE ON public.equipos
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- Lectura para los roles internos; la escritura pasa SOLO por las
-- funciones (registrar_ingreso / confirmar_compra).
ALTER TABLE public.equipos ENABLE ROW LEVEL SECURITY;
CREATE POLICY equipos_lectura ON public.equipos
    FOR SELECT TO authenticated
    USING (public.mi_rol() IN ('ADMIN', 'JEFE_SERVICIO', 'TECNICO', 'RECEPCION'));

REVOKE ALL ON public.equipos FROM anon;
GRANT SELECT ON public.equipos TO authenticated;

-- =================== 20261030000006_registros.sql ===================
-- =====================================================================
--  20261030000006_registros.sql
--  Reemplazo del módulo `garantias` por `registros` (Hito 1; spec §5.2).
--  MIGRACIÓN HACIA ADELANTE: el módulo viejo no tiene datos reales que
--  conservar, así que se suelta completo y se reconstituye con los
--  nombres nuevos. Se conservan intactos: profiles y sus políticas,
--  estados_garantia, transiciones_estado, marcas, productos, clientes,
--  y el módulo MFA completo (migración ...0003).
--  Cambio de permisos del hito (spec §6): el TECNICO ahora SÍ puede
--  crear registros (antes `crear_garantia` se lo impedía). La creación
--  va por `registrar_ingreso` (Tarea 11), nunca insertando directo.
-- =====================================================================

-- ---------------------------------------------------------------------
--  1. DERRIBADO DEL MÓDULO VIEJO
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS public.consulta_publica_intentos CASCADE;
DROP TABLE IF EXISTS public.notas_internas                        CASCADE;
DROP TABLE IF EXISTS public.historial_garantias                   CASCADE;
DROP TABLE IF EXISTS public.garantias                             CASCADE;
DROP FUNCTION IF EXISTS public.crear_garantia(UUID, UUID, DATE, TEXT, TEXT, TEXT, TEXT);
DROP FUNCTION IF EXISTS public.consultar_garantia(TEXT, TEXT);
DROP FUNCTION IF EXISTS public.calcular_vencimiento_garantia();
-- La lógica de validación de transición (líneas 337–386 de la migración
-- archivada) NO se reescribe: es genérica (estados + transiciones + mi_rol)
-- y no menciona garantías en ningún lado. Se reutiliza tal cual.
DROP FUNCTION IF EXISTS public.registrar_historial_garantia();
DROP FUNCTION IF EXISTS public.historial_es_inmutable();
DROP SEQUENCE IF EXISTS public.garantias_numero_seq;

-- ---------------------------------------------------------------------
--  2. REGISTROS
-- ---------------------------------------------------------------------
-- Correlativo legible REG-AAAA-NNNNNN desde una SEQUENCE nativa. `nextval`
-- en el DEFAULT es atómico: dos técnicos que registren en el mismo segundo
-- toman números distintos sin carreras. Los huecos por transacciones
-- revertidas se aceptan: lo que importa es que el número sea único.
CREATE SEQUENCE public.registros_numero_seq;

CREATE TABLE public.registros (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    numero_registro TEXT NOT NULL UNIQUE
                    DEFAULT ('REG-' || to_char(now(), 'YYYY') || '-'
                             || lpad(nextval('public.registros_numero_seq')::text, 6, '0')),

    -- ===== SECRETO DE CONSULTA (igual que la orden de antes) =====
    -- El token SOLO se guarda hasheado; el texto plano existe una única
    -- vez, en el valor que devuelve registrar_ingreso() (Tarea 11).
    consulta_token_hash BYTEA NOT NULL UNIQUE,

    -- ===== LA UNIDAD FÍSICA =====
    -- Antes la orden llevaba producto/serial/compra denormalizados; ahora
    -- son el equipo, registrado una sola vez y reutilizable.
    equipo_id       UUID NOT NULL REFERENCES public.equipos(id) ON DELETE RESTRICT,

    accesorios      TEXT,                 -- "cargador, caja, cable"
    falla_reportada TEXT NOT NULL CHECK (length(btrim(falla_reportada)) BETWEEN 5 AND 2000),
    diagnostico     TEXT,                 -- lo que encontró el técnico (visible al cliente)

    -- ===== COBERTURA: la calcula la base a partir de las revisiones =====
    cobertura             public.cobertura_garantia NOT NULL DEFAULT 'POR_DETERMINAR',
    motivo_anulacion_cobertura TEXT,     -- obligatorio si cobertura = ANULADA_POR_USO
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

    -- ===== Coherencia temporal y de negocio (portadas de garantias) =====
    CONSTRAINT ck_entrega_posterior_al_ingreso
        CHECK (fecha_entrega IS NULL OR fecha_entrega >= fecha_ingreso),
    CONSTRAINT ck_entregado_tiene_fecha
        CHECK ((estado = 'ENTREGADO') = (fecha_entrega IS NOT NULL)),
    CONSTRAINT ck_anulacion_cobertura_justificada
        CHECK ((cobertura = 'ANULADA_POR_USO') = (motivo_anulacion_cobertura IS NOT NULL)),
    CONSTRAINT ck_costo_solo_si_no_cubierta
        CHECK (costo_reparacion IS NULL OR cobertura <> 'EN_GARANTIA')
);

COMMENT ON TABLE public.registros IS
'Nunca se borran filas. Un registro creado por error pasa a estado ANULADO.';

-- ---------------------------------------------------------------------
--  3. HISTORIAL DEL REGISTRO  — automático e inmutable (portado)
-- ---------------------------------------------------------------------
CREATE TABLE public.historial_registros (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    registro_id     UUID NOT NULL REFERENCES public.registros(id) ON DELETE CASCADE,
    estado_anterior TEXT REFERENCES public.estados_garantia(codigo) ON DELETE RESTRICT,  -- NULL = alta
    estado_nuevo    TEXT NOT NULL REFERENCES public.estados_garantia(codigo) ON DELETE RESTRICT,
    modificado_por  UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
    comentario      TEXT,
    creado_en       TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (estado_anterior IS DISTINCT FROM estado_nuevo)
);

CREATE TABLE public.notas_internas (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    registro_id UUID NOT NULL REFERENCES public.registros(id) ON DELETE CASCADE,
    autor_id    UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
    nota        TEXT NOT NULL CHECK (length(btrim(nota)) BETWEEN 1 AND 4000),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------
--  4. TRIGGERS  (portados de §7 de la migración archivada)
-- ---------------------------------------------------------------------
-- Escritura del historial (AFTER INSERT OR UPDATE OF estado).
CREATE OR REPLACE FUNCTION public.registrar_historial_registro()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO public.historial_registros
            (registro_id, estado_anterior, estado_nuevo, modificado_por, comentario)
        VALUES (NEW.id, NULL, NEW.estado, auth.uid(), 'Registro creado');
        RETURN NEW;
    END IF;

    IF NEW.estado IS DISTINCT FROM OLD.estado THEN
        INSERT INTO public.historial_registros
            (registro_id, estado_anterior, estado_nuevo, modificado_por, comentario)
        VALUES (NEW.id, OLD.estado, NEW.estado, auth.uid(),
                nullif(btrim(coalesce(NEW.diagnostico, '')), ''));
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_registros_historial
    AFTER INSERT OR UPDATE OF estado ON public.registros
    FOR EACH ROW EXECUTE FUNCTION public.registrar_historial_registro();

-- Inmutabilidad del historial: ni service_role ni el dueño lo editan.
CREATE OR REPLACE FUNCTION public.historial_registros_es_inmutable()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
    RAISE EXCEPTION 'historial_registros es de solo anexado: % no está permitido', TG_OP
        USING ERRCODE = '42501';
END;
$$;

CREATE TRIGGER trg_historial_registros_inmutable
    BEFORE UPDATE OR DELETE ON public.historial_registros
    FOR EACH ROW EXECUTE FUNCTION public.historial_registros_es_inmutable();

CREATE TRIGGER trg_registros_updated_at
    BEFORE UPDATE ON public.registros
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE TRIGGER trg_validar_transicion_registro
    BEFORE UPDATE OF estado ON public.registros
    FOR EACH ROW EXECUTE FUNCTION public.validar_transicion_estado();

-- ---------------------------------------------------------------------
--  5. ÍNDICES  (portados; Postgres no indexa las FK automáticamente)
-- ---------------------------------------------------------------------
CREATE INDEX idx_reg_equipo     ON public.registros (equipo_id);
CREATE INDEX idx_reg_creado_por ON public.registros (creado_por);
CREATE INDEX idx_reg_ingreso    ON public.registros (fecha_ingreso DESC);

CREATE INDEX idx_reg_abiertas_por_tecnico
    ON public.registros (tecnico_asignado_id, fecha_ingreso DESC)
    WHERE estado NOT IN ('ENTREGADO', 'ANULADO');

CREATE INDEX idx_reg_abiertas_por_estado
    ON public.registros (estado, fecha_ingreso DESC)
    WHERE estado NOT IN ('ENTREGADO', 'ANULADO');

CREATE INDEX idx_reg_sin_asignar
    ON public.registros (fecha_ingreso)
    WHERE tecnico_asignado_id IS NULL AND estado NOT IN ('ENTREGADO', 'ANULADO');

CREATE INDEX idx_hist_registros_id ON public.historial_registros (registro_id, creado_en DESC);
CREATE INDEX idx_hist_registros_autor ON public.historial_registros (modificado_por, creado_en DESC);
CREATE INDEX idx_notas_registro ON public.notas_internas (registro_id, created_at DESC);
CREATE INDEX idx_notas_autor ON public.notas_internas (autor_id);

-- ---------------------------------------------------------------------
--  6. PERMISOS  (portados de §10–11, con los nombres nuevos)
-- ---------------------------------------------------------------------
ALTER TABLE public.registros         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.historial_registros ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notas_internas    ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.registros         FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.historial_registros FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.notas_internas    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON SEQUENCE public.registros_numero_seq FROM PUBLIC, anon, authenticated;

GRANT SELECT ON public.registros TO authenticated;
-- UPDATE solo por columna: la cobertura y su motivo la escriben los
-- triggers de revisiones; el técnico asignado lo fija registrar_ingreso;
-- la fecha de entrega la llena el trigger de ENTREGADO; creado_por es
-- trazabilidad. El resto (estado, diagnostico, accesorios,
-- costo_reparacion, recibido_por) sí lo toca un TECNICO asignado.
GRANT UPDATE (estado, diagnostico, accesorios, costo_reparacion, recibido_por)
  ON public.registros TO authenticated;
GRANT SELECT ON public.historial_registros TO authenticated;
GRANT SELECT, INSERT ON public.notas_internas TO authenticated;
-- Sin DELETE en ninguna tabla, para ningún rol de aplicación.

-- Los cuatro roles internos leen todo el tablero (taller de 4 personas);
-- un autenticado sin perfil (mi_rol() NULL) no ve nada, igual que en
-- equipos/revisiones/ajustes/adjuntos.
CREATE POLICY reg_select ON public.registros
    FOR SELECT TO authenticated
    USING (public.mi_rol() IN ('ADMIN', 'JEFE_SERVICIO', 'TECNICO', 'RECEPCION'));

-- Un TECNICO solo modifica lo que tiene asignado, y no puede reasignarlo
-- ni a sí mismo ni a otro; y solo lo abierto.
CREATE POLICY reg_update_tecnico ON public.registros
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

CREATE POLICY reg_update_supervision ON public.registros
    FOR UPDATE TO authenticated
    USING (public.tiene_rol('ADMIN', 'JEFE_SERVICIO'))
    WITH CHECK (public.tiene_rol('ADMIN', 'JEFE_SERVICIO'));

-- RECEPCION solo cierra la entrega; el trigger limita la transición.
CREATE POLICY reg_update_recepcion ON public.registros
    FOR UPDATE TO authenticated
    USING (public.tiene_rol('RECEPCION') AND estado IN ('REPARADO', 'IRREPARABLE', 'RECHAZADO_POR_CLIENTE'))
    WITH CHECK (public.tiene_rol('RECEPCION'));

-- Sin policy de INSERT: la creación va por registrar_ingreso (Tarea 11).
-- Sin policy de DELETE: se anula, no se borra.

CREATE POLICY hist_registros_select ON public.historial_registros
    FOR SELECT TO authenticated
    USING (public.mi_rol() IN ('ADMIN', 'JEFE_SERVICIO', 'TECNICO', 'RECEPCION'));

CREATE POLICY notasRegistro_select ON public.notas_internas
    FOR SELECT TO authenticated
    USING (public.mi_rol() IN ('ADMIN', 'JEFE_SERVICIO', 'TECNICO', 'RECEPCION'));
CREATE POLICY notasRegistro_insert ON public.notas_internas
    FOR INSERT TO authenticated WITH CHECK (autor_id = auth.uid());
-- ---------------------------------------------------------------------
--  7. CONSULTA PÚBLICA DEL REGISTRO  (portada de §9 de garantias)
-- ---------------------------------------------------------------------
-- Sin interfaz en este hito: la pantalla llega después, la base ya queda.
CREATE TABLE public.consulta_publica_intentos (
    id             BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ip             INET,
    numero_registro TEXT,
    exito          BOOLEAN NOT NULL,
    intentado_en   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_cpi_reg_ip_tiempo ON public.consulta_publica_intentos (ip, intentado_en DESC)
    WHERE NOT exito;
ALTER TABLE public.consulta_publica_intentos ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.consulta_publica_intentos FROM PUBLIC, anon, authenticated;
-- RLS con CERO policies: solo la función SECURITY DEFINER la escribe y lee.

CREATE OR REPLACE FUNCTION public.consultar_registro(
    p_numero_registro TEXT,
    p_token           TEXT
)
RETURNS TABLE (
    numero_registro TEXT,
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
    v_rid      UUID;
BEGIN
    -- IP real del cliente (PostgREST expone las cabeceras del request).
    BEGIN
        v_ip := nullif(btrim(split_part(
                    coalesce(current_setting('request.headers', TRUE)::json ->> 'x-forwarded-for', ''),
                    ',', 1)), '')::inet;
    EXCEPTION WHEN OTHERS THEN
        v_ip := NULL;
    END;

    -- Freno de fuerza bruta (portado sin cambios).
    SELECT count(*) INTO v_fallos
      FROM public.consulta_publica_intentos c
     WHERE c.ip = v_ip
       AND NOT c.exito
       AND c.intentado_en > now() - interval '15 minutes';

    IF v_ip IS NOT NULL AND v_fallos >= 10 THEN
        INSERT INTO public.consulta_publica_intentos (ip, numero_registro, exito)
        VALUES (v_ip, p_numero_registro, FALSE);
        RAISE EXCEPTION 'Demasiadas consultas fallidas. Intente de nuevo en 15 minutos.'
            USING ERRCODE = '53400';
    END IF;

    -- Búsqueda POR EL HASH: cero filas responde igual a "no existe" que a
    -- "token incorrecto" (anti-enumeración) y el intento queda en bitácora.
    SELECT r.id INTO v_rid
      FROM public.registros r
     WHERE r.consulta_token_hash = extensions.digest(coalesce(p_token, ''), 'sha256')
       AND r.numero_registro = upper(btrim(coalesce(p_numero_registro, '')));

    INSERT INTO public.consulta_publica_intentos (ip, numero_registro, exito)
    VALUES (v_ip, p_numero_registro, v_rid IS NOT NULL);

    IF v_rid IS NULL THEN
        RETURN;
    END IF;

    RETURN QUERY
    SELECT r.numero_registro,
           r.estado,
           e.nombre,
           (m.nombre || ' ' || pr.modelo)::TEXT,
           r.falla_reportada,
           r.diagnostico,
           r.cobertura,
           r.fecha_ingreso,
           r.fecha_entrega,
           r.updated_at
      FROM public.registros r
      JOIN public.estados_garantia e ON e.codigo = r.estado
      JOIN public.equipos eq         ON eq.id = r.equipo_id
      JOIN public.productos pr       ON pr.id = eq.producto_id
      JOIN public.marcas m           ON m.id = pr.marca_id
     WHERE r.id = v_rid;
END;
$$;

REVOKE ALL ON FUNCTION public.consultar_registro(TEXT, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.consultar_registro(TEXT, TEXT) TO anon, authenticated;


-- =================== 20261030000007_revisiones.sql ===================
-- =====================================================================
--  20261030000007_revisiones.sql
--  Tabla `revisiones` (spec §5.3): la evaluación del producto, con su
--  lista de verificación y el resultado CALCULADO por la base.
--  SOLO DE ANEXAR: una corrección es una revisión nueva. Los triggers
--  bloquean UPDATE, DELETE y TRUNCATE, incluso para service_role y el
--  propietario de la base: es la garantía de auditabilidad.
-- =====================================================================

CREATE TABLE public.revisiones (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    registro_id   UUID NOT NULL REFERENCES public.registros(id) ON DELETE RESTRICT,
    -- RECEPCION (la de entrada del asistente) o TECNICA (las posteriores)
    tipo          TEXT NOT NULL CHECK (tipo IN ('RECEPCION', 'TECNICA')),
    revisado_por  UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
    revisado_en   TIMESTAMPTZ NOT NULL DEFAULT now(),
    -- La lista de verificación del spec §4.3, con estructura validada.
    -- Nullable: la revisión de recepción se crea con registrar_ingreso y
    -- el paso "Verificación" del asistente es opcional.
    checklist     JSONB
        CHECK (checklist IS NULL OR public.checklist_es_valido(checklist)),
    -- Calculado por trigger (abajo). Lo que envíe el cliente se ignora.
    resultado     public.cobertura_garantia NOT NULL DEFAULT 'POR_DETERMINAR',
    observaciones TEXT
);

CREATE INDEX idx_rev_registro ON public.revisiones (registro_id, revisado_en DESC);
CREATE INDEX idx_rev_revisor  ON public.revisiones (revisado_por, revisado_en DESC);

-- ============ 1. RESULTADO: lo calcula la base (BEFORE INSERT) ============
-- Precedencia del spec §4.2 aplicada a los DATOS del equipo: el vencimiento
-- sale de la fecha de emisión guardada en el equipo, el día de ingreso de
-- registro.fecha_ingreso evaluado en Caracas (hoy_local).
CREATE OR REPLACE FUNCTION public.fijar_resultado_revision()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
    v_registro RECORD;
BEGIN
    SELECT e.vence_el, public.hoy_local(r.fecha_ingreso) AS ingreso
      INTO v_registro
      FROM public.registros r
      JOIN public.equipos e ON e.id = r.equipo_id
     WHERE r.id = NEW.registro_id;

    IF v_registro IS NULL THEN
        RAISE EXCEPTION 'La revisión apunta a un registro inexistente'
            USING ERRCODE = '23503';
    END IF;

    -- Lo que el cliente haya puesto en NEW.resultado queda descartado.
    NEW.resultado := public.calcular_cobertura(v_registro.vence_el, v_registro.ingreso, NEW.checklist);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_revisiones_resultado
    BEFORE INSERT ON public.revisiones
    FOR EACH ROW EXECUTE FUNCTION public.fijar_resultado_revision();

-- ============ 2. COBERTURA DEL REGISTRO (AFTER INSERT) ============
-- La cobertura del registro pasa al resultado de SU ÚLTIMA revisión; una
-- revisión posterior puede cambiarla (por ejemplo, de POR_DETERMINAR a
-- EN_GARANTIA al confirmar la compra, o a ANULADA_POR_USO al ver golpes).
CREATE OR REPLACE FUNCTION public.actualizar_cobertura_registro()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
    UPDATE public.registros
       SET cobertura = NEW.resultado,
           motivo_anulacion_cobertura =
               CASE WHEN NEW.resultado = 'ANULADA_POR_USO'
                    THEN public.motivo_anulacion(NEW.checklist)
               END
     WHERE id = NEW.registro_id;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_revisiones_cobertura
    AFTER INSERT ON public.revisiones
    FOR EACH ROW EXECUTE FUNCTION public.actualizar_cobertura_registro();

-- ============ 3. INMUTABILIDAD: solo de anexar ============
CREATE OR REPLACE FUNCTION public.revisiones_solo_anexar()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
    -- Se aplica por fila (UPDATE/DELETE) y por sentencia (TRUNCATE).
    RAISE EXCEPTION 'revisiones es solo de anexar: % no está permitido', TG_OP
        USING ERRCODE = '42501';
END;
$$;

CREATE TRIGGER trg_revisiones_inmutables
    BEFORE UPDATE OR DELETE ON public.revisiones
    FOR EACH ROW EXECUTE FUNCTION public.revisiones_solo_anexar();

CREATE TRIGGER trg_revisiones_inmutables_truncate
    BEFORE TRUNCATE ON public.revisiones
    FOR EACH STATEMENT EXECUTE FUNCTION public.revisiones_solo_anexar();

-- ---------------------------------------------------------------------
--  4. PERMISOS (spec §6 y §5.3)
-- ---------------------------------------------------------------------
ALTER TABLE public.revisiones ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.revisiones FROM PUBLIC, anon, authenticated, service_role;
-- El UPDATE/DELETE el trigger lo rechaza con mensaje claro; los GRANT
-- garantizan que el rechazo llegue al trigger y no a "permission denied".
GRANT SELECT, UPDATE, DELETE ON public.revisiones TO authenticated, service_role;

-- Lectura: los roles internos; escritura: solo por registrar_revision().
CREATE POLICY rev_select ON public.revisiones
    FOR SELECT TO authenticated
    USING (public.mi_rol() IN ('ADMIN', 'JEFE_SERVICIO', 'TECNICO', 'RECEPCION'));

CREATE POLICY rev_update_bloqueada ON public.revisiones
    FOR UPDATE TO authenticated
    USING (public.mi_rol() IN ('ADMIN', 'JEFE_SERVICIO', 'TECNICO', 'RECEPCION'));

-- =================== 20261030000008_adjuntos.sql ===================
-- =====================================================================
--  20261030000008_adjuntos.sql
--  Tabla `adjuntos` (spec §5.4) y bucket privado `registros`.
--  Fotos JPG/PNG/WEBP ≤ 8 MB, hasta 8 por registro; documentos
--  PDF/JPG/PNG ≤ 8 MB, hasta 6. SOLO DE ANEXAR, como las revisiones.
--  Los archivos viven en el bucket PRIVADO de Supabase Storage; aquí
--  solo se registra la fila con su ruta, MIME y tamaño.
-- =====================================================================

CREATE TABLE public.adjuntos (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    registro_id UUID NOT NULL REFERENCES public.registros(id) ON DELETE RESTRICT,
    revision_id UUID REFERENCES public.revisiones(id) ON DELETE RESTRICT,
    -- FOTO o DOCUMENTO; las reglas de mime/cantidad se aplican por trigger.
    tipo        TEXT NOT NULL CHECK (tipo IN ('FOTO', 'DOCUMENTO')),
    etiqueta    TEXT,
    -- Ruta dentro del bucket: registros/{registro_id}/…; la política de
    -- storage la refuerza también.
    ruta        TEXT NOT NULL UNIQUE CHECK (ruta ~ '^registros/.+/.+'),
    mime        TEXT NOT NULL,
    bytes       BIGINT NOT NULL CHECK (bytes > 0),
    -- La app no lo manda: el usuario de la sesión lo llena el DEFAULT
    -- (la política adj_insert exige que sea exactamente quien sube).
    subido_por  UUID REFERENCES public.profiles(id) ON DELETE RESTRICT
                DEFAULT auth.uid(),
    subido_en   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_adjuntos_registro ON public.adjuntos (registro_id, subido_en DESC);
CREATE INDEX idx_adjuntos_revision ON public.adjuntos (revision_id);

-- ---------------------------------------------------------------------
--  1. VALIDACIÓN DEL ARCHIVO (BEFORE INSERT)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.validar_adjunto()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
    v_fotos   INTEGER;
    v_docs    INTEGER;
    v_tope    CONSTANT INTEGER := 8 * 1024 * 1024;   -- 8 MB
BEGIN
    -- Tipo de archivo según uso.
    IF NEW.tipo = 'FOTO' THEN
        IF NEW.mime NOT IN ('image/jpeg', 'image/png', 'image/webp') THEN
            RAISE EXCEPTION
                'Formato no admitido para FOTO: usa JPG, PNG o WEBP (recibido: %)', NEW.mime
                USING ERRCODE = '22P02';
        END IF;
    ELSE  -- DOCUMENTO
        IF NEW.mime NOT IN ('application/pdf', 'image/jpeg', 'image/png') THEN
            RAISE EXCEPTION
                'Formato no admitido para DOCUMENTO: usa PDF, JPG o PNG (recibido: %)', NEW.mime
                USING ERRCODE = '22P02';
        END IF;
    END IF;

    -- Tamaño.
    IF NEW.bytes > v_tope THEN
        RAISE EXCEPTION
            'El archivo no puede pesar más de 8 MB (recibido: %), y el límite es común a fotos y documentos',
            round(NEW.bytes / (1024.0 * 1024), 1)
            USING ERRCODE = '22P02';
    END IF;

    -- Cantidad por registro: 8 fotos, 6 documentos.
    SELECT count(*) FILTER (WHERE tipo = 'FOTO') INTO v_fotos
      FROM public.adjuntos WHERE registro_id = NEW.registro_id;
    IF NEW.tipo = 'FOTO' AND v_fotos >= 8 THEN
        RAISE EXCEPTION 'El registro ya tiene 8 fotos: no se admiten más'
            USING ERRCODE = '22P02';
    END IF;
    SELECT count(*) FILTER (WHERE tipo = 'DOCUMENTO') INTO v_docs
      FROM public.adjuntos WHERE registro_id = NEW.registro_id;
    IF NEW.tipo = 'DOCUMENTO' AND v_docs >= 6 THEN
        RAISE EXCEPTION 'El registro ya tiene 6 documentos: no se admiten más'
            USING ERRCODE = '22P02';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_adjuntos_validar
    BEFORE INSERT ON public.adjuntos
    FOR EACH ROW EXECUTE FUNCTION public.validar_adjunto();

-- ---------------------------------------------------------------------
--  2. SOLO DE ANEXAR (igual que revisiones)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.adjuntos_solo_anexar()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
    -- Se aplica por fila (UPDATE/DELETE) y por sentencia (TRUNCATE).
    RAISE EXCEPTION 'adjuntos es solo de anexar: % no está permitido', TG_OP
        USING ERRCODE = '42501';
END;
$$;

CREATE TRIGGER trg_adjuntos_inmutables
    BEFORE UPDATE OR DELETE ON public.adjuntos
    FOR EACH ROW EXECUTE FUNCTION public.adjuntos_solo_anexar();

CREATE TRIGGER trg_adjuntos_inmutables_truncate
    BEFORE TRUNCATE ON public.adjuntos
    FOR EACH STATEMENT EXECUTE FUNCTION public.adjuntos_solo_anexar();

-- ---------------------------------------------------------------------
--  3. PERMISOS: subir adjuntos es registrar trazabilidad, lo hacen los
--     roles internos; anon nada. Nadie edita ni borra (trigger arriba).
-- ---------------------------------------------------------------------
ALTER TABLE public.adjuntos ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.adjuntos FROM PUBLIC, anon, authenticated, service_role;
-- El UPDATE/DELETE los bloquea el trigger con mensaje claro; los GRANT
-- garantizan que el rechazo llegue al trigger y no a "permission denied".
GRANT SELECT, INSERT, UPDATE, DELETE ON public.adjuntos TO authenticated, service_role;

CREATE POLICY adj_select ON public.adjuntos
    FOR SELECT TO authenticated
    USING (public.mi_rol() IN ('ADMIN', 'JEFE_SERVICIO', 'TECNICO', 'RECEPCION'));

CREATE POLICY adj_insert ON public.adjuntos
    FOR INSERT TO authenticated
    WITH CHECK (subido_por = auth.uid());

-- ---------------------------------------------------------------------
--  4. BUCKET PRIVADO Y POLÍTICAS POR RUTA
-- ---------------------------------------------------------------------
-- Ruta obligatoria: registros/{registro_id}/… (así sube la app; spec §5.4).
-- El SEGUNDO segmento debe ser el id de un registro existente: el primero
-- es literal "registros" y nadie escribe fuera de ese patrón (en este hito,
-- fuera de "un registro existente", sin cuotas por usuario).
-- El guardia de formato primero: sin él, un segmento no-uuid (p. ej.
-- "otra-cosa" en el segundo) fallaría con "invalid input syntax" en vez
-- de RLS.
INSERT INTO storage.buckets (id, name, public)
VALUES ('registros', 'registros', false)
ON CONFLICT (id) DO UPDATE SET public = false;

CREATE POLICY storage_subir_adjunto ON storage.objects
    FOR INSERT TO authenticated
    WITH CHECK (
        bucket_id = 'registros'
        AND public.mi_rol() IS NOT NULL
        AND split_part(name, '/', 1) = 'registros'
        AND split_part(name, '/', 2) ~ '^[0-9a-f-]{36}$'
        AND split_part(name, '/', 2)::uuid IN (SELECT r.id FROM public.registros r)
    );

CREATE POLICY storage_ver_adjunto ON storage.objects
    FOR SELECT TO authenticated
    USING (
        bucket_id = 'registros'
        AND public.mi_rol() IS NOT NULL
        AND split_part(name, '/', 1) = 'registros'
        AND split_part(name, '/', 2) ~ '^[0-9a-f-]{36}$'
        AND split_part(name, '/', 2)::uuid IN (SELECT r.id FROM public.registros r)
    );

-- anon no queda con ningún acceso al bucket: no se escriben políticas
-- para anon y el GRANT del esquema storage ya lo excluye de las tablas.

-- =================== 20261030000009_rpc_registro.sql ===================
-- =====================================================================
--  20261030000009_rpc_registro.sql
--  Funciones de registro de ingreso (spec §5.5 y §6). Todas SECURITY
--  DEFINER, search_path fijado, EXECUTE solo para authenticated.
--  El TECNICO AHORA SÍ puede registrar (cambio del hito, spec §6).
-- =====================================================================

-- ---------------------------------------------------------------------
--  1. GUARDAR_CLIENTE — crea o devuelve el cliente de (tipo, documento)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.guardar_cliente(
    p_tipo      public.tipo_documento,
    p_documento text,
    p_nombre    text,
    p_telefono  text DEFAULT NULL,
    p_email     text DEFAULT NULL,
    p_direccion text DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_cliente_id uuid;
BEGIN
    -- El CHECK de la tabla (5–15 dígitos) rechaza lo malo; aquí solo
    -- normalizamos y resolvemos la existencia del titular.
    INSERT INTO public.clientes (tipo_documento, documento, nombre, telefono, email, direccion)
    VALUES (p_tipo,
            btrim(coalesce(p_documento, '')),
            btrim(coalesce(p_nombre, '')),
            nullif(btrim(coalesce(p_telefono, '')), ''),
            nullif(btrim(coalesce(p_email, '')), ''),
            nullif(btrim(coalesce(p_direccion, '')), ''))
    ON CONFLICT (tipo_documento, documento) DO NOTHING;

    SELECT id INTO v_cliente_id
      FROM public.clientes
     WHERE documento = btrim(coalesce(p_documento, ''))
       AND tipo_documento = p_tipo;
    RETURN v_cliente_id;
END;
$$;

REVOKE ALL ON FUNCTION public.guardar_cliente(public.tipo_documento, text, text, text, text, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.guardar_cliente(public.tipo_documento, text, text, text, text, text)
  TO authenticated;

-- ---------------------------------------------------------------------
--  2. BUSCAR_EQUIPO — por serial en TODOS los productos (spec §5.1)
--     Devuelve también el historial de registros del equipo, para el
--     asistente (paso 1) y la advertencia de serial en otro producto.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.buscar_equipo(p_serial text)
RETURNS TABLE (
    equipo_id      uuid,
    producto_id    uuid,
    producto       text,
    numero_serie   text,
    titular_id     uuid,
    titular        text,
    vence_el       date,
    dias_restantes integer,
    registros      jsonb
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    RETURN QUERY
    SELECT e.id, e.producto_id,
           (m.nombre || ' ' || pr.modelo)::text,
           e.numero_serie,
           e.cliente_id, c.nombre,
           e.vence_el,
           (e.vence_el - public.hoy_local())::int,
           COALESCE((
               SELECT jsonb_agg(
                          jsonb_build_object(
                              'numero',  r.numero_registro,
                              'estado',  r.estado,
                              'ingreso', r.fecha_ingreso::text,
                              'cobertura', r.cobertura::text)
                          ORDER BY r.fecha_ingreso)
                 FROM public.registros r
                WHERE r.equipo_id = e.id), '[]'::jsonb)
      FROM public.equipos e
      JOIN public.productos pr ON pr.id = e.producto_id
      JOIN public.marcas m     ON m.id  = pr.marca_id
      JOIN public.clientes c   ON c.id  = e.cliente_id
     WHERE (p_serial IS NOT NULL AND btrim(p_serial) <> ''
            AND e.serie_normalizada = public.normalizar_serie(btrim(p_serial)));
END;
$$;

REVOKE ALL ON FUNCTION public.buscar_equipo(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.buscar_equipo(text) TO authenticated;

-- ---------------------------------------------------------------------
--  3. REGISTRAR_INGRESO — la transacción completa (spec §5.5)
-- ---------------------------------------------------------------------
-- Crea o reutiliza el equipo (ON CONFLICT, sin carreras), crea el registro
-- con su correlativo, inserta la revisión de RECEPCION (que fija la
-- cobertura a través de los triggers de revisiones) y devuelve el token de
-- consulta UNA VEZ. Todo en una transacción: si algo falla, nada queda.
CREATE OR REPLACE FUNCTION public.registrar_ingreso(
    p_serial          text,
    p_producto_id     uuid,
    p_cliente_id      uuid,
    p_falla           text,
    p_accesorios      text DEFAULT NULL,
    p_tipo_soporte    text DEFAULT NULL,
    p_numero_soporte  text DEFAULT NULL,
    p_fecha_emision   date DEFAULT NULL,
    p_plazo_dias      integer DEFAULT NULL,
    p_vendedor        text DEFAULT NULL,
    p_checklist       jsonb DEFAULT NULL,
    p_observaciones   text DEFAULT NULL,
    p_fecha_ingreso   timestamptz DEFAULT NULL)
RETURNS TABLE (
    registro_id     uuid,
    numero_registro text,
    consulta_token  text,   -- TEXTO PLANO, una sola vez (imprimir y olvidar)
    cobertura       public.cobertura_garantia,
    equipo_id       uuid,
    equipo_nuevo    boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_rol    public.app_role := public.mi_rol();
    v_actor  uuid := auth.uid();
    v_serial text := btrim(coalesce(p_serial, ''));
    v_falla  text := btrim(coalesce(p_falla, ''));
    v_equipo uuid;
    v_nuevo  boolean;
    v_token  text;
    v_registro uuid;
BEGIN
    IF v_rol IS NULL OR NOT public.tiene_rol('ADMIN', 'JEFE_SERVICIO', 'TECNICO', 'RECEPCION') THEN
        RAISE EXCEPTION 'Su rol no puede registrar ingresos' USING ERRCODE = '42501';
    END IF;

    IF v_serial < '!' OR length(v_serial) < 3 THEN
        RAISE EXCEPTION 'El serial es obligatorio (3 a 60 caracteres)'
            USING ERRCODE = '22P02';
    END IF;
    IF length(v_falla) < 5 OR length(v_falla) > 2000 THEN
        RAISE EXCEPTION 'La falla reportada es obligatoria (5 a 2000 caracteres)'
            USING ERRCODE = '22P02';
    END IF;

    -- ---- Equipo: buscar y, si no existe, crearlo (sin carrera) ----
    v_equipo := NULL;
    IF p_producto_id IS NOT NULL AND p_cliente_id IS NOT NULL THEN
        SELECT id INTO v_equipo
          FROM public.equipos
         WHERE producto_id = p_producto_id
           AND serie_normalizada = public.normalizar_serie(v_serial);
    END IF;

    v_nuevo := v_equipo IS NULL;
    IF v_nuevo THEN
        IF p_producto_id IS NULL OR p_cliente_id IS NULL THEN
            RAISE EXCEPTION 'Para un equipo nuevo hacen falta producto y titular'
                USING ERRCODE = '22P02';
        END IF;
        INSERT INTO public.equipos (numero_serie, producto_id, cliente_id,
                                    tipo_soporte, numero_soporte, fecha_emision,
                                    plazo_dias, vendedor)
        VALUES (v_serial, p_producto_id, p_cliente_id,
                nullif(btrim(coalesce(p_tipo_soporte, '')), ''),
                nullif(btrim(coalesce(p_numero_soporte, '')), ''),
                p_fecha_emision, p_plazo_dias,
                nullif(btrim(coalesce(p_vendedor, '')), ''))
        ON CONFLICT (producto_id, serie_normalizada) DO NOTHING;

        SELECT id INTO v_equipo
          FROM public.equipos
         WHERE producto_id = p_producto_id
           AND serie_normalizada = public.normalizar_serie(v_serial);
        IF v_equipo IS NULL THEN
            RAISE EXCEPTION 'No fue posible crear el equipo (revise el serial)'
                USING ERRCODE = '23505';
        END IF;
    END IF;

    -- ---- Registro ----
    v_token := encode(extensions.gen_random_bytes(16), 'hex');

    INSERT INTO public.registros (equipo_id, falla_reportada, accesorios,
                                  cobertura, tecnico_asignado_id, creado_por,
                                  consulta_token_hash, fecha_ingreso)
    VALUES (v_equipo, v_falla,
            nullif(btrim(coalesce(p_accesorios, '')), ''),
            'POR_DETERMINAR',
            CASE WHEN v_rol = 'TECNICO' THEN v_actor END,
            v_actor,
            extensions.digest(v_token, 'sha256'),
            -- La fecha de ingreso la manda SOLO el ADMIN (backoffice, corrida
            -- a medianoche): a los demás roles se les ignora en silencio y
            -- reciben el DEFAULT now().
            coalesce(CASE WHEN public.tiene_rol('ADMIN') THEN p_fecha_ingreso END, now()))
    RETURNING id INTO v_registro;

    -- ---- Primera revisión: la de recepción ----
    INSERT INTO public.revisiones (registro_id, tipo, revisado_por, checklist, observaciones)
    VALUES (v_registro, 'RECEPCION', v_actor, p_checklist,
            nullif(btrim(coalesce(p_observaciones, '')), ''));

    -- La cobertura la acaba de escribir el trigger de las revisiones.
    RETURN QUERY
    SELECT r.id, r.numero_registro, v_token, r.cobertura, v_equipo, v_nuevo
      FROM public.registros r
     WHERE r.id = v_registro;
END;
$$;

REVOKE ALL ON FUNCTION public.registrar_ingreso(text, uuid, uuid, text, text, text, text, date, integer, text, jsonb, text, timestamptz)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.registrar_ingreso(text, uuid, uuid, text, text, text, text, date, integer, text, jsonb, text, timestamptz)
  TO authenticated;
-- ---------------------------------------------------------------------
--  4. REGISTRAR_REVISION — añade una revisión a un registro existente
--     (spec §6: ADMIN, JEFE_SERVICIO y TECNICO; RECEPCION no)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.registrar_revision(
    p_registro_id   uuid,
    p_tipo          text,
    p_checklist     jsonb,
    p_observaciones text DEFAULT NULL)
RETURNS TABLE (revision_id uuid, cobertura public.cobertura_garantia)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_rol   public.app_role := public.mi_rol();
    v_id    uuid;
BEGIN
    IF v_rol IS NULL OR NOT public.tiene_rol('ADMIN', 'JEFE_SERVICIO', 'TECNICO') THEN
        RAISE EXCEPTION 'Su rol no puede registrar revisiones' USING ERRCODE = '42501';
    END IF;
    IF p_tipo NOT IN ('RECEPCION', 'TECNICA') THEN
        RAISE EXCEPTION 'El tipo de revisión es RECEPCION o TECNICA' USING ERRCODE = '22P02';
    END IF;
    IF p_checklist IS NOT NULL AND NOT public.checklist_es_valido(p_checklist) THEN
        RAISE EXCEPTION 'La lista de verificación no está completa' USING ERRCODE = '22P02';
    END IF;

    INSERT INTO public.revisiones (registro_id, tipo, revisado_por, checklist, observaciones)
    VALUES (p_registro_id, p_tipo, auth.uid(), p_checklist,
            nullif(btrim(coalesce(p_observaciones, '')), ''))
    RETURNING id INTO v_id;

    RETURN QUERY
    SELECT v_id, r.cobertura
      FROM public.registros r
     WHERE r.id = p_registro_id;
END;
$$;

REVOKE ALL ON FUNCTION public.registrar_revision(uuid, text, jsonb, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.registrar_revision(uuid, text, jsonb, text) TO authenticated;

-- ---------------------------------------------------------------------
--  5. CONFIRMAR_COMPRA — solo ADMIN y JEFE_SERVICIO (spec §4.4 y §6)
-- ---------------------------------------------------------------------
-- Completa los datos de factura que confirmó Ventas, deja registrado quién
-- y cuándo (el gancho para la consulta de ventas del hito siguiente) y
-- recalcula la cobertura de los registros ABIERTOS del equipo, que salen
-- de POR_DETERMINAR gracias al checklist de su última revisión.
CREATE OR REPLACE FUNCTION public.confirmar_compra(
    p_equipo_id      uuid,
    p_tipo_soporte   text,
    p_numero_soporte text,
    p_fecha_emision  date,
    p_plazo_dias     integer)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_rol   public.app_role := public.mi_rol();
    v_tiene_soporte boolean;
BEGIN
    IF v_rol IS NULL OR NOT public.tiene_rol('ADMIN', 'JEFE_SERVICIO') THEN
        RAISE EXCEPTION 'Solo ADMIN o JEFE_SERVICIO confirman la compra' USING ERRCODE = '42501';
    END IF;

    IF coalesce(p_tipo_soporte, '') NOT IN ('FACTURA', 'NOTA_ENTREGA')
       OR coalesce(p_numero_soporte, '') = ''
       OR p_fecha_emision IS NULL OR p_plazo_dias IS NULL THEN
        RAISE EXCEPTION 'Faltan datos del soporte: tipo, número, fecha de emisión y plazo'
            USING ERRCODE = '22P02';
    END IF;

    SELECT (numero_soporte IS NOT NULL) INTO v_tiene_soporte
      FROM public.equipos WHERE id = p_equipo_id;
    IF v_tiene_soporte IS NULL THEN
        RAISE EXCEPTION 'Equipo inexistente' USING ERRCODE = 'P0002';
    END IF;
    IF v_tiene_soporte THEN
        RAISE EXCEPTION 'El equipo ya tiene soporte de compras registrado'
            USING ERRCODE = '23505';
    END IF;

    UPDATE public.equipos
       SET tipo_soporte   = p_tipo_soporte,
           numero_soporte = btrim(p_numero_soporte),
           fecha_emision  = p_fecha_emision,
           plazo_dias     = p_plazo_dias,
           compra_confirmada_por = auth.uid(),
           compra_confirmada_en  = now()
     WHERE id = p_equipo_id;

    -- Recalcular la cobertura de los registros abiertos con su última revisión.
    UPDATE public.registros r
       SET cobertura = c_resultado.nueva,
           motivo_anulacion_cobertura = c_resultado.motivo
      FROM (
        SELECT r2.id AS registro,
               public.calcular_cobertura(f.vence_el, public.hoy_local(r2.fecha_ingreso), v2.checklist) AS nueva,
               CASE WHEN public.calcular_cobertura(f.vence_el, public.hoy_local(r2.fecha_ingreso), v2.checklist) = 'ANULADA_POR_USO'
                    THEN public.motivo_anulacion(v2.checklist) END AS motivo
          FROM public.registros r2
          JOIN public.equipos f   ON f.id = r2.equipo_id
          CROSS JOIN LATERAL (
            SELECT checklist
              FROM public.revisiones vr
             WHERE vr.registro_id = r2.id
             ORDER BY revisado_en DESC, id DESC LIMIT 1) v2
         WHERE r2.equipo_id = p_equipo_id
           AND r2.estado NOT IN ('ENTREGADO', 'ANULADO')
      ) c_resultado
     WHERE r.id = c_resultado.registro;
END;
$$;

REVOKE ALL ON FUNCTION public.confirmar_compra(uuid, text, text, date, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.confirmar_compra(uuid, text, text, date, integer) TO authenticated;


-- =================== 20261030000010_v_tablero.sql ===================
-- =====================================================================
--  20261030000010_v_tablero.sql
--  Vista del Tablero (spec §5.6): una fila por registro con la urgencia
--  COMBINADA de la vigencia y del SLA (§4.5–4.6). security_invoker: es
--  la RLS de las tablas base la que decide; los roles internos leen todo.
-- =====================================================================

CREATE OR REPLACE VIEW public.v_tablero
WITH (security_invoker = true) AS
SELECT r.id AS registro_id,
       r.numero_registro,
       r.estado,
       e.nombre AS estado_nombre,
       r.cobertura::text AS cobertura,
       eq.numero_serie AS serial,
       (m.nombre || ' ' || pr.modelo) AS producto,
       c.nombre AS cliente,
       c.documento AS documento,
       -- Para la búsqueda del Tablero por número de factura (spec §7.3).
       eq.numero_soporte AS numero_soporte,
       r.fecha_ingreso,
       eq.vence_el,
       CASE WHEN eq.vence_el IS NULL THEN NULL
            ELSE eq.vence_el - public.hoy_local() END AS dias_restantes,
       CASE WHEN eq.vence_el IS NULL                     THEN 'PENDIENTE'
            WHEN eq.vence_el - public.hoy_local() < 0    THEN 'VENCIDA'
            WHEN eq.vence_el - public.hoy_local() = 0    THEN 'HOY'
            WHEN eq.vence_el - public.hoy_local() <= public.ajuste('umbral_critico') THEN 'CRITICA'
            WHEN eq.vence_el - public.hoy_local() <= public.ajuste('umbral_pronto')  THEN 'PRONTO'
            ELSE 'NORMAL' END AS nivel_vigencia,
       (public.hoy_local() - public.hoy_local(r.fecha_ingreso)) AS dias_en_taller,
       CASE WHEN (public.hoy_local() - public.hoy_local(r.fecha_ingreso)) >= public.ajuste('sla_critico') THEN 'CRITICO'
            WHEN (public.hoy_local() - public.hoy_local(r.fecha_ingreso)) >= public.ajuste('sla_alerta')  THEN 'ALERTA'
            ELSE 'NORMAL' END AS nivel_sla,
       -- Cerrados: -1 (al final); abiertos: el PEOR de los dos niveles.
       -- La vigencia SOLO cuenta si la cobertura es EN_GARANTIA o
       -- POR_DETERMINAR (§4.6): un equipo que ya entró fuera de garantía o
       -- anulado tiene su fecha informativa y no sube en el orden.
       CASE WHEN r.estado NOT IN ('ENTREGADO', 'ANULADO')
            THEN GREATEST(
                CASE WHEN r.cobertura NOT IN ('EN_GARANTIA', 'POR_DETERMINAR') THEN 0
                     WHEN eq.vence_el IS NULL THEN 1
                     WHEN eq.vence_el - public.hoy_local() < 0 THEN 4
                     WHEN eq.vence_el - public.hoy_local() = 0 THEN 3
                     WHEN eq.vence_el - public.hoy_local() <= public.ajuste('umbral_critico') THEN 2
                     WHEN eq.vence_el - public.hoy_local() <= public.ajuste('umbral_pronto')  THEN 1
                     ELSE 0 END,
                CASE WHEN (public.hoy_local() - public.hoy_local(r.fecha_ingreso)) >= public.ajuste('sla_critico') THEN 2
                     WHEN (public.hoy_local() - public.hoy_local(r.fecha_ingreso)) >= public.ajuste('sla_alerta')  THEN 1
                     ELSE 0 END)
            ELSE -1 END AS urgencia_rank,
       (r.estado NOT IN ('ENTREGADO', 'ANULADO')) AS abierto
  FROM public.registros r
  JOIN public.estados_garantia e ON e.codigo = r.estado
  JOIN public.equipos eq         ON eq.id = r.equipo_id
  JOIN public.productos pr       ON pr.id = eq.producto_id
  JOIN public.marcas m           ON m.id = pr.marca_id
  JOIN public.clientes c         ON c.id = eq.cliente_id;

REVOKE ALL ON public.v_tablero FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.v_tablero TO authenticated;

-- =================== 20261030000011_limpieza_huerfanos.sql ===================
-- =====================================================================
--  20261030000011_limpieza_huerfanos.sql
--  Limpieza de archivos huérfanos (spec §5.7): el único flujo que BORRA
--  archivos, y solo los del almacenamiento que NO tienen fila en
--  `adjuntos` y ya tienen más de 24 horas (no se tocan subidas en curso).
--  Las filas de `adjuntos` nunca se tocan aquí.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.listar_huerfanos(p_gracia interval DEFAULT interval '24 hours')
RETURNS TABLE (nombre text)
LANGUAGE sql
STABLE
AS $$
  SELECT o.name
    FROM storage.objects o
   WHERE o.bucket_id = 'registros'
     AND o.created_at < now() - p_gracia
     AND NOT EXISTS (SELECT 1 FROM public.adjuntos a WHERE a.ruta = o.name);
$$;

-- Solo la ejecuta el borrador programado (la Edge Function con service_role).
REVOKE ALL ON FUNCTION public.listar_huerfanos(interval)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.listar_huerfanos(interval) TO service_role;

-- ---------------------------------------------------------------------
--  PROGRAMACIÓN DIARIA — solo si pg_cron y pg_net existen (el Postgres
--  de pruebas no los tiene: la prueba pasa sin ellos). El secreto y la
--  URL del proyecto no pueden cocinarse en una migración versionada:
--  se leen de los ajustes de la base (ALTER DATABASE … SET app.*) que
--  el despliegue define una vez.
-- ---------------------------------------------------------------------
DO $bloque$
BEGIN
  IF to_regnamespace('cron') IS NOT NULL AND to_regnamespace('net') IS NOT NULL THEN
    IF coalesce(current_setting('app.limpieza_secret', true), '') <> '' THEN
      PERFORM cron.schedule(
        'limpiar-adjuntos-huerfanos',
        '7 6 * * *',   -- 06:07 UTC = 02:07 en Caracas, después de la medianoche
        format(
          $$SELECT net.http_post(
               url     := %L,
               headers := jsonb_build_object('Content-Type', 'application/json',
                                             'x-cron-secret', current_setting('app.limpieza_secret'))
           )$$,
          'https://' || current_setting('app.proyecto_ref', true) || '.supabase.co/functions/v1/limpiar-huerfanos'
        )
      );
    ELSE
      RAISE NOTICE 'app.limpieza_secret sin definir: el job de limpieza NO se agenda (ver README, post-despliegue).';
    END IF;
  END IF;
END
$bloque$;

-- =================== 20261030000012_idempotencia_ingreso.sql ===================
-- 0012 — Idempotencia de registrar_ingreso (revisión de ingeniería H1/H2).
--
-- Un doble clic, o un reintento tras un timeout, creaba dos registros (cada
-- uno con su token) para el mismo ingreso. Ahora el asistente genera una
-- clave por envío (uuid) y la base devuelve el registro original si el mismo
-- usuario la repite. Sin clave (NULL) el comportamiento no cambia.
-- Es una migración NUEVA: no se edita la 0009 ya existente.

ALTER TABLE public.registros ADD COLUMN clave_envio uuid;

CREATE UNIQUE INDEX uq_registros_clave_envio
    ON public.registros (creado_por, clave_envio)
 WHERE clave_envio IS NOT NULL;

-- La firma cambia (parámetro nuevo al final): se retira la anterior para no
-- dejar dos sobrecargas ambiguas.
DROP FUNCTION public.registrar_ingreso(text, uuid, uuid, text, text, text, text, date, integer, text, jsonb, text, timestamptz);

CREATE FUNCTION public.registrar_ingreso(
    p_serial          text,
    p_producto_id     uuid,
    p_cliente_id      uuid,
    p_falla           text,
    p_accesorios      text DEFAULT NULL,
    p_tipo_soporte    text DEFAULT NULL,
    p_numero_soporte  text DEFAULT NULL,
    p_fecha_emision   date DEFAULT NULL,
    p_plazo_dias      integer DEFAULT NULL,
    p_vendedor        text DEFAULT NULL,
    p_checklist       jsonb DEFAULT NULL,
    p_observaciones   text DEFAULT NULL,
    p_fecha_ingreso   timestamptz DEFAULT NULL,
    p_clave_envio     uuid DEFAULT NULL)
RETURNS TABLE (
    registro_id     uuid,
    numero_registro text,
    consulta_token  text,   -- TEXTO PLANO, una sola vez (imprimir y olvidar)
    cobertura       public.cobertura_garantia,
    equipo_id       uuid,
    equipo_nuevo    boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_rol    public.app_role := public.mi_rol();
    v_actor  uuid := auth.uid();
    v_serial text := btrim(coalesce(p_serial, ''));
    v_falla  text := btrim(coalesce(p_falla, ''));
    v_equipo uuid;
    v_nuevo  boolean;
    v_token  text;
    v_registro uuid;
BEGIN
    IF v_rol IS NULL OR NOT public.tiene_rol('ADMIN', 'JEFE_SERVICIO', 'TECNICO', 'RECEPCION') THEN
        RAISE EXCEPTION 'Su rol no puede registrar ingresos' USING ERRCODE = '42501';
    END IF;

    -- ---- Idempotencia: la misma clave del mismo usuario = el mismo registro ----
    -- El candado serializa dos envíos simultáneos con la misma clave (doble
    -- clic): el segundo espera al primero y encuentra su registro. El token en
    -- claro NO se puede reconstruir (solo se guarda el hash): vuelve en NULL.
    IF p_clave_envio IS NOT NULL THEN
        PERFORM pg_advisory_xact_lock(hashtextextended(v_actor::text || p_clave_envio::text, 0));
        RETURN QUERY
        SELECT r.id, r.numero_registro, NULL::text, r.cobertura, r.equipo_id, false
          FROM public.registros r
         WHERE r.creado_por = v_actor AND r.clave_envio = p_clave_envio;
        IF FOUND THEN
            RETURN;
        END IF;
    END IF;

    IF v_serial < '!' OR length(v_serial) < 3 THEN
        RAISE EXCEPTION 'El serial es obligatorio (3 a 60 caracteres)'
            USING ERRCODE = '22P02';
    END IF;
    IF length(v_falla) < 5 OR length(v_falla) > 2000 THEN
        RAISE EXCEPTION 'La falla reportada es obligatoria (5 a 2000 caracteres)'
            USING ERRCODE = '22P02';
    END IF;

    -- ---- Equipo: buscar y, si no existe, crearlo (sin carrera) ----
    v_equipo := NULL;
    IF p_producto_id IS NOT NULL AND p_cliente_id IS NOT NULL THEN
        SELECT id INTO v_equipo
          FROM public.equipos
         WHERE producto_id = p_producto_id
           AND serie_normalizada = public.normalizar_serie(v_serial);
    END IF;

    v_nuevo := v_equipo IS NULL;
    IF v_nuevo THEN
        IF p_producto_id IS NULL OR p_cliente_id IS NULL THEN
            RAISE EXCEPTION 'Para un equipo nuevo hacen falta producto y titular'
                USING ERRCODE = '22P02';
        END IF;
        INSERT INTO public.equipos (numero_serie, producto_id, cliente_id,
                                    tipo_soporte, numero_soporte, fecha_emision,
                                    plazo_dias, vendedor)
        VALUES (v_serial, p_producto_id, p_cliente_id,
                nullif(btrim(coalesce(p_tipo_soporte, '')), ''),
                nullif(btrim(coalesce(p_numero_soporte, '')), ''),
                p_fecha_emision, p_plazo_dias,
                nullif(btrim(coalesce(p_vendedor, '')), ''))
        ON CONFLICT (producto_id, serie_normalizada) DO NOTHING;

        SELECT id INTO v_equipo
          FROM public.equipos
         WHERE producto_id = p_producto_id
           AND serie_normalizada = public.normalizar_serie(v_serial);
        IF v_equipo IS NULL THEN
            RAISE EXCEPTION 'No fue posible crear el equipo (revise el serial)'
                USING ERRCODE = '23505';
        END IF;
    END IF;

    -- ---- Registro ----
    v_token := encode(extensions.gen_random_bytes(16), 'hex');

    INSERT INTO public.registros (equipo_id, falla_reportada, accesorios,
                                  cobertura, tecnico_asignado_id, creado_por,
                                  consulta_token_hash, fecha_ingreso, clave_envio)
    VALUES (v_equipo, v_falla,
            nullif(btrim(coalesce(p_accesorios, '')), ''),
            'POR_DETERMINAR',
            CASE WHEN v_rol = 'TECNICO' THEN v_actor END,
            v_actor,
            extensions.digest(v_token, 'sha256'),
            -- La fecha de ingreso la manda SOLO el ADMIN (backoffice, corrida
            -- a medianoche): a los demás roles se les ignora en silencio y
            -- reciben el DEFAULT now(). (Cierre de D4/3: esta función de la
            -- 0012 es la que queda viva tras el DROP de la 0009.)
            coalesce(CASE WHEN public.tiene_rol('ADMIN') THEN p_fecha_ingreso END, now()), p_clave_envio)
    RETURNING id INTO v_registro;

    -- ---- Primera revisión: la de recepción ----
    INSERT INTO public.revisiones (registro_id, tipo, revisado_por, checklist, observaciones)
    VALUES (v_registro, 'RECEPCION', v_actor, p_checklist,
            nullif(btrim(coalesce(p_observaciones, '')), ''));

    -- La cobertura la acaba de escribir el trigger de las revisiones.
    RETURN QUERY
    SELECT r.id, r.numero_registro, v_token, r.cobertura, v_equipo, v_nuevo
      FROM public.registros r
     WHERE r.id = v_registro;
END;
$$;

REVOKE ALL ON FUNCTION public.registrar_ingreso(text, uuid, uuid, text, text, text, text, date, integer, text, jsonb, text, timestamptz, uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.registrar_ingreso(text, uuid, uuid, text, text, text, text, date, integer, text, jsonb, text, timestamptz, uuid)
  TO authenticated;


-- =================== 20261030000013_fase2a_renombre.sql ===================
-- =====================================================================
--  20261030000013_fase2a_renombre.sql
--  Renombre mecánico del Hito 1 hacia los nombres de la fase 2a
--  (spec §5.1): `registros` → `ordenes_servicio`, `numero_registro`
--  (REG-AAAA-NNNNNN) → `numero_orden` (OS-AAAA-NNNN, mismo mecanismo
--  de secuencia nativa), `historial_registros` → `historial_ordenes`,
--  `registrar_ingreso` → `abrir_orden`. Sin cambio de comportamiento:
--  los cuerpos son los de las migraciones fuente con SOLO los nombres
--  cambiados. Los datos existentes son de prueba: no se conservan.
-- =====================================================================

-- ---------------------------------------------------------------------
--  1. TABLAS
-- ---------------------------------------------------------------------
ALTER TABLE public.registros        RENAME TO ordenes_servicio;
ALTER TABLE public.historial_registros RENAME TO historial_ordenes;

-- ---------------------------------------------------------------------
--  2. COLUMNAS (las FK e índices siguen la columna renombrada: es la
--     misma posición, la definición textual se actualiza sola)
-- ---------------------------------------------------------------------
ALTER TABLE public.ordenes_servicio      RENAME COLUMN numero_registro TO numero_orden;
ALTER TABLE public.historial_ordenes     RENAME COLUMN registro_id     TO orden_id;
ALTER TABLE public.consulta_publica_intentos RENAME COLUMN numero_registro TO numero_orden;
ALTER TABLE public.revisiones            RENAME COLUMN registro_id     TO orden_id;
ALTER TABLE public.adjuntos              RENAME COLUMN registro_id     TO orden_id;
ALTER TABLE public.notas_internas        RENAME COLUMN registro_id     TO orden_id;

-- ---------------------------------------------------------------------
--  3. SECUENCIA Y CORRELATIVO OS-AAAA-NNNN (4 dígitos, prefix OS-)
--  Correlativo legible desde una SEQUENCE nativa. `nextval` en el
--  DEFAULT es atómico: dos técnicos que registren en el mismo segundo
--  toman números distintos sin carreras. Los huecos por transacciones
--  revertidas se aceptan: lo que importa es que el número sea único.
-- ---------------------------------------------------------------------
ALTER SEQUENCE public.registros_numero_seq RENAME TO ordenes_numero_seq;

ALTER TABLE public.ordenes_servicio
    ALTER COLUMN numero_orden
    SET DEFAULT ('OS-' || to_char(now(), 'YYYY') || '-'
                 || lpad(nextval('public.ordenes_numero_seq')::text, 4, '0'));

-- ---------------------------------------------------------------------
--  4. TRIGGERS VIEJOS (la tabla ya está renombrada; los triggers
--     siguen colgados de ella con sus nombres viejos)
-- ---------------------------------------------------------------------
DROP TRIGGER trg_registros_historial        ON public.ordenes_servicio;
DROP TRIGGER trg_registros_updated_at       ON public.ordenes_servicio;
DROP TRIGGER trg_validar_transicion_registro ON public.ordenes_servicio;
DROP TRIGGER trg_historial_registros_inmutable ON public.historial_ordenes;
-- El trigger de cobertura de revisiones apunta a una función renombrada
-- (abajo): se suelta aquí y vuelve con el mismo nombre tras la re-creación.
DROP TRIGGER trg_revisiones_cobertura ON public.revisiones;

-- Las funciones cuya firma el renombre NO toca se re-ejecutan como
-- CREATE OR REPLACE (abajo); las renombradas, o con renombre en el
-- RETURNS, llevan firma idéntica a la original y se retiran ANTES de
-- crear la versión nueva (si no, la creación colisiona con la firma
-- vieja). La retirada va después de soltar los triggers que las usaban.
DROP FUNCTION public.registrar_historial_registro();
DROP FUNCTION public.historial_registros_es_inmutable();
DROP FUNCTION public.actualizar_cobertura_registro();
DROP FUNCTION public.buscar_equipo(text);
DROP FUNCTION public.consultar_registro(text, text);
DROP FUNCTION public.registrar_revision(uuid, text, jsonb, text);
DROP FUNCTION public.registrar_ingreso(text, uuid, uuid, text, text, text, text, date, integer, text, jsonb, text, timestamptz, uuid);

-- ---------------------------------------------------------------------
--  5. FUNCIONES NUEVAS (cuerpos fuente con solo los nombres cambiados)
-- ---------------------------------------------------------------------
-- ---- Escritura del historial (AFTER INSERT OR UPDATE OF estado) ----
CREATE FUNCTION public.registrar_historial_orden()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO public.historial_ordenes
            (orden_id, estado_anterior, estado_nuevo, modificado_por, comentario)
        VALUES (NEW.id, NULL, NEW.estado, auth.uid(), 'Orden creada');
        RETURN NEW;
    END IF;

    IF NEW.estado IS DISTINCT FROM OLD.estado THEN
        INSERT INTO public.historial_ordenes
            (orden_id, estado_anterior, estado_nuevo, modificado_por, comentario)
        VALUES (NEW.id, OLD.estado, NEW.estado, auth.uid(),
                nullif(btrim(coalesce(NEW.diagnostico, '')), ''));
    END IF;

    RETURN NEW;
END;
$$;

-- Inmutabilidad del historial: ni service_role ni el dueño lo editan.
CREATE FUNCTION public.historial_ordenes_es_inmutable()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
    RAISE EXCEPTION 'historial_ordenes es de solo anexado: % no está permitido', TG_OP
        USING ERRCODE = '42501';
END;
$$;

-- ---- RESULTADO: lo calcula la base (BEFORE INSERT), cuerpos de la 0007 ----
-- Precedencia del spec §4.2 aplicada a los DATOS del equipo: el vencimiento
-- sale de la fecha de emisión guardada en el equipo, el día de ingreso de
-- orden.fecha_ingreso evaluado en Caracas (hoy_local).
CREATE OR REPLACE FUNCTION public.fijar_resultado_revision()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
    v_registro RECORD;
BEGIN
    SELECT e.vence_el, public.hoy_local(r.fecha_ingreso) AS ingreso
      INTO v_registro
      FROM public.ordenes_servicio r
      JOIN public.equipos e ON e.id = r.equipo_id
     WHERE r.id = NEW.orden_id;

    IF v_registro IS NULL THEN
        RAISE EXCEPTION 'La revisión apunta a un registro inexistente'
            USING ERRCODE = '23503';
    END IF;

    -- Lo que el cliente haya puesto en NEW.resultado queda descartado.
    NEW.resultado := public.calcular_cobertura(v_registro.vence_el, v_registro.ingreso, NEW.checklist);
    RETURN NEW;
END;
$$;

-- ---- COBERTURA DE LA ORDEN (AFTER INSERT): cuerpo de la 0007 ----
-- La cobertura de la orden pasa al resultado de SU ÚLTIMA revisión; una
-- revisión posterior puede cambiarla (por ejemplo, de POR_DETERMINAR a
-- EN_GARANTIA al confirmar la compra, o a ANULADA_POR_USO al ver golpes).
CREATE FUNCTION public.actualizar_cobertura_orden()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
    UPDATE public.ordenes_servicio
       SET cobertura = NEW.resultado,
           motivo_anulacion_cobertura =
               CASE WHEN NEW.resultado = 'ANULADA_POR_USO'
                    THEN public.motivo_anulacion(NEW.checklist)
               END
     WHERE id = NEW.orden_id;
    RETURN NEW;
END;
$$;

-- trg_revisiones_resultado no se toca: apunta a fijar_resultado_revision,
-- que sigue llamándose igual (solo cambió su cuerpo).

CREATE TRIGGER trg_revisiones_cobertura
    AFTER INSERT ON public.revisiones
    FOR EACH ROW EXECUTE FUNCTION public.actualizar_cobertura_orden();

-- ---- Validación del archivo (BEFORE INSERT): idéntica a la 0008 ----
CREATE OR REPLACE FUNCTION public.validar_adjunto()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
    v_fotos   INTEGER;
    v_docs    INTEGER;
    v_tope    CONSTANT INTEGER := 8 * 1024 * 1024;   -- 8 MB
BEGIN
    -- Tipo de archivo según uso.
    IF NEW.tipo = 'FOTO' THEN
        IF NEW.mime NOT IN ('image/jpeg', 'image/png', 'image/webp') THEN
            RAISE EXCEPTION
                'Formato no admitido para FOTO: usa JPG, PNG o WEBP (recibido: %)', NEW.mime
                USING ERRCODE = '22P02';
        END IF;
    ELSE  -- DOCUMENTO
        IF NEW.mime NOT IN ('application/pdf', 'image/jpeg', 'image/png') THEN
            RAISE EXCEPTION
                'Formato no admitido para DOCUMENTO: usa PDF, JPG o PNG (recibido: %)', NEW.mime
                USING ERRCODE = '22P02';
        END IF;
    END IF;

    -- Tamaño.
    IF NEW.bytes > v_tope THEN
        RAISE EXCEPTION
            'El archivo no puede pesar más de 8 MB (recibido: %), y el límite es común a fotos y documentos',
            round(NEW.bytes / (1024.0 * 1024), 1)
            USING ERRCODE = '22P02';
    END IF;

    -- Cantidad por orden: 8 fotos, 6 documentos.
    SELECT count(*) FILTER (WHERE tipo = 'FOTO') INTO v_fotos
      FROM public.adjuntos WHERE orden_id = NEW.orden_id;
    IF NEW.tipo = 'FOTO' AND v_fotos >= 8 THEN
        RAISE EXCEPTION 'El registro ya tiene 8 fotos: no se admiten más'
            USING ERRCODE = '22P02';
    END IF;
    SELECT count(*) FILTER (WHERE tipo = 'DOCUMENTO') INTO v_docs
      FROM public.adjuntos WHERE orden_id = NEW.orden_id;
    IF NEW.tipo = 'DOCUMENTO' AND v_docs >= 6 THEN
        RAISE EXCEPTION 'El registro ya tiene 6 documentos: no se admiten más'
            USING ERRCODE = '22P02';
    END IF;

    RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------
--  BUSCAR_EQUIPO — por serial en TODOS los productos (spec §5.1)
--     Devuelve también el historial de registros del equipo, para el
--     asistente (paso 1) y la advertencia de serial en otro producto.
-- ---------------------------------------------------------------------
CREATE FUNCTION public.buscar_equipo(p_serial text)
RETURNS TABLE (
    equipo_id        uuid,
    producto_id      uuid,
    producto         text,
    numero_serie     text,
    titular_id       uuid,
    titular          text,
    vence_el         date,
    dias_restantes   integer,
    ordenes_servicio jsonb
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    RETURN QUERY
    SELECT e.id, e.producto_id,
           (m.nombre || ' ' || pr.modelo)::text,
           e.numero_serie,
           e.cliente_id, c.nombre,
           e.vence_el,
           (e.vence_el - public.hoy_local())::int,
           COALESCE((
               SELECT jsonb_agg(
                          jsonb_build_object(
                              'numero',  r.numero_orden,
                              'estado',  r.estado,
                              'ingreso', r.fecha_ingreso::text,
                              'cobertura', r.cobertura::text)
                          ORDER BY r.fecha_ingreso)
                 FROM public.ordenes_servicio r
                WHERE r.equipo_id = e.id), '[]'::jsonb)
      FROM public.equipos e
      JOIN public.productos pr ON pr.id = e.producto_id
      JOIN public.marcas m     ON m.id  = pr.marca_id
      JOIN public.clientes c   ON c.id  = e.cliente_id
     WHERE (p_serial IS NOT NULL AND btrim(p_serial) <> ''
            AND e.serie_normalizada = public.normalizar_serie(btrim(p_serial)));
END;
$$;

REVOKE ALL ON FUNCTION public.buscar_equipo(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.buscar_equipo(text) TO authenticated;

-- ---------------------------------------------------------------------
--  ABRIR_ORDEN — la transacción completa; cuerpo EXACTO de la 0012
--  (idempotencia por clave de envío, revisión de ingeniería H1/H2).
--
--  Un doble clic, o un reintento tras un timeout, creaba dos registros
--  (cada uno con su token) para el mismo ingreso. Ahora el asistente
--  genera una clave por envío (uuid) y la base devuelve el registro
--  original si el mismo usuario la repite. Sin clave (NULL) el
--  comportamiento no cambia. Crea o reutiliza el equipo (ON CONFLICT,
--  sin carreras), crea la orden con su correlativo, inserta la revisión
--  de RECEPCION (que fija la cobertura a través de los triggers de
--  revisiones) y devuelve el token de consulta UNA VEZ. Todo en una
--  transacción: si algo falla, nada queda.
-- ---------------------------------------------------------------------
CREATE FUNCTION public.abrir_orden(
    p_serial          text,
    p_producto_id     uuid,
    p_cliente_id      uuid,
    p_falla           text,
    p_accesorios      text DEFAULT NULL,
    p_tipo_soporte    text DEFAULT NULL,
    p_numero_soporte  text DEFAULT NULL,
    p_fecha_emision   date DEFAULT NULL,
    p_plazo_dias      integer DEFAULT NULL,
    p_vendedor        text DEFAULT NULL,
    p_checklist       jsonb DEFAULT NULL,
    p_observaciones   text DEFAULT NULL,
    p_fecha_ingreso   timestamptz DEFAULT NULL,
    p_clave_envio     uuid DEFAULT NULL)
RETURNS TABLE (
    orden_id        uuid,
    numero_orden    text,
    consulta_token  text,   -- TEXTO PLANO, una sola vez (imprimir y olvidar)
    cobertura       public.cobertura_garantia,
    equipo_id       uuid,
    equipo_nuevo    boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_rol    public.app_role := public.mi_rol();
    v_actor  uuid := auth.uid();
    v_serial text := btrim(coalesce(p_serial, ''));
    v_falla  text := btrim(coalesce(p_falla, ''));
    v_equipo uuid;
    v_nuevo  boolean;
    v_token  text;
    v_registro uuid;
BEGIN
    IF v_rol IS NULL OR NOT public.tiene_rol('ADMIN', 'JEFE_SERVICIO', 'TECNICO', 'RECEPCION') THEN
        RAISE EXCEPTION 'Su rol no puede registrar ingresos' USING ERRCODE = '42501';
    END IF;

    -- ---- Idempotencia: la misma clave del mismo usuario = el mismo registro ----
    -- El candado serializa dos envíos simultáneos con la misma clave (doble
    -- clic): el segundo espera al primero y encuentra su registro. El token en
    -- claro NO se puede reconstruir (solo se guarda el hash): vuelve en NULL.
    IF p_clave_envio IS NOT NULL THEN
        PERFORM pg_advisory_xact_lock(hashtextextended(v_actor::text || p_clave_envio::text, 0));
        RETURN QUERY
        SELECT r.id, r.numero_orden, NULL::text, r.cobertura, r.equipo_id, false
          FROM public.ordenes_servicio r
         WHERE r.creado_por = v_actor AND r.clave_envio = p_clave_envio;
        IF FOUND THEN
            RETURN;
        END IF;
    END IF;

    IF v_serial < '!' OR length(v_serial) < 3 THEN
        RAISE EXCEPTION 'El serial es obligatorio (3 a 60 caracteres)'
            USING ERRCODE = '22P02';
    END IF;
    IF length(v_falla) < 5 OR length(v_falla) > 2000 THEN
        RAISE EXCEPTION 'La falla reportada es obligatoria (5 a 2000 caracteres)'
            USING ERRCODE = '22P02';
    END IF;

    -- ---- Equipo: buscar y, si no existe, crearlo (sin carrera) ----
    v_equipo := NULL;
    IF p_producto_id IS NOT NULL AND p_cliente_id IS NOT NULL THEN
        SELECT id INTO v_equipo
          FROM public.equipos
         WHERE producto_id = p_producto_id
           AND serie_normalizada = public.normalizar_serie(v_serial);
    END IF;

    v_nuevo := v_equipo IS NULL;
    IF v_nuevo THEN
        IF p_producto_id IS NULL OR p_cliente_id IS NULL THEN
            RAISE EXCEPTION 'Para un equipo nuevo hacen falta producto y titular'
                USING ERRCODE = '22P02';
        END IF;
        INSERT INTO public.equipos (numero_serie, producto_id, cliente_id,
                                    tipo_soporte, numero_soporte, fecha_emision,
                                    plazo_dias, vendedor)
        VALUES (v_serial, p_producto_id, p_cliente_id,
                nullif(btrim(coalesce(p_tipo_soporte, '')), ''),
                nullif(btrim(coalesce(p_numero_soporte, '')), ''),
                p_fecha_emision, p_plazo_dias,
                nullif(btrim(coalesce(p_vendedor, '')), ''))
        ON CONFLICT (producto_id, serie_normalizada) DO NOTHING;

        SELECT id INTO v_equipo
          FROM public.equipos
         WHERE producto_id = p_producto_id
           AND serie_normalizada = public.normalizar_serie(v_serial);
        IF v_equipo IS NULL THEN
            RAISE EXCEPTION 'No fue posible crear el equipo (revise el serial)'
                USING ERRCODE = '23505';
        END IF;
    END IF;

    -- ---- Orden ----
    v_token := encode(extensions.gen_random_bytes(16), 'hex');

    INSERT INTO public.ordenes_servicio (equipo_id, falla_reportada, accesorios,
                                  cobertura, tecnico_asignado_id, creado_por,
                                  consulta_token_hash, fecha_ingreso, clave_envio)
    VALUES (v_equipo, v_falla,
            nullif(btrim(coalesce(p_accesorios, '')), ''),
            'POR_DETERMINAR',
            CASE WHEN v_rol = 'TECNICO' THEN v_actor END,
            v_actor,
            extensions.digest(v_token, 'sha256'),
            -- La fecha de ingreso la manda SOLO el ADMIN (backoffice, corrida
            -- a medianoche): a los demás roles se les ignora en silencio y
            -- reciben el DEFAULT now(). (Cierre de D4/3: esta función de la
            -- 0012 es la que queda viva tras el DROP de la 0009.)
            coalesce(CASE WHEN public.tiene_rol('ADMIN') THEN p_fecha_ingreso END, now()), p_clave_envio)
    RETURNING id INTO v_registro;

    -- ---- Primera revisión: la de recepción ----
    INSERT INTO public.revisiones (orden_id, tipo, revisado_por, checklist, observaciones)
    VALUES (v_registro, 'RECEPCION', v_actor, p_checklist,
            nullif(btrim(coalesce(p_observaciones, '')), ''));

    -- La cobertura la acaba de escribir el trigger de las revisiones.
    RETURN QUERY
    SELECT r.id, r.numero_orden, v_token, r.cobertura, v_equipo, v_nuevo
      FROM public.ordenes_servicio r
     WHERE r.id = v_registro;
END;
$$;

REVOKE ALL ON FUNCTION public.abrir_orden(text, uuid, uuid, text, text, text, text, date, integer, text, jsonb, text, timestamptz, uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.abrir_orden(text, uuid, uuid, text, text, text, text, date, integer, text, jsonb, text, timestamptz, uuid)
  TO authenticated;

-- ---------------------------------------------------------------------
--  REGISTRAR_REVISION — añade una revisión a una orden existente
--     (spec §6: ADMIN, JEFE_SERVICIO y TECNICO; RECEPCION no)
-- ---------------------------------------------------------------------
CREATE FUNCTION public.registrar_revision(
    p_orden_id      uuid,
    p_tipo          text,
    p_checklist     jsonb,
    p_observaciones text DEFAULT NULL)
RETURNS TABLE (revision_id uuid, cobertura public.cobertura_garantia)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_rol   public.app_role := public.mi_rol();
    v_id    uuid;
BEGIN
    IF v_rol IS NULL OR NOT public.tiene_rol('ADMIN', 'JEFE_SERVICIO', 'TECNICO') THEN
        RAISE EXCEPTION 'Su rol no puede registrar revisiones' USING ERRCODE = '42501';
    END IF;
    IF p_tipo NOT IN ('RECEPCION', 'TECNICA') THEN
        RAISE EXCEPTION 'El tipo de revisión es RECEPCION o TECNICA' USING ERRCODE = '22P02';
    END IF;
    IF p_checklist IS NOT NULL AND NOT public.checklist_es_valido(p_checklist) THEN
        RAISE EXCEPTION 'La lista de verificación no está completa' USING ERRCODE = '22P02';
    END IF;

    INSERT INTO public.revisiones (orden_id, tipo, revisado_por, checklist, observaciones)
    VALUES (p_orden_id, p_tipo, auth.uid(), p_checklist,
            nullif(btrim(coalesce(p_observaciones, '')), ''))
    RETURNING id INTO v_id;

    RETURN QUERY
    SELECT v_id, r.cobertura
      FROM public.ordenes_servicio r
     WHERE r.id = p_orden_id;
END;
$$;

REVOKE ALL ON FUNCTION public.registrar_revision(uuid, text, jsonb, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.registrar_revision(uuid, text, jsonb, text) TO authenticated;

-- ---------------------------------------------------------------------
--  CONFIRMAR_COMPRA — solo ADMIN y JEFE_SERVICIO (spec §4.4 y §6)
-- ---------------------------------------------------------------------
-- Completa los datos de factura que confirmó Ventas, deja registrado quién
-- y cuándo (el gancho para la consulta de ventas del hito siguiente) y
-- recalcula la cobertura de las órdenes ABIERTAS del equipo, que salen
-- de POR_DETERMINAR gracias al checklist de su última revisión.
CREATE OR REPLACE FUNCTION public.confirmar_compra(
    p_equipo_id      uuid,
    p_tipo_soporte   text,
    p_numero_soporte text,
    p_fecha_emision  date,
    p_plazo_dias     integer)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_rol   public.app_role := public.mi_rol();
    v_tiene_soporte boolean;
BEGIN
    IF v_rol IS NULL OR NOT public.tiene_rol('ADMIN', 'JEFE_SERVICIO') THEN
        RAISE EXCEPTION 'Solo ADMIN o JEFE_SERVICIO confirman la compra' USING ERRCODE = '42501';
    END IF;

    IF coalesce(p_tipo_soporte, '') NOT IN ('FACTURA', 'NOTA_ENTREGA')
       OR coalesce(p_numero_soporte, '') = ''
       OR p_fecha_emision IS NULL OR p_plazo_dias IS NULL THEN
        RAISE EXCEPTION 'Faltan datos del soporte: tipo, número, fecha de emisión y plazo'
            USING ERRCODE = '22P02';
    END IF;

    SELECT (numero_soporte IS NOT NULL) INTO v_tiene_soporte
      FROM public.equipos WHERE id = p_equipo_id;
    IF v_tiene_soporte IS NULL THEN
        RAISE EXCEPTION 'Equipo inexistente' USING ERRCODE = 'P0002';
    END IF;
    IF v_tiene_soporte THEN
        RAISE EXCEPTION 'El equipo ya tiene soporte de compras registrado'
            USING ERRCODE = '23505';
    END IF;

    UPDATE public.equipos
       SET tipo_soporte   = p_tipo_soporte,
           numero_soporte = btrim(p_numero_soporte),
           fecha_emision  = p_fecha_emision,
           plazo_dias     = p_plazo_dias,
           compra_confirmada_por = auth.uid(),
           compra_confirmada_en  = now()
     WHERE id = p_equipo_id;

    -- Recalcular la cobertura de las órdenes abiertas con su última revisión.
    UPDATE public.ordenes_servicio r
       SET cobertura = c_resultado.nueva,
           motivo_anulacion_cobertura = c_resultado.motivo
      FROM (
        SELECT r2.id AS orden,
               public.calcular_cobertura(f.vence_el, public.hoy_local(r2.fecha_ingreso), v2.checklist) AS nueva,
               CASE WHEN public.calcular_cobertura(f.vence_el, public.hoy_local(r2.fecha_ingreso), v2.checklist) = 'ANULADA_POR_USO'
                    THEN public.motivo_anulacion(v2.checklist) END AS motivo
          FROM public.ordenes_servicio r2
          JOIN public.equipos f   ON f.id = r2.equipo_id
          CROSS JOIN LATERAL (
            SELECT checklist
              FROM public.revisiones vr
             WHERE vr.orden_id = r2.id
             ORDER BY revisado_en DESC, id DESC LIMIT 1) v2
         WHERE r2.equipo_id = p_equipo_id
           AND r2.estado NOT IN ('ENTREGADO', 'ANULADO')
      ) c_resultado
     WHERE r.id = c_resultado.orden;
END;
$$;

REVOKE ALL ON FUNCTION public.confirmar_compra(uuid, text, text, date, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.confirmar_compra(uuid, text, text, date, integer) TO authenticated;

-- ---------------------------------------------------------------------
--  CONSULTA PÚBLICA: consultar_registro (se conserva el nombre; el
--  RETURNS y el cuerpo van con `numero_orden`)
-- ---------------------------------------------------------------------
-- Sin interfaz en este hito: la pantalla llega después, la base ya queda.
CREATE FUNCTION public.consultar_registro(
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
    v_rid      UUID;
BEGIN
    -- IP real del cliente (PostgREST expone las cabeceras del request).
    BEGIN
        v_ip := nullif(btrim(split_part(
                    coalesce(current_setting('request.headers', TRUE)::json ->> 'x-forwarded-for', ''),
                    ',', 1)), '')::inet;
    EXCEPTION WHEN OTHERS THEN
        v_ip := NULL;
    END;

    -- Freno de fuerza bruta (portado sin cambios).
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

    -- Búsqueda POR EL HASH: cero filas responde igual a "no existe" que a
    -- "token incorrecto" (anti-enumeración) y el intento queda en bitácora.
    SELECT r.id INTO v_rid
      FROM public.ordenes_servicio r
     WHERE r.consulta_token_hash = extensions.digest(coalesce(p_token, ''), 'sha256')
       AND r.numero_orden = upper(btrim(coalesce(p_numero_orden, '')));

    INSERT INTO public.consulta_publica_intentos (ip, numero_orden, exito)
    VALUES (v_ip, p_numero_orden, v_rid IS NOT NULL);

    IF v_rid IS NULL THEN
        RETURN;
    END IF;

    RETURN QUERY
    SELECT r.numero_orden,
           r.estado,
           e.nombre,
           (m.nombre || ' ' || pr.modelo)::TEXT,
           r.falla_reportada,
           r.diagnostico,
           r.cobertura,
           r.fecha_ingreso,
           r.fecha_entrega,
           r.updated_at
      FROM public.ordenes_servicio r
      JOIN public.estados_garantia e ON e.codigo = r.estado
      JOIN public.equipos eq         ON eq.id = r.equipo_id
      JOIN public.productos pr       ON pr.id = eq.producto_id
      JOIN public.marcas m           ON m.id = pr.marca_id
     WHERE r.id = v_rid;
END;
$$;

REVOKE ALL ON FUNCTION public.consultar_registro(TEXT, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.consultar_registro(TEXT, TEXT) TO anon, authenticated;

-- ---------------------------------------------------------------------
--  LIMPIEZA DE ARCHIVOS HUÉRFANOS (cuerpo fuente de la 0011): el único
--  flujo que BORRA archivos, y solo los del almacenamiento que NO
--  tienen fila en `adjuntos` y ya tienen más de 24 horas (no se tocan
--  subidas en curso). Las filas de `adjuntos` nunca se tocan aquí.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.listar_huerfanos(p_gracia interval DEFAULT interval '24 hours')
RETURNS TABLE (nombre text)
LANGUAGE sql
STABLE
AS $$
  SELECT o.name
    FROM storage.objects o
   WHERE o.bucket_id = 'ordenes'
     AND o.created_at < now() - p_gracia
     AND NOT EXISTS (SELECT 1 FROM public.adjuntos a WHERE a.ruta = o.name);
$$;

-- Solo la ejecuta el borrador programado (la Edge Function con service_role).
REVOKE ALL ON FUNCTION public.listar_huerfanos(interval)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.listar_huerfanos(interval) TO service_role;

-- ---------------------------------------------------------------------
--  6. TRIGGERS NUEVOS (portados de §7 del Hito 1)
-- ---------------------------------------------------------------------
CREATE TRIGGER trg_ordenes_historial
    AFTER INSERT OR UPDATE OF estado ON public.ordenes_servicio
    FOR EACH ROW EXECUTE FUNCTION public.registrar_historial_orden();

CREATE TRIGGER trg_historial_ordenes_inmutable
    BEFORE UPDATE OR DELETE ON public.historial_ordenes
    FOR EACH ROW EXECUTE FUNCTION public.historial_ordenes_es_inmutable();

CREATE TRIGGER trg_ordenes_updated_at
    BEFORE UPDATE ON public.ordenes_servicio
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE TRIGGER trg_validar_transicion_orden
    BEFORE UPDATE OF estado ON public.ordenes_servicio
    FOR EACH ROW EXECUTE FUNCTION public.validar_transicion_estado();

-- ---------------------------------------------------------------------
--  7. CHECK DE LA RUTA DE ADJUNTOS: pasa de registros/{id}/… a ordenes/{id}/…
-- ---------------------------------------------------------------------
ALTER TABLE public.adjuntos DROP CONSTRAINT IF EXISTS adjuntos_ruta_check;
ALTER TABLE public.adjuntos
    ADD CONSTRAINT adjuntos_ruta_check CHECK (ruta ~ '^ordenes/.+/.+');

-- ---------------------------------------------------------------------
--  8. STORAGE: bucket privado `ordenes` y políticas por ruta
-- ---------------------------------------------------------------------
-- Ruta obligatoria: ordenes/{orden_id}/… (así sube la app; spec §5.4).
-- El SEGUNDO segmento debe ser el id de una orden existente: el primero
-- es literal "ordenes" y nadie escribe fuera de ese patrón (en este hito,
-- fuera de "una orden existente", sin cuotas por usuario).
-- El guardia de formato primero: sin él, un segmento no-uuid (p. ej.
-- "otra-cosa" en el segundo) fallaría con "invalid input syntax" en vez
-- de RLS.
INSERT INTO storage.buckets (id, name, public)
VALUES ('ordenes', 'ordenes', false)
ON CONFLICT (id) DO UPDATE SET public = false;

DROP POLICY storage_subir_adjunto ON storage.objects;
CREATE POLICY storage_subir_adjunto ON storage.objects
    FOR INSERT TO authenticated
    WITH CHECK (
        bucket_id = 'ordenes'
        AND public.mi_rol() IS NOT NULL
        AND split_part(name, '/', 1) = 'ordenes'
        AND split_part(name, '/', 2) ~ '^[0-9a-f-]{36}$'
        AND split_part(name, '/', 2)::uuid IN (SELECT o.id FROM public.ordenes_servicio o)
    );

DROP POLICY storage_ver_adjunto ON storage.objects;
CREATE POLICY storage_ver_adjunto ON storage.objects
    FOR SELECT TO authenticated
    USING (
        bucket_id = 'ordenes'
        AND public.mi_rol() IS NOT NULL
        AND split_part(name, '/', 1) = 'ordenes'
        AND split_part(name, '/', 2) ~ '^[0-9a-f-]{36}$'
        AND split_part(name, '/', 2)::uuid IN (SELECT o.id FROM public.ordenes_servicio o)
    );

-- anon no queda con ningún acceso al bucket: no se escriben políticas
-- para anon y el GRANT del esquema storage ya lo excluye de las tablas.

-- La fila del bucket viejo sale SOLO si no queda ningún objeto dentro:
-- en un remoto recién desplegado no hay objetos (datos de prueba), pero
-- la guardia evita enredar archivos vivos con el renombre.
-- Supabase prohíbe el DELETE directo sobre storage (42501): allí el bucket
-- vacío 'registros' se borra a mano desde el panel o la API de Storage.
DO $$
BEGIN
    DELETE FROM storage.buckets WHERE id = 'registros'
      AND NOT EXISTS (SELECT 1 FROM storage.objects WHERE bucket_id = 'registros');
EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'Bucket "registros" no borrado (storage lo protege): bórralo desde el panel de Storage';
END $$;

-- ---------------------------------------------------------------------
--  REPASO IDEMPOTENTE DE ADJUNTOS (decisión de la conversación: no se
--  sabe si el proyecto remoto aplicó la 0008 original, así que las
--  sentencias se re-ejecutan como idempotentes)
-- ---------------------------------------------------------------------
ALTER TABLE public.adjuntos ALTER COLUMN subido_por SET DEFAULT auth.uid();

DROP POLICY IF EXISTS adj_insert ON public.adjuntos;
CREATE POLICY adj_insert ON public.adjuntos
    FOR INSERT TO authenticated
    WITH CHECK (subido_por = auth.uid());

-- ---------------------------------------------------------------------
--  9. VISTA DEL TABLERO: un `CREATE OR REPLACE VIEW` no alcanza porque
--  el renombre cambia los nombres de sus columnas (`orden_id`,
--  `numero_orden`); hay que soltarla y re-crearla (security_invoker:
--  es la RLS de las tablas base la que decide; los roles internos leen
--  todo). Los GRANT se re-aplican tras la re-creación.
-- ---------------------------------------------------------------------
DROP VIEW public.v_tablero;

CREATE OR REPLACE VIEW public.v_tablero
WITH (security_invoker = true) AS
SELECT r.id AS orden_id,
       r.numero_orden,
       r.estado,
       e.nombre AS estado_nombre,
       r.cobertura::text AS cobertura,
       eq.numero_serie AS serial,
       (m.nombre || ' ' || pr.modelo) AS producto,
       c.nombre AS cliente,
       c.documento AS documento,
       -- Para la búsqueda del Tablero por número de factura (spec §7.3).
       eq.numero_soporte AS numero_soporte,
       r.fecha_ingreso,
       eq.vence_el,
       CASE WHEN eq.vence_el IS NULL THEN NULL
            ELSE eq.vence_el - public.hoy_local() END AS dias_restantes,
       CASE WHEN eq.vence_el IS NULL                     THEN 'PENDIENTE'
            WHEN eq.vence_el - public.hoy_local() < 0    THEN 'VENCIDA'
            WHEN eq.vence_el - public.hoy_local() = 0    THEN 'HOY'
            WHEN eq.vence_el - public.hoy_local() <= public.ajuste('umbral_critico') THEN 'CRITICA'
            WHEN eq.vence_el - public.hoy_local() <= public.ajuste('umbral_pronto')  THEN 'PRONTO'
            ELSE 'NORMAL' END AS nivel_vigencia,
       (public.hoy_local() - public.hoy_local(r.fecha_ingreso)) AS dias_en_taller,
       CASE WHEN (public.hoy_local() - public.hoy_local(r.fecha_ingreso)) >= public.ajuste('sla_critico') THEN 'CRITICO'
            WHEN (public.hoy_local() - public.hoy_local(r.fecha_ingreso)) >= public.ajuste('sla_alerta')  THEN 'ALERTA'
            ELSE 'NORMAL' END AS nivel_sla,
       -- Cerrados: -1 (al final); abiertos: el PEOR de los dos niveles.
       -- La vigencia SOLO cuenta si la cobertura es EN_GARANTIA o
       -- POR_DETERMINAR (§4.6): un equipo que ya entró fuera de garantía o
       -- anulado tiene su fecha informativa y no sube en el orden.
       CASE WHEN r.estado NOT IN ('ENTREGADO', 'ANULADO')
            THEN GREATEST(
                CASE WHEN r.cobertura NOT IN ('EN_GARANTIA', 'POR_DETERMINAR') THEN 0
                     WHEN eq.vence_el IS NULL THEN 1
                     WHEN eq.vence_el - public.hoy_local() < 0 THEN 4
                     WHEN eq.vence_el - public.hoy_local() = 0 THEN 3
                     WHEN eq.vence_el - public.hoy_local() <= public.ajuste('umbral_critico') THEN 2
                     WHEN eq.vence_el - public.hoy_local() <= public.ajuste('umbral_pronto')  THEN 1
                     ELSE 0 END,
                CASE WHEN (public.hoy_local() - public.hoy_local(r.fecha_ingreso)) >= public.ajuste('sla_critico') THEN 2
                     WHEN (public.hoy_local() - public.hoy_local(r.fecha_ingreso)) >= public.ajuste('sla_alerta')  THEN 1
                     ELSE 0 END)
            ELSE -1 END AS urgencia_rank,
       (r.estado NOT IN ('ENTREGADO', 'ANULADO')) AS abierto
  FROM public.ordenes_servicio r
  JOIN public.estados_garantia e ON e.codigo = r.estado
  JOIN public.equipos eq         ON eq.id = r.equipo_id
  JOIN public.productos pr       ON pr.id = eq.producto_id
  JOIN public.marcas m           ON m.id = pr.marca_id
  JOIN public.clientes c         ON c.id = eq.cliente_id;

REVOKE ALL ON public.v_tablero FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.v_tablero TO authenticated;

-- ---------------------------------------------------------------------
--  10. COMENTARIO DE TABLA (el historial no tenía uno en la fuente)
-- ---------------------------------------------------------------------
COMMENT ON TABLE public.ordenes_servicio IS
'Nunca se borran filas. Una orden creada por error pasa a estado ANULADO.';

-- =================== 20261030000014_equipos_origen.sql ===================
-- =====================================================================
--  20261030000014_equipos_origen.sql
--  Origen de la garantía (VENTA vs TALLER), desestimación de compra y
--  la precedencia NUEVA de `calcular_cobertura` (spec §4.1 y §4.2):
--  la confianza de una garantía de taller exige confirmación
--  administrativa antes de cubrir. La repaso de adjuntos ya está en la
--  0013: no se repite aquí.
-- =====================================================================

-- ---------------------------------------------------------------------
--  1. EQUIPOS: origen, autor del registro y desestimación (spec §5.2)
-- ---------------------------------------------------------------------
-- ORIGEN: VENTA (la garantía la registró el punto de venta; se confía de
-- inmediato) o TALLER (la fila la creó el taller desde Consulta, sin
-- compra aún: POR_DETERMINAR hasta que ADMIN o JEFE_SERVICIO confirme o
-- desestime). El DEFAULT 'VENTA' mantiene el comportamiento previo de
-- `abrir_orden` sin tocar su cuerpo.
ALTER TABLE public.equipos
    ADD COLUMN origen text NOT NULL DEFAULT 'VENTA'
        CONSTRAINT ck_origen CHECK (origen IN ('VENTA', 'TALLER')),

    -- Quien creó la fila del equipo (el asistente de ingreso); el spec
    -- §4.1 lo exige para la auditoría de la garantía de taller.
    ADD COLUMN registrado_por uuid REFERENCES public.profiles(id) ON DELETE SET NULL,

    -- Desestimación de la compra: ADMIN o JEFE_SERVICIO decide que la
    -- garantía NO procede, con motivo obligatorio (se guarda quién y cuándo).
    ADD COLUMN compra_desestimada_por uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
    ADD COLUMN compra_desestimada_en  timestamptz,
    ADD COLUMN compra_desestimada_motivo text;

-- La desestimación va COMPLETA o NO VA: los tres datos juntos, el motivo
-- con sustancia (10+ caracteres tras recortar espacios).
ALTER TABLE public.equipos
    ADD CONSTRAINT ck_desestimacion_completa CHECK (
        (compra_desestimada_por IS NULL
            AND compra_desestimada_en IS NULL
            AND compra_desestimada_motivo IS NULL)
        OR (compra_desestimada_por IS NOT NULL
            AND compra_desestimada_en IS NOT NULL
            AND compra_desestimada_motivo IS NOT NULL
            AND length(btrim(compra_desestimada_motivo)) >= 10));

-- Excluyentes (spec §4.1): un equipo no puede estar con la compra
-- confirmada y desestimada a la vez.
ALTER TABLE public.equipos
    ADD CONSTRAINT ck_confirmar_desestimar_excluyentes CHECK (
        NOT (compra_confirmada_por IS NOT NULL
             AND compra_desestimada_por IS NOT NULL));

-- ---------------------------------------------------------------------
--  2. CALCULAR_COBERTURA — la única fuente de verdad (spec §4.2)
-- ---------------------------------------------------------------------
-- Función PURA: ningún trigger ni columna generada la duplica. La UI la
-- llama en vivo (paso Verificación del asistente) y la base la aplica al
-- guardar la revisión. El resultado lo emite SIEMPRE la base; el cliente
-- solo aporta la lista de verificación.
--
-- Estructura del checklist (spec §4.3):
--   {"condiciones":{"factura_presentada":true,"titular_coincide":true},
--    "equipo":{"serial_legible":true,"caja_original":true,
--              "precintos_intactos":true,"contenido_completo":true},
--    "senales":{"descarga_electrica":false,"liquidos":false,
--               "altas_temperaturas":false,"golpes":false,
--               "manipulacion_terceros":false}}
-- En `condiciones` y `equipo` el FALSE es un incumplimiento; en `senales`
-- el TRUE es una señal observada.
--
-- Firma nueva (tres parámetros con DEFAULT): las llamadas viejas con 3
-- argumentos (el frontend, `confirmar_compra` de la 0013) siguen
-- compilando con p_origen='VENTA', p_compra_confirmada=true y
-- p_compra_desestimada=false — el comportamiento previo, completo.
DROP FUNCTION public.calcular_cobertura(date, date, jsonb);

CREATE OR REPLACE FUNCTION public.calcular_cobertura(
    p_vence_el           date,
    p_fecha_ingreso      date,
    p_checklist          jsonb DEFAULT NULL,
    p_origen             text DEFAULT 'VENTA',
    p_compra_confirmada  boolean DEFAULT true,
    p_compra_desestimada boolean DEFAULT false)
RETURNS public.cobertura_garantia
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_terms     jsonb := '["serial_legible","caja_original","precintos_intactos","contenido_completo"]'::jsonb;
    v_condiciones jsonb := '["factura_presentada","titular_coincide"]'::jsonb;
    v_senales   jsonb := '["descarga_electrica","liquidos","altas_temperaturas","golpes","manipulacion_terceros"]'::jsonb;
    k text;
    incumple_termino    boolean := false;
    senal_observada     boolean := false;
    incumple_condicion  boolean := false;
BEGIN
    -- 1. ▲ (spec §4.2) La compra fue desestimada: la garantía NO procede,
    --    aunque el checklist y las fechas sean perfectos. Es el corte
    --    primero porque cierra la puerta antes de cualquier otra lectura.
    IF p_compra_desestimada THEN
        RETURN 'FUERA_DE_GARANTIA';
    END IF;
    -- 2. Sin fecha de vencimiento: se recibió sin factura.
    IF p_vence_el IS NULL THEN
        RETURN 'POR_DETERMINAR';
    END IF;
    -- 3. ▲ (spec §4.1) Origen TALLER y compra sin confirmar: la confianza
    --    exige confirmación administrativa antes de cubrir.
    IF p_origen = 'TALLER' AND NOT p_compra_confirmada THEN
        RETURN 'POR_DETERMINAR';
    END IF;
    -- 4. Entró después de que la garantía terminara.
    IF p_fecha_ingreso > p_vence_el THEN
        RETURN 'FUERA_DE_GARANTIA';
    END IF;

    IF p_checklist IS NOT NULL THEN
        IF p_checklist ? 'senales' THEN
            FOR k IN SELECT jsonb_array_elements_text(v_senales) LOOP
                IF (p_checklist #>> ARRAY['senales', k])::boolean = true THEN
                    senal_observada := true;
                END IF;
            END LOOP;
        END IF;
        IF p_checklist ? 'equipo' THEN
            FOR k IN SELECT jsonb_array_elements_text(v_terms) LOOP
                IF (p_checklist #>> ARRAY['equipo', k])::boolean = false THEN
                    incumple_termino := true;
                END IF;
            END LOOP;
        END IF;
        IF senal_observada OR incumple_termino THEN
            RETURN 'ANULADA_POR_USO';
        END IF;

        IF p_checklist ? 'condiciones' THEN
            FOR k IN SELECT jsonb_array_elements_text(v_condiciones) LOOP
                IF (p_checklist #>> ARRAY['condiciones', k])::boolean = false THEN
                    incumple_condicion := true;
                END IF;
            END LOOP;
        END IF;
        IF incumple_condicion THEN
            RETURN 'POR_DETERMINAR';
        END IF;
    END IF;

    RETURN 'EN_GARANTIA';
END $$;

GRANT EXECUTE ON FUNCTION public.calcular_cobertura(date, date, jsonb, text, boolean, boolean)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------
--  3. FIJAR_RESULTADO_REVISION (BEFORE INSERT en revisiones): cuerpo de
--  la 0013 con los 3 datos nuevos del equipo. La firma no cambia, así
--  que el trigger `trg_revisiones_resultado` no se toca ni se recrea.
-- ---------------------------------------------------------------------
-- Precedencia del spec §4.2 aplicada a los DATOS del equipo: el vencimiento
-- sale de la fecha de emisión guardada en el equipo, el día de ingreso de
-- orden.fecha_ingreso evaluado en Caracas (hoy_local).
CREATE OR REPLACE FUNCTION public.fijar_resultado_revision()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
    v_registro RECORD;
BEGIN
    SELECT e.vence_el, public.hoy_local(r.fecha_ingreso) AS ingreso,
           e.origen,
           (e.compra_confirmada_por IS NOT NULL)   AS confirmada,
           (e.compra_desestimada_por IS NOT NULL)  AS desestimada
      INTO v_registro
      FROM public.ordenes_servicio r
      JOIN public.equipos e ON e.id = r.equipo_id
     WHERE r.id = NEW.orden_id;

    IF v_registro IS NULL THEN
        RAISE EXCEPTION 'La revisión apunta a un registro inexistente'
            USING ERRCODE = '23503';
    END IF;

    -- Lo que el cliente haya puesto en NEW.resultado queda descartado.
    NEW.resultado := public.calcular_cobertura(v_registro.vence_el, v_registro.ingreso,
                                               NEW.checklist,
                                               v_registro.origen,
                                               v_registro.confirmada,
                                               v_registro.desestimada);
    RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------
--  4. CONFIRMAR_COMPRA — solo ADMIN y JEFE_SERVICIO (spec §4.4 y §6).
--  Firma pública idéntica a la de la 0013; en el recálculo se pasan los
--  3 datos nuevos del equipo (el trigger fijar_resultado_revision los
--  usa con la misma lógica).
-- ---------------------------------------------------------------------
-- Completa los datos de factura que confirmó Ventas, deja registrado quién
-- y cuándo (el gancho para la consulta de ventas del hito siguiente) y
-- recalcula la cobertura de las órdenes ABIERTAS del equipo, que salen
-- de POR_DETERMINAR gracias al checklist de su última revisión.
CREATE OR REPLACE FUNCTION public.confirmar_compra(
    p_equipo_id      uuid,
    p_tipo_soporte   text,
    p_numero_soporte text,
    p_fecha_emision  date,
    p_plazo_dias     integer)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_rol   public.app_role := public.mi_rol();
    v_tiene_soporte boolean;
BEGIN
    IF v_rol IS NULL OR NOT public.tiene_rol('ADMIN', 'JEFE_SERVICIO') THEN
        RAISE EXCEPTION 'Solo ADMIN o JEFE_SERVICIO confirman la compra' USING ERRCODE = '42501';
    END IF;

    IF coalesce(p_tipo_soporte, '') NOT IN ('FACTURA', 'NOTA_ENTREGA')
       OR coalesce(p_numero_soporte, '') = ''
       OR p_fecha_emision IS NULL OR p_plazo_dias IS NULL THEN
        RAISE EXCEPTION 'Faltan datos del soporte: tipo, número, fecha de emisión y plazo'
            USING ERRCODE = '22P02';
    END IF;

    SELECT (numero_soporte IS NOT NULL) INTO v_tiene_soporte
      FROM public.equipos WHERE id = p_equipo_id;
    IF v_tiene_soporte IS NULL THEN
        RAISE EXCEPTION 'Equipo inexistente' USING ERRCODE = 'P0002';
    END IF;
    IF v_tiene_soporte THEN
        RAISE EXCEPTION 'El equipo ya tiene soporte de compras registrado'
            USING ERRCODE = '23505';
    END IF;

    -- El CHECK ck_confirmar_desestimar_excluyentes de la 0014 impide que
    -- esta confirmación pase si el equipo ya fue desestimado: el UPDATE
    -- falla con 23514 y la compra desestimada no se «revive» por aquí.
    UPDATE public.equipos
       SET tipo_soporte   = p_tipo_soporte,
           numero_soporte = btrim(p_numero_soporte),
           fecha_emision  = p_fecha_emision,
           plazo_dias     = p_plazo_dias,
           compra_confirmada_por = auth.uid(),
           compra_confirmada_en  = now()
     WHERE id = p_equipo_id;

    -- Recalcular la cobertura de las órdenes abiertas con su última revisión;
    -- el recálculo usa los DATOS ACTUALIZADOS del equipo (origen, compra
    -- confirmada, desestimada) con la precedencia nueva del spec §4.2.
    UPDATE public.ordenes_servicio r
       SET cobertura = c_resultado.nueva,
           motivo_anulacion_cobertura = c_resultado.motivo
      FROM (
        SELECT r2.id AS orden,
               c.nueva,
               CASE WHEN c.nueva = 'ANULADA_POR_USO'
                    THEN public.motivo_anulacion(v2.checklist) END AS motivo
          FROM public.ordenes_servicio r2
          JOIN public.equipos f   ON f.id = r2.equipo_id
          CROSS JOIN LATERAL (
            SELECT checklist
              FROM public.revisiones vr
             WHERE vr.orden_id = r2.id
             ORDER BY revisado_en DESC, id DESC LIMIT 1) v2
          CROSS JOIN LATERAL (
            SELECT public.calcular_cobertura(f.vence_el, public.hoy_local(r2.fecha_ingreso),
                                             v2.checklist,
                                             f.origen,
                                             f.compra_confirmada_por IS NOT NULL,
                                             f.compra_desestimada_por IS NOT NULL)
                   AS nueva) c
         WHERE r2.equipo_id = p_equipo_id
           AND r2.estado NOT IN ('ENTREGADO', 'ANULADO')
      ) c_resultado
     WHERE r.id = c_resultado.orden;
END;
$$;

REVOKE ALL ON FUNCTION public.confirmar_compra(uuid, text, text, date, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.confirmar_compra(uuid, text, text, date, integer) TO authenticated;

-- ---------------------------------------------------------------------
--  NOTA actualizar_cobertura_orden: su cuerpo de la 0013 NO cambia — no
--  llama a calcular_cobertura, solo copia `revisiones.resultado` a
--  `ordenes_servicio.cobertura` (y el motivo si el resultado es
--  ANULADA_POR_USO). La precedencia nueva entra por los datos que
--  fijar_resultado_revision ya pasa.
-- ---------------------------------------------------------------------

-- =================== 20261030000015_orden_atencion.sql ===================
-- =====================================================================
--  20261030000015_orden_atencion.sql
--  TIPO DE ATENCIÓN, motivo de rechazo y bitácora de eventos (spec §4.3
--  y §4.6; tareas 5–11 de la fase 2a): la maquinaria con la que el
--  detalle de la orden muestra la insignia (GARANTIA/PAGO/PENDIENTE),
--  guarda y PRESERVA el motivo del rechazo, y anota acciones que no
--  cambian el estado en `historial_ordenes` (evento 'BITACORA').
-- =====================================================================

-- ---------------------------------------------------------------------
--  1. ORDENES: TIPO_DE_ATENCIÓN generada + MOTIVO_RECHAZO (spec §4.3)
-- ---------------------------------------------------------------------
-- GENERADA STORED sobre la cobertura: la base la recalcula sola cada vez
-- que cambie `cobertura` (por el trigger de revisiones, la RPC de
-- confirmación/desestimación o cualquier UPDATE). La fila EN_GARANTIA →
-- GARANTIA; POR_DETERMINAR → PENDIENTE; el resto (FUERA_DE_GARANTIA,
-- ANULADA_POR_USO y todo lo que venga) → PAGO.
--
-- No admite UPDATE/INSERT (GENERATED ALWAYS): nadie la reenvía desde el
-- cliente; la emite SIEMPRE la base. Los INSERTs no la envían.
ALTER TABLE public.ordenes_servicio
    ADD COLUMN tipo_atencion text GENERATED ALWAYS AS (
        CASE cobertura
            WHEN 'EN_GARANTIA'     THEN 'GARANTIA'
            WHEN 'POR_DETERMINAR'  THEN 'PENDIENTE'
            ELSE 'PAGO'
        END) STORED;

-- El RECHAZADO (estado que añade la 0016) exige motivo con sustancia:
-- al menos 10 caracteres tras recortar espacios. Con cualquier otro
-- estado el motivo es libre (se escribe al rechazar y PERSISTE después).
ALTER TABLE public.ordenes_servicio
    ADD COLUMN motivo_rechazo text,
    ADD CONSTRAINT ck_rechazo_motivado CHECK (
        estado <> 'RECHAZADO'
        OR (motivo_rechazo IS NOT NULL AND length(btrim(motivo_rechazo)) >= 10));

-- Persistencia del motivo (spec §5.2): una vez escrito, el rechazo queda
-- justificado para siempre — el ENTREGADO posterior no lo borra ni lo
-- reescribe. BEFORE UPDATE de toda la fila: si OLD tiene motivo y NEW lo
-- pone NULL o distinto, la sentencia entera se cae con cód. 23F01.
CREATE FUNCTION public.motivo_rechazo_persiste()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
    IF OLD.motivo_rechazo IS NOT NULL
       AND NEW.motivo_rechazo IS DISTINCT FROM OLD.motivo_rechazo THEN
        RAISE EXCEPTION 'El motivo del rechazo no se puede alterar'
            USING ERRCODE = '23F01';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_motivo_rechazo_persiste
    BEFORE UPDATE ON public.ordenes_servicio
    FOR EACH ROW EXECUTE FUNCTION public.motivo_rechazo_persiste();

-- ---------------------------------------------------------------------
--  2. HISTORIAL: la columna EVENTO y su guardia combinada
-- ---------------------------------------------------------------------
-- El historial ya registraba cambios de estado. Ahora también anota
-- acciones SIN cambio de estado (asignación de técnico, presupuesto,
-- cobertura cambiada en reparación, costo limpiado por confirmación):
-- evento 'ESTADO' (el default, todo el flujo viejo) o 'BITACORA', cuya
-- fila lleva estado_anterior NULL y estado_nuevo IGUAL al estado actual
-- de la orden (no cambia nada, solo anota).
ALTER TABLE public.historial_ordenes
    ADD COLUMN evento text NOT NULL DEFAULT 'ESTADO'
        CONSTRAINT ck_historial_evento_tipo
        CHECK (evento IN ('ESTADO', 'BITACORA')),

    -- Una anotación sin texto no cuenta: la fila BITACORA lleva comentario.
    ADD CONSTRAINT ck_historial_bitacora_con_comentario
        CHECK (evento <> 'BITACORA' OR comentario IS NOT NULL);

-- Lector del estado ACTUAL de la orden, para la guardia combinada. CHECK
-- no admite subconsultas (limitación de Postgres), así que la igualdad
-- `estado_nuevo = estado de la orden` pasa por esta función auxiliar de
-- sola lectura. El planificador la evalúa solo en la rama BITACORA (el
-- AND con evento='BITACORA' cortocircuita); las filas 'ESTADO' viejas y
-- nuevas no se tocan. Si la orden no existiera (no ocurre: sin DELETE),
-- devolvería NULL y el CHECK la dejaría pasar.
CREATE FUNCTION public.estado_de_orden(p_orden_id uuid)
RETURNS text
LANGUAGE sql STABLE
SET search_path = public, pg_temp
AS $$
    SELECT estado FROM public.ordenes_servicio WHERE id = p_orden_id
$$;

-- El CHECK viejo de la tabla (sin nombre: `historial_registros_estado_…`)
-- exigía estado_anterior <> estado_nuevo y LO IMPEDÍA TODO: una fila
-- BITACORA es estado_anterior NULL con estado_nuevo IGUAL al actual. Se
-- sustituye por la guardia combinada del evento.
DO $$
DECLARE c_viejo text;
BEGIN
    SELECT conname INTO c_viejo
      FROM pg_constraint
     WHERE conrelid = 'public.historial_ordenes'::regclass
       AND contype = 'c'
       AND pg_get_constraintdef(oid) LIKE '%IS DISTINCT FROM%';
    IF c_viejo IS NULL THEN
        RAISE EXCEPTION 'No se encontró el CHECK viejo de historial_ordenes';
    END IF;
    EXECUTE format('ALTER TABLE public.historial_ordenes
                    DROP CONSTRAINT %I', c_viejo);
END $$;

ALTER TABLE public.historial_ordenes
    ADD CONSTRAINT ck_historial_evento CHECK (
        (evento = 'BITACORA'
            AND estado_anterior IS NULL
            AND estado_nuevo = public.estado_de_orden(orden_id))
     OR (evento = 'ESTADO'
            AND estado_anterior IS DISTINCT FROM estado_nuevo));

-- ---------------------------------------------------------------------
--  3. REGISTRAR_EVENTO_ORDEN — la bitácora automática (spec §7)
-- ---------------------------------------------------------------------
-- AFTER UPDATE de las tres columnas que los RPCs (SECURITY DEFINER,
-- tareas 10–11) anotan sin cambiar el estado: si el valor cambió, la
-- fila BITACORA entra AHÍ con modificado_por = auth.uid(). El RPC no
-- necesita GRANT INSERT sobre el historial: el trigger corre bajo la
-- identidad del DEFINER (dueño de las tablas). SECURITY INVOKER a
-- propósito: si el actor no puede escribir, el trigger tampoco.
CREATE FUNCTION public.registrar_evento_orden()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
    v_comentario text;
BEGIN
    IF NEW.cobertura IS DISTINCT FROM OLD.cobertura THEN
        v_comentario := 'La cobertura cambió a ' || NEW.cobertura::text
                      || ' con la orden en ' || NEW.estado;
    ELSIF NEW.costo_reparacion IS DISTINCT FROM OLD.costo_reparacion THEN
        v_comentario := 'Presupuesto: ' || NEW.costo_reparacion::text;
    ELSIF NEW.tecnico_asignado_id IS DISTINCT FROM OLD.tecnico_asignado_id THEN
        IF NEW.tecnico_asignado_id IS NULL THEN
            v_comentario := 'Técnico desasignado';
        ELSE
            v_comentario := 'Técnico asignado: ' || (
                SELECT p.full_name FROM public.profiles p
                 WHERE p.id = NEW.tecnico_asignado_id);
        END IF;
    END IF;

    IF v_comentario IS NOT NULL THEN
        INSERT INTO public.historial_ordenes
            (orden_id, estado_anterior, estado_nuevo, evento, modificado_por, comentario)
        VALUES (NEW.id, NULL, NEW.estado, 'BITACORA', auth.uid(), v_comentario);
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_registrar_evento_orden
    AFTER UPDATE OF cobertura, costo_reparacion, tecnico_asignado_id
    ON public.ordenes_servicio
    FOR EACH ROW EXECUTE FUNCTION public.registrar_evento_orden();

-- =================== 20261030000016_rechazado_transiciones.sql ===================
-- =====================================================================
--  20261030000016_rechazado_transiciones.sql
--  Estado RECHAZADO y cierre de roles de la máquina de transiciones
--  (Tarea 6 de la fase 2a; spec §4.6, §5.2 y §7).
--
--  RECHAZADO es la DECISIÓN DEL TALLER de no reparar el equipo: la
--  exige un motivo con sustancia (`ck_rechazo_motivado`, puesto por la
--  0015) y su única salida es ENTREGADO — no es terminal porque el
--  equipo igual se le devuelve al cliente. Con la migración también se
--  cierra la puerta de las transiciones "cualquier rol" (roles_permitidos
--  NULL): cada una queda con su lista exacta de roles, y RECEPCION pasa a
--  poder solo lo suyo (entregar, y recepcionar la decisión del cliente).
-- =====================================================================

-- ---------------------------------------------------------------------
--  1. EL ESTADO NUEVO (orden 85: entra entre RECHAZADO_POR_CLIENTE (80)
--     y ENTREGADO (90) para leerse junto a la otra salida sin entrega)
-- ---------------------------------------------------------------------
INSERT INTO public.estados_garantia (codigo, nombre, descripcion, orden, es_final)
VALUES ('RECHAZADO', 'Rechazado',
        'El taller decide no reparar el equipo; se devuelve con el motivo registrado',
        85, FALSE);

-- ---------------------------------------------------------------------
--  2. LAS CUATRO TRANSICIONES NUEVAS
--  Las tres entradas a RECHAZADO son decisión del taller (ADMIN o
--  JEFE_SERVICIO; el técnico propone, no decide). La salida única a
--  ENTREGADO la ejecuta el mismo trío que entrega REPARADO e
--  IRREPARABLE (recepciona la RECEPCION).
-- ---------------------------------------------------------------------
INSERT INTO public.transiciones_estado (desde, hasta, roles_permitidos) VALUES
    ('RECIBIDO',       'RECHAZADO', ARRAY['ADMIN', 'JEFE_SERVICIO']::public.app_role[]),
    ('EN_DIAGNOSTICO', 'RECHAZADO', ARRAY['ADMIN', 'JEFE_SERVICIO']::public.app_role[]),
    ('PRESUPUESTADO',  'RECHAZADO', ARRAY['ADMIN', 'JEFE_SERVICIO']::public.app_role[]),
    ('RECHAZADO',      'ENTREGADO', ARRAY['ADMIN', 'JEFE_SERVICIO', 'RECEPCION']::public.app_role[]);

-- ---------------------------------------------------------------------
--  3. CIERRE DE ROLES: ninguna transición queda ya con roles_permitidos
--     NULL ("cualquier rol con UPDATE sobre la fila"). Un UPDATE global
--     por el patrón del NULL no distingue la excepción, así que las 14
--     transiciones van UNA POR UNA con su lista exacta:
--       * Las operativas del taller: ADMIN + JEFE_SERVICIO + TECNICO.
--       * Las cuatro que recepcionan la decisión del cliente (aceptar
--         el presupuesto y partir a reparar, o rechazarlo) también
--         llevan RECEPCION.
-- ---------------------------------------------------------------------
UPDATE public.transiciones_estado
   SET roles_permitidos = ARRAY['ADMIN', 'JEFE_SERVICIO', 'TECNICO']::public.app_role[]
 WHERE desde = 'RECIBIDO'        AND hasta = 'EN_DIAGNOSTICO';

UPDATE public.transiciones_estado
   SET roles_permitidos = ARRAY['ADMIN', 'JEFE_SERVICIO', 'TECNICO']::public.app_role[]
 WHERE desde = 'EN_DIAGNOSTICO'  AND hasta = 'PRESUPUESTADO';

UPDATE public.transiciones_estado
   SET roles_permitidos = ARRAY['ADMIN', 'JEFE_SERVICIO', 'TECNICO']::public.app_role[]
 WHERE desde = 'EN_DIAGNOSTICO'  AND hasta = 'EN_REPARACION';

UPDATE public.transiciones_estado
   SET roles_permitidos = ARRAY['ADMIN', 'JEFE_SERVICIO', 'TECNICO']::public.app_role[]
 WHERE desde = 'EN_DIAGNOSTICO'  AND hasta = 'IRREPARABLE';

UPDATE public.transiciones_estado
   SET roles_permitidos = ARRAY['ADMIN', 'JEFE_SERVICIO', 'TECNICO']::public.app_role[]
 WHERE desde = 'PRESUPUESTADO'   AND hasta = 'EN_ESPERA_REPUESTO';

-- Excepción 1: la decisión del cliente la recepciona RECEPCION.
UPDATE public.transiciones_estado
   SET roles_permitidos = ARRAY['ADMIN', 'JEFE_SERVICIO', 'TECNICO', 'RECEPCION']::public.app_role[]
 WHERE desde = 'PRESUPUESTADO'   AND hasta = 'EN_REPARACION';

-- Excepción 2: idem, la negativa del cliente.
UPDATE public.transiciones_estado
   SET roles_permitidos = ARRAY['ADMIN', 'JEFE_SERVICIO', 'TECNICO', 'RECEPCION']::public.app_role[]
 WHERE desde = 'PRESUPUESTADO'   AND hasta = 'RECHAZADO_POR_CLIENTE';

UPDATE public.transiciones_estado
   SET roles_permitidos = ARRAY['ADMIN', 'JEFE_SERVICIO', 'TECNICO']::public.app_role[]
 WHERE desde = 'PRESUPUESTADO'   AND hasta = 'IRREPARABLE';

-- Excepción 3: el repuesto llegó y el cliente ya aprobó (misma decisión
-- del presupuesto, tomada con la orden esperando la pieza).
UPDATE public.transiciones_estado
   SET roles_permitidos = ARRAY['ADMIN', 'JEFE_SERVICIO', 'TECNICO', 'RECEPCION']::public.app_role[]
 WHERE desde = 'EN_ESPERA_REPUESTO' AND hasta = 'EN_REPARACION';

UPDATE public.transiciones_estado
   SET roles_permitidos = ARRAY['ADMIN', 'JEFE_SERVICIO', 'TECNICO']::public.app_role[]
 WHERE desde = 'EN_ESPERA_REPUESTO' AND hasta = 'IRREPARABLE';

-- Excepción 4: idem, el cliente desiste con la orden en espera.
UPDATE public.transiciones_estado
   SET roles_permitidos = ARRAY['ADMIN', 'JEFE_SERVICIO', 'TECNICO', 'RECEPCION']::public.app_role[]
 WHERE desde = 'EN_ESPERA_REPUESTO' AND hasta = 'RECHAZADO_POR_CLIENTE';

UPDATE public.transiciones_estado
   SET roles_permitidos = ARRAY['ADMIN', 'JEFE_SERVICIO', 'TECNICO']::public.app_role[]
 WHERE desde = 'EN_REPARACION'   AND hasta = 'REPARADO';

UPDATE public.transiciones_estado
   SET roles_permitidos = ARRAY['ADMIN', 'JEFE_SERVICIO', 'TECNICO']::public.app_role[]
 WHERE desde = 'EN_REPARACION'   AND hasta = 'IRREPARABLE';

UPDATE public.transiciones_estado
   SET roles_permitidos = ARRAY['ADMIN', 'JEFE_SERVICIO', 'TECNICO']::public.app_role[]
 WHERE desde = 'EN_REPARACION'   AND hasta = 'EN_ESPERA_REPUESTO';

-- Guardia del cierre: si alguien añade una transición en NULL y este
-- archivo vuelve a correr, o se escapó una del listado de arriba, la
-- migración muere en lugar de dejar la puerta abierta en silencio.
DO $$
DECLARE c_null integer;
BEGIN
    SELECT count(*) INTO c_null
      FROM public.transiciones_estado WHERE roles_permitidos IS NULL;
    IF c_null <> 0 THEN
        RAISE EXCEPTION 'Quedan % transiciones con roles_permitidos NULL tras el cierre', c_null
            USING ERRCODE = 'P0001';
    END IF;
END $$;

-- ---------------------------------------------------------------------
--  4. RLS: la policy de recepción por estado
--  RECEPCION solo cierra la entrega (y ahora también entrega la decisión
--  de RECHAZADO, que es una salida a ENTREGADO como las otras dos). La
--  decisión del cliente sobre PRESUPUESTADO/EN_ESPERA_REPUESTO sigue sin
--  pasar por aquí: la recepciona RECEPCION por el permiso de la
--  TRANSICIÓN, no por esta policy (ver R7 en 22_rechazado_transiciones).
-- ---------------------------------------------------------------------
DROP POLICY reg_update_recepcion ON public.ordenes_servicio;

CREATE POLICY reg_update_recepcion ON public.ordenes_servicio
    FOR UPDATE TO authenticated
    USING (public.tiene_rol('RECEPCION') AND estado IN
           ('REPARADO', 'IRREPARABLE', 'RECHAZADO_POR_CLIENTE', 'RECHAZADO'))
    WITH CHECK (public.tiene_rol('RECEPCION'));

-- =================== 20261030000017_reglas_avance.sql ===================
-- =====================================================================
--  20261030000017_reglas_avance.sql
--  REGLAS DE AVANCE impuestas por la BASE (Tarea 7 de la fase 2a; spec
--  §4.5 y §4.4): la foto y el documento condicionan pasar a diagnóstico,
--  el presupuesto condiciona PRESUPUESTADO y el pago pasa por
--  presupuesto antes de reparar. Además, la confirmación posterior que
--  vuelve la cobertura EN_GARANTIA con un presupuesto cargado limpia el
--  costo (no se cobra lo que la garantía cubre) y lo deja anotado en la
--  bitácora por registrar_evento_orden (0015-fix).
--
--  «Las impone la base, no la interfaz»: cualquier UPDATE de estado —
--  por RPC cambiar_estado, por RLS con GRANT por columna o por un
--  service_role — tropieza con las mismas reglas.
-- =====================================================================

-- ---------------------------------------------------------------------
--  1. VALIDAR_AVANCE_ORDEN (§4.5 a, b y c)
-- ---------------------------------------------------------------------
-- BEFORE UPDATE OF estado en ordenes_servicio, DISPARADO DESPUÉS de
-- validar_transicion_estado. El orden de disparo de los triggers del
-- mismo evento en Postgres es ALFABÉTICO por nombre; el trigger de la
-- 0013 se llama `trg_validar_transicion_orden`, y `trg_verificar_avance_orden`
-- se ordena después (t-r-g-_-v-a-l… < t-r-g-_-v-e-r…: en la 6ª letra,
-- 'a' < 'e'). Así, transición+roles (0013/0002)
-- tienen la primera palabra: una recepción sin permiso en RECIBIDO →
-- EN_DIAGNOSTICO recibe su 42501 y no la regla de datos; y las reglas de
-- avance solo se preguntan cuando la transición ya es válida.
--
-- NOTA sobre tipo_atencion (§4.3): la columna generada de la 0015 NO es
-- visible en un trigger BEFORE de Postgres 17 — NEW.tipo_atencion llega
-- NULL (lo computed va DESPUÉS de los triggers BEFORE). La equivalencia
-- exacta se evalúa con el MISMO CASE de cobertura de la 0015:
--   EN_GARANTIA → GARANTIA · POR_DETERMINAR → PENDIENTE · resto → PAGO.
-- (OLD.tipo_atencion sí se lee, pero regiría por el valor viejo.)
CREATE FUNCTION public.validar_avance_orden()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
    v_taller_sin_confirmar boolean;
BEGIN
    -- Sin cambio de estado no hay avance que validar (idéntica guarda a
    -- la de validar_transicion_estado: los UPDATE de costo/cobertura/
    -- técnico ni se miran aquí).
    IF NEW.estado IS NOT DISTINCT FROM OLD.estado THEN
        RETURN NEW;
    END IF;

    -- (a) → EN_DIAGNOSTICO (spec §4.5): la auditoría de recepción debe
    -- tener al menos una foto; si el equipo es de origen TALLER y la
    -- compra no está confirmada, además un documento (la factura
    -- presentada). Mensajes accionables: cod. 23514.
    IF NEW.estado = 'EN_DIAGNOSTICO' THEN
        IF NOT EXISTS (
            SELECT 1 FROM public.adjuntos a
             WHERE a.orden_id = NEW.id
               AND a.tipo = 'FOTO') THEN
            RAISE EXCEPTION 'El avance exige una foto de la auditoría de recepción'
                USING ERRCODE = '23514';
        END IF;

        SELECT e.origen = 'TALLER' AND e.compra_confirmada_por IS NULL
          INTO v_taller_sin_confirmar
          FROM public.equipos e
         WHERE e.id = NEW.equipo_id;

        IF v_taller_sin_confirmar THEN
            IF NOT EXISTS (
                SELECT 1 FROM public.adjuntos a
                 WHERE a.orden_id = NEW.id
                   AND a.tipo = 'DOCUMENTO') THEN
                RAISE EXCEPTION
                    'Un equipo de taller sin compra confirmada exige subir el documento presentado'
                    USING ERRCODE = '23514';
            END IF;
        END IF;
    END IF;

    -- (b) → PRESUPUESTADO (spec §4.5): requiere el monto cargado. La
    -- cobertura POR_DETERMINAR (PENDIENTE) o ANULADA/FUERA (PAGO) lo
    -- admite; con EN_GARANTIA es el CHECK ck_costo_solo_si_no_cubierta
    -- quien niega el cargo (0006).
    IF NEW.estado = 'PRESUPUESTADO' AND NEW.costo_reparacion IS NULL THEN
        RAISE EXCEPTION 'Para presupuestar hay que registrar el monto'
            USING ERRCODE = '23514';
    END IF;

    -- (c) EN_DIAGNOSTICO → EN_REPARACION (spec §4.5): solo con
    -- GARANTIA. «En PAGO el camino obligatorio pasa por PRESUPUESTADO;
    -- en PENDIENTE no se avanza hasta resolver la cobertura.» El salto
    -- directo desde EN_DIAGNOSTICO queda cerrado para ambos; desde
    -- PRESUPUESTADO / EN_ESPERA_REPUESTO no se revisa (ya pasó por el
    -- presupuesto: el cliente aprobó el monto).
    IF OLD.estado = 'EN_DIAGNOSTICO' AND NEW.estado = 'EN_REPARACION'
       AND (CASE NEW.cobertura
                WHEN 'EN_GARANTIA'    THEN 'GARANTIA'
                WHEN 'POR_DETERMINAR' THEN 'PENDIENTE'
                ELSE 'PAGO'
            END) <> 'GARANTIA' THEN
        RAISE EXCEPTION 'Un servicio pago pasa por PRESUPUESTADO antes de reparar'
            USING ERRCODE = '23514';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_verificar_avance_orden
    BEFORE UPDATE OF estado ON public.ordenes_servicio
    FOR EACH ROW EXECUTE FUNCTION public.validar_avance_orden();

-- ---------------------------------------------------------------------
--  2. LIMPIAR_COSTO_EN_GARANTIA (§4.4)
-- ---------------------------------------------------------------------
-- «Si una confirmación posterior vuelve la cobertura EN_GARANTIA con un
-- presupuesto cargado, la base limpia costo_reparacion y lo anota en el
-- comentario de la bitácora.» BEFORE UPDATE: el nulo se aplica a NEW
-- ANTES de que se evalúen los CHECK (el CHECK ck_costo_solo_si_no_cubierta
-- de la 0006 deja de reventar y pasa a limpiar) y antes de que el trigger
-- AFTER registrar_evento_orden (0015-fix, SECURITY DEFINER) anote el
-- evento: la rama de cobertura es la primera de su ELSIF, así que la
-- BITACORA queda con «La cobertura cambió a EN_GARANTIA …».
CREATE FUNCTION public.limpiar_costo_en_garantia()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
    IF NEW.cobertura = 'EN_GARANTIA' AND OLD.costo_reparacion IS NOT NULL THEN
        NEW.costo_reparacion := NULL;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_costo_con_cobertura
    BEFORE UPDATE ON public.ordenes_servicio
    FOR EACH ROW EXECUTE FUNCTION public.limpiar_costo_en_garantia();

-- ---------------------------------------------------------------------
--  3. COMENTARIO (cada regla citando el spec)
-- ---------------------------------------------------------------------
COMMENT ON FUNCTION public.validar_avance_orden() IS
'Reglas de avance del spec §4.5, impuestas por la base (migración 0017), '
'trigger trg_verificar_avance_orden (BEFORE UPDATE OF estado, después de '
'validar_transicion_estado por orden alfabético): '
'(a) → EN_DIAGNOSTICO exige ≥1 adjunto FOTO de la orden, y ≥1 DOCUMENTO '
'si el equipo es origen TALLER sin compra confirmada («El avance exige una '
'foto de la auditoría de recepción» / «Un equipo de taller sin compra '
'confirmada exige subir el documento presentado»); '
'(b) → PRESUPUESTADO exige costo_reparacion cargado («Para presupuestar '
'hay que registrar el monto»); '
'(c) EN_DIAGNOSTICO → EN_REPARACION solo con tipo_atencion GARANTIA: en '
'PAGO el camino obligatorio pasa por PRESUPUESTADO y PENDIENTE no avanza '
'a reparar hasta resolver la cobertura («Un servicio pago pasa por '
'PRESUPUESTADO antes de reparar»). Errores 23514.';

COMMENT ON FUNCTION public.limpiar_costo_en_garantia() IS
'Spec §4.4: si una confirmación posterior vuelve la cobertura EN_GARANTIA '
'con un presupuesto cargado (migración 0017, trigger '
'trg_costo_con_cobertura), la base limpia costo_reparacion a NULL y el '
'evento queda anotado en la bitácora por registrar_evento_orden (0015).';

COMMENT ON TRIGGER trg_verificar_avance_orden ON public.ordenes_servicio IS
'Verificar_avance_orden: foto y documento para EN_DIAGNOSTICO, monto para '
'PRESUPUESTADO y GARANTIA para EN_DIAGNOSTICO→EN_REPARACION (spec §4.5).';

-- =================== 20261030000018_rpc_garantia.sql ===================
-- =====================================================================
--  20261030000018_rpc_garantia.sql
--  Fase 2a, tarea 8 (spec §4.1 y §6):
--    · registrar_garantia: crea el equipo (la garantía) sin orden.
--    · buscar_equipo: ahora por serial, cédula/RIF, factura u orden.
--    · v_garantias: una fila por garantía, para el tablero de garantías.
--  La vigencia sale de calcular_cobertura (única fuente de verdad), sin
--  checklist: aquí solo importan la fecha, el origen y la compra.
-- =====================================================================

-- ---------------------------------------------------------------------
--  REGISTRAR_GARANTIA
--  Plazo de 7 o 15 días para todos; cualquier otro (1–365) solo lo fija
--  ADMIN o JEFE_SERVICIO. Si el equipo ya existe (mismo producto y serial
--  normalizado) lo devuelve sin tocarlo.
-- ---------------------------------------------------------------------
CREATE FUNCTION public.registrar_garantia(
    p_cliente_id      uuid,
    p_producto_id     uuid,
    p_serial          text,
    p_tipo_soporte    text DEFAULT NULL,
    p_numero_soporte  text DEFAULT NULL,
    p_fecha_emision   date DEFAULT NULL,
    p_plazo_dias      integer DEFAULT NULL,
    p_origen          text DEFAULT 'VENTA')
RETURNS TABLE (equipo_id uuid, vence_el date, equipo_nuevo boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_serial text := btrim(coalesce(p_serial, ''));
    v_equipo uuid;
BEGIN
    IF NOT public.tiene_rol('ADMIN', 'JEFE_SERVICIO', 'TECNICO', 'RECEPCION') THEN
        RAISE EXCEPTION 'Su rol no puede registrar garantías' USING ERRCODE = '42501';
    END IF;
    IF p_origen IS NULL OR p_origen NOT IN ('VENTA', 'TALLER') THEN
        RAISE EXCEPTION 'El origen debe ser VENTA o TALLER' USING ERRCODE = '22P02';
    END IF;
    IF length(v_serial) < 3 OR length(v_serial) > 60 THEN
        RAISE EXCEPTION 'El serial es obligatorio (3 a 60 caracteres)' USING ERRCODE = '22P02';
    END IF;
    IF p_plazo_dias IS NOT NULL AND p_plazo_dias NOT IN (7, 15)
       AND NOT public.tiene_rol('ADMIN', 'JEFE_SERVICIO') THEN
        RAISE EXCEPTION 'Los plazos distintos de 7 o 15 días solo los fija el jefe'
            USING ERRCODE = '42501';
    END IF;

    SELECT e.id INTO v_equipo
      FROM public.equipos e
     WHERE e.producto_id = p_producto_id
       AND e.serie_normalizada = public.normalizar_serie(v_serial);

    equipo_nuevo := v_equipo IS NULL;
    IF equipo_nuevo THEN
        INSERT INTO public.equipos (numero_serie, producto_id, cliente_id,
                                    tipo_soporte, numero_soporte, fecha_emision,
                                    plazo_dias, origen, registrado_por)
        VALUES (v_serial, p_producto_id, p_cliente_id,
                nullif(btrim(coalesce(p_tipo_soporte, '')), ''),
                nullif(btrim(coalesce(p_numero_soporte, '')), ''),
                p_fecha_emision, p_plazo_dias, p_origen, auth.uid())
        ON CONFLICT (producto_id, serie_normalizada) DO NOTHING
        RETURNING id INTO v_equipo;
        IF v_equipo IS NULL THEN          -- otro envío ganó la carrera
            equipo_nuevo := false;
            SELECT e.id INTO v_equipo FROM public.equipos e
             WHERE e.producto_id = p_producto_id
               AND e.serie_normalizada = public.normalizar_serie(v_serial);
        END IF;
    END IF;

    equipo_id := v_equipo;
    SELECT e.vence_el INTO vence_el FROM public.equipos e WHERE e.id = v_equipo;
    RETURN NEXT;
END;
$$;

REVOKE ALL ON FUNCTION public.registrar_garantia(uuid, uuid, text, text, text, date, integer, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.registrar_garantia(uuid, uuid, text, text, text, date, integer, text)
  TO authenticated;

-- ---------------------------------------------------------------------
--  V_GARANTIAS — una fila por equipo (tablero de garantías)
--  security_invoker: la RLS de `equipos` decide quién la ve.
-- ---------------------------------------------------------------------
CREATE VIEW public.v_garantias
WITH (security_invoker = true) AS
SELECT e.id                               AS equipo_id,
       e.numero_serie,
       e.producto_id,
       (m.nombre || ' ' || pr.modelo)     AS producto,
       e.cliente_id                       AS titular_id,
       c.nombre                           AS titular,
       c.documento,
       e.numero_soporte,
       e.fecha_emision,
       e.plazo_dias,
       e.vence_el,
       (e.vence_el - public.hoy_local())  AS dias_restantes,
       e.origen,
       public.calcular_cobertura(
           e.vence_el, public.hoy_local(), NULL, e.origen,
           e.compra_confirmada_por IS NOT NULL,
           e.compra_desestimada_por IS NOT NULL)  AS vigencia,
       CASE WHEN e.compra_desestimada_por IS NOT NULL THEN 'DESESTIMADA'
            WHEN e.compra_confirmada_por IS NOT NULL OR e.origen = 'VENTA' THEN 'CONFIRMADA'
            ELSE 'PENDIENTE' END          AS estado_compra
  FROM public.equipos e
  JOIN public.productos pr ON pr.id = e.producto_id
  JOIN public.marcas m     ON m.id  = pr.marca_id
  JOIN public.clientes c   ON c.id  = e.cliente_id;

REVOKE ALL ON public.v_garantias FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.v_garantias TO authenticated;

-- ---------------------------------------------------------------------
--  BUSCAR_EQUIPO — serial, cédula/RIF, factura u orden (se unen con OR)
--  SECURITY INVOKER a propósito: la RLS de equipos, clientes y órdenes
--  (solo roles internos) decide qué se ve.
-- ---------------------------------------------------------------------
DROP FUNCTION public.buscar_equipo(text);

CREATE FUNCTION public.buscar_equipo(
    p_serial    text DEFAULT NULL,
    p_documento text DEFAULT NULL,
    p_factura   text DEFAULT NULL,
    p_orden     text DEFAULT NULL)
RETURNS TABLE (
    equipo_id           uuid,
    producto_id         uuid,
    producto            text,
    numero_serie        text,
    titular_id          uuid,
    titular             text,
    documento           text,
    email               text,
    telefono            text,
    numero_soporte      text,
    fecha_emision       date,
    plazo_dias          smallint,
    vence_el            date,
    dias_restantes      integer,
    origen              text,
    vigencia            public.cobertura_garantia,
    estado_compra       text,
    motivo_desestimacion text,
    ordenes             jsonb
)
LANGUAGE sql
STABLE
SET search_path = public, pg_temp
AS $$
    WITH q AS (
        SELECT nullif(btrim(coalesce(p_serial, '')), '')    AS serial,
               nullif(btrim(coalesce(p_documento, '')), '') AS documento,
               nullif(upper(btrim(coalesce(p_factura, ''))), '') AS factura,
               nullif(upper(btrim(coalesce(p_orden, ''))), '')   AS orden
    )
    SELECT e.id, e.producto_id,
           (m.nombre || ' ' || pr.modelo)::text,
           e.numero_serie,
           e.cliente_id, c.nombre, c.documento, c.email, c.telefono,
           e.numero_soporte, e.fecha_emision, e.plazo_dias, e.vence_el,
           (e.vence_el - public.hoy_local())::int,
           e.origen,
           public.calcular_cobertura(
               e.vence_el, public.hoy_local(), NULL, e.origen,
               e.compra_confirmada_por IS NOT NULL,
               e.compra_desestimada_por IS NOT NULL),
           CASE WHEN e.compra_desestimada_por IS NOT NULL THEN 'DESESTIMADA'
                WHEN e.compra_confirmada_por IS NOT NULL OR e.origen = 'VENTA' THEN 'CONFIRMADA'
                ELSE 'PENDIENTE' END,
           e.compra_desestimada_motivo,
           COALESCE((
               SELECT jsonb_agg(jsonb_build_object(
                          'numero_orden',  o.numero_orden,
                          'estado',        o.estado,
                          'estado_nombre', s.nombre,
                          'cobertura',     o.cobertura::text,
                          'tipo_atencion', o.tipo_atencion,
                          'fecha_ingreso', o.fecha_ingreso::text)
                      ORDER BY o.fecha_ingreso)
                 FROM public.ordenes_servicio o
                 JOIN public.estados_garantia s ON s.codigo = o.estado
                WHERE o.equipo_id = e.id), '[]'::jsonb)
      FROM q,
           public.equipos e
      JOIN public.productos pr ON pr.id = e.producto_id
      JOIN public.marcas m     ON m.id  = pr.marca_id
      JOIN public.clientes c   ON c.id  = e.cliente_id
     WHERE ((q.serial IS NOT NULL AND e.serie_normalizada = public.normalizar_serie(q.serial))
         OR (q.documento IS NOT NULL AND c.documento = q.documento)
         OR (q.factura IS NOT NULL AND upper(btrim(e.numero_soporte)) = q.factura)
         OR (q.orden IS NOT NULL AND EXISTS (
                SELECT 1 FROM public.ordenes_servicio o
                 WHERE o.equipo_id = e.id AND o.numero_orden = q.orden)))
     ORDER BY e.created_at DESC;
$$;

REVOKE ALL ON FUNCTION public.buscar_equipo(text, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.buscar_equipo(text, text, text, text) TO authenticated;


-- =================== 20261030000019_abrir_orden.sql ===================
-- =====================================================================
--  20261030000019_abrir_orden.sql
--  Fase 2a, tarea 9 (spec §5.1 y §6): abrir_orden pasa a trabajar sobre
--  una garantía ya registrada (equipo), no a crearla.
--    · La garantía se crea con registrar_garantia (0018), que impone el
--      plazo de 7 o 15 días; la firma vieja de 14 parámetros creaba el
--      equipo con cualquier plazo y se retira.
--    · UNA transacción: orden + revisión de RECEPCION. La cobertura la
--      pone el trigger de las revisiones; tipo_atencion es generada.
--    · Idempotente por (creado_por, clave_envio), con el candado de la 0012.
--    · p_fecha_ingreso la manda SOLO el ADMIN (backoffice); a los demás
--      roles se les ignora y reciben now().
-- =====================================================================
DROP FUNCTION public.abrir_orden(
    text, uuid, uuid, text, text, text, text, date, integer, text,
    jsonb, text, timestamptz, uuid);

CREATE FUNCTION public.abrir_orden(
    p_equipo_id       uuid,
    p_falla           text,
    p_accesorios      text DEFAULT NULL,
    p_checklist       jsonb DEFAULT NULL,
    p_observaciones   text DEFAULT NULL,
    p_clave_envio     uuid DEFAULT NULL,
    p_fecha_ingreso   timestamptz DEFAULT NULL)
RETURNS TABLE (
    orden_id        uuid,
    numero_orden    text,
    consulta_token  text,   -- TEXTO PLANO, una sola vez (imprimir y olvidar)
    cobertura       public.cobertura_garantia,
    tipo_atencion   text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_rol    public.app_role := public.mi_rol();
    v_actor  uuid := auth.uid();
    v_falla  text := btrim(coalesce(p_falla, ''));
    v_token  text;
    v_orden  uuid;
BEGIN
    IF v_rol IS NULL OR NOT public.tiene_rol('ADMIN', 'JEFE_SERVICIO', 'TECNICO', 'RECEPCION') THEN
        RAISE EXCEPTION 'Su rol no puede abrir órdenes' USING ERRCODE = '42501';
    END IF;

    -- Idempotencia: el candado serializa dos envíos simultáneos con la misma
    -- clave; el segundo encuentra la orden del primero. El token en claro no
    -- se puede reconstruir (solo se guarda el hash): vuelve en NULL.
    IF p_clave_envio IS NOT NULL THEN
        PERFORM pg_advisory_xact_lock(hashtextextended(v_actor::text || p_clave_envio::text, 0));
        RETURN QUERY
        SELECT o.id, o.numero_orden, NULL::text, o.cobertura, o.tipo_atencion
          FROM public.ordenes_servicio o
         WHERE o.creado_por = v_actor AND o.clave_envio = p_clave_envio;
        IF FOUND THEN
            RETURN;
        END IF;
    END IF;

    IF length(v_falla) < 5 OR length(v_falla) > 2000 THEN
        RAISE EXCEPTION 'La falla reportada es obligatoria (5 a 2000 caracteres)'
            USING ERRCODE = '22P02';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.equipos e WHERE e.id = p_equipo_id) THEN
        RAISE EXCEPTION 'No existe el equipo indicado' USING ERRCODE = 'P0002';
    END IF;

    v_token := encode(extensions.gen_random_bytes(16), 'hex');

    INSERT INTO public.ordenes_servicio (equipo_id, falla_reportada, accesorios,
                                         cobertura, tecnico_asignado_id, creado_por,
                                         consulta_token_hash, fecha_ingreso, clave_envio)
    VALUES (p_equipo_id, v_falla,
            nullif(btrim(coalesce(p_accesorios, '')), ''),
            'POR_DETERMINAR',
            CASE WHEN v_rol = 'TECNICO' THEN v_actor END,
            v_actor,
            extensions.digest(v_token, 'sha256'),
            coalesce(CASE WHEN public.tiene_rol('ADMIN') THEN p_fecha_ingreso END, now()),
            p_clave_envio)
    RETURNING id INTO v_orden;

    -- La auditoría de recepción: la primera revisión. Su trigger fija la cobertura.
    INSERT INTO public.revisiones (orden_id, tipo, revisado_por, checklist, observaciones)
    VALUES (v_orden, 'RECEPCION', v_actor, p_checklist,
            nullif(btrim(coalesce(p_observaciones, '')), ''));

    RETURN QUERY
    SELECT o.id, o.numero_orden, v_token, o.cobertura, o.tipo_atencion
      FROM public.ordenes_servicio o
     WHERE o.id = v_orden;
END;
$$;

REVOKE ALL ON FUNCTION public.abrir_orden(uuid, text, text, jsonb, text, uuid, timestamptz)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.abrir_orden(uuid, text, text, jsonb, text, uuid, timestamptz)
  TO authenticated;


-- =================== 20261030000020_confirmar_desestimar.sql ===================
-- =====================================================================
--  20261030000020_confirmar_desestimar.sql
--  Fase 2a, tarea 10 (spec §4.1, §4.4 y §6):
--    · confirmar_compra RATIFICA también un equipo con soporte ya cargado
--      (la garantía TALLER trae la factura que presentó el cliente; el jefe
--      la contrasta con la venta real y la confirma o la corrige).
--    · desestimar_compra: la compra no es válida; las órdenes abiertas
--      pasan a FUERA_DE_GARANTIA (tipo PAGO). Nada se borra.
--  Ambas recalculan con el mismo helper. Si una orden vuelve a EN_GARANTIA
--  con presupuesto, el trigger de la 0017 limpia el costo y la 0015 lo anota.
-- =====================================================================

-- Recalcula la cobertura de las órdenes ABIERTAS del equipo con su última
-- revisión y los datos ACTUALES del equipo (origen, compra confirmada o
-- desestimada). Interna: sin GRANT, solo la llaman las RPC de abajo.
CREATE FUNCTION public.recalcular_cobertura_equipo(p_equipo_id uuid)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    UPDATE public.ordenes_servicio r
       SET cobertura = x.nueva,
           motivo_anulacion_cobertura =
               CASE WHEN x.nueva = 'ANULADA_POR_USO'
                    THEN public.motivo_anulacion(x.checklist) END
      FROM (
        SELECT o.id AS orden, v.checklist, c.nueva
          FROM public.ordenes_servicio o
          JOIN public.equipos f ON f.id = o.equipo_id
         CROSS JOIN LATERAL (
            SELECT vr.checklist FROM public.revisiones vr
             WHERE vr.orden_id = o.id
             ORDER BY vr.revisado_en DESC, vr.id DESC LIMIT 1) v
         CROSS JOIN LATERAL (
            SELECT public.calcular_cobertura(f.vence_el, public.hoy_local(o.fecha_ingreso),
                                             v.checklist, f.origen,
                                             f.compra_confirmada_por IS NOT NULL,
                                             f.compra_desestimada_por IS NOT NULL) AS nueva) c
         WHERE o.equipo_id = p_equipo_id
           AND o.estado NOT IN ('ENTREGADO', 'ANULADO')
      ) x
     WHERE r.id = x.orden;
$$;
REVOKE ALL ON FUNCTION public.recalcular_cobertura_equipo(uuid) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------
--  CONFIRMAR_COMPRA — solo ADMIN y JEFE_SERVICIO. Misma firma pública.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.confirmar_compra(
    p_equipo_id      uuid,
    p_tipo_soporte   text,
    p_numero_soporte text,
    p_fecha_emision  date,
    p_plazo_dias     integer)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_desestimada boolean;
BEGIN
    IF NOT public.tiene_rol('ADMIN', 'JEFE_SERVICIO') THEN
        RAISE EXCEPTION 'Solo ADMIN o JEFE_SERVICIO confirman la compra' USING ERRCODE = '42501';
    END IF;

    IF coalesce(p_tipo_soporte, '') NOT IN ('FACTURA', 'NOTA_ENTREGA')
       OR coalesce(btrim(p_numero_soporte), '') = ''
       OR p_fecha_emision IS NULL OR p_plazo_dias IS NULL THEN
        RAISE EXCEPTION 'Faltan datos del soporte: tipo, número, fecha de emisión y plazo'
            USING ERRCODE = '22P02';
    END IF;

    SELECT (compra_desestimada_por IS NOT NULL) INTO v_desestimada
      FROM public.equipos WHERE id = p_equipo_id;
    IF v_desestimada IS NULL THEN
        RAISE EXCEPTION 'Equipo inexistente' USING ERRCODE = 'P0002';
    END IF;
    IF v_desestimada THEN
        RAISE EXCEPTION 'La compra fue desestimada; no se puede confirmar'
            USING ERRCODE = '23514';
    END IF;

    UPDATE public.equipos
       SET tipo_soporte   = p_tipo_soporte,
           numero_soporte = btrim(p_numero_soporte),
           fecha_emision  = p_fecha_emision,
           plazo_dias     = p_plazo_dias,
           compra_confirmada_por = auth.uid(),
           compra_confirmada_en  = now()
     WHERE id = p_equipo_id;

    PERFORM public.recalcular_cobertura_equipo(p_equipo_id);
END;
$$;

-- ---------------------------------------------------------------------
--  DESESTIMAR_COMPRA — solo ADMIN y JEFE_SERVICIO; motivo de 10+ caracteres.
-- ---------------------------------------------------------------------
CREATE FUNCTION public.desestimar_compra(p_equipo_id uuid, p_motivo text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_motivo      text := btrim(coalesce(p_motivo, ''));
    v_confirmada  boolean;
    v_desestimada boolean;
BEGIN
    IF NOT public.tiene_rol('ADMIN', 'JEFE_SERVICIO') THEN
        RAISE EXCEPTION 'Solo ADMIN o JEFE_SERVICIO desestiman la compra' USING ERRCODE = '42501';
    END IF;
    IF length(v_motivo) < 10 THEN
        RAISE EXCEPTION 'El motivo es obligatorio (mínimo 10 caracteres)' USING ERRCODE = '22P02';
    END IF;

    SELECT (compra_confirmada_por IS NOT NULL), (compra_desestimada_por IS NOT NULL)
      INTO v_confirmada, v_desestimada
      FROM public.equipos WHERE id = p_equipo_id;
    IF v_confirmada IS NULL THEN
        RAISE EXCEPTION 'Equipo inexistente' USING ERRCODE = 'P0002';
    END IF;
    IF v_confirmada THEN
        RAISE EXCEPTION 'La compra ya está confirmada; no se puede desestimar'
            USING ERRCODE = '23514';
    END IF;
    IF v_desestimada THEN
        RAISE EXCEPTION 'La compra ya fue desestimada' USING ERRCODE = '23514';
    END IF;

    UPDATE public.equipos
       SET compra_desestimada_por = auth.uid(),
           compra_desestimada_en  = now(),
           compra_desestimada_motivo = v_motivo
     WHERE id = p_equipo_id;

    PERFORM public.recalcular_cobertura_equipo(p_equipo_id);
END;
$$;

REVOKE ALL ON FUNCTION public.desestimar_compra(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.desestimar_compra(uuid, text) TO authenticated;


-- =================== 20261030000021_maquina_rpc.sql ===================
-- =====================================================================
--  20261030000021_maquina_rpc.sql
--  Fase 2a, tarea 11 (spec §4.5, §6 y §7): la ÚNICA puerta para cambiar
--  el estado, asignar técnico y fijar el presupuesto son tres RPC.
--    · cambiar_estado: la matriz de roles y las reglas de avance las
--      imponen los triggers (0016 y 0017); la RPC añade quién puede tocar
--      la orden, el motivo del rechazo y el comentario de la bitácora.
--    · asignar_tecnico (ADMIN, JEFE) y registrar_presupuesto (solo en PAGO).
--    · UPDATE directo de estado y costo_reparacion cerrado para
--      `authenticated`; diagnostico, accesorios y recibido_por siguen
--      abiertos por columna.
-- =====================================================================

-- El comentario de cambiar_estado viaja a la bitácora por una variable de
-- transacción (la fila del historial la escribe el trigger AFTER). Sin
-- ella, el comentario sigue siendo el diagnóstico, como hasta ahora.
CREATE OR REPLACE FUNCTION public.registrar_historial_orden()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO public.historial_ordenes
            (orden_id, estado_anterior, estado_nuevo, modificado_por, comentario)
        VALUES (NEW.id, NULL, NEW.estado, auth.uid(), 'Orden creada');
        RETURN NEW;
    END IF;

    IF NEW.estado IS DISTINCT FROM OLD.estado THEN
        INSERT INTO public.historial_ordenes
            (orden_id, estado_anterior, estado_nuevo, modificado_por, comentario)
        VALUES (NEW.id, OLD.estado, NEW.estado, auth.uid(),
                coalesce(nullif(btrim(coalesce(current_setting('app.comentario_estado', true), '')), ''),
                         nullif(btrim(coalesce(NEW.diagnostico, '')), '')));
    END IF;

    RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------
--  CAMBIAR_ESTADO
-- ---------------------------------------------------------------------
CREATE FUNCTION public.cambiar_estado(
    p_orden_id   uuid,
    p_estado     text,
    p_comentario text DEFAULT NULL,
    p_motivo     text DEFAULT NULL)
RETURNS TABLE (orden_id uuid, estado text, tipo_atencion text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_asignado uuid;
    v_motivo   text := btrim(coalesce(p_motivo, ''));
BEGIN
    IF NOT public.tiene_rol('ADMIN', 'JEFE_SERVICIO', 'TECNICO', 'RECEPCION') THEN
        RAISE EXCEPTION 'Su rol no puede cambiar el estado de una orden' USING ERRCODE = '42501';
    END IF;

    SELECT o.tecnico_asignado_id INTO v_asignado
      FROM public.ordenes_servicio o WHERE o.id = p_orden_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No existe la orden indicada' USING ERRCODE = 'P0002';
    END IF;
    -- Un TECNICO solo mueve lo que tiene asignado (como la política anterior).
    IF public.tiene_rol('TECNICO') AND v_asignado IS DISTINCT FROM auth.uid() THEN
        RAISE EXCEPTION 'Solo el técnico asignado puede cambiar el estado de la orden'
            USING ERRCODE = '42501';
    END IF;
    IF p_estado = 'RECHAZADO' AND length(v_motivo) < 10 THEN
        RAISE EXCEPTION 'El motivo del rechazo es obligatorio (mínimo 10 caracteres)'
            USING ERRCODE = '22P02';
    END IF;

    PERFORM set_config('app.comentario_estado', coalesce(p_comentario, ''), true);
    UPDATE public.ordenes_servicio o
       SET estado = p_estado,
           motivo_rechazo = CASE WHEN p_estado = 'RECHAZADO' THEN v_motivo ELSE o.motivo_rechazo END
     WHERE o.id = p_orden_id;
    PERFORM set_config('app.comentario_estado', '', true);

    RETURN QUERY
    SELECT o.id, o.estado, o.tipo_atencion FROM public.ordenes_servicio o WHERE o.id = p_orden_id;
END;
$$;

-- ---------------------------------------------------------------------
--  ASIGNAR_TECNICO (NULL desasigna). La bitácora la escribe el trigger.
-- ---------------------------------------------------------------------
CREATE FUNCTION public.asignar_tecnico(p_orden_id uuid, p_tecnico_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_estado text;
BEGIN
    IF NOT public.tiene_rol('ADMIN', 'JEFE_SERVICIO') THEN
        RAISE EXCEPTION 'Solo ADMIN o JEFE_SERVICIO asignan técnico' USING ERRCODE = '42501';
    END IF;
    SELECT o.estado INTO v_estado FROM public.ordenes_servicio o WHERE o.id = p_orden_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No existe la orden indicada' USING ERRCODE = 'P0002';
    END IF;
    IF v_estado IN ('ENTREGADO', 'ANULADO') THEN
        RAISE EXCEPTION 'La orden está cerrada' USING ERRCODE = '23514';
    END IF;
    IF p_tecnico_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.profiles p
         WHERE p.id = p_tecnico_id AND p.role = 'TECNICO' AND p.is_active) THEN
        RAISE EXCEPTION 'El destinatario debe ser un técnico activo' USING ERRCODE = '22P02';
    END IF;

    UPDATE public.ordenes_servicio SET tecnico_asignado_id = p_tecnico_id WHERE id = p_orden_id;
END;
$$;

-- ---------------------------------------------------------------------
--  REGISTRAR_PRESUPUESTO — solo un servicio pago (spec §4.4)
-- ---------------------------------------------------------------------
CREATE FUNCTION public.registrar_presupuesto(p_orden_id uuid, p_monto numeric)
RETURNS TABLE (tipo_atencion text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_asignado uuid;
    v_estado   text;
    v_tipo     text;
BEGIN
    IF NOT public.tiene_rol('ADMIN', 'JEFE_SERVICIO', 'TECNICO') THEN
        RAISE EXCEPTION 'Su rol no puede registrar presupuestos' USING ERRCODE = '42501';
    END IF;
    SELECT o.tecnico_asignado_id, o.estado, o.tipo_atencion INTO v_asignado, v_estado, v_tipo
      FROM public.ordenes_servicio o WHERE o.id = p_orden_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No existe la orden indicada' USING ERRCODE = 'P0002';
    END IF;
    IF public.tiene_rol('TECNICO') AND v_asignado IS DISTINCT FROM auth.uid() THEN
        RAISE EXCEPTION 'Solo el técnico asignado puede registrar el presupuesto'
            USING ERRCODE = '42501';
    END IF;
    IF v_estado IN ('ENTREGADO', 'ANULADO') THEN
        RAISE EXCEPTION 'La orden está cerrada' USING ERRCODE = '23514';
    END IF;
    IF v_tipo <> 'PAGO' THEN
        RAISE EXCEPTION 'Solo se presupuesta un servicio pago' USING ERRCODE = '23514';
    END IF;
    IF p_monto IS NULL OR p_monto < 0 THEN
        RAISE EXCEPTION 'El monto debe ser un número mayor o igual a cero' USING ERRCODE = '22P02';
    END IF;

    UPDATE public.ordenes_servicio SET costo_reparacion = p_monto WHERE id = p_orden_id;
    RETURN QUERY SELECT v_tipo;
END;
$$;

REVOKE ALL ON FUNCTION public.cambiar_estado(uuid, text, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.asignar_tecnico(uuid, uuid)            FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.registrar_presupuesto(uuid, numeric)    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cambiar_estado(uuid, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.asignar_tecnico(uuid, uuid)            TO authenticated;
GRANT EXECUTE ON FUNCTION public.registrar_presupuesto(uuid, numeric)    TO authenticated;

-- Cierre del UPDATE directo: estado y costo solo por las RPC de arriba.
REVOKE UPDATE (estado, costo_reparacion) ON public.ordenes_servicio FROM authenticated;


-- =================== 20261030000022_orden_atencion_fix_bitacora.sql ===================
-- =====================================================================
--  20261030000022_orden_atencion_fix_bitacora.sql
--  (El encabezado citaba su nombre viejo 20261030000015_: el archivo se
--  renombró por colisión de número con `0015_orden_atencion.sql` y para
--  dejar la cadena 0013–0022 ordenada para la CI y `verificar-migraciones.sh`.)
--  CORRECCIÓN de la revisión (fase 2a, tarea 5, ronda 1): la bitácora
--  de eventos se escribía bajo la identidad de quien ejecuta el UPDATE
--  (SECURITY INVOKER), y `authenticated` NO tiene INSERT en
--  `historial_ordenes` (solo SELECT, 0006): un UPDATE legítimo de
--  costo_reparacion hecho por el TÉCNICO asignado (RLS
--  reg_update_tecnico + GRANT UPDATE por columna) moría entero con
--  'permission denied for table historial_ordenes' SOLO por la anotación
--  del trigger. Ahora el trigger escribe bajo el DEFINER (dueño de las
--  tablas, con la RLS superada como propietario): los RPCs SECURITY
--  DEFINER (tareas 10–11) y los UPDATE autorizados por columna siguen
--  anotando sin GRANT INSERT nuevo.
--
--  TRAZABILIDAD INTACTA: `auth.uid()` lee request.jwt.claim.sub, un GUC
--  de sesión que SECURITY DEFINER NO cambia (cambiar de rol no reconfigura
--  los GUC `request.jwt.*`): `modificado_por` sigue siendo el uid del
--  SOLICITANTE original. Lo cubre A9b de 21_orden_atencion.sql.
--
--  Se re-crea con DROP CASCADE + CREATE (la 0015 ya aplicada no se edita).
--  El CASCADE retira `trg_registrar_evento_orden` junto con la función y
--  abajo vuelve a crearse apuntando a la firma idéntica.
-- =====================================================================

DROP FUNCTION public.registrar_evento_orden() CASCADE;

CREATE FUNCTION public.registrar_evento_orden()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_comentario text;
BEGIN
    IF NEW.cobertura IS DISTINCT FROM OLD.cobertura THEN
        v_comentario := 'La cobertura cambió a ' || NEW.cobertura::text
                      || ' con la orden en ' || NEW.estado;
    ELSIF NEW.costo_reparacion IS DISTINCT FROM OLD.costo_reparacion THEN
        v_comentario := 'Presupuesto: ' || NEW.costo_reparacion::text;
    ELSIF NEW.tecnico_asignado_id IS DISTINCT FROM OLD.tecnico_asignado_id THEN
        IF NEW.tecnico_asignado_id IS NULL THEN
            v_comentario := 'Técnico desasignado';
        ELSE
            v_comentario := 'Técnico asignado: ' || (
                SELECT p.full_name FROM public.profiles p
                 WHERE p.id = NEW.tecnico_asignado_id);
        END IF;
    END IF;

    IF v_comentario IS NOT NULL THEN
        -- SECURITY DEFINER: la escritura la autoriza el dueño. `auth.uid()`
        -- conserva el claim del SOLICITANTE (request.jwt.claim.sub no cambia
        -- al cambiar de rol): trazabilidad intacta.
        INSERT INTO public.historial_ordenes
            (orden_id, estado_anterior, estado_nuevo, evento, modificado_por, comentario)
        VALUES (NEW.id, NULL, NEW.estado, 'BITACORA', auth.uid(), v_comentario);
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_registrar_evento_orden
    AFTER UPDATE OF cobertura, costo_reparacion, tecnico_asignado_id
    ON public.ordenes_servicio
    FOR EACH ROW EXECUTE FUNCTION public.registrar_evento_orden();

-- =================== 20261030000023_ventas_facturas.sql ===================
-- =====================================================================
--  20261030000023_ventas_facturas.sql
--  Fase 2b, tarea 1: facturas de Ventas por CSV como segunda fuente de
--  verdad de la compra.
--    · ventas_facturas / lotes_importacion: solo ADMIN y JEFE las leen y
--      solo `importar_ventas` las escribe. Nada se borra.
--    · Una garantía TALLER se confirma sola cuando coinciden factura +
--      serial + documento del titular + fecha de emisión. Si algo difiere
--      queda para revisión del jefe; nunca se desestima sola y una compra
--      desestimada nunca se confirma sola.
--    · Una garantía VENTA solo se informa (v_garantias.verificacion).
-- =====================================================================

ALTER TABLE public.equipos
    ADD COLUMN compra_confirmada_via text
        CHECK (compra_confirmada_via IS NULL OR compra_confirmada_via IN ('MANUAL', 'VENTAS'));
UPDATE public.equipos SET compra_confirmada_via = 'MANUAL' WHERE compra_confirmada_por IS NOT NULL;

CREATE TABLE public.lotes_importacion (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    archivo      text NOT NULL CHECK (length(btrim(archivo)) BETWEEN 1 AND 200),
    filas_total  integer NOT NULL DEFAULT 0,
    filas_ok     integer NOT NULL DEFAULT 0,
    filas_error  integer NOT NULL DEFAULT 0,
    importado_por uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
    creado_en    timestamptz NOT NULL DEFAULT now()
);

-- Las columnas normalizadas repiten la expresión de `equipos` (Postgres no
-- admite funciones propias en columnas generadas).
CREATE TABLE public.ventas_facturas (
    id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    lote_id              uuid NOT NULL REFERENCES public.lotes_importacion(id),
    numero_factura       text NOT NULL CHECK (length(btrim(numero_factura)) BETWEEN 1 AND 40),
    factura_normalizada  text GENERATED ALWAYS AS
        (upper(regexp_replace(numero_factura, '[ -]', '', 'g'))) STORED,
    fecha_emision        date NOT NULL
        CHECK (fecha_emision >= DATE '2000-01-01' AND fecha_emision <= public.hoy_local()),
    tipo_documento       text CHECK (length(tipo_documento) <= 5),
    numero_documento     text NOT NULL CHECK (length(btrim(numero_documento)) BETWEEN 1 AND 30),
    documento_normalizado text GENERATED ALWAYS AS
        (upper(regexp_replace(coalesce(tipo_documento, '') || numero_documento, '[^A-Za-z0-9]', '', 'g'))) STORED,
    nombre_cliente       text CHECK (length(nombre_cliente) <= 150),
    numero_serie         text NOT NULL CHECK (length(btrim(numero_serie)) BETWEEN 3 AND 60),
    serie_normalizada    text GENERATED ALWAYS AS
        (upper(regexp_replace(numero_serie, '[ -]', '', 'g'))) STORED,
    modelo               text CHECK (length(modelo) <= 80),
    vendedor             text CHECK (length(vendedor) <= 80),
    importado_por        uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
    creado_en            timestamptz NOT NULL DEFAULT now(),
    actualizado_en       timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_ventas_factura_serie UNIQUE (factura_normalizada, serie_normalizada)
);

ALTER TABLE public.lotes_importacion ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ventas_facturas   ENABLE ROW LEVEL SECURITY;
CREATE POLICY lotes_lectura ON public.lotes_importacion
    FOR SELECT TO authenticated USING (public.mi_rol() IN ('ADMIN', 'JEFE_SERVICIO'));
CREATE POLICY ventas_lectura ON public.ventas_facturas
    FOR SELECT TO authenticated USING (public.mi_rol() IN ('ADMIN', 'JEFE_SERVICIO'));
REVOKE ALL ON public.lotes_importacion, public.ventas_facturas FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.lotes_importacion, public.ventas_facturas TO authenticated;

-- ---------------------------------------------------------------------
--  VERIFICACION_VENTA — COINCIDE / DIFIERE / SIN_VENTA (NULL sin soporte
--  o sin rol interno). SECURITY DEFINER: la tabla de ventas es solo de la
--  jefatura, pero el resultado de tres valores lo ve todo rol interno.
-- ---------------------------------------------------------------------
CREATE FUNCTION public.verificacion_venta(p_equipo_id uuid)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_res text;
BEGIN
    IF NOT public.tiene_rol('ADMIN', 'JEFE_SERVICIO', 'TECNICO', 'RECEPCION') THEN
        RETURN NULL;
    END IF;
    SELECT CASE
             WHEN e.numero_soporte IS NULL THEN NULL
             WHEN v.id IS NULL THEN 'SIN_VENTA'
             WHEN v.documento_normalizado = upper(regexp_replace(c.tipo_documento::text || c.documento,
                                                                 '[^A-Za-z0-9]', '', 'g'))
                  AND v.fecha_emision = e.fecha_emision THEN 'COINCIDE'
             ELSE 'DIFIERE' END
      INTO v_res
      FROM public.equipos e
      JOIN public.clientes c ON c.id = e.cliente_id
      LEFT JOIN public.ventas_facturas v
             ON v.serie_normalizada = e.serie_normalizada
            AND v.factura_normalizada = upper(regexp_replace(e.numero_soporte, '[ -]', '', 'g'))
     WHERE e.id = p_equipo_id;
    RETURN v_res;
END;
$$;
REVOKE ALL ON FUNCTION public.verificacion_venta(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.verificacion_venta(uuid) TO authenticated;

-- Interna (sin GRANT): confirma una garantía TALLER que coincide con la
-- venta, con la misma ruta que confirmar_compra (recalcula las órdenes).
CREATE FUNCTION public.confirmar_por_ventas(p_equipo_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    UPDATE public.equipos e
       SET compra_confirmada_por = auth.uid(),
           compra_confirmada_en  = now(),
           compra_confirmada_via = 'VENTAS'
     WHERE e.id = p_equipo_id
       AND e.origen = 'TALLER'
       AND e.compra_confirmada_por IS NULL
       AND e.compra_desestimada_por IS NULL
       AND public.verificacion_venta(e.id) = 'COINCIDE';
    IF NOT FOUND THEN
        RETURN false;
    END IF;
    PERFORM public.recalcular_cobertura_equipo(p_equipo_id);
    RETURN true;
END;
$$;
REVOKE ALL ON FUNCTION public.confirmar_por_ventas(uuid) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------
--  IMPORTAR_VENTAS — ADMIN y JEFE. Cada fila se valida sola: las buenas
--  se guardan aunque otras fallen. Idempotente por (factura, serial).
-- ---------------------------------------------------------------------
CREATE FUNCTION public.importar_ventas(p_archivo text, p_filas jsonb)
RETURNS TABLE (lote_id uuid, nuevas integer, actualizadas integer,
               con_error integer, confirmadas integer, errores jsonb)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_archivo text := btrim(coalesce(p_archivo, ''));
    v_lote    uuid;
    r         record;
    v_campo   text;
    v_fecha   date;
    v_nuevo   boolean;
    v_nuevas  integer := 0;
    v_actual  integer := 0;
    v_err     jsonb := '[]'::jsonb;
    v_conf    integer;
    v_total   integer;
BEGIN
    IF NOT public.tiene_rol('ADMIN', 'JEFE_SERVICIO') THEN
        RAISE EXCEPTION 'Solo ADMIN o JEFE_SERVICIO importan ventas' USING ERRCODE = '42501';
    END IF;
    IF v_archivo = '' THEN
        RAISE EXCEPTION 'Falta el nombre del archivo' USING ERRCODE = '22P02';
    END IF;
    IF jsonb_typeof(p_filas) IS DISTINCT FROM 'array' THEN
        RAISE EXCEPTION 'Las filas deben ser un arreglo JSON' USING ERRCODE = '22P02';
    END IF;
    v_total := jsonb_array_length(p_filas);
    IF v_total > 5000 THEN
        RAISE EXCEPTION 'Máximo 5000 filas por importación' USING ERRCODE = '22P02';
    END IF;

    INSERT INTO public.lotes_importacion (archivo, filas_total, importado_por)
    VALUES (v_archivo, v_total, auth.uid())
    RETURNING id INTO v_lote;

    FOR r IN SELECT f.v AS fila, f.n::integer AS n
               FROM jsonb_array_elements(p_filas) WITH ORDINALITY f(v, n) LOOP
        BEGIN
            v_campo := 'fila';
            IF jsonb_typeof(r.fila) <> 'object' THEN
                RAISE EXCEPTION 'La fila no es un objeto' USING ERRCODE = '22P02';
            END IF;
            v_campo := 'numero_factura';
            IF length(btrim(coalesce(r.fila->>'numero_factura', ''))) NOT BETWEEN 1 AND 40 THEN
                RAISE EXCEPTION 'La factura es obligatoria (hasta 40 caracteres)' USING ERRCODE = '22P02';
            END IF;
            v_campo := 'fecha_emision';
            v_fecha := (r.fila->>'fecha_emision')::date;
            IF v_fecha IS NULL OR v_fecha < DATE '2000-01-01' OR v_fecha > public.hoy_local() THEN
                RAISE EXCEPTION 'La fecha de emisión es obligatoria y no puede ser futura' USING ERRCODE = '22P02';
            END IF;
            v_campo := 'numero_documento';
            IF length(btrim(coalesce(r.fila->>'numero_documento', ''))) NOT BETWEEN 1 AND 30 THEN
                RAISE EXCEPTION 'El documento del cliente es obligatorio (hasta 30 caracteres)' USING ERRCODE = '22P02';
            END IF;
            v_campo := 'serial';
            IF length(btrim(coalesce(r.fila->>'serial', ''))) NOT BETWEEN 3 AND 60 THEN
                RAISE EXCEPTION 'El serial es obligatorio (3 a 60 caracteres)' USING ERRCODE = '22P02';
            END IF;

            v_campo := 'fila';
            INSERT INTO public.ventas_facturas
                (lote_id, numero_factura, fecha_emision, tipo_documento, numero_documento,
                 nombre_cliente, numero_serie, modelo, vendedor, importado_por)
            VALUES (v_lote, btrim(r.fila->>'numero_factura'), v_fecha,
                    nullif(btrim(coalesce(r.fila->>'tipo_documento', '')), ''),
                    btrim(r.fila->>'numero_documento'),
                    nullif(btrim(coalesce(r.fila->>'nombre_cliente', '')), ''),
                    btrim(r.fila->>'serial'),
                    nullif(btrim(coalesce(r.fila->>'modelo', '')), ''),
                    nullif(btrim(coalesce(r.fila->>'vendedor', '')), ''),
                    auth.uid())
            ON CONFLICT (factura_normalizada, serie_normalizada) DO UPDATE
               SET lote_id = EXCLUDED.lote_id, fecha_emision = EXCLUDED.fecha_emision,
                   tipo_documento = EXCLUDED.tipo_documento, numero_documento = EXCLUDED.numero_documento,
                   nombre_cliente = EXCLUDED.nombre_cliente, modelo = EXCLUDED.modelo,
                   vendedor = EXCLUDED.vendedor, importado_por = EXCLUDED.importado_por,
                   actualizado_en = now()
            RETURNING (xmax = 0) INTO v_nuevo;

            IF v_nuevo THEN v_nuevas := v_nuevas + 1; ELSE v_actual := v_actual + 1; END IF;
        EXCEPTION WHEN OTHERS THEN
            v_err := v_err || jsonb_build_array(jsonb_build_object(
                'fila', r.n, 'campo', v_campo, 'mensaje', SQLERRM));
        END;
    END LOOP;

    -- Las garantías TALLER pendientes que esta carga respalda.
    SELECT count(*) INTO v_conf
      FROM (SELECT public.confirmar_por_ventas(e.id) AS ok
              FROM public.ventas_facturas v
              JOIN public.equipos e
                ON e.serie_normalizada = v.serie_normalizada
               AND upper(regexp_replace(coalesce(e.numero_soporte, ''), '[ -]', '', 'g')) = v.factura_normalizada
             WHERE v.lote_id = v_lote
               AND e.origen = 'TALLER'
               AND e.compra_confirmada_por IS NULL
               AND e.compra_desestimada_por IS NULL) x
     WHERE x.ok;

    UPDATE public.lotes_importacion l
       SET filas_ok = v_nuevas + v_actual, filas_error = v_total - v_nuevas - v_actual
     WHERE l.id = v_lote;

    RETURN QUERY SELECT v_lote, v_nuevas, v_actual, v_total - v_nuevas - v_actual, v_conf, v_err;
END;
$$;
REVOKE ALL ON FUNCTION public.importar_ventas(text, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.importar_ventas(text, jsonb) TO authenticated;

-- ---------------------------------------------------------------------
--  confirmar_compra: deja la vía MANUAL (misma firma y reglas de la 0020).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.confirmar_compra(
    p_equipo_id      uuid,
    p_tipo_soporte   text,
    p_numero_soporte text,
    p_fecha_emision  date,
    p_plazo_dias     integer)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_desestimada boolean;
BEGIN
    IF NOT public.tiene_rol('ADMIN', 'JEFE_SERVICIO') THEN
        RAISE EXCEPTION 'Solo ADMIN o JEFE_SERVICIO confirman la compra' USING ERRCODE = '42501';
    END IF;

    IF coalesce(p_tipo_soporte, '') NOT IN ('FACTURA', 'NOTA_ENTREGA')
       OR coalesce(btrim(p_numero_soporte), '') = ''
       OR p_fecha_emision IS NULL OR p_plazo_dias IS NULL THEN
        RAISE EXCEPTION 'Faltan datos del soporte: tipo, número, fecha de emisión y plazo'
            USING ERRCODE = '22P02';
    END IF;

    SELECT (compra_desestimada_por IS NOT NULL) INTO v_desestimada
      FROM public.equipos WHERE id = p_equipo_id;
    IF v_desestimada IS NULL THEN
        RAISE EXCEPTION 'Equipo inexistente' USING ERRCODE = 'P0002';
    END IF;
    IF v_desestimada THEN
        RAISE EXCEPTION 'La compra fue desestimada; no se puede confirmar'
            USING ERRCODE = '23514';
    END IF;

    UPDATE public.equipos
       SET tipo_soporte   = p_tipo_soporte,
           numero_soporte = btrim(p_numero_soporte),
           fecha_emision  = p_fecha_emision,
           plazo_dias     = p_plazo_dias,
           compra_confirmada_por = auth.uid(),
           compra_confirmada_en  = now(),
           compra_confirmada_via = 'MANUAL'
     WHERE id = p_equipo_id;

    PERFORM public.recalcular_cobertura_equipo(p_equipo_id);
END;
$$;

-- ---------------------------------------------------------------------
--  registrar_garantia: si la venta ya estaba importada, una garantía
--  TALLER nueva nace confirmada (misma firma y reglas de la 0018).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.registrar_garantia(
    p_cliente_id      uuid,
    p_producto_id     uuid,
    p_serial          text,
    p_tipo_soporte    text DEFAULT NULL,
    p_numero_soporte  text DEFAULT NULL,
    p_fecha_emision   date DEFAULT NULL,
    p_plazo_dias      integer DEFAULT NULL,
    p_origen          text DEFAULT 'VENTA')
RETURNS TABLE (equipo_id uuid, vence_el date, equipo_nuevo boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_serial text := btrim(coalesce(p_serial, ''));
    v_equipo uuid;
BEGIN
    IF NOT public.tiene_rol('ADMIN', 'JEFE_SERVICIO', 'TECNICO', 'RECEPCION') THEN
        RAISE EXCEPTION 'Su rol no puede registrar garantías' USING ERRCODE = '42501';
    END IF;
    IF p_origen IS NULL OR p_origen NOT IN ('VENTA', 'TALLER') THEN
        RAISE EXCEPTION 'El origen debe ser VENTA o TALLER' USING ERRCODE = '22P02';
    END IF;
    IF length(v_serial) < 3 OR length(v_serial) > 60 THEN
        RAISE EXCEPTION 'El serial es obligatorio (3 a 60 caracteres)' USING ERRCODE = '22P02';
    END IF;
    IF p_plazo_dias IS NOT NULL AND p_plazo_dias NOT IN (7, 15)
       AND NOT public.tiene_rol('ADMIN', 'JEFE_SERVICIO') THEN
        RAISE EXCEPTION 'Los plazos distintos de 7 o 15 días solo los fija el jefe'
            USING ERRCODE = '42501';
    END IF;

    SELECT e.id INTO v_equipo
      FROM public.equipos e
     WHERE e.producto_id = p_producto_id
       AND e.serie_normalizada = public.normalizar_serie(v_serial);

    equipo_nuevo := v_equipo IS NULL;
    IF equipo_nuevo THEN
        INSERT INTO public.equipos (numero_serie, producto_id, cliente_id,
                                    tipo_soporte, numero_soporte, fecha_emision,
                                    plazo_dias, origen, registrado_por)
        VALUES (v_serial, p_producto_id, p_cliente_id,
                nullif(btrim(coalesce(p_tipo_soporte, '')), ''),
                nullif(btrim(coalesce(p_numero_soporte, '')), ''),
                p_fecha_emision, p_plazo_dias, p_origen, auth.uid())
        ON CONFLICT (producto_id, serie_normalizada) DO NOTHING
        RETURNING id INTO v_equipo;
        IF v_equipo IS NULL THEN          -- otro envío ganó la carrera
            equipo_nuevo := false;
            SELECT e.id INTO v_equipo FROM public.equipos e
             WHERE e.producto_id = p_producto_id
               AND e.serie_normalizada = public.normalizar_serie(v_serial);
        ELSE
            PERFORM public.confirmar_por_ventas(v_equipo);
        END IF;
    END IF;

    equipo_id := v_equipo;
    SELECT e.vence_el INTO vence_el FROM public.equipos e WHERE e.id = v_equipo;
    RETURN NEXT;
END;
$$;

-- ---------------------------------------------------------------------
--  v_garantias: dos columnas más al final (verificación y vía).
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_garantias
WITH (security_invoker = true) AS
SELECT e.id                               AS equipo_id,
       e.numero_serie,
       e.producto_id,
       (m.nombre || ' ' || pr.modelo)     AS producto,
       e.cliente_id                       AS titular_id,
       c.nombre                           AS titular,
       c.documento,
       e.numero_soporte,
       e.fecha_emision,
       e.plazo_dias,
       e.vence_el,
       (e.vence_el - public.hoy_local())  AS dias_restantes,
       e.origen,
       public.calcular_cobertura(
           e.vence_el, public.hoy_local(), NULL, e.origen,
           e.compra_confirmada_por IS NOT NULL,
           e.compra_desestimada_por IS NOT NULL)  AS vigencia,
       CASE WHEN e.compra_desestimada_por IS NOT NULL THEN 'DESESTIMADA'
            WHEN e.compra_confirmada_por IS NOT NULL OR e.origen = 'VENTA' THEN 'CONFIRMADA'
            ELSE 'PENDIENTE' END          AS estado_compra,
       public.verificacion_venta(e.id)    AS verificacion,
       e.compra_confirmada_via
  FROM public.equipos e
  JOIN public.productos pr ON pr.id = e.producto_id
  JOIN public.marcas m     ON m.id  = pr.marca_id
  JOIN public.clientes c   ON c.id  = e.cliente_id;

INSERT INTO supabase_migrations.schema_migrations (version, name) VALUES
  ('20261030000004', 'ajustes_y_cobertura'),
  ('20261030000005', 'equipos'),
  ('20261030000006', 'registros'),
  ('20261030000007', 'revisiones'),
  ('20261030000008', 'adjuntos'),
  ('20261030000009', 'rpc_registro'),
  ('20261030000010', 'v_tablero'),
  ('20261030000011', 'limpieza_huerfanos'),
  ('20261030000012', 'idempotencia_ingreso'),
  ('20261030000013', 'fase2a_renombre'),
  ('20261030000014', 'equipos_origen'),
  ('20261030000015', 'orden_atencion'),
  ('20261030000016', 'rechazado_transiciones'),
  ('20261030000017', 'reglas_avance'),
  ('20261030000018', 'rpc_garantia'),
  ('20261030000019', 'abrir_orden'),
  ('20261030000020', 'confirmar_desestimar'),
  ('20261030000021', 'maquina_rpc'),
  ('20261030000022', 'orden_atencion_fix_bitacora'),
  ('20261030000023', 'ventas_facturas')
ON CONFLICT (version) DO NOTHING;
COMMIT;
