-- =====================================================================
--  Prime Telecom · Track Garantía
--  Migración 5 — VÁLVULA DE ESCAPE DEL TOKEN DE CONSULTA
--  PostgreSQL 17 / Supabase · 2026-09-08
--
--  EL PROBLEMA QUE RESUELVE
--  `crear_orden()` devuelve el token de consulta en claro UNA sola vez; en
--  la tabla queda solo su SHA-256. Es lo correcto: un volcado de
--  `garantias` no permite consultar nada. Pero tiene una consecuencia dura
--  en el mostrador: si el comprobante se pierde, se moja o el navegador se
--  cerró antes de anotarlo, ese cliente pierde para siempre el acceso al
--  portal público de su orden, y NADIE puede devolvérselo — ni el ADMIN,
--  ni el SQL Editor, ni service_role.
--
--  Esta función es la salida: no recupera el token viejo (imposible por
--  diseño), emite uno nuevo.
--
--  LO QUE CUESTA, Y HAY QUE DECIRLE AL CLIENTE
--  Regenerar INVALIDA el token anterior. El papel que el cliente tenga en
--  la mano deja de servir en el momento en que alguien pulsa este botón.
--  No es reversible.
--
--  POR QUÉ DEJA RASTRO
--  Una válvula de escape sin auditoría es una puerta trasera: permitiría
--  a cualquier empleado con rol de mostrador emitirse un token de acceso a
--  la orden de un cliente sin que quede constancia. El rastro va a
--  `notas_internas`, que ya es append-only (no tiene policy de UPDATE ni
--  de DELETE) y lleva autor y fecha. No se crea una tabla de auditoría
--  nueva: la que hace falta ya existe.
--
--  No se usa `historial_garantias` porque su CHECK exige
--  `estado_anterior IS DISTINCT FROM estado_nuevo`: esa tabla registra
--  transiciones de la máquina de estados, y regenerar un token no lo es.
-- =====================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.regenerar_token_orden(p_orden_id UUID)
RETURNS TABLE (
    numero_orden   TEXT,
    consulta_token TEXT   -- TEXTO PLANO. Otra vez: una sola oportunidad.
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_token TEXT;
    v_actor UUID := auth.uid();
    v_num   TEXT;
BEGIN
    -- Mismos roles que crear_orden(). El TECNICO queda fuera a propósito:
    -- no atiende al cliente en el mostrador, así que no tiene motivo para
    -- emitir credenciales de consulta.
    IF NOT public.tiene_rol('ADMIN','JEFE_SERVICIO','RECEPCION') THEN
        RAISE EXCEPTION 'Su rol no puede regenerar el token de consulta'
            USING ERRCODE = '42501';
    END IF;

    v_token := encode(extensions.gen_random_bytes(16), 'hex');

    -- SECURITY DEFINER: esto se salta la RLS de `garantias`, y es
    -- DELIBERADO. La policy `gar_update_recepcion` solo deja a RECEPCION
    -- tocar órdenes en REPARADO/IRREPARABLE/RECHAZADO_POR_CLIENTE, pero un
    -- cliente que perdió su comprobante aparece por el mostrador en
    -- cualquier momento del ciclo, no solo cuando el equipo ya está listo.
    -- Lo que esta función escribe no es dato de negocio: es la credencial
    -- de consulta del titular.
    UPDATE public.garantias g
       SET consulta_token_hash = extensions.digest(v_token, 'sha256')
     WHERE g.id = p_orden_id
    RETURNING g.numero_orden INTO v_num;

    IF v_num IS NULL THEN
        RAISE EXCEPTION 'La orden % no existe', p_orden_id
            USING ERRCODE = 'P0002';
    END IF;

    -- El rastro. Se escribe DESPUÉS del UPDATE y en la misma transacción:
    -- si el UPDATE falla no queda nota, y si la nota falla no queda token
    -- nuevo. No hay forma de rotar el token sin dejar constancia.
    INSERT INTO public.notas_internas (garantia_id, autor_id, nota)
    VALUES (p_orden_id, v_actor,
            'Token de consulta regenerado. El código entregado antes al cliente queda invalidado.');

    RETURN QUERY SELECT v_num, v_token;
END;
$$;

COMMENT ON FUNCTION public.regenerar_token_orden(UUID) IS
'Emite un token de consulta nuevo e invalida el anterior. Devuelve el token en claro una sola vez y deja nota en notas_internas.';

-- Supabase concede EXECUTE a anon y authenticated sobre toda función nueva
-- del esquema public. Se revoca nombrándolos: un REVOKE a PUBLIC no toca
-- esa concesión directa.
REVOKE ALL ON FUNCTION public.regenerar_token_orden(UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.regenerar_token_orden(UUID) TO authenticated;

COMMIT;
