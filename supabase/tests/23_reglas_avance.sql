-- Prueba de la migración 0017 (Tarea 7 de la fase 2a; spec §4.5 y §4.4):
-- las reglas de avance las impone la BASE, no la interfaz.
--   (a) → EN_DIAGNOSTICO: ≥ 1 adjunto FOTO de la orden; un equipo de
--       origen TALLER sin compra confirmada exige además ≥ 1 DOCUMENTO.
--   (b) → PRESUPUESTADO: costo_reparacion cargado.
--   (c) EN_DIAGNOSTICO → EN_REPARACION: solo con tipo_atencion GARANTIA
--       (el servicio PAGO/PENDIENTE pasa por PRESUPUESTADO o no avanza).
--   (d) cobertura → EN_GARANTIA con presupuesto cargado: la base limpia
--       el costo (no se cobra lo que la garantía cubre) y lo anota en la
--       bitácora (el trigger registrar_evento_orden de la 0015-fix).
--
-- Patrón de 22_rechazado_transiciones.sql: superuser para los UPDATE de
-- estado y los INSERT de adjuntos — las reglas dependen de los DATOS de
-- la orden, no del rol (el rol lo valida validar_transicion_estado).
\set QUIET on
CREATE OR REPLACE FUNCTION pg_temp.chk(n text, c boolean) RETURNS void
LANGUAGE plpgsql AS $$ BEGIN RAISE NOTICE '%  %', CASE WHEN c THEN 'PASA  ' ELSE '*FALLA*' END, n; END $$;

-- SQLSTATE de una sentencia del superuser.
CREATE FUNCTION pg_temp.estado(sql text) RETURNS text
LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE sql; RETURN NULL;
EXCEPTION WHEN OTHERS THEN
  RETURN SQLSTATE;
END $$;

-- SQLERRM con la misma técnica (para asercar el mensaje accionable).
CREATE FUNCTION pg_temp.mensaje(sql text) RETURNS text
LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE sql; RETURN NULL;
EXCEPTION WHEN OTHERS THEN
  RETURN SQLERRM;
END $$;
\set QUIET off

-- ============ Semillas ============
INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES
 ('11111111-1111-1111-1111-111111111111','admin@primetelecom.com','{"full_name":"Ada Admin"}'::jsonb);
DO $$
BEGIN
  IF to_regclass('public.mfa_sesiones') IS NOT NULL THEN
    INSERT INTO public.mfa_sesiones (session_id, user_id)
    SELECT p.id, p.id FROM public.profiles p
    ON CONFLICT (session_id) DO NOTHING;
  END IF;
END $$;
UPDATE public.profiles SET role='ADMIN' WHERE email='admin@primetelecom.com';

INSERT INTO public.clientes (tipo_documento, documento, nombre)
VALUES ('V','12345678','Juan Perez');

-- Equipos: tres de origen VENTA (el DEFAULT de la 0014) y uno TALLER sin
-- compra confirmada (su garantía queda POR_DETERMINAR hasta confirmar).
INSERT INTO public.equipos (numero_serie, producto_id, cliente_id)
SELECT 'QA-GAR', p.id, c.id FROM public.productos p, public.clientes c
WHERE p.modelo='HG8245' AND c.documento='12345678' LIMIT 1;
INSERT INTO public.equipos (numero_serie, producto_id, cliente_id)
SELECT 'QA-PAG', p.id, c.id FROM public.productos p, public.clientes c
WHERE p.modelo='HG8245' AND c.documento='12345678' LIMIT 1;
INSERT INTO public.equipos (numero_serie, producto_id, cliente_id)
SELECT 'QA-PRE', p.id, c.id FROM public.productos p, public.clientes c
WHERE p.modelo='HG8245' AND c.documento='12345678' LIMIT 1;
INSERT INTO public.equipos (numero_serie, producto_id, cliente_id, origen)
SELECT 'QA-TAL', p.id, c.id, 'TALLER' FROM public.productos p, public.clientes c
WHERE p.modelo='HG8245' AND c.documento='12345678' LIMIT 1;

-- Cuatro órdenes en RECIBIDO, distinguibles por su falla:
--  A → V5  (cobertura ANULADA_POR_USO → tipo PAGO: debe ir por PRESUPUESTADO)
--  B → V1/V2/V6 (cobertura EN_GARANTIA → tipo GARANTIA)
--  C → V7  (POR_DETERMINAR con presupuesto: la garantía posterior limpia)
--  D → V3/V4 (equipo TALLER sin confirmar → PENDIENTE: foto + documento)
INSERT INTO public.ordenes_servicio
       (equipo_id, falla_reportada, cobertura, motivo_anulacion_cobertura, creado_por, consulta_token_hash)
SELECT e.id, 'Falla A: pantalla rota', 'ANULADA_POR_USO', 'Golpes (señal de causa externa)',
       '11111111-1111-1111-1111-111111111111', extensions.digest('t7-a', 'sha256')
  FROM public.equipos e WHERE e.numero_serie='QA-PAG';
INSERT INTO public.ordenes_servicio
       (equipo_id, falla_reportada, cobertura, creado_por, consulta_token_hash)
SELECT e.id, 'Falla B: no carga firmware', 'EN_GARANTIA',
       '11111111-1111-1111-1111-111111111111', extensions.digest('t7-b', 'sha256')
  FROM public.equipos e WHERE e.numero_serie='QA-GAR';
INSERT INTO public.ordenes_servicio
       (equipo_id, falla_reportada, cobertura, creado_por, consulta_token_hash)
SELECT e.id, 'Falla C: sin señal wifi', 'POR_DETERMINAR',
       '11111111-1111-1111-1111-111111111111', extensions.digest('t7-c', 'sha256')
  FROM public.equipos e WHERE e.numero_serie='QA-PRE';
INSERT INTO public.ordenes_servicio
       (equipo_id, falla_reportada, cobertura, creado_por, consulta_token_hash)
SELECT e.id, 'Falla D: puerto usb suelto', 'POR_DETERMINAR',
       '11111111-1111-1111-1111-111111111111', extensions.digest('t7-d', 'sha256')
  FROM public.equipos e WHERE e.numero_serie='QA-TAL';

CREATE FUNCTION pg_temp.oa() RETURNS uuid LANGUAGE sql AS
  $$ SELECT id FROM public.ordenes_servicio WHERE falla_reportada='Falla A: pantalla rota' $$;
CREATE FUNCTION pg_temp.ob() RETURNS uuid LANGUAGE sql AS
  $$ SELECT id FROM public.ordenes_servicio WHERE falla_reportada='Falla B: no carga firmware' $$;
CREATE FUNCTION pg_temp.oc() RETURNS uuid LANGUAGE sql AS
  $$ SELECT id FROM public.ordenes_servicio WHERE falla_reportada='Falla C: sin señal wifi' $$;
CREATE FUNCTION pg_temp.od() RETURNS uuid LANGUAGE sql AS
  $$ SELECT id FROM public.ordenes_servicio WHERE falla_reportada='Falla D: puerto usb suelto' $$;

-- ============ V0: la maquinaria de la 0017 existe ============
SELECT pg_temp.chk('V0 la función validar_avance_orden() existe (la crea la 0017)',
  to_regprocedure('public.validar_avance_orden()') IS NOT NULL);
SELECT pg_temp.chk('V0b el trigger trg_verificar_avance_orden está en ordenes_servicio',
  (SELECT count(*) = 1 FROM pg_trigger
   WHERE tgrelid = 'public.ordenes_servicio'::regclass
     AND tgname = 'trg_verificar_avance_orden' AND NOT tgisinternal));
SELECT pg_temp.chk('V0c el trigger trg_costo_con_cobertura está en ordenes_servicio',
  (SELECT count(*) = 1 FROM pg_trigger
   WHERE tgrelid = 'public.ordenes_servicio'::regclass
     AND tgname = 'trg_costo_con_cobertura' AND NOT tgisinternal));

-- ============ V1: sin foto no se diagnostica (§4.5 a) ============
SELECT pg_temp.chk('V1 RECIBIDO→EN_DIAGNOSTICO sin foto rechazada (23514)',
  pg_temp.estado($q$UPDATE public.ordenes_servicio SET estado='EN_DIAGNOSTICO'
     WHERE id=pg_temp.ob()$q$) = '23514');
SELECT pg_temp.chk('V1b el mensaje pide la foto de la auditoría de recepción',
  pg_temp.mensaje($q$UPDATE public.ordenes_servicio SET estado='EN_DIAGNOSTICO'
     WHERE id=pg_temp.ob()$q$) = 'El avance exige una foto de la auditoría de recepción');
SELECT pg_temp.chk('V1c la orden sigue RECIBIDO tras el rechazo',
  (SELECT estado='RECIBIDO' FROM public.ordenes_servicio WHERE id=pg_temp.ob()));

-- ============ V2: con la FOTO de recepción avanza ============
-- INSERT directo en adjuntos (como el patrón de 15_adjuntos.sql); la ruta
-- debe respetar ordenes/{orden_id}/… (CHECK de la 0013).
INSERT INTO public.adjuntos (orden_id, tipo, etiqueta, ruta, mime, bytes)
SELECT id, 'FOTO', 'recepcion', 'ordenes/' || id || '/archivo-foto-1.png', 'image/png', 1024
  FROM public.ordenes_servicio WHERE id = pg_temp.ob();
UPDATE public.ordenes_servicio SET estado='EN_DIAGNOSTICO' WHERE id=pg_temp.ob();
SELECT pg_temp.chk('V2 RECIBIDO→EN_DIAGNOSTICO con la FOTO es aceptado',
  (SELECT estado='EN_DIAGNOSTICO' FROM public.ordenes_servicio WHERE id=pg_temp.ob()));

-- ============ V3: equipo TALLER sin compra confirmada (§4.5 a) ============
SELECT pg_temp.chk('V3a sin adjuntos pide primero la foto',
  pg_temp.mensaje($q$UPDATE public.ordenes_servicio SET estado='EN_DIAGNOSTICO'
     WHERE id=pg_temp.od()$q$) = 'El avance exige una foto de la auditoría de recepción');
INSERT INTO public.adjuntos (orden_id, tipo, etiqueta, ruta, mime, bytes)
SELECT id, 'FOTO', 'recepcion', 'ordenes/' || id || '/archivo-foto-1.png', 'image/png', 1024
  FROM public.ordenes_servicio WHERE id = pg_temp.od();
SELECT pg_temp.chk('V3b con solo FOTO exige el documento presentado',
  pg_temp.estado($q$UPDATE public.ordenes_servicio SET estado='EN_DIAGNOSTICO'
     WHERE id=pg_temp.od()$q$) = '23514'
  AND pg_temp.mensaje($q$UPDATE public.ordenes_servicio SET estado='EN_DIAGNOSTICO'
     WHERE id=pg_temp.od()$q$) = 'Un equipo de taller sin compra confirmada exige subir el documento presentado');
INSERT INTO public.adjuntos (orden_id, tipo, etiqueta, ruta, mime, bytes)
SELECT id, 'DOCUMENTO', 'factura-presentada', 'ordenes/' || id || '/documento-factura-1.png', 'image/png', 2048
  FROM public.ordenes_servicio WHERE id = pg_temp.od();
UPDATE public.ordenes_servicio SET estado='EN_DIAGNOSTICO' WHERE id=pg_temp.od();
SELECT pg_temp.chk('V3c con FOTO + DOCUMENTO avanza a EN_DIAGNOSTICO',
  (SELECT estado='EN_DIAGNOSTICO' FROM public.ordenes_servicio WHERE id=pg_temp.od()));
-- §4.5: «en PENDIENTE no se avanza a reparar hasta resolver la cobertura».
SELECT pg_temp.chk('V3d PENDIENTE tampoco repara: EN_DIAGNOSTICO→EN_REPARACION rechazada',
  pg_temp.estado($q$UPDATE public.ordenes_servicio SET estado='EN_REPARACION'
     WHERE id=pg_temp.od()$q$) = '23514'
  AND pg_temp.mensaje($q$UPDATE public.ordenes_servicio SET estado='EN_REPARACION'
     WHERE id=pg_temp.od()$q$) = 'Un servicio pago pasa por PRESUPUESTADO antes de reparar');

-- ============ V4: presupuesto exige el monto (§4.5 b) ============
SELECT pg_temp.chk('V4a EN_DIAGNOSTICO→PRESUPUESTADO sin costo rechazada (23514)',
  pg_temp.estado($q$UPDATE public.ordenes_servicio SET estado='PRESUPUESTADO'
     WHERE id=pg_temp.od()$q$) = '23514'
  AND pg_temp.mensaje($q$UPDATE public.ordenes_servicio SET estado='PRESUPUESTADO'
     WHERE id=pg_temp.od()$q$) = 'Para presupuestar hay que registrar el monto');
-- (Dos aserciones separadas: el UPDATE va en la primera y la fila se lee
-- en la segunda — combinadas en un AND, la subconsulta suelta la ejecuta
-- el InitPlan ANTES de la llamada que mueve la fila y la aserción miente.)
SELECT pg_temp.chk('V4b con el monto cargado en el mismo UPDATE avanza',
  pg_temp.estado($q$UPDATE public.ordenes_servicio
     SET estado='PRESUPUESTADO', costo_reparacion=50.00
     WHERE id=pg_temp.od()$q$) IS NULL);
SELECT pg_temp.chk('V4b2 la fila quedó PRESUPUESTADO con el monto en ella',
  (SELECT estado='PRESUPUESTADO' AND costo_reparacion = 50.00
     FROM public.ordenes_servicio WHERE id=pg_temp.od()));

-- ============ V5: el servicio PAGO pasa por PRESUPUESTADO (§4.5 c) ============
INSERT INTO public.adjuntos (orden_id, tipo, etiqueta, ruta, mime, bytes)
SELECT id, 'FOTO', 'recepcion', 'ordenes/' || id || '/archivo-foto-1.png', 'image/png', 1024
  FROM public.ordenes_servicio WHERE id = pg_temp.oa();
UPDATE public.ordenes_servicio SET estado='EN_DIAGNOSTICO' WHERE id=pg_temp.oa();
SELECT pg_temp.chk('V5a la orden PAGO con su FOTO entra a EN_DIAGNOSTICO',
  (SELECT estado='EN_DIAGNOSTICO' AND tipo_atencion='PAGO'
     FROM public.ordenes_servicio WHERE id=pg_temp.oa()));
SELECT pg_temp.chk('V5b PAGO: EN_DIAGNOSTICO→EN_REPARACION rechazada (debe ir por PRESUPUESTADO)',
  pg_temp.estado($q$UPDATE public.ordenes_servicio SET estado='EN_REPARACION'
     WHERE id=pg_temp.oa()$q$) = '23514'
  AND pg_temp.mensaje($q$UPDATE public.ordenes_servicio SET estado='EN_REPARACION'
     WHERE id=pg_temp.oa()$q$) = 'Un servicio pago pasa por PRESUPUESTADO antes de reparar');
SELECT pg_temp.chk('V5c por PRESUPUESTADO sí pasa (con su monto)',
  pg_temp.estado($q$UPDATE public.ordenes_servicio
     SET estado='PRESUPUESTADO', costo_reparacion=75.00
     WHERE id=pg_temp.oa()$q$) IS NULL);
SELECT pg_temp.chk('V5c2 la fila quedó PRESUPUESTADO con el monto en ella',
  (SELECT estado='PRESUPUESTADO' AND costo_reparacion = 75.00
     FROM public.ordenes_servicio WHERE id=pg_temp.oa()));
UPDATE public.ordenes_servicio SET estado='EN_REPARACION' WHERE id=pg_temp.oa();
SELECT pg_temp.chk('V5d PRESUPUESTADO→EN_REPARACION es aceptada',
  (SELECT estado='EN_REPARACION' FROM public.ordenes_servicio WHERE id=pg_temp.oa()));

-- ============ V6: la garantía sí repara directo (§4.5 c) ============
-- La orden B quedó en EN_DIAGNOSTICO en V2 con su FOTO y cobertura EN_GARANTIA.
UPDATE public.ordenes_servicio SET estado='EN_REPARACION' WHERE id=pg_temp.ob();
SELECT pg_temp.chk('V6 GARANTIA: EN_DIAGNOSTICO→EN_REPARACION es aceptada',
  (SELECT estado='EN_REPARACION' AND tipo_atencion='GARANTIA'
     FROM public.ordenes_servicio WHERE id=pg_temp.ob()));

-- ============ V7: la garantía posterior no cobra (§4.4) ============
-- La orden C está POR_DETERMINAR: el cargo es posible ahí (el CHECK
-- ck_costo_solo_si_no_cubierta lo bloquea solo con EN_GARANTIA). Luego una
-- confirmación posterior vuelve la cobertura EN_GARANTIA con el presupuesto
-- cargado: la base LIMPIA el costo y la bitácora anota el evento.
UPDATE public.ordenes_servicio SET costo_reparacion=50 WHERE id=pg_temp.oc();
SELECT pg_temp.chk('V7 el presupuesto de 50 queda registrado en POR_DETERMINAR',
  (SELECT costo_reparacion = 50 FROM public.ordenes_servicio WHERE id=pg_temp.oc()));
UPDATE public.ordenes_servicio SET cobertura='EN_GARANTIA', costo_reparacion=50
 WHERE id=pg_temp.oc();
SELECT pg_temp.chk('V7b la fila queda con costo NULL (la garantía no cobra)',
  (SELECT costo_reparacion IS NULL AND cobertura='EN_GARANTIA' AND tipo_atencion='GARANTIA'
     FROM public.ordenes_servicio WHERE id=pg_temp.oc()));
SELECT pg_temp.chk('V7c la bitácora anota el evento de la cobertura',
  (SELECT count(*) = 1 FROM public.historial_ordenes
   WHERE orden_id = pg_temp.oc() AND evento = 'BITACORA'
     AND comentario = 'La cobertura cambió a EN_GARANTIA con la orden en RECIBIDO'));