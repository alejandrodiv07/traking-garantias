-- Prueba del origen de la garantía (VENTA/TALLER), la desestimación de
-- compra en `equipos` y que el TRIGGER aplique la precedencia nueva a los
-- datos (Tarea 4 de la fase 2a; spec §4.1 y §4.2; migración 0014).
-- Las aserciones de la FUNCIÓN (C1-C5) viven además en 11_cobertura.sql.
\set QUIET on
CREATE OR REPLACE FUNCTION pg_temp.chk(n text, c boolean) RETURNS void
LANGUAGE plpgsql AS $$ BEGIN RAISE NOTICE '%  %', CASE WHEN c THEN 'PASA  ' ELSE '*FALLA*' END, n; END $$;

-- Semillas
INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES
 ('11111111-1111-1111-1111-111111111111','admin@primetelecom.com','{"full_name":"Ada"}'::jsonb),
 ('22222222-2222-2222-2222-222222222222','tecnico@primetelecom.com','{"full_name":"Tito"}'::jsonb);
DO $$
BEGIN
  IF to_regclass('public.mfa_sesiones') IS NOT NULL THEN
    INSERT INTO public.mfa_sesiones (session_id, user_id)
    VALUES ('11111111-1111-1111-1111-111111111111','11111111-1111-1111-1111-111111111111'),
           ('22222222-2222-2222-2222-222222222222','22222222-2222-2222-2222-222222222222');
  END IF;
END $$;
INSERT INTO public.clientes (tipo_documento, documento, nombre)
VALUES ('V','12345678','Juan Perez');

\set QUIET on
-- Productos fijos por modelo: los del seed comparten created_at, y un
-- ORDER BY por created_at no es determinista para OFFSET 1.
CREATE FUNCTION pg_temp.producto_id() RETURNS uuid LANGUAGE sql AS
  $$ SELECT id FROM public.productos WHERE modelo='HG8245' $$;
CREATE FUNCTION pg_temp.cliente_id() RETURNS uuid LANGUAGE sql AS
  $$ SELECT id FROM public.clientes LIMIT 1 $$;
CREATE FUNCTION pg_temp.admin_id() RETURNS uuid LANGUAGE sql AS
  $$ SELECT id FROM public.profiles WHERE email='admin@primetelecom.com' $$;
CREATE FUNCTION pg_temp.tecnico_id() RETURNS uuid LANGUAGE sql AS
  $$ SELECT id FROM public.profiles WHERE email='tecnico@primetelecom.com' $$;
CREATE FUNCTION pg_temp.e_id(n text) RETURNS uuid LANGUAGE sql AS
  $$ SELECT id FROM public.equipos WHERE numero_serie=n $$;
CREATE FUNCTION pg_temp.checklist_ok() RETURNS jsonb LANGUAGE sql AS $$
  SELECT '{"condiciones":{"factura_presentada":true,"titular_coincide":true},
           "equipo":{"serial_legible":true,"caja_original":true,"precintos_intactos":true,"contenido_completo":true},
           "senales":{"descarga_electrica":false,"liquidos":false,"altas_temperaturas":false,"golpes":false,"manipulacion_terceros":false}}'::jsonb $$;
\set QUIET off

-- Equipos de la prueba (INSERT directo como superuser: no hay GRANT INSERT).
INSERT INTO public.equipos (numero_serie, producto_id, cliente_id)
VALUES ('EQ-VEN', pg_temp.producto_id(), pg_temp.cliente_id());   -- sin origen: DEFAULT
INSERT INTO public.equipos (numero_serie, producto_id, cliente_id, origen)
VALUES ('EQ-TAL', pg_temp.producto_id(), pg_temp.cliente_id(), 'TALLER');
INSERT INTO public.equipos (numero_serie, producto_id, cliente_id)
VALUES ('EQ-DES', pg_temp.producto_id(), pg_temp.cliente_id());   -- para D1-D3
INSERT INTO public.equipos (numero_serie, producto_id, cliente_id, compra_confirmada_por, compra_confirmada_en)
VALUES ('EQ-CONF', pg_temp.producto_id(), pg_temp.cliente_id(), pg_temp.admin_id(), now());

-- ============ D: ORIGEN Y DESESTIMACIÓN EN LA TABLA ============
SELECT pg_temp.chk('D5 origen=TALLER aceptado en INSERT y origen=VENTA es el DEFAULT',
  (SELECT (SELECT origen::text FROM public.equipos WHERE numero_serie='EQ-TAL') = 'TALLER'
   AND (SELECT origen::text FROM public.equipos WHERE numero_serie='EQ-VEN') = 'VENTA'));

BEGIN;
INSERT INTO public.equipos (numero_serie, producto_id, cliente_id, origen)
VALUES ('EQ-X', pg_temp.producto_id(), pg_temp.cliente_id(), 'X');  -- DEBE FALLAR
ROLLBACK;
SELECT pg_temp.chk('D6 origen fuera de (VENTA,TALLER) rechazado',
  (SELECT count(*) FROM public.equipos WHERE numero_serie='EQ-X') = 0);

BEGIN;
UPDATE public.equipos
   SET compra_desestimada_motivo = 'El titular declaro que la unidad nunca fue vendida en tienda'
 WHERE numero_serie = 'EQ-DES';  -- solo el motivo (sin por/en): DEBE FALLAR
ROLLBACK;
SELECT pg_temp.chk('D1 desestimación incompleta (motivo sin por/en) rechazada',
  (SELECT compra_desestimada_motivo IS NULL FROM public.equipos WHERE numero_serie='EQ-DES'));

BEGIN;
UPDATE public.equipos
   SET compra_desestimada_por = pg_temp.admin_id(),
       compra_desestimada_en  = now(),
       compra_desestimada_motivo = '123456789'   -- 9 caracteres: DEBE FALLAR
 WHERE numero_serie = 'EQ-DES';
ROLLBACK;
SELECT pg_temp.chk('D2 motivo de desestimación de 9 caracteres rechazado',
  (SELECT compra_desestimada_motivo IS NULL FROM public.equipos WHERE numero_serie='EQ-DES'));

-- La desestimación COMPLETA (por + en + motivo de 10+ caracteres) se acepta:
UPDATE public.equipos
   SET compra_desestimada_por = pg_temp.admin_id(),
       compra_desestimada_en  = now(),
       compra_desestimada_motivo = 'Motivo documentado'
 WHERE numero_serie = 'EQ-DES';
SELECT pg_temp.chk('D3 motivo de 10 caracteres aceptado con por y en completos',
  (SELECT compra_desestimada_por IS NOT NULL AND compra_desestimada_en IS NOT NULL
          AND length(btrim(compra_desestimada_motivo)) >= 10
   FROM public.equipos WHERE numero_serie='EQ-DES'));

BEGIN;
UPDATE public.equipos
   SET compra_desestimada_por = pg_temp.admin_id(),
       compra_desestimada_en  = now(),
       compra_desestimada_motivo = 'Confirmada y desestimada a la vez'
 WHERE numero_serie = 'EQ-CONF';  -- ya confirmada (EQ-CONF): DEBE FALLAR
ROLLBACK;
SELECT pg_temp.chk('D4 confirmada y desestimada a la vez rechazado',
  (SELECT compra_confirmada_por IS NOT NULL AND compra_desestimada_por IS NULL
   FROM public.equipos WHERE numero_serie='EQ-CONF'));

-- ============ C: LA FUNCIÓN DE COBERTURA (resumen; el detalle está en
-- 11_cobertura.sql, sección "precedencia nueva") ============
SELECT pg_temp.chk('C1 taller sin confirmar → POR_DETERMINAR',
  public.calcular_cobertura(DATE '2027-01-10', public.hoy_local(), pg_temp.checklist_ok(), 'TALLER', false, false)::text = 'POR_DETERMINAR');
SELECT pg_temp.chk('C2 taller confirmada → EN_GARANTIA',
  public.calcular_cobertura(DATE '2027-01-10', public.hoy_local(), pg_temp.checklist_ok(), 'TALLER', true, false)::text = 'EN_GARANTIA');
SELECT pg_temp.chk('C3 desestimada → FUERA_DE_GARANTIA',
  public.calcular_cobertura(DATE '2027-01-10', public.hoy_local(), pg_temp.checklist_ok(), 'VENTA', false, true)::text = 'FUERA_DE_GARANTIA');
SELECT pg_temp.chk('C4 llamada con 3 argumentos (compatibilidad) sigue dando EN_GARANTIA',
  public.calcular_cobertura(DATE '2027-01-10', public.hoy_local(), pg_temp.checklist_ok())::text = 'EN_GARANTIA');

-- ============ T1: EL TRIGGER LO APLICA A LOS DATOS ============
-- Equipo de origen TALLER, sin confirmar, CON garantía en vigencia
-- (emisión 09-01 + 7 días = vence 09-08; ingreso 09-02): si la nueva
-- precedencia no se aplica, el checklist perfecto daría EN_GARANTIA.
INSERT INTO public.equipos (numero_serie, producto_id, cliente_id, origen,
                            tipo_soporte, numero_soporte, fecha_emision, plazo_dias)
VALUES ('EQ-T1', pg_temp.producto_id(), pg_temp.cliente_id(), 'TALLER',
        'FACTURA', 'F-T1', DATE '2026-09-01', 7);

INSERT INTO public.ordenes_servicio (equipo_id, falla_reportada, cobertura, creado_por,
                                     consulta_token_hash, fecha_ingreso)
VALUES (pg_temp.e_id('EQ-T1'), 'No enciende, huele a quemado', 'POR_DETERMINAR',
        pg_temp.admin_id(), extensions.digest('t4-origen-test','sha256'),
        '2026-09-02 14:00+00');

INSERT INTO public.revisiones (orden_id, tipo, revisado_por, checklist)
SELECT o.id, 'RECEPCION', pg_temp.tecnico_id(), pg_temp.checklist_ok()
  FROM public.ordenes_servicio o
 WHERE o.equipo_id = pg_temp.e_id('EQ-T1');

SELECT pg_temp.chk('T1 el TRIGGER lo aplica a los datos: TALLER sin confirmar deja revisiones.resultado y ordenes.cobertura en POR_DETERMINAR',
  (SELECT r.resultado::text = 'POR_DETERMINAR' AND o.cobertura::text = 'POR_DETERMINAR'
     FROM public.ordenes_servicio o
     JOIN public.revisiones r ON r.orden_id = o.id
    WHERE o.equipo_id = pg_temp.e_id('EQ-T1')));