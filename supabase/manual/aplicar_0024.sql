-- Track Garantía: migración 20261030000024 (documentos vinculados a la garantía).
-- Pegar en el SQL Editor de Supabase. Va en UNA transacción: si algo falla, no se aplica nada.
BEGIN;

-- =====================================================================
--  20261030000024_adjuntos_garantia.sql
--  Documentos vinculados a la GARANTÍA (el equipo), no solo a la orden.
--    · adjuntos.equipo_id: un adjunto cuelga de una orden O de un equipo,
--      nunca de ambos ni de ninguno.
--    · Ruta del bucket `ordenes`: ordenes/{orden_id}/… o equipos/{equipo_id}/…
--      y debe coincidir con el id de su fila.
--    · Los topes (8 fotos, 6 documentos) y el formato se aplican por destino.
--    · Storage: las políticas de subir y ver aceptan también equipos/{equipo_id}/…
--  Sigue siendo solo de anexar: nada se edita ni se borra.
-- =====================================================================

ALTER TABLE public.adjuntos ALTER COLUMN orden_id DROP NOT NULL;
ALTER TABLE public.adjuntos
    ADD COLUMN equipo_id uuid REFERENCES public.equipos(id) ON DELETE RESTRICT;

ALTER TABLE public.adjuntos
    ADD CONSTRAINT adjuntos_un_destino CHECK ((orden_id IS NULL) <> (equipo_id IS NULL));

CREATE INDEX idx_adjuntos_equipo ON public.adjuntos (equipo_id, subido_en DESC)
    WHERE equipo_id IS NOT NULL;

ALTER TABLE public.adjuntos DROP CONSTRAINT IF EXISTS adjuntos_ruta_check;
ALTER TABLE public.adjuntos
    ADD CONSTRAINT adjuntos_ruta_check CHECK (ruta ~ '^(ordenes|equipos)/.+/.+');

-- NOT VALID: se exige a las filas nuevas sin bloquear el despliegue si alguna
-- fila antigua (datos de prueba) tuviera la ruta de otra carpeta.
ALTER TABLE public.adjuntos
    ADD CONSTRAINT adjuntos_ruta_destino CHECK (
        (orden_id IS NOT NULL AND ruta LIKE 'ordenes/' || orden_id || '/%')
        OR (equipo_id IS NOT NULL AND ruta LIKE 'equipos/' || equipo_id || '/%')
    ) NOT VALID;

-- ---- Validación del archivo (BEFORE INSERT): igual que la 0013, con los topes por destino ----
CREATE OR REPLACE FUNCTION public.validar_adjunto()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
    v_fotos   INTEGER;
    v_docs    INTEGER;
    v_tope    CONSTANT INTEGER := 8 * 1024 * 1024;   -- 8 MB
BEGIN
    IF NEW.tipo = 'FOTO' THEN
        IF NEW.mime NOT IN ('image/jpeg', 'image/png', 'image/webp') THEN
            RAISE EXCEPTION
                'Formato no admitido para FOTO: usa JPG, PNG o WEBP (recibido: %)', NEW.mime
                USING ERRCODE = '22P02';
        END IF;
    ELSE  -- DOCUMENTO
        IF NEW.mime NOT IN ('application/pdf', 'image/jpeg', 'image/png') THEN
            RAISE EXCEPTION
                'Formato no admitido para DOCUMENTO: usa PDF, JPG o PNG (recibido: %)', NEW.mime
                USING ERRCODE = '22P02';
        END IF;
    END IF;

    IF NEW.bytes > v_tope THEN
        RAISE EXCEPTION
            'El archivo no puede pesar más de 8 MB (recibido: %), y el límite es común a fotos y documentos',
            round(NEW.bytes / (1024.0 * 1024), 1)
            USING ERRCODE = '22P02';
    END IF;

    -- Cantidad por destino (orden o equipo): 8 fotos, 6 documentos.
    SELECT count(*) FILTER (WHERE tipo = 'FOTO'), count(*) FILTER (WHERE tipo = 'DOCUMENTO')
      INTO v_fotos, v_docs
      FROM public.adjuntos
     WHERE orden_id  IS NOT DISTINCT FROM NEW.orden_id
       AND equipo_id IS NOT DISTINCT FROM NEW.equipo_id;
    IF NEW.tipo = 'FOTO' AND v_fotos >= 8 THEN
        RAISE EXCEPTION 'El registro ya tiene 8 fotos: no se admiten más'
            USING ERRCODE = '22P02';
    END IF;
    IF NEW.tipo = 'DOCUMENTO' AND v_docs >= 6 THEN
        RAISE EXCEPTION 'El registro ya tiene 6 documentos: no se admiten más'
            USING ERRCODE = '22P02';
    END IF;

    RETURN NEW;
END;
$$;

-- ---- Storage: subir y ver también bajo equipos/{equipo_id}/… ----
-- El guardia de formato (uuid) va primero: sin él, un segmento que no es uuid
-- fallaría con "invalid input syntax" en vez de RLS.
DROP POLICY IF EXISTS storage_subir_adjunto ON storage.objects;
CREATE POLICY storage_subir_adjunto ON storage.objects
    FOR INSERT TO authenticated
    WITH CHECK (
        bucket_id = 'ordenes'
        AND public.mi_rol() IS NOT NULL
        AND split_part(name, '/', 2) ~ '^[0-9a-f-]{36}$'
        AND (
            (split_part(name, '/', 1) = 'ordenes'
             AND split_part(name, '/', 2)::uuid IN (SELECT o.id FROM public.ordenes_servicio o))
            OR
            (split_part(name, '/', 1) = 'equipos'
             AND split_part(name, '/', 2)::uuid IN (SELECT e.id FROM public.equipos e))
        )
    );

DROP POLICY IF EXISTS storage_ver_adjunto ON storage.objects;
CREATE POLICY storage_ver_adjunto ON storage.objects
    FOR SELECT TO authenticated
    USING (
        bucket_id = 'ordenes'
        AND public.mi_rol() IS NOT NULL
        AND split_part(name, '/', 2) ~ '^[0-9a-f-]{36}$'
        AND (
            (split_part(name, '/', 1) = 'ordenes'
             AND split_part(name, '/', 2)::uuid IN (SELECT o.id FROM public.ordenes_servicio o))
            OR
            (split_part(name, '/', 1) = 'equipos'
             AND split_part(name, '/', 2)::uuid IN (SELECT e.id FROM public.equipos e))
        )
    );

INSERT INTO supabase_migrations.schema_migrations (version, name) VALUES ('20261030000024', 'adjuntos_garantia') ON CONFLICT (version) DO NOTHING;
COMMIT;
