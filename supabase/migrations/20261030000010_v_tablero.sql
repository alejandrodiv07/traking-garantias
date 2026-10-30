-- =====================================================================
--  20261030000010_v_tablero.sql
--  Vista del Tablero (spec §5.6): una fila por registro con la urgencia
--  COMBINADA de la vigencia y del SLA (§4.5–4.6). security_invoker: es
--  la RLS de las tablas base la que decide; los roles internos leen todo.
-- =====================================================================

CREATE OR REPLACE VIEW public.v_tablero
WITH (security_invoker = true) AS
SELECT r.id AS registro_id,
       r.numero_registro,
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
  FROM public.registros r
  JOIN public.estados_garantia e ON e.codigo = r.estado
  JOIN public.equipos eq         ON eq.id = r.equipo_id
  JOIN public.productos pr       ON pr.id = eq.producto_id
  JOIN public.marcas m           ON m.id = pr.marca_id
  JOIN public.clientes c         ON c.id = eq.cliente_id;

REVOKE ALL ON public.v_tablero FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.v_tablero TO authenticated;