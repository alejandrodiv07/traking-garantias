# Revisión de ingeniería — Registro y control de garantía

Base: plan de 22 tareas + código real de la rama `feat/registro-y-control` (corte 2026-10-29). Complementa `2026-10-29-inventario-que-esta-y-que-no.md`.

## 1. Arquitectura de un vistazo

```
 SPA React ──supabase-js──► Auth (JWT)  ──► mi_rol() exige mfa_ok()
   │                         PostgREST + RLS por rol
   ├─ registrar_ingreso()  ─► equipos (upsert) → registros → revisiones (trigger calcula cobertura)
   ├─ subirAdjunto()       ─► Storage 'registros/{registro_id}/…' → fila en adjuntos (solo anexar)
   ├─ v_tablero            ─► urgencia = vigencia garantía × SLA
   └─ registrar_revision() ─► revisiones (inmutables)
 Edge: mfa-enviar-codigo → Resend · admin-crear-usuario · limpiar-huerfanos (cron)
```

Decisión sólida: la autorización y la cobertura viven en Postgres (SECURITY DEFINER + `search_path` fijo + REVOKE a `anon`). Se mantiene.

## 2. Flujo de datos (alta de un registro)

1. Asistente de 6 pasos → borrador local 24 h (sin archivos).
2. `enviarRegistro` → **`registrar_ingreso`** (1 transacción: equipo + registro + revisión de recepción).
3. N subidas **secuenciales y no transaccionales** a Storage + `adjuntos`.
4. Si todo subió, se borra el borrador; si no, `pendientes` queda solo en memoria.

Saltos de red: 1 RPC + 2N llamadas (Storage + insert). Puntos donde el estado se desfasa: entre 2 y 3 (registro sin adjuntos), y entre Storage y `adjuntos` (objeto huérfano; lo limpia `limpiar-huerfanos`).

## 3. Propiedad del estado

| Estado | Dueño / fuente de verdad | Ambigüedad |
|---|---|---|
| Cobertura | Trigger de `revisiones` | Ninguna (bien) |
| Token de consulta | Solo hash en BD; texto plano una vez | Si la respuesta se pierde, el token se pierde (ver H1) |
| Estados (`dominio.js`) vs BD | BD; `dominio.js` es espejo | Riesgo de deriva, sin prueba que lo ate |
| `pendientes` de adjuntos | Memoria del componente | Se pierde al recargar; el borrador ya se ve “limpio” o no según el caso (H2) |
| Documentación | `ESTADO_DEL_PROYECTO.md` | **Desactualizada**: sigue describiendo `garantias`, `crear_garantia` y `consultar_garantia`, que la migración `…0006` elimina (`DROP TABLE garantias`) |

## 4. Casos límite y modos de fallo

| # | Caso | Comportamiento hoy | Veredicto |
|---|---|---|---|
| H1 | **Doble envío / reintento tras timeout**: `registrar_ingreso` no es idempotente | Crea 2 registros, 2 revisiones y 2 tokens para el mismo equipo; no hay clave de idempotencia ni restricción “un registro abierto por equipo” | 🔴 Real. Un doble clic o una red lenta ensucian el Tablero y el SLA |
| H2 | Registro creado, pestaña cerrada antes de subir adjuntos | Registro sin evidencias; el borrador sigue vivo (no se limpió) → al restaurar y reenviar se **duplica** el registro (mismo hueco que H1) | 🔴 Mismo arreglo que H1 |
| H3 | Equipo ya existente con titular o soporte distinto | `registrar_ingreso` ignora en silencio `p_cliente_id`, soporte, plazo y vendedor si el equipo existe | 🟠 Decidir: ¿avisar, actualizar o rechazar? |
| H4 | Falla con espacios (`" hola "`) | BD mide `length(btrim())`; el front mide sin `trim` → el usuario ve éxito local y recibe error 22P02 | 🟠 Prueba ya escrita y en rojo (`PasoEquipo.test.jsx:160`); falta el arreglo |
| H5 | `subido_por` | Se cambió el DEFAULT editando la migración `…0008` ya existente | 🟠 Si `…0008` ya se aplicó en algún entorno, la edición **no se ejecuta**. Mover a una migración nueva `…0012` o confirmar que ningún entorno la aplicó (D10) |
| H6 | Concurrencia: dos revisiones simultáneas | Ambas se anexan; la cobertura la fija la última | 🟡 Aceptable si es la intención; documentarlo |
| H7 | Sesión vencida a media subida | Se conserva el borrador (bien); los adjuntos subidos antes quedan atados al registro | 🟡 OK |
| H8 | Permisos | RECEPCION no registra revisiones (spec §6); `anon` sin acceso al bucket | ✅ Cubierto por SQL (17, 99) |
| H9 | Hotfix 2FA | `mfa-enviar-codigo` aún envía a `DESTINATARIO_TEMPORAL` (todos los códigos al mismo correo) | 🔴 Seguridad: debe revertirse antes de producción (dominio Resend) |
| H10 | Sin límite de tamaño/cantidad de adjuntos del lado servidor | “Sin cuotas por usuario” (comentario de la migración) | 🟠 Un usuario interno puede llenar el bucket; fijar `file_size_limit` y `allowed_mime_types` en el bucket |
| H11 | `Login.jsx` 573 líneas, `Tablero.jsx` 237 | Funciona | 🟡 Dividir antes de seguir creciendo |
| H12 | Bundle 525 kB sin code-splitting | Aceptable en intranet | 🟡 `React.lazy` por ruta |

## 5. Matriz de pruebas (derivada de los casos)

| Caso | Prueba que falta o está en rojo | Capa |
|---|---|---|
| H1/H2 | Llamar dos veces `registrar_ingreso` con la misma clave de idempotencia ⇒ mismo `registro_id`, 1 sola revisión | SQL `16_rpc_ingreso` |
| H1 | Doble clic en “Enviar” ⇒ 1 sola llamada (botón deshabilitado en vuelo) | vitest `NuevoRegistro` |
| H2 | Restaurar borrador tras envío parcial no crea otro registro | vitest `enviarRegistro` |
| H3 | Equipo existente + titular distinto ⇒ comportamiento definido | SQL `16` |
| H4 | `" hola "` ⇒ “va de 5 a 2000” (**rojo hoy**); `"     "` ⇒ obligatoria | vitest `PasoEquipo` |
| H5 | INSERT sin `subido_por` ⇒ atribuido a la sesión (**rojo hoy**, A16) | SQL `15_adjuntos` |
| H9 | Edge function usa `usuario.user.email`, no una constante | deno `index.test.ts` |
| H10 | Archivo > límite o mime no permitido ⇒ rechazo del bucket | SQL/e2e |
| `dominio.js` | Lista de estados del front == `estados` de la BD | SQL+vitest (script de comparación) |

## 6. Supuestos ocultos (confirmar)

1. Los 3 entornos (local, CI, remoto) parten de cero con la cadena `0001…0011`; ningún remoto aplicó ya `…0008` original.
2. Un equipo con el mismo serial dentro del mismo producto es **siempre** el mismo equipo físico.
3. Nadie necesita borrar registros (solo anular); el diseño no tiene `DELETE`.
4. Resend seguirá en sandbox hasta contar con dominio; el destinatario fijo es solo temporal.
5. La hora operativa es la de `hoy_local()` (un único huso).
6. El bucket privado nunca sirve URLs públicas; la lectura es por URL firmada.

## Decisiones abiertas para usted

- **H1/H2:** ¿Idempotencia con `p_clave_envio uuid` generado por el asistente (recomendado), o bloquear por “un registro abierto por equipo”?
- **H3:** Equipo existente con datos distintos: ¿rechazar, avisar al técnico, o actualizar?
- **H5:** ¿Migración nueva `…0012` (recomendado) o seguir editando `…0008`?
