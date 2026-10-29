# Track Garantía — Estado del proyecto

**Prime Telecom · Sistema de seguimiento de garantías y reparaciones**
**Corte:** 2026-10-29 (rama `main`, último commit `5ee42c6`)

> Documento pensado para dos usos: **presentar** el sistema y **dar contexto rápido a agentes de IA** para planificar. Describe lo que hay *hoy* en el repo, no lo que se pretendía. Donde un documento antiguo contradiga a este, manda este (ver §6).

---

## 1. Resumen en 30 segundos

Aplicación web para un taller de servicio técnico: recepciona equipos con garantía, calcula si siguen cubiertos, los hace pasar por un flujo de estados (diagnóstico → reparación → entrega) y deja trazabilidad completa. Hay 4 roles internos y, en el diseño, una consulta pública para el cliente.

**Stack:** React 19 + Vite 8 (SPA) · Supabase (Auth + Postgres 17 con RLS + RPC + 2 Edge Functions) · Resend (correo del 2FA) · Vercel (hosting, con CSP y cabeceras estrictas).

**Semáforo:**

| Capa | Estado |
|---|---|
| Base de datos (esquema, reglas, RLS, permisos) | 🟢 Sólida y probada con 5 scripts SQL |
| Autenticación + 2FA por correo | 🟡 Funciona; el propio commit dice "falta seguir haciendo pruebas" |
| Interfaz de negocio (órdenes, clientes, productos) | 🔴 Casi toda por hacer: el Tablero es maqueta con datos inventados |
| Consulta pública del cliente | 🟡 Existe la función en BD; **no hay pantalla** |
| Calidad / operación (tests front, CI, README, seed) | 🔴 No existe |

**En una frase:** el *cimiento* (datos, seguridad, login) está bien construido; lo que falta es **conectar la interfaz a ese cimiento**.

---

## 2. Arquitectura

```
 Navegador (SPA React, Vercel)
   │  supabase-js  (JWT en sessionStorage; localStorage solo con "Recordarme")
   ▼
 ┌──────────────────────── Supabase ────────────────────────┐
 │  Auth ........ signInWithPassword, sesiones JWT           │
 │  PostgREST ... lecturas/updates con RLS por rol           │
 │  RPC (SQL) ... crear_garantia · consultar_garantia ·      │
 │                generate_mfa_code · verify_mfa_code ·      │
 │                mfa_ok · mi_rol                            │
 │  Edge Fns .... mfa-enviar-codigo ──► Resend (correo)      │
 │                admin-crear-usuario  (service_role)        │
 │  Postgres 17 . tablas + triggers + RLS + pg_cron          │
 └───────────────────────────────────────────────────────────┘
```

**Principio rector:** *la autorización vive en Postgres, no en React.* El rol en el frontend solo decide qué se pinta; cada consulta pasa por RLS leyendo el JWT. Un usuario que manipule el estado de React ve paneles vacíos, no datos ajenos.

### Estructura del repo

```
track garantia/
├─ frontend/                    SPA (pnpm 10, Node ≥ 22.12)
│  ├─ src/
│  │  ├─ main.jsx, App.jsx      Rutas por rol
│  │  ├─ lib/supabaseClient.js  Cliente único (PKCE, storage configurable)
│  │  └─ features/
│  │     ├─ auth/               AuthContext, authService, Login, LoginPage, RutaProtegida
│  │     ├─ tablero/            Tablero (ADMIN) + componentes + dominio.js + datosDemo.js
│  │     └─ paneles/            Panel.jsx  ← placeholder para los otros 3 roles
│  ├─ vercel.json               CSP, HSTS, rewrites SPA
│  └─ .env.local                VITE_SUPABASE_URL, VITE_SUPABASE_ANON_KEY (no versionado)
├─ supabase/
│  ├─ migrations/               4 SQL activos + 1 de referencia (ver §6 · D1)
│  ├─ functions/                admin-crear-usuario, mfa-enviar-codigo
│  ├─ tests/                    00 harness · 96 MFA · 97 rechazos · 98 auth base · 99 seguridad
│  └─ config.toml
├─ scripts/setup-supabase-mfa.sh  Asistente interactivo: secretos de Resend y CORS
└─ ESTADO_DEL_PROYECTO.md       Este documento
```

> Los restos del backend Flask (blueprint, auditoría, specs y `Claude outputs/`) se eliminaron del árbol; siguen en el historial de git (último commit que los contiene: `5ee42c6`).

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
| Tablero ADMIN (KPIs, tabla, vencimientos, filtros, búsqueda) | 🟡 | **Todo sale de `datosDemo.js`.** El filtrado y la búsqueda son en memoria. 3 botones sin acción (`avisar(...)`) |
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
pnpm lint         # oxlint
pnpm build
```

- **Base de datos:** aplicar las migraciones **en este orden** (ver §6 · D1 antes de hacerlo): `auth_base` → `garantias` → `mfa_email`.
- **Edge Functions:** `supabase functions deploy mfa-enviar-codigo` y `admin-crear-usuario`. Secretos necesarios: `RESEND_API_KEY`, `ORIGENES_PERMITIDOS` (CORS). `scripts/setup-supabase-mfa.sh` los configura de forma guiada.
- **Pruebas SQL:** `supabase/tests/*.sql` (harness en `00_…`); se ejecutan a mano contra una base de pruebas.
- **Correo:** Resend está en **sandbox** (`onboarding@resend.dev`): solo entrega al correo dueño de la cuenta de Resend. Para otros usuarios hace falta un dominio verificado (SPF/DKIM/DMARC) y cambiar el `from`.

---

## 6. Deuda técnica y riesgos

| # | Gravedad | Problema | Detalle / ruta |
|---|---|---|---|
| D1 | 🔴 Alta | **Dos migraciones con el mismo timestamp** `20260906000001` (`auth_base` y `esquema_inicial`), más un `_referencia_…` que difiere de `esquema_inicial` | `supabase/migrations/`. `esquema_inicial` parece el monolito original del que se extrajo `auth_base` + `garantias`; aplicarlo junto a las otras duplicaría tipos/tablas. Decidir cuál es canónica y archivar el resto |
| ~~D2~~ | ✅ Resuelta | Documentación del backend Flask obsoleta | Eliminada (blueprint, auditoría fase 11, specs). Recuperable desde git |
| ~~D3~~ | ✅ Resuelta | `Claude outputs/` versionado con zips y código Python | Eliminada. Pendiente menor: `.gitignore` aún lista reglas de Python/`claude outputs/` que ya no aplican |
| D4 | 🟠 Media | 2FA sin cerrar: pruebas del inicio de sesión pendientes (palabras del commit `b81e632`) | Probar: código correcto, vencido, reuso, 6.º código en 15 min, refresco de página a mitad del flujo, logout |
| D5 | 🟠 Media | `config.toml` activa el seed (`./seed.sql`) pero **ese archivo no existe** | No hay datos iniciales: estados sí (van en la migración), pero no marcas/productos ni un primer ADMIN reproducible |
| D6 | 🟡 Baja | Sin README raíz (2 bytes) ni CI ni tests de frontend | Un agente nuevo no tiene punto de entrada |
| D7 | 🟡 Baja | Comentarios de código mencionan archivos ya inexistentes (`authApi.js`, `src/api/client.js`) | Solo ruido; limpiar al tocar esos archivos |
| D8 | 🟡 Baja | Mensaje de error del cliente Supabase dice `npm run dev`, el proyecto usa pnpm | `supabaseClient.js` |
| D9 | 🟡 Baja | `Tablero.jsx` y `Login.jsx` son grandes (259 y 546 líneas) | Dividir cuando se conecten datos |

---

## 7. Qué falta desarrollar (priorizado)

Cada ítem lleva su criterio de "terminado". El orden busca **tener el primer flujo real de punta a punta lo antes posible**: *recepción crea una orden → aparece en el tablero → un técnico la mueve de estado*.

### P0 — Ordenar la casa (≈ 1 día)

| # | Tarea | Terminado cuando |
|---|---|---|
| P0-1 | Resolver D1: dejar **una** cadena de migraciones canónica y aplicarla desde cero en una base limpia | `supabase db reset` corre sin errores y los 5 scripts de `tests/` pasan |
| P0-2 | Cerrar pruebas del 2FA (D4) | Lista de casos de D4 verificada, ya sea manual o como script SQL nuevo |
| P0-3 | Crear `supabase/seed.sql`: marcas, productos de ejemplo y un ADMIN reproducible (D5) | Una base nueva queda usable tras el reset |
| ~~P0-4~~ | ✅ Hecho: docs obsoletas y `Claude outputs/` eliminados | — |
| P0-5 | README raíz mínimo (qué es, cómo correr, enlace a este documento) | Un recién llegado levanta el proyecto leyéndolo |

### P1 — El primer flujo real (≈ 1–2 semanas)

| # | Tarea | Notas / terminado cuando |
|---|---|---|
| P1-1 | **Conectar el Tablero a datos reales** | Hooks `useOrdenes()`, `useKpis()`, `usePorVencer()` reemplazan `datosDemo.js`; filtros y búsqueda pasan a la consulta (los índices parciales de §8 de la migración ya están pensados para esto). Los componentes hijos no cambian: ya reciben props |
| P1-2 | **Formulario "Nueva orden"** (RECEPCION/JEFE/ADMIN) | Busca o crea cliente, elige marca→producto, fecha de compra, falla; llama a `crear_garantia()` |
| P1-3 | **Comprobante imprimible** con número de orden y token | El token se muestra una vez; hay botón de imprimir. Si se pierde, no se recupera (decidir política: ¿regenerar token?) |
| P1-4 | **Detalle de orden** | Datos, cobertura, historial, notas internas (leer/agregar) |
| P1-5 | **Cambio de estado y asignación de técnico** | La UI solo ofrece transiciones válidas según `transiciones_estado` y el rol; los errores del trigger se muestran legibles |
| P1-6 | **Panel Técnico** | Lista "mis órdenes" (índice `idx_gar_abiertas_por_tecnico`), acción de avanzar estado y anotar diagnóstico |
| P1-7 | **Panel Recepción** | Nueva orden + entregas pendientes (REPARADO/IRREPARABLE/RECHAZADO) |
| P1-8 | **Panel Jefe** | Órdenes sin asignar (índice `idx_gar_sin_asignar`), asignar, anular |

### P2 — Completar el producto

| # | Tarea | Notas |
|---|---|---|
| P2-1 | **Consulta pública del cliente** (`/consulta`) | Ruta sin login; formulario orden + token → `consultar_garantia()`; mensajes genéricos ante fallo; manejar el límite por IP |
| P2-2 | **Administración de usuarios** (ADMIN) | Listar, invitar (`invitarUsuario`), cambiar rol, desactivar |
| P2-3 | **Gestión de clientes y catálogo** (marcas/productos, meses de garantía) | |
| P2-4 | **Recuperar / cambiar contraseña** | Hoy no existe; con 4 usuarios lo resuelve ADMIN a mano, no vale como estado final |
| P2-5 | **Dominio propio verificado en Resend** | Sin esto el 2FA solo llega a una dirección |
| P2-6 | **Tests de frontend** (Vitest + Testing Library) para `authService`, `RutaProtegida`, `dominio.js` | |
| P2-7 | **CI** (lint + build + tests) en GitHub Actions | |
| P2-8 | **Reportes**: modelos con más fallas, tiempo medio por estado, garantías por vencer | El esquema normalizado ya lo permite |

### P3 — Ideas a considerar (no comprometidas)

Fotos del equipo al recibir · aviso al cliente por correo/WhatsApp al cambiar de estado · exportar a CSV/PDF · TOTP para ADMIN/JEFE como alternativa al correo.

---

## 8. Guía rápida para agentes de IA

- **Idioma:** todo en español (respuestas, comentarios, nombres de dominio como `garantias`, `tablero`, `RutaProtegida`).
- **Dónde poner código nuevo:** `frontend/src/features/<modulo>/`. Componentes reciben datos **por props**; el acceso a datos va en hooks o en un `*Service.js` por módulo (patrón de `authService.js`: ningún componente llama a `supabase.*` directamente).
- **Fuente de verdad del dominio:** las migraciones SQL. `tablero/dominio.js` es un *espejo* (estados, coberturas, tonos CSS); si cambian los estados, cambiar ambos.
- **Reglas de negocio** van en Postgres (CHECKs, triggers, RLS), no en React. La UI puede *anticipar* reglas para no ofrecer acciones inválidas, pero nunca es la única barrera.
- **No hacer:** `signUp()` desde el navegador (usar la Edge Function) · devolver el código 2FA al cliente · guardar el token de consulta en claro · añadir `DELETE` (las órdenes se anulan) · distinguir "correo inexistente" de "contraseña mala" en mensajes · exponer `notas_internas` en consultas públicas.
- **Antes de tocar la BD:** leer los comentarios `HALLAZGO CORREGIDO` de las migraciones; documentan por qué cada decisión es como es.
- **Orden recomendado para empezar:** P0-1 → P1-1 → P1-2 → P1-5.
