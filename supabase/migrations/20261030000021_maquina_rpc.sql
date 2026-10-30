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
