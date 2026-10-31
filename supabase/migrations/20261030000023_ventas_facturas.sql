-- =====================================================================
--  20261030000023_ventas_facturas.sql
--  Fase 2b, tarea 1: facturas de Ventas por CSV como segunda fuente de
--  verdad de la compra.
--    · ventas_facturas / lotes_importacion: solo ADMIN y JEFE las leen y
--      solo `importar_ventas` las escribe. Nada se borra.
--    · Una garantía TALLER se confirma sola cuando coinciden factura +
--      serial + documento del titular + fecha de emisión. Si algo difiere
--      queda para revisión del jefe; nunca se desestima sola y una compra
--      desestimada nunca se confirma sola.
--    · Una garantía VENTA solo se informa (v_garantias.verificacion).
-- =====================================================================

ALTER TABLE public.equipos
    ADD COLUMN compra_confirmada_via text
        CHECK (compra_confirmada_via IS NULL OR compra_confirmada_via IN ('MANUAL', 'VENTAS'));
UPDATE public.equipos SET compra_confirmada_via = 'MANUAL' WHERE compra_confirmada_por IS NOT NULL;

CREATE TABLE public.lotes_importacion (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    archivo      text NOT NULL CHECK (length(btrim(archivo)) BETWEEN 1 AND 200),
    filas_total  integer NOT NULL DEFAULT 0,
    filas_ok     integer NOT NULL DEFAULT 0,
    filas_error  integer NOT NULL DEFAULT 0,
    importado_por uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
    creado_en    timestamptz NOT NULL DEFAULT now()
);

-- Las columnas normalizadas repiten la expresión de `equipos` (Postgres no
-- admite funciones propias en columnas generadas).
CREATE TABLE public.ventas_facturas (
    id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    lote_id              uuid NOT NULL REFERENCES public.lotes_importacion(id),
    numero_factura       text NOT NULL CHECK (length(btrim(numero_factura)) BETWEEN 1 AND 40),
    factura_normalizada  text GENERATED ALWAYS AS
        (upper(regexp_replace(numero_factura, '[ -]', '', 'g'))) STORED,
    fecha_emision        date NOT NULL
        CHECK (fecha_emision >= DATE '2000-01-01' AND fecha_emision <= public.hoy_local()),
    tipo_documento       text CHECK (length(tipo_documento) <= 5),
    numero_documento     text NOT NULL CHECK (length(btrim(numero_documento)) BETWEEN 1 AND 30),
    documento_normalizado text GENERATED ALWAYS AS
        (upper(regexp_replace(coalesce(tipo_documento, '') || numero_documento, '[^A-Za-z0-9]', '', 'g'))) STORED,
    nombre_cliente       text CHECK (length(nombre_cliente) <= 150),
    numero_serie         text NOT NULL CHECK (length(btrim(numero_serie)) BETWEEN 3 AND 60),
    serie_normalizada    text GENERATED ALWAYS AS
        (upper(regexp_replace(numero_serie, '[ -]', '', 'g'))) STORED,
    modelo               text CHECK (length(modelo) <= 80),
    vendedor             text CHECK (length(vendedor) <= 80),
    importado_por        uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
    creado_en            timestamptz NOT NULL DEFAULT now(),
    actualizado_en       timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_ventas_factura_serie UNIQUE (factura_normalizada, serie_normalizada)
);

ALTER TABLE public.lotes_importacion ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ventas_facturas   ENABLE ROW LEVEL SECURITY;
CREATE POLICY lotes_lectura ON public.lotes_importacion
    FOR SELECT TO authenticated USING (public.mi_rol() IN ('ADMIN', 'JEFE_SERVICIO'));
CREATE POLICY ventas_lectura ON public.ventas_facturas
    FOR SELECT TO authenticated USING (public.mi_rol() IN ('ADMIN', 'JEFE_SERVICIO'));
REVOKE ALL ON public.lotes_importacion, public.ventas_facturas FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.lotes_importacion, public.ventas_facturas TO authenticated;

-- ---------------------------------------------------------------------
--  VERIFICACION_VENTA — COINCIDE / DIFIERE / SIN_VENTA (NULL sin soporte
--  o sin rol interno). SECURITY DEFINER: la tabla de ventas es solo de la
--  jefatura, pero el resultado de tres valores lo ve todo rol interno.
-- ---------------------------------------------------------------------
CREATE FUNCTION public.verificacion_venta(p_equipo_id uuid)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_res text;
BEGIN
    IF NOT public.tiene_rol('ADMIN', 'JEFE_SERVICIO', 'TECNICO', 'RECEPCION') THEN
        RETURN NULL;
    END IF;
    SELECT CASE
             WHEN e.numero_soporte IS NULL THEN NULL
             WHEN v.id IS NULL THEN 'SIN_VENTA'
             WHEN v.documento_normalizado = upper(regexp_replace(c.tipo_documento::text || c.documento,
                                                                 '[^A-Za-z0-9]', '', 'g'))
                  AND v.fecha_emision = e.fecha_emision THEN 'COINCIDE'
             ELSE 'DIFIERE' END
      INTO v_res
      FROM public.equipos e
      JOIN public.clientes c ON c.id = e.cliente_id
      LEFT JOIN public.ventas_facturas v
             ON v.serie_normalizada = e.serie_normalizada
            AND v.factura_normalizada = upper(regexp_replace(e.numero_soporte, '[ -]', '', 'g'))
     WHERE e.id = p_equipo_id;
    RETURN v_res;
END;
$$;
REVOKE ALL ON FUNCTION public.verificacion_venta(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.verificacion_venta(uuid) TO authenticated;

-- Interna (sin GRANT): confirma una garantía TALLER que coincide con la
-- venta, con la misma ruta que confirmar_compra (recalcula las órdenes).
CREATE FUNCTION public.confirmar_por_ventas(p_equipo_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    UPDATE public.equipos e
       SET compra_confirmada_por = auth.uid(),
           compra_confirmada_en  = now(),
           compra_confirmada_via = 'VENTAS'
     WHERE e.id = p_equipo_id
       AND e.origen = 'TALLER'
       AND e.compra_confirmada_por IS NULL
       AND e.compra_desestimada_por IS NULL
       AND public.verificacion_venta(e.id) = 'COINCIDE';
    IF NOT FOUND THEN
        RETURN false;
    END IF;
    PERFORM public.recalcular_cobertura_equipo(p_equipo_id);
    RETURN true;
END;
$$;
REVOKE ALL ON FUNCTION public.confirmar_por_ventas(uuid) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------
--  IMPORTAR_VENTAS — ADMIN y JEFE. Cada fila se valida sola: las buenas
--  se guardan aunque otras fallen. Idempotente por (factura, serial).
-- ---------------------------------------------------------------------
CREATE FUNCTION public.importar_ventas(p_archivo text, p_filas jsonb)
RETURNS TABLE (lote_id uuid, nuevas integer, actualizadas integer,
               con_error integer, confirmadas integer, errores jsonb)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_archivo text := btrim(coalesce(p_archivo, ''));
    v_lote    uuid;
    r         record;
    v_campo   text;
    v_fecha   date;
    v_nuevo   boolean;
    v_nuevas  integer := 0;
    v_actual  integer := 0;
    v_err     jsonb := '[]'::jsonb;
    v_conf    integer;
    v_total   integer;
BEGIN
    IF NOT public.tiene_rol('ADMIN', 'JEFE_SERVICIO') THEN
        RAISE EXCEPTION 'Solo ADMIN o JEFE_SERVICIO importan ventas' USING ERRCODE = '42501';
    END IF;
    IF v_archivo = '' THEN
        RAISE EXCEPTION 'Falta el nombre del archivo' USING ERRCODE = '22P02';
    END IF;
    IF jsonb_typeof(p_filas) IS DISTINCT FROM 'array' THEN
        RAISE EXCEPTION 'Las filas deben ser un arreglo JSON' USING ERRCODE = '22P02';
    END IF;
    v_total := jsonb_array_length(p_filas);
    IF v_total > 5000 THEN
        RAISE EXCEPTION 'Máximo 5000 filas por importación' USING ERRCODE = '22P02';
    END IF;

    INSERT INTO public.lotes_importacion (archivo, filas_total, importado_por)
    VALUES (v_archivo, v_total, auth.uid())
    RETURNING id INTO v_lote;

    FOR r IN SELECT f.v AS fila, f.n::integer AS n
               FROM jsonb_array_elements(p_filas) WITH ORDINALITY f(v, n) LOOP
        BEGIN
            v_campo := 'fila';
            IF jsonb_typeof(r.fila) <> 'object' THEN
                RAISE EXCEPTION 'La fila no es un objeto' USING ERRCODE = '22P02';
            END IF;
            v_campo := 'numero_factura';
            IF length(btrim(coalesce(r.fila->>'numero_factura', ''))) NOT BETWEEN 1 AND 40 THEN
                RAISE EXCEPTION 'La factura es obligatoria (hasta 40 caracteres)' USING ERRCODE = '22P02';
            END IF;
            v_campo := 'fecha_emision';
            v_fecha := (r.fila->>'fecha_emision')::date;
            IF v_fecha IS NULL OR v_fecha < DATE '2000-01-01' OR v_fecha > public.hoy_local() THEN
                RAISE EXCEPTION 'La fecha de emisión es obligatoria y no puede ser futura' USING ERRCODE = '22P02';
            END IF;
            v_campo := 'numero_documento';
            IF length(btrim(coalesce(r.fila->>'numero_documento', ''))) NOT BETWEEN 1 AND 30 THEN
                RAISE EXCEPTION 'El documento del cliente es obligatorio (hasta 30 caracteres)' USING ERRCODE = '22P02';
            END IF;
            v_campo := 'serial';
            IF length(btrim(coalesce(r.fila->>'serial', ''))) NOT BETWEEN 3 AND 60 THEN
                RAISE EXCEPTION 'El serial es obligatorio (3 a 60 caracteres)' USING ERRCODE = '22P02';
            END IF;

            v_campo := 'fila';
            INSERT INTO public.ventas_facturas
                (lote_id, numero_factura, fecha_emision, tipo_documento, numero_documento,
                 nombre_cliente, numero_serie, modelo, vendedor, importado_por)
            VALUES (v_lote, btrim(r.fila->>'numero_factura'), v_fecha,
                    nullif(btrim(coalesce(r.fila->>'tipo_documento', '')), ''),
                    btrim(r.fila->>'numero_documento'),
                    nullif(btrim(coalesce(r.fila->>'nombre_cliente', '')), ''),
                    btrim(r.fila->>'serial'),
                    nullif(btrim(coalesce(r.fila->>'modelo', '')), ''),
                    nullif(btrim(coalesce(r.fila->>'vendedor', '')), ''),
                    auth.uid())
            ON CONFLICT (factura_normalizada, serie_normalizada) DO UPDATE
               SET lote_id = EXCLUDED.lote_id, fecha_emision = EXCLUDED.fecha_emision,
                   tipo_documento = EXCLUDED.tipo_documento, numero_documento = EXCLUDED.numero_documento,
                   nombre_cliente = EXCLUDED.nombre_cliente, modelo = EXCLUDED.modelo,
                   vendedor = EXCLUDED.vendedor, importado_por = EXCLUDED.importado_por,
                   actualizado_en = now()
            RETURNING (xmax = 0) INTO v_nuevo;

            IF v_nuevo THEN v_nuevas := v_nuevas + 1; ELSE v_actual := v_actual + 1; END IF;
        EXCEPTION WHEN OTHERS THEN
            v_err := v_err || jsonb_build_array(jsonb_build_object(
                'fila', r.n, 'campo', v_campo, 'mensaje', SQLERRM));
        END;
    END LOOP;

    -- Las garantías TALLER pendientes que esta carga respalda.
    SELECT count(*) INTO v_conf
      FROM (SELECT public.confirmar_por_ventas(e.id) AS ok
              FROM public.ventas_facturas v
              JOIN public.equipos e
                ON e.serie_normalizada = v.serie_normalizada
               AND upper(regexp_replace(coalesce(e.numero_soporte, ''), '[ -]', '', 'g')) = v.factura_normalizada
             WHERE v.lote_id = v_lote
               AND e.origen = 'TALLER'
               AND e.compra_confirmada_por IS NULL
               AND e.compra_desestimada_por IS NULL) x
     WHERE x.ok;

    UPDATE public.lotes_importacion l
       SET filas_ok = v_nuevas + v_actual, filas_error = v_total - v_nuevas - v_actual
     WHERE l.id = v_lote;

    RETURN QUERY SELECT v_lote, v_nuevas, v_actual, v_total - v_nuevas - v_actual, v_conf, v_err;
END;
$$;
REVOKE ALL ON FUNCTION public.importar_ventas(text, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.importar_ventas(text, jsonb) TO authenticated;

-- ---------------------------------------------------------------------
--  confirmar_compra: deja la vía MANUAL (misma firma y reglas de la 0020).
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
           compra_confirmada_en  = now(),
           compra_confirmada_via = 'MANUAL'
     WHERE id = p_equipo_id;

    PERFORM public.recalcular_cobertura_equipo(p_equipo_id);
END;
$$;

-- ---------------------------------------------------------------------
--  registrar_garantia: si la venta ya estaba importada, una garantía
--  TALLER nueva nace confirmada (misma firma y reglas de la 0018).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.registrar_garantia(
    p_cliente_id      uuid,
    p_producto_id     uuid,
    p_serial          text,
    p_tipo_soporte    text DEFAULT NULL,
    p_numero_soporte  text DEFAULT NULL,
    p_fecha_emision   date DEFAULT NULL,
    p_plazo_dias      integer DEFAULT NULL,
    p_origen          text DEFAULT 'VENTA')
RETURNS TABLE (equipo_id uuid, vence_el date, equipo_nuevo boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_serial text := btrim(coalesce(p_serial, ''));
    v_equipo uuid;
BEGIN
    IF NOT public.tiene_rol('ADMIN', 'JEFE_SERVICIO', 'TECNICO', 'RECEPCION') THEN
        RAISE EXCEPTION 'Su rol no puede registrar garantías' USING ERRCODE = '42501';
    END IF;
    IF p_origen IS NULL OR p_origen NOT IN ('VENTA', 'TALLER') THEN
        RAISE EXCEPTION 'El origen debe ser VENTA o TALLER' USING ERRCODE = '22P02';
    END IF;
    IF length(v_serial) < 3 OR length(v_serial) > 60 THEN
        RAISE EXCEPTION 'El serial es obligatorio (3 a 60 caracteres)' USING ERRCODE = '22P02';
    END IF;
    IF p_plazo_dias IS NOT NULL AND p_plazo_dias NOT IN (7, 15)
       AND NOT public.tiene_rol('ADMIN', 'JEFE_SERVICIO') THEN
        RAISE EXCEPTION 'Los plazos distintos de 7 o 15 días solo los fija el jefe'
            USING ERRCODE = '42501';
    END IF;

    SELECT e.id INTO v_equipo
      FROM public.equipos e
     WHERE e.producto_id = p_producto_id
       AND e.serie_normalizada = public.normalizar_serie(v_serial);

    equipo_nuevo := v_equipo IS NULL;
    IF equipo_nuevo THEN
        INSERT INTO public.equipos (numero_serie, producto_id, cliente_id,
                                    tipo_soporte, numero_soporte, fecha_emision,
                                    plazo_dias, origen, registrado_por)
        VALUES (v_serial, p_producto_id, p_cliente_id,
                nullif(btrim(coalesce(p_tipo_soporte, '')), ''),
                nullif(btrim(coalesce(p_numero_soporte, '')), ''),
                p_fecha_emision, p_plazo_dias, p_origen, auth.uid())
        ON CONFLICT (producto_id, serie_normalizada) DO NOTHING
        RETURNING id INTO v_equipo;
        IF v_equipo IS NULL THEN          -- otro envío ganó la carrera
            equipo_nuevo := false;
            SELECT e.id INTO v_equipo FROM public.equipos e
             WHERE e.producto_id = p_producto_id
               AND e.serie_normalizada = public.normalizar_serie(v_serial);
        ELSE
            PERFORM public.confirmar_por_ventas(v_equipo);
        END IF;
    END IF;

    equipo_id := v_equipo;
    SELECT e.vence_el INTO vence_el FROM public.equipos e WHERE e.id = v_equipo;
    RETURN NEXT;
END;
$$;

-- ---------------------------------------------------------------------
--  v_garantias: dos columnas más al final (verificación y vía).
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_garantias
WITH (security_invoker = true) AS
SELECT e.id                               AS equipo_id,
       e.numero_serie,
       e.producto_id,
       (m.nombre || ' ' || pr.modelo)     AS producto,
       e.cliente_id                       AS titular_id,
       c.nombre                           AS titular,
       c.documento,
       e.numero_soporte,
       e.fecha_emision,
       e.plazo_dias,
       e.vence_el,
       (e.vence_el - public.hoy_local())  AS dias_restantes,
       e.origen,
       public.calcular_cobertura(
           e.vence_el, public.hoy_local(), NULL, e.origen,
           e.compra_confirmada_por IS NOT NULL,
           e.compra_desestimada_por IS NOT NULL)  AS vigencia,
       CASE WHEN e.compra_desestimada_por IS NOT NULL THEN 'DESESTIMADA'
            WHEN e.compra_confirmada_por IS NOT NULL OR e.origen = 'VENTA' THEN 'CONFIRMADA'
            ELSE 'PENDIENTE' END          AS estado_compra,
       public.verificacion_venta(e.id)    AS verificacion,
       e.compra_confirmada_via
  FROM public.equipos e
  JOIN public.productos pr ON pr.id = e.producto_id
  JOIN public.marcas m     ON m.id  = pr.marca_id
  JOIN public.clientes c   ON c.id  = e.cliente_id;
