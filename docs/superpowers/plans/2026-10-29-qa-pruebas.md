# QA de pruebas — línea base (sin correcciones aplicadas)

Corte 2026-10-29, rama `feat/registro-y-control`. Solo lectura y ejecución: el árbol de trabajo está sucio (ver abajo) y /qa exige árbol limpio antes de corregir, así que **no se arregló ni se hizo commit de nada**.

## Resultados

| Suite | Resultado |
|---|---|
| vitest (17 archivos) | 149 ✅ · **1 ❌** |
| SQL (`supabase/tests/run.sh`, Postgres 17 en Docker) | todo ✅ salvo **1 ❌** |
| lint (oxlint) | 0 errores · 7 avisos |
| build | ✅ (chunk 525 kB) |

## Hallazgos

| ID | Severidad | Hallazgo | Estado |
|---|---|---|---|
| QA-1 | Media | `PasoEquipo.test.jsx:160` — `" hola "` pasa la validación local (`texto.length` sin `trim`) pero la base mide `length(btrim())` ⇒ error 22P02 al enviar. Arreglo: medir `texto.trim().length` en `errorDeFalla` (`PasoEquipo.jsx:16-21`) | Prueba roja escrita, sin implementar |
| QA-2 | Media | `15_adjuntos.sql` A16 — `subido_por` sin valor no se atribuye a la sesión; la migración `…0008` ya tiene el `DEFAULT auth.uid()` en el árbol sucio, pero el script no lo ve verde | Pendiente de investigar (¿el default no aplica por el rol del INSERT o por el orden del `ALTER`?) |
| QA-3 | Alta | Sin pruebas de idempotencia de `registrar_ingreso` (doble envío ⇒ 2 registros) | Cobertura faltante (ver revisión de ingeniería H1/H2) |
| QA-4 | Alta | Sin pruebas del flujo completo de login con 2FA (D4) y `mfa-enviar-codigo` aún con `DESTINATARIO_TEMPORAL` | Cobertura faltante |
| QA-5 | Media | Asistente y Revisiones sin estilos (0 `className`); no hay pruebas visuales ni de accesibilidad automatizadas | Cobertura faltante (revisión de diseño D-6) |
| QA-6 | Baja | Avisos de lint: `waitFor`, `PDF`, `subir`, `afterEach` sin usar; `normalizar.js:21` escape inútil; `useAsistente.js:25` `setState` dentro de efecto; `AuthContext.jsx:155` fast-refresh | Limpieza |
| QA-7 | Baja | `ESTADO_DEL_PROYECTO.md` dice 104 pruebas / 210 aserciones: desactualizado | Documentación |
| QA-8 | Baja | `t.out` y el PDF sin trackear en la raíz | Higiene |

## Árbol sucio (motivo por el que no se corrigió)

`PasoEquipo.test.jsx`, `…0008_adjuntos.sql` y `tests/15_adjuntos.sql` tienen trabajo en curso sin commit; son justo los dos rojos. Mezclar correcciones de QA ahí rompería la atomicidad de los commits.

## Siguiente paso propuesto

1. Commit del WIP actual (pruebas rojas + cambio de migración) como punto de partida.
2. Corregir QA-1 y QA-2 con commits separados, cada uno con su prueba verde.
3. Escribir las pruebas de QA-3 (primero rojas) junto con la decisión de idempotencia.
