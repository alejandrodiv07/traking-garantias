# Fase 2a — Garantía, Consulta y Taller · Plan de implementación

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Separar el monolito del Hito 1 en tres módulos unidos por el serial — Registrar garantía (post-venta), Consulta (puerta de entrada del taller) y Taller (orden `OS-AAAA-NNNN` con auditoría de recepción, estados y rechazo) — con las reglas de negocio impuestas por la base.

**Architecture:** Migraciones SQL hacia adelante (0013 renombre mecánico, 0014–0021 comportamiento) con RLS/triggers/RPC `SECURITY DEFINER`; frontend React por módulos `features/<modulo>/` con un `*Service.js` por módulo, reutilizando los pasos y el borrador del Hito 1. La autorización y las reglas viven en Postgres; React solo las anticipa.

**Tech Stack:** React 19 + Vite 8 + vitest · Supabase (Postgres 17 + RLS + RPC + Storage) · pruebas SQL en Docker vía `supabase/tests/run.sh` · bash e2e.

**Spec:** `docs/superpowers/specs/2026-10-30-fase-2a-garantia-consulta-taller-design.md` (el spec manda; este plan lo argumenta).

## Global Constraints

- Todo (código, comentarios, pruebas, commits) en español.
- **TDD estricto (regla heredada del spec §9):** ninguna línea de código de producción sin una prueba vista en rojo por la razón esperada.
- Cobertura única fuente: `public.calcular_cobertura`; el cliente nunca envía el resultado.
- `revisiones` y `adjuntos` **solo de anexar** (ni con `service_role`); sin `DELETE` en tablas de negocio.
- El token de consulta existe en claro una sola vez (devolución del RPC); en la BD solo su SHA-256.
- Plazo de garantía: 7 o 15 días; cualquier otro valor (1–365) solo lo fija ADMIN o JEFE_SERVICIO.
- Motivos obligatorios ≥ 10 caracteres: rechazo de orden y desestimación de compra (mismo mínimo en BD y UI; uso interno).
- Números de orden `OS-AAAA-NNNN` (4 dígitos) por secuencia nativa; idempotencia por `clave_envio` (mecanismo 0012 conservado).
- Storage: bucket privado `ordenes`, rutas `ordenes/{orden_id}/…`; fotos ≤ 8 MB (máx 8), documentos PDF/JPG/PNG ≤ 8 MB (máx 6).
- Roles internos: ADMIN, JEFE_SERVICIO, TECNICO, RECEPCION; `anon` sin ningún acceso; el módulo MFA no se toca.
- **Frontend:** la paleta y dimensiones salen SIEMPRE de `frontend/src/styles/tokens.css` (variables `--c-*`, `--c-radio`, `--c-mono`); ningún color nuevo fuera de ahí; los módulos nuevos tienen su propio CSS (`*.css`) que solo lee esas variables. Componentes reciben datos por props; solo los `*Service.js` hablan con Supabase; todo servicio devuelve `{ ok: true, datos }` / `{ ok: false, codigo, mensaje }` con el mapeo de errores del repo (SIN_PERMISO / SESION_VENCIDA / SIN_CONEXION / DESCONOCIDO).
- Migraciones SOLO como archivos nuevos numerados en `supabase/migrations/` (nunca se edita una existente). Pruebas SQL con el patrón del repo: `pg_temp.chk('nombre', condición)`, `\set QUIET`, BEGIN/ROLLBACK para lo que debe fallar, `SET ROLE authenticated` + `set_config('request.jwt.claim.sub', …, TRUE)` para permisos.
- Ciclo de cada tarea: prueba en rojo → código mínimo → suite completa en verde (`bash supabase/tests/run.sh` y/o `pnpm test` desde `frontend/`) → `pnpm lint` y `pnpm build` limpios → commit con la línea `Co-Authored-By: Claude Code <noreply@anthropic.com>`.
- Rama de trabajo: `feat/fase-2a` (creada sobre `feat/registro-y-control`); ningún push a `main`.

## Review Focus

Faltas que el spec implica y que ninguna pantalla puede corregir — cada una con su prueba amarrada en la tarea dueña:

1. **Garantía TALLER sin confirmar nunca es EN_GARANTIA**, aunque la factura esté vigente y el checklist sea perfecto → `POR_DETERMINAR`. Prueba: `11_cobertura.sql` c7–c8 y `20_equipos_origen.sql` (Tarea 4).
2. **Plazo de 30 días:** lo intenta TECNICO → 42501; lo fija JEFE_SERVICIO → aceptado. Prueba: `24_rpc_garantia.sql` (Tarea 8).
3. **RECHAZADO sin motivo (o motivo < 10) es imposible**, y el motivo persiste tras pasar a ENTREGADO. Pruebas: `22_rechazado_transiciones.sql` y `21_orden_atencion.sql` (Tareas 6 y 5).
4. **Doble clic al abrir la orden** (misma `clave_envio`): una sola orden; la segunda respuesta devuelve la orden original SIN token. Prueba: `25_rpc_abrir_orden.sql` (Tarea 9).
5. **`anon` no ve nada nuevo**: RPC, tablas renombradas y bucket denegados. Pruebas: `28_permisos_matriz.sql` (Tarea 11) y `26`/`27` (Tareas 10–11).
6. **Consulta con serial inexistente** muestra "No hay garantía registrada" y la acción "Registrar ahora" que encadena con abrir orden; el aviso previo cuando la cobertura no es garantía ("se atenderá como servicio pago" / "cobertura pendiente de confirmar"). Prueba: `Consulta.test.jsx` (Tarea 14).

---

### Tarea 1: Rama de trabajo y línea base

**Files:** ninguno (solo git).

**Interfaces:** Produces: rama `feat/fase-2a` con bases de las 3 suites en verde (evidencia para el resto del plan).

- [ ] **Step 1: Correr la suite SQL y las de frontend ANTES de crear la rama** (línea base comprobable):

```bash
bash supabase/tests/run.sh            # esperado: 237 PASA, "TODAS LAS PRUEBAS PASAN"
cd frontend && pnpm test              # esperado: 182 pruebas, 0 fallos
cd frontend && pnpm lint && pnpm build   # sin errores
```

Si algo está en rojo ANTES de empezar: parar y reportarlo por nombre (no se arregla aquí).

- [ ] **Step 2: Crear la rama y comprometer los docs pendientes**

```bash
git checkout -b feat/fase-2a
git add docs/REPORTE_HITO_1.md docs/superpowers/specs/2026-10-30-fase-2a-garantia-consulta-taller-design.md docs/superpowers/plans/2026-10-30-fase-2a-garantia-consulta-taller.md
git commit -m "docs: diseño de la fase 2a, reporte del hito 1 y plan de tareas"
```

(El PDF `Prime Telecom — Garantías.pdf` queda como archivo no rastreado: es material de referencia visual, no del repo.)

---

### Tarea 2: Migración 0013 — renombre mecánico en SQL

Renombrar TODO sin cambiar comportamiento (spec §5.1 y §10.1). Los datos existentes son de prueba: no se conservan.

**Files:**
- Create: `supabase/migrations/20261030000013_fase2a_renombre.sql`
- Modify: `supabase/tests/13_registros.sql`, `14_revisiones.sql`, `15_adjuntos.sql`, `16_rpc_ingreso.sql` (renombrar archivo a `16_rpc_abrir_orden.sql`), `17_rpc_revision.sql`, `18_tablero.sql`, `19_huerfanos.sql`, `97_pruebas_rechazos.sql`, `99_pruebas_seguridad.sql`
- Verify: `scripts/verificar-migraciones.sh` (deriva de los nombres de archivo; solo confirmar que corre OK)

**Interfaces:**
- Produces (lo que consumen TODAS las tareas siguientes):
  - Tablas: `ordenes_servicio` (columna `numero_orden TEXT 'OS-AAAA-NNNN'`, la columna `numero_registro` y su secuencia `registros_numero_seq`/formato `REG-` quedan fuera), `historial_ordenes` (columna `orden_id`), `consulta_publica_intentos.numero_orden`; columnas `registro_id → orden_id` en `revisiones`, `adjuntos`, `notas_internas`.
  - RPC: `abrir_orden(…13 parámetros…, p_clave_envio uuid)` (corpo de la 0012, mismo comportamiento y misma tabla de RETURNS renombrada a `orden_id, numero_orden`), `registrar_revision(p_orden_id uuid, …)`, `confirmar_compra(…)` (misma firma pública), `buscar_equipo(p_serial text)`, `consultar_registro` (devuelve `numero_orden`), `listar_huerfanos(p_gracia interval)` contra el bucket `ordenes`.
  - Storage: bucket privado `ordenes`; políticas `storage_subir_adjunto` / `storage_ver_adjunto` sobre rutas `ordenes/{orden_id}/…`; CHECK de `adjuntos.ruta` pasa a `^ordenes/.+/.+`.
  - Incluye el REPASO idempotente de adjuntos (decisión de la conversación: no se sabe si el remoto aplicó la 0008 original): re-ejecutar `ALTER TABLE public.adjuntos ALTER COLUMN subido_por SET DEFAULT auth.uid()` y recrear la política `adj_insert WITH CHECK (subido_por = auth.uid())`.

- [ ] **Step 1: Escribir la migración 0013 con esta lista exacta de sentencias** (en orden; cada una usa los nombres de la migración fuente):

1) `ALTER TABLE public.registros RENAME TO ordenes_servicio;` · `ALTER TABLE public.historial_registros RENAME TO historial_ordenes;`
2) Renombres de columnas: `ordenes_servicio.numero_registro → numero_orden`; `historial_ordenes.registro_id → orden_id`; `consultas…: consulta_publica_intentos.numero_registro → numero_orden`; `revisiones/adjuntos/notas_internas.registro_id → orden_id`.
3) `ALTER SEQUENCE public.registros_numero_seq RENAME TO ordenes_numero_seq;` y recolocar el DEFAULT: `ALTER TABLE public.ordenes_servicio ALTER COLUMN numero_orden SET DEFAULT ('OS-' || to_char(now(),'YYYY') || '-' || lpad(nextval('public.ordenes_numero_seq')::text, 4, '0'));` (4 dígitos, prefix `OS-`).
4) `DROP FUNCTION` de las que mencionan nombres viejos y `CREATE OR REPLACE` con el cuerpo de la fuente solo con los nombres cambiados: `registrar_historial_orden` (comentario de alta `'Orden creada'`), `historial_ordenes_es_inmutable`, `validar_adjunto` (sin cambio de texto excepto nada — no mencionaba registros), `buscar_equipo(text)`, `abrir_orden` (nueva firma devolviendo RETURNS TABLE `(orden_id, numero_orden, consulta_token, cobertura, equipo_id, equipo_nuevo)`), `registrar_revision(orden_id, text, jsonb, text)`, `confirmar_compra`, `consultar_registro` (RETURNS y cuerpo con `numero_orden`), `listar_huerfanos` (bucket `ordenes`), y `registrar_revision` con `p_orden_id`. Los GRANT/REVOKE idénticos a los de la fuente, con los nombres nuevos.
5) Triggers: renombrar y re-crear sin `DROP TABLE`: `DROP TRIGGER trg_registros_* / trg_historial_registros_*` y crear `trg_ordenes_*` / `trg_historial_ordenes_*` apuntando a las funciones nuevas. `ALTER TABLE ordenes_servicio ALTER COLUMN estado REFERENCES` no hace falta (no hay FK a una tabla renombrada aquí: `estados_garantia` se mantuvo).
6) CHECK de ruta: identificar el nombre real (via `information_schema.table_constraints` se llamará `adjuntos_ruta_check`), `DROP CONSTRAINT` + `ADD CONSTRAINT adjuntos_ruta_check CHECK (ruta ~ '^ordenes/.+/.+')`.
7) Storage: `INSERT INTO storage.buckets (id, name, public) VALUES ('ordenes','ordenes',false) ON CONFLICT (id) DO UPDATE SET public=false;` recrear las dos políticas con `bucket_id = 'ordenes'` y `split_part(name,'/',1) = 'ordenes'`; la guardia del segmento 2 sigue siendo uuid de una fila de `ordenes_servicio`. Borrar la fila del bucket `registros` SOLO si no queda ningún objeto (`DELETE … WHERE id='registros' AND NOT EXISTS (SELECT 1 FROM storage.objects WHERE bucket_id='registros')`). Repaso idempotente de adjuntos (DEFAULT + política adj_insert).
8) `COMMENT ON TABLE public.ordenes_servicio IS 'Nunca se borran filas. Una orden creada por error pasa a estado ANULADO.'` (y el comentario del historial si lo hay).

- [ ] **Step 2: Correr la suite SQL y verla CAER con los nombres viejos** (rojo):

```bash
bash supabase/tests/run.sh
```
Esperado: FALLA > 0 en 13, 14, 15, 16, 17, 18, 19, 97, 99 — por `column "registro_id" of relation "revisiones" does not exist`, `function public.registrar_ingreso(…) does not exist`, `relation "public.registros" does not exist`. (run.sh cuenta "does not exist" como FALLA.)

- [ ] **Step 3: Migrar las pruebas a los nombres nuevos** — reemplazo mecánico y completo en los archivos listados: `registros`→`ordenes_servicio` (y `public.registros`→`public.ordenes_servicio`), `numero_registro`→`numero_orden`, `registro_id`→`orden_id`, `historial_registros`→`historial_ordenes`, `registrar_ingreso`→`abrir_orden`, `p_registro_id`→`p_orden_id` (RPC), `REG-2026-`→`OS-2026-` (y las aserciones de 6 dígitos, `NNNNNN`, a 4 dígitos `NNNN`; ajustar las máscaras/`like 'REG-%'`), rutas `registros/`→`ordenes/` en las pruebas de adjuntos y Storage (15/19/99). Añadir a `13_registros.sql` una aserción nueva: el DEFAULT genera `OS-` + año + 4 dígitos (comparar contra `'^[0-9]{4}$'` del tramo numérico). Sin cambiar el SEMÁNTICO de ninguna aserción: mismo nombre de prueba `chk`, misma condición lógica.

- [ ] **Step 4: Suite SQL en verde**

```bash
bash supabase/tests/run.sh
```
Esperado: `TODAS LAS PRUEBAS PASAN`, 237+1 PASA y FALLA 0 por archivo.

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations supabase/tests
git commit -m "refactor(db): 0013 renombra registros a ordenes_servicio y OS-AAAA-NNNN (fase 2a)"
```

---

### Tarea 3: Renombre mecánico del frontend (`orden_id` / `numero_orden` / `ordenes` / RPC)

**Files:**
- Modify: `frontend/src/features/tablero/tableroService.js` (constante `COLUMNAS`: `registro_id`→`orden_id`, `numero_registro`→`numero_orden`), `frontend/src/features/tablero/Tablero.jsx`, `frontend/src/features/tablero/componentes/*.jsx` (`TablaOrdenes.jsx`, `TablaRegistros.jsx`, `DetalleRegistro.jsx`, `PanelVencimientos.jsx`), `frontend/src/features/tablero/Tablero.test.jsx`, `frontend/src/features/tablero/tableroService.test.js`, `frontend/src/features/registro/registroService.js` y su test, `frontend/src/features/revisiones/revisionesService.js` y `HistorialRevisiones.jsx` / `RevisionForm.jsx` / `revisiones.test.jsx`
- Test: los archivos `*.test.*` de la lista

**Interfaces:**
- Consumes: RPC de la Tarea 2 (`abrir_orden` con RETURNS `orden_id, numero_orden,…`; `registrar_revision(p_orden_id,…)`; bucket `ordenes`).
- Produces: el frontend habla SIEMPOST de `orden_id` / `numero_orden`; `subirAdjunto` construye rutas `ordenes/{ordenId}/…`.

- [ ] **Step 1: Actualizar mocks/expectativas de los tests PRIMERO** (cambiar los mocks a `orden_id`, `numero_orden`, RPC `abrir_orden`, `ordenes/…` en la subida y correrlos para verlos en rojo):

```bash
cd frontend && pnpm vitest run src/features/tablero src/features/registro src/features/revisiones
```
Esperado: FALLA en tablero y registro (los mocks ya piden los nombres nuevos y el código aún los viejos).

- [ ] **Step 2: Aplicar el renombre en el código** (mismos 5 grupos: RPC `abrir_orden`, `p_orden_id` en `registrarRevision`, columnas `orden_id`/`numero_orden` en servicios/pantallas, ruta `ordenes/${registroId}`→`ordenes/${ordenId}` en `subirAdjunto`, bucket `from("ordenes")` en `subirAdjunto`). En `registroService.js` se renombra TAMBIÉN el nombre de función `registrarIngreso` → `abrirOrden` (y sus usos en `enviarRegistro.js` y `NuevoRegistro.jsx`), porque la RPC ya no existe; el resto del flujo del asistente queda igual.

- [ ] **Step 3: Suite de frontend completa en verde + lint + build**

```bash
cd frontend && pnpm test && pnpm lint && pnpm build
```
Esperado: 182 pruebas (≈ mismas cantidades), 0 fallos.

- [ ] **Step 4: Commit**

```bash
git add frontend/src
git commit -m "refactor(frontend): el cliente usa orden_id / numero_orden y la RPC abrir_orden"
```

---

### Tarea 4: Migración 0014 — origen VENTA/TALLER, desestimación y la cobertura nueva (§4.1, §4.2)

**Files:**
- Create: `supabase/migrations/20261030000014_equipos_origen.sql`
- Test (nuevo): `supabase/tests/20_equipos_origen.sql` · Test (además): `supabase/tests/11_cobertura.sql` (secciones nuevas al final)

**Interfaces:**
- Consumes: tablas de la Tarea 2.
- Produces (lo consumen Tareas 7–10 y el frontend):
  - `equipos`: `origen text NOT NULL DEFAULT 'VENTA'` con CHECK `IN ('VENTA','TALLER')`; `registrado_por uuid REFERENCES profiles(id) ON DELETE SET NULL`; `compra_desestimada_por uuid`, `compra_desestimada_en timestamptz`, `compra_desestimada_motivo text`.
  - CHECKs: `ck_desestimacion_completa` (motivo+por+en van juntos; motivo `length(btrim(…)) >= 10`); `ck_confirmar_desestimar_excluyentes` (`NOT (compra_confirmada_por IS NOT NULL AND compra_desestimada_por IS NOT NULL)`).
  - `public.calcular_cobertura(p_vence_el date, p_fecha_ingreso date, p_checklist jsonb DEFAULT NULL, p_origen text DEFAULT 'VENTA', p_compra_confirmada boolean DEFAULT true, p_compra_desestimada boolean DEFAULT false)` — nueva precedencia EXACTA: 1) desestimada → `FUERA_DE_GARANTIA` · 2) sin vence_el → `POR_DETERMINAR` · 3) origen `TALLER` y NO confirmada → `POR_DETERMINAR` · 4) `p_fecha_ingreso > p_vence_el` → `FUERA_DE_GARANTIA` · 5) incumple término o señal → `ANULADA_POR_USO` · 6) incumple condición → `POR_DETERMINAR` · 7) `EN_GARANTIA`.
  - `fijar_resultado_revision` y el recalculo de `confirmar_compra` pasan los 3 datos del equipo (origen, `compra_confirmada_por IS NOT NULL`, `compra_desestimada_por IS NOT NULL`).

- [ ] **Step 1: Escribir `20_equipos_origen.sql` con, al menos, estas aserciones** (patrón del repo, `pg_temp.chk`):

- `D1` desestimación incompleta (motivo sin por/en) rechazada — `BEGIN; UPDATE equipos SET compra_desestimada_motivo='motivo' …; ROLLBACK;` + chk count sin cambios.
- `D2` motivo desestimación de 9 caracteres rechazado; `D3` de 10 aceptado.
- `D4` confirmada y desestimada a la vez rechazado (23514).
- `D5` `origen = 'TALLER'` aceptado en INSERT y `origen='VENTA'` es el DEFAULT; `D6` otro valor (`'X'`) rechazado.
- Cobertura nueva (aserciones de función): `C1 taller-sin-confirmar → POR_DETERMINAR` (calcular_cobertura('2027-01-10', hoy, checklist perfecto, 'TALLER', false, false) = 'POR_DETERMINAR'); `C2 taller confirmada → EN_GARANTIA`; `C3 desestimada → FUERA_DE_GARANTIA` (con checklist perfecto y fechas vigentes); `C4 llamada con 3 argumentos (compatibilidad) sigue dando EN_GARANTIA`.
- `T1` el TRIGGER lo aplica a los datos: equipo `TALLER` sin confirmar + revisión de recepción con checklist perfecto → `revisiones.resultado = 'POR_DETERMINAR'` y la orden queda `cobertura = 'POR_DETERMINAR'`.

- [ ] **Step 2: Correrla en rojo**

```bash
bash supabase/tests/run.sh supabase/tests/20_equipos_origen.sql supabase/tests/11_cobertura.sql
```
Esperado: FALLA > 0 (`column equipos.origen does not exist`; función calcular_cobertura con 6 args `does not exist`).

- [ ] **Step 3: Implementar la migración 0014** — las columnas/CHECKs con los nombres EXACTOS de arriba (después del renombre), y reescribir `calcular_cobertura` colocando los dos cortes nuevos ANTES de la fecha vencida (siguiendo la precedencia), con `DROP FUNCTION public.calcular_cobertura(date, date, jsonb)` previo. Adaptar `fijar_resultado_revision` y el UPDATE de `confirmar_compra` para pasar `e.origen` y los dos booleanos; las llamadas existentes con 3 argumentos siguen compilando por los DEFAULTs.

- [ ] **Step 4: Suite SQL completa en verde** (`bash supabase/tests/run.sh`) — esperado: TODAS PASAN.

- [ ] **Step 5: Commit** `git add supabase && git commit -m "feat(db): 0014 origen VENTA/TALLER, desestimación de compra y precedencia nueva de cobertura"`

---

### Tarea 5: Migración 0015 — tipo_atención, motivo de rechazo y bitácora de eventos (§4.3, §4.6)

**Files:**
- Create: `supabase/migrations/20261030000015_orden_atencion.sql`
- Test (nuevo): `supabase/tests/21_orden_atencion.sql`

**Interfaces:**
- Produces (lo consumen Tareas 6–11 y el frontend del detalle):
  - `ordenes_servicio.tipo_atencion`: columna GENERADA STORED — `CASE cobertura WHEN 'EN_GARANTIA' THEN 'GARANTIA' WHEN 'POR_DETERMINAR' THEN 'PENDIENTE' ELSE 'PAGO' END`.
  - `ordenes_servicio.motivo_rechazo text`; CHECK `ck_rechazo_motivado: estado <> 'RECHAZADO' OR (motivo_rechazo IS NOT NULL AND length(btrim(motivo_rechazo)) >= 10)`.
  - Trigger `trg_motivo_rechazo_persiste` (BEFORE UPDATE): si OLD.motivo_rechazo IS NOT NULL y NEW lo pone NULL/distinto → exception 23F01 'El motivo del rechazo no se puede alterar'.
  - `historial_ordenes.evento text NOT NULL DEFAULT 'ESTADO'` con CHECK `IN ('ESTADO','BITACORA')` + CHECK combinado que reemplaza el actual: `(evento = 'BITACORA' AND estado_anterior IS NULL AND estado_nuevo = estado) OR (evento = 'ESTADO' AND estado_anterior IS DISTINCT FROM estado_nuevo)`; columnas de la fila BITACORA: comentario obligatorio (`CHECK evento <> 'BITACORA' OR comentario IS NOT NULL`). Función `registrar_evento_orden()` (AFTER UPDATE OF cobertura, costo_reparacion, tecnico_asignado_id): si el valor cambió, inserta fila BITACORA con comentario (`'La cobertura cambió a X con la orden en <estado>'`, `'Técnico asignado: <nombre>'`, `'Presupuesto: <monto>'`), permitiendo que los RPCs (SECURITY DEFINER) anoten sin grant INSERT.

- [ ] **Step 1: Escribir `21_orden_atencion.sql` en rojo** — aserciones: `A1` orden en garantía tiene `tipo_atencion='GARANTIA'`; `A2` cobertura `ANULADA_POR_USO` (revisión con señales) → `type='PAGO'`; `A3` cobertura `POR_DETERMINAR` → `'PENDIENTE'`; `A4` limpiar motivo_rechazo de una fila que lo tiene → exception (`ROLLBACK` con `set_config` capturado, o patrón BEGIN/ROLLBACK + count); `A5` insertar fila BITACORA en `historial_ordenes` (estado_anterior NULL, estado_nuevo igual al actual, comentario) es aceptado; `A6` fila BITACORA sin comentario rechazada; `A7` un UPDATE de cobertura con la orden en EN_REPARACION deja una fila BITACORA nueva ('La cobertura cambió a …').

- [ ] **Step 2: Correrla** (`bash supabase/tests/run.sh supabase/tests/21_orden_atencion.sql`) — FALLA > 0 (`column tipo_atencion does not exist`, etc.).

- [ ] **Step 3: Implementar la 0015** con lo de la sección Interfaces (el CHECK `ck_rechazo_motivado` se define ya; se prueba a fondo en la Tarea 6 cuando existe el estado RECHAZADO).

- [ ] **Step 4: Suite SQL completa en verde + commit** `bash supabase/tests/run.sh` → `git add supabase && git commit -m "feat(db): 0015 tipo_atencion generado, motivo de rechazo y bitácora de eventos"`

---

### Tarea 6: Migración 0016 — estado RECHAZADO, transiciones y roles cerrados (§4.6, §5.2, §7)

**Files:**
- Create: `supabase/migrations/20261030000016_rechazado_transiciones.sql`
- Test (nuevo): `supabase/tests/22_rechazado_transiciones.sql`
- Modify: `frontend/src/features/tablero/dominio.js`, Test (nuevo): `frontend/src/features/tablero/dominio.test.js`

**Interfaces:**
- Produces:
  - Estado `RECHAZADO` (nombre 'Rechazado', orden 85, es_final FALSE — tiene salida ÚNICA a ENTREGADO, así que NO es terminal).
  - Transiciones nuevas: `RECIBIDO→RECHAZADO`, `EN_DIAGNOSTICO→RECHAZADO`, `PRESUPUESTADO→RECHAZADO` con roles `ARRAY['ADMIN','JEFE_SERVICIO']`; `RECHAZADO→ENTREGADO` con `ARRAY['ADMIN','JEFE_SERVICIO','RECEPCION']`.
  - CIERRE de roles (spec: nadie ya no "cualquier rol"): todas las transiciones con `roles_permitidos NULL` pasan a `ARRAY['ADMIN','JEFE_SERVICIO','TECNICO']`, EXCEPTO `PRESUPUESTADO→EN_REPARACION` y `PRESUPUESTADO→RECHAZADO_POR_CLIENTE` (decisión del cliente, las recepciona también: esas cuatro incluyen `RECEPCION`).
  - RLS `reg_update_recepcion`: states admitidos pasan a `('REPARADO','IRREPARABLE','RECHAZADO_POR_CLIENTE','RECHAZADO')`.
  - Frontend: `ESTADOS` incluye `{ codigo:'RECHAZADO', nombre:'Rechazado', tono: ADVERSO, final:false }` en orden 85; `estaAbierta('RECHAZADO') === true`; comentario del espejo actualizado ("11 estados"): sin cambiar nada más.

- [ ] **Step 1: Escribir `22_rechazado_transiciones.sql` en rojo** — matriz (patrón 13_registros: superuser para la transición y `SET ROLE authenticated` + claim para el rol): `R1` RECIBIDO→RECHAZADO (superuser) pasa SOLO si `motivo_rechazo ≥ 10` se pone en el mismo UPDATE; sin motivo → CHECK `ck_rechazo_motivado` rechaza; con motivo de 9 → rechaza; `R2` una orden RECHAZADO pasa a ENTREGADO (recep/jefe/superuser) y el motivo SIGUE ahí; `R3` TECNICO (claim) intenta RECIBIDO→RECHAZADO → 42501; `R4` RECEPCION intenta RECIBIDO→EN_DIAGNOSTICO → 42501 (ya no tiene "cualquier rol"); `R5` RECEPCION SÍ pasa REPARADO→ENTREGADO; `R6` TECNICO pasa RECIBIDO→EN_DIAGNOSTICO; `R7` anexo: `PRESUPUESTADO→RECHAZADO_POR_CLIENTE` aceptado a RECEPCION; `R8` `RECHAZADO` cuenta como abierta en `v_tablero` (abierto = true).

- [ ] **Step 2: Correrla** (`bash supabase/tests/run.sh supabase/tests/22_rechazado_transiciones.sql`) — FALLA (> 0: estado/transiciones no existen; reg_update_recepcion sin RECHAZADO).

- [ ] **Step 3: Implementar la 0016** — INSERT del estado, INSERT de las 4 transiciones, los UPDATE de cierre de roles EXPLÍCITOS por transición (15 sentencias con sus roles exactos; nada de "UPDATE WHERE roles_permitidos IS NULL" que no distinga la excepción), `DROP POLICY reg_update_recepcion` + recrearla con los 4 estados.

- [ ] **Step 4: Suite SQL en verde.**

- [ ] **Step 5: Espejo del frontend en TDD**: crear `dominio.test.js` con: `RECHAZADO` existe en ESTADOS con tono `ADVERSO` y `final=false`; `estaAbierta('RECHAZADO')` es true; ESTADOS sigue teniendo 11 entradas. Verlo en rojo (`cd frontend && pnpm vitest run src/features/tablero/dominio.test.js`), añadir la entrada a `dominio.js`, verlo verde.

- [ ] **Step 6: Suites completas + commit** — `bash supabase/tests/run.sh` y `cd frontend && pnpm test && pnpm lint && pnpm build`; `git add supabase frontend/src && git commit -m "feat(db,frontend): 0016 estado RECHAZADO con salida única a ENTREGADO y roles cerrados" `

---

### Tarea 7: Migración 0017 — reglas de avance impuestas por la base (§4.5, §4.4)

**Files:**
- Create: `supabase/migrations/20261030000017_reglas_avance.sql`
- Test (nuevo): `supabase/tests/23_reglas_avance.sql`

**Interfaces:**
- Consumes: columnas de las Tareas 4–5; tabla `adjuntos`.
- Produces: función trigger `public.validar_avance_orden()` (BEFORE UPDATE OF estado en `ordenes_servicio`, DESPUÉS de validar_transicion en el orden de disparo) que aplica: (a) a `EN_DIAGNOSTICO`: ≥ 1 adjunto tipo FOTO de la orden; si el equipo es `origen='TALLER'` y `compra_confirmada_por IS NULL` → además ≥ 1 adjunto DOCUMENTO; (b) a `PRESUPUESTADO`: `costo_reparacion IS NOT NULL`; (c) `EN_DIAGNOSTICO → EN_REPARACION`: solo con `tipo_atencion = 'GARANTIA'`. Errores 23514 con mensajes accionables ('El avance exige una foto de la auditoría de recepción' / 'Un equipo de taller sin compra confirmada exige subir el documento presentado' / 'Para presupuestar hay que registrar el monto' / 'Un servicio pago pasa por PRESUPUESTADO antes de reparar'). Además trigger `trg_costo_con_cobertura` (BEFORE UPDATE): si NEW.cobertura = 'EN_GARANTIA' y OLD.costo_reparacion IS NOT NULL → `NEW.costo_reparacion := NULL` (la confirmación posterior no cobra lo que la garantía cubre; el evento queda en la bitácora por `registrar_evento_orden` de la Tarea 5).

- [ ] **Step 1: Escribir `23_reglas_avance.sql` en rojo** — escenario: orden con origen VENTA y factura vigente (cobertura EN_GARANTIA) + orden TALLER sin confirmar; sin adjuntos: `V1` RECIBIDO→EN_DIAGNOSTICO sin foto → 23514; `V2` con FOTO (INSERT directo en adjuntos con ruta `ordenes/<id>/x.png` como superuser) pasa; `V3` orden TALLER sin confirmar con solo FOTO → falla; con FOTO + DOCUMENTO pasa; `V4` EN_DIAGNOSTICO→PRESUPUESTADO sin costo → 23514; con costo pasa; `V5` orden PAGO (revisión con golpes → ANULADA_POR_USO): EN_DIAGNOSTICO→EN_REPARACION → 23514 (debe ir por PRESUPUESTADO); `V6` orden GARANTIA: EN_DIAGNOSTICO→EN_REPARACION pasa; `V7` UPDATE cobertura='EN_GARANTIA' con costo_reparacion=50 → la fila queda con costo NULL y `historial_ordenes` muestra el evento.

- [ ] **Step 2: Correrla** (`bash supabase/tests/run.sh supabase/tests/23_reglas_avance.sql`) — FALLA > 0.

- [ ] **Step 3: Implementar la 0017.** Crear la función trigger `validar_avance_orden()` con las 3 reglas y el trigger; crear el trigger de costo con cobertura EN_GARANTIA; `COMMENT` de cada regla citando el spec §4.5.

- [ ] **Step 4: Suite SQL completa en verde + commit** — `bash supabase/tests/run.sh`; `git commit -m "feat(db): 0017 las reglas de avance las impone la base (foto, documento, presupuesto, pago por presupuesto)"`.

---

### Tarea 8: Migración 0018 — `registrar_garantia` y `buscar_equipo` multicriterio (§4.1, §6)

**Files:**
- Create: `supabase/migrations/20261030000018_rpc_garantia.sql`
- Test (nuevo): `supabase/tests/24_rpc_garantia.sql`

**Interfaces:**
- Produces (las usan Tareas 9, 10 y las pantallas Ventas & Garantías):
  - `public.registrar_garantia(p_cliente_id uuid, p_producto_id uuid, p_serial text, p_tipo_soporte text DEFAULT NULL, p_numero_soporte text DEFAULT NULL, p_fecha_emision date DEFAULT NULL, p_plazo_dias integer DEFAULT NULL, p_origen text DEFAULT 'VENTA')` RETURNS TABLE `(equipo_id uuid, vence_el date, equipo_nuevo boolean)`. Crea el equipo (ON CONFLICT DO NOTHING + re-selección, patrón de `abrir_orden`), fija `registrado_por = auth.uid()`, sin orden. Validaciones: rol interno (los cuatro, 42501); serial 3–60 (22P02); soporte completo-o-nada (lo refuerza el CHECK del equipo); `p_plazo_dias NOT IN (7,15)` → 42501 'los plazos distintos de 7 o 15 días solo los fija el jefe' a menos que ADMIN/JEFE; `p_origen IN ('VENTA','TALLER')` (22P02). Si el equipo existía lo devuelve con `equipo_nuevo=false`.
  - `public.buscar_equipo(p_serial text DEFAULT NULL, p_documento text DEFAULT NULL, p_factura text DEFAULT NULL, p_orden text DEFAULT NULL)` RETURNS `(equipo_id, producto, numero_serie, titular_id, titular, documento, email, telefono, fecha_emision, plazo_dias, vence_el, dias_restantes, origen, vigencia cobertura_garantia, estado_compra text, motivo_desestimacion text, ordenes jsonb)` — `estado_compra` = 'CONFIRMADA' | 'DESESTIMADA' | 'PENDIENTE'; `vigencia` = el mismo CASE de precedencia (desestimada → FUERA_DE_GARANTIA; sin vence / TALLER sin confirmar → POR_DETERMINAR; vencida → FUERA; resto EN_GARANTIA); `ordenes` = jsonb con `{numero_orden, estado, estado_nombre, cobertura, tipo_atencion, fecha_ingreso}` por orden del equipo (ORDER BY fecha_ingreso). Serial busca en TODOS los productos normalizando; documento coincide `clientes.documento` (cédula/RIF) y devuelve los equipos del cliente; factura coincide `numero_soporte` (upper/btrim); `p_orden` coincide `ordenes_servicio.numero_orden` exacto y devuelve ese equipo. Si varios criterios llegan, se buscan y se UNEN sin duplicados (DISTINCT). Búsqueda vacía (todo NULL) → 0 filas. Criterios separados con OR.
  - `DROP FUNCTION public.buscar_equipo(text)` (la firma cambia; sin sobrecargas ambiguas).
- Granularidad: GRANT EXECUTE a `authenticated` (internal roles deciden por `mi_rol()`); nada para anon.

- [ ] **Step 1: Escribir `24_rpc_garantia.sql` en rojo** — semilla: cliente, producto, usuarios admin/jefe/tecnico/recepcion (patrón de `12_equipos.sql`: auth.users + mfa_sesiones si existe). Aserciones: `G1` TECNICO con plazo 7 crea la garantía origen VENTA (equipo_id devuelto, sin órdenes nuevas — `count(*) from ordenes_servicio` sin cambios); `G2` TECNICO con plazo 30 → 42501 (BEGIN/ROLLBACK); `G3` RECEPCION con plazo 30 → 42501; `G4` JEFE con plazo 30 aceptado; `G5` REVISION: lo repetido no duplica (misma llamada dos veces → mismo equipo_id, `equipo_nuevo=false` la segunda); `G6` origen TALLER acepta y el equipo queda sin orden; `G7-K1..K8 buscar_equipo`: por serial normalizado ('rt5-8842-aa' halla 'RT5-8842-AA'), serial en OTRO producto también (2 filas), por documento del titular, por factura (numero_soporte), por numero_orden exacto tras abrir una orden con `abrir_orden`, inexistente → 0 filas, todo NULL → 0 filas; `G8` forma del resultado: `vigencia='EN_GARANTIA'`, `estado_compra='CONFIRMADA'` para un equipo VENTA con factura; `estado_compra='PENDIENTE'` para TALLER sin confirmar y `vigencia='POR_DETERMINAR'`; `G9` anon sin EXECUTE: `SET ROLE anon; SELECT public.registrar_garantia(...)` → falla (permission denied); `G10` `ordenes` del resultado de `buscar_equipo` trae la orden abierta con su estado y cobertura.

- [ ] **Step 2: Correrla en rojo** (`bash supabase/tests/run.sh supabase/tests/24_rpc_garantia.sql`) — FALLA > 0 (`function public.registrar_garantia(…) does not exist`).

- [ ] **Step 3: Implementar la 0018** (ambas funciones SECURITY DEFINER, `SET search_path = public, pg_temp`, REVOKE ALL + GRANT EXECUTE authenticated, comentario cita §4.1/§6).

- [ ] **Step 4: Suite SQL completa en verde + commit** — `git add supabase && git commit -m "feat(db): 0018 registrar_garantia (plazo 7/15 salvo jefe) y buscar_equipo por serial/documento/factura/orden"`.

---

### Tarea 9: Migración 0019 — `abrir_orden` con nueva firma + envío del asistente partido (§5.1, §6)

**Files:**
- Create: `supabase/migrations/20261030000019_abrir_orden.sql`
- Test (nuevo): `supabase/tests/25_rpc_abrir_orden.sql`
- Modify: `frontend/src/features/registro/registroService.js` + `registroService.test.js`, `frontend/src/features/registro/enviarRegistro.js` + `enviarRegistro.test.js`

**Interfaces:**
- Consumes: `registrar_garantia` (Tarea 8), equipo con cobertura (Tarea 4), `revisiones`/`historial_ordenes` (Tarea 5).
- Produces:
  - `public.abrir_orden(p_equipo_id uuid, p_falla text, p_accesorios text DEFAULT NULL, p_checklist jsonb DEFAULT NULL, p_observaciones text DEFAULT NULL, p_clave_envio uuid DEFAULT NULL)` RETURNS TABLE `(orden_id uuid, numero_orden text, consulta_token text, cobertura cobertura_garantia, tipo_atencion text)`. DROP de la firma vieja (la de 13 parámetros); UNA transacción: orden + revisión RECEPCION; el token en claro sale UNA vez; la cobertura y tipo_atencion las pone la base (trigger); idempotencia por `(creado_por, clave_envio)` con el candado `pg_advisory_xact_lock` de la 0012 conservado (segunda llamada: misma orden, token NULL, `equipo_nuevo` NO existe ya — el retorno nuevo no lo lleva).
  - Frontend: `registroService.registrarGarantia(payload)` y `registroService.abrirOrden(payload)` (wrappers `rpc('registrar_garantia', …)` / `rpc('abrir_orden', …)` con el mapeo de errores) — **provisionales**: la Tarea 13 traslada `registrarGarantia` a `garantiasService` y la Tarea 15 traslada `abrirOrden` a `tallerService`, que quedan como únicas fuentes RPC por módulo. `enviarRegistro` queda: si el estado trae `equipoId` → `abrirOrden({equipoId, falla, accesorios, checklist, observaciones, claveEnvio})`; si no → `registrarGarantia(…)` y a continuación `abrirOrden({equipoId: r.datos.equipo_id, …})`; los adjuntos siguen después igual (reintento incluido).

- [ ] **Step 1: Escribir `25_rpc_abrir_orden.sql` en rojo** — `O1` abrir_orden sobre un equipo existente crea UNA orden con numero `OS-…` y una revisión RECEPCION (`count(revisiones where orden_id)=1`); `O2` devuelve token de 32 hex y la orden registra SOLO el hash; `O3` cobertura/tipo_atencion del retorno = los de la fila; `O4` IDEMPOTENTE: misma llamada repetida (misma clave) crea UNA orden (count=1) y la segunda respuesta trae `consulta_token IS NULL` y el mismo `orden_id`; dos claves distintas → dos órdenes; `O5` equipo inexistente → P0002; `O6` falla < 5 chars → 22P02; `O7` anon → permission denied; `O8` recepción (claim) SI abre orden; `O9` con checklist de golpes la cobertura del retorno es ANULADA_POR_USO y tipo PAGO.

- [ ] **Step 2: Correrla en rojo** — FALLA > 0 (`function public.abrir_orden(uuid, …) does not exist` / `function does not exist` para la vieja si quedó).

- [ ] **Step 3: Implementar la 0019** (cuerpo derivado de la 0012: sin crear equipo, SELECT del equipo, INSERT de la orden con `clave_envio`, INSERT de la revisión, RETURNING). Ajustes de TDD en el frontend: mocks → códigos nuevos, luego implementación de `registrarGarantia`/`abrirOrden` y el envío partido en `enviarRegistro.js`.

- [ ] **Step 4: Suites SQL y frontend en verde** — `bash supabase/tests/run.sh` (las pruebas viejas de `16_rpc_abrir_orden.sql` se migran a la nueva firma en ESTA tarea: `abrir_orden(equipo_id, …)` desde un equipo creado con `registrar_garantia`) y `cd frontend && pnpm test`.

- [ ] **Step 5: Commit** — `git add supabase frontend && git commit -m "feat: 0019 abrir_orden por equipo con auditoría en una transacción; el asistente envía garantía y orden por separado"`.

---

### Tarea 10: Migración 0020 — `confirmar_compra` ratificante y `desestimar_compra` (§4.1, §4.4, §6)

**Files:**
- Create: `supabase/migrations/20261030000020_confirmar_desestimar.sql`
- Test (nuevo): `supabase/tests/26_rpc_confirmar_desestimar.sql`

**Interfaces:**
- Consumes: columnas de desestimación (Tarea 4), `historial_ordenes.evento` (Tarea 5), recalclo de la 0014.
- Produces:
  - `confirmar_compra(p_equipo_id uuid, p_tipo_soporte text, p_numero_soporte text, p_fecha_emision date, p_plazo_dias integer)` REESCRITA: ADMIN/JEFE (42501); RATIFICA también un equipo con soporte ya cargado (quita el rechazo 'ya tiene soporte' — ahora SÍ se puede ratificar/corregir los datos); fija `compra_confirmada_por/en`; recalcula la cobertura de las órdenes ABIERTAS del equipo con la función pura (5 argumentos, checklist de su última revisión); si una orden pasa a `EN_GARANTIA` con costo cargado, el trigger de la 0017 limpia `costo_reparacion` y el evento queda en bitácora. Plazo distinto de 7/15: permitido (es ADMIN/JEFE), sin chequeo extra.
  - `desestimar_compra(p_equipo_id uuid, p_motivo text)`: ADMIN/JEFE; motivo ≥ 10 (22P02 si no); rechaza si ya está confirmada (23P02 'la compra ya está confirmada; deshaz con confirmar_compra'); escribe `compra_desestimada_por/en/motivo` COMPLETOS; recalcula las órdenes abiertas → `FUERA_DE_GARANTIA` (el tipo_atención pasa a PAGO por la generada); BORRA nada.
- Validación de exclusión la repite el RPC con mensaje propio (el CHECK de la Tarea 4 es el respaldo).

- [ ] **Step 1: Escribir `26_rpc_confirmar_desestimar.sql` en rojo** — escenario: equipo TALLER sin confirmar con una orden abierta en POR_DETERMINAR; equipo con soporte ya cargado; equipo confirmado. `F1` confirmar equipo con soporte ya cargado → acepta (el motivo del rechazo viejo ya no existe); la orden abierta pasa a EN_GARANTIA; `F2` confirmar con presupuesto cargado (UPDATE costo=25 como superuser) → la orden queda EN_GARANTIA con `costo_reparacion IS NULL` y una fila BITACORA nueva; `F3` desestimar → `vigencia` de buscar_equipo 'FUERA_DE_GARANTIA', orden abierta con cobertura FUERA y `tipo_atencion='PAGO'`, `compra_desestimada_*` completos; `F4` motivo de 9 chars → 22P02; `F5` desestimar lo ya confirmado → 23P02; `F6` TECNICO/RECEPCION en ambas → 42501; `F7` anon → permission denied; `F8` confirmar equipo inexistente → P0002; `F9` confirmar con soporte vacío (tipo/número/fecha faltantes) → 22P02.

- [ ] **Step 2: Correrla en rojo** (`bash supabase/tests/run.sh supabase/tests/26_rpc_confirmar_desestimar.sql`) — FALLA > 0 (`function public.desestimar_compra(…) does not exist`; F1 falla por el rechazo viejo del soporte cargado).

- [ ] **Step 3: Implementar la 0020** (REESCRIBIR `confirmar_compra` DROP+CREATE — misma firma pública que la de la 0013; `desestimar_compra` nueva; recalclo por UPDATE con CATERA LATERAL como en la fuente, ahora con los 3 datos del equipo).

- [ ] **Step 4: Suite SQL completa en verde + commit** — `git commit -m "feat(db): 0020 confirmar compra ratifica el soporte cargado y desestimar_compra fuerza PAGO"`.

---

### Tarea 11: Migración 0021 — `cambiar_estado`, `asignar_tecnico`, `registrar_presupuesto` y la matriz de permisos (§4.5, §6, §7)

**Files:**
- Create: `supabase/migrations/20261030000021_maquina_rpc.sql`
- Test (nuevos): `supabase/tests/27_rpc_estado_presupuesto.sql`, `supabase/tests/28_permisos_matriz.sql`
- Modify: `supabase/tests/13_registros.sql`, `97_pruebas_rechazos.sql` (las aserciones que actualizaban estado/costo DIRECTOMENTE como authenticated pasan a la RPC)

**Interfaces:**
- Consumes: transiciones/roles (0016), reglas de avance (0017), `tipo_atencion` (0015), `historial_ordenes` eventos (0015).
- Produces:
  - `cambiar_estado(p_orden_id uuid, p_estado text, p_comentario text DEFAULT NULL, p_motivo text DEFAULT NULL)` RETURNS `(orden_id, estado, tipo_atencion)`: ÚNICA vía de cambio de estado. Validaciones: transición existe en `transiciones_estado` (23514 con mensaje); el rol actual está en `roles_permitidos` (42501 — NULL ahora ya no existe, la 0016 cerró cualquier); a `RECHAZADO` exige `p_motivo` con ≥ 10 chars (22P02) y lo escribe en la columna; pasa `p_comentario` al historial (el trigger lo escribe). El resto de condiciones (foto, presupuesto, GARANTIA) las impone el trigger de la 0017.
  - `asignar_tecnico(p_orden_id uuid, p_tecnico_id uuid) RETURNS void`: ADMIN/JEFE (42501); valida que el destinatario exista en `profiles` con `role='TECNICO'` y `is_active` (22P02); escribe `tecnico_asignado_id`; el trigger `registrar_evento_orden` deja la fila BITACORA ('Técnico asignado/fue desasignado: <nombre>').
  - `registrar_presupuesto(p_orden_id uuid, p_monto numeric) RETURNS (tipo_atencion text)`: ADMIN/JEFE/TECNICO; solo cuando `tipo_atencion = 'PAGO'` (23P02 'Solo se presupuesta un servicio pago'; GARANTIA no se cobra, PENDIENTE no se presupuesta); monto `>= 0` (22P02); fija `costo_reparacion`; BITACORA queda por el trigger.
  - La RPC pasa a ser la ÚNICA puerta también de los permisos: `REVOKE UPDATE (estado, costo_reparacion) ON public.ordenes_servicio FROM authenticated;` + `GRANT UPDATE (diagnostico, accesorios, recibido_por) ON public.ordenes_servicio TO authenticated;` — el UPDATE directo de columnas críticas (estado, costo) queda cerrado; las políticas RLS de UPDATE quedan para las columnas restantes.
- Cambios a prueba previa (`13_registros` / `97`): las aserciones que hacían `UPDATE ordenes_servicio SET estado=…` con claim de rol interno se reescriben a `cambiar_estado(…)` (superuser sigue pudiendo, con el trigger activo, para la matriz de estados base).

- [ ] **Step 1: Escribir `27_rpc_estado_presupuesto.sql` en rojo** — sobre una orden TALLER sin confirmar (PENDIENTE): `S1` RECIBIDO→EN_DIAGNOSTICO SIN documento → 23514 (regla 0017); subiendo FOTO+DOCUMENTO pasa; `S2` PENDIENTE intenta EN_DIAGNOSTICO→EN_REPARACION → 23514/42501-según trigger (no se avanza hasta resolver cobertura); `S3` presupuesto sobre GARANTIA → 23P02; sobre PAGO acepta y monto negativo → 22P02; `S4` flujo PAGO completo por RPC: presupuesto → PRESUPUESTADO → EN_REPARACION → REPARADO → ENTREGADO (cada transición pasa y el historial tiene 4 filas ESTADO + el evento de presupuesto); `S5` rechazar sin motivo → 22P02; con motivo de 9 → 22P02; RECHAZADO con motivo pasa; RECHAZADO→ENTREGADO por RECEPCION pasa; `S6` cambiar_estado a una transición inexistente (RECIBIDO→ENTREGADO) → 23514; `S7` TECNICO intenta asignar_tecnico → 42501; ADMIN asigna y el historial tiene la fila BITACORA con el nombre del técnico; `S8` asignar a un profiles inactivo/rol no técnico → 22P02; `S9` cambiar_estado por anon → permission denied.

- [ ] **Step 2: Escribir `28_permisos_matriz.sql`** — la tabla §7 del spec COMPLETA por RPC y por UPDATE directo, con claim por rol (patrón `SET ROLE authenticated` + `set_config`):consultas (leer v_tablero/ordenes/revisiones/adjuntos sí para los 4); plazos (24 repetido a nivel matriz sin duplicar, mínimo apuntado); confirmar/desestimar (sí ADMIN/JEFE, no TECNICO/RECEPCION); abrir orden sí 4; revisión técnica no RECEPCION; presupuesto no RECEPCION; decisión de cliente (PRESUPUESTADO→EN_REPARACION/RECHAZADO_POR_CLIENTE) sí RECEPCION; asignar técnico no TECNICO; ENTREGADO sí RECEPCION desde REPARADO/IRREPARABLE/RECHAZADO_POR_CLIENTE/RECHAZADO; RECHAZADO/ANULADO no TECNICO/RECEPCION; UPDATE directo de estado y costo_reparacion DENEGADO por permiso para los 4 (permission denied a nivel GRANT, mensaje 'permission denied for column estado'); `anon`: SELECT en las tablas nuevas y RPC → permission denied / 0 filas.

- [ ] **Step 3: Correr ambos en rojo** — FALLA > 0 (funciones no existen; GRANT de estado aún abierto).

- [ ] **Step 4: Implementar la 0021** — las 3 funciones (SECURITY DEFINER, search_path fijo) + los REVOKE/GRANT de columnas; reescribir en `13_registros.sql` / `97_pruebas_rechazos.sql` lo que toque el GRANT (aserciones movidas a la RPC); correr `bash supabase/tests/run.sh` hasta verde COMPLETO.

- [ ] **Step 5: Commit** — `git add supabase && git commit -m "feat(db): 0021 cambiar_estado/asignar_tecnico/registrar_presupuesto y cierre del UPDATE directo de estado y costo"`.

---

### Tarea 12: Frontend — menú, rutas y navegación (§8)

**Files:**
- Create: `frontend/src/features/navegacion/BarraNavegacion.jsx`, `frontend/src/features/navegacion/navegacion.css`, `frontend/src/features/navegacion/BarraNavegacion.test.jsx`
- Modify: `frontend/src/App.jsx` (rutas nuevas TODAS con `RutaProtegida rolesPermitidos={["ADMIN","JEFE_SERVICIO","TECNICO","RECEPCION"]}`): `/garantias/nueva`, `/garantias/consulta`, `/taller`, `/taller/nueva`, `/taller/:id` (el componente de cada una llega en las tareas 13–17; aquí se montan con stubs de una línea `<div>Nueva garantía</div>` etc. — SOLO en Tarea 12, luego cada tarea los reemplaza), `frontend/src/features/tablero/Tablero.jsx` + `Tablero.test.jsx` (botón "Nueva orden" → navigate('/garantias/consulta'))

**Interfaces:**
- Produces: `BarraNavegacion` (props: `rol`, `rutaActual`) con pestañas `Tablero`, `Ventas & Garantías` (activa en `/garantias/*`), `Taller` (activa en `/taller/*`) y las de 2c deshabilitadas ('Clientes', 'Notificaciones'); CSS solo con `--c-*` (superficie `--c-surface`, pestañas activas con `--c-accent-bg` y `--c-accent-text`, radio `--c-radio`, borde inferior `--c-border-soft`); el PDF (páginas 2–4) guia la jerarquía (barra superior con marca y usuario, pestañas debajo).

- [ ] **Step 1: Test en rojo** — `BarraNavegacion.test.jsx`: renderiza las 3 pestañas; 'Clientes'/'Notificaciones' aparecen deshabilitadas; la pestaña activa se marca según `rutaActual` (`/garantias/consulta` → 'Ventas & Garantías'); NO llama a Supabase (es presentacional). Correr `pnpm vitest run src/features/navegacion` → FALLA (no existe).

- [ ] **Step 2: Implementar** el componente + CSS (paleta 100% tokens), montarlo en las pantallas que lo usan de a poco NO — se monta en las tareas 13–17 junto con cada pantalla; en esta tarea SOLO existe el componente y las rutas stub en `App.jsx` (con las propias rutas protegidas) y el botón del Tablero.

- [ ] **Step 3: suites verdes + commit** — `cd frontend && pnpm test && pnpm lint && pnpm build`; `git add frontend && git commit -m "feat(frontend): barra de navegación (Tablero · Ventas & Garantías · Taller) y rutas de la fase 2a"`.

---

### Tarea 13: Pantalla `/garantias/nueva` — asistente de 3 pasos (§8, reutiliza Hito 1)

**Files:**
- Create: `frontend/src/features/garantias/garantiasService.js` + `garantiasService.test.js`, `frontend/src/features/garantias/NuevaGarantia.jsx` + `NuevaGarantia.test.jsx`, `frontend/src/features/garantias/garantias.css`
- Modify: `frontend/src/features/garantias/…` usa `PasoCliente.jsx`, `PasoCompra.jsx` de `../registro/pasos/` (por props, como hoy), `frontend/src/App.jsx` (reemplaza el stub de `/garantias/nueva`), `frontend/src/features/navegacion/BarraNavegacion.jsx` se monta en `NuevaGarantia`.
- Delete (aquí NO — el asistente viejo se retira en la Tarea 15 cuando `/taller/nueva` cubre su parte de orden): nothing.

**Interfaces:**
- Consumes: `registrar_garantia` (Tarea 8) — en `garantiasService.registrarGarantia({clienteId, productoId, serial, tipoSoporte, numeroSoporte, fechaEmision, plazoDias, origen='VENTA'})`; `buscarCliente`/`guardarCliente`/`listarProductos` de `registroService` (se importan, no se copian).
- Produces: `garantiasService.registrarGarantia` y su mapeo de errores; `origen` queda como prop con default `'VENTA'` (la Consulta lo usará con `'TALLER'` en la Tarea 14).

- [ ] **Step 1: Test en rojo para `garantiasService`** — `garantiasService.test.js` (mock de supabase como en `registroService.test.js`): `registrarGarantia` llama `registrar_garantia` con `p_origen: 'VENTA'`; respuesta ok → `{ok:true, datos:{equipo_id,…}}`; error 42501 → SIN_PERMISO; SIN_CONEXION en error de red. **Trasladar aquí el wrapper `registrarGarantia` que la Tarea 9 dejó provisional en `registroService`:** `registroService` deja de exportarlo, `NuevaGarantia` y `enviarOrden` importan de `garantiasService` (única fuente RPC del módulo garantías).

- [ ] **Step 2: Test en rojo para la pantalla** — `NuevaGarantia.test.jsx`: paso Cliente busca por documento (reutiliza `PasoCliente`); paso Compra permite sin soporte y VALIDA que un plazo distinto de 7/15 avise "solo el jefe puede fijar ese plazo" (aviso, no bloqueo — la base decide); paso Resumen: "Registrar garantía" llama al servicio y al exito navega a `/garantias/consulta` con el serial (`?serial=…`) para que la consulta muestre la garantía recié­n creada; sin orden y sin checklist ni fotos (nada de `PasoVerificacion` ni `PasoAdjuntos`); borrador 24 h reutilizado tal cual (`borrador.js`, por usuario, como hoy).

- [ ] **Step 3: Implementar** pantalla + servicio; `App.jsx` cambia el stub; `origen` prop con default.

- [ ] **Step 4: suites verdes + commit** — `git commit -m "feat(frontend): asistente de 3 pasos para registrar la garantía de la venta"`.

---

### Tarea 14: Pantalla `/garantias/consulta` — buscador único y resultado (§8, Review Focus 6)

**Files:**
- Create: `frontend/src/features/garantias/Consulta.jsx` + `Consulta.test.jsx`, `frontend/src/features/garantias/consulta.css`
- Modify: `frontend/src/features/garantias/garantiasService.js` + test (nueva función), `App.jsx` (stub→real)

**Interfaces:**
- Consumes: `garantiasService.buscarGarantia({serial?, documento?, factura?, orden?})` → `rpc('buscar_equipo', …)` (Tarea 8) — nueva función de `garantiasService` (única fuente RPC de garantías).
- Produces: `Consulta` con props ninguna (lee la ruta) y querystring `?serial=…` (llega de NuevaGarantia y de `?equipo=…`? no: `/taller/nueva?equipo=…` es otra pantalla).

- [ ] **Step 1: Service test en rojo** — `buscarGarantia` manda los 4 parámetros `p_serial/p_documento/p_factura/p_orden` (pasando `null` los que faltan) y el resultado crudo.

- [ ] **Step 2: Pantalla test en rojo** — casos del Review Focus 6 + §8: 4 criterios de búsqueda (serial, cédula/RIF, factura, orden) invocan buscarGarantia y el resultado muestra producto, serial, titular, PERIODO (inicio/fin), cobertura con color (usando `cobertura()` de `tablero/dominio.js` — mismo tono token que el tablero) y días restantes; sin resultados → 'No hay garantía registrada' + botón 'Registrar ahora' que navega a `/garantias/nueva?serial=<texto>&origen=TALLER`; resultado presente: 'Abrir orden de servicio' navega a `/taller/nueva?equipo=<equipo_id>`, y si `vigencia` ≠ EN_GARANTIA avisa ANTES (texto 'se atenderá como servicio pago' cuando FUERA/ANULADA o 'cobertura pendiente de confirmar' si POR_DETERMINAR); `estado_compra='DESESTIMADA'` muestra `motivo_desestimacion`; historial de órdenes (`ordenes` del resultado) como línea de tiempo con numero_orden, estado y fecha.

- [ ] **Step 3: Implementar** (CSS solo tokens; layout de una columna como el asistente).

- [ ] **Step 4: suites verdes + commit** — `git commit -m "feat(frontend): consulta de garantía con cobertura, historial y registro encadenado"`.

---

### Tarea 15: Pantalla `/taller/nueva?equipo=…` — abrir orden con auditoría de recepción (§8)

**Files:**
- Create: `frontend/src/features/taller/tallerService.js` + `tallerService.test.js`, `frontend/src/features/taller/AbrirOrden.jsx` + `AbrirOrden.test.jsx`, `frontend/src/features/taller/taller.css`
- Modify: `frontend/src/registro/enviarRegistro.js` y `registro/pasos/*` NO se tocan; `frontend/src/features/registro/NuevoRegistro.jsx` + `enviarRegistro.js` + `enviarRegistro.test.js` + `NuevoRegistro.test.jsx` y `borrador.js` + `borrador.test.js` + `useAsistente.js` + `useAsistente.test.js` se MUEVEN a `frontend/src/features/taller/` (el borrador de 24 h, la máquina de pasos y el reintento de adjuntos son de la orden) — en este mismo paso `borrador.js` pasa a admitir clave por módulo (`clave` con default 'orden', para que NuevaGarantia use 'garantia'); `abrirOrden` traslada de `registroService` a `tallerService` (y las importaciones que la usan); `App.jsx` (stub→real) y la ruta `/registro` desaparece (si llegara un enlace viejo, `Raiz`/`*` ya manda a las rutas válidas).
- Delete: `frontend/src/features/registro/NuevoRegistro.jsx` + su test (la UI del registro de 6 pasos desaparece; queda la ruta `/registro` SI EXISTE redirigiendo a `/garantias/consulta`; `enviarRegistro.js` se reescribe aqui dentro de `taller/` para el flujo nuevo: registrar_garantia (si hace falta) + abrir_orden + adjuntos)

**Interfaces:**
- Consumes: `buscarGarantia` (Tarea 14) para leer el equipo via `?equipo=<id>` (o serial por query), `PasoEquipo`? NO — el equipo va SOLO LECTURA (encabezado); `PasoAdjuntos` (fotos de auditoría + documentos, etiquetados), checklist via `PasoVerificacion`? El checklist de recepción sí se captura en esta pantalla: reutilizar `PasoVerificacion.jsx` (lista del §4.3 Hito 1 sin cambios) como "Auditoría de recepción".
- Produces: `tallerService.abrirOrden({equipoId, falla, accesorios, checklist, observaciones, claveEnvio})` (wrapper de `abrir_orden`), `tallerService.subirAdjuntos(ordenId, archivos, pendientes)` — REUTILIZA `registroService.subirAdjunto` (ya con rutas `ordenes/`), NO lo duplica; `enviarOrden(estado, archivos, opciones)` con la MISMA promesa de `enviarRegistro` (orden primero, adjuntos después, pendientes reintentables).

- [ ] **Step 1: `tallerService.test.js` en rojo** — `abrirOrden` manda la firma exacta de la 0019 (`p_equipo_id, p_falla, p_accesorios, p_checklist, p_observaciones, p_clave_envio`); errores SIN_PERMISO/SIN_CONEXION mapeados; `subirAdjuntos` reutiliza subirAdjunto y acumula pendientes.

- [ ] **Step 2: `AbrirOrden.test.jsx` en rojo** — muestra el equipo (leido por id) en solo lectura con aviso de cobertura (mismo criterio que la Consulta); campos: falla reportada (obligatoria, 5–2000), accesorios; auditoría: checklist + fotos (al menos una) + documentos — si `estado_compra='PENDIENTE'` el formulario SITA obligatorio con mensaje 'un equipo sin compra confirmada exige el documento presentado' (aviso con prueba, la base impone); al abrir: `claveEnvio` generada por envío (uuid) como hoy; éxito → navega a `/taller/<orden_id>`.

- [ ] **Step 3: Implementar + mover los módulos del asistente** (imports actualizados en todos los que los usaban; `pnpm build` caza imports rotos).

- [ ] **Step 4: suites verdes + commit** — `git commit -m "feat(frontend): abrir orden con auditoría de recepción; el asistente viejo queda retirado"`.

---

### Tarea 16: Pantalla `/taller/:id` — detalle de la orden (§8, barra de estados, pestañas, acciones)

**Files:**
- Create: `frontend/src/features/taller/OrdenDetalle.jsx` + `OrdenDetalle.test.jsx`, `frontend/src/features/taller/componentes/BarraEstados.jsx` (con test), `frontend/src/features/taller/componentes/PanelDocumentos.jsx`, `frontend/src/features/taller/componentes/PanelBitacora.jsx`
- Modify: `frontend/src/features/taller/tallerService.js` + test (funciones de lectura), `App.jsx` (stub→real), `features/revisiones/HistorialRevisiones.jsx`/`RevisionForm.jsx` se envuelve aquí (la pestaña Auditoría reutiliza ambos, ya con `orden_id`)

**Interfaces:**
- Consumes (nuevas funciones de `tallerService`, todas sobre las RPC/tablas existentes): `obtenerOrden(id)` (SELECT `ordenes_servicio` con `equipos`, `clientes`, `estados_garantia` vía `select` anidado); `historialOrden(id)`; `notasOrden(id)` + `agregarNota(id, texto)`; `adjuntosOrden(id)`; `cambiarEstado(ordenId, {estado, comentario, motivo})`, `asignarTecnico(ordenId, tecnicoId)`, `registrarPresupuesto(ordenId, monto)`, `listarTecnicos()` (`from('profiles').select('id, full_name').eq('role','TECNICO').eq('is_active', true)` — el GRANT/policy de profiles ya existe); `registrarRevision` reutilizada de `registroService`.
- Produces: la pantalla de detalle; `BarraEstados` (props: `estado`, `cobertura`, `tipoAtencion`) que dibuja Recibido → En diagnóstico → *Diagnosticado* (etapa visual, no estado; se marca SOLO si hay revisión TECNICA o texto de diagnostico) → (Presupuestado SOLO si tipo PAGO) → En reparación → Reparado → Entregado, con los estados laterales (EN_ESPERA_REPUESTO, IRREPARABLE, RECHAZADO_POR_CLIENTE, RECHAZADO, ANULADO, PRESUPUESTADO en Pago) como insignias (colores de `dominio.js`: 4 tonos). Acciones por rol (la UI ANTICIPA, la base decide): 'Avanzar a: X' (con el dropdown de las transiciones válidas del estado actual según el espejo `dominio.js` filtrado por rol), 'Rechazar' (modal con textarea motivo ≥ 10, mismo mínimo que la base, visible solo ADMIN/JEFE desde RECIBIDO/EN_DIAGNOSTICO/PRESUPUESTADO), 'Asignar técnico' (ADMIN/JEFE). Pestañas: Resumen (equipo/garantía/falla/accesorios/insignias de cobertura y atención) · Auditoría (HistorialRevisiones + RevisionForm) · Diagnóstico y presupuesto (textarea diagnostico con UPDATE directo de la columna que sigue abierta; monto con `registrarPresupuesto` solo si tipo PAGO; decisión del cliente 'Aceptó / No aceptó' → cambiar_estado) · Documentos (PanelDocumentos con las fotos/adjuntos listadas y el aviso de pendientes) · Bitácora (historial_ordenes + notas_internas: PanelBitacora).

- [ ] **Step 1: Service tests en rojo** — cada nueva función de lectura/escritura: exactos de query/rpc y mapeo de errores (mock supabase).

- [ ] **Step 2: Componentes/pantalla en rojo** — `BarraEstados.test.jsx`: PAGO muestra el paso Presupuestado; GARANTIA no; RECHAZADO aparece como insignia adversa; la etapa 'Diagnosticado' se marca con `diagnostico` cargado. `OrdenDetalle.test.jsx`: pestañas y contenido; `Rechazar` sin texto < 10 no envía (validación cliente) y muestra el error del servicio si la base lo rechaza; botones no visibles para RECEPCION (asignar/avanzar) excepto marcar ENTREGADO; insignia de atención (`GARANTIA`/`PAGO`/`PENDIENTE`) refleja `tipo_atencion`.

- [ ] **Step 3: Implementar** (CSS solo tokens; encabezado con numero_orden grande y `estado_nombre`).

- [ ] **Step 4: suites verdes + commit** — `git commit -m "feat(frontend): detalle de la orden con barra de estados, pestañas y acciones por rol"`.

---

### Tarea 17: Pantalla `/taller` — lista de órdenes y el Tablero de la fase (§8)

**Files:**
- Create: `frontend/src/features/taller/Tallerr.jsx` (nombre: `Taller.jsx`), `Taller.test.jsx`
- Modify: `frontend/src/features/tablero/Tablero.jsx` + `TablaOrdenes.jsx` (enlaza al DETALLE `/taller/:id`, no al modal), `App.jsx` (stub→real), `features/navegacion/BarraNavegacion.jsx` montada en Taller y Tablero

**Interfaces:**
- Consumes: `tableroService.listarTablero({estado})` (ya existe; la tabla `v_tablero` ya trae `orden_id`/`numero_orden` — la lista `/taller` es el mismo servicio con otro filtro/campos a pantalla).

- [ ] **Step 1: Test en rojo** — `Taller.jsx`: chips de filtro por estado (los `FILTROS` de `dominio.js` + `RECHAZADO`); filas con numero_orden, cliente, producto, garantía (nivel_vigencia), estado y fecha; clic en fila → `/taller/<orden_id>`; sin filas → estado vacío con mensaje; usa `listarTablero` (mock).

- [ ] **Step 2: Implementar** (reutilizar la tabla estilizada del Tablero via sus propias clases CSS de `tablero.css` o CSS propio con tokens; el botón del Tablero 'Nueva orden' ya va a la consulta desde la 12).

- [ ] **Step 3: suites verdes + commit** — `git commit -m "feat(frontend): lista de órdenes del taller con filtro por estado"`.

---

### Tarea 18: e2e, docs y cierre

**Files:**
- Modify: `scripts/e2e-registro.sh` (flujo nuevo), `scripts/verificar-migraciones.sh` (SOLO si lista versiones explícitas — ver Step), `README.md`, `ESTADO_DEL_PROYECTO.md`

**Interfaces:** ninguna nueva.

- [ ] **Step 1: Actualizar `e2e-registro.sh`** al flujo del spec §9: registrar garantía (VENTA) → buscar por serial → abrir orden → auditoría con mal uso (señal) → cobertura ANULADA_POR_USO → rechazar CON motivo → RECHAZADO→ENTREGADO. Mantener el estilo del script (pSQL contra el Postgres local de Docker; reutilizar la infraestructura `run.sh`/`preparar_base` si la hay).

- [ ] **Step 2: Correr el e2e** `bash scripts/e2e-registro.sh` → verde (si el script usa supabase-js con proyecto real, adaptarlo a las llamadas RPC en un Postgres local como hoy).

- [ ] **Step 3: `bash scripts/verificar-migraciones.sh`** → si valida una lista explícita de 12, actualizarla a la cadena completa (0013–0021) y que siga en verde.

- [ ] **Step 4: Documentar** — README (migraciones nuevas, RPC nueva, cómo correr las suites) y `ESTADO_DEL_PROYECTO.md` (nuevo corte: fase 2a completa local, matriz funcional 3.2/3.3 actualizada, condiciones de despliegue con la 0013–0021 y el aviso del repaso de adjuntos si el remoto tuviera la 0008 original).

- [ ] **Step 5: Suite COMPLETA final por escrito** — SQL + frontend + lint + build + e2e, todo en verde, y commit `docs+scripts: cierra la fase 2a (e2e del flujo garantía→taller y docs)`.

---

## Apéndice — decisiones tomadas al convertir el spec en plan (rulings)

1. **Espejo del dominio y bitácora de eventos:** `historial_ordenes` gana la columna `evento` ('ESTADO'/'BITACORA') porque el spec pide anotaciones sin cambio de estado (asignación, presupuesto, cobertura cambiada en reparación, costo limpiado por confirmación) y el CHECK actual (estado_anterior ≠ estado_nuevo) lo impedía. Costo si está mal: un poco de churn en pruebas del historial; el guardia combinado mantiene la promesa de inmutabilidad.
2. **`es_final` de RECHAZADO = FALSE** (tiene salida a ENTREGADO); `v_tablero.abierto` y `estaAbierta` lo cuentan como abierta hasta entregar. Costo si está mal: un RECHAZADO se mostraría/ordenaría como cerrado y la entrega final quedaría oculta.
3. **`equipos.origen` NOT NULL DEFAULT 'VENTA'** para no romper los INSERT existentes del Hito 1 ni las pruebas; `registrar_garantia` lo pasa explícito. Costo si está mal: equipos sin origen explícito se leen como de venta — con el default lo es.
4. **`REVIEW: la RPC con firma vieja de abrir_orden se RETIRA en la Tarea 9** (DROP), y el asistente del Hito 1 se re-cablea de una vez; se borrar del todo en la Tarea 15. Entre Tareas 9 y 15 las pruebas del frontend deben seguir en verde (por eso el re-cable va en la 9).
5. **El repaso de adjuntos va dentro de la 0013** (decisión del usuario: no sabemos si el remoto tiene la 0008 original; el repaso es idempotente).
6. **`calcular_cobertura` cambia a 6 parámetros con defaults** (compatibilidad con las 3-param existentes en pruebas del Hito 1 sin tocarlas).
7. **`es_final`/`Diagnosticado`:** la barra de estados del PDF muestra 'Diagnosticado' como ETAPA VISUAL (hay diagnóstico cargado), no como estado nuevo — sin columna nueva en la BD.
8. **No se agregan pantallas Clientes/Notificaciones** (2c); la barra las muestra deshabilitadas.