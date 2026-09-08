-- =====================================================================
--  Prime Telecom · Track Garantía
--  Migración 6 — DOCUMENTOS DE LA ORDEN (documentos_garantia)
--  PostgreSQL 17 / Supabase · 2026-09-08
--
--  Fase 2 del Blueprint, extendida tras la ronda de grilling del
--  2026-09-08: el alta de orden permite adjuntar documentos (factura
--  escaneada, fotos del equipo), opcional. Ver
--  docs/specs/2026-09-08-tablero-taller-design.md §2.5 y ADR-012.
--
--  LO QUE ESTA MIGRACIÓN NO HACE
--  No toca `crear_orden()`. La subida de documentos NO es atómica con la
--  creación de la orden -- Storage no participa de una transacción SQL --
--  así que esta migración solo define dónde vive el metadato y el
--  binario; el frontend sube los archivos después de recibir el
--  `orden_id` de `crear_orden()` (P7 del plan de ejecución).
--
--  SIN UPDATE NI DELETE
--  No hay política de UPDATE/DELETE sobre `documentos_garantia` ni de
--  UPDATE/DELETE sobre `storage.objects` de este bucket. Editar o borrar
--  documentos pertenece a la ficha de detalle de la orden (Fase 2.1), que
--  todavía no existe. Dar esos permisos ahora sería una puerta sin pared.
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------------
-- 1. Tipo y tabla de metadatos
-- ---------------------------------------------------------------------

CREATE TYPE public.tipo_documento_garantia AS ENUM ('FACTURA','FOTO_EQUIPO','OTRO');

CREATE TABLE public.documentos_garantia (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    garantia_id     UUID NOT NULL REFERENCES public.garantias(id) ON DELETE CASCADE,
    tipo            public.tipo_documento_garantia NOT NULL,

    -- Path DENTRO del bucket, nunca una URL: el bucket es privado y el
    -- acceso siempre es por URL firmada de corta duración, generada en
    -- el momento de la lectura. Guardar una URL fija sería guardar un
    -- acceso permanente por si algún día ese registro se filtra.
    ruta_storage    TEXT NOT NULL,

    nombre_original TEXT NOT NULL CHECK (btrim(nombre_original) <> ''),

    -- Espejo del file_size_limit del bucket (§2 más abajo). Si alguna vez
    -- divergen, esta es la que protege la fila aunque el bucket cambie.
    tamano_bytes    INTEGER NOT NULL CHECK (tamano_bytes > 0 AND tamano_bytes <= 10485760),

    subido_por      UUID NOT NULL REFERENCES public.profiles(id),
    creado_en       TIMESTAMPTZ NOT NULL DEFAULT now(),

    UNIQUE (garantia_id, ruta_storage)
);

CREATE INDEX idx_documentos_garantia_orden ON public.documentos_garantia (garantia_id);

COMMENT ON TABLE public.documentos_garantia IS
    'Metadatos de archivos adjuntos a una orden (factura, fotos del equipo). '
    'Opcional; la subida ocurre después de crear_orden(), no dentro de ella '
    '(ver ADR-012). Los binarios viven en el bucket documentos-garantias.';

-- ---------------------------------------------------------------------
-- 2. RLS de la tabla de metadatos
-- ---------------------------------------------------------------------

ALTER TABLE public.documentos_garantia ENABLE ROW LEVEL SECURITY;

-- Misma regla que gar_select (migración 2, §11): son cuatro personas en
-- un taller, todo authenticated ve todo. La restricción real está en la
-- escritura, no en la lectura.
CREATE POLICY doc_gar_select ON public.documentos_garantia
    FOR SELECT
    TO authenticated
    USING (true);

-- Mismos roles que pueden ejecutar crear_orden(): ADMIN, JEFE_SERVICIO,
-- RECEPCION. TECNICO no sube documentos en esta fase porque no crea
-- órdenes; si alguna vez sube evidencia durante el diagnóstico, esa es
-- una regla nueva de la Fase 2.1, no de esta migración.
CREATE POLICY doc_gar_insert ON public.documentos_garantia
    FOR INSERT
    TO authenticated
    WITH CHECK (public.tiene_rol('ADMIN','JEFE_SERVICIO','RECEPCION'));

-- ---------------------------------------------------------------------
-- 3. Bucket de Storage
-- ---------------------------------------------------------------------

-- Privado (public = false): sin URL fija posible. El límite y los tipos
-- MIME son la primera barrera; el CHECK de la tabla es la segunda, por
-- si alguna vez se sube directo a Storage sin pasar por el flujo normal.
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
    'documentos-garantias',
    'documentos-garantias',
    false,
    10485760,  -- 10 MB
    ARRAY['application/pdf','image/jpeg','image/png']
)
ON CONFLICT (id) DO NOTHING;

-- Convención de path acordada con el frontend: <garantia_id>/<uuid>.<ext>
-- El primer segmento del path es lo único que estas políticas necesitan
-- para razonar sobre a qué orden pertenece un objeto -- no hace falta
-- una tabla de traducción ni tocar documentos_garantia desde aquí.
CREATE POLICY doc_storage_select ON storage.objects
    FOR SELECT
    TO authenticated
    USING (bucket_id = 'documentos-garantias');

CREATE POLICY doc_storage_insert ON storage.objects
    FOR INSERT
    TO authenticated
    WITH CHECK (
        bucket_id = 'documentos-garantias'
        AND public.tiene_rol('ADMIN','JEFE_SERVICIO','RECEPCION')
    );

-- Riesgo aceptado y documentado en el spec (§2.5): doc_storage_select no
-- cruza contra documentos_garantia.garantia_id porque storage.objects no
-- conoce esa tabla sin una función adicional. Es equivalente en efecto a
-- gar_select (todo authenticated ve todo el taller), así que no reduce
-- la seguridad ya decidida para el resto del dominio.

COMMIT;
