# Track Garantía — Estado del proyecto

**Prime Telecom · Sistema de seguimiento de garantías y reparaciones**
**Corte:** 2026-10-30 · **Rama:** `feat/registro-y-control` (hito 1, PR #1) · último commit: ver `git log -1`

> Documento pensado para dos usos: **presentar** el sistema y **dar contexto rápido a agentes de IA** para planificar. Describe lo que hay *ahora* en el repo. Donde un documento antiguo contradiga a este, manda este (ver §6).

---

## 1. Resumen en 30 segundos

Aplicación web para un taller de servicio técnico: el técnico **registra un equipo por su serial** (con fotos y documentos, admite lector de código de barras), lo consulta en un **Tablero** ordenado por la urgencia combinada de la vigencia de la garantía y del SLA de atención, y **anota revisiones** cuyo resultado lo calcula la base y es inalterable.

**Stack:** React 19 + Vite 8 (SPA) · Supabase (Auth + Postgres 17 con RLS + RPC + 3 Edge Functions) · Resend (correo del 2FA) · Vercel (hosting, con CSP y cabeceras estrictas) · GitHub Actions (CI de migraciones, pruebas SQL, vitest, lint y build).

**Semáforo (después del hito 1):**

| Capa | Estado |
|---|---|
| Base de datos (equipos, registros, revisiones, adjuntos, vista del Tablero, permisos) | 🟢 Construida y probada: 14 scripts SQL, 237 aserciones en verde |
| Flujo "Nuevo registro" (asistente de 6 pasos con borrador y lector) | 🟢 Construido y probado (vitest + Testing Library) |
| Tablero con datos reales + Revisiones | 🟢 Conectados a `v_tablero` y RPC reales |
| Autenticación + 2FA por correo | 🟡 Funciona; pendiente dominio verificado en Resend (y pruebas del flujo completo de login) |
| Consulta pública del cliente | 🟡 RPC `consultar_registro` lista en BD; **sin pantalla** (hito 2) |
| Consulta de facturas de Ventas | ❌ Hito 2: falta decidir la fuente (CSV) |

**En una frase:** el hito 1 está completo (registrar → Tablero → revisiones); queda lo alrededor (pantalla pública, facturas de Ventas, avisos).

---

## 2. Arquitectura

```
 Navegador (SPA React, Vercel)
   │  supabase-js  (JWT en sessionStorage; localStorage solo con "Recordarme")
   ▼
 ┌──────────────────────── Supabase ────────────────────────┐
 │  Auth ........ signInWithPassword, sesiones JWT           │
 │  PostgREST ... lecturas/updates con RLS por rol           │
 │  RPC (SQL) ... registrar_ingreso · buscar_equipo ·        │
 │                guardar_cliente · registrar_revision ·     │
 │                confirmar_compra · consultar_registro ·    │
 │                calcular_cobertura · hoy_local · ajuste ·  │
 │                listar_huerfanos (service_role) ·          │
 │                generate_mfa_code · verify_mfa_code ·      │
 │                mfa_ok · mi_rol                            │
 │  Vista ....... v_tablero (urgencia combinada §4.5-4.6)    │
 │  Storage ..... bucket privado `registros`                 │
 │                (ruta registros/{registro_id}/…)           │
 │  Edge Fns .... mfa-enviar-codigo ──► Resend (correo)      │
 │                admin-crear-usuario  (service_role)        │
 │                limpiar-huerfanos    (cron diario)         │
 │  Postgres 17 . tablas + triggers + RLS + pg_cron          │
 └───────────────────────────────────────────────────────────┘
```

**Principio rector:** *la autorización vive en Postgres, no en React.* El resultado de la cobertura lo calcula la base a partir de la lista de verificación (el cliente solo pide `calcular_cobertura`); las revisiones y los adjuntos son **solo de anexar** (triggers que bloquean UPDATE/DELETE/TRUNCATE incluso para `service_role` y el dueño de la base).

### Estructura del repo (novedades del hito)

```
├─ supabase/
│  ├─ migrations/        10 SQL activos (0004 ajustes → 0012 idempotencia del ingreso)… ver §3
│  ├─ archivo/           el monolito duplicado 20260906000001 (+ su referencia)
│  ├─ functions/         admin-crear-usuario · mfa-enviar-codigo · limpiar-huerfanos
│  ├─ tests/             00 harness · 10–19 pruebas SQL del hito · 96–99 previos · run.sh (Docker)
│  └─ seed.sql           4 marcas y 8 productos
├─ scripts/
│  ├─ verificar-migraciones.sh
│  └─ e2e-registro.sh          punta a punta: registrar → tablero → revisión → inmutabilidad
├─ frontend/src/features/
│  ├─ registro/           normalizar · registroService · borrador · useAsistente ·
│  │                      NuevoRegistro + pasos (equipo/cliente/compra/verificacion/adjuntos/resumen) · enviarRegistro
│  ├─ tablero/            Tablero (datos reales) · tableroService · TablaRegistros · dominio
│  └─ revisiones/         HistorialRevisiones · RevisionForm · revisionesService
└─ .github/workflows/ci.yml
```

---

## 3. Matriz de funcionalidades

Leyenda: ✅ real y conectado · 🟡 parcial / maqueta / sin UI · ❌ no existe

### 3.1 Autenticación y acceso

| Funcionalidad | Estado | Dónde vive |
|---|---|---|
| Login email + contraseña (Supabase Auth) | ✅ | `auth/authService.js::iniciarSesion` |
| Mensaje único ante cualquier fallo (anti-enumeración) | ✅ | `authService.js` (`MENSAJE_GENERICO`) |
| Aviso específico de límite de intentos (429) | ✅ | `authService.js` |
| "Recordarme" (sessionStorage ↔ localStorage) | ✅ | `lib/supabaseClient.js::recordarSesion` |
| Perfil ausente o `is_active=false` ⇒ sesión revocada | ✅ | `authService.js::obtenerPerfil` |
| 2FA por correo: emitir código (límite 5 / 15 min) | 🟡 | Edge `mfa-enviar-codigo` + RPC `generate_mfa_code` |
| 2FA: verificar código y anclarlo a la sesión | 🟡 | RPC `verify_mfa_code`, `mfa_ok()`; `mi_rol()` exige `mfa_ok()` |
| Pantalla de código 2FA en el login | 🟡 | `auth/Login.jsx` (546 líneas) |
| Rutas protegidas por rol + `/sin-acceso` | ✅ | `RutaProtegida.jsx`, `App.jsx` |
| Redirección post-login según rol | ✅ | `authService.js::RUTA_POR_ROL` |
| Logout con revocación global | ✅ | `authService.js::cerrarSesion` |
| Alta de usuarios (solo ADMIN) | 🟡 | Edge `admin-crear-usuario` + `invitarUsuario()`; **sin pantalla** |
| Cambio de rol / baja lógica de usuario | 🟡 | `cambiarRol`, `desactivarUsuario`; **sin pantalla** |
| Recuperar contraseña ("olvidé mi contraseña") | ❌ | — |
| Cambiar contraseña propia | ❌ | — |

### 3.2 Dominio de garantías (base de datos)

| Funcionalidad | Estado | Dónde vive |
|---|---|---|
| Orden con número legible `ORD-AAAA-NNNNNN` | ✅ | Tabla `garantias` + secuencia |
| Cálculo automático de vencimiento (`fecha_compra` + `meses_garantia`) | ✅ | Trigger `calcular_vencimiento_garantia` |
| Cobertura (`POR_DETERMINAR`, `EN_GARANTIA`, `FUERA_DE_GARANTIA`, `ANULADA_POR_USO`) | ✅ | ENUM + CHECKs de coherencia |
| 10 estados y máquina de transiciones con roles permitidos | ✅ | `estados_garantia`, `transiciones_estado`, trigger `validar_transicion_estado` |
| Historial inmutable de cambios | ✅ | `historial_garantias` + trigger de solo-anexado (ni `postgres` puede editarlo) |
| Notas internas (tabla aparte, nunca se filtran al cliente) | ✅ | `notas_internas` |
| Catálogo de marcas y productos (con meses de garantía) | ✅ | `marcas`, `productos` |
| Clientes | ✅ | `clientes` |
| Crear orden de forma atómica | ✅ | RPC `crear_garantia()` (devuelve el token UNA vez) |
| Consulta pública con orden + token de 128 bits, limitada por IP | ✅ | RPC `consultar_garantia()` + `consulta_publica_intentos` |
| RLS por rol y GRANTs mínimos (sin DELETE para nadie) | ✅ | Migración `…0002_garantias.sql` §10-11 |
| Reportes ("qué modelo falla más") | ❌ | El esquema lo permite; no hay vistas ni UI |
| Adjuntos / fotos del equipo | ❌ | — |
| Notificaciones al cliente (cambio de estado) | ❌ | — |

### 3.3 Interfaz

| Pantalla | Estado | Nota |
|---|---|---|
| Login | ✅ | |
| Tablero ADMIN (tabla, filtros, búsqueda, vencimientos) | 🟢 | Datos reales de `v_tablero`; filtrado y búsqueda del lado de la base. El botón "Revisar" (rol ≠ Recepción) abre el detalle con **Revisiones** (historial + formulario, RPC `registrar_revision` reales); al guardar, el tablero se recarga |
| Panel Jefe de servicio (`/jefe`) | 🟡 | `Panel.jsx` provisional |
| Panel Técnico (`/tecnico`) | 🟡 | `Panel.jsx` provisional |
| Panel Recepción (`/recepcion`) | 🟡 | `Panel.jsx` provisional |
| Formulario "Nueva orden" (cliente + equipo + falla) | ❌ | La RPC existe |
| Detalle de orden (historial, notas, diagnóstico) | ❌ | |
| Cambio de estado / asignar técnico | ❌ | Reglas ya en BD |
| Gestión de clientes | ❌ | |
| Gestión de marcas y productos | ❌ | |
| Administración de usuarios | ❌ | Servicios listos, falta UI |
| Consulta pública para el cliente | ❌ | RPC lista; sin ruta ni pantalla |
| Comprobante imprimible (con token) | ❌ | El token se devuelve una sola vez, hay que imprimirlo |

**Permisos por rol (ya aplicados en BD):**

| Rol | Puede |
|---|---|
| ADMIN | Todo; gestiona usuarios y catálogos; anula órdenes |
| JEFE_SERVICIO | Ve todo, asigna técnicos, anula órdenes, actualiza cualquier orden |
| TECNICO | Ve todo; solo modifica órdenes **asignadas a él** y no cerradas; no puede reasignar |
| RECEPCION | Crea órdenes; solo cierra entregas (`REPARADO`/`IRREPARABLE`/`RECHAZADO` → `ENTREGADO`) |

**Flujo de estados:**
`RECIBIDO → EN_DIAGNOSTICO → (PRESUPUESTADO ⇄ EN_ESPERA_REPUESTO) → EN_REPARACION → REPARADO → ENTREGADO`; salidas laterales a `IRREPARABLE`, `RECHAZADO_POR_CLIENTE` (ambos también terminan en `ENTREGADO`) y `ANULADO` (solo ADMIN/JEFE, solo desde `RECIBIDO` o `EN_DIAGNOSTICO`).

---

## 4. Seguridad: decisiones que conviene conocer

- **El código 2FA nunca viaja al navegador.** `generate_mfa_code` devuelve solo la caducidad; el código lo lee la Edge Function con `service_role` y lo manda por Resend. Sin logs del código.
- **El 2FA está conectado a la RLS**, no a la pantalla: `mi_rol()` exige `mfa_ok()`. Saltarse la pantalla da paneles vacíos.
- **Tokens de consulta pública:** solo se guarda el SHA-256; el texto plano existe una vez (al crear la orden).
- **Roles no se aceptan del cliente:** el trigger `handle_new_user` fija `TECNICO`; el rol real lo asigna la Edge Function de ADMIN.
- **Protecciones de BD:** un ADMIN no puede cambiarse el rol a sí mismo (evita quedarse sin administradores); `REVOKE` explícito sobre `anon`/`authenticated` antes de conceder.
- **Hosting:** CSP estricta (`connect-src` limitado al proyecto Supabase), HSTS preload, `X-Frame-Options: DENY`, `Referrer-Policy: no-referrer`.
- **Riesgo aceptado y documentado:** `supabase-js` guarda el JWT en almacenamiento legible por JS; un XSS robaría la sesión. Mitigado con `sessionStorage` por defecto y la CSP.

---

## 5. Cómo correrlo

```bash
cd frontend
pnpm install
# frontend/.env.local  →  VITE_SUPABASE_URL=...  VITE_SUPABASE_ANON_KEY=...
pnpm dev          # Vite en :5173
pnpm test         # vitest (154 pruebas: services, asistente, tablero, revisiones, edge fns)
pnpm lint         # oxlint
pnpm build
```

- **Pruebas SQL (requieren Docker):** `bash supabase/tests/run.sh` — levanta Postgres 17, aplica harness + migraciones + seed y corre cada script contra una base limpia; imprime `PASA n · FALLA m` por archivo y sale 1 si algo falla. `bash scripts/e2e-registro.sh` corre la prueba de punta a punta del registro.
- **Base de datos:** la cadena canónica es `0001_auth_base` → `0002_garantias` → `0003_mfa_email` → `0004`…`0012` (hito 1: ajustes/cobertura, equipos, registros, revisiones, adjuntos, RPC y vista, huérfanos, idempotencia del ingreso). El monolito duplicado quedó archivado en `supabase/archivo/` (verificar en el SQL Editor del proyecto real: `select version from supabase_migrations.schema_migrations order by 1` debe listar exactamente esas 12 versiones). `bash scripts/verificar-migraciones.sh` lo chequea (está en CI).
- **Edge Functions:** `supabase functions deploy mfa-enviar-codigo`, `admin-crear-usuario` y `limpiar-huerfanos`. Secretos: `RESEND_API_KEY`, `ORIGENES_PERMITIDOS`, y para la limpieza `LIMPIEZA_SECRET` + `ALTER DATABASE postgres SET app.limpieza_secret` y `app.proyecto_ref` (ver migración 0011).
- **Correo:** Resend está en **sandbox** (`onboarding@resend.dev`): solo entrega al correo dueño de la cuenta de Resend. Para otros usuarios hace falta un dominio verificado (SPF/DKIM/DMARC) y cambiar el `from`.

---

## 6. Deuda técnica y riesgos

| # | Gravedad | Problema | Detalle / ruta |
|---|---|---|---|
| ~~D1~~ | ✅ Resuelta (hito 1) | Duplicado `20260906000001` y copia `_referencia_…` | Archivados en `supabase/archivo/` y protegidos por `verificar-migraciones.sh` (CI). Falta SOLO confirmar el historial remoto en el SQL Editor (ver §5) |
| ~~D5~~ | ✅ Resuelta (hito 1) | Seed inexistente | `supabase/seed.sql` con 4 marcas y 8 productos; `run.sh` la valida |
| ~~D6~~ | ✅ Resuelta (hito 1) | Sin README/CI/tests | README raíz, CI y 237 aserciones SQL + 154 de frontend |
| D4 | 🟠 Media | 2FA sin cerrar: pruebas del inicio de sesión pendientes (palabras del commit `b81e632`) | Probar: código correcto, vencido, reuso, 6.º código en 15 min, refresco de página a mitad del flujo, logout |
| D7 | 🟡 Baja | Comentarios de código mencionan archivos ya inexistentes (`authApi.js`, `src/api/client.js`) | Solo ruido; limpiar al tocar esos archivos |
| D8 | 🟡 Baja | Mensaje de error del cliente Supabase dice `npm run dev`, el proyecto usa pnpm | `supabaseClient.js` |
| D9 | 🟡 Baja | `Tablero.jsx` (≈240 líneas con datos) y `Login.jsx` grandes | Dividir si crecen al conectar Revisiones en detalle |
| D10 | 🟠 Media | Historial de migraciones REMOTO sin verificar (sin acceso de red desde el entorno de pruebas) | Confirmar en el SQL Editor antes del primer `db push` (ver §5) |

---

## 7. Qué falta desarrollar (hitо 2 y siguientes)

El hito 1 quedó completo: registrar → Tablero → revisiones, con CI. Lo siguiente, priorizado:

### Pendiente del hito 1 (cierre)

| # | Tarea | Terminado cuando |
|---|---|---|
| C1 | Confirmar el historial de migraciones remoto (no hay acceso de red aquí) | Ver §5 · SQL Editor; de paso definir `app.proyecto_ref`/`app.limpieza_secret` y desplegar las 3 Edge Functions reales |
| C2 | Probar `limpiar-huerfanos` con `?simular=1` contra el proyecto real | La simulación lista sin borrar; luego el modo real |

### Hitо 2 — alrededor del registro

| # | Tarea | Notas |
|---|---|---|
| H2-1 | **Pantalla pública del cliente** (`/consulta`) | Formulario número + token → `consultar_registro()`; mensajes genéricos; respetar el freno por IP |
| H2-2 | **Consulta de facturas de Ventas** | Fuente por CSV desde Ventas; conector: usará `confirmar_compra` (quién y cuándo ya se guarda) |
| H2-3 | **Detalle del registro en una ruta propia** (`/registro/:id`) | Historial de estados, notas internas, adjuntos y revisiones en una sola pantalla; botón Revisar del Tablero |
| H2-4 | **Cambio de estado y asignación de técnico** | La UI ofrece solo transiciones válidas según `transiciones_estado` y el rol |
| H2-5 | **Avisos de vencimiento** (a correo) | Umbrales ya están en `ajustes` |
| H2-6 | **Administración de usuarios** (ADMIN) | Listar, invitar, cambiar rol, desactivar (servicios listos, falta UI) |
| H2-7 | **Gestión de clientes y catálogo** | marcas/productos (meses de garantía) |
| H2-8 | **Reportes** | modelos con más fallas, tiempo medio por estado |
| H2-9 | **Carga masiva por CSV** de registros antiguos | Necesita `registrar_ingreso` con `p_fecha_ingreso` (ya existe) |

---

## 8. Guía rápida para agentes de IA

- **Idioma:** todo en español (respuestas, comentarios, nombres de dominio como `garantias`, `tablero`, `RutaProtegida`).
- **Dónde poner código nuevo:** `frontend/src/features/<modulo>/`. Componentes reciben datos **por props**; el acceso a datos va en hooks o en un `*Service.js` por módulo (patrón de `authService.js`: ningún componente llama a `supabase.*` directamente).
- **Fuente de verdad del dominio:** las migraciones SQL. `tablero/dominio.js` es un *espejo* (estados, coberturas, tonos CSS); si cambian los estados, cambiar ambos.
- **Reglas de negocio** van en Postgres (CHECKs, triggers, RLS), no en React. La UI puede *anticipar* reglas para no ofrecer acciones inválidas, pero nunca es la única barrera.
- **No hacer:** `signUp()` desde el navegador (usar la Edge Function) · devolver el código 2FA al cliente · guardar el token de consulta en claro · añadir `DELETE` (las órdenes se anulan) · distinguir "correo inexistente" de "contraseña mala" en mensajes · exponer `notas_internas` en consultas públicas.
- **Antes de tocar la BD:** leer los comentarios `HALLAZGO CORREGIDO` de las migraciones; documentan por qué cada decisión es como es.
- **Orden recomendado para empezar:** P0-1 → P1-1 → P1-2 → P1-5.
