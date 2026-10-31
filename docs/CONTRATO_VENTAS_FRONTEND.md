# Contrato de Ventas para el frontend (fase 2b, migración 0023)

Lo que la pantalla `/ventas/importar` y las insignias pueden dar por hecho. La base valida todo; el navegador solo ayuda.

## `importar_ventas(p_archivo text, p_filas jsonb)`

Solo ADMIN y JEFE_SERVICIO (el resto recibe `42501`). `anon` no puede ejecutarla.

**Entrada:** `p_archivo` es el nombre del archivo (obligatorio, hasta 200 caracteres). `p_filas` es un arreglo JSON de **hasta 5000** objetos; más de eso se rechaza entero (`22P02`), así que el navegador debe partir el archivo en bloques.

Claves de cada fila (el parser del CSV las produce con estos nombres):

| Clave | Obligatoria | Regla |
|---|---|---|
| `numero_factura` | sí | 1 a 40 caracteres |
| `fecha_emision` | sí | `YYYY-MM-DD`; entre 2000-01-01 y hoy (no futura) |
| `numero_documento` | sí | 1 a 30 caracteres |
| `serial` | sí | 3 a 60 caracteres |
| `tipo_documento` | no | hasta 5 (`V`, `J`…) |
| `nombre_cliente` | no | hasta 150 |
| `modelo` | no | hasta 80 |
| `vendedor` | no | hasta 80 |

**Salida** (una fila):

| Campo | Significado |
|---|---|
| `lote_id` | id del lote registrado |
| `nuevas` / `actualizadas` | filas insertadas / ya existentes (misma factura y serial normalizados) que se actualizaron |
| `con_error` | filas rechazadas |
| `confirmadas` | garantías `TALLER` que esta carga confirmó solas |
| `errores` | `[{fila, campo, mensaje}]`; `fila` cuenta desde 1 dentro de `p_filas` |

Cada fila se valida sola: las buenas se guardan aunque otras fallen. Reimportar el mismo archivo no duplica. Con varios bloques, `fila` es relativa al bloque: el navegador suma el desplazamiento.

## `v_garantias`: dos columnas nuevas

- `verificacion`: `COINCIDE`, `DIFIERE` o `SIN_VENTA`. Es `NULL` si la garantía no tiene factura registrada o si quien consulta no tiene rol interno.
  - `COINCIDE`: la venta existe y cuadran documento del titular y fecha de emisión → insignia *Respaldada por Ventas*.
  - `DIFIERE`: existe la factura con ese serial pero no cuadra el documento o la fecha → *No coincide / Revisión requerida*.
  - `SIN_VENTA`: no hay venta con esa factura y serial → *Sin venta*.
- `compra_confirmada_via`: `MANUAL`, `VENTAS` o `NULL` (sin confirmar).

## Reglas que la pantalla no debe repetir

- Una garantía `TALLER` se confirma sola solo con `COINCIDE`; nunca se desestima sola. `DIFIERE` y `SIN_VENTA` siguen el flujo manual (`confirmar_compra` / `desestimar_compra`).
- Una garantía `VENTA` solo se informa: su cobertura no cambia.
- Las tablas `ventas_facturas` y `lotes_importacion` las leen solo ADMIN y JEFE_SERVICIO y no se escriben directo.
