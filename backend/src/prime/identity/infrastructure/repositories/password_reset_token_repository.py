"""`PasswordResetTokenRepository` — persistencia de `password_reset_tokens`
(Paso 6).

Contrato: ver
`tests/identity/infrastructure/repositories/test_password_reset_token_repository.py`.
`AUTH_BLUEPRINT.md` §4.5: `token_hash` es SHA-256 del token de 32 bytes
enviado por correo — sin pepper, porque el token ya tiene entropía propia
suficiente (a diferencia del código de 6 dígitos de MFA).
"""
from __future__ import annotations

import hashlib
from datetime import datetime

from sqlalchemy import select
from sqlalchemy.orm import Session

from prime.identity.infrastructure.orm.models import PasswordResetToken


def _sha256(value: str) -> bytes:
    return hashlib.sha256(value.encode("utf-8")).digest()


class PasswordResetTokenRepository:
    def __init__(self, session: Session):
        self._session = session

    def create(
        self,
        *,
        user_id: int,
        token: str,
        expires_at: datetime,
        requested_ip: bytes | None = None,
    ) -> PasswordResetToken:
        reset_token = PasswordResetToken(
            user_id=user_id,
            token_hash=_sha256(token),
            expires_at=expires_at,
            requested_ip=requested_ip,
        )
        self._session.add(reset_token)
        self._session.flush()
        return reset_token

    def find_by_token(self, token: str) -> PasswordResetToken | None:
        stmt = select(PasswordResetToken).where(PasswordResetToken.token_hash == _sha256(token))
        return self._session.execute(stmt).scalar_one_or_none()
