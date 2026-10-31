# Usuarios que sí pueden iniciar sesión

Qué cuentas sirven para entrar, dónde existen y qué le falta a la nube para que entren todos. Verificado el **31/10/2026**: el flujo completo (contraseña → código → `verify_mfa_code` → `mfa_ok = true`) se probó uno a uno contra el Supabase local de esta máquina.

> ⚠️ Contraseñas de prueba, para entornos locales/nube de desarrollo. No usarlas en producción.

---

## 1. Supabase local (esta máquina · `http://127.0.0.1:54321`) — ✅ verificado hoy

Las cuatro cuentas existen en `auth.users` con correo confirmado, perfil activo y rol asignado. La contraseña es común a las cuatro: **`Prueba-12345!`**

| Usuario (correo) | Rol | Estado |
|---|---|---|
| `admin@prueba.local` | `ADMIN` | ✅ Login completo verificado (mfa_ok = true) |
| `jefe@prueba.local` | `JEFE_SERVICIO` | ✅ Login completo verificado (mfa_ok = true) |
| `tecnico@prueba.local` | `TECNICO` | ✅ Login completo verificado (mfa_ok = true) |
| `recepcion@prueba.local` | `RECEPCION` | ✅ Login completo verificado (mfa_ok = true) |

Cómo entrar con cada una:

- **Con Postman (el camino garantizado, incluso sin internet):** importa `postman/track-garantia.collection.json` y `postman/ventas-roles-taller.collection.json` con el entorno `postman/local.environment.json` (`base = http://[::1]:54321`, la `password` ya está en el entorno). La colección hace: `token?grant_type=password` → `rpc/generate_mfa_code` → lee el código → `rpc/verify_mfa_code`.
- **En el navegador:** el repo apunta por defecto al proyecto remoto, así que hay que (1) cambiar `frontend/.env.local` a `VITE_SUPABASE_URL=http://127.0.0.1:54321` con la clave anon local, (2) agregar esa URL al `connect-src` del CSP de `frontend/index.html` y (3) tener `mfa-enviar-codigo` servida contra el Supabase local (`supabase functions serve`); sin la API key de Resend el paso de «enviar código» del navegador falla aunque el código exista en la tabla `email_mfa_codes` — ahí sirven los pasos de Postman.

Si las cuentas se pierden al rehacer la base (`supabase db reset`), se recrean invitándolas de nuevo con la función `admin-crear-usuario` (los pasos equivalentes de crear usuario están en las colecciones Postman) o insertando en `auth.users` + `profiles` con la misma contraseña.

## 2. Proyecto en la nube (Supabase `przkjfyatficximekvow`) — ⚠️ solo con el correo de Resend

Hoy las **funciones de login funcionan** (contraseña, RPC, sesión), pero el envío del código OTP pasa por Resend, y el despliegue actual lleva el hotfix temporal del destino fijo:

| Cuenta | Puede entrar hoy | Por qué |
|---|---|---|
| `samuel.alejandronle66@gmail.com` | ✅ (verificado 29/10/2026: 201 de Resend + OTP recibido) | Es el **dueño de la cuenta Resend**: el sandbox `onboarding@resend.dev` solo acepta entregarle a él |
| Otra cuenta cualquiera (p. ej. `samuel.admin2@primetelecom.com`, creada en el diagnóstico y activa) | ✅ con un paso extra | El hotfix de `mfa-enviar-codigo` **manda todos los códigos a `samuel.alejandronle66@gmail.com`**: hay que leer el OTP de ese correo e introducirlo en su login. Sin eso, el envío devuelve 502 |
| Un usuario nuevo invitado con su propio correo | ❌ hasta revertir el hotfix | Sin verificación de dominio, Resend rechaza (403) y la función traduce a 502, que el login muestra como «Credenciales incorrectas» |

El código del **repositorio ya está revertido** (`to: [usuario.user.email]`); lo que sigue desplegado es la versión con hotfix. Para que cada usuario reciba *su* código hacen falta, en orden: (1) verificar el dominio `primetelecom.com` en Resend (SPF/DKIM — pendiente del acceso al DNS), (2) ajustar el `REMITENTE`, (3) revertir el hotfix y (4) redesplegar la función. Todo anotado en `docs/PENDIENTES.md` (D11).

> 🔒 Nota de seguridad observada durante el diagnóstico: el historial/log de Resend muestra el contenido completo del correo, incluido el OTP. La contraseña temporal de la cuenta Gmail es rotable — conviene rotarla al cerrar la prueba.

## 3. No se pueden loguear (nombres que parecen usuarios pero no lo son)

Estos correos aparecen en `supabase/tests/*.sql` como perfiles de prueba (`admin@primetelecom.com`, `tecnico@primetelecom.com`, `recep@primetelecom.com`, `fantasma@x.com`…) y **no tienen cuenta** en `auth.users`: viven solo en bases de datos efímeras de la suite SQL. No sirven para entrar ni en local ni en la nube.

---

Ver también: [INSTALAR_EN_OTRA_MAQUINA.md](INSTALAR_EN_OTRA_MAQUINA.md) (montar todo desde cero) · [PENDIENTES.md](PENDIENTES.md) (deuda D11 de Resend) · [FUNCIONALIDADES.md](FUNCIONALIDADES.md) (qué probar por rol una vez dentro).