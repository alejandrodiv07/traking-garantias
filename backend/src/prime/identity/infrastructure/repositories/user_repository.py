"""`UserRepository` — persistencia de `users` (Paso 6).

Contrato: ver `tests/identity/infrastructure/repositories/test_user_repository.py`.
`password_hash` llega ya hasheado (Argon2id, Paso 2) — este repositorio no
hashea nada, solo persiste tal cual.

`save()` no lo exige ningún test del Paso 6: las entidades ORM son mutables
y `add()`/`get_by_*` devuelven objetos ya adjuntos a la sesión, así que
mutar un atributo y hacer `session.commit()` basta para persistir el
cambio. Se añade de todas formas para que el Paso 7 (`LoginUseCase`,
`VerifyMfaUseCase`) tenga un punto explícito donde declarar "esta mutación
se persiste aquí", en vez de depender implícitamente del autoflush de
SQLAlchemy — más legible en el caso de uso, sin cambiar el comportamiento.
"""
from __future__ import annotations

from datetime import datetime

from sqlalchemy import select
from sqlalchemy.orm import Session

from prime.identity.infrastructure.orm.models import User


class UserRepository:
    def __init__(self, session: Session):
        self._session = session

    def add(
        self,
        *,
        role_id: int,
        full_name: str,
        email: str,
        password_hash: str,
        email_verified_at: datetime | None = None,
        must_change_password: bool = False,
    ) -> User:
        user = User(
            role_id=role_id,
            full_name=full_name,
            email=email,
            password_hash=password_hash,
            email_verified_at=email_verified_at,
            must_change_password=must_change_password,
        )
        self._session.add(user)
        self._session.flush()
        return user

    def get_by_email(self, email: str) -> User | None:
        stmt = select(User).where(User.email == email)
        return self._session.execute(stmt).scalar_one_or_none()

    def get_by_id(self, user_id: int) -> User | None:
        return self._session.get(User, user_id)

    def save(self, user: User) -> None:
        self._session.add(user)
        self._session.flush()
