-- Prueba de la migración 0016 (Tarea 6 de la fase 2a; spec §4.6, §5.2 y §7):
-- el estado RECHAZADO (decisión del taller, motivo obligatorio ≥ 10 y única
-- salida a ENTREGADO), el cierre de los roles "cualquier rol" de la máquina
-- de transiciones y la RLS de recepción que admite RECHAZADO.
--
-- Patrón de 13_registros.sql: superuser para el flujo y transición, y
-- `SET LOCAL ROLE authenticated` + claims (sub = session_id = uid, con su
-- perfil y su sesión MFA sembradas) para las aserciones por rol.
-- Para aislar el CIERRE DE ROLES del trigger (42501) de la RLS se usa
-- también un helper que fija las claims SIN cambiar el rol: postgres sigue
-- bypasseando la RLS (0 filas no es 42501) pero el trigger SECURITY DEFINER
-- resuelve mi_rol() con las claims — así se mide exactamente el permiso
-- de la transición, no el filtro de la policy.
\set QUIET on
CREATE OR REPLACE FUNCTION pg_temp.chk(n text, c boolean) RETURNS void
LANGUAGE plpgsql AS $$ BEGIN RAISE NOTICE '%  %', CASE WHEN c THEN 'PASA  ' ELSE '*FALLA*' END, n; END $$;

-- Ejecuta una sentencia como authenticated con la claim del uid y devuelve
-- TRUE si tuvo éxito Y movió filas (cambiado de como_tecnico en
-- 21_orden_atencion.sql: un UPDATE silenciosamente filtrado por la RLS
-- afecta 0 filas y NO es un éxito).
CREATE FUNCTION pg_temp.como(uid text, sql text) RETURNS boolean
LANGUAGE plpgsql AS $$
DECLARE n integer;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', uid, TRUE);
  PERFORM set_config('request.jwt.claim.session_id', uid, TRUE);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    EXECUTE sql;
    GET DIAGNOSTICS n = ROW_COUNT;
    EXECUTE 'RESET ROLE';
    RETURN n > 0;
  EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    RETURN FALSE;
  END;
END $$;

-- SQLSTATE de una sentencia como authenticated con la claim del uid.
CREATE FUNCTION pg_temp.estado_de(uid text, sql text) RETURNS text
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claim.sub', uid, TRUE);
  PERFORM set_config('request.jwt.claim.session_id', uid, TRUE);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    EXECUTE sql; EXECUTE 'RESET ROLE'; RETURN NULL;
  EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE'; RETURN SQLSTATE;
  END;
END $$;

-- SQLERRM de una sentencia como authenticated con la claim del uid.
CREATE FUNCTION pg_temp.mensaje_de(uid text, sql text) RETURNS text
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claim.sub', uid, TRUE);
  PERFORM set_config('request.jwt.claim.session_id', uid, TRUE);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    EXECUTE sql; EXECUTE 'RESET ROLE'; RETURN NULL;
  EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE'; RETURN SQLERRM;
  END;
END $$;

-- SQLSTATE de una sentencia ejecutada como quien corre el archivo
-- (superuser, sin claims): para el CHECK ck_rechazo_motivado sobre la
-- transición que el SQL del panel ejecuta (R1).
CREATE FUNCTION pg_temp.estado(sql text) RETURNS text
LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE sql; RETURN NULL;
EXCEPTION WHEN OTHERS THEN
  RETURN SQLSTATE;
END $$;

-- SQLERRM con la misma técnica.
CREATE FUNCTION pg_temp.mensaje(sql text) RETURNS text
LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE sql; RETURN NULL;
EXCEPTION WHEN OTHERS THEN
  RETURN SQLERRM;
END $$;

-- SQLSTATE de una sentencia con las claims del PERFIL de recepción fijadas
-- PERO corriendo como postgres (superuser): aislado del cierre de roles del
-- trigger — la RLS quedaría filtrada en 0 filas, y eso no es 42501.
CREATE FUNCTION pg_temp.estado_rol(sql text) RETURNS text
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '33333333-3333-3333-3333-333333333333', TRUE);
  PERFORM set_config('request.jwt.claim.session_id', '33333333-3333-3333-3333-333333333333', TRUE);
  BEGIN
    EXECUTE sql; RETURN NULL;
  EXCEPTION WHEN OTHERS THEN
    RETURN SQLSTATE;
  END;
END $$;

-- SQLERRM con la misma técnica (para asercar el mensaje del trigger).
CREATE FUNCTION pg_temp.mensaje_rol(sql text) RETURNS text
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claim.sub', '33333333-3333-3333-3333-333333333333', TRUE);
  PERFORM set_config('request.jwt.claim.session_id', '33333333-3333-3333-3333-333333333333', TRUE);
  BEGIN
    EXECUTE sql; RETURN NULL;
  EXCEPTION WHEN OTHERS THEN
    RETURN SQLERRM;
  END;
END $$;

-- SELECT booleano como authenticated con la claim del uid (para v_tablero).
CREATE FUNCTION pg_temp.vista(uid text, sql text) RETURNS boolean
LANGUAGE plpgsql AS $$
DECLARE r boolean;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', uid, TRUE);
  PERFORM set_config('request.jwt.claim.session_id', uid, TRUE);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    EXECUTE sql INTO r;
  EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE'; RETURN FALSE;
  END;
  EXECUTE 'RESET ROLE';
  RETURN r;
END $$;

\set QUIET off

-- ============ Semillas: 4 usuarios con sus perfiles y MFA ============
INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES
 ('11111111-1111-1111-1111-111111111111','admin@primetelecom.com','{"full_name":"Ada Admin"}'::jsonb),
 ('22222222-2222-2222-2222-222222222222','tecnico@primetelecom.com','{"full_name":"Tito Tecnico"}'::jsonb),
 ('33333333-3333-3333-3333-333333333333','recep@primetelecom.com','{"full_name":"Rosa Recepcion"}'::jsonb),
 ('44444444-4444-4444-4444-444444444444','jefe@primetelecom.com','{"full_name":"Julia Jefa"}'::jsonb);
DO $$
BEGIN
  IF to_regclass('public.mfa_sesiones') IS NOT NULL THEN
    INSERT INTO public.mfa_sesiones (session_id, user_id)
    SELECT p.id, p.id FROM public.profiles p
    ON CONFLICT (session_id) DO NOTHING;
  END IF;
END $$;
UPDATE public.profiles SET role='ADMIN'        WHERE email='admin@primetelecom.com';
-- El TECNICO es el rol por defecto del perfil: aquí no se toca.
UPDATE public.profiles SET role='RECEPCION'    WHERE email='recep@primetelecom.com';
UPDATE public.profiles SET role='JEFE_SERVICIO' WHERE email='jefe@primetelecom.com';

INSERT INTO public.clientes (tipo_documento, documento, nombre)
VALUES ('V','12345678','Juan Perez');
INSERT INTO public.equipos (numero_serie, producto_id, cliente_id)
SELECT 'RT5-8842-AA', p.id, c.id
FROM public.productos p, public.clientes c
WHERE p.modelo='HG8245' AND c.documento='12345678'
LIMIT 1;

CREATE FUNCTION pg_temp.equipo_id() RETURNS uuid LANGUAGE sql AS
  $$ SELECT id FROM public.equipos LIMIT 1 $$;

-- Cinco órdenes en RECIBIDO, distinguibles por su falla:
--  A → R1/R2 (rechazo y salida a ENTREGADO, asignada al técnico)
--  B → R3/R6 (intentos del TÉCNICO, asignada a él)
--  C → R4/R8 (cierre de roles y v_tablero)
--  D → R5   (entrega de RECEPCION desde REPARADO)
--  E → R7   (RECHAZADO_POR_CLIENTE de RECEPCION)
INSERT INTO public.ordenes_servicio (equipo_id, falla_reportada, cobertura, creado_por, tecnico_asignado_id, consulta_token_hash)
VALUES (pg_temp.equipo_id(), 'Falla A: no enciende', 'EN_GARANTIA',
        '11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222',
        extensions.digest('t6-a', 'sha256')),
       (pg_temp.equipo_id(), 'Falla B: antena floja', 'EN_GARANTIA',
        '11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222',
        extensions.digest('t6-b', 'sha256')),
       (pg_temp.equipo_id(), 'Falla C: pantalla rayada', 'EN_GARANTIA',
        '11111111-1111-1111-1111-111111111111', NULL,
        extensions.digest('t6-c', 'sha256')),
       (pg_temp.equipo_id(), 'Falla D: sin tarjeta', 'EN_GARANTIA',
        '11111111-1111-1111-1111-111111111111', NULL,
        extensions.digest('t6-d', 'sha256')),
       (pg_temp.equipo_id(), 'Falla E: sin carga', 'EN_GARANTIA',
        '11111111-1111-1111-1111-111111111111', NULL,
        extensions.digest('t6-e', 'sha256'));

CREATE FUNCTION pg_temp.oa() RETURNS uuid LANGUAGE sql AS
  $$ SELECT id FROM public.ordenes_servicio WHERE falla_reportada='Falla A: no enciende' $$;
CREATE FUNCTION pg_temp.ob() RETURNS uuid LANGUAGE sql AS
  $$ SELECT id FROM public.ordenes_servicio WHERE falla_reportada='Falla B: antena floja' $$;
CREATE FUNCTION pg_temp.oc() RETURNS uuid LANGUAGE sql AS
  $$ SELECT id FROM public.ordenes_servicio WHERE falla_reportada='Falla C: pantalla rayada' $$;
CREATE FUNCTION pg_temp.od() RETURNS uuid LANGUAGE sql AS
  $$ SELECT id FROM public.ordenes_servicio WHERE falla_reportada='Falla D: sin tarjeta' $$;
CREATE FUNCTION pg_temp.oe() RETURNS uuid LANGUAGE sql AS
  $$ SELECT id FROM public.ordenes_servicio WHERE falla_reportada='Falla E: sin carga' $$;

-- La 0017 (spec §4.5) impone las reglas de avance: las órdenes que estas
-- pruebas avanzan a EN_DIAGNOSTICO (B y D, en R6 y R5) llevan ya su foto
-- de la auditoría de recepción. La orden E (R7) se prepara además para el
-- PRESUPUESTADO del §4.4: la regla (b) exige el monto y el CHECK
-- ck_costo_solo_si_no_cubierta de la 0006 no admite un monto con la
-- cobertura EN_GARANTIA, así que se la deja POR_DETERMINAR (sin motivo) y
-- se siembra el costo antes de transitar.
INSERT INTO public.adjuntos (orden_id, tipo, etiqueta, ruta, mime, bytes)
SELECT id, 'FOTO', 'recepcion', 'ordenes/' || id || '/archivo-foto-1.png', 'image/png', 1024
  FROM public.ordenes_servicio
 WHERE falla_reportada IN ('Falla B: antena floja', 'Falla D: sin tarjeta', 'Falla E: sin carga');
UPDATE public.ordenes_servicio
   SET cobertura = 'POR_DETERMINAR', costo_reparacion = 40
 WHERE falla_reportada = 'Falla E: sin carga';

-- ============ R0: el catálogo ============
SELECT pg_temp.chk('R0 RECHAZADO existe: nombre Rechazado, orden 85, es_final FALSE',
  (SELECT nombre = 'Rechazado' AND orden = 85 AND es_final = FALSE
     FROM public.estados_garantia WHERE codigo = 'RECHAZADO'));

-- ============ R1: RECIBIDO → RECHAZADO exige motivo ≥ 10 (§5.2) ============
-- El UPDATE lo hace el superuser (SQL del panel) por la transición recién
-- creada con roles ARRAY['ADMIN','JEFE_SERVICIO'].
BEGIN;
SELECT pg_temp.chk('R1a RECIBIDO→RECHAZADO sin motivo rechazada (23514 ck_rechazo_motivado)',
  pg_temp.mensaje($q$UPDATE public.ordenes_servicio SET estado='RECHAZADO'
     WHERE id=pg_temp.oa()$q$) ~ 'ck_rechazo_motivado');
SELECT pg_temp.chk('R1a2 el SQLSTATE del rechazo es 23514',
  pg_temp.estado($q$UPDATE public.ordenes_servicio SET estado='RECHAZADO'
     WHERE id=pg_temp.oa()$q$) = '23514');
SELECT pg_temp.chk('R1b RECIBIDO→RECHAZADO con motivo de 9 caracteres rechazada',
  pg_temp.mensaje($q$UPDATE public.ordenes_servicio
     SET estado='RECHAZADO', motivo_rechazo='Rechazo X'
     WHERE id=pg_temp.oa()$q$) ~ 'ck_rechazo_motivado');
SELECT pg_temp.chk('R1c sin motivo y con motivo corto la fila sigue RECIBIDO',
  (SELECT estado='RECIBIDO' AND motivo_rechazo IS NULL
     FROM public.ordenes_servicio WHERE id=pg_temp.oa()));
ROLLBACK;

UPDATE public.ordenes_servicio
   SET estado='RECHAZADO',
       motivo_rechazo='Sin repuestos disponibles y el cliente no espera: se rechaza'
 WHERE id=pg_temp.oa();
SELECT pg_temp.chk('R1d RECIBIDO→RECHAZADO con motivo de 10+ en el mismo UPDATE es aceptada',
  (SELECT estado='RECHAZADO'
     FROM public.ordenes_servicio WHERE id=pg_temp.oa()));
SELECT pg_temp.chk('R1e el motivo quedó en la fila',
  (SELECT motivo_rechazo = 'Sin repuestos disponibles y el cliente no espera: se rechaza'
     FROM public.ordenes_servicio WHERE id=pg_temp.oa()));

-- ============ R2: la única salida, RECHAZADO → ENTREGADO (R/S/jefe) ============
BEGIN;
SELECT pg_temp.chk('R2a RECEPCION pasa RECHAZADO→ENTREGADO',
  pg_temp.como('33333333-3333-3333-3333-333333333333',
    $q$UPDATE public.ordenes_servicio SET estado='ENTREGADO'
        WHERE id=pg_temp.oa()$q$));
SELECT pg_temp.chk('R2b tras ENTREGADO el motivo SIGUE en la fila y la fecha quedó llena',
  (SELECT estado='ENTREGADO'
       AND motivo_rechazo = 'Sin repuestos disponibles y el cliente no espera: se rechaza'
       AND fecha_entrega IS NOT NULL
     FROM public.ordenes_servicio WHERE id=pg_temp.oa()));
ROLLBACK;

BEGIN;
SELECT pg_temp.chk('R2c JEFE_SERVICIO pasa RECHAZADO→ENTREGADO',
  pg_temp.como('44444444-4444-4444-4444-444444444444',
    $q$UPDATE public.ordenes_servicio SET estado='ENTREGADO'
        WHERE id=pg_temp.oa()$q$));
ROLLBACK;

BEGIN;
UPDATE public.ordenes_servicio SET estado='ENTREGADO' WHERE id=pg_temp.oa();
SELECT pg_temp.chk('R2d el superuser pasa RECHAZADO→ENTREGADO',
  (SELECT estado='ENTREGADO' FROM public.ordenes_servicio WHERE id=pg_temp.oa()));
ROLLBACK;
SELECT pg_temp.chk('R2e tras los tres intentos la orden sigue RECHAZADO con su motivo',
  (SELECT estado='RECHAZADO'
       AND motivo_rechazo = 'Sin repuestos disponibles y el cliente no espera: se rechaza'
     FROM public.ordenes_servicio WHERE id=pg_temp.oa()));

-- ============ R3: el TÉCNICO ya no rechaza (transición cerrada) ============
-- Su orden está asignada a él (la RLS reg_update_tecnico la deja pasar):
-- el 42501 sale del trigger validar_transicion_estado por roles_permitidos.
SELECT pg_temp.chk('R3 TECNICO intenta RECIBIDO→RECHAZADO y recibe 42501',
  pg_temp.estado_de('22222222-2222-2222-2222-222222222222',
    $q$UPDATE public.ordenes_servicio SET estado='RECHAZADO'
        WHERE id=pg_temp.ob()$q$) = '42501');
SELECT pg_temp.chk('R3b el mensaje nombra la transición cerrada',
  pg_temp.mensaje_de('22222222-2222-2222-2222-222222222222',
    $q$UPDATE public.ordenes_servicio SET estado='RECHAZADO'
        WHERE id=pg_temp.ob()$q$) ~ 'no puede ejecutar la transición RECIBIDO -> RECHAZADO');

-- ============ R4: RECEPCION ya no tiene "cualquier rol" ============
-- Aislado del permiso de la transición (claims + superuser): antes de la
-- 0016 la fila roles_permitidos NULL aceptaba a RECEPCION; después, no.
SELECT pg_temp.chk('R4 RECEPCION intenta RECIBIDO→EN_DIAGNOSTICO y recibe 42501',
  pg_temp.estado_rol($q$UPDATE public.ordenes_servicio SET estado='EN_DIAGNOSTICO'
     WHERE id=pg_temp.oc()$q$) = '42501');
SELECT pg_temp.chk('R4b el mensaje nombra a RECEPCION fuera de la transición',
  pg_temp.mensaje_rol($q$UPDATE public.ordenes_servicio SET estado='EN_DIAGNOSTICO'
     WHERE id=pg_temp.oc()$q$) ~ 'El rol RECEPCION no puede ejecutar la transición RECIBIDO -> EN_DIAGNOSTICO');
SELECT pg_temp.chk('R4c la orden C sigue RECIBIDO tras el intento',
  (SELECT estado='RECIBIDO' FROM public.ordenes_servicio WHERE id=pg_temp.oc()));

-- ============ R5: RECEPCION SÍ entrega desde REPARADO (regresión) ============
UPDATE public.ordenes_servicio SET estado='EN_DIAGNOSTICO' WHERE id=pg_temp.od();
UPDATE public.ordenes_servicio SET estado='EN_REPARACION'  WHERE id=pg_temp.od();
UPDATE public.ordenes_servicio SET estado='REPARADO'       WHERE id=pg_temp.od();
BEGIN;
SELECT pg_temp.chk('R5 RECEPCION sí pasa REPARADO→ENTREGADO',
  pg_temp.como('33333333-3333-3333-3333-333333333333',
    $q$UPDATE public.ordenes_servicio SET estado='ENTREGADO'
        WHERE id=pg_temp.od()$q$));
ROLLBACK;

-- ============ R6: el TÉCNICO sigue avanzando su orden (regresión) ============
BEGIN;
SELECT pg_temp.chk('R6 TECNICO pasa RECIBIDO→EN_DIAGNOSTICO',
  pg_temp.como('22222222-2222-2222-2222-222222222222',
    $q$UPDATE public.ordenes_servicio SET estado='EN_DIAGNOSTICO'
        WHERE id=pg_temp.ob()$q$));
ROLLBACK;

-- ============ R7: la decisión del cliente la recepciona RECEPCION ============
UPDATE public.ordenes_servicio SET estado='EN_DIAGNOSTICO' WHERE id=pg_temp.oe();
UPDATE public.ordenes_servicio SET estado='PRESUPUESTADO'  WHERE id=pg_temp.oe();
-- Aislado del permiso de la transición (claims + superuser): la policy de
-- recepción sigue sin admitir PRESUPUESTADO, y así lo mantiene la 0016.
SELECT pg_temp.chk('R7 PRESUPUESTADO→RECHAZADO_POR_CLIENTE aceptado a RECEPCION',
  pg_temp.estado_rol($q$UPDATE public.ordenes_servicio SET estado='RECHAZADO_POR_CLIENTE'
     WHERE id=pg_temp.oe()$q$) IS NULL);
SELECT pg_temp.chk('R7b la orden E quedó RECHAZADO_POR_CLIENTE',
  (SELECT estado='RECHAZADO_POR_CLIENTE' FROM public.ordenes_servicio WHERE id=pg_temp.oe()));

-- ============ R8: RECHAZADO cuenta como ABIERTA en v_tablero ============
UPDATE public.ordenes_servicio
   SET estado='RECHAZADO',
       motivo_rechazo='La carcasa está abierta con sellos violados por terceros'
 WHERE id=pg_temp.oc();
SELECT pg_temp.chk('R8 RECHAZADO queda abierto=true en v_tablero',
  pg_temp.vista('11111111-1111-1111-1111-111111111111',
    $q$SELECT estado='RECHAZADO' AND abierto
        FROM public.v_tablero WHERE orden_id=pg_temp.oc()$q$));

-- ============ R9: el cierre de roles total ============
SELECT pg_temp.chk('R9 ninguna transición queda con roles_permitidos NULL',
  (SELECT count(*) = 0 FROM public.transiciones_estado WHERE roles_permitidos IS NULL));
SELECT pg_temp.chk('R9b la salida de RECHAZADO es única (solo hacia ENTREGADO)',
  (SELECT count(*) = 1 AND bool_and(hasta = 'ENTREGADO')
     FROM public.transiciones_estado WHERE desde = 'RECHAZADO'));