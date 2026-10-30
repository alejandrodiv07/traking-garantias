-- Apoyo solo para pruebas (nunca se aplica a un proyecto real).
-- `test_ingreso` conserva el orden de argumentos del antiguo `abrir_orden`
-- de 14 parámetros: crea la garantía (registrar_garantia) y abre la orden
-- (abrir_orden) en una sola llamada, para que las pruebas que solo
-- necesitan "un equipo con una orden" no repitan los dos pasos.
CREATE FUNCTION public.test_ingreso(
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
    orden_id       uuid,
    numero_orden   text,
    consulta_token text,
    cobertura      public.cobertura_garantia,
    equipo_id      uuid,
    equipo_nuevo   boolean)
LANGUAGE plpgsql AS $$
DECLARE
    v_equipo uuid;
    v_nuevo  boolean;
BEGIN
    SELECT g.equipo_id, g.equipo_nuevo INTO v_equipo, v_nuevo
      FROM public.registrar_garantia(p_cliente_id, p_producto_id, p_serial,
               p_tipo_soporte, p_numero_soporte, p_fecha_emision, p_plazo_dias) g;
    RETURN QUERY
    SELECT o.orden_id, o.numero_orden, o.consulta_token, o.cobertura, v_equipo, v_nuevo
      FROM public.abrir_orden(v_equipo, p_falla, p_accesorios, p_checklist,
               p_observaciones, p_clave_envio, p_fecha_ingreso) o;
END $$;
