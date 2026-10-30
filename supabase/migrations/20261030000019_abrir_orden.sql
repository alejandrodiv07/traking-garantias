-- =====================================================================
--  20261030000019_abrir_orden.sql
--  Fase 2a, tarea 9 (spec §5.1 y §6): abrir_orden pasa a trabajar sobre
--  una garantía ya registrada (equipo), no a crearla.
--    · La garantía se crea con registrar_garantia (0018), que impone el
--      plazo de 7 o 15 días; la firma vieja de 14 parámetros creaba el
--      equipo con cualquier plazo y se retira.
--    · UNA transacción: orden + revisión de RECEPCION. La cobertura la
--      pone el trigger de las revisiones; tipo_atencion es generada.
--    · Idempotente por (creado_por, clave_envio), con el candado de la 0012.
--    · p_fecha_ingreso la manda SOLO el ADMIN (backoffice); a los demás
--      roles se les ignora y reciben now().
-- =====================================================================
DROP FUNCTION public.abrir_orden(
    text, uuid, uuid, text, text, text, text, date, integer, text,
    jsonb, text, timestamptz, uuid);

CREATE FUNCTION public.abrir_orden(
    p_equipo_id       uuid,
    p_falla           text,
    p_accesorios      text DEFAULT NULL,
    p_checklist       jsonb DEFAULT NULL,
    p_observaciones   text DEFAULT NULL,
    p_clave_envio     uuid DEFAULT NULL,
    p_fecha_ingreso   timestamptz DEFAULT NULL)
RETURNS TABLE (
    orden_id        uuid,
    numero_orden    text,
    consulta_token  text,   -- TEXTO PLANO, una sola vez (imprimir y olvidar)
    cobertura       public.cobertura_garantia,
    tipo_atencion   text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_rol    public.app_role := public.mi_rol();
    v_actor  uuid := auth.uid();
    v_falla  text := btrim(coalesce(p_falla, ''));
    v_token  text;
    v_orden  uuid;
BEGIN
    IF v_rol IS NULL OR NOT public.tiene_rol('ADMIN', 'JEFE_SERVICIO', 'TECNICO', 'RECEPCION') THEN
        RAISE EXCEPTION 'Su rol no puede abrir órdenes' USING ERRCODE = '42501';
    END IF;

    -- Idempotencia: el candado serializa dos envíos simultáneos con la misma
    -- clave; el segundo encuentra la orden del primero. El token en claro no
    -- se puede reconstruir (solo se guarda el hash): vuelve en NULL.
    IF p_clave_envio IS NOT NULL THEN
        PERFORM pg_advisory_xact_lock(hashtextextended(v_actor::text || p_clave_envio::text, 0));
        RETURN QUERY
        SELECT o.id, o.numero_orden, NULL::text, o.cobertura, o.tipo_atencion
          FROM public.ordenes_servicio o
         WHERE o.creado_por = v_actor AND o.clave_envio = p_clave_envio;
        IF FOUND THEN
            RETURN;
        END IF;
    END IF;

    IF length(v_falla) < 5 OR length(v_falla) > 2000 THEN
        RAISE EXCEPTION 'La falla reportada es obligatoria (5 a 2000 caracteres)'
            USING ERRCODE = '22P02';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.equipos e WHERE e.id = p_equipo_id) THEN
        RAISE EXCEPTION 'No existe el equipo indicado' USING ERRCODE = 'P0002';
    END IF;

    v_token := encode(extensions.gen_random_bytes(16), 'hex');

    INSERT INTO public.ordenes_servicio (equipo_id, falla_reportada, accesorios,
                                         cobertura, tecnico_asignado_id, creado_por,
                                         consulta_token_hash, fecha_ingreso, clave_envio)
    VALUES (p_equipo_id, v_falla,
            nullif(btrim(coalesce(p_accesorios, '')), ''),
            'POR_DETERMINAR',
            CASE WHEN v_rol = 'TECNICO' THEN v_actor END,
            v_actor,
            extensions.digest(v_token, 'sha256'),
            coalesce(CASE WHEN public.tiene_rol('ADMIN') THEN p_fecha_ingreso END, now()),
            p_clave_envio)
    RETURNING id INTO v_orden;

    -- La auditoría de recepción: la primera revisión. Su trigger fija la cobertura.
    INSERT INTO public.revisiones (orden_id, tipo, revisado_por, checklist, observaciones)
    VALUES (v_orden, 'RECEPCION', v_actor, p_checklist,
            nullif(btrim(coalesce(p_observaciones, '')), ''));

    RETURN QUERY
    SELECT o.id, o.numero_orden, v_token, o.cobertura, o.tipo_atencion
      FROM public.ordenes_servicio o
     WHERE o.id = v_orden;
END;
$$;

REVOKE ALL ON FUNCTION public.abrir_orden(uuid, text, text, jsonb, text, uuid, timestamptz)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.abrir_orden(uuid, text, text, jsonb, text, uuid, timestamptz)
  TO authenticated;
