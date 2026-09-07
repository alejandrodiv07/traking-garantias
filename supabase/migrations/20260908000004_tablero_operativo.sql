-- =====================================================================
--  Prime Telecom · Track Garantía
--  Migración 4 — TABLERO OPERATIVO (Fase 2 del Blueprint Supabase)
--  PostgreSQL 17 / Supabase · 2026-09-08
--
--  Spec: docs/specs/2026-09-08-tablero-taller-design.md
--
--  QUÉ AÑADE
--   · prioridad, tipo_garantia, meses_garantia_override, sla_dias
--   · el ajuste del trigger de cobertura para honrar ambos
--   · crear_orden(): alta ATÓMICA de orden + cliente/producto nuevos
--   · v_ordenes_tablero + kpis_tablero(): la capa de lectura del tablero
--
--  QUÉ NO TOCA, A PROPÓSITO
--   · La numeración 'ORD-YYYY-NNNNNN' (ADR-010). La interfaz se subordina
--     a la verdad de los datos, no al revés.
--   · La máquina de estados, el historial y las policies de ...0002.
--
--  ORDEN OBLIGATORIO: después de ...0002_garantias.sql.
-- =====================================================================

BEGIN;

-- =====================================================================
--  1. TIPOS
-- =====================================================================

CREATE TYPE public.prioridad_orden AS ENUM ('BAJA','NORMAL','ALTA','URGENTE');

CREATE TYPE public.tipo_garantia AS ENUM (
    'ESTANDAR',      -- la del fabricante: productos.meses_garantia
    'EXTENDIDA',     -- plazo pactado aparte; exige meses_garantia_override
    'SIN_GARANTIA'   -- entra al taller sin cobertura: se factura siempre
);


-- =====================================================================
--  2. COLUMNAS OPERATIVAS
-- =====================================================================

ALTER TABLE public.garantias
  ADD COLUMN prioridad     public.prioridad_orden NOT NULL DEFAULT 'NORMAL',
  ADD COLUMN tipo_garantia public.tipo_garantia   NOT NULL DEFAULT 'ESTANDAR',

  -- Duración pactada en meses. NULL = usar productos.meses_garantia.
  ADD COLUMN meses_garantia_override SMALLINT
      CHECK (meses_garantia_override IS NULL
             OR meses_garantia_override BETWEEN 0 AND 120),

  -- Plazo de entrega comprometido, EN DÍAS desde el ingreso.
  -- NO se guarda la fecha límite: es un valor derivado, y un derivado
  -- almacenado se desincroniza de su origen sin que nada avise. La fecha
  -- se calcula en v_ordenes_tablero (§4). Misma regla que ya aplica
  -- PanelVencimientos.jsx al no guardar "faltan N días".
  ADD COLUMN sla_dias SMALLINT NOT NULL DEFAULT 5
      CHECK (sla_dias BETWEEN 1 AND 90),

  -- Una garantía extendida sin plazo declarado es una contradicción:
  -- 'EXTENDIDA' solo significa algo si dice hasta cuándo.
  ADD CONSTRAINT ck_extendida_declara_meses
      CHECK (tipo_garantia <> 'EXTENDIDA' OR meses_garantia_override IS NOT NULL);

COMMENT ON COLUMN public.garantias.sla_dias IS
'Plazo de entrega comprometido en días. La fecha límite se deriva: fecha_ingreso::date + sla_dias.';

-- NO se indexa (fecha_ingreso::date + sla_dias): el cast de timestamptz a
-- date es STABLE, no IMMUTABLE (depende de TimeZone), y Postgres rechaza la
-- expresión con "functions in index expression must be marked IMMUTABLE".
-- Tampoco hace falta: `idx_gar_abiertas_por_estado` (migración ...0002) ya
-- restringe el conjunto a las órdenes vivas, que es sobre el que se calcula
-- el plazo. Un índice que la consulta no puede usar es solo mantenimiento.

-- Índice parcial: solo las órdenes vivas se ordenan por prioridad. Las
-- cerradas son historia y no entran en el tablero.
CREATE INDEX idx_gar_prioridad
    ON public.garantias (prioridad, fecha_ingreso DESC)
    WHERE estado NOT IN ('ENTREGADO','ANULADO');


-- =====================================================================
--  3. CÁLCULO DE COBERTURA — ajuste
-- =====================================================================
-- Esta función YA estaba probada y en uso. Cambian dos cosas y solo dos:
--   a) el plazo pactado (override) gana sobre el del catálogo;
--   b) SIN_GARANTIA corta el cálculo antes de empezar.
-- Sin (b), una orden marcada sin garantía saldría EN_GARANTIA si la fecha
-- de compra es reciente, que es exactamente lo contrario de lo declarado.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.calcular_vencimiento_garantia()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_meses SMALLINT;
BEGIN
    IF NEW.tipo_garantia = 'SIN_GARANTIA' THEN
        -- La fecha de compra sigue siendo un dato real (sirve al histórico),
        -- pero la cobertura queda determinada desde el minuto cero.
        NEW.garantia_vence_el := NEW.fecha_compra;
        NEW.cobertura := 'FUERA_DE_GARANTIA';
        RETURN NEW;
    END IF;

    SELECT COALESCE(NEW.meses_garantia_override, p.meses_garantia)
      INTO v_meses
      FROM public.productos p
     WHERE p.id = NEW.producto_id;

    IF v_meses IS NULL THEN
        RAISE EXCEPTION 'El producto % no existe', NEW.producto_id
            USING ERRCODE = '23503';
    END IF;

    NEW.garantia_vence_el := NEW.fecha_compra + make_interval(months => v_meses);

    -- Solo se decide mientras siga POR_DETERMINAR. Una vez que un técnico
    -- la fija en ANULADA_POR_USO, ningún UPDATE la devuelve a EN_GARANTIA
    -- por acción de este trigger. Ya era así; se conserva.
    IF NEW.cobertura = 'POR_DETERMINAR' THEN
        NEW.cobertura := CASE
            WHEN NEW.garantia_vence_el >= now()::date THEN 'EN_GARANTIA'
            ELSE 'FUERA_DE_GARANTIA'
        END;
    END IF;

    RETURN NEW;
END;
$$;


-- =====================================================================
--  4. VISTA DE LECTURA DEL TABLERO
-- =====================================================================
-- security_invoker = true NO ES OPCIONAL.
-- Sin esa opción una vista se ejecuta con los privilegios de su DUEÑO y
-- bypassea TODA la RLS de §11 de ...0002_garantias.sql: cualquier
-- `authenticated` leería el taller entero al margen de sus políticas.
-- Con ella, la vista es exactamente tan restrictiva como `gar_select`.
-- Requiere PostgreSQL 15+; este proyecto está en 17.
--
-- QUÉ NO LLEVA, A PROPÓSITO: notas_internas, costo_reparacion,
-- diagnostico, motivo_anulacion_cobertura y consulta_token_hash. El
-- tablero es una LISTA. Una vista que trae de más es una filtración
-- esperando a un SELECT * mal filtrado.
-- =====================================================================
CREATE VIEW public.v_ordenes_tablero
WITH (security_invoker = true) AS
SELECT
    g.id,
    g.numero_orden,
    g.estado,
    e.nombre  AS estado_nombre,
    e.orden   AS estado_orden,
    e.es_final,
    g.cobertura,
    g.prioridad,
    g.numero_serie,
    g.numero_factura,
    g.fecha_ingreso,
    g.fecha_entrega,
    g.garantia_vence_el,
    g.sla_dias,
    (g.fecha_ingreso::date + g.sla_dias) AS sla_vence_el,  -- derivado, nunca guardado
    g.tecnico_asignado_id,
    c.nombre AS cliente,
    (c.tipo_documento || '-' || c.documento) AS documento,
    (m.nombre || ' ' || p.modelo)            AS equipo,
    p.categoria
FROM public.garantias g
JOIN public.estados_garantia e ON e.codigo = g.estado
JOIN public.clientes  c ON c.id = g.cliente_id
JOIN public.productos p ON p.id = g.producto_id
JOIN public.marcas    m ON m.id = p.marca_id;

COMMENT ON VIEW public.v_ordenes_tablero IS
'Lista del tablero. security_invoker: hereda la RLS de garantias. No expone notas, costos ni diagnóstico.';


-- =====================================================================
--  5. KPIs
-- =====================================================================
-- SECURITY INVOKER, y es DELIBERADO: al revés que mi_rol() o crear_orden(),
-- esta función solo CUENTA filas que el usuario ya puede ver. Con DEFINER
-- contaría también lo que la RLS le oculta, y la tarjeta mostraría un
-- número que la tabla de abajo no puede justificar.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.kpis_tablero()
RETURNS TABLE (
    ordenes_abiertas INTEGER,
    nuevas_semana    INTEGER,
    en_diagnostico   INTEGER,
    sla_por_vencer   INTEGER,
    por_vencer_30d   INTEGER,
    reparadas_mes    INTEGER,
    tasa_a_tiempo    NUMERIC
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
    WITH abiertas AS (
        SELECT * FROM public.garantias
         WHERE estado NOT IN ('ENTREGADO','ANULADO')
    ),
    mes AS (
        SELECT * FROM public.garantias
         WHERE fecha_entrega >= date_trunc('month', now())
    )
    SELECT
        (SELECT count(*) FROM abiertas)::INTEGER,
        (SELECT count(*) FROM abiertas
          WHERE fecha_ingreso > now() - interval '7 days')::INTEGER,
        (SELECT count(*) FROM abiertas WHERE estado = 'EN_DIAGNOSTICO')::INTEGER,
        (SELECT count(*) FROM abiertas
          WHERE fecha_ingreso::date + sla_dias <= now()::date + 2)::INTEGER,
        (SELECT count(*) FROM public.garantias
          WHERE garantia_vence_el BETWEEN now()::date AND now()::date + 30
            AND cobertura = 'EN_GARANTIA')::INTEGER,
        (SELECT count(*) FROM mes WHERE estado = 'ENTREGADO')::INTEGER,
        (SELECT COALESCE(round(100.0 * count(*) FILTER (
                    WHERE fecha_entrega::date <= fecha_ingreso::date + sla_dias
                 ) / NULLIF(count(*),0), 0), 0)
           FROM mes WHERE estado = 'ENTREGADO');
$$;


-- =====================================================================
--  6. ALTA DE ORDEN — atómica
-- =====================================================================
-- Sustituye a crear_garantia(). Se hace DROP y no sobrecarga: dos
-- funciones homónimas con parámetros por defecto producen ambigüedad de
-- resolución, y nada del frontend la invoca todavía.
--
-- LA ATOMICIDAD ES EL PUNTO ENTERO. Recibe cliente y producto O BIEN como
-- UUID existente O BIEN como datos nuevos, y resuelve el alta en la MISMA
-- transacción que la orden:
--   · si la orden falla, el cliente nuevo desaparece con ella (sin huérfanos);
--   · el ON CONFLICT usa las claves únicas REALES, así que dos
--     recepcionistas registrando a la vez al mismo cliente no producen un
--     duplicado ni un error en la cara del segundo.
--
-- El autocompletado del frontend sigue siendo imprescindible: la
-- atomicidad evita huérfanos, la búsqueda previa evita duplicados por
-- errata. Hacen falta las dos.
-- =====================================================================
DROP FUNCTION IF EXISTS public.crear_garantia(UUID, UUID, DATE, TEXT, TEXT, TEXT, TEXT);

CREATE OR REPLACE FUNCTION public.crear_orden(
    p_fecha_compra     DATE,
    p_falla_reportada  TEXT,
    p_cliente_id       UUID  DEFAULT NULL,
    p_cliente_nuevo    JSONB DEFAULT NULL,
    p_producto_id      UUID  DEFAULT NULL,
    p_producto_nuevo   JSONB DEFAULT NULL,
    p_numero_serie     TEXT  DEFAULT NULL,
    p_numero_factura   TEXT  DEFAULT NULL,
    p_accesorios       TEXT  DEFAULT NULL,
    p_prioridad        public.prioridad_orden DEFAULT 'NORMAL',
    p_tipo_garantia    public.tipo_garantia   DEFAULT 'ESTANDAR',
    -- INTEGER y no SMALLINT a propósito: en notación con nombre, un literal
    -- entero NO resuelve contra un parámetro SMALLINT (int4 -> int2 no es una
    -- conversión implícita) y la llamada muere con
    -- "42883 function crear_orden(...) does not exist", que no dice nada.
    -- Se recibe INTEGER, se convierte al insertar y el CHECK de la columna
    -- sigue siendo quien rechaza los valores fuera de rango.
    p_meses_override   INTEGER DEFAULT NULL,
    p_sla_dias         INTEGER DEFAULT 5,
    p_tecnico_id       UUID     DEFAULT NULL
)
RETURNS TABLE (
    orden_id       UUID,
    numero_orden   TEXT,
    consulta_token TEXT,   -- TEXTO PLANO. Se devuelve UNA vez. Imprimir y olvidar.
    cobertura      public.cobertura_garantia,
    vence_el       DATE,
    cliente_id     UUID,
    producto_id    UUID
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_token    TEXT;
    v_actor    UUID := auth.uid();
    v_cliente  UUID;
    v_producto UUID;
BEGIN
    IF NOT public.tiene_rol('ADMIN','JEFE_SERVICIO','RECEPCION') THEN
        RAISE EXCEPTION 'Su rol no puede registrar órdenes' USING ERRCODE = '42501';
    END IF;

    -- ---------- Cliente: exactamente uno de los dos caminos ----------
    IF (p_cliente_id IS NULL) = (p_cliente_nuevo IS NULL) THEN
        RAISE EXCEPTION 'Indique un cliente existente o los datos de uno nuevo, no ambos'
            USING ERRCODE = '22023';
    END IF;

    IF p_cliente_id IS NOT NULL THEN
        v_cliente := p_cliente_id;
    ELSE
        INSERT INTO public.clientes (tipo_documento, documento, nombre, telefono, email)
        VALUES (
            (p_cliente_nuevo->>'tipo_documento')::public.tipo_documento,
            btrim(p_cliente_nuevo->>'documento'),
            btrim(p_cliente_nuevo->>'nombre'),
            nullif(btrim(coalesce(p_cliente_nuevo->>'telefono','')),''),
            nullif(lower(btrim(coalesce(p_cliente_nuevo->>'email',''))),'')
        )
        ON CONFLICT (tipo_documento, documento) DO UPDATE
            SET updated_at = now()
        RETURNING id INTO v_cliente;
    END IF;

    -- ---------- Producto: mismo patrón ----------
    IF (p_producto_id IS NULL) = (p_producto_nuevo IS NULL) THEN
        RAISE EXCEPTION 'Indique un producto existente o los datos de uno nuevo, no ambos'
            USING ERRCODE = '22023';
    END IF;

    IF p_producto_id IS NOT NULL THEN
        v_producto := p_producto_id;
    ELSE
        INSERT INTO public.productos (marca_id, modelo, categoria, meses_garantia)
        VALUES (
            (p_producto_nuevo->>'marca_id')::UUID,
            btrim(p_producto_nuevo->>'modelo'),
            btrim(p_producto_nuevo->>'categoria'),
            COALESCE((p_producto_nuevo->>'meses_garantia')::SMALLINT, 12)
        )
        ON CONFLICT (marca_id, lower(btrim(modelo))) DO UPDATE
            SET updated_at = now()
        RETURNING id INTO v_producto;
    END IF;

    -- 128 bits del CSPRNG del sistema. Existe en claro AQUÍ y en ningún
    -- otro sitio: en la tabla solo queda su SHA-256.
    v_token := encode(extensions.gen_random_bytes(16), 'hex');

    RETURN QUERY
    INSERT INTO public.garantias (
        consulta_token_hash, cliente_id, producto_id, fecha_compra,
        falla_reportada, numero_serie, numero_factura, accesorios,
        prioridad, tipo_garantia, meses_garantia_override, sla_dias,
        tecnico_asignado_id, garantia_vence_el, creado_por
    )
    VALUES (
        extensions.digest(v_token, 'sha256'),
        v_cliente, v_producto, p_fecha_compra,
        btrim(p_falla_reportada),
        nullif(btrim(coalesce(p_numero_serie,'')),''),
        nullif(btrim(coalesce(p_numero_factura,'')),''),
        nullif(btrim(coalesce(p_accesorios,'')),''),
        p_prioridad, p_tipo_garantia, p_meses_override::SMALLINT,
        COALESCE(p_sla_dias, 5)::SMALLINT,
        p_tecnico_id,
        p_fecha_compra,          -- el trigger §3 lo recalcula
        v_actor
    )
    RETURNING garantias.id, garantias.numero_orden, v_token,
              garantias.cobertura, garantias.garantia_vence_el,
              v_cliente, v_producto;
END;
$$;

COMMENT ON FUNCTION public.crear_orden IS
'Alta atómica de orden. Devuelve el token de consulta EN CLARO una sola vez: si no se entrega al cliente, se pierde.';


-- =====================================================================
--  7. GRANTS — cerrar antes de abrir
-- =====================================================================
-- Supabase configura ALTER DEFAULT PRIVILEGES que concede permisos sobre
-- cada objeto NUEVO del esquema `public` a `anon` y `authenticated`. La
-- vista y las dos funciones nacen AHORA, así que hay que revocarlas
-- nombrando a esos roles: un REVOKE a PUBLIC deja la concesión directa
-- intacta y el fichero mentiría sobre lo que hace.
-- =====================================================================

REVOKE ALL ON public.v_ordenes_tablero FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.v_ordenes_tablero TO authenticated;

REVOKE ALL ON FUNCTION public.kpis_tablero() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.kpis_tablero() TO authenticated;

REVOKE ALL ON FUNCTION public.crear_orden(
    DATE, TEXT, UUID, JSONB, UUID, JSONB, TEXT, TEXT, TEXT,
    public.prioridad_orden, public.tipo_garantia, INTEGER, INTEGER, UUID
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.crear_orden(
    DATE, TEXT, UUID, JSONB, UUID, JSONB, TEXT, TEXT, TEXT,
    public.prioridad_orden, public.tipo_garantia, INTEGER, INTEGER, UUID
) TO authenticated;

COMMIT;
