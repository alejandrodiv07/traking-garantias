"""`MfaChallengeRepository` — persistencia de `mfa_challenges` (Paso 6).

Contrato: ver
`tests/identity/infrastructure/repositories/test_mfa_challenge_repository.py`.
`AUTH_BLUEPRINT.md` §4.4: el código de 6 dígitos se guarda como
HMAC-SHA256(código, pepper) en `code_hmac` (el pepper evita fuerza bruta
offline sobre un espacio de solo 10^6 valores). `preauth_hash` es SHA-256
del token de la cookie `pt_mfa` (32 bytes de entropía propia, no necesita
pepper).

`save()`: igual que en `UserRepository`, las entidades ORM ya son
mutables y un `commit()` bastaría, pero el Paso 7 (`VerifyMfaUseCase`)
necesita persistir explícitamente `attempts`/`consumed_at` tras aplicar
`MfaPolicy.evaluar` — se añade el método para ese punto de conexión.
"""
from __future__ import annotations

import hashlib
from datetime import datetime

from sqlalchemy import select
from sqlalchemy.orm import Session

from prime.identity.domain.mfa_policy import OtpGenerator
from prime.identity.infrastructure.orm.models import MfaChallenge


def _sha256(value: str) -> bytes:
    return hashlib.sha256(value.encode("utf-8")).digest()


class MfaChallengeRepository:
    def __init__(self, session: Session, pepper: bytes):
        self._session = session
        self._pepper = pepper

    def create(
        self,
        *,
        user_id: int,
        code: str,
        preauth_token: str,
        expires_at: datetime,
        purpose: str = "LOGIN",
        ip_address: bytes | None = None,
    ) -> MfaChallenge:
        challenge = MfaChallenge(
            user_id=user_id,
            code_hmac=OtpGenerator.hash(code, self._pepper),
            purpose=purpose,
            preauth_hash=_sha256(preauth_token),
            expires_at=expires_at,
            ip_address=ip_address,
        )
        self._session.add(challenge)
        self._session.flush()
        return challenge

    def find_by_preauth_token(self, preauth_token: str) -> MfaChallenge | None:
        stmt = select(MfaChallenge).where(MfaChallenge.preauth_hash == _sha256(preauth_token))
        return self._session.execute(stmt).scalar_one_or_none()

    def save(self, challenge: MfaChallenge) -> None:
        self._session.add(challenge)
        self._session.flush()
