-- =====================================================================
--  20261030000016_rechazado_transiciones.sql
--  Estado RECHAZADO y cierre de roles de la máquina de transiciones
--  (Tarea 6 de la fase 2a; spec §4.6, §5.2 y §7).
--
--  RECHAZADO es la DECISIÓN DEL TALLER de no reparar el equipo: la
--  exige un motivo con sustancia (`ck_rechazo_motivado`, puesto por la
--  0015) y su única salida es ENTREGADO — no es terminal porque el
--  equipo igual se le devuelve al cliente. Con la migración también se
--  cierra la puerta de las transiciones "cualquier rol" (roles_permitidos
--  NULL): cada una queda con su lista exacta de roles, y RECEPCION pasa a
--  poder solo lo suyo (entregar, y recepcionar la decisión del cliente).
-- =====================================================================

-- ---------------------------------------------------------------------
--  1. EL ESTADO NUEVO (orden 85: entra entre RECHAZADO_POR_CLIENTE (80)
--     y ENTREGADO (90) para leerse junto a la otra salida sin entrega)
-- ---------------------------------------------------------------------
INSERT INTO public.estados_garantia (codigo, nombre, descripcion, orden, es_final)
VALUES ('RECHAZADO', 'Rechazado',
        'El taller decide no reparar el equipo; se devuelve con el motivo registrado',
        85, FALSE);

-- ---------------------------------------------------------------------
--  2. LAS CUATRO TRANSICIONES NUEVAS
--  Las tres entradas a RECHAZADO son decisión del taller (ADMIN o
--  JEFE_SERVICIO; el técnico propone, no decide). La salida única a
--  ENTREGADO la ejecuta el mismo trío que entrega REPARADO e
--  IRREPARABLE (recepciona la RECEPCION).
-- ---------------------------------------------------------------------
INSERT INTO public.transiciones_estado (desde, hasta, roles_permitidos) VALUES
    ('RECIBIDO',       'RECHAZADO', ARRAY['ADMIN', 'JEFE_SERVICIO']::public.app_role[]),
    ('EN_DIAGNOSTICO', 'RECHAZADO', ARRAY['ADMIN', 'JEFE_SERVICIO']::public.app_role[]),
    ('PRESUPUESTADO',  'RECHAZADO', ARRAY['ADMIN', 'JEFE_SERVICIO']::public.app_role[]),
    ('RECHAZADO',      'ENTREGADO', ARRAY['ADMIN', 'JEFE_SERVICIO', 'RECEPCION']::public.app_role[]);

-- ---------------------------------------------------------------------
--  3. CIERRE DE ROLES: ninguna transición queda ya con roles_permitidos
--     NULL ("cualquier rol con UPDATE sobre la fila"). Un UPDATE global
--     por el patrón del NULL no distingue la excepción, así que las 14
--     transiciones van UNA POR UNA con su lista exacta:
--       * Las operativas del taller: ADMIN + JEFE_SERVICIO + TECNICO.
--       * Las cuatro que recepcionan la decisión del cliente (aceptar
--         el presupuesto y partir a reparar, o rechazarlo) también
--         llevan RECEPCION.
-- ---------------------------------------------------------------------
UPDATE public.transiciones_estado
   SET roles_permitidos = ARRAY['ADMIN', 'JEFE_SERVICIO', 'TECNICO']::public.app_role[]
 WHERE desde = 'RECIBIDO'        AND hasta = 'EN_DIAGNOSTICO';

UPDATE public.transiciones_estado
   SET roles_permitidos = ARRAY['ADMIN', 'JEFE_SERVICIO', 'TECNICO']::public.app_role[]
 WHERE desde = 'EN_DIAGNOSTICO'  AND hasta = 'PRESUPUESTADO';

UPDATE public.transiciones_estado
   SET roles_permitidos = ARRAY['ADMIN', 'JEFE_SERVICIO', 'TECNICO']::public.app_role[]
 WHERE desde = 'EN_DIAGNOSTICO'  AND hasta = 'EN_REPARACION';

UPDATE public.transiciones_estado
   SET roles_permitidos = ARRAY['ADMIN', 'JEFE_SERVICIO', 'TECNICO']::public.app_role[]
 WHERE desde = 'EN_DIAGNOSTICO'  AND hasta = 'IRREPARABLE';

UPDATE public.transiciones_estado
   SET roles_permitidos = ARRAY['ADMIN', 'JEFE_SERVICIO', 'TECNICO']::public.app_role[]
 WHERE desde = 'PRESUPUESTADO'   AND hasta = 'EN_ESPERA_REPUESTO';

-- Excepción 1: la decisión del cliente la recepciona RECEPCION.
UPDATE public.transiciones_estado
   SET roles_permitidos = ARRAY['ADMIN', 'JEFE_SERVICIO', 'TECNICO', 'RECEPCION']::public.app_role[]
 WHERE desde = 'PRESUPUESTADO'   AND hasta = 'EN_REPARACION';

-- Excepción 2: idem, la negativa del cliente.
UPDATE public.transiciones_estado
   SET roles_permitidos = ARRAY['ADMIN', 'JEFE_SERVICIO', 'TECNICO', 'RECEPCION']::public.app_role[]
 WHERE desde = 'PRESUPUESTADO'   AND hasta = 'RECHAZADO_POR_CLIENTE';

UPDATE public.transiciones_estado
   SET roles_permitidos = ARRAY['ADMIN', 'JEFE_SERVICIO', 'TECNICO']::public.app_role[]
 WHERE desde = 'PRESUPUESTADO'   AND hasta = 'IRREPARABLE';

-- Excepción 3: el repuesto llegó y el cliente ya aprobó (misma decisión
-- del presupuesto, tomada con la orden esperando la pieza).
UPDATE public.transiciones_estado
   SET roles_permitidos = ARRAY['ADMIN', 'JEFE_SERVICIO', 'TECNICO', 'RECEPCION']::public.app_role[]
 WHERE desde = 'EN_ESPERA_REPUESTO' AND hasta = 'EN_REPARACION';

UPDATE public.transiciones_estado
   SET roles_permitidos = ARRAY['ADMIN', 'JEFE_SERVICIO', 'TECNICO']::public.app_role[]
 WHERE desde = 'EN_ESPERA_REPUESTO' AND hasta = 'IRREPARABLE';

-- Excepción 4: idem, el cliente desiste con la orden en espera.
UPDATE public.transiciones_estado
   SET roles_permitidos = ARRAY['ADMIN', 'JEFE_SERVICIO', 'TECNICO', 'RECEPCION']::public.app_role[]
 WHERE desde = 'EN_ESPERA_REPUESTO' AND hasta = 'RECHAZADO_POR_CLIENTE';

UPDATE public.transiciones_estado
   SET roles_permitidos = ARRAY['ADMIN', 'JEFE_SERVICIO', 'TECNICO']::public.app_role[]
 WHERE desde = 'EN_REPARACION'   AND hasta = 'REPARADO';

UPDATE public.transiciones_estado
   SET roles_permitidos = ARRAY['ADMIN', 'JEFE_SERVICIO', 'TECNICO']::public.app_role[]
 WHERE desde = 'EN_REPARACION'   AND hasta = 'IRREPARABLE';

UPDATE public.transiciones_estado
   SET roles_permitidos = ARRAY['ADMIN', 'JEFE_SERVICIO', 'TECNICO']::public.app_role[]
 WHERE desde = 'EN_REPARACION'   AND hasta = 'EN_ESPERA_REPUESTO';

-- Guardia del cierre: si alguien añade una transición en NULL y este
-- archivo vuelve a correr, o se escapó una del listado de arriba, la
-- migración muere en lugar de dejar la puerta abierta en silencio.
DO $$
DECLARE c_null integer;
BEGIN
    SELECT count(*) INTO c_null
      FROM public.transiciones_estado WHERE roles_permitidos IS NULL;
    IF c_null <> 0 THEN
        RAISE EXCEPTION 'Quedan % transiciones con roles_permitidos NULL tras el cierre', c_null
            USING ERRCODE = 'P0001';
    END IF;
END $$;

-- ---------------------------------------------------------------------
--  4. RLS: la policy de recepción por estado
--  RECEPCION solo cierra la entrega (y ahora también entrega la decisión
--  de RECHAZADO, que es una salida a ENTREGADO como las otras dos). La
--  decisión del cliente sobre PRESUPUESTADO/EN_ESPERA_REPUESTO sigue sin
--  pasar por aquí: la recepciona RECEPCION por el permiso de la
--  TRANSICIÓN, no por esta policy (ver R7 en 22_rechazado_transiciones).
-- ---------------------------------------------------------------------
DROP POLICY reg_update_recepcion ON public.ordenes_servicio;

CREATE POLICY reg_update_recepcion ON public.ordenes_servicio
    FOR UPDATE TO authenticated
    USING (public.tiene_rol('RECEPCION') AND estado IN
           ('REPARADO', 'IRREPARABLE', 'RECHAZADO_POR_CLIENTE', 'RECHAZADO'))
    WITH CHECK (public.tiene_rol('RECEPCION'));