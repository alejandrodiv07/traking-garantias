> **SUPERADO (2026-09-08).** Describe el backend Flask/MySQL que se abandonó. Se conserva como registro histórico del diseño del segundo factor, cuyo concepto sí sobrevive. La arquitectura vigente está en `2026-09-07-blueprint-supabase.md`; la deuda de seguridad que este documento originó, en `../deuda-seguridad.md`.

# Spec de arranque — Fase 1-A: Login seguro
**Fecha:** 2026-09-05 · **Proyecto:** Prime Telecom · **Estado:** aprobado para codificar

Este documento fija las decisiones de arranque que salieron del brainstorming. El diseño técnico completo (DDL, flujos, trazabilidad CISO, auditoría) vive en `AUTH_BLUEPRINT.md`; aquí solo está lo que ese documento no decidía.

---

## 1. La fase se parte en dos

`AUTH_BLUEPRINT.md` describía una Fase 1-A de ~6,5 días sin nada demostrable hasta el final. Se parte:

### Fase 1-A — Autenticación utilizable (~4,5 días)

Objetivo: **un humano puede entrar al sistema de forma segura y salir.** Al terminar, hay algo que se enseña.

| Paso | Contenido | Ref. |
|------|-----------|------|
| 0 | Andamiaje del monorepo, `.venv`, `pytest`, `.env.example` | §6 Paso 0 |
| 1-4 | Dominio puro: `Email`, `PlainPassword`, `PasswordHasher`, `LockoutPolicy`, `MfaPolicy` | §6 Pasos 1-4 |
| 5 | Migración inicial (incluye `roles` mínimo y **las 6 tablas completas**) | §6 Paso 5 |
| 5-bis | Arranque en frío: `flask auth seed-admin` + `flask auth unlock` | §6 Paso 5-bis |
| 6 | Repositorios (los 6, incluidos `PasswordResetToken` y `SecurityEvent`) | §6 Paso 6 |
| 7 | `LoginUseCase` + `VerifyMfaUseCase` | §6 Paso 7 |
| 7-bis* | Solo `ChangePasswordUseCase` | §6 Paso 7-bis |
| 8-10 | Endpoints, cookies + CSRF atado a sesión, `ProxyFix` + rate limit + cabeceras | §6 Pasos 8-10 |
| 11 | Integración con el `Login.jsx` existente + pantalla de código 2FA | §6 Paso 11 |

### Fase 1-B — Restablecimiento por correo (~1,5 días)

`POST /password/forgot` y `POST /password/reset`, con el encolado asíncrono que exige el anti-enumeración (§5, directiva 4) y las mitigaciones del riesgo de canal único (§5.2).

**Por qué así:** las tablas se crean todas en la migración de 1-A, así que el esquema no se fragmenta ni hace falta una segunda migración estructural. Lo que se aplaza son dos casos de uso y dos rutas. Mientras 1-B no exista, un olvido de contraseña lo resuelve el ADMIN por consola — aceptable durante una semana con cuatro usuarios internos, no aceptable como estado final.

**Consecuencia que hay que anotar:** hasta cerrar 1-B, la fila de la directiva 4 en la matriz de trazabilidad (§5) queda **parcialmente cubierta**. El login cumple; el reseteo todavía no existe. La matriz se marca así, no se da por cerrada.

---

## 2. Estructura: se reorganiza al monorepo ahora

Hoy: `Login.jsx` suelto en la raíz y `login-app/` importándolo con `../../Login.jsx` — fuera de la raíz de Vite. Funciona por accidente y se romperá en el primer `build` con `base` distinto o en el primer despliegue.

Destino, en el Paso 0:

```text
prime-telecom/
├── backend/
│   ├── pyproject.toml
│   ├── .env.example
│   ├── src/prime/
│   │   ├── shared/
│   │   └── identity/
│   │       ├── domain/          # Pasos 1-4 (puro, sin BD)
│   │       ├── application/     # Paso 7
│   │       └── infrastructure/  # Pasos 5-6
│   └── tests/identity/
└── frontend/                    # el actual login-app/
    └── src/
        ├── api/                 # instancia con credentials:"include"
        ├── features/auth/       # aquí entra Login.jsx
        └── ui/
```

`git init` en `prime-telecom/`, con `.venv/`, `__pycache__/`, `.env` y `node_modules/` ignorados desde el primer commit.

---

## 3. Base de datos: SQLite en desarrollo, MySQL antes de cerrar la fase

En la máquina hay Python 3.10, git, Node y npm. No hay MySQL, ni Redis, ni Docker.

- **Pasos 0-4:** no tocan BD. Arrancan hoy sin instalar nada.
- **Pasos 5-11:** SQLAlchemy + Alembic contra **SQLite en fichero**. El código de dominio y de aplicación es idéntico.
- **Rate limiting:** `Flask-Limiter` en memoria (el `in_memory_fallback` que el Paso 10 ya contempla). Con un solo worker en desarrollo, el contador es correcto.

**Riesgos que esto introduce, y cómo se cierran:**

| Riesgo | Cierre |
|--------|--------|
| SQLite ignora `BINARY(16)`, `VARBINARY`, `ENUM` y `COLLATE` | Los tipos se declaran con `sqlalchemy.dialects.mysql` y variantes por dialecto. El test de colación (`test_colacion_email_es_as_cs`) se marca `@pytest.mark.mysql` y solo corre contra MySQL |
| Una migración válida en SQLite puede fallar en MySQL | **Puerta de salida de la Fase 1-A:** `alembic upgrade head` + toda la suite verde contra MySQL 8 real antes de dar la fase por cerrada. No es opcional |
| El comportamiento con Redis caído no se prueba | Se prueba en 1-B o en la Fase 3, cuando Redis exista |

Instalar MySQL 8 y Redis queda como tarea paralela, sin bloquear el arranque.

---

## 4. Criterios de aceptación de la Fase 1-A

La fase está hecha cuando, contra **MySQL 8 real**:

1. `flask auth seed-admin` crea el primer usuario y ese usuario completa login → código → panel → logout, de extremo a extremo.
2. El token de sesión no aparece en `document.cookie`, ni en el cuerpo de ninguna respuesta, ni en la pestaña de aplicación de las DevTools.
3. Las cinco causas de fallo devuelven el mismo cuerpo, el mismo código y el mismo tiempo (dentro del umbral).
4. `test_xff_falsificado_no_cambia_la_clave_de_rate_limit` en verde.
5. `test_csrf_inyectado_desde_subdominio_no_valida` en verde.
6. Cinco fallos de MFA bloquean la cuenta igual que cinco fallos de contraseña.
7. Ni la contraseña, ni el token de sesión, ni el código 2FA, ni el token de reseteo aparecen en claro en ninguna tabla (verificado con consulta literal).
8. La cobertura del paquete `identity/domain/` es del 100%. En el resto, todo camino de fallo tiene su test.

---

## 5. Supuestos declarados

- **Sesión opaca en BD**, no JWT (§2 del blueprint). Corrige el §1.3 del Blueprint maestro.
- **2FA por correo en cada login**, sin dispositivos de confianza.
- **Email corporativo como identificador**; el campo `username` del `Login.jsx` actual se renombra.
- **El correo corporativo ya está verificado fuera de banda** (lo crea sistemas), por eso el alta escribe `email_verified_at = NOW()` y no hay flujo de auto-verificación en esta fase.
- **La seguridad del buzón corporativo es una precondición del sistema** (§5.2, riesgo aceptado).
- **RBAC fuera de alcance.** `role_id` existe y se rellena, pero ningún permiso se evalúa todavía.
