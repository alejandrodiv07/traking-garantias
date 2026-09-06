"""RED del Paso 6 — `MfaChallengeRepository`.

Contrato exigido:

    MfaChallengeRepository(session, pepper: bytes)
        .create(*, user_id, code: str, preauth_token: str, expires_at,
                purpose: str = "LOGIN", ip_address=None) -> MfaChallenge
        .find_by_preauth_token(preauth_token: str) -> MfaChallenge | None

`AUTH_BLUEPRINT.md` §4.4: el código de 6 dígitos se guarda como
HMAC-SHA256(código, pepper) en `code_hmac` — el espacio de solo 10^6
valores exige pepper, si no un volcado de la tabla permite fuerza bruta
offline instantánea. `preauth_hash` es SHA-256 del token de la cookie
`pt_mfa` (32 bytes de entropía, no necesita pepper — igual que
`auth_sessions.token_hash`).
"""
from __future__ import annotations

import hashlib
import hmac
from datetime import datetime, timedelta, timezone

from sqlalchemy import text

from prime.identity.infrastructure.repositories.mfa_challenge_repository import (
    MfaChallengeRepository,
)
from .conftest import TEST_PEPPER

PLAINTEXT_CODE = "042931"
PLAINTEXT_PREAUTH_TOKEN = "preauth-cookie-pt_mfa-32-bytes-entropia"


def _now():
    return datetime.now(timezone.utc).replace(tzinfo=None)


def _expected_code_hmac(code: str) -> bytes:
    return hmac.new(TEST_PEPPER, code.encode("utf-8"), hashlib.sha256).digest()


def _expected_preauth_hash(token: str) -> bytes:
    return hashlib.sha256(token.encode("utf-8")).digest()


def test_create_persiste_solo_los_hashes_no_el_codigo_ni_el_token(
    db_session, seeded_user_id
):
    repo = MfaChallengeRepository(db_session, pepper=TEST_PEPPER)

    challenge = repo.create(
        user_id=seeded_user_id,
        code=PLAINTEXT_CODE,
        preauth_token=PLAINTEXT_PREAUTH_TOKEN,
        expires_at=_now() + timedelta(minutes=10),
    )
    db_session.commit()

    row = db_session.execute(
        text(
            "SELECT code_hmac, preauth_hash, purpose FROM mfa_challenges "
            "WHERE id = :id"
        ),
        {"id": challenge.id},
    ).fetchone()
    assert bytes(row.code_hmac) == _expected_code_hmac(PLAINTEXT_CODE)
    assert bytes(row.preauth_hash) == _expected_preauth_hash(PLAINTEXT_PREAUTH_TOKEN)
    assert row.purpose == "LOGIN"


def test_ni_el_codigo_ni_el_token_preauth_aparecen_en_claro(db_session, seeded_user_id):
    repo = MfaChallengeRepository(db_session, pepper=TEST_PEPPER)
    repo.create(
        user_id=seeded_user_id,
        code=PLAINTEXT_CODE,
        preauth_token=PLAINTEXT_PREAUTH_TOKEN,
        expires_at=_now() + timedelta(minutes=10),
    )
    db_session.commit()

    leaked = db_session.execute(
        text(
            "SELECT COUNT(*) FROM mfa_challenges WHERE "
            "CAST(code_hmac AS TEXT) LIKE :code_needle OR "
            "CAST(preauth_hash AS TEXT) LIKE :token_needle"
        ),
        {"code_needle": f"%{PLAINTEXT_CODE}%", "token_needle": f"%{PLAINTEXT_PREAUTH_TOKEN}%"},
    ).scalar_one()
    assert leaked == 0


def test_find_by_preauth_token_recupera_el_desafio_vigente(db_session, seeded_user_id):
    repo = MfaChallengeRepository(db_session, pepper=TEST_PEPPER)
    created = repo.create(
        user_id=seeded_user_id,
        code=PLAINTEXT_CODE,
        preauth_token=PLAINTEXT_PREAUTH_TOKEN,
        expires_at=_now() + timedelta(minutes=10),
    )
    db_session.commit()

    found = repo.find_by_preauth_token(PLAINTEXT_PREAUTH_TOKEN)
    assert found is not None
    assert found.id == created.id

    assert repo.find_by_preauth_token("token-que-no-existe") is None
