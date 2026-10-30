-- =====================================================================
--  20261030000018_rpc_garantia.sql
--  Fase 2a, tarea 8 (spec §4.1 y §6):
--    · registrar_garantia: crea el equipo (la garantía) sin orden.
--    · buscar_equipo: ahora por serial, cédula/RIF, factura u orden.
--    · v_garantias: una fila por garantía, para el tablero de garantías.
--  La vigencia sale de calcular_cobertura (única fuente de verdad), sin
--  checklist: aquí solo importan la fecha, el origen y la compra.
-- =====================================================================

-- ---------------------------------------------------------------------
--  REGISTRAR_GARANTIA
--  Plazo de 7 o 15 días para todos; cualquier otro (1–365) solo lo fija
--  ADMIN o JEFE_SERVICIO. Si el equipo ya existe (mismo producto y serial
--  normalizado) lo devuelve sin tocarlo.
-- ---------------------------------------------------------------------
CREATE FUNCTION public.registrar_garantia(
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
        END IF;
    END IF;

    equipo_id := v_equipo;
    SELECT e.vence_el INTO vence_el FROM public.equipos e WHERE e.id = v_equipo;
    RETURN NEXT;
END;
$$;

REVOKE ALL ON FUNCTION public.registrar_garantia(uuid, uuid, text, text, text, date, integer, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.registrar_garantia(uuid, uuid, text, text, text, date, integer, text)
  TO authenticated;

-- ---------------------------------------------------------------------
--  V_GARANTIAS — una fila por equipo (tablero de garantías)
--  security_invoker: la RLS de `equipos` decide quién la ve.
-- ---------------------------------------------------------------------
CREATE VIEW public.v_garantias
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
            ELSE 'PENDIENTE' END          AS estado_compra
  FROM public.equipos e
  JOIN public.productos pr ON pr.id = e.producto_id
  JOIN public.marcas m     ON m.id  = pr.marca_id
  JOIN public.clientes c   ON c.id  = e.cliente_id;

REVOKE ALL ON public.v_garantias FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.v_garantias TO authenticated;

-- ---------------------------------------------------------------------
--  BUSCAR_EQUIPO — serial, cédula/RIF, factura u orden (se unen con OR)
--  SECURITY INVOKER a propósito: la RLS de equipos, clientes y órdenes
--  (solo roles internos) decide qué se ve.
-- ---------------------------------------------------------------------
DROP FUNCTION public.buscar_equipo(text);

CREATE FUNCTION public.buscar_equipo(
    p_serial    text DEFAULT NULL,
    p_documento text DEFAULT NULL,
    p_factura   text DEFAULT NULL,
    p_orden     text DEFAULT NULL)
RETURNS TABLE (
    equipo_id           uuid,
    producto_id         uuid,
    producto            text,
    numero_serie        text,
    titular_id          uuid,
    titular             text,
    documento           text,
    email               text,
    telefono            text,
    numero_soporte      text,
    fecha_emision       date,
    plazo_dias          smallint,
    vence_el            date,
    dias_restantes      integer,
    origen              text,
    vigencia            public.cobertura_garantia,
    estado_compra       text,
    motivo_desestimacion text,
    ordenes             jsonb
)
LANGUAGE sql
STABLE
SET search_path = public, pg_temp
AS $$
    WITH q AS (
        SELECT nullif(btrim(coalesce(p_serial, '')), '')    AS serial,
               nullif(btrim(coalesce(p_documento, '')), '') AS documento,
               nullif(upper(btrim(coalesce(p_factura, ''))), '') AS factura,
               nullif(upper(btrim(coalesce(p_orden, ''))), '')   AS orden
    )
    SELECT e.id, e.producto_id,
           (m.nombre || ' ' || pr.modelo)::text,
           e.numero_serie,
           e.cliente_id, c.nombre, c.documento, c.email, c.telefono,
           e.numero_soporte, e.fecha_emision, e.plazo_dias, e.vence_el,
           (e.vence_el - public.hoy_local())::int,
           e.origen,
           public.calcular_cobertura(
               e.vence_el, public.hoy_local(), NULL, e.origen,
               e.compra_confirmada_por IS NOT NULL,
               e.compra_desestimada_por IS NOT NULL),
           CASE WHEN e.compra_desestimada_por IS NOT NULL THEN 'DESESTIMADA'
                WHEN e.compra_confirmada_por IS NOT NULL OR e.origen = 'VENTA' THEN 'CONFIRMADA'
                ELSE 'PENDIENTE' END,
           e.compra_desestimada_motivo,
           COALESCE((
               SELECT jsonb_agg(jsonb_build_object(
                          'numero_orden',  o.numero_orden,
                          'estado',        o.estado,
                          'estado_nombre', s.nombre,
                          'cobertura',     o.cobertura::text,
                          'tipo_atencion', o.tipo_atencion,
                          'fecha_ingreso', o.fecha_ingreso::text)
                      ORDER BY o.fecha_ingreso)
                 FROM public.ordenes_servicio o
                 JOIN public.estados_garantia s ON s.codigo = o.estado
                WHERE o.equipo_id = e.id), '[]'::jsonb)
      FROM q,
           public.equipos e
      JOIN public.productos pr ON pr.id = e.producto_id
      JOIN public.marcas m     ON m.id  = pr.marca_id
      JOIN public.clientes c   ON c.id  = e.cliente_id
     WHERE ((q.serial IS NOT NULL AND e.serie_normalizada = public.normalizar_serie(q.serial))
         OR (q.documento IS NOT NULL AND c.documento = q.documento)
         OR (q.factura IS NOT NULL AND upper(btrim(e.numero_soporte)) = q.factura)
         OR (q.orden IS NOT NULL AND EXISTS (
                SELECT 1 FROM public.ordenes_servicio o
                 WHERE o.equipo_id = e.id AND o.numero_orden = q.orden)))
     ORDER BY e.created_at DESC;
$$;

REVOKE ALL ON FUNCTION public.buscar_equipo(text, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.buscar_equipo(text, text, text, text) TO authenticated;
