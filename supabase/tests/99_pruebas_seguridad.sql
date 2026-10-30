-- Pruebas de seguridad (roles y RLS) sobre los NOMBRES NUEVOS del hito
-- "registro y control de garantía": ordenes_servicio, historial_ordenes,
-- notas_internas. Portada de la versión anterior (que probaba garantías).
-- Cambio de permisos del hito (spec §6): el TECNICO AHORA SÍ crea
-- ordenes_servicio, pero por la función `abrir_orden`, no insertando directo.
\set ON_ERROR_STOP off
\pset pager off
\set QUIET on
CREATE OR REPLACE FUNCTION pg_temp.chk(nombre text, cond boolean) RETURNS void
LANGUAGE plpgsql AS $$ BEGIN
  RAISE NOTICE '%  %', CASE WHEN cond THEN 'PASA ' ELSE '*FALLA*' END, nombre;
END $$;
\set QUIET off

-- ============ SEMILLA: 3 usuarios via auth.users (dispara el trigger) ============
INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES
 ('11111111-1111-1111-1111-111111111111','admin@primetelecom.com',   '{"full_name":"Ada Admin","role":"ADMIN"}'::jsonb),
 ('22222222-2222-2222-2222-222222222222','tecnico@primetelecom.com', '{"full_name":"Tito Tecnico","role":"ADMIN"}'::jsonb),
 ('33333333-3333-3333-3333-333333333333','recep@primetelecom.com',   '{"full_name":"Rosa Recepcion"}'::jsonb);
-- MFA ya superado (estas pruebas miden ROLES y RLS, no el 2FA: eso es 96).
-- CONVENIO: el session_id de las pruebas ES el id del usuario.
DO $$
BEGIN
  IF to_regclass('public.mfa_sesiones') IS NULL THEN RETURN; END IF;
  INSERT INTO public.mfa_sesiones (session_id, user_id)
  SELECT p.id, p.id FROM public.profiles p
  ON CONFLICT (session_id) DO NOTHING;
END $$;

-- T1: METADATA MANIPULADO NO OTORGA ADMIN  (la vulnerabilidad original)
SELECT pg_temp.chk('T1 metadata {"role":"ADMIN"} NO escala privilegios',
  (SELECT bool_and(role='TECNICO') FROM public.profiles));

-- Promoción legítima, fuera de banda (postgres, como en post-instalación)
UPDATE public.profiles SET role='ADMIN'    WHERE email='admin@primetelecom.com';
UPDATE public.profiles SET role='RECEPCION' WHERE email='recep@primetelecom.com';

INSERT INTO public.clientes (tipo_documento, documento, nombre, email)
VALUES ('V','12345678','Juan Perez','juan@correo.com');
INSERT INTO public.equipos (numero_serie, producto_id, cliente_id)
SELECT 'RT5-8842-AA', p.id, c.id
FROM public.productos p, public.clientes c
WHERE p.modelo='HG8245' AND c.documento='12345678' LIMIT 1;
-- El registro vive solo vía RPC (§16 del plan); la mesa se siembra como postgres.
INSERT INTO public.ordenes_servicio (equipo_id, falla_reportada, cobertura, creado_por, consulta_token_hash)
SELECT e.id, 'No enciende, huele a quemado', 'EN_GARANTIA', '11111111-1111-1111-1111-111111111111',
       extensions.digest('seguridad-1', 'sha256')
FROM public.equipos e LIMIT 1;

-- ============ T2: RECURSION RLS EN PROFILES ============
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
SET LOCAL request.jwt.claim.session_id = '22222222-2222-2222-2222-222222222222';
SELECT pg_temp.chk('T2 SELECT profiles como authenticated sin recursion (42P17)',
  (SELECT count(*)>0 FROM public.profiles));
SELECT pg_temp.chk('T2b mi_rol() resuelve el rol', public.mi_rol()::text = 'TECNICO');
COMMIT;

-- ============ T3: AUTOESCALADA DIRECTA ============
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
SET LOCAL request.jwt.claim.session_id = '22222222-2222-2222-2222-222222222222';
UPDATE public.profiles SET role='ADMIN' WHERE id=auth.uid();  -- DEBE FALLAR
ROLLBACK;
SELECT pg_temp.chk('T3 TECNICO no puede auto-promoverse a ADMIN',
  (SELECT role='TECNICO' FROM public.profiles WHERE id='22222222-2222-2222-2222-222222222222'));

-- ============ T4: ESCALADA HORIZONTAL (editar el perfil de otro) ============
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
SET LOCAL request.jwt.claim.session_id = '22222222-2222-2222-2222-222222222222';
UPDATE public.profiles SET full_name='Hackeado' WHERE id='11111111-1111-1111-1111-111111111111';
SELECT pg_temp.chk('T4 TECNICO no edita el perfil de otro (0 filas afectadas)',
  (SELECT full_name='Ada Admin' FROM public.profiles WHERE id='11111111-1111-1111-1111-111111111111'));
ROLLBACK;

-- ============ T5: anon NO TOCA NINGUNA TABLA ============
BEGIN;
SET LOCAL ROLE anon;
SELECT count(*) FROM public.ordenes_servicio;  -- DEBE FALLAR: permiso denegado
ROLLBACK;
BEGIN;
SET LOCAL ROLE anon;
SELECT count(*) FROM public.profiles;   -- DEBE FALLAR
ROLLBACK;
BEGIN;
SET LOCAL ROLE anon;
SELECT count(*) FROM public.clientes;   -- DEBE FALLAR
ROLLBACK;

-- ============ T6: TECNICO NO INSERTA REGISTROS DIRECTO ============
-- La creación va por `abrir_orden` (Tarea 11 del plan), que asigna
-- el equipo, el registro y su revisión de recepción en una transacción.
-- No existe ni GRANT ni policy de INSERT sobre `ordenes_servicio`.
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
SET LOCAL request.jwt.claim.session_id = '22222222-2222-2222-2222-222222222222';
INSERT INTO public.ordenes_servicio (equipo_id, falla_reportada, cobertura, creado_por)
VALUES ((SELECT id FROM public.equipos LIMIT 1), 'Intento directo', 'EN_GARANTIA', auth.uid());
ROLLBACK;  -- DEBE FALLAR (permiso denegado)
SELECT pg_temp.chk('T6 un TECNICO no inserta ordenes_servicio directo (por la función)',
  (SELECT count(*)=1 FROM public.ordenes_servicio));

-- ============ T8: MAQUINA DE ESTADOS ============
UPDATE public.ordenes_servicio SET tecnico_asignado_id='22222222-2222-2222-2222-222222222222';
BEGIN;
UPDATE public.ordenes_servicio SET estado='ENTREGADO';  -- RECIBIDO -> ENTREGADO: NO EXISTE
ROLLBACK;
BEGIN;
UPDATE public.ordenes_servicio SET estado='EN_DIAGNOSTICO';
SELECT pg_temp.chk('T8b transicion valida RECIBIDO -> EN_DIAGNOSTICO aceptada',
  (SELECT estado='EN_DIAGNOSTICO' FROM public.ordenes_servicio));
SELECT pg_temp.chk('T8c historial registra estado_anterior Y estado_nuevo',
  (SELECT count(*)=1 FROM public.historial_ordenes WHERE estado_anterior='RECIBIDO' AND estado_nuevo='EN_DIAGNOSTICO'));
ROLLBACK;

-- ============ T9: TECNICO SOLO TOCA LO SUYO ============
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
SET LOCAL request.jwt.claim.session_id = '22222222-2222-2222-2222-222222222222';
UPDATE public.ordenes_servicio SET estado='EN_DIAGNOSTICO';
SELECT pg_temp.chk('T9 TECNICO asignado SI puede avanzar su registro',
  (SELECT estado='EN_DIAGNOSTICO' FROM public.ordenes_servicio));
ROLLBACK;

UPDATE public.ordenes_servicio SET tecnico_asignado_id='11111111-1111-1111-1111-111111111111';
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
SET LOCAL request.jwt.claim.session_id = '22222222-2222-2222-2222-222222222222';
UPDATE public.ordenes_servicio SET estado='EN_DIAGNOSTICO';
SELECT pg_temp.chk('T9b TECNICO NO asignado no modifica (0 filas)',
  (SELECT estado='RECIBIDO' FROM public.ordenes_servicio));
ROLLBACK;
UPDATE public.ordenes_servicio SET tecnico_asignado_id='22222222-2222-2222-2222-222222222222';

-- ============ T10: HISTORIAL INMUTABLE (incluso como superusuario) ============
BEGIN;
UPDATE public.historial_ordenes SET comentario='falsificado';  -- DEBE FALLAR
ROLLBACK;
BEGIN;
DELETE FROM public.historial_ordenes;  -- DEBE FALLAR
ROLLBACK;
SELECT pg_temp.chk('T10 historial intacto tras intentos de UPDATE/DELETE',
  -- Con la 0015 el trigger de eventos añade filas BITACORA por las
  -- asignaciones de técnico de T8/T9; el conteo mide el historial de
  -- ESTADOS de la orden (su única fila: la de alta).
  (SELECT count(*)=1 FROM public.historial_ordenes WHERE evento='ESTADO'));

-- ============ T12: CHECKS DE COHERENCIA ============
BEGIN;
UPDATE public.ordenes_servicio SET fecha_entrega = now() - interval '400 days'; -- entrega < ingreso: FALLA
ROLLBACK;
BEGIN;
UPDATE public.ordenes_servicio SET cobertura='ANULADA_POR_USO';  -- sin motivo: FALLA
ROLLBACK;
BEGIN;
UPDATE public.ordenes_servicio SET cobertura='EN_GARANTIA', costo_reparacion=50; -- cobrar lo cubierto: FALLA
ROLLBACK;
-- Las tres aserciones miden el ESTADO tras los intentos: los CHECK los
-- rechazaron si y solo si ningún registro quedó incoherente.
SELECT pg_temp.chk('T12 0 filas con fecha_entrega < fecha_ingreso',
  (SELECT count(*)=0 FROM public.ordenes_servicio WHERE fecha_entrega < fecha_ingreso));
SELECT pg_temp.chk('T12 0 filas con cobertura ANULADA sin motivo',
  (SELECT count(*)=0 FROM public.ordenes_servicio
   WHERE cobertura='ANULADA_POR_USO' AND motivo_anulacion_cobertura IS NULL));
SELECT pg_temp.chk('T12 0 filas con costo_reparacion y cobertura EN_GARANTIA',
  (SELECT count(*)=0 FROM public.ordenes_servicio
   WHERE costo_reparacion IS NOT NULL AND cobertura='EN_GARANTIA'));