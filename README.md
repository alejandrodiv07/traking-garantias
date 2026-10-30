# Track Garantía — Prime Telecom

Sistema web para el taller de servicio técnico: el técnico **registra un equipo por su serial** (con fotos, documentos y lector de código de barras), consulta el **Tablero** ordenado por urgencia (días que le quedan a la garantía y días que lleva en reparación) y **anota revisiones** cuyo resultado lo calcula la base y no se puede alterar.

## Stack

- **Frontend:** React 19 + Vite 8, pnpm 10, Node ≥ 22.12
- **Base de datos y autorización:** Supabase (PostgreSQL 17 con RLS, triggers y funciones RPC)
- **Tareas programadas:** Edge Functions de Supabase (Deno) + pg_cron
- **Pruebas:** Postgres 17 en Docker para el SQL · vitest + Testing Library para el frontend
- **CI:** GitHub Actions (migraciones, pruebas SQL, vitest, lint y build)

## Cómo correrlo

```bash
# Frontend
cd frontend
pnpm install
# crea frontend/.env.local con:
#   VITE_SUPABASE_URL=https://<proyecto>.supabase.co
#   VITE_SUPABASE_ANON_KEY=<clave anon>
pnpm dev          # Vite en :5173

# Pruebas
pnpm test                             # vitest (181 pruebas)
bash supabase/tests/run.sh            # SQL: 237 aserciones sobre Postgres 17 en Docker
bash scripts/e2e-registro.sh          # punta a punta del registro
bash scripts/verificar-migraciones.sh # historial de migraciones sin duplicados

# Verificación completa (lo que hace la CI)
pnpm test && pnpm lint && pnpm build && bash supabase/tests/run.sh
```

La cadena de migraciones canónica está en `supabase/migrations/` (de `0001_auth_base` a `0011_limpieza_huerfanos`); el monolito antiguo quedó en `supabase/archivo/` y no se aplica. `supabase/seed.sql` deja el catálogo de marcas y productos.

## Documentación

- [Estado del proyecto](ESTADO_DEL_PROYECTO.md) — qué existe hoy, deuda y pendientes
- [Diseño del hito 1](docs/superpowers/specs/2026-10-29-registro-y-control-de-garantia-design.md) — reglas de negocio (vigencia, cobertura, urgencia, permisos)
- [Plan de implementación](docs/superpowers/plans/2026-10-29-registro-y-control-de-garantia.md) — el orden de construcción y sus verificaciones