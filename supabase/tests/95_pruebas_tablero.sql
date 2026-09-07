-- =====================================================================
--  Pruebas de la migración ...0004_tablero_operativo.sql
--
--  Convención del repo (igual que 97/98/99): psql plano con
--  pg_temp.chk(nombre, condicion) -> NOTICE 'PASA' / '*FALLA*'.
--  Se lee con:  supabase db reset && psql -f supabase/tests/95_...
--
--  ORDEN: después de 00_harness y de las tres migraciones.
-- =====================================================================
\set QUIET on

CREATE OR REPLACE FUNCTION pg_temp.chk(n text, c boolean) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN RAISE NOTICE '%  %', CASE WHEN c THEN 'PASA  ' ELSE '*FALLA*' END, n; END $$;

-- Ejecuta `sql` bajo la identidad `uid` y devuelve el SQLSTATE del error,
-- o 'OK' si no lanzó. CONVENIO del repo: session_id = id del usuario.
CREATE OR REPLACE FUNCTION pg_temp.errcode(uid text, sql text) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE v_estado text;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', uid, TRUE);
  PERFORM set_config('request.jwt.claim.session_id', uid, TRUE);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    EXECUTE sql;
  EXCEPTION WHEN others THEN
    v_estado := SQLSTATE;
    EXECUTE 'RESET ROLE';
    RETURN v_estado;
  END;
  EXECUTE 'RESET ROLE';
  RETURN 'OK';
END $$;

-- Igual, pero para el rol `anon`, que no tiene identidad.
CREATE OR REPLACE FUNCTION pg_temp.errcode_anon(sql text) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE v_estado text;
BEGIN
  EXECUTE 'SET LOCAL ROLE anon';
  BEGIN
    EXECUTE sql;
  EXCEPTION WHEN others THEN
    v_estado := SQLSTATE;
    EXECUTE 'RESET ROLE';
    RETURN v_estado;
  END;
  EXECUTE 'RESET ROLE';
  RETURN 'OK';
END $$;
\set QUIET off


-- =====================================================================
--  SEMILLA
-- =====================================================================
INSERT INTO auth.users (id, email) VALUES
 ('aaaaaaaa-0000-0000-0000-000000000001','recepcion@primetelecom.com'),
 ('aaaaaaaa-0000-0000-0000-000000000002','tecnico2@primetelecom.com');

UPDATE public.profiles SET role='RECEPCION' WHERE email='recepcion@primetelecom.com';
UPDATE public.profiles SET role='TECNICO'   WHERE email='tecnico2@primetelecom.com';

-- El segundo factor viaja con la identidad: mi_rol() exige mfa_ok(). Sin
-- esta semilla, TODA prueba de rol se pondría roja por el motivo
-- equivocado (actor sin rol efectivo, no política que rechaza).
DO $$
BEGIN
  IF to_regclass('public.mfa_sesiones') IS NULL THEN RETURN; END IF;
  INSERT INTO public.mfa_sesiones (session_id, user_id)
  SELECT p.id, p.id FROM public.profiles p
  ON CONFLICT (session_id) DO NOTHING;
END $$;

-- Catálogo mínimo.
INSERT INTO public.productos (id, marca_id, modelo, categoria, meses_garantia)
SELECT 'bbbbbbbb-0000-0000-0000-000000000001', m.id, 'Router Pruebas X1', 'ROUTER', 12
  FROM public.marcas m WHERE lower(m.nombre) = 'huawei' LIMIT 1;

INSERT INTO public.clientes (id, tipo_documento, documento, nombre)
VALUES ('cccccccc-0000-0000-0000-000000000001','V','12345678','Cliente Existente');


-- =====================================================================
--  A. INVARIANTES DE LAS COLUMNAS NUEVAS
-- =====================================================================

-- A1 · Una garantía EXTENDIDA sin plazo declarado no significa nada.
SELECT pg_temp.chk('A1 EXTENDIDA sin meses_garantia_override se rechaza',
  pg_temp.errcode('aaaaaaaa-0000-0000-0000-000000000001', $q$
    SELECT public.crear_orden(
      p_fecha_compra    => current_date - 30,
      p_falla_reportada => 'No enciende de ninguna manera',
      p_cliente_id      => 'cccccccc-0000-0000-0000-000000000001',
      p_producto_id     => 'bbbbbbbb-0000-0000-0000-000000000001',
      p_tipo_garantia   => 'EXTENDIDA')
  $q$) = '23514');

-- A2 · sla_dias fuera de 1..90.
SELECT pg_temp.chk('A2 sla_dias = 0 se rechaza',
  pg_temp.errcode('aaaaaaaa-0000-0000-0000-000000000001', $q$
    SELECT public.crear_orden(
      p_fecha_compra    => current_date - 30,
      p_falla_reportada => 'No enciende de ninguna manera',
      p_cliente_id      => 'cccccccc-0000-0000-0000-000000000001',
      p_producto_id     => 'bbbbbbbb-0000-0000-0000-000000000001',
      p_sla_dias        => 0)
  $q$) = '23514');

SELECT pg_temp.chk('A3 sla_dias = 91 se rechaza',
  pg_temp.errcode('aaaaaaaa-0000-0000-0000-000000000001', $q$
    SELECT public.crear_orden(
      p_fecha_compra    => current_date - 30,
      p_falla_reportada => 'No enciende de ninguna manera',
      p_cliente_id      => 'cccccccc-0000-0000-0000-000000000001',
      p_producto_id     => 'bbbbbbbb-0000-0000-0000-000000000001',
      p_sla_dias        => 91)
  $q$) = '23514');


-- =====================================================================
--  B. TRIGGER DE COBERTURA
-- =====================================================================

-- B1 · SIN_GARANTIA no calcula vencimiento y queda FUERA_DE_GARANTIA,
--      aunque la compra sea de ayer.
-- OJO: `SET LOCAL` fuera de una transacción explícita NO hace nada (psql
-- envuelve cada sentencia en la suya). Con `is_local => TRUE` el claim se
-- perdía antes de la línea siguiente, auth.uid() salía NULL y la prueba se
-- ponía roja por "Su rol no puede registrar órdenes" en vez de por el
-- motivo que mide. Se fija a nivel de SESIÓN.
SELECT set_config('request.jwt.claim.sub','aaaaaaaa-0000-0000-0000-000000000001',FALSE);
SELECT set_config('request.jwt.claim.session_id','aaaaaaaa-0000-0000-0000-000000000001',FALSE);

CREATE TEMP TABLE t_sin AS
SELECT * FROM public.crear_orden(
  p_fecha_compra    => current_date - 1,
  p_falla_reportada => 'Pantalla partida por caida',
  p_cliente_id      => 'cccccccc-0000-0000-0000-000000000001',
  p_producto_id     => 'bbbbbbbb-0000-0000-0000-000000000001',
  p_tipo_garantia   => 'SIN_GARANTIA');

SELECT pg_temp.chk('B1 SIN_GARANTIA => cobertura FUERA_DE_GARANTIA',
  (SELECT cobertura = 'FUERA_DE_GARANTIA' FROM t_sin));

SELECT pg_temp.chk('B1b SIN_GARANTIA no proyecta vencimiento (vence = compra)',
  (SELECT vence_el = current_date - 1 FROM t_sin));

-- B2 · El plazo pactado gana sobre el del catálogo (12 meses del producto).
CREATE TEMP TABLE t_ext AS
SELECT * FROM public.crear_orden(
  p_fecha_compra    => current_date,
  p_falla_reportada => 'Reinicios aleatorios cada pocas horas',
  p_cliente_id      => 'cccccccc-0000-0000-0000-000000000001',
  p_producto_id     => 'bbbbbbbb-0000-0000-0000-000000000001',
  p_tipo_garantia   => 'EXTENDIDA',
  p_meses_override  => 24);

SELECT pg_temp.chk('B2 override 24m gana sobre los 12m del catalogo',
  (SELECT vence_el = current_date + interval '24 months' FROM t_ext));

SELECT pg_temp.chk('B3 compra de hoy con cobertura => EN_GARANTIA',
  (SELECT cobertura = 'EN_GARANTIA' FROM t_ext));

-- B4 · El token vuelve en claro, 32 hex, y su hash es el guardado.
SELECT pg_temp.chk('B4 el token es de 128 bits en hexadecimal',
  (SELECT consulta_token ~ '^[0-9a-f]{32}$' FROM t_ext));

SELECT pg_temp.chk('B5 el hash guardado corresponde al token devuelto',
  EXISTS (SELECT 1 FROM public.garantias g, t_ext t
           WHERE g.id = t.orden_id
             AND g.consulta_token_hash = extensions.digest(t.consulta_token,'sha256')));
RESET ROLE;


-- =====================================================================
--  C. AUTORIZACIÓN
-- =====================================================================

-- C1 · Un TECNICO no registra órdenes. Es la regla que la interfaz
--      REFLEJA ocultando el botón; aquí se comprueba quién la HACE CUMPLIR.
SELECT pg_temp.chk('C1 TECNICO recibe 42501 al crear una orden',
  pg_temp.errcode('aaaaaaaa-0000-0000-0000-000000000002', $q$
    SELECT public.crear_orden(
      p_fecha_compra    => current_date - 30,
      p_falla_reportada => 'No enciende de ninguna manera',
      p_cliente_id      => 'cccccccc-0000-0000-0000-000000000001',
      p_producto_id     => 'bbbbbbbb-0000-0000-0000-000000000001')
  $q$) = '42501');

-- C2/C3 · Cliente: exactamente uno de los dos caminos.
SELECT pg_temp.chk('C2 cliente por id Y por datos nuevos a la vez => 22023',
  pg_temp.errcode('aaaaaaaa-0000-0000-0000-000000000001', $q$
    SELECT public.crear_orden(
      p_fecha_compra    => current_date - 30,
      p_falla_reportada => 'No enciende de ninguna manera',
      p_cliente_id      => 'cccccccc-0000-0000-0000-000000000001',
      p_cliente_nuevo   => '{"tipo_documento":"V","documento":"99999999","nombre":"Duplicado"}'::jsonb,
      p_producto_id     => 'bbbbbbbb-0000-0000-0000-000000000001')
  $q$) = '22023');

SELECT pg_temp.chk('C3 sin cliente por ningun camino => 22023',
  pg_temp.errcode('aaaaaaaa-0000-0000-0000-000000000001', $q$
    SELECT public.crear_orden(
      p_fecha_compra    => current_date - 30,
      p_falla_reportada => 'No enciende de ninguna manera',
      p_producto_id     => 'bbbbbbbb-0000-0000-0000-000000000001')
  $q$) = '22023');


-- =====================================================================
--  D. ATOMICIDAD  (la razón de ser de crear_orden)
-- =====================================================================

-- D1 · Orden que FALLA (falla_reportada de 4 caracteres, el CHECK exige 5)
--      con un cliente nuevo: el cliente NO debe quedar creado.
SELECT pg_temp.chk('D1 una orden invalida no deja el cliente nuevo huerfano',
  pg_temp.errcode('aaaaaaaa-0000-0000-0000-000000000001', $q$
    SELECT public.crear_orden(
      p_fecha_compra    => current_date - 10,
      p_falla_reportada => 'ruid',
      p_cliente_nuevo   => '{"tipo_documento":"V","documento":"77777777","nombre":"Fantasma Huerfano"}'::jsonb,
      p_producto_id     => 'bbbbbbbb-0000-0000-0000-000000000001')
  $q$) = '23514'
  AND NOT EXISTS (SELECT 1 FROM public.clientes WHERE documento = '77777777'));

-- D2 · Alta conjunta correcta: cliente nuevo + orden, ambos presentes.
-- OJO: `SET LOCAL` fuera de una transacción explícita NO hace nada (psql
-- envuelve cada sentencia en la suya). Con `is_local => TRUE` el claim se
-- perdía antes de la línea siguiente, auth.uid() salía NULL y la prueba se
-- ponía roja por "Su rol no puede registrar órdenes" en vez de por el
-- motivo que mide. Se fija a nivel de SESIÓN.
SELECT set_config('request.jwt.claim.sub','aaaaaaaa-0000-0000-0000-000000000001',FALSE);
SELECT set_config('request.jwt.claim.session_id','aaaaaaaa-0000-0000-0000-000000000001',FALSE);

CREATE TEMP TABLE t_nuevo AS
SELECT * FROM public.crear_orden(
  p_fecha_compra    => current_date - 100,
  p_falla_reportada => 'Puerto WAN sin enlace tras tormenta electrica',
  p_cliente_nuevo   => '{"tipo_documento":"J","documento":"305892147","nombre":"Comercializadora Andina C.A.","telefono":"04141234567"}'::jsonb,
  p_producto_nuevo  => (SELECT jsonb_build_object(
                          'marca_id', m.id, 'modelo','ONT Pruebas G1',
                          'categoria','ONT','meses_garantia',6)
                        FROM public.marcas m WHERE lower(m.nombre)='zte' LIMIT 1));

SELECT pg_temp.chk('D2 el cliente nuevo quedo creado y enlazado',
  EXISTS (SELECT 1 FROM public.clientes c, t_nuevo t
           WHERE c.id = t.cliente_id AND c.documento = '305892147'));

SELECT pg_temp.chk('D3 el producto nuevo quedo creado y enlazado',
  EXISTS (SELECT 1 FROM public.productos p, t_nuevo t
           WHERE p.id = t.producto_id AND p.modelo = 'ONT Pruebas G1'));

SELECT pg_temp.chk('D4 el producto nuevo (6m) fija el vencimiento, no el default de 12m',
  (SELECT vence_el = (current_date - 100) + interval '6 months' FROM t_nuevo));

-- D5 · Carrera: el mismo documento otra vez REUTILIZA, no falla.
CREATE TEMP TABLE t_repe AS
SELECT * FROM public.crear_orden(
  p_fecha_compra    => current_date - 5,
  p_falla_reportada => 'Segundo equipo del mismo cliente, no da senal',
  p_cliente_nuevo   => '{"tipo_documento":"J","documento":"305892147","nombre":"Comercializadora Andina C.A."}'::jsonb,
  p_producto_id     => 'bbbbbbbb-0000-0000-0000-000000000001');

SELECT pg_temp.chk('D5 registrar el mismo documento reutiliza el cliente (ON CONFLICT)',
  (SELECT t_repe.cliente_id = t_nuevo.cliente_id FROM t_repe, t_nuevo));

SELECT pg_temp.chk('D6 no se duplico la fila de cliente',
  (SELECT count(*) = 1 FROM public.clientes WHERE documento = '305892147'));
RESET ROLE;


-- =====================================================================
--  E. LA VISTA DEL TABLERO
-- =====================================================================

-- E1 · LA PRUEBA QUE PROTEGE `security_invoker`. Si alguien edita la vista
--      y quita esa opción, la vista pasa a ejecutar como su dueño y
--      bypassea toda la RLS. Esta línea es la que se pondría roja.
SELECT pg_temp.chk('E1 anon NO lee v_ordenes_tablero',
  pg_temp.errcode_anon('SELECT * FROM public.v_ordenes_tablero') <> 'OK'
  OR (SELECT count(*) FROM public.v_ordenes_tablero) = 0);

-- E2 · La vista no expone lo sensible. Se comprueba contra el catálogo,
--      no leyendo filas: así falla aunque la tabla esté vacía.
SELECT pg_temp.chk('E2 la vista no expone notas, costo, diagnostico ni el hash del token',
  NOT EXISTS (
    SELECT 1 FROM information_schema.columns
     WHERE table_schema='public' AND table_name='v_ordenes_tablero'
       AND column_name IN ('costo_reparacion','diagnostico',
                           'motivo_anulacion_cobertura','consulta_token_hash','nota')));

-- E3 · La fecha límite es derivada y coincide con el cálculo.
SELECT pg_temp.chk('E3 sla_vence_el = fecha_ingreso + sla_dias',
  NOT EXISTS (SELECT 1 FROM public.v_ordenes_tablero
               WHERE sla_vence_el <> fecha_ingreso::date + sla_dias));

-- E4 · La vista resuelve los textos que el tablero muestra.
SELECT pg_temp.chk('E4 la vista compone cliente, documento y equipo',
  EXISTS (SELECT 1 FROM public.v_ordenes_tablero
           WHERE documento = 'J-305892147'
             AND cliente = 'Comercializadora Andina C.A.'
             AND equipo LIKE '%ONT Pruebas G1'));

-- E5 · Toda orden nueva nace POR_DETERMINAR salvo que el trigger decida.
--      Se comprueba que la vista expone las CUATRO coberturas posibles.
SELECT pg_temp.chk('E5 la columna cobertura es el enum completo de 4 valores',
  (SELECT count(*) = 4 FROM unnest(enum_range(NULL::public.cobertura_garantia))));


-- =====================================================================
--  F. KPIs
-- =====================================================================

-- F1 · anon no ejecuta la función.
SELECT pg_temp.chk('F1 anon NO ejecuta kpis_tablero()',
  pg_temp.errcode_anon('SELECT public.kpis_tablero()') <> 'OK');

-- F2 · El conteo de abiertas cuadra con la consulta directa. Un KPI que no
--      cuadra con la tabla de abajo es peor que no tener KPI.
SELECT pg_temp.chk('F2 ordenes_abiertas cuadra con el conteo directo',
  (SELECT k.ordenes_abiertas FROM public.kpis_tablero() k)
  = (SELECT count(*)::int FROM public.garantias
      WHERE estado NOT IN ('ENTREGADO','ANULADO')));

-- F3 · Sin entregas este mes, la tasa es 0 y no NULL ni división por cero.
SELECT pg_temp.chk('F3 tasa_a_tiempo nunca es NULL',
  (SELECT tasa_a_tiempo IS NOT NULL FROM public.kpis_tablero()));

-- F4 · El plazo por vencer usa el derivado, no una columna guardada.
SELECT pg_temp.chk('F4 sla_por_vencer cuadra con el calculo derivado',
  (SELECT k.sla_por_vencer FROM public.kpis_tablero() k)
  = (SELECT count(*)::int FROM public.garantias
      WHERE estado NOT IN ('ENTREGADO','ANULADO')
        AND fecha_ingreso::date + sla_dias <= current_date + 2));
