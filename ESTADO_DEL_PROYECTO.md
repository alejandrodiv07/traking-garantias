# Track Garantía — Estado del proyecto

**Prime Telecom · Sistema de seguimiento de garantías y reparaciones**
**Corte:** 2026-10-30 · **Rama:** `feat/fase-2a` (fase 2a: garantía, consulta y taller; sobre el hito 1, PR #1) · último commit: ver `git log -1`

> Documento pensado para dos usos: **presentar** el sistema y **dar contexto rápido a agentes de IA** para planificar. Describe lo que hay *ahora* en el repo. Donde un documento antiguo contradiga a este, manda este (ver §6).

---

## 1. Resumen en 30 segundos

Aplicación web para un taller de servicio técnico, en tres módulos unidos por el serial: **Registrar garantía** (post-venta), **Consulta** (búsqueda por serial, cédula/RIF, factura u orden, con vigencia y días restantes) y **Taller** (orden `OS-AAAA-NNNN` con auditoría de recepción, diagnóstico y presupuesto, bitácora y estados hasta la entrega o el rechazo con motivo). La cobertura y las reglas de avance las calcula y las impone la base; las revisiones y los adjuntos son inalterables.

**Stack:** React 19 + Vite 8 (SPA) · Supabase (Auth + Postgres 17 con RLS + RPC + 3 Edge Functions) · Resend (correo del 2FA) · Vercel (hosting, con CSP y cabeceras estrictas) · GitHub Actions (CI de migraciones, pruebas SQL, vitest, lint y build).

**Semáforo (fase 2a):**

| Capa | Estado |
|---|---|
| Base de datos (garantías, órdenes, revisiones, adjuntos, reglas de avance, permisos) | 🟢 Construida y probada: 23 scripts SQL, 436 aserciones en verde; e2e de 12 comprobaciones |
| Registrar garantía, Consulta, Abrir orden, Detalle de la orden, lista del Taller y tablero de garantías | 🟢 Construidos y probados (312 pruebas de vitest), conectados a las RPC reales |
| Layout con barra lateral y rutas `/garantias` y `/taller` | 🟢 |
| Autenticación + 2FA por correo | 🟡 Funciona; pendiente dominio verificado en Resend (la función desplegada sigue con destinatario fijo) |
| Entregas, Inventario, Reportes, Clientes y Notificaciones (pantallas 05 a 08 del diseño) | ❌ Con maqueta en `docs/diseno-ui/`, sin backend (ver su README §4) |
| Consulta pública del cliente y alertas de vencimiento | ❌ Fase 2c: la RPC `consultar_registro` existe, sin pantalla |
| Facturas de Ventas por CSV | ❌ Fase 2b |

**En una frase:** la fase 2a está completa de punta a punta (registrar la garantía → consultarla → abrir la orden → diagnosticar, presupuestar, rechazar o entregar); falta desplegarla y todo lo que rodea al taller.

---

## 2. Arquitectura

```
 Navegador (SPA React, Vercel)
   │  supabase-js  (JWT en sessionStorage; localStorage solo con "Recordarme")
   ▼
 ┌──────────────────────── Supabase ────────────────────────┐
 │  Auth ........ signInWithPassword, sesiones JWT           │
 │  PostgREST ... lecturas/updates con RLS por rol           │
 │  RPC (SQL) ... registrar_garantia · buscar_equipo ·       │
 │                abrir_orden · registrar_revision ·         │
 │                confirmar_compra · desestimar_compra ·     │
 │                cambiar_estado · asignar_tecnico ·         │
 │                registrar_presupuesto · guardar_cliente ·  │
 │                consultar_registro · calcular_cobertura ·  │
 │                hoy_local · listar_huerfanos (service_role)│
 │                generate_mfa_code · verify_mfa_code ·      │
 │                mfa_ok · mi_rol                            │
 │  Vistas ...... v_tablero (urgencia §4.5-4.6) · v_garantias│
 │  Storage ..... bucket privado `ordenes`                   │
 │                (ruta ordenes/{orden_id}/…)                │
 │  Edge Fns .... mfa-enviar-codigo ──► Resend (correo)      │
 │                admin-crear-usuario  (service_role)        │
 │                limpiar-huerfanos    (cron diario)         │
 │  Postgres 17 . tablas + triggers + RLS + pg_cron          │
 └───────────────────────────────────────────────────────────┘
```

**Principio rector:** *la autorización vive en Postgres, no en React.* El resultado de la cobertura lo calcula la base a partir de la lista de verificación (el cliente solo pide `calcular_cobertura`); las revisiones y los adjuntos son **solo de anexar** (triggers que bloquean UPDATE/DELETE/TRUNCATE incluso para `service_role` y el dueño de la base).

### Estructura del repo (novedades de la fase 2a)

```
├─ supabase/
│  ├─ migrations/        22 SQL activos (0013 a 0022 son de la fase 2a)
│  ├─ archivo/           el monolito duplicado 20260906000001 (+ su referencia)
│  ├─ functions/         admin-crear-usuario · mfa-enviar-codigo · limpiar-huerfanos
│  ├─ tests/             00 harness · 10–28 pruebas SQL · 96–99 previos · apoyo_pruebas.sql · run.sh (Docker)
│  └─ seed.sql           4 marcas y 8 productos
├─ scripts/
│  ├─ verificar-migraciones.sh
│  └─ e2e-registro.sh          garantía → consulta → orden → mal uso → rechazo con motivo → entrega
├─ docs/diseno-ui/             8 maquetas HTML (01–04 conectadas; 05–08 pendientes de backend)
├─ frontend/src/features/
│  ├─ layout/             Layout con barra lateral (NavLink)
│  ├─ garantias/          Garantias (tablero) · NuevaGarantia · Consulta · garantiasService
│  ├─ taller/             Taller (lista) · AbrirOrden · OrdenDetalle · BarraEstados · tallerService · borrador (24 h, módulo 'orden')
│  ├─ registro/           pasos reutilizados (cliente, compra, verificación, adjuntos) · normalizar
│  ├─ tablero/            dominio (espejo de estados) · Tablero y paneles del hito 1
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

### 3.2 Dominio (base de datos)

| Funcionalidad | Estado | Dónde vive |
|---|---|---|
| Garantía = fila de `equipos` (serial, titular, factura, plazo, vencimiento) con origen `VENTA` o `TALLER` | ✅ | `registrar_garantia` |
| Plazo de 7 o 15 días; otro valor (1–365) solo ADMIN/JEFE_SERVICIO | ✅ | `registrar_garantia` (42501) |
| Búsqueda por serial, cédula/RIF, factura u orden, con vigencia y estado de la compra | ✅ | `buscar_equipo`, vista `v_garantias` |
| Cobertura con precedencia única (desestimada → sin factura → taller sin confirmar → vencida → mal uso → condición) | ✅ | `calcular_cobertura` |
| Tipo de atención `GARANTIA`/`PAGO`/`PENDIENTE` (columna generada) | ✅ | `ordenes_servicio.tipo_atencion` |
| Confirmar o desestimar la compra (motivo ≥ 10); recalcula las órdenes abiertas | ✅ | `confirmar_compra`, `desestimar_compra` |
| Orden `OS-AAAA-NNNN` + auditoría de recepción en una transacción, idempotente por clave de envío | ✅ | `abrir_orden` |
| 11 estados con `RECHAZADO` (motivo obligatorio, salida única a `ENTREGADO`) y roles cerrados | ✅ | `transiciones_estado`, trigger de validación |
| Reglas de avance: foto, documento (equipo de taller sin confirmar), monto, pago por presupuesto | ✅ | trigger `validar_avance_orden` |
| Cambio de estado, asignación de técnico y presupuesto solo por RPC (UPDATE directo cerrado) | ✅ | `cambiar_estado`, `asignar_tecnico`, `registrar_presupuesto` |
| Bitácora de estados y de eventos (cobertura, presupuesto, técnico) inmutable | ✅ | `historial_ordenes` |
| Revisiones y adjuntos solo de anexar (ni `service_role`) | ✅ | triggers del hito 1 |
| Consulta pública con orden + token de 128 bits, limitada por IP | 🟡 | RPC `consultar_registro`; sin pantalla (2c) |
| Reportes, entregas con datos, stock de inventario, avisos al cliente | ❌ | Ver `docs/diseno-ui/README.md` §4 |

### 3.3 Interfaz

| Pantalla | Ruta | Estado | Nota |
|---|---|---|---|
| Login | `/login` | ✅ | |
| Tablero de garantías | `/garantias` | ✅ | Sobre `v_garantias`: chips Vigente / Por vencer / Vencida / Por confirmar, búsqueda |
| Registrar garantía | `/garantias/nueva` | ✅ | Asistente de 3 pasos (cliente, equipo, compra); sin borrador ni checklist — recorte documentado en la fase 2a |
| Consulta | `/garantias/consulta` | ✅ | Cuatro criterios, cobertura con color, historial de órdenes, aviso previo y "Registrar ahora"; Confirmar/Desestimar compra solo para jefatura |
| Lista del Taller | `/taller` | ✅ | Filtro por estado |
| Abrir orden | `/taller/nueva?equipo=…` | ✅ | Falla, accesorios, auditoría de recepción, fotos y documentos; borrador de 24 h (módulo 'orden') con restauración ofrecida: la clave de envío se reutiliza, el éxito total lo limpia |
| Detalle de la orden | `/taller/:id` | ✅ | Barra de estados y cinco pestañas; acciones por rol vía RPC (avanzar filtrado por la matriz, rechazar con motivo, asignar técnico, presupuesto solo en PAGO), revisión técnica, diagnóstico por UPDATE directo de la columna abierta y notas internas |
| Tablero y paneles del hito 1 (`/tablero`, `/jefe`, …) | — | 🟡 | Siguen montados; el aterrizaje tras iniciar sesión es `/garantias` |
| Entregas, Inventario, Reportes, Clientes, Notificaciones | — | ❌ | Maquetas 05–08 listas; falta backend y la pantalla de Notificaciones |
| Administración de usuarios | — | ❌ | Servicios listos, falta UI |

**Permisos por rol (ya aplicados en BD):**

| Rol | Puede |
|---|---|
| ADMIN | Todo; gestiona usuarios y catálogos; anula órdenes |
| JEFE_SERVICIO | Ve todo, asigna técnicos, rechaza y anula órdenes, confirma o desestima compras, fija plazos distintos de 7 o 15 días |
| TECNICO | Ve todo; registra garantías y abre órdenes; solo avanza y presupuesta las órdenes **asignadas a él**; no rechaza ni reasigna |
| RECEPCION | Registra garantías y abre órdenes; registra la decisión del cliente sobre el presupuesto; cierra entregas (`REPARADO`/`IRREPARABLE`/`RECHAZADO_POR_CLIENTE`/`RECHAZADO` → `ENTREGADO`) |

**Flujo de estados:**
`RECIBIDO → EN_DIAGNOSTICO → (PRESUPUESTADO ⇄ EN_ESPERA_REPUESTO) → EN_REPARACION → REPARADO → ENTREGADO`; en un servicio de pago el camino pasa por `PRESUPUESTADO`; con cobertura `PENDIENTE` no se avanza a reparar. Salidas laterales a `IRREPARABLE`, `RECHAZADO_POR_CLIENTE` y `RECHAZADO` (este solo ADMIN/JEFE, con motivo; los tres terminan en `ENTREGADO`) y `ANULADO` (solo ADMIN/JEFE, solo desde `RECIBIDO` o `EN_DIAGNOSTICO`).

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
pnpm test         # vitest (312 pruebas)
pnpm lint         # oxlint
pnpm build
```

- **Pruebas SQL (requieren Docker):** `bash supabase/tests/run.sh` — levanta Postgres 17, aplica harness + migraciones + seed y corre cada script contra una base limpia; imprime `PASA n · FALLA m` por archivo y sale 1 si algo falla. `bash scripts/e2e-registro.sh` corre el flujo de la fase 2a de punta a punta. Cada archivo SQL usa una base nueva; con poca memoria se puede correr por tandas pasando los archivos como argumentos.
- **Base de datos:** la cadena canónica es `0001_auth_base` → `0002_garantias` → `0003_mfa_email` → `0004`…`0012` (hito 1) → `0013`…`0022` (fase 2a: renombrado a órdenes, origen y desestimación, tipo de atención, `RECHAZADO`, reglas de avance, RPC de garantía, de orden y de la máquina de estados). El monolito duplicado quedó archivado en `supabase/archivo/` (verificar en el SQL Editor del proyecto real: `select version from supabase_migrations.schema_migrations order by 1`). `bash scripts/verificar-migraciones.sh` lo chequea (está en CI).
- **Aviso de despliegue de la 0013:** incluye un repaso idempotente de adjuntos (DEFAULT de `subido_por` y la política de INSERT) por si el remoto aplicó la `0008` original. Renombra el bucket a `ordenes`; los datos existentes son de prueba y no se conservan.
- **Edge Functions:** `supabase functions deploy mfa-enviar-codigo`, `admin-crear-usuario` y `limpiar-huerfanos`. Secretos: `RESEND_API_KEY`, `ORIGENES_PERMITIDOS`, y para la limpieza `LIMPIEZA_SECRET` + `ALTER DATABASE postgres SET app.limpieza_secret` y `app.proyecto_ref` (ver migración 0011).
- **Correo:** Resend está en **sandbox** (`onboarding@resend.dev`): solo entrega al correo dueño de la cuenta de Resend. Para otros usuarios hace falta un dominio verificado (SPF/DKIM/DMARC) y cambiar el `from`.

---

## 6. Deuda técnica y riesgos

| # | Gravedad | Problema | Detalle / ruta |
|---|---|---|---|
| ~~D1~~ | ✅ Resuelta (hito 1) | Duplicado `20260906000001` y copia `_referencia_…` | Archivados en `supabase/archivo/` y protegidos por `verificar-migraciones.sh` (CI). Falta SOLO confirmar el historial remoto en el SQL Editor (ver §5) |
| ~~D5~~ | ✅ Resuelta (hito 1) | Seed inexistente | `supabase/seed.sql` con 4 marcas y 8 productos; `run.sh` la valida |
| ~~D6~~ | ✅ Resuelta (hito 1) | Sin README/CI/tests | README raíz, CI, 436 aserciones SQL + 312 pruebas de frontend |
| D11 | 🟠 Media | `mfa-enviar-codigo` DESPLEGADA sigue con destinatario fijo (hotfix del sandbox de Resend); el código del repo ya envía al correo del usuario | Verificar el dominio en Resend y redesplegar; hasta entonces no redesplegar la función |
| D12 | 🟡 Baja | Tablero y paneles del hito 1 (`/tablero`, `/jefe`, `/tecnico`, `/recepcion`) siguen montados junto a la app nueva | Retirarlos cuando se acepte la navegación de la fase 2a |
| D13 | 🟡 Baja | La suite SQL completa necesita memoria (un contenedor por corrida) | Correr por tandas; limpiar contenedores `postgres:17` huérfanos |
| D4 | 🟠 Media | 2FA sin cerrar: pruebas del inicio de sesión pendientes (palabras del commit `b81e632`) | Probar: código correcto, vencido, reuso, 6.º código en 15 min, refresco de página a mitad del flujo, logout |
| D7 | 🟡 Baja | Comentarios de código mencionan archivos ya inexistentes (`authApi.js`, `src/api/client.js`) | Solo ruido; limpiar al tocar esos archivos |
| D8 | 🟡 Baja | Mensaje de error del cliente Supabase dice `npm run dev`, el proyecto usa pnpm | `supabaseClient.js` |
| D9 | 🟡 Baja | `Tablero.jsx` (≈240 líneas con datos) y `Login.jsx` grandes | Dividir si crecen al conectar Revisiones en detalle |
| D10 | 🟠 Media | Historial de migraciones REMOTO sin verificar (sin acceso de red desde el entorno de pruebas) | Confirmar en el SQL Editor antes del primer `db push` (ver §5) |

---

## 7. Qué falta desarrollar

La fase 2a está completa. Lo siguiente, priorizado:

### Antes de desplegar

| # | Tarea | Terminado cuando |
|---|---|---|
| C1 | Confirmar el historial de migraciones remoto y aplicar la 0013–0022 | `schema_migrations` lista las 22 versiones; el aviso de despliegue de §5 revisado |
| C2 | Definir `app.proyecto_ref`/`app.limpieza_secret` y desplegar las 3 Edge Functions reales; probar `limpiar-huerfanos` con `?simular=1` | La simulación lista sin borrar |
| C3 | Verificar el dominio en Resend y redesplegar `mfa-enviar-codigo` (D11) | Un usuario distinto del dueño de la cuenta recibe el código |

### Fases siguientes

| # | Tarea | Notas |
|---|---|---|
| 2b | Facturas de Ventas por CSV | La confirmación de una garantía `TALLER` pasaría a ser automática cuando la factura coincida |
| 2c | Enlace público de seguimiento y alertas de vencimiento por correo | Necesita el dominio de Resend; pantalla de Notificaciones aún sin diseñar |
| E | Entregas con datos (quién retira, cobro, plazo previsto) | Maqueta 05; faltan columnas y RPC |
| I | Inventario (stock, mínimos, movimientos, repuestos) | Maqueta 06; fuente probable: `Catalogo-actualizado-Prime.pdf`, sin revisar |
| R | Reportes y expedientes (PDF/Excel) | Maqueta 07 |
| K | Clientes y avisos | Maqueta 08; necesita registro de avisos y envío de correos |
| A | Administración de usuarios (ADMIN) | Servicios listos, falta UI |

## 8. Guía rápida para agentes de IA

- **Idioma:** todo en español (respuestas, comentarios, nombres de dominio como `garantias`, `tablero`, `RutaProtegida`).
- **Dónde poner código nuevo:** `frontend/src/features/<modulo>/`. Componentes reciben datos **por props**; el acceso a datos va en hooks o en un `*Service.js` por módulo (patrón de `authService.js`: ningún componente llama a `supabase.*` directamente).
- **Fuente de verdad del dominio:** las migraciones SQL. `tablero/dominio.js` es un *espejo* (estados, coberturas, tonos CSS); si cambian los estados, cambiar ambos.
- **Reglas de negocio** van en Postgres (CHECKs, triggers, RLS), no en React. La UI puede *anticipar* reglas para no ofrecer acciones inválidas, pero nunca es la única barrera.
- **No hacer:** `signUp()` desde el navegador (usar la Edge Function) · devolver el código 2FA al cliente · guardar el token de consulta en claro · añadir `DELETE` (las órdenes se anulan) · distinguir "correo inexistente" de "contraseña mala" en mensajes · exponer `notas_internas` en consultas públicas.
- **Antes de tocar la BD:** leer los comentarios `HALLAZGO CORREGIDO` de las migraciones; documentan por qué cada decisión es como es.
- **Orden recomendado para empezar:** C1 → C2 → C3 (despliegue) y luego la fase 2b o la que se priorice.
- **Cambios de estado, presupuesto y asignación:** solo por `cambiar_estado`, `registrar_presupuesto` y `asignar_tecnico`; el UPDATE directo de `estado`, `costo_reparacion` y `tecnico_asignado_id` está denegado.
