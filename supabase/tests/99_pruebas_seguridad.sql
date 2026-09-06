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

-- T1: METADATA MANIPULADO NO OTORGA ADMIN  (la vulnerabilidad original)
SELECT pg_temp.chk('T1 metadata {"role":"ADMIN"} NO escala privilegios',
  (SELECT bool_and(role='TECNICO') FROM public.profiles));

-- Promoción legítima, fuera de banda (postgres, como en post-instalación)
UPDATE public.profiles SET role='ADMIN'    WHERE email='admin@primetelecom.com';
UPDATE public.profiles SET role='RECEPCION' WHERE email='recep@primetelecom.com';

INSERT INTO public.productos (marca_id, modelo, categoria, meses_garantia)
SELECT id,'HG8245','ONT',12 FROM public.marcas WHERE nombre='Huawei';
INSERT INTO public.clientes (tipo_documento, documento, nombre, email)
VALUES ('V','12345678','Juan Perez','juan@correo.com');

-- ============ T2: RECURSION RLS EN PROFILES ============
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
SELECT pg_temp.chk('T2 SELECT profiles como authenticated sin recursion (42P17)',
  (SELECT count(*)>0 FROM public.profiles));
SELECT pg_temp.chk('T2b mi_rol() resuelve el rol', public.mi_rol()::text = 'TECNICO');
COMMIT;

-- ============ T3: AUTOESCALADA DIRECTA ============
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
UPDATE public.profiles SET role='ADMIN' WHERE id=auth.uid();  -- DEBE FALLAR
ROLLBACK;
SELECT pg_temp.chk('T3 TECNICO no puede auto-promoverse a ADMIN',
  (SELECT role='TECNICO' FROM public.profiles WHERE id='22222222-2222-2222-2222-222222222222'));

-- ============ T4: ESCALADA HORIZONTAL (editar el perfil de otro) ============
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
UPDATE public.profiles SET full_name='Hackeado' WHERE id='11111111-1111-1111-1111-111111111111';
SELECT pg_temp.chk('T4 TECNICO no edita el perfil de otro (0 filas afectadas)',
  (SELECT full_name='Ada Admin' FROM public.profiles WHERE id='11111111-1111-1111-1111-111111111111'));
ROLLBACK;

-- ============ T5: anon NO TOCA NINGUNA TABLA ============
BEGIN;
SET LOCAL ROLE anon;
SELECT count(*) FROM public.garantias;  -- DEBE FALLAR: permiso denegado
ROLLBACK;
BEGIN;
SET LOCAL ROLE anon;
SELECT count(*) FROM public.profiles;   -- DEBE FALLAR
ROLLBACK;
BEGIN;
SET LOCAL ROLE anon;
SELECT count(*) FROM public.clientes;   -- DEBE FALLAR
ROLLBACK;

-- ============ T6: TECNICO NO PUEDE CREAR ORDENES ============
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
SELECT * FROM public.crear_garantia(
  (SELECT id FROM public.clientes LIMIT 1), (SELECT id FROM public.productos LIMIT 1),
  CURRENT_DATE - 30, 'No enciende');   -- DEBE FALLAR 42501
ROLLBACK;

-- ============ T7: RECEPCION CREA LA ORDEN Y RECIBE EL TOKEN UNA VEZ ============
SET request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';
SET ROLE authenticated;
CREATE TEMP TABLE t7_src AS SELECT * FROM public.crear_garantia(
  (SELECT id FROM public.clientes LIMIT 1), (SELECT id FROM public.productos LIMIT 1),
  CURRENT_DATE - 30, 'No enciende, huele a quemado', 'SN-0001', 'F-889');
RESET ROLE;
CREATE TEMP TABLE t7 AS SELECT * FROM t7_src;
SELECT pg_temp.chk('T7 numero_orden legible y secuencial',
  (SELECT numero_orden LIKE 'ORD-____-000001' FROM t7));
SELECT pg_temp.chk('T7b token de 128 bits devuelto en claro una vez',
  (SELECT length(consulta_token)=32 FROM t7));
SELECT pg_temp.chk('T7c cobertura calculada = EN_GARANTIA (compra hace 30d, 12 meses)',
  (SELECT cobertura::text='EN_GARANTIA' FROM t7));
SELECT pg_temp.chk('T7d el token NO se guarda en claro en la tabla',
  NOT EXISTS (SELECT 1 FROM public.garantias g, t7 WHERE g.consulta_token_hash::text LIKE '%'||t7.consulta_token||'%'));
SELECT pg_temp.chk('T7e historial escrito automaticamente al crear',
  (SELECT count(*)=1 FROM public.historial_garantias h, t7 WHERE h.garantia_id=t7.garantia_id AND h.estado_anterior IS NULL AND h.estado_nuevo='RECIBIDO'));

-- ============ T8: MAQUINA DE ESTADOS ============
UPDATE public.garantias SET tecnico_asignado_id='22222222-2222-2222-2222-222222222222';
BEGIN;
UPDATE public.garantias SET estado='ENTREGADO';  -- RECIBIDO -> ENTREGADO: NO EXISTE
ROLLBACK;
BEGIN;
UPDATE public.garantias SET estado='EN_DIAGNOSTICO';
SELECT pg_temp.chk('T8b transicion valida RECIBIDO -> EN_DIAGNOSTICO aceptada',
  (SELECT estado='EN_DIAGNOSTICO' FROM public.garantias));
SELECT pg_temp.chk('T8c historial registra estado_anterior Y estado_nuevo',
  (SELECT count(*)=1 FROM public.historial_garantias WHERE estado_anterior='RECIBIDO' AND estado_nuevo='EN_DIAGNOSTICO'));
ROLLBACK;

-- ============ T9: TECNICO SOLO TOCA LO SUYO ============
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
UPDATE public.garantias SET estado='EN_DIAGNOSTICO';
SELECT pg_temp.chk('T9 TECNICO asignado SI puede avanzar su orden',
  (SELECT estado='EN_DIAGNOSTICO' FROM public.garantias));
ROLLBACK;

UPDATE public.garantias SET tecnico_asignado_id='11111111-1111-1111-1111-111111111111';
BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
UPDATE public.garantias SET estado='EN_DIAGNOSTICO';
SELECT pg_temp.chk('T9b TECNICO NO asignado no modifica (0 filas)',
  (SELECT estado='RECIBIDO' FROM public.garantias));
ROLLBACK;
UPDATE public.garantias SET tecnico_asignado_id='22222222-2222-2222-2222-222222222222';

-- ============ T10: HISTORIAL INMUTABLE (incluso como superusuario) ============
BEGIN;
UPDATE public.historial_garantias SET comentario='falsificado';  -- DEBE FALLAR
ROLLBACK;
BEGIN;
DELETE FROM public.historial_garantias;  -- DEBE FALLAR
ROLLBACK;
SELECT pg_temp.chk('T10 historial intacto tras intentos de UPDATE/DELETE',
  (SELECT count(*)=1 FROM public.historial_garantias));

-- ============ T11: CONSULTA PUBLICA ============
SET ROLE anon;
SELECT pg_temp.chk('T11a token incorrecto devuelve CERO filas (no revela nada)',
  (SELECT count(*)=0 FROM public.consultar_garantia('ORD-2026-000001','0000000000000000000000000000dead')));
RESET ROLE;
\gset
SELECT numero_orden AS ord, consulta_token AS tok FROM t7 \gset
SET ROLE anon;
SELECT pg_temp.chk('T11b consulta con numero_orden + token correcto devuelve 1 fila',
  (SELECT count(*)=1 FROM public.consultar_garantia(:'ord', :'tok')));
RESET ROLE;

SELECT pg_temp.chk('T11c la respuesta publica NO expone cedula/correo/costo/tecnico/notas',
  NOT EXISTS (
    SELECT 1 FROM information_schema.parameters
     WHERE specific_schema='public' AND parameter_mode='OUT'
       AND specific_name IN (SELECT specific_name FROM information_schema.routines
                              WHERE routine_schema='public' AND routine_name='consultar_garantia')
       AND parameter_name ~* 'documento|email|costo|tecnico|nota|cliente'));

SELECT pg_temp.chk('T11d el intento fallido quedo registrado en la bitacora',
  (SELECT count(*)>=1 FROM public.consulta_publica_intentos WHERE NOT exito));

-- ============ T12: CHECKS DE COHERENCIA ============
BEGIN;
UPDATE public.garantias SET fecha_entrega = now() - interval '400 days'; -- entrega < ingreso: FALLA
ROLLBACK;
BEGIN;
UPDATE public.garantias SET cobertura='ANULADA_POR_USO';  -- sin motivo: FALLA
ROLLBACK;
BEGIN;
UPDATE public.garantias SET cobertura='EN_GARANTIA', costo_reparacion=50; -- cobrar lo cubierto: FALLA
ROLLBACK;
SELECT pg_temp.chk('T12 los 3 CHECK de coherencia rechazaron los 3 intentos', TRUE);
