# Hito 1 — Registro y control de garantía · Reporte de lo hecho

**Fecha:** 2026-10-30 · **Rama:** `feat/registro-y-control` (base `b8d223d`) · **PR:** #1 (borrador)
**Spec:** `docs/superpowers/specs/2026-10-29-registro-y-control-de-garantia-design.md`
**Plan:** `docs/superpowers/plans/2026-10-29-registro-y-control-de-garantia.md` (22 tareas)

---

## 1. Resumen

El técnico ya puede **registrar un equipo por su serial** (con fotos y documentos, admitiendo lector de código de barras), verlo en el **Tablero** ordenado por la urgencia combinada (días de garantía restantes + días en taller/SLA) y **anotar revisiones** cuyo resultado lo calcula la base y que **no se pueden editar ni borrar** — ni por `service_role` ni por el dueño de la base.

Estado final verificado en el árbol: **SQL 237 aserciones en verde** (14 archivos de prueba SQL sobre Postgres 17 en Docker) · **e2e de punta a punta 9/9** (`scripts/e2e-registro.sh`) · **frontend 182 pruebas en verde** (19 archivos: services, asistente paso a paso, tablero, revisiones, tokens) · **lint 0** · **build 0** · **CI de GitHub en verde** (job de base de datos + job de frontend).

## 2. Tareas del plan (22, cada una en RED→GREEN)

### Cimientos (T5.1–T5.3 de infraestructura)
| # | Qué se hizo | Commits |
|---|---|---|
| 1 | **Ejecutor de pruebas SQL** `supabase/tests/run.sh`: Postgres 17 en Docker, roles emulados de Supabase (`anon`, `authenticated`, `service_role` BYPASSRLS), una base de datos LIMPIA por archivo de prueba (los scripts traen sus semillas), cortes estrictos en harness y migraciones, salida `PASA n · FALLA m` y exit 1 ante desvío; el ejecutor cuenta también los objetos inexistentes como fallo (un RED no puede quedar verde) | `c572628`, `ce1fd3f`, `57a526d` |
| 2 | **Historial de migraciones limpio**: el monolito duplicado `20260906000001_esquema_inicial.sql` (+ su `_referencia_`) archivado en `supabase/archivo/`; verificador `scripts/verificar-migraciones.sh` (en CI); `supabase/seed.sql` con 4 marcas y 8 productos (validado por `run.sh`) | `c572628`, `2d61c17` |
| 3 | **CI** (`.github/workflows/ci.yml`): job `base-de-datos` (verificador + `run.sh` + e2e) y job `frontend` (pnpm 10, Node 22.12, `pnpm install --frozen-lockfile`, test/lint/build); el PR #1 lo corrió en verde | `2f28f01`, `a742982..2f28f01` (fix de pnpm/action-setup) |

### Base de datos (T5.4–T5.14)
| # | Qué se hizo | Commits |
|---|---|---|
| 4 | `hoy_local()` (el día del taller en `America/Caracas`) y tabla `ajustes` con los umbrales de urgencia/SLA (3/7/7/15), escritura solo ADMIN y lectura de los roles internos | `fe875dc` |
| 5 | `calcular_cobertura()` **función pura** con la precedencia del spec (sin factura → POR_DETERMINAR; ingreso vencido → FUERA; señal o término incumplido → ANULADA con motivo; condición del trámite fallida → POR_DETERMINAR; resto EN_GARANTIA) + `motivo_anulacion()` (nombra lo observado) + `checklist_es_valido()` (claves exactas, booleanos) — 26 casos de prueba | `a5fb94f` |
| 6 | Tabla `equipos`: `serie_normalizada` generada (mayúsculas sin espacios/guiones, ceros a la izquierda), **única junto con `producto_id`**; `vence_el` generada (`fecha_emision + plazo_dias`, 1–365); soporte va todo junto o ninguno; solo lectura para roles internos | `ba60dbf` |
| 7 | Tabla `registros` (reemplaza `garantias`): correlativo `REG-AAAA-NNNNNN` desde `SEQUENCE` nativa (atómico, huecos aceptados), `historial_registros` inmutable con triggers, `notas_internas(registro_id)`, máquina de estados portada, permisos por rol; la prueba `99_pruebas_seguridad.sql` quedó portada a los nombres nuevos | `0996ba6` |
| 8 | `consultar_registro(número, token)`: consulta pública portada (anti-enumeración, freno de fuerza bruta por IP con bitácora, respuesta sin datos internos) — la pantalla queda para el hito 2 | `9b47ba7` |
| 9 | Tabla `revisiones`: el resultado lo **calcula el trigger** con `calcular_cobertura` (lo que envíe el cliente se ignora); el registro mantiene su cobertura al resultado de la última revisión; **solo de anexar**: UPDATE/DELETE/TRUNCATE rechazados con mensaje claro, también para `service_role` y el dueño | `9fdbd2b` |
| 10 | Tabla `adjuntos` + bucket privado `registros`: fotos JPG/PNG/WEBP y documentos PDF/JPG/PNG, 8 MB, máx. 8 fotos / 6 documentos por registro (validación en la base con mensajes claros); **solo de anexar** igual que revisiones; políticas de Storage por ruta `registros/{registro_id}/…` con guardia de formato uuid; `subido_por` con `DEFAULT auth.uid()` | `9eef18e`, `86fee0c` |
| 11 | RPC `guardar_cliente`, `buscar_equipo` (por serial en TODOS los productos, con historial) y `registrar_ingreso` (SECURITY DEFINER, transacción completa: crea o reutiliza el equipo con `ON CONFLICT`, el registro, su revisión de recepción y el token devuelto UNA vez); TECNICO puede registrar (cambio del hito, spec §6) | `a515129` |
| 12 | RPC `registrar_revision` (ADMIN/JEFE/TECNICO; RECEPCION rechazada) y `confirmar_compra` (solo ADMIN/JEFE: llena el soporte, deja quién y cuándo, recalcula la cobertura de los registros abiertos); pruebas de la matriz de 4 roles + anon | `5db76a8` |
| 13 | Vista `v_tablero` (`security_invoker`): días restantes y `nivel_vigencia` (VENCIDA/HOY/CRITICA/PRONTO/NORMAL/PENDIENTE), `dias_en_taller` y `nivel_sla` (NORMAL/ALERTA/CRITICO), **urgencia combinada** (la vigencia no cuenta si la cobertura ya no es EN/POR), cerrados con rank −1 al final; incluye `numero_soporte` para la búsqueda | `d957347`, `3b5fbdd` |
| 14 | `listar_huerfanos()` (anti-join `storage.objects` contra `adjuntos`, EXECUTE solo `service_role`) + Edge Function `limpiar-huerfanos` (exige `x-cron-secret`, modos simular/borrar; contrato de 7 pruebas vitest); el cron diario queda aguardado por la existencia de pg_cron/pg_net y lee secreto/URL de los ajustes de la base (post-despliegue) | `79a806a` |

### Frontend (T5.15–T5.22)
| # | Qué se hizo | Commits |
|---|---|---|
| 15 | `normalizarSerie`/`normalizarDocumento` + `registroService` (todas las RPC con nombres de parámetro exactos, validación temprana de adjuntos, mapeo de errores SIN_PERMISO/SIN_CONEXION/SESION_VENCIDA/FORMATO_NO_ADMITIDO/LIMITE/DESCONOCIDO) | `0e07853` |
| 16 | Borrador local con caducidad de **24 h**: clave por usuario (PC compartido), se borra al caducar/terminar, descarta archivos a CUALQUIER profundidad, y `cerrarSesion` limpia TODOS los borradores aunque falle la red | `f7ee696` |
| 17 | `useAsistente` (pasos, borrador ofrecido/restaurado, omite "compra" al reutilizar) y **PasoEquipo**: foco al abrir, búsqueda por Enter o pausa de 400 ms con 3+ caracteres, reutilización del equipo, advertencia de serial repetido con OTRO producto, catálogo marca/modelo (`listarProductos`) y **campo "Falla reportada"** (5–2000, obligatorio, medido como la base) | `999df77`, `f372ac5`, `f5050b9` |
| 18 | PasoCliente (documento normalizado + búsqueda del titular existente; teclear otro documento limpia el cliente hallado), PasoCompra (auto-commit por campo, vencimiento mostrado, casilla "no trae la factura" → por determinar) y PasoVerificacion (la cobertura SIEMPRE la pregunta a la base con el checklist COMPLETO; anulación con motivo; "Se calculará al guardar" si la base falla) | `76e95a4` |
| 19 | PasoAdjuntos (mensajes claros sin perder los adjuntos válidos; multi-archivo en lote), PasoResumen (con "Editar" por sección) y `enviarRegistro` (registro PRIMERO, adjuntos después; los fallidos quedan en `pendientes` con "Reintentar adjuntos"; el borrador se conserva si la sesión venció) | `c2b22b3` |
| 20 | **Tablero con datos reales**: `listarTablero` sobre `v_tablero` (búsqueda multicriterio por serial/titular/cédula/factura/número de registro, filtros por estado y urgencia), días restantes y días en taller por separado con su color, "Sin factura" para PENDIENTES, botón **"Nuevo registro"** que abre el asistente; los 4 roles aterrizan en `/tablero`; los datos de demostración se eliminaron | `3b5fbdd` |
| 21 | **Revisiones**: historial cronológico inverso (revisor por nombre, resultado, observaciones, SIN botones de editar/borrar) y formulario (misma lista de verificación; para RECEPCION no se muestra; errores legibles) | `1b5be5d` |
| 22 | **e2e de punta a punta** `scripts/e2e-registro.sh`: como TECNICO — guardar_cliente → registrar_ingreso (RT5-8842-AA, plazo 7) → aparece en `v_tablero` con sus 7 días → revisión con golpes → ANULADA_POR_USO con motivo → el UPDATE de la revisión falla; sale 1 ante cualquier desvío (probado con un desvío plantado) y quedó en la CI. Documentación: `ESTADO_DEL_PROYECTO.md` actualizado y README raíz completo | `c41b000`, `22ecbb1` |

### Trabajo adicional que llegó durante la ejecución (del propio equipo)
- **Idempotencia del envío** (migración `0012`): `registrar_ingreso` deduplica con `p_clave_envio` por usuario (`creado_por, clave_envio` + candado `pg_advisory_xact_lock`); la clave nace en el primer intento, viaja en el borrador (doble clic o reenvío tras caída no crea duplicados; el token no se reexpone). Probada con 7 casos nuevos. Commits: `57a526d`, `44474f8`, `7037f10`.
- **Estilos y modo oscuro** con tokens únicos (`frontend/src/styles/tokens.css`): 13 pares de contraste por tema asertados con WCAG real; asistente y revisiones con estilos; `App.css` de la plantilla eliminado. Commits: `78409fe`, `3d86e3d`, `eecd8bc`, `7bfe86b`.
- **Revert del hotfix del 2FA** (destinatario fijo): el código vuelve al correo del usuario que entra, con prueba que lo aserta. Commit: `4c015f3`. (Ver condiciones de despliegue.)

## 3. Pase de corrección del revisor final (multiagente, hallazgos → todos addressed)

El revisor de la rama y el revisor final reportaron 4 críticos + 9 importantes; **todos quedaron corregidos** (cada fix con su prueba en rojo primero) y las re-revisiones acotadas verificaron cada uno:

| Hallazgo | Arreglo |
|---|---|
| CRÍTICO · el asistente solo montaba el paso Equipo | Los 6 pasos montados y navegables + prueba de integración que registra de punta a punta (`e66b3ea`→`e9b2cac`) |
| CRÍTICO · contrato de adjuntos incompatible (política por segmento equivocado, `subido_por` sin DEFAULT, pruebas sembrando rutas inexistentes) | Ruta real `registros/{id}/…` en las políticas (segmento 2), `subido_por DEFAULT auth.uid()`, A14/A15/A16 actualizadas |
| CRÍTICO · checklist parcial rompía todo el flujo | El frontend envía el checklist COMPLETO (11 casillas, sin marcar = false); la previsualización usa la fecha de HOY |
| IMPORTANTE · Revisiones como código muerto | El botón "Revisar" abre `DetalleRegistro` con el historial y el formulario (`0e3e00b`) |
| IMPORTANTE · UPDATE directo de columnas críticas (cobertura/motivo/creado_por/tecnico/fecha) | `GRANT UPDATE` solo de estado/diagnóstico/accesorios/costo/recibido_por (`75b7390`); los triggers internos no necesitan el GRANT |
| IMPORTANTE · `p_fecha_ingreso` expuesto a cualquier autenticado | Solo ADMIN puede mandarla; los demás reciben `now()` (`c57267e`, aplicado a la definición viva de la 0012) |
| IMPORTANTE · lecturas sin comprobar rol (registros/historial/notas) | Las tres policies exigen `mi_rol()` de los 4 roles internos (`1d01c4a`) |
| IMPORTANTE · T12 aserción cabheada en TRUE | 3 aserciones de estado reales (`ccfce8d`) |
| IMPORTANTE · clienteId huérfano, compra sin auto-commit, selección múltiple que pierde archivos, borrador con archivos anidados, revisor como UUID, longitud sin trim | Todos corregidos (ver §2, tareas 16–21 y commits `b75641e`, `dd9cee7`, `18a515b`, `e9b2cac`, `c832f54`, `f5050b9`) |

## 4. Decisiones que tomé en tu nombre (rulings) — las de más peso

1. **Adelanté el archivado del monolito duplicado (D1)** a la Tarea 1: sin él la línea base era imposible (la cadena de migraciones no aplicaba).
2. **`run.sh` crea una base de datos NUEVA por archivo de prueba**: los scripts traen semillas con claves iguales y no conviven en una sola base (contaminación observada).
3. **Las pruebas SQL corren sin `ON_ERROR_STOP`** (harness/migraciones sí lo llevan): contiene errores previstos envueltos en BEGIN/ROLLBACK; sin eso una prueba aborta a medias y parece verde.
4. **`registrar_ingreso` lleva `p_fecha_ingreso` opcional** (DEFAULT now(), hoy solo ADMIN): se necesita para el cruce de día de Caracas y para cargas de historial; el frontend no lo manda.
5. **`revisiones.checklist` nullable y listado de catálogo (`listarProductos`)**: ingresos sin paso de verificación y marca/modelo del paso del serial, que el plan no cubría.
6. **El "motivo" de la cobertura lo pregunta `previsualizarCobertura` a `motivo_anulacion`** solo cuando la base dice ANULADA_POR_USO (el motivo obligatorio solo la base lo nombra).
7. **La "falla reportada" va en el paso Equipo** — el spec §7.1 no la asignaba a ningún paso (vacío real del spec).
8. **`p_clave_envio` (idempotencia) y los estilos/tokens**: trabajo integrado en el hito con revisión final en verde (ver §2).
9. **PR de borrador #1 creado** para validar el trabajo `pull_request` de la CI.

## 5. Condiciones de DESPLIEGUE (las debe ejecutar alguien con acceso al proyecto Supabase)

1. **Verificar el historial de migraciones REMOTO** (sin acceso de red desde aquí): en el SQL Editor, `select version from supabase_migrations.schema_migrations order by 1` — debe listar las 12 versiones (0001..0012). Si el remoto hubiese aplicado la **0008 ORIGINAL** (las correcciones de adjuntos se editaron en su lugar), hay que mover el DEFAULT de `subido_por` y las políticas de Storage a una migración **0013** antes del primer `db push` — si no, toda subida de adjuntos fallará en el remoto con RLS.
2. **Desplegar las 3 Edge Functions** (`mfa-enviar-codigo`, `admin-crear-usuario`, `limpiar-huerfanos`) — el revert del 2FA exige re-desplegar la primera (que el remoto no quede con el destinatario fijo).
3. **Limpieza programada**: definir `LIMPIEZA_SECRET` (`supabase secrets set`) y los ajustes de la base `app.limpieza_secret` / `app.proyecto_ref` (`ALTER DATABASE … SET`), y probar `limpiar-huerfanos?simular=1` contra el remoto (la simulación lista sin borrar).
4. **Dominio propio verificado en Resend** (SPF/DKIM/DMARC): hasta entonces el 2FA solo llega al dueño de la cuenta (estado documentado en README/ESTADO).

## 6. Diferidos (menores, revisados y aceptados)

- Reenvío de adjuntos sin `upsert` (un 409 atascable hasta el limpiador de 24 h).
- `crypto.randomUUID()` requiere contexto seguro (https/localhost): respaldo para http de intranet.
- Checklist comprometido vía preview con debounce de 250 ms (carrera de doble clic).
- Avatar con `#fff` sobre acento en modo oscuro ≈2,6:1 (par de contraste por debajo de AA).
- `outline:none` con sustitución en login.css/Tablero.css (preexistente a la rama).
- `btrim` de la base vs `String.trim` del navegador: relleno exótico (NBSP) puede dar >2000 en la base tras validar el front.
- La falla vacía no bloquea el "Siguiente" (el envío la valida con mensaje claro).
- Dialogs sin trampa de foco ni cierre con Escape; newlines finales pendientes en 3 archivos; I7/C7 dependen del calendario real (1 semana al año); filtros del Tablero con 6 de 10 estados y sin paginación real (limit 200).

## 7. Pendiente del hito 2

Pantalla pública del cliente (`consultar_registro` ya está lista en la base), consulta de facturas de Ventas (CSV), ruta propia del detalle del registro (`/registro/:id`; el panel actual del Tablero es reutilizable), cambio de estado/asignación en la UI, avisos de vencimiento, administración de usuarios y catálogo, reportes, y las pruebas pendientes del flujo de login (D4 del estado del proyecto).