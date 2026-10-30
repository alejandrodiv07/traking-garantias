-- =====================================================================
--  20261030000015_orden_atencion_fix_bitacora.sql
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