-- =====================================================================
--  Prime Telecom · Track Garantía
--  Migración 7 — CORRECCIONES DE LA REVISIÓN DEL 2026-09-08
--  PostgreSQL 17 / Supabase
--
--  Todo lo de aquí es ADITIVO: no borra datos, no quita permisos que la
--  aplicación esté usando hoy y no cambia ninguna firma que el frontend
--  invoque. Son seis huecos encontrados leyendo el esquema contra el
--  frontend, en orden de gravedad.
--
--    §1  La cobertura no se recalcula al cambiar el tipo de garantía.
--    §2  `garantias` no tiene protección de COLUMNAS (solo de filas).
--    §3  `crear_orden()` acepta como "técnico" a cualquier perfil.
--    §4  `documentos_garantia` deja firmar una subida a nombre de otro.
--    §5  La búsqueda del tablero (`ilike %texto%`) no tiene índice usable.
--    §6  Índice de la FK `documentos_garantia.subido_por`.
--
--  ORDEN OBLIGATORIO: después de ...0006_documentos_garantia.sql.
-- =====================================================================

BEGIN;

-- =====================================================================
--  1. LA COBERTURA SE RECALCULA CUANDO CAMBIA LO QUE LA DETERMINA
-- =====================================================================
-- La migración ...0004 enseñó a `calcular_vencimiento_garantia()` a mirar
-- `tipo_garantia` y `meses_garantia_override`, pero NO amplió la lista de
-- columnas del trigger, que sigue siendo la de ...0002:
--     BEFORE INSERT OR UPDATE OF fecha_compra, producto_id
-- Consecuencia real, reproducible hoy: marcar una orden como SIN_GARANTIA
-- después de crearla no cambia nada -- `cobertura` sigue en EN_GARANTIA y
-- `garantia_vence_el` sigue apuntando a la fecha del catálogo. Y una
-- garantía EXTENDIDA a la que se le pone el plazo pactado después del alta
-- conserva el vencimiento del fabricante. El CHECK
-- `ck_extendida_declara_meses` deja pasar ambos casos porque solo mira que
-- el override no sea NULL, no que se haya aplicado.
--
-- Se recrea el trigger con la lista completa. La función no se toca.
DROP TRIGGER IF EXISTS trg_garantias_cobertura ON public.garantias;

CREATE TRIGGER trg_garantias_cobertura
    BEFORE INSERT OR UPDATE OF
        fecha_compra, producto_id, tipo_garantia, meses_garantia_override
    ON public.garantias
    FOR EACH ROW EXECUTE FUNCTION public.calcular_vencimiento_garantia();


-- =====================================================================
--  2. PROTECCIÓN DE COLUMNAS EN `garantias`
-- =====================================================================
-- `profiles` tiene dos capas: la RLS decide QUÉ FILA se toca y el trigger
-- `proteger_columnas_de_profile` decide QUÉ COLUMNAS. `garantias` solo
-- tiene la primera, y el GRANT es de tabla entera:
--     GRANT SELECT, UPDATE ON public.garantias TO authenticated;
-- Es decir: un TECNICO, sobre una orden que sí tiene asignada, puede hoy
-- reescribir `numero_orden` (el número que el cliente lleva en el papel),
-- `creado_por` (borrando quién la registró), `fecha_ingreso` (moviendo el
-- SLA a su favor) o `consulta_token_hash` (dejando fuera al titular). Nada
-- de eso es una transición de estado, así que no deja rastro en
-- `historial_garantias`.
--
-- Este trigger no quita permisos a nadie sobre lo que la aplicación sí
-- hace (estado, diagnóstico, cobertura, costo, prioridad, técnico...):
-- solo congela los campos de identidad y procedencia de la orden.
CREATE OR REPLACE FUNCTION public.proteger_columnas_de_garantia()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    -- Arranque en frío / backend, igual que en `proteger_columnas_de_profile`:
    -- `auth.uid()` es NULL en el SQL Editor, en una migración y con
    -- service_role, contextos que ya bypassean la RLS por definición.
    IF auth.uid() IS NULL THEN
        RETURN NEW;
    END IF;

    IF NEW.id IS DISTINCT FROM OLD.id THEN
        RAISE EXCEPTION 'El identificador de la orden es inmutable' USING ERRCODE = '42501';
    END IF;

    IF NEW.numero_orden IS DISTINCT FROM OLD.numero_orden THEN
        RAISE EXCEPTION 'El número de orden es el que tiene el cliente en la mano: no se edita'
            USING ERRCODE = '42501';
    END IF;

    IF NEW.creado_por IS DISTINCT FROM OLD.creado_por THEN
        RAISE EXCEPTION 'Quién registró la orden es un dato de auditoría: no se edita'
            USING ERRCODE = '42501';
    END IF;

    IF NEW.fecha_ingreso IS DISTINCT FROM OLD.fecha_ingreso THEN
        RAISE EXCEPTION 'La fecha de ingreso fija el SLA: no se edita' USING ERRCODE = '42501';
    END IF;

    -- El token solo lo rota `regenerar_token_orden()`, que se identifica
    -- con una marca LOCAL a la transacción (se borra sola al terminar).
    -- Mismo patrón que `pt.sync_email` en ...0001_auth_base.sql.
    IF NEW.consulta_token_hash IS DISTINCT FROM OLD.consulta_token_hash
       AND coalesce(current_setting('pt.rotar_token', TRUE), '') <> '1' THEN
        RAISE EXCEPTION 'El token de consulta se rota con regenerar_token_orden(), no con un UPDATE'
            USING ERRCODE = '42501';
    END IF;

    -- Cambiar de cliente o de equipo no es corregir una errata: es otra
    -- orden. Se deja, pero solo a quien supervisa.
    IF (NEW.cliente_id  IS DISTINCT FROM OLD.cliente_id
     OR NEW.producto_id IS DISTINCT FROM OLD.producto_id)
       AND NOT public.tiene_rol('ADMIN', 'JEFE_SERVICIO') THEN
        RAISE EXCEPTION 'Solo ADMIN o JEFE_SERVICIO pueden reasignar el cliente o el equipo de una orden'
            USING ERRCODE = '42501';
    END IF;

    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.proteger_columnas_de_garantia() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_proteger_garantia ON public.garantias;
CREATE TRIGGER trg_proteger_garantia
    BEFORE UPDATE ON public.garantias
    FOR EACH ROW EXECUTE FUNCTION public.proteger_columnas_de_garantia();

-- `regenerar_token_orden()` se reescribe solo para levantar la marca. El
-- resto del cuerpo es idéntico al de ...0005 (mismos roles, mismo rastro
-- en notas_internas, mismo contrato de salida).
CREATE OR REPLACE FUNCTION public.regenerar_token_orden(p_orden_id UUID)
RETURNS TABLE (
    numero_orden   TEXT,
    consulta_token TEXT   -- TEXTO PLANO. Otra vez: una sola oportunidad.
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_token TEXT;
    v_actor UUID := auth.uid();
    v_num   TEXT;
BEGIN
    IF NOT public.tiene_rol('ADMIN','JEFE_SERVICIO','RECEPCION') THEN
        RAISE EXCEPTION 'Su rol no puede regenerar el token de consulta'
            USING ERRCODE = '42501';
    END IF;

    v_token := encode(extensions.gen_random_bytes(16), 'hex');

    -- Marca local a la transacción: es la llave que reconoce
    -- `proteger_columnas_de_garantia` (§2). Se apaga en cuanto termina el
    -- UPDATE, así que no queda un permiso colgando en la sesión.
    PERFORM set_config('pt.rotar_token', '1', TRUE);

    UPDATE public.garantias g
       SET consulta_token_hash = extensions.digest(v_token, 'sha256')
     WHERE g.id = p_orden_id
    RETURNING g.numero_orden INTO v_num;

    PERFORM set_config('pt.rotar_token', '', TRUE);

    IF v_num IS NULL THEN
        RAISE EXCEPTION 'La orden % no existe', p_orden_id USING ERRCODE = 'P0002';
    END IF;

    INSERT INTO public.notas_internas (garantia_id, autor_id, nota)
    VALUES (p_orden_id, v_actor,
            'Token de consulta regenerado. El código entregado antes al cliente queda invalidado.');

    RETURN QUERY SELECT v_num, v_token;
END;
$$;

REVOKE ALL ON FUNCTION public.regenerar_token_orden(UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.regenerar_token_orden(UUID) TO authenticated;


-- =====================================================================
--  3. `crear_orden()`: el técnico asignado tiene que ser un técnico
-- =====================================================================
-- `p_tecnico_id` entra crudo y solo lo valida la FK contra `profiles`, que
-- acepta CUALQUIER perfil. Hoy una RECEPCION puede asignarle una orden al
-- ADMIN, a otra RECEPCION o a una cuenta dada de baja. Y esa orden queda
-- fuera de la bandeja de todo el mundo: la policy `gar_update_tecnico`
-- exige `tiene_rol('TECNICO') AND tecnico_asignado_id = auth.uid()`, así
-- que nadie con rol de técnico la puede tocar y el asignado tampoco,
-- porque no es técnico. Es una orden huérfana que nadie puede trabajar.
--
-- Se añade la comprobación al principio; el resto del cuerpo es el de
-- ...0004 sin un cambio.
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
    p_meses_override   INTEGER DEFAULT NULL,
    p_sla_dias         INTEGER DEFAULT 5,
    p_tecnico_id       UUID     DEFAULT NULL
)
RETURNS TABLE (
    orden_id       UUID,
    numero_orden   TEXT,
    consulta_token TEXT,
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

    -- NUEVO (§3 de esta migración).
    IF p_tecnico_id IS NOT NULL
       AND NOT EXISTS (
           SELECT 1 FROM public.profiles p
            WHERE p.id = p_tecnico_id AND p.role = 'TECNICO' AND p.is_active
       ) THEN
        RAISE EXCEPTION 'El técnico asignado no existe, no está activo o no es un técnico'
            USING ERRCODE = '22023';
    END IF;

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
        p_fecha_compra,
        v_actor
    )
    RETURNING garantias.id, garantias.numero_orden, v_token,
              garantias.cobertura, garantias.garantia_vence_el,
              v_cliente, v_producto;
END;
$$;

REVOKE ALL ON FUNCTION public.crear_orden(
    DATE, TEXT, UUID, JSONB, UUID, JSONB, TEXT, TEXT, TEXT,
    public.prioridad_orden, public.tipo_garantia, INTEGER, INTEGER, UUID
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.crear_orden(
    DATE, TEXT, UUID, JSONB, UUID, JSONB, TEXT, TEXT, TEXT,
    public.prioridad_orden, public.tipo_garantia, INTEGER, INTEGER, UUID
) TO authenticated;


-- =====================================================================
--  4. UN DOCUMENTO LO FIRMA QUIEN LO SUBE
-- =====================================================================
-- `documentos_garantia.subido_por` lo manda el navegador
-- (`documentos.js`: `subido_por: usuarioId`) y la policy solo comprueba el
-- ROL de quien inserta, no que la firma coincida con él. Cualquier
-- RECEPCION puede subir un documento a nombre del ADMIN. La tabla no tiene
-- UPDATE ni DELETE precisamente porque es evidencia; una evidencia que se
-- puede firmar con el nombre de otro no lo es.
--
-- Mismo patrón que `notas_insert` en ...0002 (`autor_id = auth.uid()`).
DROP POLICY IF EXISTS doc_gar_insert ON public.documentos_garantia;

CREATE POLICY doc_gar_insert ON public.documentos_garantia
    FOR INSERT
    TO authenticated
    WITH CHECK (
        public.tiene_rol('ADMIN','JEFE_SERVICIO','RECEPCION')
        AND subido_por = auth.uid()
    );


-- =====================================================================
--  5. LA BÚSQUEDA DEL TABLERO NECESITA ÍNDICES DE VERDAD
-- =====================================================================
-- El buscador manda `ilike.%texto%` sobre seis columnas
-- (`ordenes.js`: COLUMNAS_BUSQUEDA). Un patrón que empieza por comodín NO
-- puede usar un índice B-tree, ni siquiera con `text_pattern_ops`: el
-- índice `idx_clientes_nombre_trgm` de ...0002 se llama "trgm" pero es un
-- B-tree, y esa consulta hace un seq scan de `clientes` + `garantias` +
-- `productos` en cada tecla que el operador suelta.
--
-- pg_trgm sí sirve para `%texto%`, y es la extensión que el nombre de ese
-- índice prometía. Se crean los índices GIN sobre las columnas reales que
-- alimentan la vista del tablero.
CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA extensions;

CREATE INDEX IF NOT EXISTS idx_clientes_nombre_gin
    ON public.clientes USING gin (lower(nombre) extensions.gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_clientes_documento_gin
    ON public.clientes USING gin (documento extensions.gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_productos_modelo_gin
    ON public.productos USING gin (lower(modelo) extensions.gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_gar_numero_orden_gin
    ON public.garantias USING gin (numero_orden extensions.gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_gar_serie_gin
    ON public.garantias USING gin (numero_serie extensions.gin_trgm_ops)
    WHERE numero_serie IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_gar_factura_gin
    ON public.garantias USING gin (numero_factura extensions.gin_trgm_ops)
    WHERE numero_factura IS NOT NULL;

-- El B-tree que no puede servir a `%texto%` y que además miente en el
-- nombre. Se retira ahora que existe el GIN que sí lo hace.
DROP INDEX IF EXISTS public.idx_clientes_nombre_trgm;


-- =====================================================================
--  6. ÍNDICE DE LA FK QUE FALTABA
-- =====================================================================
-- Postgres no indexa las FK. Sin este índice, desactivar o tocar un perfil
-- hace un seq scan de `documentos_garantia`. Es el mismo criterio que ya
-- aplica §8 de ...0002_garantias.sql al resto de las FK.
CREATE INDEX IF NOT EXISTS idx_documentos_subido_por
    ON public.documentos_garantia (subido_por);

COMMIT;


-- =====================================================================
--  QUÉ NO ARREGLA ESTA MIGRACIÓN, Y POR QUÉ
-- =====================================================================
--
-- 1) `consultar_garantia()` toma la IP del PRIMER elemento de
--    `x-forwarded-for`, que es la cabecera que envía el CLIENTE. Un
--    atacante que rote ese valor en cada petición nunca acumula fallos y
--    el freno de fuerza bruta de 10 por 15 minutos no llega a activarse.
--    Lo correcto es tomar el ÚLTIMO elemento (el que añade el gateway) o
--    la cabecera que ponga el borde. No se cambia aquí porque el valor
--    correcto depende de qué proxy tenga delante el proyecto desplegado;
--    hay que comprobarlo contra el gateway real antes de tocarlo.
--
-- 2) `productos.categoria` es TEXT libre ('ROUTER', 'ONT', ...). Debería
--    ser una tabla-catálogo con FK, igual que `estados_garantia`, por la
--    misma razón que se normalizó marca/modelo: con texto libre, "ROUTER",
--    "Router" y "router" son tres categorías y el reporte por categoría no
--    existe. Es una migración con backfill de datos, no aditiva: se hace
--    aparte y con los datos delante.
--
-- 3) `consulta_publica_intentos` sigue creciendo sin techo. Necesita el
--    cron de purga que ya documenta ...0002 (nota 5 de post-instalación).
-- =====================================================================
