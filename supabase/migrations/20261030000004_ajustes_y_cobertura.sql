-- =====================================================================
--  20261030000004_ajustes_y_cobertura.sql
--  Cimientos del hito "registro y control de garantía": zona horaria del
--  taller, umbrales de urgencia/SLA editables solo por ADMIN, y (en la
--  tarea siguiente) la función única de cobertura.
--  Spec: docs/superpowers/specs/2026-10-29-registro-y-control-de-garantia-design.md §4.1, §4.5
-- =====================================================================

-- ---------------------------------------------------------------------
--  1. HOY_LOCAL  —  el día del taller, no el día del servidor
-- ---------------------------------------------------------------------
-- "Hoy" se evalúa en la zona horaria del taller (America/Caracas, UTC−4)
-- para que el cambio de día no dependa de dónde corra Postgres. Toda la
-- vigencia (días restantes, niveles de urgencia) pasa por esta función.
CREATE OR REPLACE FUNCTION public.hoy_local(p_ahora timestamptz DEFAULT now())
RETURNS date
LANGUAGE sql STABLE AS $$
  SELECT (p_ahora AT TIME ZONE 'America/Caracas')::date;
$$;

GRANT EXECUTE ON FUNCTION public.hoy_local(timestamptz)
  TO anon, authenticated, service_role;

-- ---------------------------------------------------------------------
--  2. AJUSTES  —  umbrales del Tablero y del SLA
-- ---------------------------------------------------------------------
-- Los niveles de urgencia (crítica = 1–3 días, pronto = 4–7) y de SLA
-- (alerta = 7, crítico = 15 días en taller) son ajustes, no reglas
-- cocinadas en el código: el ADMIN los afina con el taller.
CREATE TABLE public.ajustes (
    clave  TEXT PRIMARY KEY,
    valor  INTEGER NOT NULL
);

INSERT INTO public.ajustes (clave, valor) VALUES
  ('umbral_critico', 3),
  ('umbral_pronto',  7),
  ('sla_alerta',     7),
  ('sla_critico',    15)
ON CONFLICT (clave) DO NOTHING;

ALTER TABLE public.ajustes ENABLE ROW LEVEL SECURITY;

-- Leer: los roles internos del taller (todos ven el Tablero).
CREATE POLICY ajustes_lectura ON public.ajustes
    FOR SELECT TO authenticated
    USING (public.mi_rol() IN ('ADMIN', 'JEFE_SERVICIO', 'TECNICO', 'RECEPCION'));

-- Escribir: solo el ADMIN edita los umbrales.
CREATE POLICY ajustes_admin ON public.ajustes
    FOR UPDATE TO authenticated
    USING (public.mi_rol() = 'ADMIN')
    WITH CHECK (public.mi_rol() = 'ADMIN');

REVOKE ALL ON public.ajustes FROM anon;
GRANT SELECT ON public.ajustes TO authenticated;
GRANT UPDATE ON public.ajustes TO authenticated;

-- Lector de conveniencia, STABLE para que el planner la evalúe como constante
-- dentro de las funciones que calculan urgencia.
CREATE OR REPLACE FUNCTION public.ajuste(p_clave text) RETURNS integer
LANGUAGE sql STABLE AS $$
  SELECT valor FROM public.ajustes WHERE clave = p_clave;
$$;

GRANT EXECUTE ON FUNCTION public.ajuste(text) TO authenticated, service_role;