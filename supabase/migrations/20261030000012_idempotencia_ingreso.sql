-- 0012 — Idempotencia de registrar_ingreso (revisión de ingeniería H1/H2).
--
-- Un doble clic, o un reintento tras un timeout, creaba dos registros (cada
-- uno con su token) para el mismo ingreso. Ahora el asistente genera una
-- clave por envío (uuid) y la base devuelve el registro original si el mismo
-- usuario la repite. Sin clave (NULL) el comportamiento no cambia.
-- Es una migración NUEVA: no se edita la 0009 ya existente.

ALTER TABLE public.registros ADD COLUMN clave_envio uuid;

CREATE UNIQUE INDEX uq_registros_clave_envio
    ON public.registros (creado_por, clave_envio)
 WHERE clave_envio IS NOT NULL;

-- La firma cambia (parámetro nuevo al final): se retira la anterior para no
-- dejar dos sobrecargas ambiguas.
DROP FUNCTION public.registrar_ingreso(text, uuid, uuid, text, text, text, text, date, integer, text, jsonb, text, timestamptz);

CREATE FUNCTION public.registrar_ingreso(
    p_serial          text,
    p_producto_id     uuid,
    p_cliente_id      uuid,
    p_falla           text,
    p_accesorios      text DEFAULT NULL,
    p_tipo_soporte    text DEFAULT NULL,
    p_numero_soporte  text DEFAULT NULL,
    p_fecha_emision   date DEFAULT NULL,
    p_plazo_dias      integer DEFAULT NULL,
    p_vendedor        text DEFAULT NULL,
    p_checklist       jsonb DEFAULT NULL,
    p_observaciones   text DEFAULT NULL,
    p_fecha_ingreso   timestamptz DEFAULT NULL,
    p_clave_envio     uuid DEFAULT NULL)
RETURNS TABLE (
    registro_id     uuid,
    numero_registro text,
    consulta_token  text,   -- TEXTO PLANO, una sola vez (imprimir y olvidar)
    cobertura       public.cobertura_garantia,
    equipo_id       uuid,
    equipo_nuevo    boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_rol    public.app_role := public.mi_rol();
    v_actor  uuid := auth.uid();
    v_serial text := btrim(coalesce(p_serial, ''));
    v_falla  text := btrim(coalesce(p_falla, ''));
    v_equipo uuid;
    v_nuevo  boolean;
    v_token  text;
    v_registro uuid;
BEGIN
    IF v_rol IS NULL OR NOT public.tiene_rol('ADMIN', 'JEFE_SERVICIO', 'TECNICO', 'RECEPCION') THEN
        RAISE EXCEPTION 'Su rol no puede registrar ingresos' USING ERRCODE = '42501';
    END IF;

    -- ---- Idempotencia: la misma clave del mismo usuario = el mismo registro ----
    -- El candado serializa dos envíos simultáneos con la misma clave (doble
    -- clic): el segundo espera al primero y encuentra su registro. El token en
    -- claro NO se puede reconstruir (solo se guarda el hash): vuelve en NULL.
    IF p_clave_envio IS NOT NULL THEN
        PERFORM pg_advisory_xact_lock(hashtextextended(v_actor::text || p_clave_envio::text, 0));
        RETURN QUERY
        SELECT r.id, r.numero_registro, NULL::text, r.cobertura, r.equipo_id, false
          FROM public.registros r
         WHERE r.creado_por = v_actor AND r.clave_envio = p_clave_envio;
        IF FOUND THEN
            RETURN;
        END IF;
    END IF;

    IF v_serial < '!' OR length(v_serial) < 3 THEN
        RAISE EXCEPTION 'El serial es obligatorio (3 a 60 caracteres)'
            USING ERRCODE = '22P02';
    END IF;
    IF length(v_falla) < 5 OR length(v_falla) > 2000 THEN
        RAISE EXCEPTION 'La falla reportada es obligatoria (5 a 2000 caracteres)'
            USING ERRCODE = '22P02';
    END IF;

    -- ---- Equipo: buscar y, si no existe, crearlo (sin carrera) ----
    v_equipo := NULL;
    IF p_producto_id IS NOT NULL AND p_cliente_id IS NOT NULL THEN
        SELECT id INTO v_equipo
          FROM public.equipos
         WHERE producto_id = p_producto_id
           AND serie_normalizada = public.normalizar_serie(v_serial);
    END IF;

    v_nuevo := v_equipo IS NULL;
    IF v_nuevo THEN
        IF p_producto_id IS NULL OR p_cliente_id IS NULL THEN
            RAISE EXCEPTION 'Para un equipo nuevo hacen falta producto y titular'
                USING ERRCODE = '22P02';
        END IF;
        INSERT INTO public.equipos (numero_serie, producto_id, cliente_id,
                                    tipo_soporte, numero_soporte, fecha_emision,
                                    plazo_dias, vendedor)
        VALUES (v_serial, p_producto_id, p_cliente_id,
                nullif(btrim(coalesce(p_tipo_soporte, '')), ''),
                nullif(btrim(coalesce(p_numero_soporte, '')), ''),
                p_fecha_emision, p_plazo_dias,
                nullif(btrim(coalesce(p_vendedor, '')), ''))
        ON CONFLICT (producto_id, serie_normalizada) DO NOTHING;

        SELECT id INTO v_equipo
          FROM public.equipos
         WHERE producto_id = p_producto_id
           AND serie_normalizada = public.normalizar_serie(v_serial);
        IF v_equipo IS NULL THEN
            RAISE EXCEPTION 'No fue posible crear el equipo (revise el serial)'
                USING ERRCODE = '23505';
        END IF;
    END IF;

    -- ---- Registro ----
    v_token := encode(extensions.gen_random_bytes(16), 'hex');

    INSERT INTO public.registros (equipo_id, falla_reportada, accesorios,
                                  cobertura, tecnico_asignado_id, creado_por,
                                  consulta_token_hash, fecha_ingreso, clave_envio)
    VALUES (v_equipo, v_falla,
            nullif(btrim(coalesce(p_accesorios, '')), ''),
            'POR_DETERMINAR',
            CASE WHEN v_rol = 'TECNICO' THEN v_actor END,
            v_actor,
            extensions.digest(v_token, 'sha256'),
            coalesce(p_fecha_ingreso, now()), p_clave_envio)
    RETURNING id INTO v_registro;

    -- ---- Primera revisión: la de recepción ----
    INSERT INTO public.revisiones (registro_id, tipo, revisado_por, checklist, observaciones)
    VALUES (v_registro, 'RECEPCION', v_actor, p_checklist,
            nullif(btrim(coalesce(p_observaciones, '')), ''));

    -- La cobertura la acaba de escribir el trigger de las revisiones.
    RETURN QUERY
    SELECT r.id, r.numero_registro, v_token, r.cobertura, v_equipo, v_nuevo
      FROM public.registros r
     WHERE r.id = v_registro;
END;
$$;

REVOKE ALL ON FUNCTION public.registrar_ingreso(text, uuid, uuid, text, text, text, text, date, integer, text, jsonb, text, timestamptz, uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.registrar_ingreso(text, uuid, uuid, text, text, text, text, date, integer, text, jsonb, text, timestamptz, uuid)
  TO authenticated;
