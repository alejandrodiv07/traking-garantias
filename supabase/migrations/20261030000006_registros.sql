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

-- Los cuatro roles internos leen todo el tablero (taller de 4 personas).
CREATE POLICY reg_select ON public.registros
    FOR SELECT TO authenticated USING (TRUE);

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
    FOR SELECT TO authenticated USING (TRUE);

CREATE POLICY notasRegistro_select ON public.notas_internas
    FOR SELECT TO authenticated USING (TRUE);
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
