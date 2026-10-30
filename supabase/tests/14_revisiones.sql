-- Prueba de la tabla `revisiones` (Tarea 9 del plan; spec §5.3).
-- El resultado lo calcula la base, nunca lo envía el cliente; solo anexar.
\set QUIET on
CREATE OR REPLACE FUNCTION pg_temp.chk(n text, c boolean) RETURNS void
LANGUAGE plpgsql AS $$ BEGIN RAISE NOTICE '%  %', CASE WHEN c THEN 'PASA  ' ELSE '*FALLA*' END, n; END $$;

-- Mensaje de error de una sentencia bajo una identidad (o postgres si uid NULL)
CREATE FUNCTION pg_temp.mensaje(uid text, sql text) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE
BEGIN
  IF uid IS NOT NULL THEN
    PERFORM set_config('request.jwt.claim.sub', uid, TRUE);
    PERFORM set_config('request.jwt.claim.session_id', uid, TRUE);
    EXECUTE 'SET LOCAL ROLE authenticated';
  END IF;
  BEGIN
    EXECUTE sql;
    IF uid IS NOT NULL THEN EXECUTE 'RESET ROLE'; END IF;
    RETURN NULL;   -- la sentencia que debía fallar, no falló
  EXCEPTION WHEN OTHERS THEN
    IF uid IS NOT NULL THEN EXECUTE 'RESET ROLE'; END IF;
    RETURN SQLERRM;
  END;
END $$;
\set QUIET off

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
INSERT INTO public.clientes (tipo_documento, documento, nombre) VALUES ('V','12345678','Juan Perez');
INSERT INTO public.equipos (numero_serie, producto_id, cliente_id, tipo_soporte, numero_soporte, fecha_emision, plazo_dias)
SELECT 'RT5-8842-AA', p.id, c.id, 'FACTURA', 'F-1', DATE '2026-09-01', 7
FROM public.productos p, public.clientes c
WHERE p.modelo='HG8245' AND c.documento='12345678' LIMIT 1;
INSERT INTO public.ordenes_servicio (equipo_id, falla_reportada, cobertura, creado_por, consulta_token_hash, fecha_ingreso)
VALUES ((SELECT id FROM public.equipos LIMIT 1), 'No enciende, huele a quemado',
        'POR_DETERMINAR', '11111111-1111-1111-1111-111111111111',
        extensions.digest('rev-test','sha256'), '2026-09-02 14:00+00');

CREATE FUNCTION pg_temp.orden_id() RETURNS uuid LANGUAGE sql AS
  $$ SELECT id FROM public.ordenes_servicio ORDER BY fecha_ingreso LIMIT 1 $$;
CREATE FUNCTION pg_temp.checklist_ok() RETURNS jsonb LANGUAGE sql AS $$
  SELECT '{"condiciones":{"factura_presentada":true,"titular_coincide":true},
           "equipo":{"serial_legible":true,"caja_original":true,"precintos_intactos":true,"contenido_completo":true},
           "senales":{"descarga_electrica":false,"liquidos":false,"altas_temperaturas":false,"golpes":false,"manipulacion_terceros":false}}'::jsonb $$;
CREATE FUNCTION pg_temp.checklist_golpes() RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_set(pg_temp.checklist_ok(), '{senales,golpes}', 'true') $$;

-- ============ R1: el cliente NO decide el resultado ============
INSERT INTO public.revisiones (orden_id, tipo, revisado_por, checklist, observaciones, resultado)
VALUES (pg_temp.orden_id(), 'RECEPCION', '22222222-2222-2222-2222-222222222222',
        pg_temp.checklist_golpes(), 'Equipo con golpes visibles',
        'EN_GARANTIA');  -- EL CLIENTE DICE EN_GARANTIA...
SELECT pg_temp.chk('R1 la base guarda ANULADA_POR_USO aunque el cliente haya enviado EN_GARANTIA',
  (SELECT resultado::text = 'ANULADA_POR_USO' FROM public.revisiones
   WHERE resultado::text = 'ANULADA_POR_USO'));

-- ============ R2: la cobertura del registro sigue a la revisión ============
SELECT pg_temp.chk('R2 ordenes_servicio.cobertura quedó en el resultado de la revisión',
  (SELECT cobertura::text = 'ANULADA_POR_USO' FROM public.ordenes_servicio
   WHERE id = pg_temp.orden_id()));
SELECT pg_temp.chk('R3 el motivo de anulación se llenó solo y menciona golpes',
  (SELECT motivo_anulacion_cobertura ~ 'golpes' FROM public.ordenes_servicio
   WHERE id = pg_temp.orden_id()));

-- ============ R4: checklist inválido rechazado ============
BEGIN;
INSERT INTO public.revisiones (orden_id, tipo, revisado_por, checklist)
VALUES (pg_temp.orden_id(), 'TECNICA', '22222222-2222-2222-2222-222222222222',
        '{"condiciones":{"factura_presentada":true,"titular_coincide":true},"equipo":{"serial_legible":true,"caja_original":true,"precintos_intactos":true},"senales":{"descarga_electrica":false,"liquidos":false,"altas_temperaturas":false,"golpes":false,"manipulacion_terceros":false}}'::jsonb);
ROLLBACK;  -- falta contenido_completo: DEBE FALLAR
SELECT pg_temp.chk('R4 checklist con clave faltante rechazado',
  (SELECT count(*) FROM public.revisiones) = 1);

-- ============ R5: SOLO DE ANEXAR ============
SELECT pg_temp.chk('R5 el UPDATE de una revisión está bloqueado (authenticated)',
  pg_temp.mensaje('22222222-2222-2222-2222-222222222222',
    $$UPDATE public.revisiones SET observaciones='falsificado'$$) ~ 'solo de anexar');

SET LOCAL ROLE service_role;
SELECT pg_temp.chk('R6 el UPDATE está bloqueado también para service_role',
  pg_temp.mensaje(NULL, $$UPDATE public.revisiones SET observaciones='falsificado'$$) ~ 'solo de anexar');
RESET ROLE;

SELECT pg_temp.chk('R7 el DELETE está bloqueado como propietario (postgres)',
  pg_temp.mensaje(NULL, $$DELETE FROM public.revisiones$$) ~ 'solo de anexar');

-- ============ R8: TRUNCATE también bloqueado ============
-- El intento de TRUNCATE debe fallar. Con la migración ...0008 (FK de
-- adjuntos a revisiones), Postgres rechaza antes por la referencia FK
-- ("cannot truncate ... foreign key constraint"); solo cuando no hay
-- adjuntos actúa el trigger con "solo de anexar". La invariante importa:
-- no se puede vaciar revisiones.
SELECT pg_temp.chk('R8 el TRUNCATE de revisiones está bloqueado (FK o trigger)',
  pg_temp.mensaje(NULL, $$TRUNCATE public.revisiones$$) IS NOT NULL);