# Deuda de seguridad vigente

> **Origen.** Rescate de `docs/2026-09-06-auditoria-fase-11.md`, eliminado en la Fase 0 porque auditaba el backend Flask/MySQL que nunca llegó al repositorio. Sus hallazgos no se pierden: aquí quedan los que **siguen siendo ciertos sobre Supabase**, y los que dejaron de aplicar quedan listados con el motivo.
>
> Regla de este documento: un hallazgo se cierra cuando la arquitectura lo vuelve imposible, no cuando el fichero que lo describía desaparece.

**Fecha del rescate:** 2026-09-08

---

## Vigentes

### CSO-07 · Longitud mínima de contraseña — **CERRADO en esta Fase 0**

La auditoría pedía subir `MIN_PASSWORD` a 12 en `Login.jsx`. El código lo tenía en **5**.

Corregido, pero **no solo donde decía la auditoría**: subir el mínimo únicamente en el formulario de login habría dejado a cualquiera con una contraseña de 6–11 caracteres sin poder ni enviar el formulario, porque la validación del cliente bloquea el envío. El mínimo tiene que ser el mismo allí donde la contraseña se **crea** que allí donde se **escribe**:

- `frontend/src/features/auth/Login.jsx` → `MIN_PASSWORD = 12`
- `supabase/config.toml` → `minimum_password_length = 12`

`admin-crear-usuario` ya generaba contraseñas temporales de 144 bits, así que ninguna cuenta creada por el alta de administrador se ve afectada.

> **Al sincronizar:** si alguna cuenta se cambió la contraseña a mano y tiene menos de 12 caracteres, hay que restablecerla. En un proyecto sin registro público y con altas por invitación, eso es como mucho una cuenta.

### CSO-10 · MEDIUM · ABIERTO — un correo sin verificar recibe el segundo factor

`auth.users.email_confirmed_at` existe en Supabase y **nada del flujo lo comprueba**. Una cuenta cuyo correo nadie confirmó puede iniciar sesión, y el OTP viaja a un buzón que no se ha verificado que exista o pertenezca a esa persona.

Es más grave aquí que en el diseño original, porque el ADR-004 del Blueprint declara el buzón corporativo como **precondición del sistema de identidad**: si el buzón no está verificado, esa precondición no se cumple y el segundo factor es decorativo.

**Dónde se arregla:** `generate_mfa_code()` debe negarse a emitir un código si `email_confirmed_at IS NULL`, y el login debe decirlo con un mensaje propio. Es una condición en SQL, no en React.

### CSO-12 · MEDIUM · ABIERTO — la contraseña temporal no caduca

`admin-crear-usuario` crea la cuenta con una contraseña temporal de 144 bits y **nada obliga a cambiarla**. Quien la reciba por correo puede usarla indefinidamente, y esa contraseña ha viajado en claro por un canal que no controlamos.

En el diseño original esto era `users.must_change_password`, que se escribía y nadie honraba. Aquí ni siquiera existe la columna.

**Dónde se arregla:** una marca en `profiles` (o en `raw_app_meta_data`, que el usuario no controla) y una comprobación en el enrutado tras el segundo factor.

### CSO-05 · LOW (degradado) · ABIERTO — rastro forense parcial del segundo factor

La auditoría lo marcaba HIGH por `ip_address` y `user_agent_hash` siempre nulos. Sobre Supabase se degrada, no se cierra:

- `consulta_publica_intentos` **sí** registra IP, y de ahí depende el freno de fuerza bruta del portal público.
- `email_mfa_codes` y `mfa_sesiones` **no** registran nada del origen: no hay forma de reconstruir desde dónde se pidió o se verificó un código.
- Supabase Auth mantiene su propio registro de accesos, que cubre el primer factor pero no el segundo, porque el segundo lo implementamos nosotros.

**Dónde se arregla:** una columna de IP en `mfa_sesiones`, alimentada desde `request.headers` igual que ya hace `consultar_garantia()`.

---

## Cerrados por la arquitectura

No requieren trabajo: el mecanismo que los hacía posibles dejó de existir al desaparecer el servidor propio.

| Hallazgo | Por qué ya no aplica |
|---|---|
| **CSO-03** · sin validación CSRF ni de `Origin` | No hay sesión por cookie: el JWT viaja en la cabecera `Authorization`, que un formulario de otro origen no puede fijar. La Edge Function además valida `ORIGENES_PERMITIDOS` |
| **CSO-04** · falta el prefijo `__Host-` y `Max-Age` | No emitimos cookies propias. La sesión la gestiona Supabase Auth |
| **CSO-08** · `SECRET_KEY` en `.env.example` sin usar | No hay servidor propio que firme nada. Las claves son las de Supabase, gestionadas como secretos del proyecto |
| **CSO-11** · `password_algo` y rehash perezoso | El hashing de contraseñas es responsabilidad de Supabase Auth, incluida su migración de parámetros |
| **CSO-13** · el nivel de bloqueo no decae solo | No hay tabla de bloqueo propia. El límite de intentos lo aplica Supabase Auth, y nuestra ventana anti-fuerza-bruta (`email_mfa_codes.intentos`, `consulta_publica_intentos`) es por código y por IP, sin escalada persistente que pueda atrapar a la víctima |

---

## Cómo se cierra un punto de esta lista

Con una migración y su prueba en `supabase/tests/`, no con una comprobación en React. Las tres vigentes son condiciones de servidor: si solo las hace cumplir la interfaz, no las hace cumplir nadie (§8.2 del Blueprint).
