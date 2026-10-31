-- =====================================================================
--  20261030000026_buscar_equipo_tipo_documento.sql
--  buscar_equipo devuelve también el tipo del documento del titular (V, E,
--  J, G, P) para que la Consulta muestre «V-12345678» como el registro y no
--  el número suelto. Misma lógica y mismos permisos que la 0018; cambia la
--  forma del resultado, por eso se recrea la función.
-- =====================================================================

DROP FUNCTION public.buscar_equipo(text, text, text, text);

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
    tipo_documento      public.tipo_documento,
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
           e.cliente_id, c.nombre, c.documento, c.tipo_documento, c.email, c.telefono,
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
