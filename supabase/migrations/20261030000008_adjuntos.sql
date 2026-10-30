-- =====================================================================
--  20261030000008_adjuntos.sql
--  Tabla `adjuntos` (spec §5.4) y bucket privado `registros`.
--  Fotos JPG/PNG/WEBP ≤ 8 MB, hasta 8 por registro; documentos
--  PDF/JPG/PNG ≤ 8 MB, hasta 6. SOLO DE ANEXAR, como las revisiones.
--  Los archivos viven en el bucket PRIVADO de Supabase Storage; aquí
--  solo se registra la fila con su ruta, MIME y tamaño.
-- =====================================================================

CREATE TABLE public.adjuntos (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    registro_id UUID NOT NULL REFERENCES public.registros(id) ON DELETE RESTRICT,
    revision_id UUID REFERENCES public.revisiones(id) ON DELETE RESTRICT,
    -- FOTO o DOCUMENTO; las reglas de mime/cantidad se aplican por trigger.
    tipo        TEXT NOT NULL CHECK (tipo IN ('FOTO', 'DOCUMENTO')),
    etiqueta    TEXT,
    -- Ruta dentro del bucket: registros/{registro_id}/…; la política de
    -- storage la refuerza también.
    ruta        TEXT NOT NULL UNIQUE CHECK (ruta ~ '^registros/.+/.+'),
    mime        TEXT NOT NULL,
    bytes       BIGINT NOT NULL CHECK (bytes > 0),
    subido_por  UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
    subido_en   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_adjuntos_registro ON public.adjuntos (registro_id, subido_en DESC);
CREATE INDEX idx_adjuntos_revision ON public.adjuntos (revision_id);

-- ---------------------------------------------------------------------
--  1. VALIDACIÓN DEL ARCHIVO (BEFORE INSERT)
-- ---------------------------------------------------------------------
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
    -- Tipo de archivo según uso.
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

    -- Tamaño.
    IF NEW.bytes > v_tope THEN
        RAISE EXCEPTION
            'El archivo no puede pesar más de 8 MB (recibido: %), y el límite es común a fotos y documentos',
            round(NEW.bytes / (1024.0 * 1024), 1)
            USING ERRCODE = '22P02';
    END IF;

    -- Cantidad por registro: 8 fotos, 6 documentos.
    SELECT count(*) FILTER (WHERE tipo = 'FOTO') INTO v_fotos
      FROM public.adjuntos WHERE registro_id = NEW.registro_id;
    IF NEW.tipo = 'FOTO' AND v_fotos >= 8 THEN
        RAISE EXCEPTION 'El registro ya tiene 8 fotos: no se admiten más'
            USING ERRCODE = '22P02';
    END IF;
    SELECT count(*) FILTER (WHERE tipo = 'DOCUMENTO') INTO v_docs
      FROM public.adjuntos WHERE registro_id = NEW.registro_id;
    IF NEW.tipo = 'DOCUMENTO' AND v_docs >= 6 THEN
        RAISE EXCEPTION 'El registro ya tiene 6 documentos: no se admiten más'
            USING ERRCODE = '22P02';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_adjuntos_validar
    BEFORE INSERT ON public.adjuntos
    FOR EACH ROW EXECUTE FUNCTION public.validar_adjunto();

-- ---------------------------------------------------------------------
--  2. SOLO DE ANEXAR (igual que revisiones)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.adjuntos_solo_anexar()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
    -- Se aplica por fila (UPDATE/DELETE) y por sentencia (TRUNCATE).
    RAISE EXCEPTION 'adjuntos es solo de anexar: % no está permitido', TG_OP
        USING ERRCODE = '42501';
END;
$$;

CREATE TRIGGER trg_adjuntos_inmutables
    BEFORE UPDATE OR DELETE ON public.adjuntos
    FOR EACH ROW EXECUTE FUNCTION public.adjuntos_solo_anexar();

CREATE TRIGGER trg_adjuntos_inmutables_truncate
    BEFORE TRUNCATE ON public.adjuntos
    FOR EACH STATEMENT EXECUTE FUNCTION public.adjuntos_solo_anexar();

-- ---------------------------------------------------------------------
--  3. PERMISOS: subir adjuntos es registrar trazabilidad, lo hacen los
--     roles internos; anon nada. Nadie edita ni borra (trigger arriba).
-- ---------------------------------------------------------------------
ALTER TABLE public.adjuntos ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.adjuntos FROM PUBLIC, anon, authenticated, service_role;
-- El UPDATE/DELETE los bloquea el trigger con mensaje claro; los GRANT
-- garantizan que el rechazo llegue al trigger y no a "permission denied".
GRANT SELECT, INSERT, UPDATE, DELETE ON public.adjuntos TO authenticated, service_role;

CREATE POLICY adj_select ON public.adjuntos
    FOR SELECT TO authenticated
    USING (public.mi_rol() IN ('ADMIN', 'JEFE_SERVICIO', 'TECNICO', 'RECEPCION'));

CREATE POLICY adj_insert ON public.adjuntos
    FOR INSERT TO authenticated
    WITH CHECK (subido_por = auth.uid());

-- ---------------------------------------------------------------------
--  4. BUCKET PRIVADO Y POLÍTICAS POR RUTA
-- ---------------------------------------------------------------------
-- Ruta obligatoria: registros/{registro_id}/… . El primer segmento debe
-- ser el id de un registro existente; nadie escribe fuera de ese patrón
-- (en este hito, fuera de "un registro existente", sin cuotas por usuario).
-- El guardia de formato primero: sin él, un segmento no-uuid (p. ej.
-- "otra-cosa") fallaría con "invalid input syntax" en vez de RLS.
INSERT INTO storage.buckets (id, name, public)
VALUES ('registros', 'registros', false)
ON CONFLICT (id) DO UPDATE SET public = false;

CREATE POLICY storage_subir_adjunto ON storage.objects
    FOR INSERT TO authenticated
    WITH CHECK (
        bucket_id = 'registros'
        AND public.mi_rol() IS NOT NULL
        AND split_part(name, '/', 1) ~ '^[0-9a-f-]{36}$'
        AND split_part(name, '/', 1)::uuid IN (SELECT r.id FROM public.registros r)
    );

CREATE POLICY storage_ver_adjunto ON storage.objects
    FOR SELECT TO authenticated
    USING (
        bucket_id = 'registros'
        AND public.mi_rol() IS NOT NULL
        AND split_part(name, '/', 1) ~ '^[0-9a-f-]{36}$'
        AND split_part(name, '/', 1)::uuid IN (SELECT r.id FROM public.registros r)
    );

-- anon no queda con ningún acceso al bucket: no se escriben políticas
-- para anon y el GRANT del esquema storage ya lo excluye de las tablas.