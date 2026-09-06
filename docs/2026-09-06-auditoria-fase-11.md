# Auditoría de la Fase 11 — Cierre del backend de login

**Fecha:** 2026-09-06 · **Proyecto:** Prime Telecom · **Alcance:** `backend/` completo tras la Fase 11 (E2E, adaptador MFA, integración React)
**Perfiles ejecutados:** `/gs-qa` (calidad y estabilidad) y `/gs-cso` (pentest estático)
**Estado de la suite al cerrar:** 223 passed, 1 skipped (`test_colacion_email_es_as_cs`, solo MySQL 8)

> **Descargo.** Esto es un primer filtro asistido por IA sobre el código real del repositorio, no un sustituto de una auditoría profesional. Cubre patrones conocidos; no garantiza ausencia de vulnerabilidades. Para producción con datos de clientes sigue haciendo falta una revisión humana especializada.

---

## 0. Resumen ejecutivo

```
POSTURA DE SEGURIDAD — Fase 11 (backend de login completo)
══════════════════════════════════════════════════════════
Candidatos evaluados:  19
Reportados:            16   (3 descartados como falso positivo)
Corregidos en esta entrega:  6
Abiertos:              10   (3 de ellos son alcance declarado de fases posteriores)

  CRITICAL  0
  HIGH      6   → 3 corregidos, 3 abiertos
  MEDIUM    7   → 3 corregidos, 4 abiertos
  LOW       3   → 0 corregidos, 3 abiertos

Veredicto: NO APTO PARA PRODUCCIÓN — apto para continuar la Fase 1-A.
```

El veredicto no es alarmismo. Tres de los hallazgos abiertos son estructurales y ya estaban en el plan (rate limiting, `ProxyFix`, cabeceras de seguridad = Paso 10; validación CSRF en servidor y `GET /me` = Paso 9 incompleto). Los otros siete son huecos entre lo que el `AUTH_BLUEPRINT.md` **afirma** y lo que el código **hace** — que es exactamente lo que una auditoría de código, y no de documento, sirve para encontrar.

Lo que sí está sólido, y conviene decirlo porque es la mayor parte: Argon2id con los parámetros correctos, cero secretos en claro en base de datos (verificado con consulta literal en E2E), `PEPPER` sin fallback, tokens de 32 bytes del CSPRNG, comparación en tiempo constante, y la separación 401-con-commit / 500-con-rollback funcionando de verdad.

---

## 1. `/gs-qa` — Calidad y estabilidad

### 1.1 Fugas de conexión en el override de `get_db()`

**Veredicto: sin fuga.** Tres propiedades lo sostienen, y las tres son deliberadas:

| Riesgo | Cómo se cierra | Dónde |
|---|---|---|
| `Session` que no se cierra si el handler lanza | `finally: session.close()` incondicional | `dependencies.session_scope` |
| El test reimplementa el `try/except` y diverge del de producción | El override **reutiliza** `session_scope`; solo cambia de dónde sale la Session | `tests/e2e/conftest.py::override_get_db` |
| Conexiones del pool vivas al terminar la sesión de pytest | `engine.dispose()` en el teardown del fixture de sesión | `tests/e2e/conftest.py::engine` |

Sin el `dispose`, el fichero SQLite queda abierto cuando pytest limpia `tmp_path` — fatal en Windows, que no borra ficheros con descriptores vivos — y contra MySQL cada corrida dejaría una conexión colgando en el servidor.

Un detalle que merece constancia: si el `commit` de la rama `HTTPException` fallara (base caída), la excepción nueva sustituye a la `HTTPException` y sale como 500. Es lo correcto: no hay respuesta de negocio que dar si no se pudo escribir la auditoría. La conexión se cierra igual.

### 1.2 Excepciones no capturadas

**QA-01 · MEDIUM · CORREGIDO — `POST /login` devolvía 200 con cuerpo vacío ante un `outcome` desconocido.**
El router tenía tres `if` sin `else`. Un `LoginResult` con un outcome nuevo caía por el final de la función y FastAPI serializaba `None` con un 200. El frontend lo habría leído como "sesión abierta" sin que existiera ninguna cookie. Ahora es un 500 explícito: un caso de uso que devuelva algo inesperado debe romper ruidosamente, no abrir la puerta.

**QA-02 · MEDIUM · CORREGIDO — oráculo por `ValueError` de `PlainPassword`.** Detallado en §2.3 (es a la vez defecto de estabilidad y vulnerabilidad).

**Sobre "tumbar Uvicorn": descartado como falso positivo.** Starlette envuelve cada petición en `ServerErrorMiddleware`; una excepción no capturada produce un 500 y el worker sigue vivo. Con `debug=False` (el valor por defecto de FastAPI, y no se activa en ningún sitio del repositorio) el cuerpo es `Internal Server Error` sin traza ni SQL. **Pendiente menor (QA-03 · LOW):** no hay `@app.exception_handler` propio, así que un 500 no deja entrada estructurada en el log ni correlación. Antes de producción conviene añadirlo.

### 1.3 Idempotencia del logout

**CSO-01 / QA-04 · HIGH · CORREGIDO.** Ver §2.1: el logout no revocaba nada. La idempotencia se especificó y se probó como parte de la corrección: sin cookie, con cookie que no resuelve fila, y dos veces seguidas → 200 en los tres casos, el evento de auditoría se emite una sola vez y la hora del cierre original **no** se reescribe (`test_es_idempotente_y_no_reescribe_la_hora_del_cierre`).

Un 4xx aquí habría sido peor que inútil: convierte "ya estabas fuera" en un error que el usuario no puede resolver, y de paso le regala a quien tenga una cookie robada un endpoint gratuito para comprobar si sigue viva.

### 1.4 Reintentos de MFA — dos huecos reales

**QA-05 · HIGH · ABIERTO — no se invalida el desafío anterior, ni hay tope de desafíos por cuenta.**
`AUTH_BLUEPRINT.md` §4.4 lo especifica en dos reglas (1 y 6) y ninguna está en el código: `MfaChallengeRepository.create` solo hace `INSERT`, y `LoginUseCase._iniciar_desafio_mfa` no cuenta nada.

Consecuencia concreta: quien ya tenga la contraseña vuelve al paso 1 tantas veces como quiera. Cada vuelta abre un desafío nuevo con 5 intentos frescos y su propia cookie `pt_mfa`, y los anteriores siguen vivos. El cálculo del blueprint —"5 intentos en 600 s ≈ 1 en 200.000"— deja de aplicar: con paciencia se cubre el espacio de 10⁶. De paso, cada vuelta dispara un correo: el login se convierte en un cañón de spam contra la víctima.

*Corrección:* `COUNT(*) WHERE user_id=? AND created_at > NOW()-INTERVAL 15 MINUTE` antes de crear (rechazar con `TOO_MANY_CHALLENGES`), y `UPDATE mfa_challenges SET consumed_at=NOW() WHERE user_id=? AND consumed_at IS NULL` al crear el nuevo. El test que lo fija ya está escrito en el blueprint: `test_sexto_desafio_en_15_min_es_rechazado`.

**QA-06 · HIGH · ABIERTO — el estado de la cuenta no se revalida en el paso 2.**
`AUTH_BLUEPRINT.md` §4.4 regla 8. `VerifyMfaUseCase` carga el usuario y emite la sesión sin volver a mirar `is_active` ni `locked_until`. Entre el paso 1 y el 2 hay 10 minutos de ventana: un `ADMIN` que desactive a un empleado durante ese rato descubre que el empleado entra igual. El blueprint incluso trae el test escrito (`test_usuario_desactivado_entre_paso1_y_paso2_no_obtiene_sesion`).

**QA-07 · LOW — no existe `POST /login/resend-mfa`.** La pantalla del frontend ya tiene el hueco (`onResend`); el endpoint no está. Sin él, un código que se pierde obliga a rehacer el paso 1, que es justo lo que QA-05 hace peligroso.

### 1.5 Otros hallazgos de calidad

| # | Sev | Hallazgo | Nota |
|---|-----|----------|------|
| QA-08 | MEDIUM · **CORREGIDO** | `tests/api` mutaba `app.dependency_overrides` en el import y no lo deshacía | Cualquier suite posterior recibía el fake del `LoginUseCase`. La E2E habría probado el doble, con fallo dependiente del orden de recolección |
| QA-09 | MEDIUM · **CORREGIDO** | El test de logout no tenía override → habría escrito en `dev.db` | `FakeLogoutUseCase` en el fixture |
| QA-10 | MEDIUM · **CORREGIDO** | `fileConfig` de Alembic apagaba los loggers existentes | `disable_existing_loggers=False`. Dejaba mudo al adaptador de notificaciones al correr migraciones en proceso |
| QA-11 | LOW · ABIERTO | Los casos de uso usan `datetime.utcnow()` para calcular vencimientos en vez del `now` inyectado | Dos relojes en la misma operación, y `utcnow()` está deprecado desde 3.12 |
| QA-12 | LOW · ABIERTO | `VerifyMfaUseCase._record_attempt` recarga el usuario en cada llamada | Recibe `user_id` y hace `get_by_id` para leer el email; el llamador ya tenía el objeto |

---

## 2. `/gs-cso` — Pentest estático

### 2.1 Robustez de cookies y ausencia de tokens en payload

**Verificado correcto:**

- El token de sesión **no aparece** en el cuerpo de ninguna respuesta (`test_el_token_de_sesion_no_viaja_en_el_cuerpo_ni_se_guarda_en_claro`).
- En base de datos se guarda `SHA-256`, nunca el token: consulta literal por el valor en claro → 0 filas; por su hash → 1 fila. Ídem para `pt_csrf` y para el código OTP (HMAC con pepper).
- `Secure` y `SameSite=Lax` en las tres cookies. `HttpOnly` en `pt_session` y `pt_mfa`.

**CSO-01 · HIGH · CORREGIDO — el logout no revocaba la sesión.**
Sólo emitía dos `Set-Cookie` de borrado. La fila de `auth_sessions` seguía con `revoked_at IS NULL`, así que el token continuaba válido hasta su `absolute_expires_at` (8 h). El punto que lo convierte en HIGH y no en cosmético: **el borrado de cookie lo ejecuta la víctima, no el atacante.** Quien ya tuviera el token —XSS, backup filtrado, portátil compartido— se quedaba dentro; el único efecto del logout era expulsar al usuario legítimo.

**CSO-02 · HIGH · CORREGIDO — `pt_csrf` salía con `HttpOnly=True`.**
La defensa CSRF del §5.1 es double-submit atado a la sesión: la SPA lee `pt_csrf` y la devuelve en `X-CSRF-Token`; el servidor compara `sha256(cabecera)` contra `auth_sessions.csrf_hash`. Con `HttpOnly`, `document.cookie` no la ve, la SPA nunca puede mandar la cabecera y **toda la defensa queda inerte**: el `csrf_hash` se escribe en cada login y nadie lo lee jamás. El peligro no es el flag, es que parece que hay protección.

Corregido en la emisión. **Queda abierta la otra mitad (CSO-03, abajo).**

**CSO-03 · HIGH · ABIERTO — no existe validación de CSRF ni de `Origin` en el servidor.**
No hay middleware que compare la cabecera contra `auth_sessions.csrf_hash`, ni lista blanca de `Origin` en los métodos mutantes. Es el Paso 9 a medias: el esquema tiene la columna, el login la rellena, el frontend ya manda la cabecera, y nadie la verifica. Con `SameSite=Lax` el riesgo práctico hoy es bajo (Lax no adjunta cookies en POST cross-site), pero la protección declarada en la matriz de trazabilidad no existe.

**CSO-04 · MEDIUM · ABIERTO — falta el prefijo `__Host-` y la política de `Max-Age`.**
`AUTH_BLUEPRINT.md` §5.1 punto 3 pide `__Host-pt_session`. Sin él, un subdominio comprometido puede sobrescribir la cookie de sesión (efecto denegación de servicio sobre la víctima). Además, las cookies se emiten sin `Max-Age`, así que son de sesión de navegador mientras la base dice 8 h: el "Recordarme" del `Login.jsx` no tiene nada detrás. Ambas son una línea de configuración.

*Nota de desviación consciente:* el blueprint especifica `SameSite=Strict` y la implementación usa `Lax`. Es defendible (Strict rompe la vuelta desde enlaces externos), pero conviene anotarlo en la matriz de trazabilidad en lugar de dejar dos documentos que se contradicen.

### 2.2 Fallo de negocio (401 + commit) vs. fallo de sistema (500 + rollback)

**Verificado impenetrable, y probado de extremo a extremo.**

`session_scope` trata `HTTPException` como lo que es —una respuesta de negocio controlada— y confirma la transacción; cualquier otra excepción revierte. Es la única definición de esa regla en el código, y la suite E2E la ejerce contra base real: `test_login_fallido_devuelve_401_y_persiste_el_intento` comprueba que tras el 401 la fila de `login_attempts` sigue ahí con `outcome='BAD_PASSWORD'`.

Por qué importa para fuerza bruta y enumeración: un `except: rollback` ingenuo habría borrado justo las filas de los intentos fallidos —el rastro que alimenta el backoff de la directiva 3— dejando un sistema que registra los éxitos y olvida los ataques. El bloqueo por cuenta habría sido decorativo.

**CSO-05 · HIGH · ABIERTO — el rastro forense está incompleto: `ip_address` y `user_agent_hash` siempre son `NULL`.**
`LoginUseCase.execute` los acepta como parámetros, pero el router **no los pasa nunca**. Consecuencia: `login_attempts.ip_address` es NULL en todas las filas, el índice `idx_att_ip_time` no sirve para nada y la detección de ataque distribuido por IP —justificación explícita de ese índice en §4.3— no puede existir. Lo mismo para `auth_sessions.ip_address` y `user_agent_hash`, que son la base de la futura detección de robo de sesión.

Esto se cruza con la ausencia de `ProxyFix` (§2.4): no tiene sentido empezar a guardar IPs antes de resolver de dónde sale la IP real, porque se llenaría la tabla con la del proxy. Los dos se arreglan juntos, en el Paso 10.

### 2.3 Oráculo de tiempo — CORREGIDO

**CSO-06 · HIGH · CORREGIDO.** `LoginUseCase` evaluaba `locked_until` e `is_active` **antes** de llegar a Argon2. El ataque no adivina contraseñas, mide relojes:

1. El atacante manda 5 intentos fallidos contra `nombre.apellido@primetelecom.com`. Si la cuenta existe, queda bloqueada.
2. Sexto intento, cronómetro en mano: cuenta bloqueada → ~5 ms (corta antes de hashear); cuenta inexistente → ~100 ms (paga el hash).
3. Veinte veces de diferencia, muy por encima del ruido de red, con un 401 idéntico en ambos casos. Enumera el directorio completo a 6 peticiones por correo.

Corregido en dos capas, las dos que pide el §5.0:

- **Orden fijo.** La verificación Argon2 se ejecuta siempre —contra el hash real o contra `DECOY_HASH`— antes de mirar el estado de la cuenta. El `outcome` se decide después, cuando todos los caminos ya pagaron lo mismo.
- **Deadline en el handler.** `PRIME_LOGIN_TIME_BUDGET_MS`, por defecto 250 ms, con `time.monotonic`.

El señuelo es una **constante** y no un cálculo de arranque, por coste. El riesgo de una constante es que los parámetros de Argon2 cambien y se quede barata en silencio: lo cierra `test_el_senuelo_usa_los_parametros_vigentes`, que falla en rojo el día que alguien suba `_MEMORIA_KIB` sin regenerarla.

**Residuales anotados:**
- `POST /mfa/verify` no tiene presupuesto de tiempo. Sus caminos de fallo son mucho menos enumerables (hace falta la cookie `pt_mfa`, que exige haber superado el primer factor), pero conviene igualarlo cuando se toque el Paso 10.
- Una contraseña fuera del rango 12-128 responde antes que una dentro de rango, porque el corte por longitud precede a Argon2. **No es un oráculo:** el corte no depende de que la cuenta exista, lo decide solo lo que el atacante escribió.

**CSO-07 · MEDIUM · CORREGIDO — el `ValueError` de `PlainPassword` era un oráculo de enumeración.**
`PlainPassword` exige 12-128 caracteres. Ese punto del flujo solo se alcanza si el correo **existe** y la cuenta está activa y sin bloquear, así que una contraseña de 10 caracteres daba **500 con cuenta real y 401 con cuenta inexistente** — enumeración completa sin adivinar una sola contraseña. Y `Login.jsx` exige hoy exactamente 10 (`MIN_PASSWORD = 10`), así que no era un caso de laboratorio: era el formulario en producción.

Corregido: se trata como fallo de verificación (401 + `BAD_PASSWORD`). **Acción pendiente para ti:** subir `MIN_PASSWORD` a 12 en `Login.jsx` para que el cliente y el dominio digan lo mismo.

### 2.4 `PEPPER`, secretos y parámetros criptográficos

**Verificado correcto:**

- **`PEPPER` sin fallback.** `get_pepper()` lanza `RuntimeError` si falta. Un valor por defecto silencioso significaría dos cosas malas a la vez: un secreto conocido en producción y, si cambiara entre arranques, un índice de auditoría ilegible hacia atrás.
- **Argon2id con `m=64 MiB, t=3, p=4`,** exactamente lo que dicta la directiva 2. Verificado en el código y fijado por test contra el señuelo.
- **Salt por hash** (lo genera `argon2-cffi`), tokens con `secrets.token_urlsafe(32)`, OTP con `secrets.randbelow(1_000_000)` formateado a 6 dígitos, comparaciones con `hmac.compare_digest`. Cero criptografía escrita a mano.
- **El OTP en el log está cerrado con dos barreras:** el código en claro exige `PRIME_MFA_LOG_CODE=1` explícito, y con `PRIME_ENV=production` esa combinación se rechaza al arrancar. Por defecto se enmascara y el login con MFA no se completa — fallar hacia el lado que no expone el factor.

**CSO-08 · MEDIUM · ABIERTO — `SECRET_KEY` está en `.env.example` y no lo lee nadie.**
No es una vulnerabilidad hoy (no hay nada que firmar), pero una variable de secreto declarada y sin consumir es una invitación a que alguien la reutilice mal más adelante. O se usa, o se quita.

**CSO-09 · LOW — rotación del `PEPPER` sin procedimiento.** Ya declarado como deuda en el blueprint §7. Rotarlo invalida todos los `email_hmac` y `code_hmac` históricos; hace falta escribir el procedimiento antes de producción.

### 2.5 Huecos entre el esquema y lo que el código hace

Estos cuatro comparten una forma: la columna existe, el diagrama la explica, y ningún código la escribe o la lee.

| # | Sev | Columna / regla | Qué falta | Consecuencia |
|---|-----|-----------------|-----------|--------------|
| CSO-10 | MEDIUM · ABIERTO | `users.email_verified_at` | `LoginUseCase` no la comprueba | Una cuenta con el correo sin verificar inicia sesión. El segundo factor viaja a un buzón que nadie confirmó: el 2FA es una ilusión en ese caso (§4.1 lo dice literalmente) |
| CSO-11 | MEDIUM · ABIERTO | `users.password_algo` + rehash perezoso | `needs_rehash()` existe y nadie lo llama | La columna nunca se escribe. El día que haya que subir los parámetros de Argon2 no habrá migración sin downtime, que es su única razón de existir (§6 Paso 7 lo exige explícitamente) |
| CSO-12 | MEDIUM · ABIERTO | `users.must_change_password` | `RegisterUseCase` la pone a `TRUE` y nadie la honra | La contraseña temporal del alta por ADMIN vale para siempre. Es el hallazgo CRIT-2 de la auditoría del blueprint, reabierto en el código |
| CSO-13 | LOW · ABIERTO | `users.lockout_level_decays_at` | No aparece en ningún `.py` | El nivel de bloqueo nunca baja solo. Con el reseteo tras un login exitoso como única salida, y ese login exigiendo no estar bloqueado, la trampa se cierra sobre la víctima — que es justo lo que esa columna se añadió para evitar |

### 2.6 Alcance declarado de fases posteriores (no son hallazgos nuevos)

Se listan para que nadie los dé por hechos: **no hay `ProxyFix`** (así que la IP del cliente no se resuelve), **no hay `Flask-Limiter` ni equivalente** (ninguna cuota por IP ni por cuenta a nivel HTTP), **no hay cabeceras de seguridad** (`CSP`, `HSTS`, `X-Content-Type-Options`, `X-Frame-Options`), **no existe `GET /auth/me` ni ningún decorador que resuelva la cookie** — las sesiones se crean y jamás se leen, así que `idle_expires_at` no se desliza nunca —, y **el CORS tiene `http://localhost:5173` escrito a mano** en `main.py`.

Todo esto es el Paso 10 y la parte no hecha del Paso 9. La observación que sí es de auditoría: **la matriz de trazabilidad del §5 no puede marcar como cubiertas las directivas 3 y 5 mientras esto siga así.**

---

## 3. Falsos positivos descartados

| Candidato | Por qué se descarta |
|---|---|
| "Una excepción no capturada tumba Uvicorn" | `ServerErrorMiddleware` de Starlette la convierte en 500 y el worker sobrevive. Con `debug=False` (por defecto, y nunca activado en el repo) el cuerpo no filtra traza ni SQL |
| "El E2E contamina `dev.db`" | Verificado por mtime tras corridas repetidas: la base de desarrollo no se toca. El override de `get_db` desvía toda la persistencia a un SQLite bajo `tmp_path_factory` |
| "`login_attempts` guarda correos y es una lista de cuentas válidas" | Se guarda `HMAC-SHA256(email, PEPPER)`. Verificado en E2E: consulta literal por el correo en claro → 0 filas |

---

## 4. Orden de ataque recomendado para lo que queda

1. **CSO-03** (validar `X-CSRF-Token` y `Origin` en servidor) — la mitad del cliente ya está hecha, y es la fila de la matriz que hoy miente más.
2. **QA-05 + QA-06** (tope de desafíos, invalidar el anterior, revalidar el estado en el paso 2) — los tres tocan `LoginUseCase`/`VerifyMfaUseCase` y comparten tests; hacerlos juntos cuesta menos que por separado.
3. **CSO-10, CSO-11, CSO-12** (verificación de correo, rehash perezoso, cambio obligatorio) — un `if` y dos ganchos en `LoginUseCase`. Cierran tres columnas que hoy mienten.
4. **Paso 10 completo** (`ProxyFix` → rate limiting → cabeceras → y solo entonces CSO-05, pasar la IP a los casos de uso).
5. **CSO-04** (`__Host-`, `Max-Age`) — configuración, sin lógica.
6. **Puerta de salida de la fase:** `alembic upgrade head` + suite completa contra MySQL 8 real. Los 223 tests verdes de hoy corren sobre SQLite; la única fila que hoy se salta (`test_colacion_email_es_as_cs`) es precisamente la que protege contra la multiplicación de cuota por variantes acentuadas.
