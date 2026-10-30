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