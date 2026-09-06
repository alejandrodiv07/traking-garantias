"""`SessionRepository` — persistencia de `auth_sessions` (Paso 6).

Contrato: ver `tests/identity/infrastructure/repositories/test_session_repository.py`.
`AUTH_BLUEPRINT.md` §2.1/§4.2: en la base de datos nunca se guarda el
token ni el csrf_token en claro, solo su SHA-256.
"""
from __future__ import annotations

import hashlib
from datetime import datetime

from sqlalchemy import select
from sqlalchemy.orm import Session

from prime.identity.infrastructure.orm.models import AuthSession


def _sha256(value: str) -> bytes:
    return hashlib.sha256(value.encode("utf-8")).digest()


class SessionRepository:
    def __init__(self, session: Session):
        self._session = session

    def create(
        self,
        *,
        user_id: int,
        token: str,
        csrf_token: str,
        idle_expires_at: datetime,
        absolute_expires_at: datetime,
        ip_address: bytes | None = None,
        user_agent_hash: bytes | None = None,
    ) -> AuthSession:
        auth_session = AuthSession(
            user_id=user_id,
            token_hash=_sha256(token),
            csrf_hash=_sha256(csrf_token),
            idle_expires_at=idle_expires_at,
            absolute_expires_at=absolute_expires_at,
            ip_address=ip_address,
            user_agent_hash=user_agent_hash,
        )
        self._session.add(auth_session)
        self._session.flush()
        return auth_session

    def find_by_token(self, token: str) -> AuthSession | None:
        stmt = select(AuthSession).where(AuthSession.token_hash == _sha256(token))
        return self._session.execute(stmt).scalar_one_or_none()

    def revoke(self, session_id: bytes, reason: str) -> None:
        auth_session = self._session.get(AuthSession, session_id)
        if auth_session is None:
            return
        auth_session.revoked_at = datetime.utcnow()
        auth_session.revoke_reason = reason
        self._session.flush()
