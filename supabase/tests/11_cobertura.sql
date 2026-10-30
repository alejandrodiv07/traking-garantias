-- Prueba de `calcular_cobertura`, `motivo_anulacion` y `checklist_es_valido`
-- (Tarea 5 del plan; spec §4.2 y §4.3).
\set QUIET on
CREATE OR REPLACE FUNCTION pg_temp.chk(n text, c boolean) RETURNS void
LANGUAGE plpgsql AS $$ BEGIN RAISE NOTICE '%  %', CASE WHEN c THEN 'PASA  ' ELSE '*FALLA*' END, n; END $$;

-- Arma un checklist completo con todos los incumplibles en su estado bueno
-- y aplica encima las diferencias de cada caso.
CREATE FUNCTION pg_temp.ck(condiciones jsonb DEFAULT NULL, equipo jsonb DEFAULT NULL, senales jsonb DEFAULT NULL) RETURNS jsonb
LANGUAGE sql AS $$
  SELECT jsonb_build_object(
    'condiciones', jsonb_build_object('factura_presentada', true, 'titular_coincide', true) || coalesce(condiciones, '{}'::jsonb),
    'equipo',      jsonb_build_object('serial_legible', true, 'caja_original', true, 'precintos_intactos', true, 'contenido_completo', true) || coalesce(equipo, '{}'::jsonb),
    'senales',     jsonb_build_object('descarga_electrica', false, 'liquidos', false, 'altas_temperaturas', false, 'golpes', false, 'manipulacion_terceros', false) || coalesce(senales, '{}'::jsonb));
$$;
\set QUIET off

-- ============ TABLA DE CASOS: precedencia del spec §4.2 ============
DO $$
DECLARE
  caso RECORD;
BEGIN
  FOR caso IN
    SELECT * FROM (VALUES
      -- (nombre, vence_el, fecha_ingreso, checklist, esperado)
      ('C1 ingreso en vigencia sin checklist',          DATE '2026-09-10', DATE '2026-09-03', NULL::jsonb, 'EN_GARANTIA'),
      ('C2 dia exacto de vencimiento sigue vigente',    DATE '2026-09-10', DATE '2026-09-10', NULL::jsonb, 'EN_GARANTIA'),
      ('C3 un dia despues del vencimiento',             DATE '2026-09-10', DATE '2026-09-11', NULL::jsonb, 'FUERA_DE_GARANTIA'),
      ('C4 sin fecha de vencimiento',                   NULL,              DATE '2026-09-03', NULL::jsonb, 'POR_DETERMINAR'),
      -- señales de causa externa: cada una anula
      ('C5 señal golpes',                               DATE '2026-09-10', DATE '2026-09-03', pg_temp.ck(NULL, NULL, '{"golpes":true}'), 'ANULADA_POR_USO'),
      ('C6 señal descarga_electrica',                   DATE '2026-09-10', DATE '2026-09-03', pg_temp.ck(NULL, NULL, '{"descarga_electrica":true}'), 'ANULADA_POR_USO'),
      ('C7 señal liquidos',                             DATE '2026-09-10', DATE '2026-09-03', pg_temp.ck(NULL, NULL, '{"liquidos":true}'), 'ANULADA_POR_USO'),
      ('C8 señal altas_temperaturas',                   DATE '2026-09-10', DATE '2026-09-03', pg_temp.ck(NULL, NULL, '{"altas_temperaturas":true}'), 'ANULADA_POR_USO'),
      ('C9 señal manipulacion_terceros',                DATE '2026-09-10', DATE '2026-09-03', pg_temp.ck(NULL, NULL, '{"manipulacion_terceros":true}'), 'ANULADA_POR_USO'),
      -- términos del equipo incumplidos: anulan
      ('C10 precintos_intactos=false',                  DATE '2026-09-10', DATE '2026-09-03', pg_temp.ck(NULL, '{"precintos_intactos":false}'), 'ANULADA_POR_USO'),
      ('C11 serial_legible=false',                      DATE '2026-09-10', DATE '2026-09-03', pg_temp.ck(NULL, '{"serial_legible":false}'), 'ANULADA_POR_USO'),
      ('C12 caja_original=false',                       DATE '2026-09-10', DATE '2026-09-03', pg_temp.ck(NULL, '{"caja_original":false}'), 'ANULADA_POR_USO'),
      ('C13 contenido_completo=false',                  DATE '2026-09-10', DATE '2026-09-03', pg_temp.ck(NULL, '{"contenido_completo":false}'), 'ANULADA_POR_USO'),
      -- condiciones del trámite: detienen el proceso, no anulan
      ('C14 factura_presentada=false',                  DATE '2026-09-10', DATE '2026-09-03', pg_temp.ck('{"factura_presentada":false}'), 'POR_DETERMINAR'),
      ('C15 titular_coincide=false',                    DATE '2026-09-10', DATE '2026-09-03', pg_temp.ck('{"titular_coincide":false}'), 'POR_DETERMINAR'),
      -- la fecha manda sobre la anulación
      ('C16 señal y garantía vencida',                  DATE '2026-09-10', DATE '2026-09-11', pg_temp.ck(NULL, NULL, '{"golpes":true}'), 'FUERA_DE_GARANTIA'),
      -- la anulación manda sobre la condición
      ('C17 señal con factura no presentada',           DATE '2026-09-10', DATE '2026-09-03', pg_temp.ck('{"factura_presentada":false}', NULL, '{"golpes":true}'), 'ANULADA_POR_USO'),
      -- sin vencimiento, sin cobertura aunque haya señales
      ('C18 sin fecha y con señal',                     NULL,              DATE '2026-09-03', pg_temp.ck(NULL, NULL, '{"golpes":true}'), 'POR_DETERMINAR'),
      -- plazo de 7 días: compra 09-03 + 7 = vence 09-10, cuenta vigente
      ('C19 plazo de 7 dias vence el mismo dia',        DATE '2026-09-07', DATE '2026-09-07', NULL::jsonb, 'EN_GARANTIA')
    ) t(nombre, vence_el, ingreso, checklist, esperado)
  LOOP
    PERFORM pg_temp.chk(caso.nombre,
      public.calcular_cobertura(caso.vence_el, caso.ingreso, caso.checklist)::text = caso.esperado);
  END LOOP;
END $$;

-- ============ MOTIVO DE ANULACIÓN: nombra lo observado ============
SELECT pg_temp.chk('M1 motivo por señal menciona golpes',
  public.motivo_anulacion(pg_temp.ck(NULL, NULL, '{"golpes":true}')) ~ 'golpes');
SELECT pg_temp.chk('M2 motivo por término menciona precintos',
  public.motivo_anulacion(pg_temp.ck(NULL, '{"precintos_intactos":false}')) ~ 'precintos');
SELECT pg_temp.chk('M3 motivo vacío cuando nada anula',
  public.motivo_anulacion(pg_temp.ck()) IS NULL);

-- ============ CHECKLIST ES VÁLIDO: claves y tipos ============
SELECT pg_temp.chk('V1 checklist completo y booleano es válido',
  public.checklist_es_valido(pg_temp.ck()));
SELECT pg_temp.chk('V2 rechaza una clave faltante',
  NOT public.checklist_es_valido(
    '{"condiciones":{"factura_presentada":true,"titular_coincide":true},
      "equipo":{"serial_legible":true,"caja_original":true,"precintos_intactos":true}
      ,"senales":{"descarga_electrica":false,"liquidos":false,"altas_temperaturas":false,"golpes":false,"manipulacion_terceros":false}}'::jsonb));
SELECT pg_temp.chk('V3 rechaza valores no booleanos',
  NOT public.checklist_es_valido(pg_temp.ck(NULL, NULL, '{"golpes":"sí"}')));
SELECT pg_temp.chk('V4 NULL (sin checklist) es un uso válido',
  public.checklist_es_valido(NULL));

-- ============ PRECEDENCIA NUEVA (fase 2a §4.2): desestimación y origen ============
-- Migración 0014: la confianza de una garantía de taller exige
-- confirmación administrativa, y una compra desestimada cierra la puerta.
-- Los cortes nuevos van ANTES del de la fecha vencida (§4.2, pasos 1 y 3).
-- Estas mismas aserciones viven también en 20_equipos_origen.sql (C1-C4)
-- junto a las del resto de la tarea.

-- C1 usa una fecha de vencimiento lejana y el ingreso de HOY (hoy_local):
-- sin los cortes nuevos, el checklist perfecto daría EN_GARANTIA.
SELECT pg_temp.chk('C1 taller sin confirmar → POR_DETERMINAR',
  public.calcular_cobertura(DATE '2027-01-10', public.hoy_local(), pg_temp.ck(), 'TALLER', false, false)::text = 'POR_DETERMINAR');
SELECT pg_temp.chk('C2 taller confirmada → EN_GARANTIA',
  public.calcular_cobertura(DATE '2027-01-10', public.hoy_local(), pg_temp.ck(), 'TALLER', true, false)::text = 'EN_GARANTIA');
SELECT pg_temp.chk('C3 desestimada → FUERA_DE_GARANTIA (checklist perfecto y fechas vigentes)',
  public.calcular_cobertura(DATE '2027-01-10', public.hoy_local(), pg_temp.ck(), 'VENTA', false, true)::text = 'FUERA_DE_GARANTIA');
SELECT pg_temp.chk('C4 llamada con 3 argumentos (compatibilidad) sigue dando EN_GARANTIA',
  public.calcular_cobertura(DATE '2027-01-10', public.hoy_local(), pg_temp.ck())::text = 'EN_GARANTIA');
-- La desestimación es el corte 1: manda aunque el equipo ni siquiera
-- tenga fecha de vencimiento (el paso 2 ya no se alcanza).
SELECT pg_temp.chk('C5 desestimada sin vence_el sigue en FUERA_DE_GARANTIA',
  public.calcular_cobertura(NULL, public.hoy_local(), pg_temp.ck(), 'VENTA', false, true)::text = 'FUERA_DE_GARANTIA');