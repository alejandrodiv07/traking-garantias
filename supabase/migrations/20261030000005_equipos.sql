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