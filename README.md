# Track Garantías

Este proyecto combina una app frontend con autenticación, paneles y un backend basado en Supabase. Incluye una Edge Function para enviar el segundo factor por correo (`mfa-enviar-codigo`) y varias migraciones para reglas de seguridad, MFA y acceso por roles.

## 0. Atajo: wizard de setup

Si ya tienes un proyecto Supabase y una cuenta Resend creados, `scripts/setup-supabase-mfa.sh` automatiza todo lo de las secciones 1-8 (instalar dependencias, login/link de Supabase, `frontend/.env`, secrets, `db push` y el deploy de la función) y valida el flujo de login + MFA al final:

```bash
bash scripts/setup-supabase-mfa.sh
```

Es interactivo: te dice qué abrir, qué copiar y dónde lo guarda. Puedes interrumpirlo con Ctrl-C y volver a correrlo — reutiliza los valores que ya quedaron en `frontend/.env`. El resto de esta guía explica cada paso a mano, por si prefieres hacerlo tú mismo o algo falla.

## 1. Requisitos previos

Antes de empezar, asegúrate de tener instalado:

- Node.js 18+ y npm
- Git
- Supabase CLI
- Acceso a tu proyecto Supabase
- Un correo válido para Resend o un dominio verificado si vas a producción

Instala el CLI si aún no lo tienes:

```bash
npm install -g supabase
```

Comprueba que quedó instalado:

```bash
supabase --version
```

## 2. Clonar y preparar el proyecto

En la terminal:

```bash
cd tu-carpeta-del-proyecto
npm install
```

Si quieres arrancar la interfaz web localmente:

```bash
cd frontend
pnpm install
pnpm run dev
```

La app suele quedar en:

```text
http://localhost:5173
```

## 3. Iniciar sesión en Supabase

Desde la raíz del proyecto:

```bash
supabase login
```

Si el CLI no puede hacer el prompt interactivo en tu entorno, usa un token:

```bash
supabase login --token "TU_ACCESS_TOKEN"
```

Si el token ya fue generado correctamente, verás un mensaje como:

```text
Token ... created successfully.
You are now logged in.
```

## 4. Enlazar el proyecto correcto

Necesitas el `project-ref` de tu proyecto de Supabase. Lo normal es que esté en la URL:

```text
https://<project-ref>.supabase.co
```

Ejemplo:

```bash
supabase link --project-ref xyz123abcd567
```

Si falla con un mensaje como:

```text
LegacyProjectNotLinkedError
```

entonces no se ha vinculado ningún proyecto todavía. Repite el comando con el ref correcto.

## 5. Variables de entorno y secretos

La Edge Function usa secretos de Supabase para enviar correos. Debes configurarlos en el proyecto:

```bash
supabase secrets set RESEND_API_KEY=tu_clave_resend
supabase secrets set ORIGENES_PERMITIDOS=http://localhost:5173,https://tu-dominio.com
```

La función también usa automáticamente las variables que Supabase inyecta:

- `SUPABASE_URL`
- `SUPABASE_ANON_KEY`
- `SUPABASE_SERVICE_ROLE_KEY`

## 6. Desplegar la Edge Function

Desde la raíz del proyecto:

```bash
supabase functions deploy mfa-enviar-codigo
```

Si tienes el proyecto enlazado y los secretos correctos, la función debería desplegarse sin error.

> Importante: esta Edge Function mantiene `verify_jwt` activado por defecto. Eso significa que la llamada debe llevar un JWT válido en el header `Authorization`.

## 7. Validación de la Edge Function

### 7.1 Validación de seguridad básica

La función debe rechazar peticiones sin JWT:

```bash
curl -i -X POST "https://<project-ref>.supabase.co/functions/v1/mfa-enviar-codigo" \
  -H "Content-Type: application/json" \
  -H "Origin: http://localhost:5173"
```

Resultado esperado:

- `401 Unauthorized`
- o un error de autenticación

### 7.2 Validación con JWT válido

Primero genera o reutiliza un token válido del usuario autenticado. Luego prueba la llamada:

```bash
curl -i -X POST "https://<project-ref>.supabase.co/functions/v1/mfa-enviar-codigo" \
  -H "Content-Type: application/json" \
  -H "Origin: http://localhost:5173" \
  -H "Authorization: Bearer <JWT_DEL_USUARIO>"
```

Resultado esperado:

- respuesta HTTP `201` o `200`
- JSON con el campo `expira_en`
- no debe devolver el código real al navegador

### 7.3 Verificación de que no se filtra el código

La función debe devolver solo la caducidad del código, no el código en sí.

Ejemplo de respuesta esperada:

```json
{
  "expira_en": "2026-09-07T12:35:00.000Z"
}
```

No debe devolver algo como:

```json
{
  "code": "123456"
}
```

### 7.4 Validación desde la base de datos

En Supabase SQL editor, puedes comprobar que la función de generación de código está creando filas seguras:

```sql
SELECT generate_mfa_code();
SELECT * FROM public.email_mfa_codes ORDER BY created_at DESC LIMIT 5;
```

La función `generate_mfa_code()` devuelve una marca de tiempo/expiración, no el código visible. El código real debe permanecer en la tabla y no ser expuesto al frontend.

### 7.5 Verificación de logs

Si algo falla, revisa el historial de la función:

```bash
supabase functions logs mfa-enviar-codigo --since 1h
```

Esto te ayuda a revisar:

- JWT faltante o inválido
- `RESEND_API_KEY` ausente
- error de conexión a Resend
- problema de CORS
- problema con `project-ref` o permisos

## 8. Validación del flujo completo en la app

### Flujo recomendado

1. El usuario inicia sesión con email y contraseña.
2. El frontend llama a la Edge Function con el JWT del usuario.
3. La función ejecuta `generate_mfa_code()` usando la identidad real del usuario.
4. La función lee el código recién generado con `service_role`.
5. La función envía el correo por Resend.
6. El frontend pide al usuario que introduzca el código recibido.
7. La app valida el código con la lógica de la base de datos.
8. Si es correcto, se activa la sesión de MFA y se concede el acceso adecuado.

## 9. Ejecutar el proyecto localmente

Desde la raíz del proyecto:

```bash
supabase start
```

Luego en otra terminal:

```bash
cd frontend
pnpm run dev
```

Por si necesitas servir la función localmente:

```bash
supabase functions serve mfa-enviar-codigo --no-verify-jwt
```

> Usar `--no-verify-jwt` solo es útil para pruebas locales; en producción o en el proyecto desplegado no debe desactivarse la protección.

## 10. Diagnóstico rápido de errores comunes

### Error: `Access token not provided`

Solución:

```bash
supabase login
```

### Error: `Cannot find project ref. Have you run supabase link?`

Solución:

```bash
supabase link --project-ref <project-ref>
```

### Error: `401 Unauthorized`

Revisa que el cliente esté enviando un JWT válido en el header:

```http
Authorization: Bearer <jwt>
```

### Error: `No se pudo enviar el código de verificación`

Revisa:

- SECRET `RESEND_API_KEY`
- dominio verificado en Resend
- que la Edge Function esté desplegada
- que `ORIGENES_PERMITIDOS` incluya tu origen local o real

## 11. Recomendaciones de seguridad

- Nunca expongas el código del MFA al cliente.
- Mantén `verify_jwt` activo.
- Usa `service_role` solo para tareas del backend, no para decisiones del usuario.
- Guarda secretos en Supabase secrets o en variables del entorno seguro del proyecto.
- No hagas `console.log` del código del MFA en la Edge Function.

## 12. Flujo resumido para cualquier usuario del proyecto

```bash
npm install -g supabase
supabase login
supabase link --project-ref <project-ref>
supabase secrets set RESEND_API_KEY=tu_clave_resend
supabase secrets set ORIGENES_PERMITIDOS=http://localhost:5173
supabase functions deploy mfa-enviar-codigo
cd frontend
pnpm install
pnpm run dev
```

Y luego probar la validación con un JWT válido y la URL de la función desplegada.

## 13. Resumen

La validación correcta de esta Edge Function implica:

- autenticar el CLI de Supabase
- enlazar el proyecto correcto
- desplegar la función
- correr la llamada con JWT válido
- verificar que la función responde con `expira_en` y no con el código
- revisar logs si falla
- mantener la protección JWT activa en producción

Si todo esto queda correcto, el flujo de MFA queda listo para ser usado por la app.
