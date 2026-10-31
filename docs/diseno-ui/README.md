# Diseño de pantallas — Prime Telecom · Track Garantía

**Para:** el agente que construye el frontend y el backend.
**Fecha:** 2026-10-30 · **Estado:** diseño aprobado por pantalla (maquetas HTML); el login ya está hecho.
**Base:** `docs/superpowers/specs/2026-10-30-fase-2a-garantia-consulta-taller-design.md` (reglas de negocio y RPC). Este documento no lo reemplaza: dice cómo se ven y se comportan las pantallas.

---

## 1. Cómo usar este paquete

Las ocho maquetas están en [`pantallas/`](pantallas). Son archivos HTML **autónomos**: se abren con doble clic en el navegador, con datos de ejemplo y toda la interacción funcionando (filtros, formularios, validaciones, diálogos).

- **Son la referencia de diseño y de comportamiento, no código para copiar.** Están escritas en JavaScript plano. El proyecto real es React 19 + Vite + Tailwind 4 + CSS propio; hay que reconstruirlas con sus componentes.
- Los datos son inventados. Los números de orden, fechas y clientes salen de una fecha de hoy fija (**30 oct 2026**).
- Cada maqueta repite la barra lateral. En el proyecto es un único componente de layout.
- Un selector "Ver como" (rol) aparece arriba en varias pantallas. Es solo para probar permisos en la maqueta; en producción el rol sale de `profiles` bajo RLS.

| Archivo | Ruta sugerida | Sidebar |
|---|---|---|
| `01-garantias-tablero.html` | `/garantias` | Garantías |
| `02-nueva-garantia.html` | `/garantias/nueva` | Garantías |
| `03-consulta.html` | `/garantias/consulta` (y `?q=`) | Garantías |
| `04-taller.html` | `/taller`, `/taller/nueva`, `/taller/:id` | Taller |
| `05-entregas.html` | `/entregas` | Entregas |
| `06-inventario.html` | `/inventario` | Inventario |
| `07-reportes.html` | `/reportes`, `/reportes/:serial` | Reportes |
| `08-clientes.html` | `/clientes`, `/clientes/:id` | Clientes |
| (pendiente) | `/notificaciones` | Notificaciones |

`04`, `07` y `08` contienen varias vistas dentro del mismo archivo (lista, detalle, asistente); en el router real son rutas separadas.

---

## 2. Sistema visual

Se **conserva el que ya tiene el proyecto** (`frontend/src/styles/tokens.css`): papel crema, tinta casi negra y un único acento terracota, con modo oscuro. Las maquetas usan los mismos valores. No inventar colores nuevos: cambiar un color se hace solo en `tokens.css`.

- **Tipografía:** Inter (400, 500, 600, 700). Números de tabla con `font-variant-numeric: tabular-nums`; seriales, facturas y números de orden en fuente monoespaciada.
- **Estados con cuatro tonos** (ya existen en tokens): `neutro`, `progreso` (ámbar), `resuelto` (verde), `adverso` (rojo). Un estado **nunca** se comunica solo con color: siempre lleva texto (y punto o icono).
- **Radios:** tarjetas 14 px, controles 10 px, píldoras 999 px. Botones y campos de **44 px** de alto mínimo.
- **Foco:** anillo visible en todo. **Movimiento:** respetar `prefers-reduced-motion`.
- **CSP del proyecto:** `style-src 'self'` sin `unsafe-inline`. En React **no usar atributos `style`**; el ancho de una barra o un color variable se expresa con clases o variables CSS escritas desde una hoja. (Las maquetas sí usan `style` en pocos sitios, solo porque corren en un visor aparte.)
- **Móvil (≤ 900 px):** la barra lateral pasa a cajón; las tablas pasan a fichas con la etiqueta de cada dato.

### Barra lateral (fija)
Marca "Prime Telecom", botón para plegar a iconos (recuerda la preferencia), siete destinos con icono **y** texto (Garantías, Taller, Entregas, Inventario, Reportes, Clientes, Notificaciones), contador en Notificaciones, correo del usuario y "Cerrar sesión" abajo. El destino actual lleva fondo teñido, barra y `aria-current="page"`. Cada destino es `<NavLink>` (URL real, no estado local). Reemplaza al `BarraLateral.jsx` de 64 px actual y su menú "Tablero · Ventas y garantías · Taller · Clientes · Notificaciones".

---

## 3. Pantallas

### 01 · Tablero de garantías (`/garantias`)
Lista de **garantías registradas** (la fila de `equipos`). Indicadores: registradas, vigentes, vencen en 3 días, vencidas. Búsqueda por serial, cédula/RIF o factura + rango de fechas de emisión. Chips por estado: **Vigente · Por vencer (≤ 3 días) · Vencida · Por confirmar** (origen `TALLER` sin confirmar). Tabla con serial, titular, equipo, factura, emisión, vence (ordenable) y estado. Botón principal "Nueva garantía". Una fila abre la **Consulta (03)**.

### 02 · Nueva garantía (`/garantias/nueva`)
Solo el **registro posterior a la venta**; no revisa el equipo (eso es Taller). Asistente de 5 pasos con resumen en vivo a la derecha:
1. **Cliente:** tipo de documento + número, nombre, correo (obligatorio, a él llegan los avisos), teléfono opcional. Si el documento existe se traen sus datos.
2. **Productos:** uno o varios (marca → modelo del catálogo de Inventario + serial). Misma factura y plazo para todos; cada equipo genera su propia garantía. Rechaza serial repetido o ya registrado.
3. **Compra:** n.º de factura, fecha de emisión (no futura), plazo de **7 o 15 días**. Calcula y muestra el vencimiento y avisa si ya nació vencida. "Otro plazo" aparece bloqueado: solo ADMIN/JEFE_SERVICIO (`registrar_garantia`).
4. **Documentos:** factura escaneada y PDF de la venta con el plazo (recomendados, no obligatorios), fotos opcionales. PDF/JPG/PNG, 8 MB; fotos 8 máx., documentos 6 máx.
5. **Resumen:** repaso con "Editar" por sección y confirmación. Borrador local de 24 h (ya existe `borrador.js`).

### 03 · Consulta de garantía (`/garantias/consulta`)
Buscador único (serial, cédula/RIF, factura u orden → `buscar_equipo`). Resultado: ficha del equipo con **período de cobertura** (barra, días restantes, inicio y fin), documentos vinculados, órdenes del equipo y, a la derecha, el cliente y las acciones.
- Varios resultados → lista para elegir. Ninguno → "No hay garantía registrada" + **Registrar ahora** (origen `TALLER`).
- Estados: vigente, por vencer, vencida, **por confirmar** y **compra desestimada** (muestra el motivo).
- **Abrir orden de servicio** siempre disponible, con aviso previo según el estado ("se atenderá como servicio pago", "cobertura pendiente"). Si ya hay una orden abierta, lo avisa.
- Solo ADMIN/JEFE_SERVICIO: **Confirmar compra** y **Desestimar compra** (motivo ≥ 10 caracteres) → `confirmar_compra` / `desestimar_compra`.

### 04 · Taller (`/taller`, `/taller/nueva`, `/taller/:id`)
- **Lista:** indicadores, búsqueda, chips por estado y tabla (orden, cliente, equipo, atención, estado, abierta).
- **Nueva orden** (3 pasos, resumen en vivo): (1) buscar el equipo y **validar la vigencia**, o registrarlo ahí mismo (`TALLER`, queda por confirmar); (2) falla reportada (5–2000 caracteres) y accesorios; (3) **auditoría de recepción**.
  - Checklist: *Condiciones del trámite* (2 puntos), *Estado del equipo* (4 puntos), *Causas externas* (5 casillas). Cada punto lleva **Sí / No sin valor por defecto**, para no confundir "sin responder" con "no cumple".
  - La **cobertura se calcula en vivo** con la precedencia del spec §4.2 y muestra el tipo de atención. Si queda `ANULADA_POR_USO` pide motivo (≥ 10).
  - Fotos y documentos (el documento es requerido si el equipo es `TALLER` sin confirmar).
  - Todos los puntos de la auditoría son obligatorios para abrir la orden.
- **Detalle de la orden:** barra de estados (Recibido → En diagnóstico → *Presupuestado, solo en pago* → En reparación → Reparado → Entregado), insignias de estado/cobertura/atención y pestañas **Resumen · Auditoría · Diagnóstico y presupuesto · Documentos · Bitácora**. Aside: garantía, cliente, documentos, detalles (técnico asignable por Jefatura).
  - **Reglas de avance** (las impone la base, la interfaz solo las explica): a *En diagnóstico* hace falta ≥ 1 foto (y factura presentada si es `TALLER` sin confirmar); a *Presupuestado* hace falta monto; de diagnóstico a reparación solo en `GARANTIA`; en `PENDIENTE` no se avanza. Rechazar pide motivo y es solo de Jefatura. El resultado del diagnóstico (reparable / requiere repuesto / irreparable) decide el siguiente paso. Confirmar la compra recalcula la cobertura y limpia el presupuesto si pasa a garantía.

### 05 · Entregas (`/entregas`)
Salida del taller, derivada de las órdenes. **Tarjetas con barra de progreso** de la orden, en cuadrícula, con chips por etapa: **En proceso** (con plazo previsto editable y aviso de retraso) · **Listo para retirar** (días esperando, cobro pendiente, "Avisar al cliente") · **Por devolver sin reparar** (irreparable / rechazada) · **Entregado** (fecha, quién retiró, quién entregó). Búsqueda y rango de fechas de entrega.
- **Marcar entregado** (ADMIN, JEFE_SERVICIO, RECEPCION): quién retira, cédula/RIF, fecha y hora (no futura), accesorios devueltos (todos marcados), y confirmación del cobro si es servicio pago.

### 06 · Inventario (`/inventario`)
Catálogo oficial y stock. Pestañas **Productos** y **Repuestos del taller**. Tabla con producto, categoría, código, garantía del fabricante (meses), **stock con − / +**, estado (Disponible / Stock bajo / Agotado / Inactivo) y cuántas garantías lo usan. Indicadores, filtros y búsqueda.
- **Este catálogo valida los productos del sistema:** marca/modelo de *Nueva garantía* y *Nueva orden* salen de aquí, solo los **activos**. Un producto con garantías no se borra: se **desactiva** (la FK es `ON DELETE RESTRICT`).
- Validaciones: marca + modelo únicos, código único, meses 0–120, mínimo ≥ 0. Cada cambio de stock queda en un **historial de movimientos** (entrada/salida, cantidad, saldo, motivo, quién); una salida no puede superar el stock.
- **Importar desde PDF:** sube el PDF, muestra lo detectado fila por fila (nuevo / ya existe / falta la marca) y deja elegir si se suma, se reemplaza o se omite el stock. **La lectura del PDF está simulada** (ver §5).
- Permisos: stock lo mueven TECNICO y JEFE; catálogo (crear, editar, desactivar, importar) solo JEFE/ADMIN.

### 07 · Reportes (`/reportes`)
Centro de documentación y auditoría.
- **Expedientes:** uno por garantía, con **todos los documentos del registro y de sus órdenes** (factura, PDF de la venta, comprobante, orden, auditoría, fotos, diagnóstico, presupuesto, acta). Indica qué documentos clave faltan. Se pueden **generar** los documentos que el estado permite, agregar archivos y exportar el expediente (PDF/Excel). Pestaña "Informe de la garantía" con línea de tiempo.
- **Informes:** garantías registradas, por vencer, vencidas, órdenes, fallas, auditorías de recepción y entregas. Rango de fechas, formato PDF o Excel, vista previa e historial de lo generado.
- **Importar** (solo Jefatura): documentos a un expediente, o **garantías en lote desde CSV/Excel** con validación por fila (serial, cédula/RIF, nombre, factura, fecha, plazo 7/15). Alimenta lo que el spec llama 2b.

### 08 · Clientes (`/clientes`, `/clientes/:id`)
Tablero con indicadores y filtros (garantía por vencer, en taller, listos para retirar, sin correo). Cada fila: contacto, equipos, estado de garantía, orden en taller y último aviso. **Ficha:** cada equipo con su barra de cobertura y, si está en taller, su progreso; contacto; historial de avisos.
- **Notificar** al cliente: *Plazo de la garantía* o *Cómo va su equipo*. Mensaje redactado con los datos reales y editable; exige correo; avisa si ya se le notificó hoy (hay que confirmar para repetir). **Enviar recordatorios** avisa en lote a quienes vencen en ≤ 3 días.

---

## 4. Lo que falta en el backend

Las pantallas 01–04 se apoyan en las RPC del spec 2a. Lo siguiente **no existe aún** y lo necesitan las demás:

| Pantalla | Necesita |
|---|---|
| Entregas | Guardar **plazo previsto de entrega**, y los datos de la entrega (fecha y hora, quién retira, su documento, quién entrega, accesorios devueltos, cobro recibido, observaciones). Hoy `ENTREGADO` es solo un estado. |
| Inventario | **Stock** (hoy `productos` no tiene), **stock mínimo**, código interno, **movimientos de stock** (tabla de historial), y una tabla de **repuestos**. Importación del PDF en el servidor. |
| Reportes | Tipos de documento vinculados (hoy `adjuntos` distingue foto/documento y etiqueta), **generación de PDF** (comprobante, orden, auditoría, diagnóstico, presupuesto, acta), exportación a PDF/Excel y registro de lo generado. Importación en lote de garantías. |
| Clientes | Correo del cliente (ya existe `clientes.email`), **registro de avisos enviados** (a quién, qué, cuándo, quién, canal) y el envío de correos. |
| Notificaciones | Alertas automáticas de vencimiento (spec 2c) y su bandeja. |
| Taller | Diagnóstico con **resultado** (reparable / repuesto / irreparable) y plazo previsto. |

---

## 5. Qué está simulado en las maquetas

- **Descargas y exportaciones** (PDF, Excel, documentos): el visor bloquea las descargas; solo muestran un aviso. Lo único real es "Copiar tabla para Excel".
- **Envío de correos:** no se envía nada. El envío real depende de verificar el dominio en Resend (hoy en modo de pruebas, con destinatario fijo).
- **Lectura del PDF de inventario:** las filas detectadas son de muestra. El CSV de *Reportes → Importar* sí se lee de verdad.
- **Lectura de `.xlsx`:** no implementada en las maquetas.
- **Datos:** todo es de ejemplo.

---

## 6. Decisiones y diferencias con las capturas de referencia

- **Plazo en días, no en meses:** el ejemplo de la Consulta mostraba una garantía de 12 meses. El spec dice **7 o 15 días**; las maquetas usan días.
- **Fuera de esta entrega** (el spec los difiere): "Imprimir factura", "Enviar enlace de seguimiento", pestaña Piezas en la orden, Prioridad, categoría del equipo en la orden y el seguimiento público.
- **Lenguaje:** se quitó el texto técnico ("Descarga con JWT + rol" → "Descarga protegida por rol").
- **Roles de las maquetas** (Recepción, Técnico, Jefatura) corresponden a `RECEPCION`, `TECNICO` y `JEFE_SERVICIO`; `ADMIN` puede todo lo que puede Jefatura.
- La auditoría usa **Sí / No sin valor por defecto**, distinto del checklist de casillas anterior.

---

## 7. Pendiente

- **Pantalla Notificaciones** (`/notificaciones`): bandeja de alertas automáticas de vencimiento y estados. Sin diseñar todavía.
- **Inventario real:** en la carpeta del proyecto apareció `Catalogo-actualizado-Prime.pdf`, que no se ha revisado ni importado; probablemente es la fuente del inventario.
- Conectar todo a Supabase y reemplazar los datos de ejemplo.
- Revisar las maquetas en 375 px y en modo oscuro una vez construidas en React.
