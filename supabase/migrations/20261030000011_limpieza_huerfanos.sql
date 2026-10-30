-- =====================================================================
--  20261030000011_limpieza_huerfanos.sql
--  Limpieza de archivos huérfanos (spec §5.7): el único flujo que BORRA
--  archivos, y solo los del almacenamiento que NO tienen fila en
--  `adjuntos` y ya tienen más de 24 horas (no se tocan subidas en curso).
--  Las filas de `adjuntos` nunca se tocan aquí.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.listar_huerfanos(p_gracia interval DEFAULT interval '24 hours')
RETURNS TABLE (nombre text)
LANGUAGE sql
STABLE
AS $$
  SELECT o.name
    FROM storage.objects o
   WHERE o.bucket_id = 'registros'
     AND o.created_at < now() - p_gracia
     AND NOT EXISTS (SELECT 1 FROM public.adjuntos a WHERE a.ruta = o.name);
$$;

-- Solo la ejecuta el borrador programado (la Edge Function con service_role).
REVOKE ALL ON FUNCTION public.listar_huerfanos(interval)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.listar_huerfanos(interval) TO service_role;

-- ---------------------------------------------------------------------
--  PROGRAMACIÓN DIARIA — solo si pg_cron y pg_net existen (el Postgres
--  de pruebas no los tiene: la prueba pasa sin ellos). El secreto y la
--  URL del proyecto no pueden cocinarse en una migración versionada:
--  se leen de los ajustes de la base (ALTER DATABASE … SET app.*) que
--  el despliegue define una vez.
-- ---------------------------------------------------------------------
DO $bloque$
BEGIN
  IF to_regnamespace('cron') IS NOT NULL AND to_regnamespace('net') IS NOT NULL THEN
    IF coalesce(current_setting('app.limpieza_secret', true), '') <> '' THEN
      PERFORM cron.schedule(
        'limpiar-adjuntos-huerfanos',
        '7 6 * * *',   -- 06:07 UTC = 02:07 en Caracas, después de la medianoche
        format(
          $$SELECT net.http_post(
               url     := %L,
               headers := jsonb_build_object('Content-Type', 'application/json',
                                             'x-cron-secret', current_setting('app.limpieza_secret'))
           )$$,
          'https://' || current_setting('app.proyecto_ref', true) || '.supabase.co/functions/v1/limpiar-huerfanos'
        )
      );
    ELSE
      RAISE NOTICE 'app.limpieza_secret sin definir: el job de limpieza NO se agenda (ver README, post-despliegue).';
    END IF;
  END IF;
END
$bloque$;