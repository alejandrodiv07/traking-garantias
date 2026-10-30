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