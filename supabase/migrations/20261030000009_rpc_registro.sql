-- =====================================================================
--  20261030000009_rpc_registro.sql
--  Funciones de registro de ingreso (spec §5.5 y §6). Todas SECURITY
--  DEFINER, search_path fijado, EXECUTE solo para authenticated.
--  El TECNICO AHORA SÍ puede registrar (cambio del hito, spec §6).
-- =====================================================================

-- ---------------------------------------------------------------------
--  1. GUARDAR_CLIENTE — crea o devuelve el cliente de (tipo, documento)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.guardar_cliente(
    p_tipo      public.tipo_documento,
    p_documento text,
    p_nombre    text,
    p_telefono  text DEFAULT NULL,
    p_email     text DEFAULT NULL,
    p_direccion text DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_cliente_id uuid;
BEGIN
    -- El CHECK de la tabla (5–15 dígitos) rechaza lo malo; aquí solo
    -- normalizamos y resolvemos la existencia del titular.
    INSERT INTO public.clientes (tipo_documento, documento, nombre, telefono, email, direccion)
    VALUES (p_tipo,
            btrim(coalesce(p_documento, '')),
            btrim(coalesce(p_nombre, '')),
            nullif(btrim(coalesce(p_telefono, '')), ''),
            nullif(btrim(coalesce(p_email, '')), ''),
            nullif(btrim(coalesce(p_direccion, '')), ''))
    ON CONFLICT (tipo_documento, documento) DO NOTHING;

    SELECT id INTO v_cliente_id
      FROM public.clientes
     WHERE documento = btrim(coalesce(p_documento, ''))
       AND tipo_documento = p_tipo;
    RETURN v_cliente_id;
END;
$$;

REVOKE ALL ON FUNCTION public.guardar_cliente(public.tipo_documento, text, text, text, text, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.guardar_cliente(public.tipo_documento, text, text, text, text, text)
  TO authenticated;

-- ---------------------------------------------------------------------
--  2. BUSCAR_EQUIPO — por serial en TODOS los productos (spec §5.1)
--     Devuelve también el historial de registros del equipo, para el
--     asistente (paso 1) y la advertencia de serial en otro producto.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.buscar_equipo(p_serial text)
RETURNS TABLE (
    equipo_id      uuid,
    producto_id    uuid,
    producto       text,
    numero_serie   text,
    titular_id     uuid,
    titular        text,
    vence_el       date,
    dias_restantes integer,
    registros      jsonb
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    RETURN QUERY
    SELECT e.id, e.producto_id,
           (m.nombre || ' ' || pr.modelo)::text,
           e.numero_serie,
           e.cliente_id, c.nombre,
           e.vence_el,
           (e.vence_el - public.hoy_local())::int,
           COALESCE((
               SELECT jsonb_agg(
                          jsonb_build_object(
                              'numero',  r.numero_registro,
                              'estado',  r.estado,
                              'ingreso', r.fecha_ingreso::text,
                              'cobertura', r.cobertura::text)
                          ORDER BY r.fecha_ingreso)
                 FROM public.registros r
                WHERE r.equipo_id = e.id), '[]'::jsonb)
      FROM public.equipos e
      JOIN public.productos pr ON pr.id = e.producto_id
      JOIN public.marcas m     ON m.id  = pr.marca_id
      JOIN public.clientes c   ON c.id  = e.cliente_id
     WHERE (p_serial IS NOT NULL AND btrim(p_serial) <> ''
            AND e.serie_normalizada = public.normalizar_serie(btrim(p_serial)));
END;
$$;

REVOKE ALL ON FUNCTION public.buscar_equipo(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.buscar_equipo(text) TO authenticated;

-- ---------------------------------------------------------------------
--  3. REGISTRAR_INGRESO — la transacción completa (spec §5.5)
-- ---------------------------------------------------------------------
-- Crea o reutiliza el equipo (ON CONFLICT, sin carreras), crea el registro
-- con su correlativo, inserta la revisión de RECEPCION (que fija la
-- cobertura a través de los triggers de revisiones) y devuelve el token de
-- consulta UNA VEZ. Todo en una transacción: si algo falla, nada queda.
CREATE OR REPLACE FUNCTION public.registrar_ingreso(
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
    p_fecha_ingreso   timestamptz DEFAULT NULL)
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
                                  consulta_token_hash, fecha_ingreso)
    VALUES (v_equipo, v_falla,
            nullif(btrim(coalesce(p_accesorios, '')), ''),
            'POR_DETERMINAR',
            CASE WHEN v_rol = 'TECNICO' THEN v_actor END,
            v_actor,
            extensions.digest(v_token, 'sha256'),
            coalesce(p_fecha_ingreso, now()))
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

REVOKE ALL ON FUNCTION public.registrar_ingreso(text, uuid, uuid, text, text, text, text, date, integer, text, jsonb, text, timestamptz)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.registrar_ingreso(text, uuid, uuid, text, text, text, text, date, integer, text, jsonb, text, timestamptz)
  TO authenticated;
-- ---------------------------------------------------------------------
--  4. REGISTRAR_REVISION — añade una revisión a un registro existente
--     (spec §6: ADMIN, JEFE_SERVICIO y TECNICO; RECEPCION no)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.registrar_revision(
    p_registro_id   uuid,
    p_tipo          text,
    p_checklist     jsonb,
    p_observaciones text DEFAULT NULL)
RETURNS TABLE (revision_id uuid, cobertura public.cobertura_garantia)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_rol   public.app_role := public.mi_rol();
    v_id    uuid;
BEGIN
    IF v_rol IS NULL OR NOT public.tiene_rol('ADMIN', 'JEFE_SERVICIO', 'TECNICO') THEN
        RAISE EXCEPTION 'Su rol no puede registrar revisiones' USING ERRCODE = '42501';
    END IF;
    IF p_tipo NOT IN ('RECEPCION', 'TECNICA') THEN
        RAISE EXCEPTION 'El tipo de revisión es RECEPCION o TECNICA' USING ERRCODE = '22P02';
    END IF;
    IF p_checklist IS NOT NULL AND NOT public.checklist_es_valido(p_checklist) THEN
        RAISE EXCEPTION 'La lista de verificación no está completa' USING ERRCODE = '22P02';
    END IF;

    INSERT INTO public.revisiones (registro_id, tipo, revisado_por, checklist, observaciones)
    VALUES (p_registro_id, p_tipo, auth.uid(), p_checklist,
            nullif(btrim(coalesce(p_observaciones, '')), ''))
    RETURNING id INTO v_id;

    RETURN QUERY
    SELECT v_id, r.cobertura
      FROM public.registros r
     WHERE r.id = p_registro_id;
END;
$$;

REVOKE ALL ON FUNCTION public.registrar_revision(uuid, text, jsonb, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.registrar_revision(uuid, text, jsonb, text) TO authenticated;

-- ---------------------------------------------------------------------
--  5. CONFIRMAR_COMPRA — solo ADMIN y JEFE_SERVICIO (spec §4.4 y §6)
-- ---------------------------------------------------------------------
-- Completa los datos de factura que confirmó Ventas, deja registrado quién
-- y cuándo (el gancho para la consulta de ventas del hito siguiente) y
-- recalcula la cobertura de los registros ABIERTOS del equipo, que salen
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

    UPDATE public.equipos
       SET tipo_soporte   = p_tipo_soporte,
           numero_soporte = btrim(p_numero_soporte),
           fecha_emision  = p_fecha_emision,
           plazo_dias     = p_plazo_dias,
           compra_confirmada_por = auth.uid(),
           compra_confirmada_en  = now()
     WHERE id = p_equipo_id;

    -- Recalcular la cobertura de los registros abiertos con su última revisión.
    UPDATE public.registros r
       SET cobertura = c_resultado.nueva,
           motivo_anulacion_cobertura = c_resultado.motivo
      FROM (
        SELECT r2.id AS registro,
               public.calcular_cobertura(f.vence_el, public.hoy_local(r2.fecha_ingreso), v2.checklist) AS nueva,
               CASE WHEN public.calcular_cobertura(f.vence_el, public.hoy_local(r2.fecha_ingreso), v2.checklist) = 'ANULADA_POR_USO'
                    THEN public.motivo_anulacion(v2.checklist) END AS motivo
          FROM public.registros r2
          JOIN public.equipos f   ON f.id = r2.equipo_id
          CROSS JOIN LATERAL (
            SELECT checklist
              FROM public.revisiones vr
             WHERE vr.registro_id = r2.id
             ORDER BY revisado_en DESC, id DESC LIMIT 1) v2
         WHERE r2.equipo_id = p_equipo_id
           AND r2.estado NOT IN ('ENTREGADO', 'ANULADO')
      ) c_resultado
     WHERE r.id = c_resultado.registro;
END;
$$;

REVOKE ALL ON FUNCTION public.confirmar_compra(uuid, text, text, date, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.confirmar_compra(uuid, text, text, date, integer) TO authenticated;
