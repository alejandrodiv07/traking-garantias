# Fase 2a — Registro de garantía, Consulta y Taller — Diseño

**Fecha:** 2026-10-30 · **Proyecto:** Prime Telecom · Track Garantía
**Estado:** diseño aprobado en conversación (secciones 1 a 4); pendiente de revisión del spec escrito.
**Parte de:** Fase 2 (2a núcleo · 2b facturas de Ventas por CSV · 2c enlace público y alertas). Este documento cubre solo **2a**.
**Base:** Hito 1 (`docs/REPORTE_HITO_1.md`; spec `2026-10-29-registro-y-control-de-garantia-design.md`).
**Referencia visual:** `Prime Telecom — Garantías.pdf` (pantallas de Tablero, Consulta, Orden y seguimiento público).

---

## 1. Objetivo

Separar en tres módulos relacionados por el serial lo que el Hito 1 mezcló en un solo asistente:

1. **Registro de garantía** (post-venta): cliente, contacto para alertas, serial, factura y plazo. No revisa el equipo.
2. **Consulta de garantía** (puerta de entrada del taller): se busca por serial, cédula/RIF, factura u orden; el sistema dice si el equipo está en vigencia y cuántos días quedan, y desde ahí se abre la orden.
3. **Taller**: la orden de servicio `OS-AAAA-NNNN`, con la **auditoría de recepción** (caja, precintos, señales de golpe o humedad), documentos vinculados y la barra de estados hasta la entrega.

**Criterio de éxito:** una garantía registrada en la venta se consulta por serial y muestra su vigencia; con un equipo en el mostrador se abre una orden que fija la cobertura según la auditoría; la orden avanza por sus estados con las reglas de negocio impuestas por la base; y un serial no registrado se puede registrar y atender sin abrir un hueco para garantías falsas.

## 2. Alcance

**Dentro (2a):** migración de modelo (renombrado y reglas nuevas); registrar garantía; Consulta; abrir orden con auditoría de recepción; detalle de la orden (resumen, auditoría, diagnóstico y presupuesto, documentos, bitácora); cambio de estado, asignación de técnico, rechazo; menú de navegación; pruebas SQL, de frontend y e2e.

**Fuera, con su fase:** facturas de Ventas por CSV (2b); enlace público de seguimiento y alertas de vencimiento por correo (2c); pestaña Piezas, Prioridad, categoría del equipo, imprimir factura y botones de enlace/WhatsApp del PDF (diferidos); pantallas Clientes y Notificaciones del menú (2c).

## 3. Vocabulario

| Término | Significa |
|---|---|
| **Garantía** | La fila de `equipos`: serial, titular, factura, plazo y vencimiento. Existe una sola vez por unidad. |
| **Orden** | Cada ingreso del equipo al taller (`ordenes_servicio`, antes `registros`). Un equipo puede tener varias. |
| **Auditoría de recepción** | La primera revisión (`RECEPCION`) de la orden, con checklist y fotos. Es inmutable. |
| **Origen** | `VENTA` (registrada al vender) o `TALLER` (registrada desde Consulta porque no existía). |
| **Tipo de atención** | `GARANTIA`, `PAGO` o `PENDIENTE`, derivado de la cobertura. |

## 4. Reglas de negocio

### 4.1 Origen y confianza de la garantía
- Una garantía de origen `VENTA` queda `EN_GARANTIA` de inmediato (si la fecha y el plazo lo permiten). Se confía en el punto de venta; el autor queda en `registrado_por`.
- Una garantía de origen `TALLER` queda `POR_DETERMINAR` hasta que ADMIN o JEFE_SERVICIO la **confirme** contra la venta real (`confirmar_compra`) o la **desestime** (`desestimar_compra`, motivo obligatorio).
- El **plazo** es 7 o 15 días. Cualquier otro valor (1–365) solo lo fija ADMIN o JEFE_SERVICIO. Un TECNICO o RECEPCION que lo intente es rechazado.
- Con 2b, la factura se validará contra la tabla de ventas y la confirmación de `TALLER` pasará a ser automática cuando coincida.

### 4.2 Cobertura (`calcular_cobertura`, función pura y única fuente de verdad)
Precedencia, de arriba abajo (cambios del Hito 1 marcados con ▲):

1. ▲ La compra fue **desestimada** → `FUERA_DE_GARANTIA` (con el motivo guardado en el equipo).
2. El equipo no tiene fecha de vencimiento (sin factura) → `POR_DETERMINAR`.
3. ▲ Origen `TALLER` y compra sin confirmar → `POR_DETERMINAR`.
4. `fecha_ingreso > vence_el` → `FUERA_DE_GARANTIA`.
5. La revisión incumple un término del equipo o marca señal de causa externa → `ANULADA_POR_USO` (motivo obligatorio).
6. La revisión incumple una condición del trámite → `POR_DETERMINAR`.
7. Cualquier otro caso → `EN_GARANTIA`.

La checklist y los términos son los de §4.3 del spec del Hito 1 (sin cambios). El cliente nunca envía el resultado.

### 4.3 Tipo de atención (columna generada de la cobertura)
| Cobertura | Tipo de atención |
|---|---|
| `EN_GARANTIA` | `GARANTIA` |
| `FUERA_DE_GARANTIA`, `ANULADA_POR_USO` | `PAGO` |
| `POR_DETERMINAR` | `PENDIENTE` |

### 4.4 Rama de pago y presupuesto
- El presupuesto reutiliza la máquina de estados existente: `EN_DIAGNOSTICO → PRESUPUESTADO → EN_REPARACION` (cliente acepta) o `→ RECHAZADO_POR_CLIENTE`. La decisión del cliente es la propia transición; la bitácora (`historial_ordenes`) ya registra quién y cuándo.
- El monto es `costo_reparacion` (ya existe; el `CHECK` actual lo impide con cobertura `EN_GARANTIA`). No se crean columnas de presupuesto.
- Alcance mínimo: monto y decisión. Propuesta formal en PDF, versiones y piezas quedan fuera.
- Si una confirmación posterior vuelve la cobertura `EN_GARANTIA` con un presupuesto cargado, la base limpia `costo_reparacion` y lo anota en el comentario de la bitácora.

### 4.5 Reglas de avance (las impone la base, no la interfaz)
- **→ `EN_DIAGNOSTICO`:** la auditoría de recepción debe tener al menos una foto. Si el equipo es de origen `TALLER` y la compra no está confirmada, debe haber además al menos un documento (la factura presentada).
- **→ `PRESUPUESTADO`:** requiere `costo_reparacion` cargado.
- **`EN_DIAGNOSTICO → EN_REPARACION`:** solo si `tipo_atencion = GARANTIA`. En `PAGO` el camino obligatorio pasa por `PRESUPUESTADO`; en `PENDIENTE` no se avanza hasta resolver la cobertura.
- **→ `RECHAZADO`:** motivo obligatorio (§5.2).
- Si la cobertura cambia con la orden ya en reparación, el estado no retrocede: la orden recibe un comentario en la bitácora y la insignia de atención se actualiza.

### 4.6 Estado nuevo `RECHAZADO`
Terminal por decisión del taller (el jefe decide no atender, por ejemplo con garantía anulada por uso). Distinto de `RECHAZADO_POR_CLIENTE` (el cliente no aprobó el presupuesto) y de `ANULADO` (orden creada por error). Se alcanza desde `RECIBIDO`, `EN_DIAGNOSTICO` o `PRESUPUESTADO`, solo por ADMIN o JEFE_SERVICIO. Su única salida es `ENTREGADO` (devolución sin reparar), permitida a ADMIN, JEFE_SERVICIO y RECEPCION.

### 4.7 Vigencia, urgencia y SLA
Sin cambios respecto al Hito 1 (§4.1, §4.5 y §4.6 de su spec): la garantía corre desde la fecha de emisión, `hoy_local()` en `America/Caracas`, urgencia combinada vigencia + SLA, vigencia que solo cuenta mientras la cobertura es `EN_GARANTIA` o `POR_DETERMINAR`.

## 5. Modelo de datos (migración 0013, hacia adelante)

Los datos existentes son de prueba; se renombra y se agrega, sin conservar datos. **La 0013 se ejecuta primero y sola**: renombrado mecánico, con todas las pruebas migradas y en verde, antes de añadir comportamiento.

### 5.1 Renombrado
| Antes | Después |
|---|---|
| `registros` | `ordenes_servicio` |
| `numero_registro` (`REG-AAAA-NNNNNN`) | `numero_orden` (`OS-AAAA-NNNN`, mismo mecanismo de secuencia nativa) |
| `registros_numero_seq` | `ordenes_numero_seq` |
| `historial_registros` | `historial_ordenes` |
| columna `registro_id` en `revisiones`, `adjuntos`, `notas_internas`, `historial` | `orden_id` |
| `registrar_ingreso` | `abrir_orden` (y se divide, §6) |

`v_tablero` y todas las funciones que mencionen los nombres antiguos se reescriben con los nuevos. Las rutas de Storage pasan de `registros/{id}/…` a `ordenes/{id}/…` (políticas y limpiador de huérfanos incluidos).

### 5.2 Cambios con comportamiento
**`equipos`:** `origen` (`VENTA`/`TALLER`, NOT NULL), `registrado_por` (perfil), `compra_desestimada_por`, `compra_desestimada_en`, `compra_desestimada_motivo`. Restricciones: la desestimación va completa o nada, el motivo tiene al menos 10 caracteres, y confirmar y desestimar son excluyentes.

**`ordenes_servicio`:** `tipo_atencion` (columna generada, §4.3), `motivo_rechazo` con `CHECK` de que si `estado = 'RECHAZADO'` el motivo tiene al menos 10 caracteres; el motivo persiste tras pasar a `ENTREGADO` (un trigger impide borrarlo).

**Estados y transiciones:** se inserta `RECHAZADO` (terminal salvo `→ ENTREGADO`) y sus transiciones en `transiciones_estado`. Se cierran a `{TECNICO, JEFE_SERVICIO, ADMIN}` las transiciones del diagnóstico y la reparación que hoy tienen `NULL` (cualquier rol), con una excepción: `PRESUPUESTADO → EN_REPARACION` y `PRESUPUESTADO → RECHAZADO_POR_CLIENTE` (la decisión del cliente, §7) quedan abiertas también a RECEPCION. El trigger de validación de transición se amplía con las reglas de §4.5.

**Se conserva sin cambios de esquema:** `revisiones` y `adjuntos` (solo de anexar, también para `service_role`), `notas_internas`, `clientes`, `productos`, `ajustes`, la tabla de estados y el módulo MFA.

## 6. Funciones (RPC)

Todas `SECURITY DEFINER` con `search_path` fijo, validando `mi_rol()`.

| Función | Quién | Qué hace |
|---|---|---|
| `registrar_garantia(cliente, producto, serial, soporte, número, fecha_emisión, plazo, origen)` | roles internos | Crea el equipo y reutiliza el cliente; sin orden. `origen = TALLER` solo lo usa el flujo de Consulta. Plazo ≠ 7/15 → solo ADMIN/JEFE. |
| `buscar_equipo(criterio)` | roles internos | Busca por serial (todos los productos), cédula/RIF, factura o número de orden; devuelve vigencia, titular e historial de órdenes. |
| `abrir_orden(equipo, falla, accesorios, checklist, clave_envio)` | roles internos | **Una transacción:** crea la orden y su revisión de recepción; la cobertura la calcula la base. Idempotente por `clave_envio` (se conserva el mecanismo `0012`). Devuelve el código de consulta una vez. |
| `confirmar_compra(equipo, …)` | ADMIN, JEFE | Ratifica la garantía `TALLER` (o completa la que no tenía factura); recalcula las órdenes abiertas. Debe aceptar un equipo con soporte ya cargado. |
| `desestimar_compra(equipo, motivo)` | ADMIN, JEFE | Marca la compra como no válida; las órdenes abiertas pasan a `PAGO`. Nada se borra. |
| `registrar_revision(orden, checklist, observaciones)` | ADMIN, JEFE, TECNICO | Revisión técnica posterior (se conserva). |
| `registrar_presupuesto(orden, monto)` | ADMIN, JEFE, TECNICO | Fija `costo_reparacion` (solo con `tipo_atencion = PAGO`). |
| `cambiar_estado(orden, estado, comentario, motivo)` | según matriz | Única vía de cambio de estado; aplica §4.5 y los roles de la tabla de transiciones. |
| `asignar_tecnico(orden, técnico)` | ADMIN, JEFE | Asigna o reasigna; queda en la bitácora. |

**Atomicidad:** la orden y su auditoría de recepción son transaccionales. Las fotos y documentos viven en Storage y se suben después, con el reintento de adjuntos del Hito 1; la regla de §4.5 impide avanzar sin ellos y `limpiar-huerfanos` retira los archivos sin fila.

## 7. Permisos

| Acción | ADMIN | JEFE | TECNICO | RECEPCION |
|---|---|---|---|---|
| Consultar garantías y órdenes | ✅ | ✅ | ✅ | ✅ |
| Registrar garantía (`VENTA` o `TALLER`) | ✅ | ✅ | ✅ | ✅ |
| Plazo distinto de 7 o 15 días | ✅ | ✅ | ❌ | ❌ |
| Confirmar o desestimar compra | ✅ | ✅ | ❌ | ❌ |
| Abrir orden (con auditoría de recepción) | ✅ | ✅ | ✅ | ✅ |
| Revisión técnica posterior | ✅ | ✅ | ✅ | ❌ |
| Diagnóstico y presupuesto | ✅ | ✅ | ✅ | ❌ |
| Registrar decisión del cliente sobre el presupuesto | ✅ | ✅ | ✅ | ✅ |
| Asignar técnico | ✅ | ✅ | ❌ | ❌ |
| Avanzar diagnóstico y reparación | ✅ | ✅ | ✅ | ❌ |
| Marcar `ENTREGADO` | ✅ | ✅ | ❌ | ✅ |
| `RECHAZADO` o `ANULADO` | ✅ | ✅ | ❌ | ❌ |
| Editar o borrar revisiones y adjuntos | nadie | nadie | nadie | nadie |
| Cualquier acceso sin sesión (`anon`) | ❌ | ❌ | ❌ | ❌ |

Se mantienen las reglas del Hito 1: lecturas solo para roles internos, `UPDATE` directo limitado a columnas no críticas, cambios de estado/presupuesto/asignación solo por RPC.

## 8. Interfaz

**Menú** (del PDF): Tablero · Ventas & Garantías · Taller. Clientes y Notificaciones quedan para 2c.

| Ruta | Pantalla |
|---|---|
| `/tablero` | KPIs, órdenes por urgencia y panel "Garantías por vencer"; el botón "Nueva orden" lleva a Consulta |
| `/garantias/nueva` | Asistente de 3 pasos: Cliente (búsqueda por documento), Equipo y compra, Resumen. Sin falla, checklist ni fotos |
| `/garantias/consulta` | Buscador único y resultado: cobertura con color, días restantes, línea de tiempo, titular, historial de órdenes |
| `/taller` | Lista de órdenes con filtro por estado |
| `/taller/nueva?equipo=…` | Abrir orden: datos del equipo (solo lectura), falla, accesorios, auditoría de recepción con fotos y documentos |
| `/taller/:id` | Detalle: encabezado con número, estado, insignia de cobertura y de atención; barra de estados; pestañas Resumen · Auditoría · Diagnóstico y presupuesto · Documentos · Bitácora; acciones Avanzar, Rechazar, Asignar técnico según rol |

**Consulta, comportamiento:**
- "Abrir orden de servicio" está siempre disponible; si la garantía está vencida, anulada o por determinar, avisa antes de continuar ("se atenderá como servicio pago" / "cobertura pendiente de confirmar").
- Serial inexistente: "No hay garantía registrada" y la opción **Registrar ahora** (`origen = TALLER`), que encadena directamente con Abrir orden y exige adjuntar la factura presentada en esa orden.
- Muestra el motivo vigente cuando la compra fue desestimada o la orden rechazada.

**Barra de estados:** Recibido → En diagnóstico → (Presupuestado, solo en pago) → En reparación → Reparado → Entregado. El "Diagnosticado" del PDF es una etapa visual (diagnóstico cargado), no un estado nuevo. Los laterales (En espera de repuesto, Irreparable, Rechazado por cliente, Rechazado, Anulado) se muestran como insignias.

**Reutilización del Hito 1:** `PasoCliente`, `PasoCompra`, `PasoVerificacion`, `PasoAdjuntos`, borrador local de 24 h, reintento de adjuntos, `Tablero`, `HistorialRevisiones` y `RevisionForm`. El asistente de seis pasos se reparte entre "Registrar garantía" y "Abrir orden".

**Motivos obligatorios:** al rechazar una orden y al desestimar una compra la interfaz pide un texto (mínimo 10 caracteres), con el mismo mínimo en la base. El motivo es de uso interno; cuando llegue 2c se definirá un texto separado, apto para el cliente.

## 9. Estrategia de pruebas

**Regla heredada:** nada de código sin una prueba que haya fallado antes por la razón esperada.

| Capa | Qué se prueba |
|---|---|
| SQL (`supabase/tests/`) | Las 237 aserciones del Hito 1 migradas a los nombres nuevos; cobertura con el nuevo orden de precedencia; reglas de avance de §4.5; `RECHAZADO` sin motivo falla; `RECHAZADO → ENTREGADO` para los cuatro roles; matriz de permisos de §7 y `anon`; plazo de 30 días rechazado a TECNICO y aceptado a JEFE; `abrir_orden` idempotente y con checklist incompleto rechazado; revisiones y adjuntos sin `UPDATE`/`DELETE`/`TRUNCATE` ni con `service_role` |
| Casos de cobertura | `TALLER` sin confirmar → `POR_DETERMINAR`; confirmar → `EN_GARANTIA`; desestimar → `FUERA_DE_GARANTIA` y órdenes abiertas a `PAGO`; confirmación con presupuesto cargado limpia el costo |
| Frontend (vitest) | Cada pantalla y servicio nuevo; Consulta por los cuatro criterios y serial inexistente; botón de avanzar según rol y reglas; motivo obligatorio |
| e2e (`scripts/e2e-registro.sh`) | Registrar garantía → consultar → abrir orden → auditoría con mal uso → `ANULADA_POR_USO` → rechazar con motivo → entregar |

**Definición de terminado de cada tarea:** prueba vista en rojo, código mínimo, suite completa en verde, lint y build limpios, y cualquier fallo preexistente reportado por su nombre.

## 10. Orden de construcción

1. **Migración 0013 de renombrado, sola**, con las pruebas SQL y de frontend ya migradas y en verde.
2. Columnas y reglas nuevas de modelo (§5.2): `equipos`, `ordenes_servicio`, estado `RECHAZADO`, transiciones, `calcular_cobertura`.
3. Funciones RPC (§6) en este orden: `registrar_garantia`/`buscar_equipo`, `abrir_orden`, `confirmar_compra`/`desestimar_compra`, `cambiar_estado`/`asignar_tecnico`/`registrar_presupuesto`.
4. Frontend: layout y menú, Registrar garantía, Consulta, Abrir orden, Detalle de la orden, lista de Taller y Tablero.
5. e2e actualizado y documentación (README y `ESTADO_DEL_PROYECTO.md`).

## 11. Riesgos y decisiones

- **Hito 1 sin cerrar.** El PR #1 está en borrador y el reporte lista condiciones de despliegue (historial remoto de migraciones, Edge Functions, limpieza programada, dominio de Resend). Recomendación: cerrar y desplegar el Hito 1 antes de aplicar la 0013. Si el remoto aplicó la `0008` original, la 0013 debe incluir también la corrección de adjuntos (DEFAULT de `subido_por` y políticas de Storage).
- **El renombrado toca todo** (237 aserciones SQL, 182 pruebas de frontend, políticas de Storage). Mitigación: hacerlo primero y solo (§10).
- **Roles del PDF** (VENDEDOR, SUPERVISOR) no coinciden con los del sistema; 2a usa los cuatro roles existentes.
- **`confirmar_compra` actual** se escribió para completar una factura ausente; debe verificarse en la implementación que admita ratificar un equipo con soporte ya cargado.
- **Resend en modo de pruebas:** bloquea las alertas de 2c, no 2a.
- **Segunda fuente de verdad:** hasta 2b, la factura de una garantía `VENTA` es lo que teclea quien registra; la protección es la bitácora de autor y el plazo restringido.

## 12. Decisiones tomadas

Tres módulos independientes unidos por el serial; `equipos` es la garantía registrada y `registros` pasa a `ordenes_servicio`; cualquier rol interno registra garantías; serial no hallado → registrar ahí mismo con origen `TALLER` y confirmación administrativa; `VENTA` confiable de inmediato; plazo de 7 o 15 días salvo ADMIN/JEFE; mal uso → la orden sigue sin garantía y el jefe decide, con estado `RECHAZADO` y motivo obligatorio; presupuesto mínimo sobre los estados existentes; la orden y su auditoría son una transacción, y las fotos condicionan el avance; renombrado de la base en una migración aislada.
