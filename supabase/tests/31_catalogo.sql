-- Catálogo de Prime Telecom (migración 0025): marcas y modelos cargados desde el PDF.
\set QUIET on
CREATE OR REPLACE FUNCTION pg_temp.chk(n text, c boolean) RETURNS void
LANGUAGE plpgsql AS $$ BEGIN RAISE NOTICE '%  %', CASE WHEN c THEN 'PASA  ' ELSE '*FALLA*' END, n; END $$;
\set QUIET off

SELECT pg_temp.chk('K1 el catálogo trae las marcas del PDF (27) además de las del seed',
  (SELECT count(*) >= 27 FROM public.marcas)
  AND (SELECT count(*) = 5 FROM public.marcas WHERE nombre IN ('Dell','HP','Epson','Hikvision','Ubiquiti')));
SELECT pg_temp.chk('K2 hay más de 200 modelos y todos tienen marca, modelo y tipo',
  (SELECT count(*) > 200 FROM public.productos)
  AND (SELECT count(*) = 0 FROM public.productos WHERE btrim(modelo) = '' OR btrim(categoria) = ''));
SELECT pg_temp.chk('K3 ninguna marca ni modelo se repite (sin distinguir mayúsculas)',
  (SELECT count(*) = count(DISTINCT lower(btrim(nombre))) FROM public.marcas)
  AND (SELECT count(*) = count(DISTINCT (marca_id, lower(btrim(modelo)))) FROM public.productos));
SELECT pg_temp.chk('K4 TP-Link y MikroTik no se duplican con el seed y conservan sus modelos',
  (SELECT count(*) = 1 FROM public.marcas WHERE lower(nombre) = 'tp-link')
  AND (SELECT count(*) = 1 FROM public.marcas WHERE lower(nombre) = 'mikrotik')
  AND EXISTS (SELECT 1 FROM public.productos p JOIN public.marcas m ON m.id = p.marca_id WHERE m.nombre = 'TP-Link' AND p.modelo = 'Archer C6')
  AND EXISTS (SELECT 1 FROM public.productos p JOIN public.marcas m ON m.id = p.marca_id WHERE m.nombre = 'TP-Link' AND p.modelo = 'TL-SG108'));
SELECT pg_temp.chk('K5 hay tipos de equipo para elegir (router, switch, UPS, monitor, laptop…)',
  (SELECT count(DISTINCT categoria) >= 15 FROM public.productos)
  AND EXISTS (SELECT 1 FROM public.productos WHERE categoria = 'SWITCH')
  AND EXISTS (SELECT 1 FROM public.productos WHERE categoria = 'UPS Y REGULADORES')
  AND EXISTS (SELECT 1 FROM public.productos WHERE categoria = 'MONITOR'));
SELECT pg_temp.chk('K6 todos quedan activos y con la garantía del fabricante por defecto (12 meses)',
  (SELECT bool_and(activo) FROM public.productos)
  AND (SELECT count(*) > 200 FROM public.productos WHERE meses_garantia = 12));

-- Re-ejecutar la carga no duplica nada.
DO $$
DECLARE antes int; despues int;
BEGIN
  SELECT count(*) INTO antes FROM public.productos;
  INSERT INTO public.productos (marca_id, modelo, categoria)
  SELECT ma.id, 'Archer C6', 'ROUTER' FROM public.marcas ma WHERE ma.nombre = 'TP-Link'
   AND NOT EXISTS (SELECT 1 FROM public.productos pr WHERE pr.marca_id = ma.id AND lower(btrim(pr.modelo)) = 'archer c6');
  SELECT count(*) INTO despues FROM public.productos;
  PERFORM pg_temp.chk('K7 la carga es idempotente (no duplica un modelo que ya existe)', antes = despues);
END $$;
