# Instalar el proyecto en otra máquina

Guía para clonar el repositorio en un equipo nuevo y dejarlo corriendo, con pruebas incluidas. Última revisión: 2026-10-31.

---

## 1. Programas que hay que instalar (una sola vez)

| Programa | Versión | Para qué | Dónde lo instala uno |
|---|---|---|---|
| **Git** | 2.40+ | Clonar y commitear | [git-scm.com](https://git-scm.com/downloads) |
| **Node.js** | **≥ 22.12** (LTS 22) | El motor del frontend y de las pruebas | [nodejs.org](https://nodejs.org) — verificar con `node -v` |
| **pnpm** | **≥ 10** (el repo fija `pnpm@10.34.9`) | Gestor de paquetes del frontend | `corepack enable` y `corepack prepare pnpm@10.34.9 --activate` (Corepack viene con Node) |
| **Docker Desktop** | cualquiera reciente (motor actual) | Corre Postgres 17 para las pruebas SQL y el e2e | [docker.com](https://www.docker.com/products/docker-desktop/) — en Windows exige WSL2 activado |
| Supabase CLI *(opcional)* | v2 | Solo si se quiere un Supabase local completo o desplegar Edge Functions | `npm i -g supabase` o [instalador](https://supabase.com/docs/guides/local-development/cli/getting-started) |
| Postman *(opcional)* | escritorio | Importar las colecciones de pruebas de la API de `postman/` | [postman.com](https://www.postman.com/downloads/) |

> **Windows:** antes de las pruebas SQL hay que abrir Docker Desktop una vez para que el motor arranque. Comprobación: `docker version` debe responder sin error.
> **Linux/macOS:** el proyecto se desarrolla en Windows pero no depende de nada específico de Windows; los scripts (`run.sh`, `e2e-registro.sh`) se corren igualmente con Git Bash o bash nativo.

**Requisitos aproximados:** 4 GB de RAM libres para la suite SQL (levanta un contenedor `postgres:17` y una base por archivo de prueba) y ~2 GB de disco para dependencias + imagen de Postgres (~300 MB al primer `run.sh`).

---

## 2. Después de clonar el repositorio

```bash
git clone <url-del-repo>
cd track-garantia      # o "track garantia", según el clone

# 2.1 Dependencias del frontend (no hace falta instalar nada a mano:
#     package.json + pnpm-lock.yaml fijan todo)
cd frontend
corepack enable
pnpm install
```

Lo que instala `pnpm install` (no se instala manualmente, queda registrado aquí para referencia):

- **Producción:** React 19.2, react-dom 19.2, react-router-dom 7.18, @supabase/supabase-js 2.115, lucide-react (iconos), @fontsource/inter y @fontsource/ibm-plex-sans (tipografías).
- **Desarrollo:** Vite 8.2 + @vitejs/plugin-react, vitest 3.2 + Testing Library (@testing-library/react, jest-dom, user-event, dom) + jsdom, Tailwind CSS 4.3 (@tailwindcss/vite), oxlint, @babel/core + babel-plugin-react-compiler + @rolldown/plugin-babel, @types/react.

---

## 3. Variables de entorno obligatorias

Crear `frontend/.env.local` (no está en el repo; el `.gitignore` lo excluye):

```ini
VITE_SUPABASE_URL=https://<proyecto>.supabase.co
VITE_SUPABASE_ANON_KEY=<clave anon del proyecto>
```

Ambos valores salen del panel de Supabase → *Project Settings* → *API*.

Si se trabaja contra **Supabase local** (con el CLI), la URL es `http://127.0.0.1:54321` y las claves las imprime `supabase start` (la `anon key` local sirve para desarrollo; el seed y las migraciones se aplican solo — ver §4-B).

---

## 4. La base de datos

El frontend necesita un proyecto Supabase. Dos caminos:

### A — Proyecto remoto (el normal)
1. Crear el proyecto en [supabase.com](https://supabase.com).
2. Aplicar las migraciones **en orden** desde `supabase/migrations/` (de `20260906000001_auth_base.sql` a `20261030000026_buscar_equipo_tipo_documento.sql`):
   - Con CLI: `supabase db push` desde la raíz del repo (pide vincular el proyecto).
   - Sin CLI: en el *SQL Editor* del panel, ejecutar `supabase/manual/aplicar_0004_0023.sql`, luego `aplicar_0024.sql`, luego `aplicar_0025.sql` (bloques agrupados listos para pegar).
3. Cargar el catálogo inicial: ejecutar `supabase/seed.sql` en el SQL Editor (idempotente, no duplica).
4. Verificar: `select version from supabase_migrations.schema_migrations order by version;` debe listar hasta `20261030000026`.

### B — Supabase local (opcional, para desarrollo sin red)
```bash
supabase start          # levanta Postgres, Auth, Storage y la API en :54321
```
Las migraciones de `supabase/migrations/` se aplican automáticamente al arrancar; el seed puede regenerarse con `supabase db reset`.

---

## 5. Correrlo y probar que quedó bien

```bash
cd frontend
pnpm dev        # abre http://localhost:5173

# Suite de verificación (lo mismo que corre la CI de GitHub Actions):
pnpm test                             # vitest, 416 pruebas en 31 archivos
pnpm lint                             # oxlint
pnpm build                            # build de producción en frontend/dist
bash supabase/tests/run.sh            # SQL: 31 archivos de prueba con Postgres 17 en Docker
bash scripts/e2e-registro.sh          # punta a punta: garantía → consulta → orden → rechazo → entrega → importar ventas
bash scripts/verificar-migraciones.sh # historial de migraciones sin duplicados ni saltos
```

Otros comandos útiles: `pnpm test:watch` (vitest en modo continuo) y `pnpm preview` (sirve el build de `/dist`).

Primer arranque tras `run.sh`: la imagen `postgres:17` se descarga de Docker Hub (~150 MB).

---

## 6. Edge Functions (solo si se despliegan)

Viven en `supabase/functions/` — `admin-crear-usuario`, `mfa-enviar-codigo`, `limpiar-huerfanos` — y se despliegan con el CLI, requiere haber entrado con `supabase login`:

```bash
supabase functions deploy mfa-enviar-codigo
supabase functions deploy admin-crear-usuario
supabase functions deploy limpiar-huerfanos
```

No hace falta instalar Deno: el CLI lo maneja.

---

## 7. Puertos usados

| Puerto | Quién | Cuándo |
|---|---|---|
| 5173 | Vite (frontend) | `pnpm dev` y `pnpm preview` usa 4173 |
| 54321 | Supabase local | solo con `supabase start` |
| — | Postgres 17 en Docker | la suite SQL usa contenedores efímeros con puertos internos, no ocupa puertos del equipo |

## 8. Problemas típicos

- **`pnpm` no se encuentra:** falta `corepack enable` o la versión de Node es menor a 22.12.
- **`run.sh` cuelga o falla**: Docker Desktop no arrancó. En Windows se puede reiniciar con `wsl --shutdown` y abriendo Docker de nuevo; conviene limpiar contenedores viejos con `docker rm -f $(docker ps -aq --filter ancestor=postgres:17)`.
- **La app carga en blanco o da 401 en todo:** falta `frontend/.env.local` o la clave es de otro proyecto.
- **Login pide código y nunca llega:** el envío de códigos MFA pasa por la Edge Function `mfa-enviar-codigo` y Resend; en desarrollo hay un hotfix que manda todo a un destinatario fijo (ver `ESTADO_DEL_PROYECTO.md`, deuda D11), pendiente de verificar el dominio en Resend.