"""RED del Paso 6 — `LoginAttemptRepository`.

Contrato exigido:

    LoginAttemptRepository(session, pepper: bytes)
        .record(*, user_id: int | None, email: str,
                ip_address: bytes | None, user_agent_hash: bytes | None,
                outcome: str) -> LoginAttempt

`AUTH_BLUEPRINT.md` §4.3: el correo tecleado se guarda como
HMAC-SHA256(email, pepper) en `email_hmac`, nunca en claro — así se puede
agrupar y contar intentos por identidad sin que la tabla sea una lista de
correos legible. `user_id` es NULLABLE a propósito: un correo inexistente
también debe dejar rastro.
"""
from __future__ import annotations

import hashlib
import hmac

from sqlalchemy import text

from prime.identity.infrastructure.repositories.login_attempt_repository import (
    LoginAttemptRepository,
)
from .conftest import TEST_PEPPER

PLAINTEXT_EMAIL = "victima@primetelecom.com"


def _expected_hmac(email: str) -> bytes:
    return hmac.new(TEST_PEPPER, email.encode("utf-8"), hashlib.sha256).digest()


def test_record_persiste_solo_el_hmac_del_email(db_session, seeded_user_id):
    repo = LoginAttemptRepository(db_session, pepper=TEST_PEPPER)

    attempt = repo.record(
        user_id=seeded_user_id,
        email=PLAINTEXT_EMAIL,
        ip_address=None,
        user_agent_hash=None,
        outcome="BAD_PASSWORD",
    )
    db_session.commit()

    row = db_session.execute(
        text("SELECT email_hmac, outcome FROM login_attempts WHERE id = :id"),
        {"id": attempt.id},
    ).fetchone()
    assert bytes(row.email_hmac) == _expected_hmac(PLAINTEXT_EMAIL)
    assert row.outcome == "BAD_PASSWORD"


def test_el_correo_en_claro_nunca_aparece_en_la_tabla(db_session, seeded_user_id):
    repo = LoginAttemptRepository(db_session, pepper=TEST_PEPPER)
    repo.record(
        user_id=seeded_user_id,
        email=PLAINTEXT_EMAIL,
        ip_address=None,
        user_agent_hash=None,
        outcome="SUCCESS",
    )
    db_session.commit()

    leaked = db_session.execute(
        text(
            "SELECT COUNT(*) FROM login_attempts "
            "WHERE CAST(email_hmac AS TEXT) LIKE :needle"
        ),
        {"needle": f"%{PLAINTEXT_EMAIL}%"},
    ).scalar_one()
    assert leaked == 0


def test_registra_intentos_de_correos_inexistentes_con_user_id_nulo(db_session):
    # Directiva 3: sondear correos inexistentes también debe dejar rastro,
    # o un atacante que enumera nombre.apellido@dominio no deja huella.
    repo = LoginAttemptRepository(db_session, pepper=TEST_PEPPER)
    attempt = repo.record(
        user_id=None,
        email="no.existe@primetelecom.com",
        ip_address=None,
        user_agent_hash=None,
        outcome="UNKNOWN_EMAIL",
    )
    db_session.commit()

    row = db_session.execute(
        text("SELECT user_id, outcome FROM login_attempts WHERE id = :id"),
        {"id": attempt.id},
    ).fetchone()
    assert row.user_id is None
    assert row.outcome == "UNKNOWN_EMAIL"
