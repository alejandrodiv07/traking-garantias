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