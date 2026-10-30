# Inventario: qué está y qué no (corte 2026-10-29, rama `feat/registro-y-control`)

Fuentes: plan de 22 tareas (`2026-10-29-registro-y-control-de-garantia.md`), `ESTADO_DEL_PROYECTO.md`, y ejecución real de `pnpm test`, `pnpm lint`, `pnpm build` y `supabase/tests/run.sh`.

## Verificación real (hoy)

| Chequeo | Resultado |
|---|---|
| vitest | 149 pasan, **1 falla**: `PasoEquipo.test.jsx:160` (`" hola "` debe medirse con `trim()`; `errorDeFalla` usa `texto.length`) |
| Pruebas SQL | Todo verde salvo **`15_adjuntos.sql` A16** (`subido_por` por defecto = usuario de sesión) |
| lint | 0 errores, 7 warnings (imports sin usar, `set-state-in-effect` en `useAsistente.js:25`) |
| build | OK; chunk de 525 kB (>500 kB) |

Los 2 rojos son trabajo en curso sin commitear (`PasoEquipo.test.jsx`, migración `…0008_adjuntos.sql`, `tests/15_adjuntos.sql`): pruebas escritas primero, falta la implementación.
`ESTADO_DEL_PROYECTO.md` dice "210 aserciones / 104 pruebas": está desactualizado (hoy 150 en frontend).

## Plan de 22 tareas

| Bloque | Tareas | Estado |
|---|---|---|
| Infra (rama, ejecutor SQL, migraciones limpias, CI) | 1–3 | ✅ |
| BD: ajustes, cobertura, equipos, registros, consulta pública | 4–8 | ✅ |
| BD: revisiones, adjuntos, RPC ingreso/revisión, `v_tablero`, huérfanos | 9–14 | ✅ salvo adjuntos A16 (🔴 en curso) |
| Frontend: servicios, borrador, asistente (pasos 1–6) | 15–19 | ✅ salvo validación de falla con `trim` (🔴 en curso) |
| Tablero real y revisiones | 20–21 | ✅ |
| Integración punta a punta y documentación | 22 | 🟡 `e2e-registro.sh` existe; docs desactualizadas |

## Lo que NO está (fuera del hito 1)

- Pantalla pública `/consulta` (la RPC `consultar_registro` existe) — H2-1
- Facturas de Ventas (fuente por decidir) — H2-2
- Detalle en ruta propia `/registro/:id`, cambio de estado/asignación de técnico — H2-3, H2-4
- Avisos de vencimiento por correo — H2-5
- Administración de usuarios, clientes y catálogo, reportes, carga masiva CSV — H2-6 a H2-9
- Recuperar / cambiar contraseña
- 2FA: pruebas del flujo completo de login (D4) y dominio verificado en Resend; `Panel.jsx` sigue provisional para jefe/técnico/recepción
- Cierre remoto: historial de migraciones remoto (D10/C1), `limpiar-huerfanos` simulado (C2)
- Hotfix temporal del 2FA (destinatario fijo): **pendiente de revertir** (ver memoria del proyecto)

## Higiene del repo

`t.out` (salida de pruebas) y `Prime Telecom — Garantías.pdf` sin trackear; deberían ir a `.gitignore` o borrarse. `docs/` aún sin commitear.
