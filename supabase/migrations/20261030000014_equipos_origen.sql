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