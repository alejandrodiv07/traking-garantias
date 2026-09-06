"""Siembra el superusuario ADMIN local (desvio tactico, dev-only).

`AUTH_BLUEPRINT.md` (tabla de deuda consciente, "Alta de usuarios por
ADMIN"): no hay endpoint de registro publico; los primeros usuarios se
siembran con un script. Este es ese script — vive en `scripts/`, NO en
`src/`: no forma parte del paquete desplegable y ningun caso de uso lo
importa.

Reutiliza las piezas ya probadas en vez de reimplementarlas:
  - `Email` normaliza y valida (strip + lower + regex, Paso 1).
  - `PlainPassword` valida longitud ANTES de gastar ~100 ms de Argon2.
  - `Argon2PasswordHasher` produce el hash con los parametros vigentes
    (m=64 MiB, t=3, p=4) — el mismo que verificara `LoginUseCase`.
  - `UserRepository.add()` inserta; aqui no se escribe SQL a mano.

Uso tipico (desde `backend/`):

    python scripts/create_superuser.py --create-tables
    python scripts/create_superuser.py --email otro@primetelecom.com --force

Por defecto crea al admin con `mfa_enabled=False`: el canal de correo del
segundo factor no existe todavia (Fase 9+), asi que un admin con MFA
activo seria un admin con el que no se puede entrar. `--mfa` lo activa
cuando llegue ese momento. Es una decision de conveniencia de DESARROLLO;
el `server_default` de la tabla sigue siendo TRUE y ningun alta real pasa
por aqui.
"""
from __future__ import annotations

import argparse
import os
import sys
from datetime import datetime
from pathlib import Path

BACKEND_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BACKEND_ROOT / "src"))

import sqlalchemy as sa
from sqlalchemy.orm import Session

from prime.identity.domain.password_hasher import Argon2PasswordHasher
from prime.identity.domain.value_objects import Email, PlainPassword
from prime.identity.infrastructure.orm.base import Base
from prime.identity.infrastructure.orm.models import Role
from prime.identity.infrastructure.repositories.user_repository import UserRepository

DEFAULT_URL = os.environ.get(
    "PRIME_DATABASE_URL", f"sqlite:///{BACKEND_ROOT / 'dev.db'}"
)
DEFAULT_EMAIL = "admin@primetelecom.com"
# 12 caracteres es el minimo que impone `PlainPassword` (Paso 1).
DEFAULT_PASSWORD = "Prime-Admin-2026!"
DEFAULT_FULL_NAME = "Administrador Prime"
DEFAULT_ROLE_CODE = "ADMIN"


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Crea el usuario ADMIN local.")
    p.add_argument("--database-url", default=DEFAULT_URL)
    p.add_argument("--email", default=DEFAULT_EMAIL)
    p.add_argument("--password", default=DEFAULT_PASSWORD)
    p.add_argument("--full-name", default=DEFAULT_FULL_NAME)
    p.add_argument("--role", default=DEFAULT_ROLE_CODE, help="roles.code a asignar")
    p.add_argument(
        "--mfa",
        action="store_true",
        help="crear el admin con mfa_enabled=True (por defecto False, ver docstring)",
    )
    p.add_argument(
        "--create-tables",
        action="store_true",
        help="crear el esquema con metadata.create_all si la BD esta vacia "
             "(atajo de dev; en MySQL usa 'alembic upgrade head')",
    )
    p.add_argument(
        "--force",
        action="store_true",
        help="si el correo ya existe, reescribir su contrasena en vez de abortar",
    )
    return p.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)

    # Validar ANTES de tocar la base de datos: un correo mal escrito o una
    # contrasena corta no deben dejar el esquema a medio crear.
    email = Email(args.email)
    password = PlainPassword(args.password)

    engine = sa.create_engine(args.database_url, future=True)

    if args.create_tables:
        Base.metadata.create_all(engine)

    if not sa.inspect(engine).has_table("users"):
        print(
            f"ERROR: la tabla 'users' no existe en {args.database_url}.\n"
            "       Ejecuta 'alembic upgrade head' o repite con --create-tables.",
            file=sys.stderr,
        )
        return 1

    hasher = Argon2PasswordHasher()

    with Session(engine, future=True) as session:
        role = session.execute(
            sa.select(Role).where(Role.code == args.role)
        ).scalar_one_or_none()

        if role is None:
            if not args.create_tables:
                # Con Alembic la fila ADMIN viene sembrada en 0001; que falte
                # significa que la BD no esta en head, y sembrarla a mano aqui
                # taparia ese problema en vez de senalarlo.
                print(
                    f"ERROR: no existe roles.code='{args.role}'. La migracion "
                    "0001 la siembra: ejecuta 'alembic upgrade head'.",
                    file=sys.stderr,
                )
                return 1
            # Ruta create_all: no hay migraciones, luego no hay semilla.
            role = Role(id=1, code=args.role, name="Administrador")
            session.add(role)
            session.flush()

        repo = UserRepository(session)
        existing = repo.get_by_email(email.value)

        if existing is not None and not args.force:
            print(
                f"El usuario {email.value} ya existe (id={existing.id}). "
                "Usa --force para reescribir su contrasena."
            )
            return 0

        password_hash = hasher.hash(password.expose())

        if existing is not None:
            existing.password_hash = password_hash
            existing.password_algo = "argon2id"
            existing.password_updated_at = datetime.utcnow()
            existing.must_change_password = False
            existing.failed_login_count = 0
            existing.locked_until = None
            existing.lockout_level = 0
            existing.is_active = True
            existing.mfa_enabled = args.mfa
            repo.save(existing)
            user = existing
            accion = "actualizado"
        else:
            user = repo.add(
                role_id=role.id,
                full_name=args.full_name,
                email=email.value,
                password_hash=password_hash,
                # Correo dado por verificado: lo crea un humano con acceso a
                # la BD, no un formulario publico.
                email_verified_at=datetime.utcnow(),
                # A diferencia de un alta real por ADMIN (que fuerza el
                # cambio), este es un usuario de pruebas manuales: obligar a
                # cambiar la contrasena romperia el flujo que queremos probar.
                must_change_password=False,
            )
            user.mfa_enabled = args.mfa
            repo.save(user)
            accion = "creado"

        session.commit()

        print(
            f"Superusuario {accion}: id={user.id} email={user.email} "
            f"role={args.role}(id={role.id}) mfa_enabled={user.mfa_enabled}"
        )
        print(f"Contrasena: {args.password}   <- solo dev, no reutilizar")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
