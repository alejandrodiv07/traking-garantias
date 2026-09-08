# Revisión integral — base de datos, lógica de negocio, front↔backend y seguridad

**Fecha:** 2026-09-08 · **Alcance:** las 6 migraciones de `supabase/migrations/`, las 2 Edge Functions, y el módulo `frontend/src/features/taller` con su capa de datos.
**Método:** lectura del esquema contra el frontend (`mp-code-review`), auditoría con criterio de CSO (`gs-cso`) y pruebas rojo→verde sobre el panel (`sp-test-driven-development`).

> **Punto de partida honesto.** Este esquema está por encima de la media: la máquina de estados es una tabla y no un campo libre, el historial lo escribe un trigger y es inmutable, el token de consulta se guarda hasheado, `mi_rol()` exige `mfa_ok()` y cada migración revoca antes de conceder **nombrando** a `anon` y `authenticated`. Los hallazgos de abajo son huecos concretos, no una enmienda a la totalidad.

---

## Resumen

| # | Hallazgo | Gravedad | Estado |
|---|---|---|---|
| F1 | `VITE_SUPABASE_URL` apuntaba a `.../rest/v1/` — el cliente añade ese path él solo | **Alta** (rompe producción) | ✅ corregido |
| S1 | `garantias` tiene RLS de filas pero ninguna protección de **columnas** | **Alta** | ✅ migración 7 §2 |
| D1 | La cobertura no se recalcula al cambiar `tipo_garantia` / `meses_garantia_override` | **Alta** | ✅ migración 7 §1 |
| S2 | El freno de fuerza bruta del portal público es evadible (IP del cliente) | Media-alta | ⚠️ requiere verificar el gateway |
| D2 | `crear_orden()` acepta como "técnico" a cualquier perfil → orden que nadie puede trabajar | Media | ✅ migración 7 §3 |
| S3 | `documentos_garantia.subido_por` lo elige el navegador; la RLS no lo comprueba | Media | ✅ migración 7 §4 |
| S4 | La limpieza de adjuntos huérfanos no puede funcionar: no hay policy de DELETE en Storage | Media | ⚠️ pendiente de decisión |
| F2 | Los recuentos de las píldoras ignoraban la búsqueda (la píldora decía 40, la tabla 2) | Media | ✅ corregido + pruebas |
| F3 | "Hoy" se calculaba en UTC → un día de desfase desde las 20:00 en Caracas | Media | ✅ corregido + pruebas |
| F4 | `%` y `_` escritos por el usuario pasaban como comodines de LIKE | Media | ✅ corregido + pruebas |
| D3 | `crear_orden()` descarta en silencio los datos de un cliente/producto "nuevo" ya existente | Media | ⚠️ pendiente (cambia la firma) |
| D4 | `kpis_tablero().sla_por_vencer` cuenta también las ya vencidas | Media | ⚠️ decisión de negocio |
| D5 | `historial_garantias.comentario` guarda el diagnóstico actual, no un comentario de la transición | Media | ⚠️ pendiente |
| D9 | `idx_clientes_nombre_trgm` se llamaba "trgm" pero era un B-tree inútil para `%texto%` | Baja | ✅ migración 7 §5 |
| D6 | `productos.categoria` es texto libre — el problema que ya se corrigió con marca/modelo | Baja (normalización) | ⚠️ necesita backfill |
| F6 | El tablero no tiene paginación en la interfaz: con >25 órdenes no se llega a las demás | Baja | ⚠️ Fase 2.1 |
| F10 | `package-lock.json` desincronizado: `npm ci` fallaba | Baja | ✅ corregido |
| — | El doble de pruebas descartaba los argumentos: ningún filtro roto podía hacer fallar un test | Metodológica | ✅ corregido |

---

## 1. Seguridad

### S1 · `garantias` no protege columnas — **corregido**

`profiles` tiene dos capas y las dos hacen falta: la RLS decide **qué fila** se toca, y el trigger `proteger_columnas_de_profile` decide **qué columnas**. `garantias` solo tiene la primera, y el permiso es de tabla entera:

```sql
GRANT SELECT, UPDATE ON public.garantias TO authenticated;
```

Un TECNICO, sobre una orden que **sí** tiene asignada, podía reescribir:

- `numero_orden` — el número que el cliente lleva impreso en el comprobante;
- `consulta_token_hash` — dejando al titular fuera de su propio portal;
- `creado_por` — borrando quién registró la orden;
- `fecha_ingreso` — moviendo el SLA a su favor;
- `cliente_id` / `producto_id` — convirtiendo la orden en otra orden.

Ninguno de esos cambios es una transición de estado, así que **ninguno deja rastro en `historial_garantias`**. El escenario concreto: un técnico al que se le pasó el plazo mueve `fecha_ingreso` dos días hacia adelante y sale a tiempo en `tasa_a_tiempo`, sin que quede constancia.

La migración 7 añade `proteger_columnas_de_garantia()`: congela id, número, `creado_por` y `fecha_ingreso`; deja la rotación del token exclusivamente a `regenerar_token_orden()` (con la misma marca local a la transacción que usa `pt.sync_email`); y restringe el cambio de cliente/equipo a ADMIN y JEFE_SERVICIO. No quita a nadie lo que la aplicación sí hace hoy: estado, diagnóstico, cobertura, costo, prioridad y asignación siguen igual.

### S2 · El freno de fuerza bruta del portal público es evadible — **abierto**

En `consultar_garantia()`:

```sql
v_ip := ...split_part(current_setting('request.headers')::json ->> 'x-forwarded-for', ',', 1)...
```

El **primer** elemento de `X-Forwarded-For` es el que envía el cliente; los proxys **añaden** al final. Un atacante que mande `X-Forwarded-For: 1.2.3.<aleatorio>` en cada petición nunca acumula fallos, y el techo de 10 por 15 minutos no llega a activarse: quedan 128 bits de token frente a fuerza bruta sin freno real (el token es largo, así que el riesgo práctico es bajo — pero el freno que se creía tener no está).

**Arreglo:** tomar el **último** elemento de la cadena, o la cabecera que ponga el borde real. No se aplica en la migración 7 porque el valor correcto depende del proxy que tenga delante el proyecto desplegado: hay que comprobarlo contra el gateway antes de tocarlo.

### S3 · Un documento se puede firmar a nombre de otro — **corregido**

`documentos.js` manda `subido_por: usuarioId` desde el navegador, y `doc_gar_insert` solo comprobaba el **rol** de quien inserta. Una RECEPCION podía subir un adjunto firmado como el ADMIN. La tabla no tiene UPDATE ni DELETE precisamente porque es evidencia; una evidencia que se firma con el nombre de otro no lo es. La migración 7 §4 exige `subido_por = auth.uid()`, el mismo patrón que ya usa `notas_insert`.

### S4 · La compensación de adjuntos huérfanos no puede funcionar — **abierto**

`subirDocumento()` sube el binario, inserta el metadato y, si el INSERT falla, hace:

```js
await supabase.storage.from(BUCKET).remove([ruta]);
```

La migración 6 **no crea policy de DELETE sobre `storage.objects`** (decisión declarada: "dar esos permisos ahora sería una puerta sin pared"). Ese `remove()` falla siempre, su error se ignora, y el binario queda en el bucket sin metadato: invisible desde la aplicación y no borrable por nadie salvo `service_role`.

Además, `doc_storage_insert` permite escribir en **cualquier** path del bucket: nada obliga a que el primer segmento sea una orden existente.

**Decisión pendiente:** o se concede DELETE al autor sobre el path de su propia subida reciente, o la compensación se mueve a una Edge Function con `service_role`. Hoy el código promete una limpieza que no ocurre.

### S5-S7 · Menores

- La verificación MFA vale 12 h y va anclada al `session_id`. Con "Recordarme" el JWT vive en `localStorage`, así que una pestaña reabierta dentro de esas 12 h entra sin segundo factor. Es coherente con lo diseñado; conviene que esté escrito.
- `supabase/config.toml` tiene `enable_signup = true`. Es la config local, pero el README exige apagarlo en el proyecto desplegado: **confirmarlo en el panel**.
- `frontend/.env` **no** está versionado (verificado con `git ls-files`) y la clave del bundle es `sb_publishable_*`, no una secreta. `supabaseClient.js` además lo comprueba en tiempo de arranque. Correcto.
- Lo ya registrado en `docs/deuda-seguridad.md` (CSO-05, CSO-10, CSO-12) sigue vigente y no se duplica aquí.

---

## 2. Base de datos y lógica de negocio

### D1 · La cobertura no se recalculaba — **corregido**

La migración 4 enseñó a `calcular_vencimiento_garantia()` a mirar `tipo_garantia` y `meses_garantia_override`, pero dejó la lista de columnas del trigger como estaba en la migración 2:

```sql
BEFORE INSERT OR UPDATE OF fecha_compra, producto_id
```

Reproducible hoy: marcar una orden como `SIN_GARANTIA` después de crearla **no cambia nada** — `cobertura` sigue en `EN_GARANTIA` y `garantia_vence_el` sigue siendo el del catálogo. Y una garantía `EXTENDIDA` a la que se le pone el plazo pactado después del alta conserva el vencimiento del fabricante. El CHECK `ck_extendida_declara_meses` deja pasar los dos casos porque solo mira que el override no sea NULL, no que se haya aplicado. Migración 7 §1 recrea el trigger con la lista completa.

### D2 · Un "técnico" que no es técnico — **corregido**

`p_tecnico_id` entraba crudo y solo lo validaba la FK contra `profiles`, que acepta cualquier perfil. Una RECEPCION podía asignarle la orden al ADMIN o a una cuenta de baja. El efecto es peor que cosmético: `gar_update_tecnico` exige `tiene_rol('TECNICO') AND tecnico_asignado_id = auth.uid()`, así que **nadie** puede trabajar esa orden — ni los técnicos (no está asignada a ellos) ni el asignado (no es técnico). Migración 7 §3.

### D3 · El "cliente nuevo" que en realidad ya existía — **abierto**

```sql
ON CONFLICT (tipo_documento, documento) DO UPDATE SET updated_at = now()
```

Si el recepcionista registra a "Juan Pérez, tel 0412-…" con una cédula que ya está en la base, la orden se engancha al registro **viejo** y el nombre y el teléfono que acaba de teclear se descartan sin un solo aviso. Lo mismo con el producto (`ON CONFLICT (marca_id, modelo)`): la `categoria` y los `meses_garantia` que escribió se ignoran, y la cobertura se calcula con el plazo del registro antiguo.

La atomicidad y el `ON CONFLICT` están bien elegidos — el problema es el silencio. **Propuesta:** devolver `cliente_ya_existia` / `producto_ya_existia` en el `RETURNS TABLE` y que el modal lo diga ("Ese documento ya estaba registrado a nombre de *María Pérez*; se usó ese cliente"). No se aplica aquí porque cambia la firma de salida de `crear_orden()` y toca `ordenes.js` y el modal.

### D4 · `sla_por_vencer` cuenta las vencidas — **decisión**

```sql
WHERE fecha_ingreso::date + sla_dias <= now()::date + 2
```

No hay cota inferior: una orden con el plazo vencido hace tres semanas entra en "por vencer". Si eso es lo querido, el KPI debería llamarse *en riesgo o vencidas*; si no, falta `>= now()::date`. Hoy la tarjeta responde a una pregunta distinta de la que su etiqueta hace.

### D5 · El historial guarda el diagnóstico, no el comentario — **abierto**

`registrar_historial_garantia()` escribe en `comentario` el valor de `NEW.diagnostico`. Resultado: cada transición copia el diagnóstico **vigente en ese momento**, no lo que motivó el cambio, y el mismo texto aparece repetido en varias filas. Una bitácora que dice siempre lo mismo no ayuda a reconstruir nada. Lo natural es un parámetro explícito de comentario en la operación de cambio de estado (que todavía no existe en el frontend).

### D6 · Normalización pendiente: `productos.categoria`

Es `TEXT NOT NULL` sin CHECK ni catálogo: `'ROUTER'`, `'Router'` y `'router'` son tres categorías. Es exactamente el problema que la migración 2 resolvió muy bien para marca/modelo ("con texto libre, Samsung A54, samsung a-54 y SAMSUNG A54 son tres productos"), y aquí quedó sin resolver — y `crear_orden()` la acepta cruda desde el JSON del frontend. Corresponde una tabla `categorias_producto` con FK, igual que `estados_garantia`. **No es aditivo**: necesita backfill de los datos existentes, así que va en su propia migración y con los datos delante.

### D7-D12 · Menores y observaciones

- **Índice que mentía (D9, corregido):** `idx_clientes_nombre_trgm` era un B-tree `text_pattern_ops`, que sirve para `LIKE 'texto%'` pero **no** para `ILIKE '%texto%'`, que es justo lo que manda el buscador. Cada tecleo era un seq scan de `clientes` ⋈ `garantias` ⋈ `productos`. La migración 7 §5 instala `pg_trgm` y crea los índices GIN sobre las seis columnas reales de búsqueda, y retira el B-tree.
- **FK sin índice (D10, corregido):** `documentos_garantia.subido_por`. Migración 7 §6.
- **Estados desactivados (D8):** poner `activo = false` en un estado que tiene órdenes vivas las saca de las píldoras (`listarEstados()` filtra por `activo`) pero las deja en "TODAS", sin forma de aislarlas. Un CHECK o un aviso al desactivar evitaría la sorpresa.
- **Zona horaria (D11):** `now()::date` en `kpis_tablero()` y en el cálculo de cobertura usa la zona de la sesión de PostgREST, que en Supabase es **UTC**. Con el taller en `America/Caracas` (UTC-4), entre las 20:00 y la medianoche el servidor ya está en el día siguiente. Recomendado: `ALTER ROLE authenticator SET timezone = 'America/Caracas';` (o comparar con `timezone('America/Caracas', now())::date` de forma explícita). Es el mismo error que se corrigió del lado del navegador en F3.
- **`consulta_publica_intentos` (D12):** sigue creciendo sin techo. El cron de purga que documenta la migración 2 (nota 5) no está programado.
- **Bien resueltos, para que conste:** `mi_rol()` como único cuello de botella de las 20 policies; el historial append-only con doble capa; la vista con `security_invoker`; `kpis_tablero()` en INVERSO (SECURITY INVOKER) para que la tarjeta no cuente lo que la tabla no puede mostrar; y el `RETURN` vacío en vez de `RAISE` dentro de `consultar_garantia()` para que el contador de intentos sobreviva.

---

## 3. Comunicación front ↔ backend

### F1 · La URL de Supabase estaba mal formada — **corregido**

```
VITE_SUPABASE_URL=https://przkjfyatficximekvow.supabase.co/rest/v1/   ← antes
VITE_SUPABASE_URL=https://przkjfyatficximekvow.supabase.co            ← ahora
```

`createClient()` recibe la URL **raíz** del proyecto y añade `/rest/v1`, `/auth/v1`, `/functions/v1` y `/storage/v1` por su cuenta. Con el sufijo puesto a mano, cada llamada iba a `/rest/v1/rest/v1/…`, y auth, Edge Functions y Storage quedaban rotos. `frontend/.env.local` (el stack local) sí estaba bien, que es por lo que no salta en desarrollo.

### F2 · Las píldoras y la tabla contaban cosas distintas — **corregido**

`useOrdenes` recibía el término del buscador; `useRecuentosPorEstado` no. Al buscar "ana", la tabla mostraba 2 filas y la píldora de al lado seguía diciendo 40, sin forma de saber cuál era el número bueno. Ahora `contarPorEstado(codigos, { termino })` aplica la misma expresión de búsqueda que la tabla, y `Tablero.jsx` le pasa el término ya debounced a `FiltrosEstado`.

### F3 · "Hoy" se calculaba en UTC — **corregido**

`diasHasta()` y la ventana de `consultarPorVencer()` usaban `toISOString().slice(0,10)`, que da la fecha **UTC**. A partir de las 20:00 en Caracas eso ya es mañana: el operador del turno de noche veía "Venció hace 1 d" en una garantía que vence mañana, y una garantía que vencía hoy desaparecía del panel. Se añadió `fechaLocalISO()` en `dominio.js` y se usa en los dos sitios.

### F4 · `%` y `_` funcionaban como comodines — **corregido**

`sanearTermino()` limpiaba `(`, `)`, `,` y `*` (para no romper la gramática de `.or()`) pero dejaba pasar los comodines de LIKE. Buscar `100%` devolvía el taller entero, y `ORD_2026` casaba con `ORD-2026`. Ahora se escapan con `\`.

> **Verificar en el backend real:** el escape con `\` es el de SQL `LIKE` y PostgREST pasa el patrón tal cual. Conviene comprobarlo contra el proyecto desplegado la primera vez que se busque un `%` literal.

### F5-F11 · Resto

- **F5:** ver S4 — la limpieza de huérfanos es código que no puede tener efecto.
- **F6:** `useOrdenes` usa `pagina: 0, porPagina: 25` fijos y no hay controles de paginación; "Ver todas" avisa que no está construido. Con más de 25 órdenes vivas, las siguientes son inalcanzables desde el tablero. La búsqueda lo mitiga, no lo resuelve.
- **F7:** `contarPorEstado` hace una consulta `head` por estado (11 con el catálogo actual) en cada búsqueda. Es asumible al volumen de un taller y ahora ya no es un seq scan (§5 de la migración 7); si algún día duele, una función `recuentos_tablero(termino)` que devuelva todo en una pasada lo resuelve sin tocar la interfaz.
- **F8:** `consultarPorVencer` no lleva `limit`: trae todo lo que caiga en la ventana de 30 días.
- **F9:** `traducirError()` no cubre `P0002` (orden inexistente, de `regenerar_token_orden`) ni `54000` (límite de códigos MFA).
- **F10:** `package-lock.json` no incluía las dependencias de prueba que ya estaban en `package.json`, así que `npm ci` fallaba con `EUSAGE` — cualquier CI o instalación limpia se caía. Regenerado y verificado con `npm ci`.
- **F11:** `normalizarFila()` expone `prioridad`, pero `TablaOrdenes` no la pinta. Dato que viaja y no se usa.
- **Bien resuelto:** ningún componente conoce Supabase; el filtrado y la búsqueda ocurren en la consulta y no en memoria; `traducirError` es el único punto que conoce los códigos de PostgREST; `AuthContext` difiere el trabajo fuera del callback de `onAuthStateChange` (el bloqueo clásico de supabase-js).

---

## 4. Pruebas del panel (filtros y búsqueda)

**El problema de método primero.** `src/test/supabaseFake.js` descartaba los argumentos de la cadena:

```js
eq: () => encadenable,
or: () => encadenable,
```

Con eso se podía probar que una fila se normaliza bien, pero **no** que el filtro por estado llegue a la consulta, ni que la búsqueda mire las seis columnas, ni que la paginación pida el rango correcto. Es decir: alguien podía borrar el `if (estado !== "TODAS")` entero y las 33 pruebas seguían en verde. Un doble que se traga los argumentos convierte "filtrar" en una función sin comportamiento observable.

Ahora cada eslabón anota `[metodo, ...args]` y el doble expone `argumentosDe(nombre)` y `seLlamo(nombre)`. El contrato anterior no cambia, así que las pruebas existentes siguen funcionando sin tocarlas.

**26 pruebas nuevas**, escritas en rojo antes de cada arreglo:

- `datos/filtros.test.js` — filtro por estado (incluida la ausencia de filtro en "TODAS"), la expresión exacta de búsqueda sobre las seis columnas, la combinación filtro+búsqueda, el término en blanco, el saneado de `,`/`()`, los comodines `%` y `_`, los rangos de paginación (0-24, 50-74), el orden por fecha y los recuentos con y sin término.
- `datos/recuentos.test.jsx` — que `useRecuentosPorEstado` propaga el término y vuelve a contar cuando cambia.
- `dominio.test.js` — `diasHasta` y la ventana de vencimientos a las 20:30 de Caracas, que es donde estaba el desfase.

```
Test Files  8 passed (8)
     Tests  59 passed (59)      # 33 antes de esta revisión
```

Ejecutadas con `TZ=America/Caracas` en una copia local del frontend; `npm ci` verificado.

---

## 5. Qué hacer a continuación, por orden

1. **Aplicar la migración 7** (`supabase db push`) y escribir sus pruebas en `supabase/tests/` — el resto del esquema tiene pruebas y esta todavía no.
2. **Confirmar la URL corregida** en el despliegue (Vercel u otro): la variable de entorno del hosting tiene la misma forma que tenía `.env`.
3. **Decidir S4** (limpieza de adjuntos huérfanos) y **S2** (de qué cabecera sale la IP real).
4. **D3** — avisar cuando el cliente/producto "nuevo" ya existía.
5. **D4 y D5** — dos preguntas de negocio antes que de código: qué cuenta `sla_por_vencer` y qué debe decir el comentario del historial.
6. **Fijar la zona horaria del servidor** (D11) para que la base y el navegador estén en el mismo día.
7. **Normalizar `productos.categoria`** (D6), con backfill, en su propia migración.
8. **Paginación del tablero** (F6) cuando llegue la Fase 2.1.
