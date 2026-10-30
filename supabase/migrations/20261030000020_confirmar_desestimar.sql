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
