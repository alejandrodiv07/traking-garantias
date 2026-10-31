# Funcionalidades — Track Garantía

Qué existe hoy, para qué sirve cada cosa y qué está listo para probar. Corte: **2026-10-31**, rama `feat/fase-2b`. La guía para montarlo en otra máquina está en [INSTALAR_EN_OTRA_MAQUINA.md](INSTALAR_EN_OTRA_MAQUINA.md).

---

## 1. El sistema en una frase

Gestión del taller de servicio técnico de Prime Telecom en tres piezas unidas por el **serial** del equipo: la **garantía** (lo que se vendió, con su factura y plazo), la **consulta** (dime si este equipo está cubierto) y la **orden de servicio** (cada vez que ese equipo entra al taller). La autorización y las reglas de negocio viven en Postgres (RLS + RPC + triggers); el frontend adelanta avisos pero no decide.

## 2. Roles y entrada

| Rol | Aterriza en | Puede |
|---|---|---|
| `RECEPCION` | `/garantias` | Registrar garantías y abrir órdenes |
| `TECNICO` | `/taller` | Consultar, abrir órdenes propias, avanzar estados de las suyas, presupuestar |
| `JEFE_SERVICIO` | `/taller` | Todo lo anterior + asignar técnico, rechazar, confirmar/desestimar compra, importar ventas, catálogo |
| `ADMIN` | `/garantias` | Todo lo anterior + fijar plazos arbitrarios, gestionar usuarios y sus roles |

- **Inicio de sesión:** correo + contraseña, y luego un **código de un solo uso por correo** (MFA por email, migración 0003). El código lo manda la Edge Function `mfa-enviar-codigo` vía Resend. La base exige `mfa_ok()` para devolver el rol: un perfil válido con sesión sin verificar ve datos restringidos. ⚠️ Deuda conocida (D11): mientras el dominio de Resend no esté verificado, la función manda todos los códigos a un destinatario fijo (hotfix temporal).
- Los usuarios se crean con **invitación** desde la función `admin-crear-usuario` (solo ADMIN y vía `service_role`); nadie se auto-registra ni se auto-asigna rol. **Cuentas ya verificadas para entrar:** [USUARIOS_LOGIN.md](USUARIOS_LOGIN.md).
- Un usuario sin perfil, inactivo o con sesión revocada queda sin datos (`/sin-acceso`).

## 3. Módulos de la interfaz (todos funcionales)

### `/garantias` — Tablero de garantías
Tabla `v_garantias`: una fila por equipo. Filtro de texto, filtro por estado de compra, fechas. Muestra titular, producto+serial, factura, cobertura con días restantes, estado de compra y cómo se verificó contra Ventas (insignia: factura hallada / no hallada en Ventas). «Ver» lleva a la ficha del equipo en la Consulta.

### `/garantias/nueva` — Nueva garantía (asistente de 5 pasos)
1. **Titular:** cliente existente por documento o titular nuevo (tipo, nombre, correo).
2. **Productos:** varios por garantía (una garantía por producto). Cascada **tipo de equipo → marca → modelo** contra el catálogo del Inventario (nuevo en 2b): cambiar el tipo limpia marca y modelo. Serial único: lo repetido lo rechaza la base.
3. **Compra:** fecha de emisión (no futura), plazo 7 o 15 días; «otro plazo» solo lo fija Jefatura/ADMIN. Calcula vencimiento y días restantes en vivo y avisa si nace vencida. Sin factura → «por determinar».
4. **Documentos:** fotos (JPG/PNG/WEBP ≤ 8 MB, hasta 8) y documentos (PDF/JPG/PNG ≤ 8 MB, hasta 6), opcionales, vinculados a la garantía o garantías recién creadas.
5. **Registrar:** llama `registrar_garantia` (RPC 0018). Si un producto falla, no se repiten los ya registrados al reintentar. La pantalla de éxito ofrece: ver en Consulta, abrir orden o registrar otra.

### `/garantias/consulta` — Consulta
Búsqueda por **serial** (cédula/RIF, factura u orden también). Ficha del equipo: titular, tipo de documento, cobertura (vigencia exacta, día límite), insignia de verificación, estado de compra y historial de órdenes con su estado. Desde la ficha:
- **Confirmar compra** (ADMIN/JEFE): ratifica un soporte ya cargado (tipo, número, fecha, plazo).
- **Desestimar compra** (ADMIN/JEFE): motivo ≥ 10 caracteres; las órdenes abiertas pasan a FUERA DE GARANTÍA / PAGO.
- **Abrir orden** o, si el serial no existe, ir a registrarla con origen `TALLER` («queda por confirmar» hasta ratificar el soporte).

### `/taller` — Taller
- **Lista:** órdenes por estado con chips, buscador (orden, cliente, serial, factura) y KPI.
- **Abrir orden** (`/taller/nueva?equipo=…`): la **auditoría de recepción** en un formulario único que llama `abrir_orden` (RPC 0019): falla reportada, accesories, checklist sí/no, observaciones, fotos y documentos, con **borrador local de 24 h** por equipo (restaura lo no enviado) y **clave de envío idempotente** (reenviar no crea dos órdenes; si falla una subida se reintentan solo los adjuntos).
- **Detalle** (`/taller/:id`): datos del equipo, revisión técnica, bitácora de eventos y las acciones según el rol y el estado:
  - Avanzar estado con `cambiar_estado` (RPC 0021), única vía; la base impone las reglas (migración 0017): foto para pasar a diagnóstico; documento si el equipo de taller no está confirmado; monto para pasar a Presupuestado; en pago no se salta el presupuesto.
  - Estados: RECIBIDO → EN_DIAGNOSTICO → PRESUPUESTADO → (EN_ESPERA_REPUESTO) → EN_REPARACION → REPARADO / IRREPARABLE / RECHAZADO_POR_CLIENTE → ENTREGADO; RECHAZADO (decisión del taller, motivo ≥ 10, solo Jefatura; única salida ENTREGADO); ANULADO terminal.
  - **Asignar técnico** (ADMIN/JEFE), **registrar presupuesto** (monto), **entregar** (quién recibe), **confirmar/desestimar compra** del cliente en PRESUPUESTADO.

### `/ventas/importar` — Importar ventas (ADMIN/JEFE)
Carga el CSV/PDF de facturas de venta → `importar_ventas` (migración 0023). Al confirmar una factura se recalcula la cobertura, la garantía `TALLER` ya con factura se confirma sola y el tablero muestra cómo se verificó.

### `/inventario` — Inventario (nuevo en 2b)
Catálogo de productos del taller (marca → modelo, categoría) de la migración 0025. Lista con buscador y paginación; **crear, corregir y desactivar** modelos (solo ADMIN/JEFE); el activo/inactivo marca qué ofrece el asistente de Nueva garantía. Sirve de origen a la cascada tipo→marca→modelo.

### En preparación (`Proximamente`, con motivo visible)
`/entregas` (falta backend de retiro y cobro) · `/reportes` (falta expedientes y PDF) · `/clientes` (avisos por correo, depende de Resend) · `/notificaciones` (fase 2c).

### General
- **Tema claro/oscuro** (oscuro por defecto) conmutable desde la barra superior.
- **Móvil:** lista→detalle con formularios antes que resumen; el teclado no tapa los campos clave.
- El título de la pestaña sigue al módulo activo.

## 4. Qué impone la base (no la interfaz)

- **RLS** por rol con `mi_rol()` (que además exige MFA hecho) e `is_active`.
- **RPC únicas:** `registrar_garantia`, `buscar_equipo`, `abrir_orden`, `cambiar_estado`, `asignar_tecnico`, `registrar_presupuesto`, `confirmar_compra`, `desestimar_compra`, `importar_ventas`, `limpiar-huerfanos` (Edge, programa pg_cron).
- **Reglas de avance** de estados (0017), **transiciones y roles cerrados** (0016), **UPDATE directo de estado/costo/técnico cerrado** desde 0021.
- **Adjuntos:** bucket `ordenes`/`equipos`, topes de cantidad y peso, rutas por equipo, jamás orden y equipo a la vez (0024).
- Un usuario sin perfil o revocado no ve ni una fila.

## 5. Estado de las pruebas (31/10/2026)

| Suite | Resultado |
|---|---|
| `pnpm test` (vitest + Testing Library) | ✅ **416 pruebas en 31 archivos, todas pasan** |
| `pnpm lint` (oxlint) | ✅ Sin errores (7 avisos de variables/importes sin uso) |
| `pnpm build` (Vite) | ✅ Construye; nota: un chunk > 500 kB (sin dividir, no es error) |
| `bash supabase/tests/run.sh` (31 archivos SQL, Postgres 17 en Docker) | ✅ **31/31 archivos pasan** (corrida completa del 31/10/2026; la nueva `31_catalogo.sql` de la migración 0025 suma 7 aserciones) |
| `bash scripts/e2e-registro.sh` | punta a punta garantía → consulta → orden → rechazo → entrega → importar ventas |
| Colecciones Postman (`postman/`) | contrato de garantías, ventas/roles/taller contra Supabase |

## 6. Qué probar a mano (recorrido por rol, con sitio desplegado)

- **RECEPCION:** registrar una garantía (plazo 7/15). Un plazo distinto debe rechazarla si no es ADMIN/JEFE. Subir foto + documento y verlos en la garantía.
- **TODOS:** buscar en Consulta por serial, cédula, factura y orden; leer la ficha (cobertura, días restantes, insignia de Ventas, historial).
- **TECNICO:** abrir una orden desde la Consulta: completar la auditoría (un «No» cuenta), subir fotos; avanzar RECIBIDO → EN_DIAGNOSTICO (exige foto) y hasta Presupuestado si es de pago (exige monto). Probar el borrador de 24 h y el reintento de adjuntos.
- **JEFE_SERVICIO:** asignar técnico; rechazar una orden **sin** motivo (debe fallar) y con motivo; entregarla; confirmar y desestimar una compra `TALLER`; importar ventas y ver que la garantía TALLER se confirma sola.
- **ADMIN:** fijar «otro plazo» distinto de 7/15; crear/invitar usuarios y cambiar roles; administrar el catálogo del Inventario (crear, corregir, desactivar) y ver la cascada reflejada en Nueva garantía.
- **Negativos:** un usuario sin perfil o sin MFA no ve datos; serial repetido rechazado; fecha futura rechazada; presupuesto en garantía no requiere monto.
- **Login:** el código llega por correo; con dos usuarios cada uno recibe el suyo (pendiente de verificar el dominio en Resend, ver D11).

## 7. Documentación relacionada

- [Cambio de máquina / dependencias](INSTALAR_EN_OTRA_MAQUINA.md)
- [Cambios de la fase 2a](CAMBIOS_FASE_2A.md) — modelo de datos y RPC completos
- [Pendientes](PENDIENTES.md) — despliegue real, decisiones y deuda
- [Contrato del frontend de Ventas](CONTRATO_VENTAS_FRONTEND.md)
- [Diseño de pantallas](diseno-ui/README.md) — ocho maquetas HTML
- [Estado del proyecto](../ESTADO_DEL_PROYECTO.md)