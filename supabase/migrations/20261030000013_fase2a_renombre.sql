-- =====================================================================
--  20261030000013_fase2a_renombre.sql
--  Renombre mecánico del Hito 1 hacia los nombres de la fase 2a
--  (spec §5.1): `registros` → `ordenes_servicio`, `numero_registro`
--  (REG-AAAA-NNNNNN) → `numero_orden` (OS-AAAA-NNNN, mismo mecanismo
--  de secuencia nativa), `historial_registros` → `historial_ordenes`,
--  `registrar_ingreso` → `abrir_orden`. Sin cambio de comportamiento:
--  los cuerpos son los de las migraciones fuente con SOLO los nombres
--  cambiados. Los datos existentes son de prueba: no se conservan.
-- =====================================================================

-- ---------------------------------------------------------------------
--  1. TABLAS
-- ---------------------------------------------------------------------
ALTER TABLE public.registros        RENAME TO ordenes_servicio;
ALTER TABLE public.historial_registros RENAME TO historial_ordenes;

-- ---------------------------------------------------------------------
--  2. COLUMNAS (las FK e índices siguen la columna renombrada: es la
--     misma posición, la definición textual se actualiza sola)
-- ---------------------------------------------------------------------
ALTER TABLE public.ordenes_servicio      RENAME COLUMN numero_registro TO numero_orden;
ALTER TABLE public.historial_ordenes     RENAME COLUMN registro_id     TO orden_id;
ALTER TABLE public.consulta_publica_intentos RENAME COLUMN numero_registro TO numero_orden;
ALTER TABLE public.revisiones            RENAME COLUMN registro_id     TO orden_id;
ALTER TABLE public.adjuntos              RENAME COLUMN registro_id     TO orden_id;
ALTER TABLE public.notas_internas        RENAME COLUMN registro_id     TO orden_id;

-- ---------------------------------------------------------------------
--  3. SECUENCIA Y CORRELATIVO OS-AAAA-NNNN (4 dígitos, prefix OS-)
--  Correlativo legible desde una SEQUENCE nativa. `nextval` en el
--  DEFAULT es atómico: dos técnicos que registren en el mismo segundo
--  toman números distintos sin carreras. Los huecos por transacciones
--  revertidas se aceptan: lo que importa es que el número sea único.
-- ---------------------------------------------------------------------
ALTER SEQUENCE public.registros_numero_seq RENAME TO ordenes_numero_seq;

ALTER TABLE public.ordenes_servicio
    ALTER COLUMN numero_orden
    SET DEFAULT ('OS-' || to_char(now(), 'YYYY') || '-'
                 || lpad(nextval('public.ordenes_numero_seq')::text, 4, '0'));

-- ---------------------------------------------------------------------
--  4. TRIGGERS VIEJOS (la tabla ya está renombrada; los triggers
--     siguen colgados de ella con sus nombres viejos)
-- ---------------------------------------------------------------------
DROP TRIGGER trg_registros_historial        ON public.ordenes_servicio;
DROP TRIGGER trg_registros_updated_at       ON public.ordenes_servicio;
DROP TRIGGER trg_validar_transicion_registro ON public.ordenes_servicio;
DROP TRIGGER trg_historial_registros_inmutable ON public.historial_ordenes;
-- El trigger de cobertura de revisiones apunta a una función renombrada
-- (abajo): se suelta aquí y vuelve con el mismo nombre tras la re-creación.
DROP TRIGGER trg_revisiones_cobertura ON public.revisiones;

-- Las funciones cuya firma el renombre NO toca se re-ejecutan como
-- CREATE OR REPLACE (abajo); las renombradas, o con renombre en el
-- RETURNS, llevan firma idéntica a la original y se retiran ANTES de
-- crear la versión nueva (si no, la creación colisiona con la firma
-- vieja). La retirada va después de soltar los triggers que las usaban.
DROP FUNCTION public.registrar_historial_registro();
DROP FUNCTION public.historial_registros_es_inmutable();
DROP FUNCTION public.actualizar_cobertura_registro();
DROP FUNCTION public.buscar_equipo(text);
DROP FUNCTION public.consultar_registro(text, text);
DROP FUNCTION public.registrar_revision(uuid, text, jsonb, text);
DROP FUNCTION public.registrar_ingreso(text, uuid, uuid, text, text, text, text, date, integer, text, jsonb, text, timestamptz, uuid);

-- ---------------------------------------------------------------------
--  5. FUNCIONES NUEVAS (cuerpos fuente con solo los nombres cambiados)
-- ---------------------------------------------------------------------
-- ---- Escritura del historial (AFTER INSERT OR UPDATE OF estado) ----
CREATE FUNCTION public.registrar_historial_orden()
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
                nullif(btrim(coalesce(NEW.diagnostico, '')), ''));
    END IF;

    RETURN NEW;
END;
$$;

-- Inmutabilidad del historial: ni service_role ni el dueño lo editan.
CREATE FUNCTION public.historial_ordenes_es_inmutable()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
    RAISE EXCEPTION 'historial_ordenes es de solo anexado: % no está permitido', TG_OP
        USING ERRCODE = '42501';
END;
$$;

-- ---- RESULTADO: lo calcula la base (BEFORE INSERT), cuerpos de la 0007 ----
-- Precedencia del spec §4.2 aplicada a los DATOS del equipo: el vencimiento
-- sale de la fecha de emisión guardada en el equipo, el día de ingreso de
-- orden.fecha_ingreso evaluado en Caracas (hoy_local).
CREATE OR REPLACE FUNCTION public.fijar_resultado_revision()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
    v_registro RECORD;
BEGIN
    SELECT e.vence_el, public.hoy_local(r.fecha_ingreso) AS ingreso
      INTO v_registro
      FROM public.ordenes_servicio r
      JOIN public.equipos e ON e.id = r.equipo_id
     WHERE r.id = NEW.orden_id;

    IF v_registro IS NULL THEN
        RAISE EXCEPTION 'La revisión apunta a un registro inexistente'
            USING ERRCODE = '23503';
    END IF;

    -- Lo que el cliente haya puesto en NEW.resultado queda descartado.
    NEW.resultado := public.calcular_cobertura(v_registro.vence_el, v_registro.ingreso, NEW.checklist);
    RETURN NEW;
END;
$$;

-- ---- COBERTURA DE LA ORDEN (AFTER INSERT): cuerpo de la 0007 ----
-- La cobertura de la orden pasa al resultado de SU ÚLTIMA revisión; una
-- revisión posterior puede cambiarla (por ejemplo, de POR_DETERMINAR a
-- EN_GARANTIA al confirmar la compra, o a ANULADA_POR_USO al ver golpes).
CREATE FUNCTION public.actualizar_cobertura_orden()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
    UPDATE public.ordenes_servicio
       SET cobertura = NEW.resultado,
           motivo_anulacion_cobertura =
               CASE WHEN NEW.resultado = 'ANULADA_POR_USO'
                    THEN public.motivo_anulacion(NEW.checklist)
               END
     WHERE id = NEW.orden_id;
    RETURN NEW;
END;
$$;

-- trg_revisiones_resultado no se toca: apunta a fijar_resultado_revision,
-- que sigue llamándose igual (solo cambió su cuerpo).

CREATE TRIGGER trg_revisiones_cobertura
    AFTER INSERT ON public.revisiones
    FOR EACH ROW EXECUTE FUNCTION public.actualizar_cobertura_orden();

-- ---- Validación del archivo (BEFORE INSERT): idéntica a la 0008 ----
CREATE OR REPLACE FUNCTION public.validar_adjunto()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
    v_fotos   INTEGER;
    v_docs    INTEGER;
    v_tope    CONSTANT INTEGER := 8 * 1024 * 1024;   -- 8 MB
BEGIN
    -- Tipo de archivo según uso.
    IF NEW.tipo = 'FOTO' THEN
        IF NEW.mime NOT IN ('image/jpeg', 'image/png', 'image/webp') THEN
            RAISE EXCEPTION
                'Formato no admitido para FOTO: usa JPG, PNG o WEBP (recibido: %)', NEW.mime
                USING ERRCODE = '22P02';
        END IF;
    ELSE  -- DOCUMENTO
        IF NEW.mime NOT IN ('application/pdf', 'image/jpeg', 'image/png') THEN
            RAISE EXCEPTION
                'Formato no admitido para DOCUMENTO: usa PDF, JPG o PNG (recibido: %)', NEW.mime
                USING ERRCODE = '22P02';
        END IF;
    END IF;

    -- Tamaño.
    IF NEW.bytes > v_tope THEN
        RAISE EXCEPTION
            'El archivo no puede pesar más de 8 MB (recibido: %), y el límite es común a fotos y documentos',
            round(NEW.bytes / (1024.0 * 1024), 1)
            USING ERRCODE = '22P02';
    END IF;

    -- Cantidad por orden: 8 fotos, 6 documentos.
    SELECT count(*) FILTER (WHERE tipo = 'FOTO') INTO v_fotos
      FROM public.adjuntos WHERE orden_id = NEW.orden_id;
    IF NEW.tipo = 'FOTO' AND v_fotos >= 8 THEN
        RAISE EXCEPTION 'El registro ya tiene 8 fotos: no se admiten más'
            USING ERRCODE = '22P02';
    END IF;
    SELECT count(*) FILTER (WHERE tipo = 'DOCUMENTO') INTO v_docs
      FROM public.adjuntos WHERE orden_id = NEW.orden_id;
    IF NEW.tipo = 'DOCUMENTO' AND v_docs >= 6 THEN
        RAISE EXCEPTION 'El registro ya tiene 6 documentos: no se admiten más'
            USING ERRCODE = '22P02';
    END IF;

    RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------
--  BUSCAR_EQUIPO — por serial en TODOS los productos (spec §5.1)
--     Devuelve también el historial de registros del equipo, para el
--     asistente (paso 1) y la advertencia de serial en otro producto.
-- ---------------------------------------------------------------------
CREATE FUNCTION public.buscar_equipo(p_serial text)
RETURNS TABLE (
    equipo_id        uuid,
    producto_id      uuid,
    producto         text,
    numero_serie     text,
    titular_id       uuid,
    titular          text,
    vence_el         date,
    dias_restantes   integer,
    ordenes_servicio jsonb
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
                              'numero',  r.numero_orden,
                              'estado',  r.estado,
                              'ingreso', r.fecha_ingreso::text,
                              'cobertura', r.cobertura::text)
                          ORDER BY r.fecha_ingreso)
                 FROM public.ordenes_servicio r
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
--  ABRIR_ORDEN — la transacción completa; cuerpo EXACTO de la 0012
--  (idempotencia por clave de envío, revisión de ingeniería H1/H2).
--
--  Un doble clic, o un reintento tras un timeout, creaba dos registros
--  (cada uno con su token) para el mismo ingreso. Ahora el asistente
--  genera una clave por envío (uuid) y la base devuelve el registro
--  original si el mismo usuario la repite. Sin clave (NULL) el
--  comportamiento no cambia. Crea o reutiliza el equipo (ON CONFLICT,
--  sin carreras), crea la orden con su correlativo, inserta la revisión
--  de RECEPCION (que fija la cobertura a través de los triggers de
--  revisiones) y devuelve el token de consulta UNA VEZ. Todo en una
--  transacción: si algo falla, nada queda.
-- ---------------------------------------------------------------------
CREATE FUNCTION public.abrir_orden(
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
    orden_id        uuid,
    numero_orden    text,
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
        SELECT r.id, r.numero_orden, NULL::text, r.cobertura, r.equipo_id, false
          FROM public.ordenes_servicio r
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

    -- ---- Orden ----
    v_token := encode(extensions.gen_random_bytes(16), 'hex');

    INSERT INTO public.ordenes_servicio (equipo_id, falla_reportada, accesorios,
                                  cobertura, tecnico_asignado_id, creado_por,
                                  consulta_token_hash, fecha_ingreso, clave_envio)
    VALUES (v_equipo, v_falla,
            nullif(btrim(coalesce(p_accesorios, '')), ''),
            'POR_DETERMINAR',
            CASE WHEN v_rol = 'TECNICO' THEN v_actor END,
            v_actor,
            extensions.digest(v_token, 'sha256'),
            -- La fecha de ingreso la manda SOLO el ADMIN (backoffice, corrida
            -- a medianoche): a los demás roles se les ignora en silencio y
            -- reciben el DEFAULT now(). (Cierre de D4/3: esta función de la
            -- 0012 es la que queda viva tras el DROP de la 0009.)
            coalesce(CASE WHEN public.tiene_rol('ADMIN') THEN p_fecha_ingreso END, now()), p_clave_envio)
    RETURNING id INTO v_registro;

    -- ---- Primera revisión: la de recepción ----
    INSERT INTO public.revisiones (orden_id, tipo, revisado_por, checklist, observaciones)
    VALUES (v_registro, 'RECEPCION', v_actor, p_checklist,
            nullif(btrim(coalesce(p_observaciones, '')), ''));

    -- La cobertura la acaba de escribir el trigger de las revisiones.
    RETURN QUERY
    SELECT r.id, r.numero_orden, v_token, r.cobertura, v_equipo, v_nuevo
      FROM public.ordenes_servicio r
     WHERE r.id = v_registro;
END;
$$;

REVOKE ALL ON FUNCTION public.abrir_orden(text, uuid, uuid, text, text, text, text, date, integer, text, jsonb, text, timestamptz, uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.abrir_orden(text, uuid, uuid, text, text, text, text, date, integer, text, jsonb, text, timestamptz, uuid)
  TO authenticated;

-- ---------------------------------------------------------------------
--  REGISTRAR_REVISION — añade una revisión a una orden existente
--     (spec §6: ADMIN, JEFE_SERVICIO y TECNICO; RECEPCION no)
-- ---------------------------------------------------------------------
CREATE FUNCTION public.registrar_revision(
    p_orden_id      uuid,
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

    INSERT INTO public.revisiones (orden_id, tipo, revisado_por, checklist, observaciones)
    VALUES (p_orden_id, p_tipo, auth.uid(), p_checklist,
            nullif(btrim(coalesce(p_observaciones, '')), ''))
    RETURNING id INTO v_id;

    RETURN QUERY
    SELECT v_id, r.cobertura
      FROM public.ordenes_servicio r
     WHERE r.id = p_orden_id;
END;
$$;

REVOKE ALL ON FUNCTION public.registrar_revision(uuid, text, jsonb, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.registrar_revision(uuid, text, jsonb, text) TO authenticated;

-- ---------------------------------------------------------------------
--  CONFIRMAR_COMPRA — solo ADMIN y JEFE_SERVICIO (spec §4.4 y §6)
-- ---------------------------------------------------------------------
-- Completa los datos de factura que confirmó Ventas, deja registrado quién
-- y cuándo (el gancho para la consulta de ventas del hito siguiente) y
-- recalcula la cobertura de las órdenes ABIERTAS del equipo, que salen
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

    -- Recalcular la cobertura de las órdenes abiertas con su última revisión.
    UPDATE public.ordenes_servicio r
       SET cobertura = c_resultado.nueva,
           motivo_anulacion_cobertura = c_resultado.motivo
      FROM (
        SELECT r2.id AS orden,
               public.calcular_cobertura(f.vence_el, public.hoy_local(r2.fecha_ingreso), v2.checklist) AS nueva,
               CASE WHEN public.calcular_cobertura(f.vence_el, public.hoy_local(r2.fecha_ingreso), v2.checklist) = 'ANULADA_POR_USO'
                    THEN public.motivo_anulacion(v2.checklist) END AS motivo
          FROM public.ordenes_servicio r2
          JOIN public.equipos f   ON f.id = r2.equipo_id
          CROSS JOIN LATERAL (
            SELECT checklist
              FROM public.revisiones vr
             WHERE vr.orden_id = r2.id
             ORDER BY revisado_en DESC, id DESC LIMIT 1) v2
         WHERE r2.equipo_id = p_equipo_id
           AND r2.estado NOT IN ('ENTREGADO', 'ANULADO')
      ) c_resultado
     WHERE r.id = c_resultado.orden;
END;
$$;

REVOKE ALL ON FUNCTION public.confirmar_compra(uuid, text, text, date, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.confirmar_compra(uuid, text, text, date, integer) TO authenticated;

-- ---------------------------------------------------------------------
--  CONSULTA PÚBLICA: consultar_registro (se conserva el nombre; el
--  RETURNS y el cuerpo van con `numero_orden`)
-- ---------------------------------------------------------------------
-- Sin interfaz en este hito: la pantalla llega después, la base ya queda.
CREATE FUNCTION public.consultar_registro(
    p_numero_orden TEXT,
    p_token        TEXT
)
RETURNS TABLE (
    numero_orden    TEXT,
    estado          TEXT,
    estado_nombre   TEXT,
    equipo          TEXT,
    falla_reportada TEXT,
    diagnostico     TEXT,
    cobertura       public.cobertura_garantia,
    fecha_ingreso   TIMESTAMPTZ,
    fecha_entrega   TIMESTAMPTZ,
    actualizado_en  TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_ip       INET;
    v_fallos   INTEGER;
    v_rid      UUID;
BEGIN
    -- IP real del cliente (PostgREST expone las cabeceras del request).
    BEGIN
        v_ip := nullif(btrim(split_part(
                    coalesce(current_setting('request.headers', TRUE)::json ->> 'x-forwarded-for', ''),
                    ',', 1)), '')::inet;
    EXCEPTION WHEN OTHERS THEN
        v_ip := NULL;
    END;

    -- Freno de fuerza bruta (portado sin cambios).
    SELECT count(*) INTO v_fallos
      FROM public.consulta_publica_intentos c
     WHERE c.ip = v_ip
       AND NOT c.exito
       AND c.intentado_en > now() - interval '15 minutes';

    IF v_ip IS NOT NULL AND v_fallos >= 10 THEN
        INSERT INTO public.consulta_publica_intentos (ip, numero_orden, exito)
        VALUES (v_ip, p_numero_orden, FALSE);
        RAISE EXCEPTION 'Demasiadas consultas fallidas. Intente de nuevo en 15 minutos.'
            USING ERRCODE = '53400';
    END IF;

    -- Búsqueda POR EL HASH: cero filas responde igual a "no existe" que a
    -- "token incorrecto" (anti-enumeración) y el intento queda en bitácora.
    SELECT r.id INTO v_rid
      FROM public.ordenes_servicio r
     WHERE r.consulta_token_hash = extensions.digest(coalesce(p_token, ''), 'sha256')
       AND r.numero_orden = upper(btrim(coalesce(p_numero_orden, '')));

    INSERT INTO public.consulta_publica_intentos (ip, numero_orden, exito)
    VALUES (v_ip, p_numero_orden, v_rid IS NOT NULL);

    IF v_rid IS NULL THEN
        RETURN;
    END IF;

    RETURN QUERY
    SELECT r.numero_orden,
           r.estado,
           e.nombre,
           (m.nombre || ' ' || pr.modelo)::TEXT,
           r.falla_reportada,
           r.diagnostico,
           r.cobertura,
           r.fecha_ingreso,
           r.fecha_entrega,
           r.updated_at
      FROM public.ordenes_servicio r
      JOIN public.estados_garantia e ON e.codigo = r.estado
      JOIN public.equipos eq         ON eq.id = r.equipo_id
      JOIN public.productos pr       ON pr.id = eq.producto_id
      JOIN public.marcas m           ON m.id = pr.marca_id
     WHERE r.id = v_rid;
END;
$$;

REVOKE ALL ON FUNCTION public.consultar_registro(TEXT, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.consultar_registro(TEXT, TEXT) TO anon, authenticated;

-- ---------------------------------------------------------------------
--  LIMPIEZA DE ARCHIVOS HUÉRFANOS (cuerpo fuente de la 0011): el único
--  flujo que BORRA archivos, y solo los del almacenamiento que NO
--  tienen fila en `adjuntos` y ya tienen más de 24 horas (no se tocan
--  subidas en curso). Las filas de `adjuntos` nunca se tocan aquí.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.listar_huerfanos(p_gracia interval DEFAULT interval '24 hours')
RETURNS TABLE (nombre text)
LANGUAGE sql
STABLE
AS $$
  SELECT o.name
    FROM storage.objects o
   WHERE o.bucket_id = 'ordenes'
     AND o.created_at < now() - p_gracia
     AND NOT EXISTS (SELECT 1 FROM public.adjuntos a WHERE a.ruta = o.name);
$$;

-- Solo la ejecuta el borrador programado (la Edge Function con service_role).
REVOKE ALL ON FUNCTION public.listar_huerfanos(interval)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.listar_huerfanos(interval) TO service_role;

-- ---------------------------------------------------------------------
--  6. TRIGGERS NUEVOS (portados de §7 del Hito 1)
-- ---------------------------------------------------------------------
CREATE TRIGGER trg_ordenes_historial
    AFTER INSERT OR UPDATE OF estado ON public.ordenes_servicio
    FOR EACH ROW EXECUTE FUNCTION public.registrar_historial_orden();

CREATE TRIGGER trg_historial_ordenes_inmutable
    BEFORE UPDATE OR DELETE ON public.historial_ordenes
    FOR EACH ROW EXECUTE FUNCTION public.historial_ordenes_es_inmutable();

CREATE TRIGGER trg_ordenes_updated_at
    BEFORE UPDATE ON public.ordenes_servicio
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE TRIGGER trg_validar_transicion_orden
    BEFORE UPDATE OF estado ON public.ordenes_servicio
    FOR EACH ROW EXECUTE FUNCTION public.validar_transicion_estado();

-- ---------------------------------------------------------------------
--  7. CHECK DE LA RUTA DE ADJUNTOS: pasa de registros/{id}/… a ordenes/{id}/…
-- ---------------------------------------------------------------------
ALTER TABLE public.adjuntos DROP CONSTRAINT IF EXISTS adjuntos_ruta_check;
ALTER TABLE public.adjuntos
    ADD CONSTRAINT adjuntos_ruta_check CHECK (ruta ~ '^ordenes/.+/.+');

-- ---------------------------------------------------------------------
--  8. STORAGE: bucket privado `ordenes` y políticas por ruta
-- ---------------------------------------------------------------------
-- Ruta obligatoria: ordenes/{orden_id}/… (así sube la app; spec §5.4).
-- El SEGUNDO segmento debe ser el id de una orden existente: el primero
-- es literal "ordenes" y nadie escribe fuera de ese patrón (en este hito,
-- fuera de "una orden existente", sin cuotas por usuario).
-- El guardia de formato primero: sin él, un segmento no-uuid (p. ej.
-- "otra-cosa" en el segundo) fallaría con "invalid input syntax" en vez
-- de RLS.
INSERT INTO storage.buckets (id, name, public)
VALUES ('ordenes', 'ordenes', false)
ON CONFLICT (id) DO UPDATE SET public = false;

DROP POLICY storage_subir_adjunto ON storage.objects;
CREATE POLICY storage_subir_adjunto ON storage.objects
    FOR INSERT TO authenticated
    WITH CHECK (
        bucket_id = 'ordenes'
        AND public.mi_rol() IS NOT NULL
        AND split_part(name, '/', 1) = 'ordenes'
        AND split_part(name, '/', 2) ~ '^[0-9a-f-]{36}$'
        AND split_part(name, '/', 2)::uuid IN (SELECT o.id FROM public.ordenes_servicio o)
    );

DROP POLICY storage_ver_adjunto ON storage.objects;
CREATE POLICY storage_ver_adjunto ON storage.objects
    FOR SELECT TO authenticated
    USING (
        bucket_id = 'ordenes'
        AND public.mi_rol() IS NOT NULL
        AND split_part(name, '/', 1) = 'ordenes'
        AND split_part(name, '/', 2) ~ '^[0-9a-f-]{36}$'
        AND split_part(name, '/', 2)::uuid IN (SELECT o.id FROM public.ordenes_servicio o)
    );

-- anon no queda con ningún acceso al bucket: no se escriben políticas
-- para anon y el GRANT del esquema storage ya lo excluye de las tablas.

-- La fila del bucket viejo sale SOLO si no queda ningún objeto dentro:
-- en un remoto recién desplegado no hay objetos (datos de prueba), pero
-- la guardia evita enredar archivos vivos con el renombre.
DELETE FROM storage.buckets WHERE id = 'registros'
  AND NOT EXISTS (SELECT 1 FROM storage.objects WHERE bucket_id = 'registros');

-- ---------------------------------------------------------------------
--  REPASO IDEMPOTENTE DE ADJUNTOS (decisión de la conversación: no se
--  sabe si el proyecto remoto aplicó la 0008 original, así que las
--  sentencias se re-ejecutan como idempotentes)
-- ---------------------------------------------------------------------
ALTER TABLE public.adjuntos ALTER COLUMN subido_por SET DEFAULT auth.uid();

DROP POLICY IF EXISTS adj_insert ON public.adjuntos;
CREATE POLICY adj_insert ON public.adjuntos
    FOR INSERT TO authenticated
    WITH CHECK (subido_por = auth.uid());

-- ---------------------------------------------------------------------
--  9. VISTA DEL TABLERO: un `CREATE OR REPLACE VIEW` no alcanza porque
--  el renombre cambia los nombres de sus columnas (`orden_id`,
--  `numero_orden`); hay que soltarla y re-crearla (security_invoker:
--  es la RLS de las tablas base la que decide; los roles internos leen
--  todo). Los GRANT se re-aplican tras la re-creación.
-- ---------------------------------------------------------------------
DROP VIEW public.v_tablero;

CREATE OR REPLACE VIEW public.v_tablero
WITH (security_invoker = true) AS
SELECT r.id AS orden_id,
       r.numero_orden,
       r.estado,
       e.nombre AS estado_nombre,
       r.cobertura::text AS cobertura,
       eq.numero_serie AS serial,
       (m.nombre || ' ' || pr.modelo) AS producto,
       c.nombre AS cliente,
       c.documento AS documento,
       -- Para la búsqueda del Tablero por número de factura (spec §7.3).
       eq.numero_soporte AS numero_soporte,
       r.fecha_ingreso,
       eq.vence_el,
       CASE WHEN eq.vence_el IS NULL THEN NULL
            ELSE eq.vence_el - public.hoy_local() END AS dias_restantes,
       CASE WHEN eq.vence_el IS NULL                     THEN 'PENDIENTE'
            WHEN eq.vence_el - public.hoy_local() < 0    THEN 'VENCIDA'
            WHEN eq.vence_el - public.hoy_local() = 0    THEN 'HOY'
            WHEN eq.vence_el - public.hoy_local() <= public.ajuste('umbral_critico') THEN 'CRITICA'
            WHEN eq.vence_el - public.hoy_local() <= public.ajuste('umbral_pronto')  THEN 'PRONTO'
            ELSE 'NORMAL' END AS nivel_vigencia,
       (public.hoy_local() - public.hoy_local(r.fecha_ingreso)) AS dias_en_taller,
       CASE WHEN (public.hoy_local() - public.hoy_local(r.fecha_ingreso)) >= public.ajuste('sla_critico') THEN 'CRITICO'
            WHEN (public.hoy_local() - public.hoy_local(r.fecha_ingreso)) >= public.ajuste('sla_alerta')  THEN 'ALERTA'
            ELSE 'NORMAL' END AS nivel_sla,
       -- Cerrados: -1 (al final); abiertos: el PEOR de los dos niveles.
       -- La vigencia SOLO cuenta si la cobertura es EN_GARANTIA o
       -- POR_DETERMINAR (§4.6): un equipo que ya entró fuera de garantía o
       -- anulado tiene su fecha informativa y no sube en el orden.
       CASE WHEN r.estado NOT IN ('ENTREGADO', 'ANULADO')
            THEN GREATEST(
                CASE WHEN r.cobertura NOT IN ('EN_GARANTIA', 'POR_DETERMINAR') THEN 0
                     WHEN eq.vence_el IS NULL THEN 1
                     WHEN eq.vence_el - public.hoy_local() < 0 THEN 4
                     WHEN eq.vence_el - public.hoy_local() = 0 THEN 3
                     WHEN eq.vence_el - public.hoy_local() <= public.ajuste('umbral_critico') THEN 2
                     WHEN eq.vence_el - public.hoy_local() <= public.ajuste('umbral_pronto')  THEN 1
                     ELSE 0 END,
                CASE WHEN (public.hoy_local() - public.hoy_local(r.fecha_ingreso)) >= public.ajuste('sla_critico') THEN 2
                     WHEN (public.hoy_local() - public.hoy_local(r.fecha_ingreso)) >= public.ajuste('sla_alerta')  THEN 1
                     ELSE 0 END)
            ELSE -1 END AS urgencia_rank,
       (r.estado NOT IN ('ENTREGADO', 'ANULADO')) AS abierto
  FROM public.ordenes_servicio r
  JOIN public.estados_garantia e ON e.codigo = r.estado
  JOIN public.equipos eq         ON eq.id = r.equipo_id
  JOIN public.productos pr       ON pr.id = eq.producto_id
  JOIN public.marcas m           ON m.id = pr.marca_id
  JOIN public.clientes c         ON c.id = eq.cliente_id;

REVOKE ALL ON public.v_tablero FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.v_tablero TO authenticated;

-- ---------------------------------------------------------------------
--  10. COMENTARIO DE TABLA (el historial no tenía uno en la fuente)
-- ---------------------------------------------------------------------
COMMENT ON TABLE public.ordenes_servicio IS
'Nunca se borran filas. Una orden creada por error pasa a estado ANULADO.';