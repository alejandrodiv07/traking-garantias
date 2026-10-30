# Track Garantía — Prime Telecom

Sistema web para el taller de servicio técnico, en tres módulos unidos por el **serial** del equipo:

1. **Registrar garantía** (post-venta): cliente, serial, factura y plazo (7 o 15 días).
2. **Consulta**: se busca por serial, cédula/RIF, factura u orden; dice si el equipo está en vigencia, cuántos días quedan y su historial de órdenes. Desde ahí se abre la orden o, si el serial no existe, se registra ahí mismo (queda por confirmar).
3. **Taller**: la orden `OS-AAAA-NNNN` con su **auditoría de recepción** (checklist, fotos y documentos), diagnóstico y presupuesto, bitácora y los estados hasta la entrega o el rechazo con motivo.

La cobertura (en garantía, fuera, anulada por uso o por determinar) y las reglas de avance las calcula y las impone la base de datos, no la interfaz.

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
pnpm test                             # vitest (312 pruebas)
bash supabase/tests/run.sh            # SQL: 23 archivos, 436 aserciones, Postgres 17 en Docker
bash scripts/e2e-registro.sh          # punta a punta: garantía → consulta → orden → rechazo → entrega
bash scripts/verificar-migraciones.sh # historial de migraciones sin duplicados

# Verificación completa (lo que hace la CI)
pnpm test && pnpm lint && pnpm build && bash supabase/tests/run.sh
```

La suite SQL levanta un contenedor por corrida y una base nueva por archivo; si la máquina anda justa de memoria, se puede correr por tandas pasando los archivos: `bash supabase/tests/run.sh supabase/tests/24_rpc_garantia.sql …`.

## Base de datos

La cadena de migraciones está en `supabase/migrations/` (de `0001_auth_base` a `0022`). La fase 2a añade:

| Migración | Qué hace |
|---|---|
| 0013 | Renombra `registros` → `ordenes_servicio` (`OS-AAAA-NNNN`), bucket `ordenes` |
| 0014 | Origen `VENTA`/`TALLER`, desestimación de compra y precedencia nueva de cobertura |
| 0015 | `tipo_atencion` generado, motivo de rechazo y bitácora de eventos |
| 0016 | Estado `RECHAZADO` (única salida: `ENTREGADO`) y roles cerrados en las transiciones |
| 0017 | Reglas de avance impuestas por la base (foto, documento, presupuesto, pago) |
| 0018 | `registrar_garantia`, `buscar_equipo` multicriterio y la vista `v_garantias` |
| 0019 | `abrir_orden` por equipo (orden + auditoría de recepción en una transacción, idempotente) |
| 0020 | `confirmar_compra` (ratifica) y `desestimar_compra` |
| 0021 | `cambiar_estado`, `asignar_tecnico`, `registrar_presupuesto`; el UPDATE directo de estado y costo queda cerrado |
| 0022 | Corrección de la bitácora de eventos (SECURITY DEFINER) |

`supabase/seed.sql` deja el catálogo de marcas y productos. El monolito antiguo quedó en `supabase/archivo/` y no se aplica.

## Rutas del frontend

`/garantias` (tablero de garantías) · `/garantias/nueva` · `/garantias/consulta` · `/taller` · `/taller/nueva?equipo=…` · `/taller/:id`. El diseño de las pantallas está en `docs/diseno-ui/`.

## Documentación

- [Estado del proyecto](ESTADO_DEL_PROYECTO.md) — qué existe hoy, deuda y pendientes
- [Diseño de la fase 2a](docs/superpowers/specs/2026-10-30-fase-2a-garantia-consulta-taller-design.md) — reglas de negocio, RPC y permisos
- [Plan de la fase 2a](docs/superpowers/plans/2026-10-30-fase-2a-garantia-consulta-taller.md) — el orden de construcción
- [Diseño de pantallas](docs/diseno-ui/README.md) — maquetas y lo que falta en el backend
- [Reporte del hito 1](docs/REPORTE_HITO_1.md) y su [diseño](docs/superpowers/specs/2026-10-29-registro-y-control-de-garantia-design.md)
