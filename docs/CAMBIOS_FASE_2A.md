# Fase 2a — Garantía, Consulta y Taller · Registro de cambios

**Corte:** 2026-10-30 · **Rama:** `feat/fase-2a` · **Plan:** `docs/superpowers/plans/2026-10-30-fase-2a-garantia-consulta-taller.md`
**Spec:** `docs/superpowers/specs/2026-10-30-fase-2a-garantia-consulta-taller-design.md` · **Diseño de pantallas:** `docs/diseno-ui/`

> Este documento explica qué se hizo, por qué y qué sigue en curso. Lo hecho está **comprometido en git**; lo "en proceso" figura como cambios **sin commit** en el árbol de trabajo y puede haber cambiado desde que se escribió esto.

---

## 1. Resumen en 30 segundos

La fase 2a separa dos ideas que el Hito 1 mezclaba: **la garantía** (el equipo vendido, con su factura y plazo) y **la orden de servicio** (cada vez que ese equipo entra al taller). Antes, "registrar un equipo" creaba todo junto. Ahora:

1. **Ventas & Garantías** registra la garantía de la venta (sin revisar el equipo).
2. **Consulta** busca un equipo por serial, cédula/RIF, factura u orden y dice si está en garantía.
3. **Taller** abre una orden sobre ese equipo, con auditoría de recepción (checklist, fotos, documentos), y la sigue hasta la entrega.

La regla rectora no cambia: **la autorización y las reglas de negocio viven en Postgres, no en React**. El frontend adelanta avisos, pero la base decide.

**Trabajo en paralelo:** dos sesiones de Claude con repartos separados — una hizo el SQL (`supabase/`), otra el frontend (`frontend/`). Commits separados, sin `git add -A`.

---

## 2. Estado por tarea del plan

| Tarea | Qué es | Estado |
|---|---|---|
| 1–2 | Rama de trabajo y migración 0013 (renombre `registros` → `ordenes_servicio`) | ✅ Comprometida |
| 3 | Renombre mecánico del frontend | ✅ Comprometida |
| 4 | Migración 0014: origen VENTA/TALLER y desestimación | ✅ Comprometida |
| 5 | Migración 0015: tipo de atención, motivo de rechazo, bitácora | ✅ Comprometida |
| 6 | Migración 0016: estado RECHAZADO y roles cerrados | ✅ Comprometida |
| 7 | Migración 0017: reglas de avance impuestas por la base | ✅ Comprometida |
| 8 | Migración 0018: `registrar_garantia` y `buscar_equipo` | ✅ Comprometida |
| 9 | Migración 0019: `abrir_orden` por equipo | ✅ Comprometida |
| 10 | Migración 0020: `confirmar_compra` / `desestimar_compra` | ✅ Comprometida |
| 11 | Migración 0021: `cambiar_estado`, `asignar_tecnico`, `registrar_presupuesto` | ✅ Comprometida |
| 12 | Menú, layout y rutas | ✅ Comprometida (con cambio de diseño, ver §4.1) |
| 13 | Pantalla Nueva garantía | ✅ Comprometida |
| 14 | Pantalla Consulta (+ confirmar/desestimar compra) | ✅ Comprometida |
| 15 | Abrir orden con auditoría de recepción | ✅ Comprometida |
| 16 | Detalle de la orden | 🟡 **Solo lectura comprometida; las acciones están en proceso** |
| 17 | Lista del Taller | ✅ Comprometida |
| — | Tablero de garantías `/garantias` (maqueta 01) | ✅ Comprometido |
| 18 | e2e, documentación y cierre | 🟡 **En proceso** (`scripts/e2e-registro.sh` reescrito, sin commit) |

---

## 3. Backend (SQL) — migraciones 0013 a 0021

Las migraciones 0013–0017 ya estaban comprometidas al empezar la sesión de hoy; 0018–0021 se hicieron durante ella. Todas con su archivo de prueba SQL en `supabase/tests/`.

### 3.1 Modelo de datos
| Migración | Qué hace |
|---|---|
| **0013** | Renombre mecánico: `registros` → `ordenes_servicio`, `numero_registro` → `numero_orden`, `registro_id` → `orden_id`, `registrar_ingreso` → `abrir_orden`, `REG-AAAA-NNNNNN` → `OS-AAAA-NNNN`, bucket `registros/` → `ordenes/`. |
| **0014** | El equipo gana **origen** (`VENTA` o `TALLER`), quién lo registró y campos de **desestimación de compra**. La cobertura se recalcula con una precedencia nueva (desestimada y "taller sin confirmar" cortan antes que la fecha vencida). |
| **0015** | `tipo_atencion` **generado** (`GARANTIA` / `PAGO` / `PENDIENTE`) a partir de la cobertura; `motivo_rechazo`; bitácora de eventos en `historial_ordenes` (evento `BITACORA`). Un cambio de cobertura deja una fila automática. |
| **0016** | Estado **RECHAZADO** (decisión del taller, con motivo ≥ 10 caracteres; su única salida es ENTREGADO). Roles de cada transición cerrados de forma explícita. |
| **0017** | Las **reglas de avance las impone la base**: foto para pasar a diagnóstico; documento si el equipo es de taller sin confirmar; monto para pasar a "Presupuestado"; en servicio pago no se salta el presupuesto; un presupuesto se limpia si la orden vuelve a garantía. |

### 3.2 Funciones (RPC) nuevas
| Migración | Función | Contrato resumido |
|---|---|---|
| **0018** | `registrar_garantia(cliente, producto, serial, tipo_soporte, número, fecha_emisión, plazo, origen)` | Crea el equipo sin orden. Plazo distinto de 7 o 15 días → solo ADMIN/JEFE (42501). Lo repetido no duplica (`equipo_nuevo=false`). |
| **0018** | `buscar_equipo(p_serial, p_documento, p_factura, p_orden)` | Busca por serial (en todos los productos), cédula/RIF, factura o número de orden. Devuelve titular, vigencia, `estado_compra` (CONFIRMADA / PENDIENTE / DESESTIMADA) e historial `ordenes`. **Cambio incompatible:** la columna `ordenes_servicio` pasó a llamarse `ordenes`. |
| **0018** | Vista `v_garantias` | Una fila por equipo; alimenta el tablero de garantías. |
| **0019** | `abrir_orden(equipo, falla, accesorios, checklist, observaciones, clave_envio, fecha_ingreso)` | Abre la orden de un equipo existente, con la revisión de recepción, **en una sola transacción**. Idempotente por `clave_envio` (la repetición devuelve la orden original sin token). La firma antigua de 14 parámetros se retiró. |
| **0020** | `confirmar_compra(equipo, tipo, número, fecha, plazo)` | Solo ADMIN/JEFE. Ahora ratifica un soporte ya cargado. Recalcula las órdenes abiertas. |
| **0020** | `desestimar_compra(equipo, motivo)` | Solo ADMIN/JEFE, motivo ≥ 10. Las órdenes abiertas pasan a `FUERA_DE_GARANTIA` y tipo `PAGO`. |
| **0021** | `cambiar_estado(orden, estado, comentario, motivo)` | **Única vía** para cambiar el estado. Un TECNICO solo mueve órdenes asignadas a él. Transición inválida → 23514. |
| **0021** | `asignar_tecnico(orden, técnico)` | Solo ADMIN/JEFE; NULL desasigna; deja bitácora con el nombre. |
| **0021** | `registrar_presupuesto(orden, monto)` | ADMIN, JEFE o el técnico asignado; solo con tipo `PAGO`; monto ≥ 0. |

> ⚠️ **Cambio de permisos:** desde la 0021, `authenticated` **ya no puede hacer UPDATE directo** de `estado`, `costo_reparacion` ni `tecnico_asignado_id`. Solo siguen abiertas `diagnostico`, `accesorios` y `recibido_por`. Todo lo demás pasa por las RPC.

**Verificación reportada por la sesión de SQL:** los 22 archivos de prueba SQL pasan con la suite completa. Yo **no** volví a correr la suite SQL (requiere Docker).

---

## 4. Frontend — lo comprometido hoy

Reparto: backend SQL y frontend por sesiones separadas. Cada pieza se hizo con prueba antes del código (RED → GREEN) y quedó con `pnpm test`, `pnpm build` y `pnpm lint` en verde al momento de su commit.

### 4.1 Layout y rutas — commit `6cfcf5b`
- **Qué:** un único `Layout` con barra lateral que usa `NavLink` (URL real) con los destinos **Garantías** y **Taller**, el correo del usuario y "Cerrar sesión".
- **Cambio de diseño:** el plan pedía una `BarraNavegacion` de pestañas; se reemplazó por la barra lateral del diseño aprobado (`docs/diseno-ui/README.md` §2) y se borró la primera versión (nunca comprometida).
- **Rutas** (todas protegidas para los 4 roles): `/garantias`, `/garantias/nueva`, `/garantias/consulta`, `/taller`, `/taller/nueva`, `/taller/:id`.
- **Tablero antiguo:** el botón "Nuevo registro" pasó a **"Nueva orden"** y navega a la Consulta; ya no monta el asistente viejo.

### 4.2 Nueva garantía — commit `a8d2cac` · `/garantias/nueva`
- Asistente de **4 pasos**: Cliente → Equipo → Compra → Resumen. Reutiliza `PasoCliente` y `PasoCompra` del Hito 1.
- **No** pide falla, checklist ni fotos (revisar el equipo es cosa del Taller).
- Si el plazo no es 7 ni 15 y el rol no es jefatura, **avisa pero no bloquea**: la base decide.
- Si la base rechaza, muestra su mensaje. Al registrar, navega a `/garantias/consulta?serial=…`.
- **Servicio:** `garantiasService.js` (`registrarGarantia`, `buscarGarantia`). Se exportó `rpc` desde `registroService` para reutilizar el mapeo de errores.

### 4.3 Consulta — commit `bb4e904` · `/garantias/consulta`
- Buscador único: selector **Buscar por** (serial, cédula/RIF, factura, orden) + valor.
- Si llega `?serial=…` busca sola.
- **Ficha por equipo:** producto, serial, titular, periodo (emisión → vencimiento), cobertura con color (mismo tono que el Tablero) y días restantes o "Vencida"; motivo si la compra fue desestimada; historial de órdenes.
- **Avisos antes de abrir orden:** "se atenderá como servicio pago" (fuera de garantía), "cobertura pendiente de confirmar" (por determinar), y "ya tiene una orden abierta".
- **Sin resultados:** "No hay garantía registrada" + **Registrar ahora** → `/garantias/nueva?serial=…&origen=TALLER` (la Nueva garantía lee ese serial y origen).
- **Abrir orden de servicio** → `/taller/nueva?equipo=<id>`.

### 4.4 Confirmar y desestimar compra — commit `0eeb861`
- En la ficha, solo para **ADMIN y JEFE_SERVICIO** y solo si la compra está **PENDIENTE**.
- **Confirmar:** formulario (número de factura, fecha, plazo) precargado con lo que el equipo trae → `confirmar_compra`.
- **Desestimar:** motivo; el botón se habilita con 10 caracteres → `desestimar_compra`.
- Tras guardar, repite la búsqueda para mostrar el estado nuevo; si la base rechaza, muestra su mensaje.

### 4.5 Abrir orden con auditoría de recepción — commit `4704758` · `/taller/nueva?equipo=<id>`
- Una sola pantalla: equipo en solo lectura (leído de `v_garantias`) con aviso de cobertura; **falla** (5–2000), **accesorios**, **checklist** (`PasoVerificacion`) y **fotos/documentos** (`PasoAdjuntos`).
- Exige falla y al menos una foto; si la compra del equipo está PENDIENTE, exige además el **documento presentado**.
- **Orden primero, adjuntos después**, con una clave de envío por pantalla: si una subida falla, aparece "Reintentar adjuntos" y repite solo la subida, sin crear otra orden. Al terminar va a `/taller/<orden_id>`.
- **Servicio:** `tallerService.js` (`abrirOrden` con la firma exacta de la 0019 y sin fecha de ingreso, `leerEquipo`, `subirAdjuntos`).
- **Asistente viejo retirado:** se borraron `NuevoRegistro`, `useAsistente`, `enviarRegistro`, `PasoEquipo`, `PasoResumen` y `registro.css` con sus pruebas, y el `abrirOrden` antiguo de `registroService` (ya no funcionaba contra la base). Se conservó `borrador.js` porque `authService` lo usa.

### 4.6 Lista del Taller — commit `48dd8c5` · `/taller`
- Tabla de órdenes sobre `v_tablero` (ya ordenada por urgencia): orden, cliente, equipo, garantía, estado, ingreso.
- **Chips por estado** (Todas, Recibido, En diagnóstico, En reparación —incluye "En espera de repuesto"—, Reparado) más un chip nuevo **Rechazado**.
- El clic en una fila abre `/taller/<orden_id>`. Estado vacío, error y botón **Nueva orden**.

### 4.7 Tablero de garantías — commit `11fb937` · `/garantias`
- Una fila por equipo sobre `v_garantias`, ordenada por vencimiento, con **búsqueda en la base** (serial, titular, cédula, factura).
- **Chips:** Vigente · Por vencer (3 días o menos) · Vencida · Por confirmar. Una fila abre la Consulta con su serial; **Nueva garantía** abre el asistente.

### 4.8 Detalle de la orden, solo lectura — commit `540f057` · `/taller/:id`
- **Encabezado:** número de orden, estado, cobertura con color e insignia "Atención: garantía / pago / pendiente".
- **Barra de estados:** Recibido → En diagnóstico → Diagnosticado → *Presupuestado (solo pago)* → En reparación → Reparado → Entregado. "Diagnosticado" es una etapa visual que se marca si hay diagnóstico. Los estados laterales (rechazado, irreparable, en espera de repuesto) salen como insignia con su tono.
- **Cinco pestañas:** Resumen · Auditoría (historial de revisiones) · Diagnóstico y presupuesto · Documentos · Bitácora (cambios de estado, eventos de la base y notas internas). Cada pestaña lee lo suyo al abrirse; un fallo en una no tumba el resto.
- **Servicio:** `obtenerOrden` junta tres lecturas simples (`v_tablero`, `ordenes_servicio`, nombre del técnico) en vez de un embed que dependa de claves foráneas; más `historialOrden`, `notasOrden`, `adjuntosOrden`.

### 4.9 Aterrizaje tras el login — commit `7ace5bf`
- **Problema:** al iniciar sesión los cuatro roles caían en `/tablero` (el Tablero antiguo), sin enlaces a las pantallas nuevas.
- **Cambio:** ahora aterrizan en `/garantias`. Se cambió primero la prueba (`authService.test.js`) y luego `RUTA_POR_ROL`. El `/tablero` antiguo sigue existiendo en esa URL, pero nada lo enlaza.

---

## 5. En proceso (cambios sin commit al momento de escribir esto)

> Esto **no lo hice yo**: lo vi como cambios sin commit en el árbol de trabajo, hechos por otra sesión. Lo describo para que no haya sorpresas; confírmalo con quien lo esté haciendo.

- **Acciones del detalle de la orden (resto de la Tarea 16)**, en `OrdenDetalle.jsx`, `tallerService.js`, `tablero/dominio.js` y sus pruebas:
  - Nuevas funciones de servicio: `cambiarEstado`, `asignarTecnico`, `registrarPresupuesto`, `listarTecnicos`.
  - Espejo de transiciones en `dominio.js` (`TRANSICIONES`, `transicionesDesde(desde, rol)`).
  - En las pruebas: **Avanzar** (con comentario opcional), **Rechazar** (modal con motivo ≥ 10), **Asignar técnico** (modal con técnicos activos) y el caso de **RECEPCION** (solo marca Entregado).
  - Estado al medir: **2 pruebas en rojo** (`dibuja la barra de estados con el tipo de atención` y `una orden entregada ya no ofrece avanzar, rechazar ni asignar`), consistente con trabajo a medio hacer. La suite total daba 285 pasadas y 2 fallidas.
- **Tarea 18 — e2e:** `scripts/e2e-registro.sh` reescrito (~176 líneas cambiadas) para el flujo garantía → taller. Sin commit y sin verificar por mí.
- **Pendiente de la Tarea 18:** actualizar `scripts/verificar-migraciones.sh` a la cadena 0013–0021, el README y `ESTADO_DEL_PROYECTO.md` (nuevo corte, matriz de funcionalidades y condiciones de despliegue).

---

## 6. Decisiones de diseño y recortes (modo "lo mínimo que funciona")

- **Barra lateral en vez de pestañas** (ver §4.1).
- **Nueva garantía sin borrador de 24 h:** el plan lo pedía; se omitió porque `useAsistente` compartía clave con el asistente viejo. Hoy se pierde lo escrito si se cierra la pestaña.
- **Un producto por garantía:** la maqueta permite varios por factura; la RPC y el plan registran uno.
- **Tipo de soporte fijo en FACTURA** al confirmar la compra; la RPC también admite nota de entrega.
- **Auditoría con casillas** (checklist del Hito 1) en vez del Sí/No obligatorio por punto de la maqueta; si no se marca nada se manda `checklist: null`.
- **Documentos del detalle** se listan por nombre, pero **no se pueden abrir** todavía (faltan URLs firmadas del bucket).
- **Auditoría del detalle** muestra el historial, pero no el formulario de nueva revisión.
- **Filtro de chips del Taller** se aplica sobre lo ya cargado (hasta 200 filas), no en la base.
- **Tablero antiguo `/tablero`** queda como ruta heredada sin enlace; su barra lateral de 64 px y el menú original no se tocaron.

---

## 7. Riesgos y pendientes por resolver

1. **Migraciones en el Supabase remoto: sin verificar.** El proyecto del `.env.local` (`przkjfyatficximekvow`) no está en la cuenta de Supabase conectada a la sesión de Claude, y `supabase migration list --linked` no devolvió lista (se quedó en "Initialising login role…"). Las pantallas nuevas necesitan **0013–0021** aplicadas; si el remoto está atrás, `/garantias` y la Consulta darán error. **Acción tuya:** correr `npx supabase migration list --linked` y, si faltan, decidir cuándo hacer `supabase db push`. No se aplicó nada al remoto.
2. **Aviso del repaso de adjuntos:** si el remoto tuviera la 0008 original, hay que revisarlo al desplegar (lo pide el plan en la Tarea 18).
3. **Login 2FA / Resend:** sigue pendiente el dominio verificado en Resend y revertir el destinatario fijo temporal (ver memoria del proyecto).
4. **Las RPC se probaron simuladas en el frontend.** Las pruebas de pantalla mockean los servicios; la integración real contra la base solo está cubierta por las pruebas SQL y, cuando se complete, el e2e.
5. **Advertencias de lint preexistentes** (variables sin usar en tests antiguos, un `no-useless-escape`, un aviso de fast-refresh en `AuthContext`). No hay errores.
6. **Documentos de diseño sin versionar:** `diseno.md`, `docs/diseno-ui/` y los dos PDF siguen sin seguimiento en git.

---

## 8. Cómo probarlo en local

```bash
cd frontend
pnpm dev          # abre la URL que imprime Vite (normalmente http://localhost:5173)
```

- Necesita `frontend/.env.local` con `VITE_SUPABASE_URL` y `VITE_SUPABASE_ANON_KEY` (ya existe).
- Tras iniciar sesión (con código 2FA) aterrizas en `/garantias`. Rutas: `/garantias`, `/garantias/nueva`, `/garantias/consulta`, `/taller`, `/taller/nueva?equipo=<id>`, `/taller/<id>`.
- Pruebas: `pnpm test` · lint: `pnpm lint` · build: `pnpm build`. Suite SQL: `bash supabase/tests/run.sh` (requiere Docker).

---

## 9. Verificación al momento de cada commit de frontend

| Commit | Pruebas de frontend | Build |
|---|---|---|
| `6cfcf5b` layout y rutas | 192 pasan | ✅ |
| `a8d2cac` Nueva garantía | 203 | ✅ |
| `bb4e904` Consulta | 221 | ✅ |
| `4704758` Abrir orden | 202 (tras retirar el asistente viejo y sus pruebas) | ✅ |
| `48dd8c5` Lista del Taller | 209 | ✅ |
| `11fb937` Tablero de garantías | 220 | ✅ |
| `0eeb861` Confirmar/desestimar | 228 | ✅ |
| `540f057` Detalle solo lectura | 258 | ✅ |
| `7ace5bf` Aterrizaje tras login | 258 | ✅ |

El número baja en `4704758` porque se eliminaron las pruebas del asistente viejo junto con su código.
