# Diseño — Tablero del taller y alta de órdenes

## Fase 2 del Blueprint Supabase · Prime Telecom

> **Spec de implementación.** Deriva de `docs/specs/2026-09-07-blueprint-supabase.md` (§6 Fase 2). Toda decisión aquí es trazable a ese documento o lo extiende explícitamente. Alcance cerrado: **tablero + alta de orden**. Ninguna otra pantalla se toca.

**Fecha:** 2026-09-08
**Depende de:** Fase 0 (saneamiento) ejecutada
**Referencias de diseño:** `Tablero del taller.pdf`, `Nueva orden formulario.pdf`

---

## 1. Alcance

### Dentro

- Migración **Fase 0.1**: `prioridad`, `tipo_garantia`, `meses_garantia_override`, `sla_dias`.
- Capa de lectura: vista `v_ordenes_tablero` + RPC `kpis_tablero()`.
- RPC de escritura **atómica** `crear_orden()` (sustituye a `crear_garantia()`).
- Tablero conectado a datos reales: KPIs, tabla, filtros dinámicos, búsqueda multicriterio, panel de vencimientos.
- Modal de alta con autocompletado de cliente y producto, `falla_reportada` obligatorio, y **entrega única del token de consulta**.

### Fuera (declarado, no olvidado)

| Queda fuera | Por qué | Dónde vuelve |
|---|---|---|
| Ficha de detalle de la orden | Decisión de alcance del usuario | Fase 2.1 |
| Cambio de estado desde la interfaz | Sin ficha no hay dónde hacerlo | Fase 2.1 |
| Hoja de impresión del comprobante | El token sí se entrega en pantalla; falta el CSS de impresión | Fase 2.1 |
| "Colaboradores CM LF +" del mockup | Presencia en tiempo real: otro subsistema | Sin planificar |
| "Enviar recordatorios" y campana de avisos | Necesitan el outbox | Fase 4 |
| Pantallas de `/jefe`, `/tecnico`, `/recepcion` | Alcance cerrado | Fase 2.1 |

### 1.1 Divergencias del mockup, resueltas a favor del esquema

La interfaz se subordina a la verdad de los datos. Cuatro cambios respecto a los PDF:

| Mockup | Se implementa | Motivo |
|---|---|---|
| `OS-2026-0142` | **`ORD-2026-000142`** | Es el formato que genera la secuencia. Cambiarlo dejaría dos formatos conviviendo en una columna `UNIQUE`, y toda búsqueda futura tendría que contemplar ambos |
| Columna GARANTÍA con 3 valores | **4 valores, con `POR_DETERMINAR`** | Es el estado inicial de toda orden recién creada: el más frecuente en un tablero real. En el mockup no aparece ninguno |
| `RECHAZADO` | **`RECHAZADO_POR_CLIENTE`** | Es el código real y dice quién rechazó |
| Avatares "Colaboradores CM LF +" | Se descarta | Presencia en tiempo real: otro subsistema |

---

## 2. Migración Fase 0.1 — `20260908000004_tablero_operativo.sql`

### 2.1 Tipos y columnas

```sql
BEGIN;

CREATE TYPE public.prioridad_orden AS ENUM ('BAJA','NORMAL','ALTA','URGENTE');
CREATE TYPE public.tipo_garantia   AS ENUM ('ESTANDAR','EXTENDIDA','SIN_GARANTIA');

ALTER TABLE public.garantias
  ADD COLUMN prioridad     public.prioridad_orden NOT NULL DEFAULT 'NORMAL',
  ADD COLUMN tipo_garantia public.tipo_garantia   NOT NULL DEFAULT 'ESTANDAR',

  -- Duración pactada, en meses. NULL = usar productos.meses_garantia.
  -- Existe porque EXTENDIDA sin un plazo propio no significa nada: es el
  -- selector "Duración de garantía" del mockup.
  ADD COLUMN meses_garantia_override SMALLINT
      CHECK (meses_garantia_override IS NULL
             OR meses_garantia_override BETWEEN 0 AND 120),

  -- Plazo de entrega comprometido, en días desde el ingreso.
  ADD COLUMN sla_dias SMALLINT NOT NULL DEFAULT 5
      CHECK (sla_dias BETWEEN 1 AND 90),

  -- Una garantía extendida sin plazo declarado es una contradicción.
  ADD CONSTRAINT ck_extendida_declara_meses
      CHECK (tipo_garantia <> 'EXTENDIDA' OR meses_garantia_override IS NOT NULL);

CREATE INDEX idx_gar_sla
    ON public.garantias ((fecha_ingreso::date + sla_dias))
    WHERE estado NOT IN ('ENTREGADO','ANULADO');

CREATE INDEX idx_gar_prioridad
    ON public.garantias (prioridad, fecha_ingreso DESC)
    WHERE estado NOT IN ('ENTREGADO','ANULADO');
```

**Por qué `sla_dias` y no una fecha límite guardada.** La fecha se deriva siempre (`fecha_ingreso::date + sla_dias`), nunca se almacena. Un valor derivado que se guarda es un valor que puede quedar desincronizado con su origen: si alguna vez se corrige la fecha de ingreso, una fecha límite guardada seguiría apuntando al plazo viejo sin que nada avise. Es la misma regla que ya aplica `PanelVencimientos.jsx` con los "faltan N días".

**Consecuencia aceptada:** extender el plazo de una orden concreta significa subir su `sla_dias`, no mover una fecha. Es equivalente en efecto y mantiene una sola fuente.

### 2.2 La numeración no cambia

Se conserva `ORD-YYYY-NNNNNN` tal como lo genera `garantias_numero_seq`. Ni `DEFAULT` nuevo, ni reescritura de filas, ni `CHECK` de formato — nada de eso entra en esta migración. **La interfaz muestra el número tal cual viene de la base.**

### 2.3 Ajuste del cálculo de cobertura

`calcular_vencimiento_garantia()` está probado y en uso, así que se toca **con test primero**. Cambian dos cosas: el plazo pactado gana sobre el del catálogo, y `SIN_GARANTIA` corta el cálculo.

```sql
CREATE OR REPLACE FUNCTION public.calcular_vencimiento_garantia()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_meses SMALLINT;
BEGIN
    -- SIN_GARANTIA no calcula nada: la fecha de compra sigue siendo un dato
    -- real (sirve para el histórico), pero la cobertura queda determinada
    -- desde el minuto cero. Sin esta rama, el trigger la marcaría EN_GARANTIA.
    IF NEW.tipo_garantia = 'SIN_GARANTIA' THEN
        NEW.garantia_vence_el := NEW.fecha_compra;
        NEW.cobertura := 'FUERA_DE_GARANTIA';
        RETURN NEW;
    END IF;

    SELECT COALESCE(NEW.meses_garantia_override, p.meses_garantia)
      INTO v_meses
      FROM public.productos p
     WHERE p.id = NEW.producto_id;

    NEW.garantia_vence_el := NEW.fecha_compra + make_interval(months => v_meses);

    IF NEW.cobertura = 'POR_DETERMINAR' THEN
        NEW.cobertura := CASE
            WHEN NEW.garantia_vence_el >= now()::date THEN 'EN_GARANTIA'
            ELSE 'FUERA_DE_GARANTIA'
        END;
    END IF;

    RETURN NEW;
END;
$$;
```

> **Comportamiento que se conserva:** la cobertura solo se recalcula mientras siga en `POR_DETERMINAR`. Una vez que un técnico la fija en `ANULADA_POR_USO`, ningún `UPDATE` posterior la devuelve a `EN_GARANTIA` por acción del trigger. Ya era así y no se toca.

### 2.4 RPC de alta atómica — `crear_orden()`

Sustituye a `crear_garantia()`. Se hace `DROP` en vez de sobrecarga: dos funciones homónimas con parámetros por defecto producen ambigüedad de resolución, y nada del frontend la invoca todavía.

**La atomicidad es el punto entero de esta función.** Recibe el cliente y el producto **o bien** como UUID existente **o bien** como datos nuevos, y resuelve el alta dentro de la misma transacción que la orden. Si la orden falla por cualquier motivo, el cliente nuevo desaparece con ella: no quedan huérfanos. Y el alta usa `ON CONFLICT` sobre las claves únicas reales (`uq_clientes_documento`, `uq_productos_marca_modelo`), así que dos recepcionistas registrando a la vez al mismo cliente no producen un duplicado ni un error.

```sql
DROP FUNCTION IF EXISTS public.crear_garantia(UUID, UUID, DATE, TEXT, TEXT, TEXT, TEXT);

CREATE OR REPLACE FUNCTION public.crear_orden(
    p_fecha_compra     DATE,
    p_falla_reportada  TEXT,
    -- Cliente: exactamente uno de los dos.
    p_cliente_id       UUID  DEFAULT NULL,
    p_cliente_nuevo    JSONB DEFAULT NULL,  -- {tipo_documento, documento, nombre, telefono?, email?}
    -- Producto: exactamente uno de los dos.
    p_producto_id      UUID  DEFAULT NULL,
    p_producto_nuevo   JSONB DEFAULT NULL,  -- {marca_id, modelo, categoria, meses_garantia?}
    p_numero_serie     TEXT  DEFAULT NULL,
    p_numero_factura   TEXT  DEFAULT NULL,
    p_accesorios       TEXT  DEFAULT NULL,
    p_prioridad        public.prioridad_orden DEFAULT 'NORMAL',
    p_tipo_garantia    public.tipo_garantia   DEFAULT 'ESTANDAR',
    p_meses_override   SMALLINT DEFAULT NULL,
    p_sla_dias         SMALLINT DEFAULT 5,
    p_tecnico_id       UUID     DEFAULT NULL
)
RETURNS TABLE (
    orden_id       UUID,
    numero_orden   TEXT,
    consulta_token TEXT,   -- TEXTO PLANO. Se devuelve UNA vez. Imprimir y olvidar.
    cobertura      public.cobertura_garantia,
    vence_el       DATE,
    cliente_id     UUID,
    producto_id    UUID
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_token    TEXT;
    v_actor    UUID := auth.uid();
    v_cliente  UUID;
    v_producto UUID;
BEGIN
    IF NOT public.tiene_rol('ADMIN','JEFE_SERVICIO','RECEPCION') THEN
        RAISE EXCEPTION 'Su rol no puede registrar órdenes' USING ERRCODE = '42501';
    END IF;

    -- ---- Cliente: exactamente uno de los dos caminos ----
    IF (p_cliente_id IS NULL) = (p_cliente_nuevo IS NULL) THEN
        RAISE EXCEPTION 'Indique un cliente existente o los datos de uno nuevo, no ambos'
            USING ERRCODE = '22023';
    END IF;

    IF p_cliente_id IS NOT NULL THEN
        v_cliente := p_cliente_id;
    ELSE
        -- ON CONFLICT sobre uq_clientes_documento: si otro lo dio de alta
        -- entre la búsqueda y el envío, se reutiliza en vez de fallar.
        INSERT INTO public.clientes (tipo_documento, documento, nombre, telefono, email)
        VALUES (
            (p_cliente_nuevo->>'tipo_documento')::public.tipo_documento,
            btrim(p_cliente_nuevo->>'documento'),
            btrim(p_cliente_nuevo->>'nombre'),
            nullif(btrim(coalesce(p_cliente_nuevo->>'telefono','')),''),
            nullif(lower(btrim(coalesce(p_cliente_nuevo->>'email',''))),'')
        )
        ON CONFLICT (tipo_documento, documento) DO UPDATE
            SET updated_at = now()
        RETURNING id INTO v_cliente;
    END IF;

    -- ---- Producto: mismo patrón ----
    IF (p_producto_id IS NULL) = (p_producto_nuevo IS NULL) THEN
        RAISE EXCEPTION 'Indique un producto existente o los datos de uno nuevo, no ambos'
            USING ERRCODE = '22023';
    END IF;

    IF p_producto_id IS NOT NULL THEN
        v_producto := p_producto_id;
    ELSE
        INSERT INTO public.productos (marca_id, modelo, categoria, meses_garantia)
        VALUES (
            (p_producto_nuevo->>'marca_id')::UUID,
            btrim(p_producto_nuevo->>'modelo'),
            btrim(p_producto_nuevo->>'categoria'),
            COALESCE((p_producto_nuevo->>'meses_garantia')::SMALLINT, 12)
        )
        ON CONFLICT (marca_id, lower(btrim(modelo))) DO UPDATE
            SET updated_at = now()
        RETURNING id INTO v_producto;
    END IF;

    v_token := encode(extensions.gen_random_bytes(16), 'hex');

    RETURN QUERY
    INSERT INTO public.garantias (
        consulta_token_hash, cliente_id, producto_id, fecha_compra,
        falla_reportada, numero_serie, numero_factura, accesorios,
        prioridad, tipo_garantia, meses_garantia_override, sla_dias,
        tecnico_asignado_id, garantia_vence_el, creado_por
    )
    VALUES (
        extensions.digest(v_token, 'sha256'),
        v_cliente, v_producto, p_fecha_compra,
        btrim(p_falla_reportada),
        nullif(btrim(coalesce(p_numero_serie,'')),''),
        nullif(btrim(coalesce(p_numero_factura,'')),''),
        nullif(btrim(coalesce(p_accesorios,'')),''),
        p_prioridad, p_tipo_garantia, p_meses_override,
        COALESCE(p_sla_dias, 5),
        p_tecnico_id,
        p_fecha_compra,          -- el trigger §2.3 lo recalcula
        v_actor
    )
    RETURNING garantias.id, garantias.numero_orden, v_token,
              garantias.cobertura, garantias.garantia_vence_el,
              v_cliente, v_producto;
END;
$$;
```

**Sobre el uso de `JSONB` para los datos nuevos.** La alternativa era añadir nueve parámetros sueltos (`p_cliente_nombre`, `p_cliente_documento`, …), lo que da una firma de veintiún argumentos posicionales donde cualquier desajuste de orden pasa desapercibido. El `JSONB` agrupa el concepto "un cliente que aún no existe" en un solo argumento, a costa de que la validación de tipos ocurra dentro de la función y no en la firma. Los `CHECK` de `clientes` y `productos` siguen siendo los que rechazan un documento mal formado o un modelo vacío: el `JSONB` cambia cómo viajan los datos, no quién los valida.

La RPC **devuelve `cliente_id` y `producto_id`** para que el frontend refresque sus selectores sin una consulta extra.

---

## 3. Capa de lectura

### 3.1 `v_ordenes_tablero` — una vista, no un endpoint por consulta

```sql
CREATE VIEW public.v_ordenes_tablero
WITH (security_invoker = true) AS
SELECT
    g.id,
    g.numero_orden,
    g.estado,
    e.nombre        AS estado_nombre,
    e.orden         AS estado_orden,
    e.es_final,
    g.cobertura,
    g.prioridad,
    g.numero_serie,
    g.numero_factura,
    g.fecha_ingreso,
    g.fecha_entrega,
    g.garantia_vence_el,
    g.sla_dias,
    (g.fecha_ingreso::date + g.sla_dias) AS sla_vence_el,   -- derivado, nunca guardado
    g.tecnico_asignado_id,
    c.nombre        AS cliente,
    (c.tipo_documento || '-' || c.documento) AS documento,
    (m.nombre || ' ' || p.modelo)            AS equipo,
    p.categoria
FROM public.garantias g
JOIN public.estados_garantia e ON e.codigo = g.estado
JOIN public.clientes  c ON c.id = g.cliente_id
JOIN public.productos p ON p.id = g.producto_id
JOIN public.marcas    m ON m.id = p.marca_id;

GRANT SELECT ON public.v_ordenes_tablero TO authenticated;
```

**`security_invoker = true` no es opcional.** Sin esa opción una vista se ejecuta con los privilegios de su dueño y **bypassea toda la RLS de §11** de la migración de garantías: cualquier `authenticated` —y con un `GRANT` descuidado, `anon`— leería el taller entero. Con ella, la vista es exactamente tan restrictiva como `gar_select`. Requiere PostgreSQL 15+; el proyecto está en 17.

**Qué NO lleva la vista, a propósito:** `notas_internas`, `costo_reparacion`, `diagnostico`, `motivo_anulacion_cobertura` y `consulta_token_hash`. El tablero es una lista; lo sensible se lee en la ficha, fuera de alcance. Una vista que trae de más es una filtración esperando a un `SELECT *`.

Con la vista, filtro, búsqueda, orden y paginación son parámetros de PostgREST. No hace falta una RPC por consulta.

### 3.2 `kpis_tablero()` — las agregaciones en un viaje

```sql
CREATE OR REPLACE FUNCTION public.kpis_tablero()
RETURNS TABLE (
    ordenes_abiertas INTEGER,
    nuevas_semana    INTEGER,
    en_diagnostico   INTEGER,
    sla_por_vencer   INTEGER,  -- abiertas cuyo plazo cae en <= 2 días
    por_vencer_30d   INTEGER,  -- garantías que caducan en <= 30 días
    reparadas_mes    INTEGER,
    tasa_a_tiempo    NUMERIC   -- % entregadas dentro del plazo, mes en curso
)
LANGUAGE sql
STABLE
SECURITY INVOKER            -- respeta la RLS del invocante, igual que la vista
SET search_path = public, pg_temp
AS $$
    WITH abiertas AS (
        SELECT * FROM public.garantias
         WHERE estado NOT IN ('ENTREGADO','ANULADO')
    ),
    mes AS (
        SELECT * FROM public.garantias
         WHERE fecha_entrega >= date_trunc('month', now())
    )
    SELECT
        (SELECT count(*) FROM abiertas)::INTEGER,
        (SELECT count(*) FROM abiertas
          WHERE fecha_ingreso > now() - interval '7 days')::INTEGER,
        (SELECT count(*) FROM abiertas WHERE estado = 'EN_DIAGNOSTICO')::INTEGER,
        (SELECT count(*) FROM abiertas
          WHERE fecha_ingreso::date + sla_dias <= now()::date + 2)::INTEGER,
        (SELECT count(*) FROM public.garantias
          WHERE garantia_vence_el BETWEEN now()::date AND now()::date + 30
            AND cobertura = 'EN_GARANTIA')::INTEGER,
        (SELECT count(*) FROM mes WHERE estado = 'ENTREGADO')::INTEGER,
        (SELECT COALESCE(round(100.0 * count(*) FILTER (
                    WHERE fecha_entrega::date <= fecha_ingreso::date + sla_dias
                 ) / NULLIF(count(*),0), 0), 0)
           FROM mes WHERE estado = 'ENTREGADO');
$$;

GRANT EXECUTE ON FUNCTION public.kpis_tablero() TO authenticated;
```

`SECURITY INVOKER` es deliberado y **es lo contrario de lo que hacen `mi_rol()` y `crear_orden()`**: aquellas necesitan privilegio elevado para no recursar o para escribir el token; esta solo cuenta filas que el usuario ya puede ver. Una función de conteo con `DEFINER` contaría también lo que la RLS le oculta, y el KPI mostraría un número que la tabla de abajo no puede justificar.

**Correspondencia con las tarjetas del mockup:**

| Tarjeta | Campo | Nota |
|---|---|---|
| ÓRDENES ABIERTAS · "▲3 esta semana" | `ordenes_abiertas`, `nuevas_semana` | |
| EN DIAGNÓSTICO · "2 con SLA por vencer" | `en_diagnostico`, `sla_por_vencer` | `sla_por_vencer` cuenta **todas** las abiertas, no solo las de diagnóstico. El rótulo se corrige a *"N con SLA por vencer"* referido al taller |
| GARANTÍAS POR VENCER · "próximos 30 días" | `por_vencer_30d` | |
| REPARADAS (MES) · "tasa 94% a tiempo" | `reparadas_mes`, `tasa_a_tiempo` | Cuenta **entregadas**, que es cuando el plazo se puede evaluar |

---

## 4. Estructura del frontend

El módulo `features/tablero/` pasa a `features/taller/`: el tablero y el alta de órdenes son el mismo dominio, comparten catálogos y comparten la forma de fila. Separarlos obligaría a que `nueva-orden` importara de `tablero`, que es la señal de que eran una sola cosa.

```
frontend/src/features/taller/
├── Tablero.jsx                 ← existe; se adelgaza (KPIs y filtros salen a componentes)
├── Tablero.css                 ← existe
├── dominio.js                  ← existe; deja de ser catálogo, conserva SOLO el mapa de tonos
├── datos/
│   ├── ordenes.js              consultas a v_ordenes_tablero · rpc crear_orden
│   ├── catalogos.js            estados · marcas · productos · clientes
│   └── hooks.js                useOrdenes · useKpis · usePorVencer · useEstados · useBusqueda
├── componentes/
│   ├── BarraLateral.jsx        ← existe, sin cambios
│   ├── TablaOrdenes.jsx        ← existe, sin cambios (recibe filas ya resueltas)
│   ├── PanelVencimientos.jsx   ← existe, sin cambios
│   ├── TarjetasKpi.jsx         NUEVO — hoy vive incrustado en Tablero.jsx
│   ├── FiltrosEstado.jsx       NUEVO — píldoras generadas desde la base
│   └── BuscadorOrdenes.jsx     NUEVO — con retardo de 300 ms
└── nueva-orden/
    ├── ModalNuevaOrden.jsx     NUEVO — foco atrapado, Esc, aria-modal
    ├── FormularioOrden.jsx     NUEVO — las cuatro secciones del mockup
    ├── SelectorAsincrono.jsx   NUEVO — base compartida de autocompletado
    ├── CampoCliente.jsx        NUEVO — busca, o compone el JSONB de cliente nuevo
    ├── CampoProducto.jsx       NUEVO — busca, o compone el JSONB de producto nuevo
    ├── TokenDeConsulta.jsx     NUEVO — la entrega única
    └── NuevaOrden.css
```

**`datosDemo.js` no se borra: se mueve a `__fixtures__/ordenes.js`.** Contiene a propósito los casos incómodos que un mock bonito esconde —nombre de cliente larguísimo, orden sin número de serie, cobertura `POR_DETERMINAR`, estados de los cuatro tonos— y eso es exactamente el material de los tests de Vitest.

**`dominio.js` adelgaza.** Hoy declara los 10 estados como constantes; el propio fichero ya anticipa el cambio: *"cuando este módulo deje de ser el catálogo y pase a leerse de la base, lo único que sobrevive de aquí es el mapa de CLASES CSS: el color no está en la base ni debe estarlo."* Se ejecuta ese cambio. Sobreviven `tonoDeEstado(codigo)`, `COBERTURAS` (con sus cuatro valores, `POR_DETERMINAR` incluido), `diasHasta()` y `fechaCorta()`.

---

## 5. Contratos de datos

Los componentes no conocen Supabase. Reciben datos por props, igual que hoy.

```js
// datos/hooks.js

useEstados()
// -> { estados: [{ codigo, nombre, orden, es_final }], cargando, error }
// Los 10 desde estados_garantia, ordenados por `orden`, solo `activo`.

useOrdenes({ estado, termino, pagina = 0, porPagina = 25 })
// -> { ordenes: Fila[], total, cargando, error, recargar }
// estado === 'TODAS' no filtra. `termino` se aplica con .or() (§5.1).

useKpis()
// -> { kpis: {...}, cargando, error, recargar }

usePorVencer({ dias = 30 })
// -> { ordenes: Fila[], cargando, error }
// cobertura EN_GARANTIA y garantia_vence_el en [hoy, hoy+dias], ascendente.

useBusquedaClientes(termino)   // -> { resultados, buscando }
useBusquedaProductos(termino)  // -> { resultados, buscando }
```

Toda operación de escritura vive en `datos/ordenes.js` y devuelve la misma forma:
`{ ok: true, datos }` o `{ ok: false, error: { codigo, mensaje } }`. **Ningún componente lee el mensaje crudo de PostgREST**: los códigos se traducen en un único sitio (`42501` → "Tu rol no puede registrar órdenes"; `22023` → "Faltan datos del cliente o del equipo"; `23514` → el `CHECK` que falló), igual que `authService.js` hace hoy con los errores de Auth.

### 5.1 Búsqueda multicriterio

Un solo cuadro busca por número de orden, cliente, documento, equipo, serial o factura, porque quien atiende el mostrador tiene **una** cosa en la mano y no sabe en qué columna cae:

```js
.or([
  `numero_orden.ilike.%${t}%`,
  `cliente.ilike.%${t}%`,
  `documento.ilike.%${t}%`,
  `equipo.ilike.%${t}%`,
  `numero_serie.ilike.%${t}%`,
  `numero_factura.ilike.%${t}%`,
].join(","))
```

**Riesgo conocido:** `t` se interpola en la gramática de PostgREST, así que una coma o un paréntesis en el término rompen la consulta. Se sanea antes (`t.replace(/[(),*]/g, " ")`). No es riesgo de inyección SQL —PostgREST parametriza— pero sí de consulta malformada, y el usuario vería un error opaco.

**Rendimiento:** `ilike '%…%'` no usa índice. Al volumen de un taller es irrelevante. Si llegara a notarse, la solución es `pg_trgm` con GIN — **no** cambiar la interfaz.

---

## 6. Casos de uso

| # | Caso de uso | Actor | Criterio de aceptación |
|---|---|---|---|
| **CU-01** | Ver la carga del taller de un vistazo | Todos | Las 4 tarjetas muestran los valores de `kpis_tablero()`; con el taller vacío muestran `0`, no un hueco ni un error |
| **CU-02** | Localizar una orden con lo que tenga en la mano | Todos | Escribir `V-12345678`, `SW24-0093-LM`, `ORD-2026-000139` o "El Faro" encuentra la misma orden; sin resultados, estado vacío con el término buscado |
| **CU-03** | Filtrar por estado | Todos | Las píldoras son los 10 de `estados_garantia`; añadir un estado en SQL lo hace aparecer sin tocar React; cada píldora lleva su recuento |
| **CU-04** | Ver qué garantías vencen pronto | Todos | Lista ordenada por urgencia; los días se calculan en el navegador contra la fecha real, nunca se guardan como texto |
| **CU-05** | Registrar una orden | ADMIN · JEFE · RECEPCION | Se crea con `crear_orden()`; el tablero se refresca; el `TECNICO` **no ve el botón**, y si fuerza la llamada recibe `42501` |
| **CU-06** | Registrar un cliente o equipo que no existe | ADMIN · JEFE · RECEPCION | Se envía en el mismo `crear_orden()`; si la orden falla, el cliente **no** queda creado |
| **CU-07** | Entregar el token al cliente | Quien creó la orden | Se muestra **una vez**, con aviso explícito de que no se puede recuperar; recargar la página no lo devuelve |

### 6.1 Reglas de rol en la interfaz

`crear_orden()` rechaza a `TECNICO` con `42501`, así que el botón "Nueva orden" se oculta para ese rol. **Se oculta como cortesía, no como control**: quien lo fuerce con las herramientas del navegador recibe el mismo rechazo de la base. Es la regla 1 de §8.2 del Blueprint — el cliente nunca decide un permiso.

`gar_select` es `TRUE` para todo `authenticated`: **el técnico ve todas las órdenes del taller**, no solo las suyas. Es deliberado y está documentado en la migración: *"son cuatro personas en un taller; ocultarle órdenes a un técnico solo genera llamadas al jefe. La restricción real está en la escritura."* El tablero no filtra por rol al leer.

### 6.2 Estados de la interfaz

Cada zona con datos tiene cuatro estados, y **"vacío" es de primera clase**, no un error. Bajo RLS, una consulta sin permiso no devuelve `403`: devuelve **cero filas** (§8.1 del Blueprint). Confundir "no hay" con "no puedes" es el error de diseño más probable de esta pantalla.

| Zona | Cargando | Vacío | Error |
|---|---|---|---|
| Tarjetas KPI | Esqueleto, no `0` | `0` real | Guion `—` y aviso discreto |
| Tabla | Esqueleto de 5 filas | "Sin órdenes que coincidan" + término | Aviso con "Reintentar" |
| Vencimientos | Esqueleto | "Ninguna garantía vence en 30 días" | Aviso discreto |
| Autocompletado | "Buscando…" | "Sin coincidencias" + "Registrar nuevo" | Mensaje en línea |

---

## 7. El formulario

### 7.1 Secciones y campos

| Sección | Campo | Origen / destino | Obligatorio |
|---|---|---|---|
| Cliente y equipo | Cliente | Autocompletado → `p_cliente_id` o `p_cliente_nuevo` | Sí |
| | Cédula / RIF | Se rellena al seleccionar; editable solo al registrar nuevo | Sí |
| | Equipo / modelo | Autocompletado → `p_producto_id` o `p_producto_nuevo` | Sí |
| | Serial | `p_numero_serie` (3–60 car.) | No |
| | Nº de factura | `p_numero_factura` | No |
| | Categoría | Del producto; **solo lectura** salvo al registrar uno nuevo | — |
| | **Falla reportada** | `p_falla_reportada`, **5–2000 car.** | **Sí** |
| Cobertura | Fecha de compra | `p_fecha_compra` (≥ 2000-01-01) | Sí |
| | Tipo de garantía | `p_tipo_garantia` | Sí (ESTANDAR por defecto) |
| | Duración | `p_meses_override`; editable solo si EXTENDIDA | Condicional |
| | *(barra de vigencia)* | Cálculo en pantalla, espejo del trigger | — |
| Prioridad y asignación | Prioridad | `p_prioridad` | Sí (NORMAL por defecto) |
| | Técnico | `p_tecnico_id` (perfiles con rol TECNICO) | No |
| | Plazo de entrega | `p_sla_dias` (1–90, por defecto 5) | Sí |

**`falla_reportada` no aparece en el mockup y es obligatorio en la base.** Se añade como área de texto al final de la primera sección, con contador de caracteres y validación en el cliente (5–2000). Sin él la RPC falla con un error de `CHECK`, y es además lo primero que el técnico lee al abrir la orden.

**La categoría es de solo lectura al seleccionar un producto existente.** Es una propiedad del producto, no de la orden; hacerla editable sugeriría que se puede cambiar por orden, que es falso. Solo se escribe al registrar un producto nuevo.

**La barra de vigencia es un espejo, no la fuente.** Calcula `fecha_compra + meses` en el navegador para dar realimentación inmediata; el valor que queda guardado lo fija el trigger. Si divergen, manda el trigger. Se etiqueta como estimación.

### 7.2 Autocompletado (`SelectorAsincrono.jsx`)

Un componente base, dos usos. Comportamiento:

1. Desde 2 caracteres, busca con 300 ms de retardo.
2. Muestra hasta 8 coincidencias con el dato desambiguador visible (documento para clientes, marca para productos) — sin él, dos "Distribuidora El Faro" son indistinguibles.
3. Al elegir, guarda el **UUID**; el texto visible es solo etiqueta.
4. Sin coincidencias, ofrece "Registrar nuevo", que despliega los campos del alta **dentro del propio formulario**. No se inserta nada todavía: los datos se acumulan y viajan como `p_cliente_nuevo` / `p_producto_nuevo` en el mismo `crear_orden()`.
5. Teclado completo: flechas, Enter, Esc; `role="combobox"` con `aria-activedescendant`.

El punto 4 es lo que garantiza que no haya huérfanos: **hasta que la orden no se crea, no existe ningún cliente nuevo en la base.**

### 7.3 La entrega del token (`TokenDeConsulta.jsx`)

**Esta pantalla es un requisito funcional, no un extra.** `crear_orden()` devuelve `consulta_token` en claro exactamente una vez; en la base solo queda su SHA-256. Ni el ADMIN, ni el SQL Editor, ni `service_role` pueden recuperarlo. Si el modal se cierra sin mostrarlo, ese cliente pierde para siempre el acceso al portal público de esa orden.

Reglas:

- Al crear, el modal **no se cierra**: cambia a la vista de token.
- Muestra `numero_orden` + token en monoespaciada, con botón de copiar.
- Aviso explícito: *"Este código no se puede volver a mostrar. Anótalo o imprímelo antes de cerrar."*
- El botón de cerrar pide confirmación.
- El token **nunca** se guarda en `localStorage`, ni se registra en consola, ni viaja a ningún otro sitio.

---

## 8. Plan de ejecución

Cada paso arranca en **RED**: el test se escribe antes.

| Paso | Entrega | Verificación de cierre |
|---|---|---|
| **P1** | Migración `20260908000004`: columnas, trigger ajustado, `crear_orden()` | pgTAP: EXTENDIDA sin meses falla · SIN_GARANTIA no calcula fecha · `sla_dias` fuera de 1–90 falla · un `TECNICO` recibe `42501` · cliente y orden a la vez son atómicos · orden fallida no deja cliente |
| **P2** | `v_ordenes_tablero` + `kpis_tablero()` | pgTAP: con `anon` la vista devuelve **cero filas** · la vista no expone notas, costo ni diagnóstico · los KPIs cuadran con conteos directos |
| **P3** | `datos/` + hooks; el Tablero sigue con la fixture detrás del hook | Vitest sobre los hooks con cliente simulado: carga, vacío y error |
| **P4** | Tablero conectado: KPIs, tabla, vencimientos | La pantalla se ve igual que el mockup con datos reales; `datosDemo` ya no se importa en producción |
| **P5** | `FiltrosEstado` desde la base + búsqueda contra la vista | Añadir un estado con `INSERT` lo hace aparecer sin tocar React · buscar `Ana, S.A.` (con coma) no rompe la consulta |
| **P6** | Modal + formulario + autocompletado | Vitest: foco atrapado, Esc cierra, error por campo, `falla_reportada` con 4 caracteres bloquea el envío |
| **P7** | Alta real + entrega del token | El token se ve una vez; recargar no lo recupera; cerrar pide confirmación; el tablero muestra la orden nueva |

**P1 y P2 son bloqueantes.** Son SQL puro y definen la forma de los datos; el frontend no puede empezar antes.

### 8.1 Prueba de humo antes de dar por cerrada la fase

Con la clave `anon`:

```sql
select * from v_ordenes_tablero;   -- 0 filas
select kpis_tablero();             -- permiso denegado
```

Con un JWT de `TECNICO` que superó el segundo factor: ve las órdenes, y `crear_orden(...)` devuelve `42501`.

---

## 9. Decisiones registradas

Se incorporan al apéndice C del Blueprint maestro.

### ADR-007 · El tablero lee de una vista con `security_invoker`

**Decisión.** `v_ordenes_tablero WITH (security_invoker = true)`; filtro, búsqueda y paginación como parámetros de PostgREST.
**Alternativa descartada.** Una RPC `buscar_ordenes(termino, estado, pagina)`.
**Motivo.** La RPC obligaría a reimplementar en PL/pgSQL lo que PostgREST ya hace, y a tocar SQL cada vez que la interfaz necesite ordenar por otra columna. La vista da todo eso gratis.
**Riesgo cubierto.** Sin `security_invoker`, una vista ejecuta como su dueño y anula toda la RLS. Es la línea más importante de la definición, y su test en P2 (`anon` → cero filas) es lo que la protege de una edición futura descuidada.

### ADR-008 · `sla_dias` se guarda; la fecha límite se deriva

**Decisión.** Columna `SMALLINT` con el plazo comprometido en días; `sla_vence_el` se calcula en la vista.
**Alternativa descartada.** Guardar `sla_fecha_limite DATE`.
**Motivo.** Un valor derivado que se almacena puede desincronizarse de su origen sin que nada avise: corregida la fecha de ingreso, una fecha límite guardada seguiría apuntando al plazo viejo. Es la misma regla que ya aplica `PanelVencimientos.jsx` al no guardar "faltan N días".
**Consecuencia aceptada.** Extender el plazo de una orden significa subir su `sla_dias`, no mover una fecha.

### ADR-009 · El alta de cliente y producto ocurre dentro de `crear_orden()`

**Decisión.** La RPC recibe el UUID existente **o** el `JSONB` con los datos nuevos, y hace el alta en la misma transacción, con `ON CONFLICT` sobre las claves únicas reales.
**Alternativa descartada.** Un `INSERT` independiente desde el frontend antes de crear la orden.
**Motivo.** Con el `INSERT` aparte, un formulario abandonado deja un cliente sin órdenes, y dos recepcionistas dando de alta al mismo cliente a la vez producen un error de unicidad en la cara del segundo. Dentro de la transacción, si la orden falla el cliente desaparece con ella, y el `ON CONFLICT` convierte la carrera en una reutilización silenciosa.
**Contrapartida.** El autocompletado sigue siendo imprescindible: es lo que hace que el recepcionista **vea** al cliente existente antes de teclear uno nuevo. La atomicidad evita huérfanos; la búsqueda previa evita duplicados por errata. Hacen falta las dos.

### ADR-010 · La numeración `ORD-YYYY-NNNNNN` no cambia

**Decisión.** Se conserva el formato que genera la secuencia. La interfaz muestra el número tal cual.
**Alternativa descartada.** Renumerar a `OS-YYYY-XXXX` para acompañar el branding del mockup.
**Motivo.** Cambiar el `DEFAULT` sin reescribir el histórico deja dos formatos conviviendo en una columna `UNIQUE`, y toda búsqueda futura tendría que contemplar ambos, para siempre. Reescribir el histórico es una migración destructiva sobre el identificador que el cliente lleva impreso en su comprobante. Ninguna de las dos se justifica por estética.
**Principio general.** La interfaz se subordina a la verdad de los datos, no al revés.

---

## 10. Riesgos abiertos

| Riesgo | Impacto | Mitigación |
|---|---|---|
| La Fase 0 no está ejecutada: dos migraciones comparten el timestamp `20260906000001` | `supabase db reset` falla antes de llegar a esta migración | **Bloqueante para verificar P1/P2 contra una base real.** Ejecutar Fase 0 primero |
| El trigger de cobertura está probado y se modifica | Regresión silenciosa en el cálculo de vigencia | Los pgTAP existentes deben seguir verdes; los nuevos van en RED antes de tocarlo |
| `JSONB` mueve la validación de tipos dentro de la función | Un `marca_id` mal formado falla en tiempo de ejecución, no de firma | Los `CHECK` de `clientes`/`productos` siguen siendo los que validan; el frontend valida antes de enviar |
| Interpolación del término en la gramática de PostgREST | Consulta malformada, error opaco | Sanear `[(),*]` antes de construir el `.or()` |
| `ilike '%…%'` no usa índice | Ninguno al volumen actual | Si se nota: `pg_trgm` + GIN, sin tocar la interfaz |
| Renombrar `tablero/` a `taller/` rompe importaciones | Compilación falla, ruidosa e inmediata | Se hace en P3, en un commit propio y solo de movimientos |
| El árbol tiene churn de fin de línea (CRLF↔LF) en 70 archivos | Los commits se vuelven ilegibles | Commitear solo rutas explícitas; añadir `.gitattributes` con `* text=auto eol=lf` en un commit de normalización aparte |

---

**Fin del documento.** Al cerrarse la Fase 2, el Blueprint maestro se actualiza en §6 marcándola completada, y los ADR-007 a 010 pasan a su apéndice C.
