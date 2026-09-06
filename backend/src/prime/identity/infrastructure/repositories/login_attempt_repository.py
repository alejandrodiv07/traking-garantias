"""`LoginAttemptRepository` — persistencia de `login_attempts` (Paso 6).

Contrato: ver
`tests/identity/infrastructure/repositories/test_login_attempt_repository.py`.
`AUTH_BLUEPRINT.md` §4.3: el correo tecleado se guarda como
HMAC-SHA256(email, pepper), nunca en claro. `user_id` es NULLABLE a
propósito — un correo inexistente también deja rastro (directiva 3).
"""
from __future__ import annotations

import hashlib
import hmac

from sqlalchemy.orm import Session

from prime.identity.infrastructure.orm.models import LoginAttempt


class LoginAttemptRepository:
    def __init__(self, session: Session, pepper: bytes):
        self._session = session
        self._pepper = pepper

    def record(
        self,
        *,
        user_id: int | None,
        email: str,
        ip_address: bytes | None,
        user_agent_hash: bytes | None,
        outcome: str,
    ) -> LoginAttempt:
        attempt = LoginAttempt(
            user_id=user_id,
            email_hmac=hmac.new(self._pepper, email.encode("utf-8"), hashlib.sha256).digest(),
            ip_address=ip_address,
            user_agent_hash=user_agent_hash,
            outcome=outcome,
        )
        self._session.add(attempt)
        self._session.flush()
        return attempt
