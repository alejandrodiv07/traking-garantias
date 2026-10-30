# Registro y control de garantía — Diseño (Hito 1)

**Fecha:** 2026-10-29 · **Proyecto:** Prime Telecom · Track Garantía
**Estado:** aprobado. Incorpora la revisión del 2026-10-29 (serial único por producto, correlativo con secuencia, limpieza de huérfanos, borrador con caducidad, urgencia combinada con SLA, lector de código de barras).
**Origen:** investigación con el jefe de informática y 3 técnicos; condiciones y términos de garantía publicados en la web de la empresa; modelo de referencia Warracker (solo ideas, nunca código: es AGPL-3.0).

---

## 1. Objetivo

Que el **técnico** registre un equipo que ingresa por garantía (*Nuevo registro*) con producto, modelo, **serial**, fotos y los demás datos; que luego pueda **consultarlo de forma ordenada en el Tablero** viendo **cuántos días de vigencia le quedan a la garantía**; y que pueda anotar las **revisiones** donde se evalúa el producto.

**Criterio de éxito:** un técnico registra un equipo en pocos minutos, el equipo aparece en el Tablero ordenado por urgencia con sus días restantes, y registra una revisión cuyo resultado queda guardado y no se puede alterar.

## 2. Alcance

**Dentro (Hito 1):** cimientos y CI; modelo de datos; Nuevo registro con fotos y documentos; Tablero con datos reales; pantalla de Revisiones.

**Fuera (hitos siguientes):** consulta rápida de facturas emitidas por Ventas (tabla de ventas cargada por CSV; ver 4.4), seguimiento público para el cliente, reportes y exportación, carga masiva por CSV, avisos de vencimiento, administración de usuarios y catálogo, WhatsApp.

## 3. Vocabulario

| Término | Significa |
|---|---|
| **Equipo** | Una unidad física identificada por su **serial**, con su titular, su factura y su plazo de garantía. Se registra una sola vez. |
| **Registro** | Cada ingreso del equipo al taller. Lo crea el técnico con *Nuevo registro*. Un equipo puede tener varios registros. |
| **Revisión** | Una evaluación del producto con lista de verificación y resultado. Un registro tiene una o más. |
| **Vigencia** | Días que quedan hasta que vence la garantía del equipo. |

En pantalla se dice *Nuevo registro*; el código de un registro es `REG-AAAA-NNNNNN`.

## 4. Reglas de negocio

### 4.1 Vigencia
- La garantía **empieza en la fecha de emisión** de la factura o nota de entrega y dura **7 o 15 días** (el plazo que indica la factura). El sistema admite de 1 a 365 días.
- `vence_el = fecha_emisión + plazo_en_días`. El día de vencimiento **cuenta como vigente**.
- **Días restantes** = `vence_el − hoy`. "Hoy" se calcula en la zona horaria `America/Caracas`, con una función única `hoy_local()`, para que el cambio de día no dependa del servidor.

### 4.2 Cobertura
Se calcula con una función pura `calcular_cobertura(equipo, fecha_ingreso, última_revisión)` que es la **única fuente de verdad**. Precedencia, de arriba abajo:

1. El equipo no tiene fecha de vencimiento (se recibió sin factura) → `POR_DETERMINAR`.
2. `fecha_ingreso > vence_el` → `FUERA_DE_GARANTIA`.
3. La revisión incumple un **término del equipo** o marca una **señal de causa externa** → `ANULADA_POR_USO` (con motivo obligatorio).
4. La revisión incumple una **condición del trámite** → `POR_DETERMINAR` (el proceso de garantía se detiene).
5. En cualquier otro caso → `EN_GARANTIA`.

La cobertura de un registro se fija en su primera revisión (la de recepción) y cambia si una revisión posterior da otro resultado. **El cliente nunca envía el resultado:** lo calcula la base a partir de la lista de verificación.

### 4.3 Verificación (lista que guarda cada revisión)
- **Condiciones del trámite:** factura o nota presentada sin alteraciones; el titular que tramita coincide con el nombre de la factura.
- **Estado del equipo:** serial de fábrica legible; caja original; precintos de seguridad intactos; equipo sin abrir y con todo su contenido en buen estado.
- **Señales de causas externas:** descarga eléctrica, derrame de líquidos, altas temperaturas, golpes, manipulación de terceros.

### 4.4 Sin factura
Se **registra igual**, con `fecha_emisión` vacía y la cobertura `POR_DETERMINAR`, hasta que un ADMIN o JEFE_SERVICIO confirme la compra (con Ventas). Es lo que hoy ya ocurre en el taller.

La confirmación es **manual en este hito**. Una consulta rápida contra una tabla de facturas y notas de entrega emitidas queda para el hito siguiente, porque hoy no existe una fuente de datos de ventas que cargarla: primero hay que decidir cómo se alimenta (CSV desde Ventas). `confirmar_compra` ya deja registrado quién confirmó y cuándo, que es el gancho para esa integración.

### 4.5 Urgencia en el Tablero
| Nivel | Condición |
|---|---|
| Vencida | días restantes < 0 |
| Vence hoy | = 0 |
| Crítica | de 1 a 3 |
| Pronto | de 4 a 7 |
| Normal | más de 7 |
| Pendiente | sin fecha de vencimiento |

Los umbrales (3 y 7) se guardan en una tabla de ajustes que solo el ADMIN edita.

### 4.6 SLA de atención y urgencia combinada
La vigencia sola no basta: un equipo recién ingresado con la garantía vencida no debe esconder a otro que lleva muchos días en reparación. Cada registro **abierto** (no `ENTREGADO` ni `ANULADO`) tiene además `dias_en_taller = hoy − fecha_ingreso`:

| Nivel de SLA | Condición (ajustable) |
|---|---|
| Normal | menos de 7 días en el taller |
| Alerta | de 7 a 14 días |
| Crítico | 15 días o más |

La **urgencia combinada** es el peor de los dos niveles (el de vigencia y el de SLA), en una escala común de 0 a 4: normal 0; pronto o alerta 1; crítica o crítico 2; vence hoy 3; vencida 4. El Tablero ordena por ella y muestra las dos columnas por separado, para que se vea de dónde viene la alerta. Los registros cerrados no entran en este orden.

La vigencia **solo cuenta para la urgencia mientras la cobertura del registro sea `EN_GARANTIA` o `POR_DETERMINAR`**. Si el equipo ya ingresó fuera de garantía o con la garantía anulada, su fecha de vencimiento es informativa y no lo sube en el orden. Así un equipo recién ingresado con la garantía vencida no desplaza a uno que lleva 15 días en reparación.

## 5. Modelo de datos

Se hace con una **migración hacia adelante** (no se reescribe el historial ya aplicado): reemplaza el módulo de garantías actual, que no tiene datos reales que conservar, y deja `profiles`, el 2FA y los estados como están.

### 5.1 `equipos`
| Columna | Regla |
|---|---|
| `numero_serie` | **Obligatorio**, de 3 a 60 caracteres |
| `serie_normalizada` | Generada: mayúsculas, sin espacios ni guiones. **Única junto con `producto_id`** (índice único compuesto) |
| `producto_id` | Obligatorio, del catálogo |
| `cliente_id` | Obligatorio: es el titular de la factura |
| `tipo_soporte` | `FACTURA` o `NOTA_ENTREGA`; vacío si no hay soporte |
| `numero_soporte`, `fecha_emision`, `plazo_dias`, `vendedor` | Los dos primeros y `plazo_dias` van juntos o ninguno; `fecha_emision` entre 2000-01-01 y hoy |
| `vence_el` | Generada: `fecha_emision + plazo_dias` |
| `compra_confirmada_por/en` | Los llena un ADMIN o JEFE_SERVICIO al confirmar con Ventas |

La unicidad es **por producto**: dos fabricantes pueden emitir el mismo serial numérico corto (por ejemplo `100452`) sin bloquearse. Para no perder la protección contra errores de transcripción, `buscar_equipo(serial)` busca en **todos los productos** y, si el serial existe con otro producto, el asistente lo advierte ("este serial está registrado como X") antes de crear un equipo nuevo.

### 5.2 `registros` (reemplaza a `garantias`)
Equipo, falla reportada (5–2000), accesorios, estado (la misma máquina de 10 estados ya probada), técnico asignado, creador, fecha de ingreso y de entrega, **cobertura**, motivo de anulación, costo de reparación y el código de consulta (solo su hash). Si quien registra es un TECNICO, queda asignado a ese técnico.

El correlativo `REG-AAAA-NNNNNN` sale de una **`SEQUENCE` nativa** (`registros_numero_seq`) usada como valor por defecto de la columna. `nextval` es atómico: dos técnicos que registren en el mismo segundo reciben números distintos, sin carreras ni colisiones. Pueden quedar huecos en la numeración si una transacción se revierte; se acepta, porque lo que importa es que sea único.

### 5.3 `revisiones`
Registro, tipo (`RECEPCION` o `TECNICA`), revisor, fecha, **lista de verificación** (jsonb con las claves de 4.3, validada por una restricción), **resultado** (calculado por la base, nunca enviado por el cliente) y observaciones. **Solo de anexar:** una corrección es una revisión nueva. Triggers `BEFORE UPDATE OR DELETE` (por fila) y `BEFORE TRUNCATE` (por sentencia) lanzan un `RAISE EXCEPTION` explícito con un mensaje claro. Los triggers se aplican también a `service_role` y al propietario de la base, que sí se saltan la seguridad por filas: es la garantía de auditabilidad ante un cliente o una disputa.

### 5.4 `adjuntos`
Registro (y opcionalmente revisión), tipo (`FOTO` o `DOCUMENTO`), etiqueta, ruta en el almacenamiento, tipo MIME, tamaño, quién lo subió y cuándo. **No se borra.** Límites aplicados en la base: fotos JPG, PNG o WEBP de hasta 8 MB, hasta 8 por registro; documentos PDF, JPG o PNG de hasta 8 MB, hasta 6 por registro. Los archivos van a un bucket **privado** de Supabase Storage, con política por ruta `registros/{registro_id}/…`. La tabla `adjuntos` tiene los mismos triggers de inmutabilidad que `revisiones` (UPDATE, DELETE y TRUNCATE).

### 5.5 Funciones
- `buscar_equipo(serial)`: devuelve el equipo con su titular, vigencia e historial de registros.
- `registrar_ingreso(...)`: en una sola transacción crea o reutiliza el equipo, crea el registro y su **primera revisión (recepción)**, y devuelve el código de consulta una única vez.
- `registrar_revision(registro, checklist, observaciones)`: añade una revisión.
- `confirmar_compra(equipo, soporte, número, fecha_emisión, plazo_días)`: solo ADMIN y JEFE_SERVICIO. Completa los datos de factura que faltaban (con lo que confirmó Ventas), deja registrado quién y cuándo, y recalcula la cobertura de los registros abiertos del equipo.
- `calcular_cobertura(...)`, `hoy_local()`.

### 5.6 Vista del Tablero
`v_tablero` con `security_invoker`: una fila por registro, con días restantes, nivel de urgencia por vigencia, `dias_en_taller`, nivel de SLA, **urgencia combinada** (4.6), cobertura, estado, titular, equipo y serial. Orden: registros abiertos por urgencia combinada y luego por fecha de ingreso; después los cerrados.

### 5.7 Limpieza de archivos huérfanos
Si una foto se sube bien pero la conexión cae antes de guardar su fila en `adjuntos`, el archivo queda sin referencia en el bucket. Una **Edge Function programada** (diaria, con `pg_cron`) lista los objetos del bucket privado y elimina los que **no tienen fila en `adjuntos` y tienen más de 24 horas**, para no tocar subidas en curso. Es lo único que borra archivos, y solo borra de almacenamiento: las filas de `adjuntos` nunca se tocan. Tiene un modo de simulación que solo informa qué borraría, y registra cada ejecución.

## 6. Permisos

| Acción | ADMIN | JEFE_SERVICIO | TECNICO | RECEPCION |
|---|---|---|---|---|
| Ver registros, equipos y revisiones | ✅ | ✅ | ✅ | ✅ |
| Crear registro (`registrar_ingreso`) | ✅ | ✅ | ✅ | ✅ |
| Registrar revisión | ✅ | ✅ | ✅ | ❌ |
| Confirmar compra | ✅ | ✅ | ❌ | ❌ |
| Cambiar estado | según las políticas actuales | | | |
| Editar o borrar revisiones y adjuntos | nadie | | | |
| Cualquier acceso sin sesión (`anon`) | ❌ | | | |

Cambio respecto a hoy: el TECNICO **sí** puede crear registros. La función `crear_garantia` actual se lo impedía.

## 7. Interfaz

### 7.1 Nuevo registro (asistente en ventana)
Se abre desde el botón del Tablero. Seis pasos:
1. **Equipo:** se escribe primero el **serial**. El campo recibe el foco al abrir el asistente y la búsqueda se dispara con **Enter** o tras una **pausa de 400 ms** sin teclear (con al menos 3 caracteres), de modo que una pistola lectora de código de barras o QR, que escribe como un teclado y termina con Enter, funcione sin tocar nada. Enter en este campo no envía el formulario. Si ya existe, se muestran sus datos y su historial y se reutilizan (no se recapturan titular, factura ni plazo). Si es nuevo, se piden marca y modelo.
2. **Cliente:** titular, con búsqueda por cédula, RIF o pasaporte.
3. **Compra:** soporte, número, fecha de emisión y plazo (7 o 15 días; otro valor disponible). Casilla "no trae la factura". Se omite cuando se reutiliza un equipo.
4. **Verificación:** la lista de 4.3 con el resultado de cobertura en vivo, calculado por `calcular_cobertura`.
5. **Fotos y documentos:** opcional, con cámara o archivo.
6. **Resumen:** revisión de todo con "Editar" por sección.

### 7.2 Borrador y conexión
El asistente guarda un **borrador** en el navegador (sin los archivos) y lo ofrece recuperar tras un corte de internet o un cierre accidental. El borrador **caduca a las 24 horas**, se borra al completar el registro y al cerrar sesión, y se guarda con la clave del usuario, porque las laptops del taller son compartidas y el borrador contiene datos personales del cliente. Si la subida de archivos falla, el registro ya existe y se ofrece reintentar solo los adjuntos pendientes.

### 7.3 Tablero
Lista ordenada por urgencia con los **días restantes**, búsqueda por serial, cliente, cédula, número de factura y número de registro, y filtros por estado y por urgencia. Los datos de demostración desaparecen.

### 7.4 Revisiones
Dentro del detalle del registro: historial de revisiones y formulario para añadir una nueva con la misma lista de verificación y observaciones.

## 8. Estrategia de pruebas (obligatoria en todo el hito)

**Regla:** nada de código sin una prueba que haya fallado antes, por la razón esperada.

| Capa | Qué se prueba | Herramienta |
|---|---|---|
| Base de datos | Tabla de más de 15 casos de `calcular_cobertura`; unicidad y normalización del serial; vencimiento generado; restricciones de la lista de verificación; revisiones y adjuntos inmutables; límites de adjuntos | Scripts SQL en `supabase/tests/` |
| Permisos | Matriz de la sección 6: cada rol puede lo suyo y no puede lo ajeno, y `anon` no accede a nada | Scripts SQL con roles reales |
| Edge Functions | Cada respuesta lleva CORS; errores controlados | vitest con `Deno` simulado |
| Frontend | Servicios, cada paso del asistente, orden del Tablero por urgencia, borrador | vitest y Testing Library |
| Integración | Registrar → aparece en el Tablero → añadir revisión, contra una base local | Script de punta a punta |

**Casos límite que deben existir:** día exacto de vencimiento; plazo de 7 y de 15 días; ingreso un día después del vencimiento; factura sin fecha; serial repetido con distinto formato (`rt5-8842-aa` frente a `RT5 8842 AA`); mismo serial en dos productos distintos (permitido, con advertencia); dos registros seguidos con correlativos distintos; `UPDATE`, `DELETE` y `TRUNCATE` sobre revisiones y adjuntos, también con `service_role`; cambio de día en `America/Caracas`; urgencia combinada (equipo recién ingresado con garantía vencida frente a equipo con 15 días en taller); lector de código de barras (escritura rápida más Enter); borrador de 24 horas (vigente, caducado, borrado al terminar y al cerrar sesión); limpieza de huérfanos (no borra objetos con menos de 24 horas ni objetos con fila en `adjuntos`; el modo simulación no borra nada).

**Definición de terminado de cada tarea:** prueba vista en rojo, código mínimo, suite completa en verde, lint y build limpios, y cualquier fallo preexistente reportado por su nombre.

## 9. Orden de construcción

1. **Cimientos:** reconciliar el historial de migraciones (`supabase migration list --linked`), archivar el monolito duplicado, datos iniciales de marcas y productos, README y **CI** (GitHub Actions: pruebas SQL, vitest, lint y build).
2. **Modelo de datos:** tablas, funciones, vista, permisos y todas sus pruebas SQL.
3. **Nuevo registro** conectado, con fotos y documentos.
4. **Tablero** con datos reales.
5. **Revisiones.**
6. **Limpieza de archivos huérfanos** (5.7).

## 10. Riesgos y decisiones

- **Internet inestable en el taller:** mitigado con el borrador local y el reintento de adjuntos.
- **PC compartido:** la sesión de 12 horas y el 2FA por correo se revisan al conectar el login a este flujo.
- **Resend en modo de pruebas:** el código 2FA solo llega a una dirección hasta verificar un dominio propio.
- **Tesis:** el análisis del ítem 10 cita Python y MySQL; el sistema real usa React y Supabase (PostgreSQL). Hay que corregir el texto o explicar el cambio.
- **Datos existentes:** se asume que el proyecto Supabase solo tiene datos de prueba en las tablas de garantías.

**Decisiones tomadas por el equipo:** separar equipo y registro; la vigencia corre desde la fecha de la factura; el serial es obligatorio y único por producto; un equipo sin factura se registra con cobertura por determinar; el botón se llama *Nuevo registro*; el técnico puede registrar; el correlativo sale de una secuencia; revisiones y adjuntos son inmutables; el borrador caduca a las 24 horas; la urgencia combina vigencia y SLA; el asistente admite lector de código de barras; los archivos huérfanos se limpian cada día.

**Aplazado con motivo:** la consulta rápida de facturas emitidas por Ventas pasa al hito siguiente, porque requiere una fuente de datos de ventas que hoy no existe.
