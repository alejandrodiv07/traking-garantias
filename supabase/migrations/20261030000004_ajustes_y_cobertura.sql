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