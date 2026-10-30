# Fase 2b — Facturas de Ventas por CSV

**Fecha:** 2026-10-30 · **Rama:** `feat/fase-2b` (sale de `feat/fase-2a`)
**Estado:** borrador para aprobar. Las preguntas abiertas (§9) cambian el formato del CSV, no la arquitectura.

## 1. Objetivo

Hoy la factura de una garantía es lo que teclea quien la registra (deuda declarada en el spec de 2a, §10). Con 2b, **Ventas entrega un CSV de facturas** y la base lo usa como segunda fuente de verdad:

1. Jefatura importa el CSV (validación por fila, sin perder el resto si una fila falla).
2. Las garantías de origen `TALLER` cuya factura coincide con una venta real se **confirman solas** (hoy las confirma a mano un jefe).
3. Las demás quedan señaladas: *coincide*, *difiere* (con qué campo) o *sin venta registrada*. Nunca se desestima automáticamente: esa decisión sigue siendo humana.

Fuera: Excel `.xlsx`, adjuntar documentos a expedientes, enlace público y alertas (2c), pantallas Entregas/Inventario/Reportes.

## 2. Reglas

- **Clave de la venta:** (factura normalizada, serial normalizado). Reimportar el mismo CSV no duplica ni falla (idempotente por esa clave; los datos de la fila se actualizan).
- **Coincidencia** de una garantía con una venta, en este orden:
  1. misma factura y mismo serial → candidata;
  2. además mismo documento del titular (`tipo + número`, normalizado) → **COINCIDE**;
  3. si el documento o la fecha de emisión no cuadran → **DIFIERE** (se guarda cuál campo);
  4. sin fila con ese serial y esa factura → **SIN_VENTA**.
- **Confirmación automática:** solo si el resultado es COINCIDE y el equipo es `TALLER`, no está confirmado ni desestimado. Queda `compra_confirmada_via = 'VENTAS'` y las órdenes abiertas se recalculan con `recalcular_cobertura_equipo` (misma ruta que `confirmar_compra`).
- Un equipo `VENTA` se verifica igual, pero **solo informa** (columna `respaldo_venta` en `v_garantias`); no cambia su cobertura.
- Si la venta se importa **después** de que el equipo ya existe, el recorrido de confirmación corre al terminar la importación. Si el equipo se registra **después** de importada la venta, corre dentro de `registrar_garantia`.
- Una garantía DIFIERE o SIN_VENTA sigue el flujo manual de 2a (`confirmar_compra` / `desestimar_compra`).

## 3. Datos (migración 0023)

```
lotes_importacion(id, archivo, filas_total, filas_ok, filas_error, importado_por, creado_en)
ventas_facturas(id, lote_id, numero_factura, factura_normalizada (generada),
                fecha_emision, tipo_documento, documento, cliente_nombre,
                numero_serie, serie_normalizada (generada), modelo,
                importado_por, creado_en,
                UNIQUE (factura_normalizada, serie_normalizada))
equipos + compra_confirmada_via text CHECK IN ('MANUAL','VENTAS')
```

- RLS: ADMIN y JEFE_SERVICIO leen; nadie escribe por tabla, solo por la RPC. `anon` sin acceso. Las filas no se borran (rastro); un error de carga se corrige reimportando.
- La normalización de factura y serial reutiliza la misma función que `equipos.serie_normalizada`.

## 4. RPC

- `importar_ventas(p_archivo text, p_filas jsonb) → (lote_id, nuevas, actualizadas, con_error, confirmadas, errores jsonb)`
  ADMIN/JEFE_SERVICIO (42501 para el resto). Valida cada fila (serial 3–60, factura no vacía, fecha no futura, documento válido) y devuelve `errores: [{fila, campo, mensaje}]`; las filas válidas se guardan aunque otras fallen. Máximo 5 000 filas por llamada. Una sola transacción, con aviso del lote en `lotes_importacion`.
- `verificar_compra(p_equipo_id) → (resultado, campo_diferente)` — interna, SECURITY DEFINER, la usan las demás.
- `v_garantias` gana `verificacion` (`COINCIDE`/`DIFIERE`/`SIN_VENTA`) y `compra_confirmada_via`.

El CSV se **lee en el navegador** (parser mínimo de unas 30 líneas, sin dependencia nueva; `;` o `,`, UTF-8 con o sin BOM) y se envía como JSON. El servidor no recibe archivos.

## 5. Pantalla

`/ventas/importar` (solo Jefatura; enlace desde Garantías):
1. Elegir archivo → tabla de vista previa con las filas inválidas marcadas y el motivo.
2. «Importar N filas válidas» → resumen: nuevas · actualizadas · con error · garantías confirmadas.
3. Descargar las filas con error como CSV para corregirlas en Ventas.

En Garantías y en Consulta, una insignia por equipo: *Respaldada por Ventas*, *No coincide: documento*, *Sin venta*.

## 6. Pruebas (TDD)

- SQL (`29_ventas_importar.sql`): permisos por rol y `anon`; fila válida/inválida; idempotencia; COINCIDE/DIFIERE/SIN_VENTA; confirmación automática en las dos direcciones (venta antes y después del equipo); un equipo `VENTA` no cambia de cobertura; `desestimada` nunca se confirma sola; órdenes abiertas recalculadas; límite de 5 000 filas.
- vitest: parser CSV (delimitador, comillas, BOM, líneas vacías), vista previa, resumen, acceso solo para Jefatura.
- e2e: importar → la garantía `TALLER` pasa de POR_DETERMINAR a EN_GARANTIA sin intervención.

## 7. Seguridad

Entrada no confiable: todo se valida en la RPC (el navegador solo ayuda). Texto de celdas tratado como dato (sin interpolar en SQL; el frontend lo escapa como cualquier texto de React). Sin nueva superficie para `anon`. La confirmación automática deja autor (`importado_por` del lote) y vía en el equipo.

## 8. Orden de construcción

1. Migración 0023 + `importar_ventas` + `verificar_compra` (pruebas SQL primero).
2. Enganche en `registrar_garantia` y vista `v_garantias`.
3. Parser CSV y servicio `ventasService`.
4. Pantalla `/ventas/importar` + insignias.
5. e2e, README y ESTADO.

## 9. Preguntas abiertas (necesito la respuesta antes de la tarea 1)

1. **Columnas reales del CSV de Ventas.** Supuestas: `factura, fecha, tipo_documento, documento, cliente, serial, modelo`. ¿Trae el serial en cada fila (una fila por unidad) o una fila por factura con varios seriales? Con un archivo de muestra se fija el formato.
2. **¿Trae el plazo (7/15)?** Si no, se usa el que registró el punto de venta y no se compara.
3. **Criterio de «coincide»:** propongo factura + serial + documento. ¿Basta factura + serial, o también debe cuadrar la fecha?
4. **Frecuencia:** ¿archivo completo cada vez o solo lo nuevo? (Ambos funcionan; cambia el texto de la pantalla.)
