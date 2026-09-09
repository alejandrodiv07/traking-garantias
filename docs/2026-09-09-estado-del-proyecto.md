# Track Garantías — Estado del proyecto

**Fecha:** 2026-09-09 · **Rama:** `main` · **Último commit:** `35c0e99`
**Stack:** React 19 + Vite 8 (pnpm) · Supabase (PostgreSQL + Auth + Edge Functions + Storage)
**Documentos de referencia:** `docs/specs/2026-09-07-blueprint-supabase.md` (maestro), `docs/specs/2026-09-08-tablero-taller-design.md` (Fase 2), `docs/2026-09-08-revision-integral.md` (revisión), `docs/deuda-seguridad.md`

> **Principio de arquitectura.** La base de datos *es* la capa de aplicación: reglas de negocio, autorización e invariantes viven en PostgreSQL (RLS, triggers, RPC). El navegador y las Edge Functions son clientes de esa base. Cualquier regla que solo exista en React no es una regla.

---

## 1. Dónde estamos

| Fase | Estado | Entrega |
|---|---|---|
| **0 · Saneamiento** | ✅ completada (2026-09-08) | Un solo árbol coherente, sin colisión de timestamps, `db reset` limpio, cero rastro de Flask/MySQL/TOTP |
| **1 · Identidad y acceso** | ✅ completada | Login + 2FA por OTP de correo + RLS por rol |
| **2 · Dominio de garantías** | ◐ **en curso** — SQL listo y tablero conectado; falta ficha de detalle y pantallas por rol | El taller puede dar de alta órdenes y verlas en el tablero |
| **2.1 · Ficha y operación por rol** | ⬜ pendiente | Detalle de orden, cambio de estado, impresión, paneles `/jefe` `/tecnico` `/recepcion` |
| **3 · Evidencia documental** | ◐ parcial | La tabla `documentos_garantia`, el bucket y la subida desde el alta **ya existen**; falta la descarga/gestión desde la ficha |
| **4 · Portal público y notificaciones** | ⬜ pendiente | La RPC pública ya existe en SQL; faltan pantalla, outbox, `notificar` y `pg_cron` |

### 1.1 Qué funciona hoy, de extremo a extremo

- **Autenticación**: email + contraseña (mínimo 12 caracteres, en el formulario *y* en `config.toml`), segundo factor por código enviado con Resend desde la Edge Function `mfa-enviar-codigo`. El código nunca vuelve al navegador: la función solo devuelve `expira_en`.
- **Autorización**: el rol se lee de `profiles` bajo RLS, no del formulario ni del metadata del JWT. `mi_rol()` exige `mfa_ok()`, así que sin segundo factor no hay lectura de dominio.
- **Alta de usuarios**: Edge Function `admin-crear-usuario` con contraseña temporal de 144 bits.
- **Tablero del taller** (`/admin`): KPIs, tabla de órdenes, filtros por estado leídos de `estados_garantia`, búsqueda multicriterio sobre 6 columnas, panel de vencimientos.
- **Alta de orden**: modal con autocompletado de cliente y producto, creación atómica con `crear_orden()`, subida de documentos y **entrega única del token de consulta**.
- **Base de datos**: 7 migraciones, máquina de estados en tabla (no campo libre), cobertura calculada por trigger, historial inmutable append-only, token de consulta hasheado, ~110 pruebas pgTAP + 59 pruebas Vitest.

### 1.2 Mapa de migraciones

| Migración | Contenido |
|---|---|
| `20260906000001_auth_base` | `profiles`, roles, RLS anti-recursión, triggers anti-autoescalada |
| `20260906000002_garantias` | Catálogos, `garantias`, estados y transiciones, historial, `consultar_garantia()` |
| `20260907000003_mfa_email` | `email_mfa_codes`, `mfa_sesiones`, `generate_mfa_code()`, `mfa_ok()` |
| `20260908000004_tablero_operativo` | `prioridad`, `tipo_garantia`, `meses_garantia_override`, `sla_dias`, `v_ordenes_tablero`, `kpis_tablero()`, `crear_orden()` |
| `20260908000005_regenerar_token` | `regenerar_token_orden()` |
| `20260908000006_documentos_garantia` | Tabla de documentos + bucket privado + políticas de Storage |
| `20260908000007_correcciones_revision` | Correcciones S1, D1, D2, S3, D9, D10 de la revisión integral |

---

## 2. Instalación y puesta en marcha

### 2.1 Requisitos

- Node.js 18+ (probado con 22)
- **pnpm** — el frontend usa pnpm (`packageManager: pnpm@12.3.4`) y `pnpm-lock.yaml`; no mezclar con npm en `frontend/`
- Supabase CLI
- Cuenta de Resend (o dominio verificado, si va a producción)

```bash
npm install -g pnpm
npm install -g supabase
pnpm --version && supabase --version
```

### 2.2 Camino corto

Con un proyecto Supabase y una cuenta Resend ya creados, el wizard hace todo lo demás (dependencias, login/link, `.env`, secretos, `db push` y deploy) y valida el flujo de login + MFA al final:

```bash
bash scripts/setup-supabase-mfa.sh
```

Es interactivo y reentrante: se puede cortar con Ctrl-C y volver a correr — reutiliza lo que ya quedó en `frontend/.env`.

### 2.3 Camino manual

```bash
# 1. Backend
supabase login                              # o: supabase login --token "TU_ACCESS_TOKEN"
supabase link --project-ref <project-ref>   # el <project-ref> sale de https://<project-ref>.supabase.co
supabase secrets set RESEND_API_KEY=tu_clave_resend
supabase secrets set ORIGENES_PERMITIDOS=http://localhost:5173,https://tu-dominio.com
supabase db push
supabase functions deploy mfa-enviar-codigo
supabase functions deploy admin-crear-usuario

# 2. Frontend
cd frontend
pnpm install
pnpm dev            # http://localhost:5173
```

`frontend/.env` (no versionado):

```env
VITE_SUPABASE_URL=https://<project-ref>.supabase.co      # RAÍZ, sin /rest/v1
VITE_SUPABASE_ANON_KEY=sb_publishable_...
```

> **Error clásico (F1 de la revisión):** poner `/rest/v1/` al final de `VITE_SUPABASE_URL`. `createClient()` añade `/rest/v1`, `/auth/v1`, `/functions/v1` y `/storage/v1` por su cuenta; con el sufijo puesto a mano se rompen auth, funciones y storage. **Verificar también la variable en Vercel**, que arrastraba la misma forma.

### 2.4 Comandos del día a día

| Comando | Dónde | Qué hace |
|---|---|---|
| `pnpm dev` | `frontend/` | Servidor de desarrollo |
| `pnpm build` / `pnpm preview` | `frontend/` | Build de producción y vista previa |
| `pnpm test` | `frontend/` | Vitest (59 pruebas). Correr con `TZ=America/Caracas` |
| `pnpm lint` | `frontend/` | Oxlint |
| `supabase start` | raíz | Stack local completo |
| `supabase db reset` | raíz | Recrea el esquema desde cero + pruebas pgTAP |
| `supabase functions serve mfa-enviar-codigo --no-verify-jwt` | raíz | Función en local (**solo** local) |
| `supabase functions logs mfa-enviar-codigo --since 1h` | raíz | Diagnóstico |

### 2.5 Verificación rápida tras instalar

```bash
# La función debe rechazar peticiones sin JWT
curl -i -X POST "https://<project-ref>.supabase.co/functions/v1/mfa-enviar-codigo" \
  -H "Content-Type: application/json" -H "Origin: http://localhost:5173"
# Esperado: 401
```

Con la clave `anon` en el SQL editor: `select * from v_ordenes_tablero;` → **0 filas**; `select kpis_tablero();` → permiso denegado.

---

## 3. Funcionalidades y paneles pendientes

### 3.1 Fase 2.1 — lo siguiente en la fila

| Pendiente | Detalle |
|---|---|
| **Ficha de detalle de la orden** | Es la pieza que desbloquea casi todo lo demás: cambio de estado, notas, diagnóstico, documentos y política de resolución cuelgan de ella |
| **Cambio de estado desde la interfaz** | Los destinos posibles se consultan a `transiciones_estado`, no se codifican en React. Necesita además un parámetro de comentario real (ver D5) |
| **Política de resolución** | Nota de crédito (ingreso por tienda) vs. cambio directo (cliente final). Marcado como **requisito innegociable** por la operativa de mostrador |
| **Paneles `/jefe`, `/tecnico`, `/recepcion`** | Hoy los tres renderizan `Panel.jsx`, una pantalla provisional que solo muestra nombre, correo, rol y expiración de sesión. `/admin` es el único con tablero real |
| **Navegación de la barra lateral** | `BarraLateral.jsx` tiene 5 destinos (Tablero, Ventas y garantías, Taller, Clientes, Notificaciones) y **ninguno navega**: falta sustituir `onIr` por `<NavLink>` cuando existan las rutas |
| **Paginación del tablero** | `useOrdenes` usa `pagina: 0, porPagina: 25` fijos y "Ver todas" avisa que no está construido: con más de 25 órdenes vivas las demás son inalcanzables |
| **Hoja de impresión del comprobante** | El token se entrega en pantalla; falta el CSS de impresión |
| **Pruebas del flujo de login** | Deuda declarada desde el commit `b81e632` |
| **Pruebas pgTAP de la migración 7** | El resto del esquema tiene pruebas; `20260908000007` todavía no |

### 3.2 Fase 3 — evidencia documental (parcial)

Falta la descarga con URL firmada desde la ficha, y la gestión (reemplazar/eliminar un adjunto mal subido), que hoy no existe por decisión declarada: sin ficha, dar `UPDATE`/`DELETE` sería "una puerta sin pared".

### 3.3 Fase 4 — portal público y notificaciones

| Pendiente | Detalle |
|---|---|
| Pantalla de consulta pública | Formulario `nº de orden + token` contra `consultar_garantia()`; sin login, sin datos internos |
| Tabla `eventos_dominio` (outbox) | `INSERT` desde los triggers que ya escriben el historial |
| Edge Function `notificar` | Consume el outbox por webhook y despacha por Resend |
| Barrido `pg_cron` | Aviso de garantía por vencer + purga de `consulta_publica_intentos` |
| Campana de avisos y "Enviar recordatorios" | Dependen del outbox |

### 3.4 Sin planificar

Presencia en tiempo real ("Colaboradores" del mockup) — es otro subsistema y se descartó del alcance.

---

## 4. Qué falta corregir del código ya implementado

### 4.1 Seguridad — abierto

| Id | Hallazgo | Dónde se arregla |
|---|---|---|
| **S2** · media-alta | El freno de fuerza bruta del portal público es evadible: `consultar_garantia()` toma el **primer** elemento de `X-Forwarded-For`, que lo pone el cliente. Basta variar esa cabecera para no acumular nunca fallos | Tomar el **último** elemento o la cabecera del borde real — **hay que comprobar el gateway del despliegue antes de tocarlo** |
| **S4** · media | La limpieza de adjuntos huérfanos no puede funcionar: `subirDocumento()` llama a `storage.remove()` y la migración 6 no crea policy de DELETE. El binario queda en el bucket sin metadato, y `doc_storage_insert` además permite escribir en cualquier path del bucket | Decidir: DELETE al autor sobre su propia subida reciente, **o** mover la compensación a una Edge Function con `service_role` |
| **CSO-10** · media | Un correo sin verificar recibe el segundo factor: nada comprueba `auth.users.email_confirmed_at` | Condición en `generate_mfa_code()` (SQL, no React) + mensaje propio en el login |
| **CSO-12** · media | La contraseña temporal de `admin-crear-usuario` nunca caduca ni obliga a cambiarse | Marca en `profiles` o en `raw_app_meta_data` + comprobación en el enrutado tras el 2FA |
| **CSO-05** · baja | Rastro forense parcial del 2FA: `email_mfa_codes` y `mfa_sesiones` no registran origen | Columna de IP en `mfa_sesiones`, alimentada desde `request.headers` |
| **S5** | MFA válido 12 h anclado al `session_id`: con "Recordarme", una pestaña reabierta dentro de esa ventana entra sin segundo factor. Es coherente con lo diseñado, pero conviene documentarlo | Documentar (o acortar la ventana) |
| **S6** | `config.toml` tiene `enable_signup = true` (config local) | **Confirmar que el registro público está apagado en el proyecto desplegado** |

### 4.2 Base de datos y negocio — abierto

| Id | Hallazgo | Nota |
|---|---|---|
| **D3** · media | `crear_orden()` descarta en silencio los datos de un cliente/producto "nuevo" que ya existía (`ON CONFLICT ... DO UPDATE SET updated_at`). El recepcionista teclea nombre y teléfono y se ignoran | Propuesta: devolver `cliente_ya_existia` / `producto_ya_existia` y avisarlo en el modal. **Cambia la firma** de la RPC y toca `ordenes.js` |
| **D4** · media | `kpis_tablero().sla_por_vencer` cuenta también las ya vencidas (no hay cota inferior) | **Decisión de negocio**: o se renombra el KPI a "en riesgo o vencidas", o se añade `>= now()::date` |
| **D5** · media | `historial_garantias.comentario` guarda el diagnóstico vigente, no el motivo de la transición: la bitácora repite siempre lo mismo | Necesita un parámetro de comentario en la operación de cambio de estado (que aún no existe en la UI) |
| **D11** · media | `now()::date` corre en UTC (zona de PostgREST). Con el taller en `America/Caracas`, entre las 20:00 y medianoche el servidor ya está en el día siguiente | `ALTER ROLE authenticator SET timezone = 'America/Caracas';` o comparar explícitamente. Es el mismo error ya corregido en el navegador |
| **D6** · baja | `productos.categoria` es texto libre sin CHECK ni catálogo: `ROUTER`, `Router` y `router` son tres categorías | Tabla `categorias_producto` con FK. **No es aditivo**: necesita backfill, migración propia |
| **D8** · baja | Desactivar un estado con órdenes vivas las saca de las píldoras pero las deja en "TODAS", sin forma de aislarlas | CHECK o aviso al desactivar |
| **D12** · baja | `consulta_publica_intentos` crece sin techo; el cron de purga no está programado | Entra con el `pg_cron` de la Fase 4 |

### 4.3 Frontend — abierto

| Id | Hallazgo |
|---|---|
| **F6** | Sin paginación en la interfaz (ver §3.1) |
| **F7** | `contarPorEstado` hace una consulta `head` por estado (11 con el catálogo actual) en cada búsqueda. Asumible al volumen de un taller; si duele, una RPC `recuentos_tablero(termino)` lo resuelve sin tocar la UI |
| **F8** | `consultarPorVencer` no lleva `limit`: trae todo lo que caiga en la ventana de 30 días |
| **F9** | `traducirError()` no cubre `P0002` (orden inexistente) ni `54000` (límite de códigos MFA) |
| **F11** | `normalizarFila()` expone `prioridad` y `TablaOrdenes` no la pinta: dato que viaja y no se usa |
| **F4-bis** | El escape de `%` y `_` con `\` está hecho del lado del cliente; **verificar contra el proyecto desplegado** la primera vez que se busque un `%` literal |

### 4.4 Ya corregido (no reabrir)

`VITE_SUPABASE_URL` mal formada (F1) · protección de columnas en `garantias` (S1) · recálculo de cobertura al cambiar `tipo_garantia`/`meses_garantia_override` (D1) · validación de rol del técnico en `crear_orden()` (D2) · `subido_por = auth.uid()` (S3) · recuentos de píldoras con el término de búsqueda (F2) · "hoy" en hora local (F3) · comodines de LIKE escapados (F4) · índices GIN reales con `pg_trgm` (D9) · índice de la FK `subido_por` (D10) · lockfile sincronizado (F10) · el doble de pruebas ahora registra los argumentos de la cadena.

### 4.5 Cambio sin commitear

`supabase/functions/admin-crear-usuario/index.ts` tiene en *stage* la ampliación de `Access-Control-Allow-Headers` (`apikey, x-client-info, x-application-name`). Falta commitear y **redesplegar la función** para que surta efecto.

---

## 5. Orden de trabajo sugerido

1. Commitear y redesplegar `admin-crear-usuario` (§4.5).
2. Escribir las pruebas pgTAP de la migración 7 y confirmar la URL corregida en el despliegue.
3. Decidir **S4** (adjuntos huérfanos) y **S2** (de qué cabecera sale la IP real).
4. Cerrar **CSO-10** y **CSO-12** — las dos son condiciones de servidor, en SQL.
5. Fijar la zona horaria del servidor (**D11**).
6. Responder las dos preguntas de negocio: **D4** (qué cuenta `sla_por_vencer`) y **D5** (qué dice el comentario del historial).
7. Arrancar la **Fase 2.1** por la ficha de detalle: desbloquea cambio de estado, D5, la gestión de documentos y la política de resolución.
8. Paginación del tablero (**F6**), aviso de cliente/producto ya existente (**D3**) y normalización de `productos.categoria` (**D6**, con backfill).

> **Regla del proyecto:** un punto de seguridad se cierra con una migración y su prueba en `supabase/tests/`, no con una comprobación en React. Si solo lo hace cumplir la interfaz, no lo hace cumplir nadie.
