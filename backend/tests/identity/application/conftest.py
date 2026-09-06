"""Dobles en memoria para los tests del Paso 7.

Por diseño (`AUTH_BLUEPRINT.md` §6, Paso 7): los casos de uso se prueban
con repositorios FALSOS en memoria — sin MySQL, sin Alembic, sin Flask.
Las políticas de dominio (`LockoutPolicy`, `MfaPolicy`, `OtpGenerator`) NO
se fakean: son lógica pura ya probada en `tests/identity/domain` (129
tests), y reusarlas aquí es lo que hace que estos tests validen la
orquestación real, no una simulación de ella.

Estos fakes replican el contrato público de los repositorios reales del
Paso 6 (mismos nombres de método) más un `save()` que Paso 6 no necesitaba
— los casos de uso mutan estado (contador de fallos, `consumed_at` del
desafío) y necesitan persistir esa mutación. Cuando se conecte esto a
infraestructura real, `UserRepository` y `MfaChallengeRepository`
necesitarán un método `save()` análogo (los de Paso 6 ya devuelven
entidades ORM mutables; añadirlo es una línea, `session.flush()`).

Las filas se modelan como dataclasses propias del test (no se importa
`prime.identity.infrastructure.orm`): los casos de uso de aplicación no
deben depender de SQLAlchemy, y los `server_default` del ORM no se aplican
fuera de una inserción real — reusar los modelos ORM aquí produciría
`None` silencioso en campos como `failed_login_count` y ocultaría bugs.
"""
from __future__ import annotations

import hashlib
from dataclasses import dataclass, field
from datetime import datetime
from typing import Optional

import pytest


# ---------------------------------------------------------------------------
# Filas en memoria (equivalentes ligeros de las entidades ORM del Paso 6)
# ---------------------------------------------------------------------------

@dataclass
class FakeUserRow:
    id: int
    role_id: int
    full_name: str
    email: str
    password_hash: str
    email_verified_at: Optional[datetime] = None
    password_algo: str = "argon2id"
    must_change_password: bool = False
    failed_login_count: int = 0
    last_failed_login_at: Optional[datetime] = None
    locked_until: Optional[datetime] = None
    lockout_level: int = 0
    mfa_enabled: bool = True
    is_active: bool = True


@dataclass
class FakeAuthSessionRow:
    id: bytes
    user_id: int
    token_hash: bytes
    csrf_hash: bytes
    idle_expires_at: datetime
    absolute_expires_at: datetime
    ip_address: Optional[bytes] = None
    user_agent_hash: Optional[bytes] = None
    revoked_at: Optional[datetime] = None
    revoke_reason: Optional[str] = None


@dataclass
class FakeLoginAttemptRow:
    id: int
    user_id: Optional[int]
    email_hmac: bytes
    ip_address: Optional[bytes]
    user_agent_hash: Optional[bytes]
    outcome: str


@dataclass
class FakeMfaChallengeRow:
    id: int
    user_id: int
    code_hmac: bytes
    preauth_hash: bytes
    expires_at: datetime
    purpose: str = "LOGIN"
    attempts: int = 0
    max_attempts: int = 5
    resend_count: int = 0
    consumed_at: Optional[datetime] = None


@dataclass
class FakeSecurityEventRow:
    id: int
    user_id: Optional[int]
    event_type: str
    detail: Optional[dict] = None


# ---------------------------------------------------------------------------
# Repositorios falsos — mismo contrato público que Paso 6, en memoria
# ---------------------------------------------------------------------------

class FakeUserRepository:
    def __init__(self):
        self._rows: dict[int, FakeUserRow] = {}
        self._next_id = 1

    def add(self, **fields) -> FakeUserRow:
        row = FakeUserRow(id=self._next_id, **fields)
        self._rows[row.id] = row
        self._next_id += 1
        return row

    def get_by_email(self, email: str) -> Optional[FakeUserRow]:
        return next((u for u in self._rows.values() if u.email == email), None)

    def get_by_id(self, user_id: int) -> Optional[FakeUserRow]:
        return self._rows.get(user_id)

    def save(self, user: FakeUserRow) -> None:
        self._rows[user.id] = user


class FakeSessionRepository:
    def __init__(self):
        self._rows: list[FakeAuthSessionRow] = []
        self._next_id = 1

    def create(self, *, user_id, token, csrf_token, idle_expires_at, absolute_expires_at,
               ip_address=None, user_agent_hash=None) -> FakeAuthSessionRow:
        row = FakeAuthSessionRow(
            id=self._next_id.to_bytes(16, "big"),
            user_id=user_id,
            token_hash=hashlib.sha256(token.encode("utf-8")).digest(),
            csrf_hash=hashlib.sha256(csrf_token.encode("utf-8")).digest(),
            idle_expires_at=idle_expires_at,
            absolute_expires_at=absolute_expires_at,
            ip_address=ip_address,
            user_agent_hash=user_agent_hash,
        )
        self._next_id += 1
        self._rows.append(row)
        return row

    def count(self) -> int:
        return len(self._rows)

    def all(self) -> list[FakeAuthSessionRow]:
        return list(self._rows)


class FakeLoginAttemptRepository:
    def __init__(self, pepper: bytes):
        self._pepper = pepper
        self._rows: list[FakeLoginAttemptRow] = []
        self._next_id = 1

    def record(self, *, user_id, email, ip_address, user_agent_hash, outcome) -> FakeLoginAttemptRow:
        import hmac
        row = FakeLoginAttemptRow(
            id=self._next_id,
            user_id=user_id,
            email_hmac=hmac.new(self._pepper, email.encode("utf-8"), hashlib.sha256).digest(),
            ip_address=ip_address,
            user_agent_hash=user_agent_hash,
            outcome=outcome,
        )
        self._next_id += 1
        self._rows.append(row)
        return row

    def count(self) -> int:
        return len(self._rows)

    def outcomes(self) -> list[str]:
        return [row.outcome for row in self._rows]


class FakeMfaChallengeRepository:
    def __init__(self, pepper: bytes, otp_generator):
        self._pepper = pepper
        self._otp = otp_generator
        self._rows: dict[int, FakeMfaChallengeRow] = {}
        self._next_id = 1

    def create(self, *, user_id, code, preauth_token, expires_at, purpose="LOGIN",
               ip_address=None) -> FakeMfaChallengeRow:
        row = FakeMfaChallengeRow(
            id=self._next_id,
            user_id=user_id,
            code_hmac=self._otp.hash(code, self._pepper),
            preauth_hash=hashlib.sha256(preauth_token.encode("utf-8")).digest(),
            expires_at=expires_at,
            purpose=purpose,
        )
        self._next_id += 1
        self._rows[row.id] = row
        return row

    def find_by_preauth_token(self, preauth_token: str) -> Optional[FakeMfaChallengeRow]:
        target = hashlib.sha256(preauth_token.encode("utf-8")).digest()
        return next((c for c in self._rows.values() if c.preauth_hash == target), None)

    def save(self, challenge: FakeMfaChallengeRow) -> None:
        self._rows[challenge.id] = challenge

    def count(self) -> int:
        return len(self._rows)


class FakeSecurityEventRepository:
    def __init__(self):
        self._rows: list[FakeSecurityEventRow] = []
        self._next_id = 1

    def record(self, *, user_id, event_type, detail=None, ip_address=None) -> FakeSecurityEventRow:
        row = FakeSecurityEventRow(id=self._next_id, user_id=user_id, event_type=event_type, detail=detail)
        self._next_id += 1
        self._rows.append(row)
        return row

    def event_types(self) -> list[str]:
        return [row.event_type for row in self._rows]


class FakePasswordHasher:
    """Adaptador rápido — el Argon2id real se prueba aparte (Paso 2).

    `PlainPassword` solo expone `.expose()` (a propósito, ver
    `prime.identity.domain.value_objects` — nunca `.value`, para que leer
    el secreto se vea en el diff), así que el fake lo respeta igual que el
    hasher real lo haría.
    """

    def hash(self, plain_password) -> str:
        return "$fake$" + hashlib.sha256(plain_password.expose().encode("utf-8")).hexdigest()

    def verify(self, plain_password, password_hash: str) -> bool:
        return self.hash(plain_password) == password_hash

    def needs_rehash(self, password_hash: str) -> bool:
        return False


DECOY_HASH = "$fake$" + "0" * 64
TEST_PEPPER = b"test-pepper-not-for-production-0123456789"


@pytest.fixture
def user_repo():
    return FakeUserRepository()


@pytest.fixture
def session_repo():
    return FakeSessionRepository()


@pytest.fixture
def login_attempt_repo():
    return FakeLoginAttemptRepository(pepper=TEST_PEPPER)


@pytest.fixture
def security_event_repo():
    return FakeSecurityEventRepository()


@pytest.fixture
def password_hasher():
    return FakePasswordHasher()


@pytest.fixture
def otp_generator():
    from prime.identity.domain.mfa_policy import OtpGenerator

    return OtpGenerator()


@pytest.fixture
def lockout_policy():
    from prime.identity.domain.lockout_policy import LockoutPolicy

    return LockoutPolicy()


@pytest.fixture
def mfa_policy(otp_generator):
    from prime.identity.domain.mfa_policy import MfaPolicy

    # MfaPolicy es un namespace de staticmethods (sin __init__ propio, ver
    # `prime.identity.domain.mfa_policy`) — se expone la clase misma, no una
    # instancia construida con argumentos que su constructor no acepta.
    return MfaPolicy


@pytest.fixture
def mfa_challenge_repo(otp_generator):
    return FakeMfaChallengeRepository(pepper=TEST_PEPPER, otp_generator=otp_generator)
