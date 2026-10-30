# Registro y control de garantía — Plan de implementación (Hito 1)

> **Para agentes:** SUB-SKILL REQUERIDA: usar `superpowers:subagent-driven-development` (recomendado) o `superpowers:executing-plans` para ejecutar este plan tarea por tarea. Los pasos usan casillas (`- [ ]`) para el seguimiento.

**Objetivo:** que el técnico registre un equipo por su serial con fotos y documentos, lo consulte en el Tablero con los días de vigencia que le quedan y anote las revisiones que evalúan el producto.

**Arquitectura:** una migración hacia adelante reemplaza el módulo `garantias` por `equipos`, `registros`, `revisiones` y `adjuntos`. Las reglas viven en Postgres (`calcular_cobertura`, triggers, funciones RPC, RLS) y se prueban con scripts SQL; el frontend React solo llama a las funciones y a una vista (`v_tablero`).

**Stack:** PostgreSQL 17 (Supabase), React 19 + Vite 8, vitest 3 + Testing Library, Edge Functions en Deno, Docker (solo para las pruebas SQL), GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-10-29-registro-y-control-de-garantia-design.md`

## Restricciones globales

- Toda la interfaz, mensajes de error y comentarios van en **español**.
- Node ≥ 22.12 y pnpm ≥ 10; `vitest` 3.x y `jsdom` 26 (versiones 5 y 30 traen `undici` 8, incompatible con Node 22.12).
- Vigencia: `vence_el = fecha_emision + plazo_dias`; el día de vencimiento cuenta como vigente; plazo de **1 a 365** días (la interfaz ofrece 7 y 15); "hoy" es `hoy_local()` en `America/Caracas`.
- Serial: **obligatorio**, de 3 a 60 caracteres; `serie_normalizada` = mayúsculas sin espacios ni guiones (los ceros a la izquierda se conservan); única junto con `producto_id`.
- Falla reportada de 5 a 2000 caracteres. Cédula, RIF o pasaporte: solo dígitos, de 5 a 15.
- Correlativo `REG-AAAA-NNNNNN` desde `registros_numero_seq`.
- Fotos: JPG, PNG o WEBP, ≤ 8 MB, máximo 8 por registro. Documentos: PDF, JPG o PNG, ≤ 8 MB, máximo 6 por registro. Bucket privado `registros`, rutas `registros/{registro_id}/…`.
- Urgencia por vigencia: vencida < 0, hoy = 0, crítica 1–3, pronto 4–7, normal > 7. SLA: normal < 7 días en taller, alerta 7–14, crítico ≥ 15 (se guardan en `ajustes`).
- Borrador local: caduca a las **24 h**, clave por usuario, se borra al terminar y al cerrar sesión. Búsqueda del serial: Enter o pausa de **400 ms**, mínimo 3 caracteres.
- Huérfanos de Storage: se borran los objetos sin fila en `adjuntos` y con más de **24 h**.
- Permisos: ver, ADMIN/JEFE_SERVICIO/TECNICO/RECEPCION; crear registro, los cuatro; revisar, ADMIN/JEFE_SERVICIO/TECNICO; confirmar compra, ADMIN/JEFE_SERVICIO; `anon` nada. Nadie borra ni edita revisiones ni adjuntos.
- No se copia código de Warracker (AGPL-3.0). No hay claves en el repositorio.
- Commits en español, formato `tipo(ámbito): resumen`, con la línea de coautoría que indique la sesión.
- **Regla de pruebas:** ninguna línea de código de producción sin una prueba que haya fallado antes por la razón esperada. Antes de dar una tarea por terminada corre la suite completa (SQL, vitest), `pnpm lint` y `pnpm build`, e informa cualquier fallo por su nombre.

## Foco de revisión

Entradas que el spec implica pero que ninguna tarea cubriría por defecto; cada una tiene su prueba en la tarea indicada.

1. **Dos técnicos registran el mismo serial a la vez** (el segundo no debe fallar por unicidad; reutiliza el equipo) → Tarea 11.
2. **Serial con formatos distintos** (`rt5-8842-aa`, `RT5 8842 AA`, `00123` frente a `123`) → Tarea 6.
3. **Registro cerca de medianoche en Caracas** (23:30 allí es el día siguiente en UTC) → Tareas 4 y 13.
4. **Foto de teléfono en HEIC o de más de 8 MB** (rechazo claro, sin perder el resto del registro) → Tareas 10 y 19.
5. **Sesión vencida a mitad del asistente** (el borrador se conserva y se pide volver a entrar) → Tarea 19.

## Estructura de archivos

| Ruta | Responsabilidad |
|---|---|
| `supabase/tests/run.sh` | Levanta Postgres en Docker, aplica el harness, las migraciones y las pruebas SQL |
| `scripts/verificar-migraciones.sh` | Falla si hay versiones de migración duplicadas o nombres mal formados |
| `supabase/migrations/20261030000004…0011_*.sql` | Una migración por tarea de base de datos (ver tareas) |
| `supabase/tests/10_…19_*.sql` | Una prueba SQL por migración |
| `supabase/functions/limpiar-huerfanos/` | Edge Function programada y su prueba |
| `frontend/src/features/registro/` | Servicios, normalización, borrador, hook del asistente y pasos |
| `frontend/src/features/tablero/` | Tablero con datos reales (reemplaza `datosDemo.js`) |
| `frontend/src/features/revisiones/` | Historial y formulario de revisión |
| `.github/workflows/ci.yml` | Integración continua |

---

### Tarea 1: Rama y ejecutor de pruebas SQL con línea base

**Files:**
- Create: `supabase/tests/run.sh`
- Modify: `supabase/tests/00_harness_supabase_local.sql`

**Interfaces:**
- Produces: `bash supabase/tests/run.sh [archivo.sql …]`. Con argumentos corre solo esos archivos; sin ellos, todos los `*.sql` en orden. Imprime `PASA n · FALLA m` por archivo y sale con código 1 si `m > 0` o si un archivo no imprime ninguna línea `PASA`.

- [ ] **Step 1: Crear la rama** `git switch -c feat/registro-y-control`.
- [ ] **Step 2: Escribir la prueba del ejecutor.** Crear `supabase/tests/zz_centinela.sql` con una línea `RAISE NOTICE '*FALLA*  centinela'` (dentro de un `DO`). Ejecutar `bash supabase/tests/run.sh supabase/tests/zz_centinela.sql`. Esperado: no existe `run.sh`, falla.
- [ ] **Step 3: Implementar `run.sh`.** Con `docker run --rm -d postgres:17`, esperar a `pg_isready`, crear los roles `anon`, `authenticated` y `service_role` (este con `BYPASSRLS`), aplicar el harness y cada migración con `ON_ERROR_STOP=1`, y cada prueba capturando las líneas `NOTICE`. Detener el contenedor al salir (`trap`).
- [ ] **Step 4: Verificar rojo y verde.** El centinela debe terminar con código 1 y mostrar `FALLA 1`. Cambiarlo a `PASA` debe dar código 0. Borrar el centinela.
- [ ] **Step 5: Línea base.** Correr `bash supabase/tests/run.sh` con las pruebas 96 a 99 existentes. Si falla por una extensión que no existe en Postgres plano (`pg_cron`) o por el esquema `storage`, añadir al harness un esquema `cron` y un esquema `storage` con `buckets(id, name, public)` y `objects(id, bucket_id, name, created_at)` mínimos. Esperado final: las cuatro pruebas existentes pasan como antes.
- [ ] **Step 6: Commit** `test(sql): ejecutor de pruebas en Docker y línea base`.

---

### Tarea 2: Historial de migraciones limpio y datos iniciales

**Files:**
- Create: `scripts/verificar-migraciones.sh`, `supabase/seed.sql`
- Move: `supabase/migrations/20260906000001_esquema_inicial.sql` y `_referencia_20260906000001_esquema_inicial.sql` → `supabase/archivo/`

**Interfaces:**
- Produces: `bash scripts/verificar-migraciones.sh` sale con 1 si dos archivos comparten versión o si algún nombre no cumple `^[0-9]{14}_[a-z0-9_]+\.sql$`.

- [ ] **Step 1: Escribir la comprobación** `verificar-migraciones.sh` y ejecutarla. Esperado: FALLA, informa la versión duplicada `20260906000001`.
- [ ] **Step 2: Reconciliar con el remoto.** Ejecutar `supabase migration list --linked`. Si el CLI no conecta (ya dio tiempo de espera), ejecutar en el SQL Editor `select version from supabase_migrations.schema_migrations order by 1` y comparar. Mover a `supabase/archivo/` el monolito y la referencia, que no deben aplicarse.
- [ ] **Step 3: Ejecutar** `verificar-migraciones.sh`. Esperado: sale 0.
- [ ] **Step 4: Escribir `seed.sql`** con 4 marcas y 8 productos de ejemplo (categorías `ROUTER`, `ONT`, `SWITCH`, `REPETIDOR`). Sin usuarios ni claves.
- [ ] **Step 5: Hacer que `run.sh` cargue el seed** tras las migraciones y que falle si `select count(*) from productos` es 0.
- [ ] **Step 6: Commit** `chore(db): historial de migraciones limpio y datos iniciales`.

---

### Tarea 3: Integración continua

**Files:**
- Create: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: `scripts/verificar-migraciones.sh`, `supabase/tests/run.sh`, scripts `test`, `lint`, `build` de `frontend/package.json`.

- [ ] **Step 1:** Definir el flujo con dos trabajos en `pull_request` y `push` a `main`: `base-de-datos` (verificar migraciones y `run.sh`) y `frontend` (pnpm 10, Node 22.12, `pnpm install --frozen-lockfile`, `pnpm test`, `pnpm lint`, `pnpm build`).
- [ ] **Step 2: Verificar localmente** cada comando del flujo. Esperado: todos salen 0.
- [ ] **Step 3: Verificar en GitHub** tras subir la rama: `gh run watch`. Esperado: ambos trabajos en verde.
- [ ] **Step 4: Commit** `ci: pruebas SQL, vitest, lint y build`.

---

### Tarea 4: `hoy_local()` y `ajustes`

**Files:**
- Create: `supabase/migrations/20261030000004_ajustes_y_cobertura.sql` (esta tarea y la 5 comparten la migración), `supabase/tests/10_ajustes.sql`

**Interfaces:**
- Produces: `public.hoy_local(p_ahora timestamptz DEFAULT now()) RETURNS date`; tabla `public.ajustes(clave text PRIMARY KEY, valor integer NOT NULL)` con `umbral_critico=3`, `umbral_pronto=7`, `sla_alerta=7`, `sla_critico=15`; `public.ajuste(p_clave text) RETURNS integer` (STABLE).

- [ ] **Step 1: Escribir `10_ajustes.sql`** con aserciones:
  - `hoy_local('2026-09-04 02:30+00') = '2026-09-03'` (23:30 en Caracas, UTC−4)
  - `hoy_local('2026-09-04 04:00+00') = '2026-09-04'`
  - `ajuste('umbral_critico') = 3` y `ajuste('sla_critico') = 15`
  - un `TECNICO` no puede actualizar `ajustes`; un `ADMIN` sí
- [ ] **Step 2: Verificar rojo:** `bash supabase/tests/run.sh supabase/tests/10_ajustes.sql`. Esperado: falla porque no existe `hoy_local`.
- [ ] **Step 3: Implementar** la función, la tabla, sus valores iniciales, `ajuste()` y la política (lectura para roles internos, escritura solo ADMIN).
- [ ] **Step 4: Verificar verde.** Esperado: `FALLA 0`.
- [ ] **Step 5: Commit** `feat(db): hoy_local y ajustes`.

---

### Tarea 5: `calcular_cobertura`

**Files:**
- Modify: `supabase/migrations/20261030000004_ajustes_y_cobertura.sql`
- Test: `supabase/tests/11_cobertura.sql`

**Interfaces:**
- Produces: `public.calcular_cobertura(p_vence_el date, p_fecha_ingreso date, p_checklist jsonb DEFAULT NULL) RETURNS public.cobertura_garantia` (IMMUTABLE, EXECUTE para `authenticated`); `public.motivo_anulacion(p_checklist jsonb) RETURNS text`; `public.checklist_es_valido(p_checklist jsonb) RETURNS boolean`.
- Estructura del `p_checklist`: `{"condiciones":{"factura_presentada":b,"titular_coincide":b},"equipo":{"serial_legible":b,"caja_original":b,"precintos_intactos":b,"contenido_completo":b},"senales":{"descarga_electrica":b,"liquidos":b,"altas_temperaturas":b,"golpes":b,"manipulacion_terceros":b}}`. En `condiciones` y `equipo`, `false` es un incumplimiento; en `senales`, `true` es una señal observada.

- [ ] **Step 1: Escribir `11_cobertura.sql`** con una tabla de casos `(vence_el, ingreso, checklist) → esperado` (vence `2026-09-10` salvo indicación):
  - ingreso `2026-09-03`, sin checklist → `EN_GARANTIA`
  - ingreso `2026-09-10` (día exacto) → `EN_GARANTIA`
  - ingreso `2026-09-11` → `FUERA_DE_GARANTIA`
  - `vence_el` NULL → `POR_DETERMINAR`
  - una señal `golpes=true` → `ANULADA_POR_USO`
  - cada una de las 5 señales por separado → `ANULADA_POR_USO`
  - `precintos_intactos=false` → `ANULADA_POR_USO`; igual para `serial_legible`, `caja_original` y `contenido_completo`
  - `factura_presentada=false` → `POR_DETERMINAR`; igual para `titular_coincide`
  - `golpes=true` y ingreso vencido → `FUERA_DE_GARANTIA` (la fecha manda sobre la anulación)
  - `golpes=true` y `factura_presentada=false` → `ANULADA_POR_USO` (la anulación manda sobre la condición)
  - `vence_el` NULL y `golpes=true` → `POR_DETERMINAR`
  - `motivo_anulacion` nombra lo observado; `checklist_es_valido` rechaza claves faltantes y valores no booleanos
- [ ] **Step 2: Verificar rojo** (`run.sh … 11_cobertura.sql`). Esperado: no existe la función.
- [ ] **Step 3: Implementar** con la precedencia del spec, sección 4.2.
- [ ] **Step 4: Verificar verde.**
- [ ] **Step 5: Commit** `feat(db): calcular_cobertura con tabla de casos`.

---

### Tarea 6: Tabla `equipos`

**Files:**
- Create: `supabase/migrations/20261030000005_equipos.sql`, `supabase/tests/12_equipos.sql`

**Interfaces:**
- Consumes: `productos`, `clientes` (migración 0002).
- Produces: `public.normalizar_serie(p_serie text) RETURNS text` (IMMUTABLE); tabla `public.equipos` con las columnas de la sección 5.1 del spec; índice único `(producto_id, serie_normalizada)`.

- [ ] **Step 1: Escribir `12_equipos.sql`:**
  - `normalizar_serie('rt5-8842-aa') = normalizar_serie('RT5 8842 AA')`
  - `normalizar_serie('00123') <> normalizar_serie('123')`
  - insertar sin serie, con serie de 2 caracteres o de 61 → rechazado
  - dos equipos con la misma serie normalizada y el mismo producto → rechazado; con productos distintos → aceptado
  - `fecha_emision='2026-09-01'` y `plazo_dias=7` → `vence_el='2026-09-08'`
  - `plazo_dias` 0 y 366 rechazados; `fecha_emision` sin `plazo_dias` rechazado; fecha anterior a 2000-01-01 o futura rechazada
  - sin soporte: `fecha_emision`, `plazo_dias` y `vence_el` NULL es válido
  - `anon` no lee la tabla; los cuatro roles internos sí; ningún rol interno inserta directamente (solo las funciones)
- [ ] **Step 2: Verificar rojo.**
- [ ] **Step 3: Implementar** la función, la tabla (con `vence_el` y `serie_normalizada` como columnas generadas), las restricciones, los índices, el trigger `updated_at`, RLS y GRANTs (solo `SELECT`).
- [ ] **Step 4: Verificar verde.**
- [ ] **Step 5: Commit** `feat(db): tabla equipos con serial único por producto`.

---

### Tarea 7: Tabla `registros` (reemplaza `garantias`)

**Files:**
- Create: `supabase/migrations/20261030000006_registros.sql`, `supabase/tests/13_registros.sql`
- Modify: `supabase/tests/99_pruebas_seguridad.sql` (portar las 25 referencias a `garantias`, `crear_garantia`, `historial_garantias` y `notas_internas`)

**Interfaces:**
- Consumes: `equipos`, `estados_garantia`, `transiciones_estado`, `profiles`.
- Produces: `public.registros` (sección 5.2 del spec) con `numero_registro text UNIQUE DEFAULT 'REG-'||to_char(now(),'YYYY')||'-'||lpad(nextval('registros_numero_seq')::text,6,'0')`; `historial_registros`, `notas_internas(registro_id)`; triggers de validación de transición, historial y `updated_at`.

- [ ] **Step 1: Escribir `13_registros.sql`** y portar `99`: los mismos casos que hoy prueban la máquina de estados, el historial inmutable, las políticas de actualización por rol y las notas, ahora sobre los nombres nuevos. Añadir:
  - dos inserciones seguidas dan `numero_registro` distintos con formato `^REG-[0-9]{4}-[0-9]{6}$`
  - `ENTREGADO` exige `fecha_entrega`; `ANULADA_POR_USO` exige `motivo_anulacion_cobertura`
  - un TECNICO solo actualiza registros asignados a él y abiertos
- [ ] **Step 2: Verificar rojo.**
- [ ] **Step 3: Implementar.** Eliminar el módulo viejo (`garantias`, `historial_garantias`, `consulta_publica_intentos`, `crear_garantia`, `consultar_garantia`, `calcular_vencimiento_garantia`, la secuencia vieja y sus políticas) y recrearlo con los nombres nuevos, portando textualmente la lógica de las líneas 337–445 de `20260906000002_garantias.sql` con los identificadores renombrados. Conservar `estados_garantia`, `transiciones_estado`, `marcas`, `productos`, `clientes`.
- [ ] **Step 4: Verificar verde** con la suite completa (`run.sh` sin argumentos).
- [ ] **Step 5: Commit** `feat(db): tabla registros con correlativo por secuencia`.

---

### Tarea 8: Consulta pública del registro

**Files:**
- Modify: `supabase/migrations/20261030000006_registros.sql`
- Test: `supabase/tests/13_registros.sql` (sección nueva)

**Interfaces:**
- Produces: `public.consultar_registro(p_numero_registro text, p_token text)`, mismas columnas de salida que `consultar_garantia` con `numero_registro` en lugar de `numero_orden`; `consulta_publica_intentos`. Sin interfaz en este hito.

- [ ] **Step 1: Portar a la prueba** los casos que hoy cubren `consultar_garantia` (token correcto, token incorrecto, límite por IP, ausencia de datos internos como notas). Añadir: `anon` puede ejecutarla y no puede leer ninguna tabla.
- [ ] **Step 2: Verificar rojo. Step 3: Implementar** portando el cuerpo de `consultar_garantia`. **Step 4: Verificar verde.**
- [ ] **Step 5: Commit** `feat(db): consultar_registro`.

---

### Tarea 9: Tabla `revisiones`

**Files:**
- Create: `supabase/migrations/20261030000007_revisiones.sql`, `supabase/tests/14_revisiones.sql`

**Interfaces:**
- Consumes: `calcular_cobertura`, `checklist_es_valido`, `motivo_anulacion`, `registros`, `equipos`.
- Produces: `public.revisiones(id, registro_id, tipo, revisado_por, revisado_en, checklist, resultado, observaciones)`; trigger `BEFORE INSERT` que **calcula `resultado`** e ignora lo que envíe el cliente; trigger `AFTER INSERT` que actualiza `registros.cobertura` y `motivo_anulacion_cobertura`.

- [ ] **Step 1: Escribir `14_revisiones.sql`:**
  - insertar con `resultado='EN_GARANTIA'` y un checklist con `golpes=true` guarda `ANULADA_POR_USO` (el cliente no decide)
  - `registros.cobertura` queda igual al resultado de la última revisión, y `motivo_anulacion_cobertura` se llena cuando es `ANULADA_POR_USO`
  - checklist inválido rechazado
  - `UPDATE` y `DELETE` lanzan una excepción cuyo mensaje contiene `solo de anexar`, tanto como `authenticated` como como `service_role` y como propietario
  - `TRUNCATE` lanza la misma excepción
- [ ] **Step 2: Verificar rojo. Step 3: Implementar** (tabla, CHECK de checklist, ambos triggers de cobertura, y triggers `BEFORE UPDATE OR DELETE` por fila y `BEFORE TRUNCATE` por sentencia con `RAISE EXCEPTION`). **Step 4: Verificar verde.**
- [ ] **Step 5: Commit** `feat(db): revisiones inmutables con cobertura calculada`.

---

### Tarea 10: Adjuntos y bucket de Storage

**Files:**
- Create: `supabase/migrations/20261030000008_adjuntos.sql`, `supabase/tests/15_adjuntos.sql`

**Interfaces:**
- Produces: `public.adjuntos(id, registro_id, revision_id NULL, tipo, etiqueta, ruta, mime, bytes, subido_por, subido_en)`; bucket privado `registros` y políticas de `storage.objects` por ruta.

- [ ] **Step 1: Escribir `15_adjuntos.sql`:**
  - `FOTO` con `image/jpeg`, `image/png` y `image/webp` aceptadas; `image/heic` y `application/pdf` como foto rechazadas con un mensaje que menciona JPG, PNG o WEBP
  - `bytes` de 8 MB + 1 rechazado; la novena foto y el séptimo documento del mismo registro rechazados
  - `UPDATE`, `DELETE` y `TRUNCATE` bloqueados como en las revisiones
  - `anon` no inserta ni lee; un usuario sin rol no sube a `storage.objects` del bucket; un rol interno sí sube a una ruta que empieza por un `registro_id` existente y no a otra
  - el bucket `registros` no es público
- [ ] **Step 2: Verificar rojo. Step 3: Implementar** (tabla, triggers de límite y de inmutabilidad, bucket y políticas). **Step 4: Verificar verde.**
- [ ] **Step 5: Commit** `feat(db): adjuntos inmutables y bucket privado`.

---

### Tarea 11: Clientes, `buscar_equipo` y `registrar_ingreso`

**Files:**
- Create: `supabase/migrations/20261030000009_rpc_registro.sql`, `supabase/tests/16_rpc_ingreso.sql`

**Interfaces:**
- Produces (todas `SECURITY DEFINER`, `search_path = public, pg_temp`, EXECUTE solo para `authenticated`):
  - `public.guardar_cliente(p_tipo public.tipo_documento, p_documento text, p_nombre text, p_telefono text, p_email text, p_direccion text) RETURNS uuid`: crea o devuelve el cliente de `(tipo, documento)`.
  - `public.buscar_equipo(p_serial text) RETURNS TABLE(equipo_id uuid, producto_id uuid, producto text, numero_serie text, titular_id uuid, titular text, vence_el date, dias_restantes integer, registros jsonb)`: busca por `serie_normalizada` en **todos** los productos.
  - `public.registrar_ingreso(p_serial text, p_producto_id uuid, p_cliente_id uuid, p_falla text, p_accesorios text, p_tipo_soporte text, p_numero_soporte text, p_fecha_emision date, p_plazo_dias integer, p_vendedor text, p_checklist jsonb, p_observaciones text) RETURNS TABLE(registro_id uuid, numero_registro text, consulta_token text, cobertura public.cobertura_garantia, equipo_id uuid, equipo_nuevo boolean)`.

- [ ] **Step 1: Escribir `16_rpc_ingreso.sql`:**
  - un TECNICO registra un ingreso completo: existen equipo, registro y una revisión de tipo `RECEPCION`; `tecnico_asignado_id` es el técnico; el token devuelto tiene 32 caracteres y la tabla guarda solo su hash
  - segundo ingreso con el mismo serial y producto reutiliza el equipo (`equipo_nuevo=false`) y no duplica la factura; con el serial escrito `rt5 8842 aa` también
  - **dos ingresos seguidos con el mismo serial no producen error de unicidad** (Foco de revisión 1)
  - `buscar_equipo` devuelve el equipo existente aunque se consulte con otro formato; si el serial existe con otro producto, devuelve ambas filas
  - atomicidad: un checklist inválido no deja ningún equipo ni registro
  - sin factura (`p_fecha_emision` NULL): `cobertura = POR_DETERMINAR` y `vence_el` NULL
  - ingreso a las `2026-09-04 02:30+00` evalúa el día `2026-09-03` (Foco de revisión 3)
  - `anon` y un usuario sin perfil: rechazados; `guardar_cliente` con documento de 4 dígitos rechazado
- [ ] **Step 2: Verificar rojo. Step 3: Implementar.** En `registrar_ingreso`, buscar el equipo y, si no existe, insertarlo con `ON CONFLICT (producto_id, serie_normalizada) DO NOTHING` y volver a leerlo; crear el registro y la revisión de recepción; el token sale de `gen_random_bytes(16)` y se guarda con `sha256`. **Step 4: Verificar verde.**
- [ ] **Step 5: Commit** `feat(db): registrar_ingreso, buscar_equipo y guardar_cliente`.

---

### Tarea 12: `registrar_revision`, `confirmar_compra` y matriz de permisos

**Files:**
- Modify: `supabase/migrations/20261030000009_rpc_registro.sql`
- Create: `supabase/tests/17_rpc_revision.sql`

**Interfaces:**
- Produces: `public.registrar_revision(p_registro_id uuid, p_tipo text, p_checklist jsonb, p_observaciones text) RETURNS TABLE(revision_id uuid, cobertura public.cobertura_garantia)`; `public.confirmar_compra(p_equipo_id uuid, p_tipo_soporte text, p_numero_soporte text, p_fecha_emision date, p_plazo_dias integer) RETURNS void`.

- [ ] **Step 1: Escribir `17_rpc_revision.sql`:**
  - matriz de permisos: crear registro permitido a los 4 roles; `registrar_revision` permitido a ADMIN, JEFE_SERVICIO y TECNICO y **rechazado a RECEPCION**; `confirmar_compra` solo ADMIN y JEFE_SERVICIO; `anon` rechazado en todo
  - una revisión técnica con `golpes=true` cambia la cobertura del registro a `ANULADA_POR_USO`; una posterior limpia la devuelve a `EN_GARANTIA` y la anterior sigue guardada
  - `confirmar_compra` sobre un equipo sin factura llena los datos, guarda quién y cuándo, y deja `vence_el` calculado; los registros abiertos del equipo pasan de `POR_DETERMINAR` a su cobertura real
  - `confirmar_compra` sobre un equipo que ya tiene factura se rechaza
- [ ] **Step 2: Verificar rojo. Step 3: Implementar. Step 4: Verificar verde** con la suite completa.
- [ ] **Step 5: Commit** `feat(db): revisiones y confirmación de compra con permisos`.

---

### Tarea 13: Vista `v_tablero`

**Files:**
- Create: `supabase/migrations/20261030000010_v_tablero.sql`, `supabase/tests/18_tablero.sql`

**Interfaces:**
- Produces: vista `public.v_tablero` con `security_invoker = true` y las columnas `registro_id, numero_registro, estado, estado_nombre, cobertura, serial, producto, cliente, documento, fecha_ingreso, vence_el, dias_restantes, nivel_vigencia, dias_en_taller, nivel_sla, urgencia_rank, abierto`. Niveles de vigencia: `VENCIDA, HOY, CRITICA, PRONTO, NORMAL, PENDIENTE`; de SLA: `NORMAL, ALERTA, CRITICO`. `urgencia_rank` = mayor entre rango de vigencia (0 normal, 1 pronto o pendiente, 2 crítica, 3 hoy, 4 vencida; **solo cuenta si `cobertura` es `EN_GARANTIA` o `POR_DETERMINAR`, si no vale 0**) y rango de SLA (0, 1, 2); `-1` si está cerrado.

- [ ] **Step 1: Escribir `18_tablero.sql`** con `hoy_local` fijado por un registro creado con fechas relativas:
  - vigencia 8 días → `NORMAL`; 7 → `PRONTO`; 4 → `PRONTO`; 3 → `CRITICA`; 1 → `CRITICA`; 0 → `HOY`; −1 → `VENCIDA`; sin fecha → `PENDIENTE`
  - 6 días en taller → SLA `NORMAL`; 7 → `ALERTA`; 14 → `ALERTA`; 15 → `CRITICO`
  - **caso del spec:** un registro recién ingresado con `cobertura=FUERA_DE_GARANTIA` y vigencia vencida tiene `urgencia_rank` menor que uno `EN_GARANTIA` con 15 días en taller
  - los registros `ENTREGADO` y `ANULADO` tienen `urgencia_rank = -1` y salen al final con `ORDER BY urgencia_rank DESC, fecha_ingreso`
  - `anon` no lee la vista; un TECNICO lee todos los registros
- [ ] **Step 2: Verificar rojo. Step 3: Implementar** usando `hoy_local()` y `ajuste()`. **Step 4: Verificar verde.**
- [ ] **Step 5: Commit** `feat(db): vista del tablero con urgencia combinada`.

---

### Tarea 14: Limpieza de archivos huérfanos

**Files:**
- Create: `supabase/migrations/20261030000011_limpieza_huerfanos.sql`, `supabase/tests/19_huerfanos.sql`, `supabase/functions/limpiar-huerfanos/index.ts`, `supabase/functions/limpiar-huerfanos/index.test.ts`

**Interfaces:**
- Produces: `public.listar_huerfanos(p_gracia interval DEFAULT interval '24 hours') RETURNS TABLE(nombre text)` (EXECUTE solo `service_role`); Edge Function `POST /limpiar-huerfanos[?simular=1]`, que exige la cabecera `x-cron-secret` igual al secreto `LIMPIEZA_SECRET` y responde `{"huerfanos": n, "borrados": n, "simulacion": bool}`.

- [ ] **Step 1: Escribir `19_huerfanos.sql`:** objeto sin fila y de 25 h → listado; objeto sin fila y de 23 h → no; objeto con fila en `adjuntos` y de 48 h → no; otro bucket → no; `authenticated` no puede ejecutar la función.
- [ ] **Step 2: Escribir `index.test.ts`** (vitest, `Deno` y supabase simulados como en `mfa-enviar-codigo`): sin `x-cron-secret` → 401; con secreto y `?simular=1` → informa los nombres y **no llama a `remove`**; con secreto y sin simular → llama a `remove` con exactamente los nombres devueltos por `listar_huerfanos`; si `listar_huerfanos` devuelve vacío no llama a `remove`; un fallo de Storage responde 500 sin borrar nada más.
- [ ] **Step 3: Verificar rojo** (`run.sh … 19_huerfanos.sql` y `pnpm vitest run ../supabase/functions/limpiar-huerfanos` desde `frontend/`).
- [ ] **Step 4: Implementar** la función SQL (anti-join entre `storage.objects` y `adjuntos.ruta`) y la Edge Function. La programación diaria (`cron.schedule` con `pg_net`) va en la misma migración protegida por `to_regnamespace('cron') IS NOT NULL`.
- [ ] **Step 5: Verificar verde.** Paso manual posterior al despliegue: desplegar la función, definir `LIMPIEZA_SECRET` y ejecutarla con `?simular=1` contra el proyecto real.
- [ ] **Step 6: Commit** `feat(storage): limpieza diaria de archivos huérfanos`.

---

### Tarea 15: Servicios y normalización del frontend

**Files:**
- Create: `frontend/src/features/registro/normalizar.js`, `frontend/src/features/registro/registroService.js`, y sus `.test.js`
- Modify: `frontend/vitest.config.js` (incluir `src/**/*.test.{js,jsx}`)

**Interfaces:**
- Produces: `normalizarSerie(s: string): string`; `normalizarDocumento(s: string): {tipo: string|null, documento: string}` (`'J-30.589.214-7'` → `{tipo:'J', documento:'305892147'}`); en `registroService.js`: `buscarEquipo(serial)`, `guardarCliente(datos)`, `registrarIngreso(payload)`, `subirAdjunto(registroId, archivo, {tipo, etiqueta})`, `registrarRevision(registroId, {tipo, checklist, observaciones})`, `previsualizarCobertura({venceEl, fechaIngreso, checklist})`. Cada una devuelve `{ok:true, datos}` o `{ok:false, codigo, mensaje}`; códigos: `SIN_PERMISO` (42501), `SIN_CONEXION`, `SESION_VENCIDA` (401), `FORMATO_NO_ADMITIDO`, `LIMITE`, `DESCONOCIDO`.

- [ ] **Step 1: Escribir las pruebas:** `normalizarSerie('rt5-8842-aa') === normalizarSerie('RT5 8842 AA')` y `'00123' !== '123'`; `normalizarDocumento` con puntos, guiones y letra de tipo, y con espacios; en el servicio, con el cliente de Supabase simulado en el borde (`../../lib/supabaseClient.js`): cada función llama a la RPC con los nombres de parámetro exactos de las Tareas 11 y 12; un error `42501` da `SIN_PERMISO`; un `fetch` que lanza da `SIN_CONEXION`; un 401 da `SESION_VENCIDA`; `subirAdjunto` rechaza `image/heic` y archivos de más de 8 MB **antes** de subir, con `FORMATO_NO_ADMITIDO` y `LIMITE`.
- [ ] **Step 2: Verificar rojo:** `pnpm vitest run src/features/registro`. **Step 3: Implementar. Step 4: Verificar verde.**
- [ ] **Step 5: Commit** `feat(registro): servicios y normalización`.

---

### Tarea 16: Borrador local de 24 horas

**Files:**
- Create: `frontend/src/features/registro/borrador.js`, `borrador.test.js`
- Modify: `frontend/src/features/auth/authService.js` (`cerrarSesion` llama a `limpiarBorradores`)

**Interfaces:**
- Produces: `guardarBorrador(userId: string, estado: object): void`; `leerBorrador(userId: string): object|null` (devuelve `null` si pasaron 24 h y lo elimina); `limpiarBorrador(userId: string): void`; `limpiarBorradores(): void` (todos los usuarios). Clave de `localStorage`: `pt.borrador.{userId}`. El estado guardado nunca incluye archivos.

- [ ] **Step 1: Escribir las pruebas** con relojes simulados: a 23 h 59 min se lee; a 24 h 1 min devuelve `null` y la clave desaparece; el borrador de un usuario no es visible para otro; `limpiarBorrador` y `limpiarBorradores` borran; `cerrarSesion` limpia aunque falle la red; un `File` incluido por error en el estado se descarta al guardar.
- [ ] **Step 2: Verificar rojo. Step 3: Implementar. Step 4: Verificar verde.**
- [ ] **Step 5: Commit** `feat(registro): borrador local con caducidad de 24 horas`.

---

### Tarea 17: Asistente: estructura y paso del serial

**Files:**
- Create: `frontend/src/features/registro/useAsistente.js`, `NuevoRegistro.jsx`, `pasos/PasoEquipo.jsx`, y sus pruebas

**Interfaces:**
- Consumes: `buscarEquipo`, `normalizarSerie`, `guardarBorrador`, `leerBorrador`.
- Produces: `useAsistente(userId)` → `{paso, pasos, estado, ir(n), siguiente(), atras(), actualizar(parcial), reiniciar()}`; los pasos, en orden: `equipo, cliente, compra, verificacion, adjuntos, resumen`. `<NuevoRegistro onCerrar onCreado />`.

- [ ] **Step 1: Escribir las pruebas** con Testing Library y `userEvent`:
  - al abrir, el campo del serial tiene el foco
  - escribir `RT5-8842-AA` rápido y pulsar Enter dispara **una** búsqueda; escribir y esperar 400 ms la dispara; con 2 caracteres no se dispara; Enter no envía ni cierra el formulario
  - si `buscarEquipo` devuelve un equipo, se muestran titular, vigencia e historial y se **omite el paso `compra`**
  - si el serial existe con otro producto, aparece la advertencia "este serial está registrado como …" y no se crea el equipo sin confirmar
  - el borrador se guarda al avanzar y se ofrece restaurar al reabrir
- [ ] **Step 2: Verificar rojo. Step 3: Implementar** el hook (estado y navegación) y el paso 1. **Step 4: Verificar verde.**
- [ ] **Step 5: Commit** `feat(registro): asistente y paso del serial con lector de códigos`.

---

### Tarea 18: Asistente: pasos Cliente, Compra y Verificación

**Files:**
- Create: `frontend/src/features/registro/pasos/PasoCliente.jsx`, `PasoCompra.jsx`, `PasoVerificacion.jsx`, y sus pruebas

**Interfaces:**
- Consumes: `guardarCliente`, `normalizarDocumento`, `previsualizarCobertura`, el hook de la Tarea 17.

- [ ] **Step 1: Escribir las pruebas:**
  - cliente: escribir `J-30.589.214-7` rellena tipo `J` y documento `305892147`; un documento de 4 dígitos muestra el error junto al campo; "cliente existente" y "nuevo" alternan los campos
  - compra: elegir 7 o 15 días y una fecha de emisión muestra la fecha de vencimiento calculada; marcar "no trae la factura" desactiva soporte, fecha y plazo y muestra el aviso de cobertura por determinar
  - verificación: cada casilla llama a `previsualizarCobertura` y muestra el título que devuelve la base (no se calcula en el navegador); marcar `golpes` muestra `ANULADA_POR_USO` y el motivo; si la llamada falla muestra "Se calculará al guardar" sin bloquear
- [ ] **Step 2: Verificar rojo. Step 3: Implementar. Step 4: Verificar verde.**
- [ ] **Step 5: Commit** `feat(registro): pasos de cliente, compra y verificación`.

---

### Tarea 19: Asistente: fotos, documentos, resumen y envío con reintento

**Files:**
- Create: `frontend/src/features/registro/pasos/PasoAdjuntos.jsx`, `PasoResumen.jsx`, `enviarRegistro.js`, y sus pruebas

**Interfaces:**
- Consumes: `registrarIngreso`, `subirAdjunto`, `limpiarBorrador`.
- Produces: `enviarRegistro(estado, archivos): Promise<{ok:boolean, registro?, pendientes: Archivo[], codigo?}>`: primero `registrarIngreso`; después sube cada archivo; los que fallen quedan en `pendientes`.

- [ ] **Step 1: Escribir las pruebas:**
  - un `File` `image/heic` o de 9 MB se rechaza con el mensaje "Formato no admitido: usa JPG, PNG o WEBP" o el de tamaño, sin quitar los demás adjuntos
  - la novena foto muestra el límite
  - si `registrarIngreso` responde bien y 1 de 3 subidas falla, el resultado trae `pendientes` con ese archivo, el registro **existe** y se ofrece "Reintentar adjuntos"; reintentar sube solo el pendiente
  - si `registrarIngreso` falla por `SESION_VENCIDA`, el borrador **se conserva** y se muestra "Tu sesión venció: vuelve a entrar para continuar" (Foco de revisión 5)
  - si todo sale bien se llama a `limpiarBorrador`
  - el resumen lista cliente, equipo, falla, compra, verificación y adjuntos, con "Editar" que vuelve a ese paso
- [ ] **Step 2: Verificar rojo. Step 3: Implementar. Step 4: Verificar verde.**
- [ ] **Step 5: Commit** `feat(registro): adjuntos, resumen y envío con reintento`.

---

### Tarea 20: Tablero con datos reales y rutas por rol

**Files:**
- Create: `frontend/src/features/tablero/tableroService.js`, `componentes/TablaRegistros.jsx`, y sus pruebas
- Modify: `frontend/src/features/tablero/Tablero.jsx`, `frontend/src/App.jsx`, `frontend/src/features/auth/authService.js` (`RUTA_POR_ROL`)
- Delete: `frontend/src/features/tablero/datosDemo.js`

**Interfaces:**
- Produces: `listarTablero({busqueda, estado, urgencia}): Promise<{ok, filas}>` sobre `v_tablero` con orden `urgencia_rank DESC, fecha_ingreso`; la búsqueda cubre serial, cliente, documento, número de soporte y `numero_registro`.

- [ ] **Step 1: Escribir las pruebas:**
  - `listarTablero` pide la vista con el orden y los filtros correctos
  - la tabla muestra por separado **días restantes** y **días en taller**, con el color de cada nivel; una fila `PENDIENTE` muestra "Sin factura"
  - el botón dice **"Nuevo registro"** y abre el asistente
  - `RUTA_POR_ROL`: los cuatro roles (`ADMIN`, `JEFE_SERVICIO`, `TECNICO`, `RECEPCION`) aterrizan en `/tablero`; `RECEPCION` no ve el botón de revisión
  - estado vacío y estado de error con "Reintentar"
- [ ] **Step 2: Verificar rojo. Step 3: Implementar.** Reutilizar los componentes `BarraLateral` y `PanelVencimientos` conectados a `v_tablero`; quitar los datos de demostración. **Step 4: Verificar verde** y `pnpm build`.
- [ ] **Step 5: Commit** `feat(tablero): datos reales, urgencia combinada y Nuevo registro`.

---

### Tarea 21: Revisiones

**Files:**
- Create: `frontend/src/features/revisiones/HistorialRevisiones.jsx`, `RevisionForm.jsx`, y sus pruebas

**Interfaces:**
- Consumes: `registrarRevision`; lectura de `revisiones` por `registro_id`.

- [ ] **Step 1: Escribir las pruebas:** el historial muestra las revisiones en orden cronológico inverso con revisor, fecha, resultado y observaciones; no hay botones de editar ni borrar; el formulario envía el checklist y muestra el resultado devuelto por la base; para `RECEPCION` el formulario no se muestra; un error `SIN_PERMISO` se muestra junto al formulario.
- [ ] **Step 2: Verificar rojo. Step 3: Implementar. Step 4: Verificar verde.**
- [ ] **Step 5: Commit** `feat(revisiones): historial y formulario de revisión`.

---

### Tarea 22: Integración de punta a punta y documentación

**Files:**
- Create: `scripts/e2e-registro.sh`
- Modify: `ESTADO_DEL_PROYECTO.md`, `README.md`

**Interfaces:**
- Consumes: todo lo anterior.

- [ ] **Step 1: Escribir `e2e-registro.sh`:** sobre la base de pruebas, como un TECNICO: `guardar_cliente` → `registrar_ingreso` con serial `RT5-8842-AA` y plazo 7 → `v_tablero` lo muestra con 7 días → `registrar_revision` con `golpes=true` → el registro queda `ANULADA_POR_USO` → se intenta `UPDATE` de la revisión y falla. Sale 1 ante cualquier desvío.
- [ ] **Step 2: Verificar rojo** (antes de que `run.sh` lo incluya) **y verde** después.
- [ ] **Step 3: Documentar:** actualizar `ESTADO_DEL_PROYECTO.md` (matriz, deuda y pendientes del hito 2) y reemplazar el README vacío por qué es el proyecto, cómo correr las pruebas SQL (`bash supabase/tests/run.sh`) y el frontend, y el enlace al spec y a este plan.
- [ ] **Step 4: Verificación final:** suite SQL completa, `pnpm test`, `pnpm lint`, `pnpm build`, y la CI en verde.
- [ ] **Step 5: Commit** `docs: estado del proyecto y prueba de punta a punta del hito 1`.
