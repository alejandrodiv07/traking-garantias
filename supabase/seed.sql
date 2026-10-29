-- Datos iniciales del taller (marca/producto). Sin usuarios ni claves: los
-- ADMIN se crean con la Edge Function `admin-crear-usuario`.
-- Idempotente: puede recargarse sin duplicar (WHERE NOT EXISTS).

INSERT INTO public.marcas (nombre)
SELECT btrim(m) FROM unnest(ARRAY['Huawei','TP-Link','MikroTik','Deco Prime']) AS m
WHERE NOT EXISTS (SELECT 1 FROM public.marcas WHERE lower(btrim(nombre)) = lower(btrim(m)));

INSERT INTO public.productos (marca_id, modelo, categoria, meses_garantia)
SELECT ma.id, p.modelo, p.categoria, p.meses
FROM (VALUES
  ('Huawei',    'HG8245',   'ONT',        12),
  ('Huawei',    'HG8145V5', 'ONT',        12),
  ('TP-Link',   'Archer C6','ROUTER',     24),
  ('TP-Link',   'Archer A5','ROUTER',     12),
  ('MikroTik',  'hAP ac²',  'ROUTER',     24),
  ('MikroTik',  'CRS106',   'SWITCH',     24),
  ('Deco Prime','DP-750',   'REPETIDOR',  6),
  ('Deco Prime','DP-1200',  'REPETIDOR',  6)
) AS p(marca, modelo, categoria, meses)
JOIN public.marcas ma ON ma.nombre = p.marca
WHERE NOT EXISTS (
  SELECT 1 FROM public.productos pr
  WHERE pr.marca_id = ma.id AND lower(btrim(pr.modelo)) = lower(btrim(p.modelo))
);