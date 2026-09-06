"""RED del Paso 6 — `PasswordResetTokenRepository`.

Contrato exigido:

    PasswordResetTokenRepository(session)
        .create(*, user_id, token: str, expires_at,
                requested_ip=None) -> PasswordResetToken
        .find_by_token(token: str) -> PasswordResetToken | None

`AUTH_BLUEPRINT.md` §4.5: `token_hash` es SHA-256 del token de 32 bytes
enviado por correo — sin pepper, porque el token ya tiene entropía
suficiente (a diferencia del código de 6 dígitos de MFA). Esta tabla es
"vía de entrada al login": un reseteo débil hace irrelevante lo robusto
que sea el resto, así que el criterio de "nunca en claro" aplica igual.
"""
from __future__ import annotations

import hashlib
from datetime import datetime, timedelta, timezone

from sqlalchemy import text

from prime.identity.infrastructure.repositories.password_reset_token_repository import (
    PasswordResetTokenRepository,
)

PLAINTEXT_TOKEN = "reset-token-32-bytes-de-entropia-enviado-por-correo"


def _now():
    return datetime.now(timezone.utc).replace(tzinfo=None)


def test_create_persiste_solo_el_hash_del_token(db_session, seeded_user_id):
    repo = PasswordResetTokenRepository(db_session)

    reset_token = repo.create(
        user_id=seeded_user_id,
        token=PLAINTEXT_TOKEN,
        expires_at=_now() + timedelta(minutes=30),
    )
    db_session.commit()

    expected_hash = hashlib.sha256(PLAINTEXT_TOKEN.encode("utf-8")).digest()
    row = db_session.execute(
        text("SELECT token_hash FROM password_reset_tokens WHERE id = :id"),
        {"id": reset_token.id},
    ).fetchone()
    assert bytes(row.token_hash) == expected_hash


def test_el_token_en_claro_nunca_aparece_en_la_tabla(db_session, seeded_user_id):
    repo = PasswordResetTokenRepository(db_session)
    repo.create(
        user_id=seeded_user_id,
        token=PLAINTEXT_TOKEN,
        expires_at=_now() + timedelta(minutes=30),
    )
    db_session.commit()

    leaked = db_session.execute(
        text(
            "SELECT COUNT(*) FROM password_reset_tokens "
            "WHERE CAST(token_hash AS TEXT) LIKE :needle"
        ),
        {"needle": f"%{PLAINTEXT_TOKEN}%"},
    ).scalar_one()
    assert leaked == 0


def test_find_by_token_recupera_por_el_token_en_claro_y_un_solo_uso(
    db_session, seeded_user_id
):
    repo = PasswordResetTokenRepository(db_session)
    created = repo.create(
        user_id=seeded_user_id,
        token=PLAINTEXT_TOKEN,
        expires_at=_now() + timedelta(minutes=30),
    )
    db_session.commit()

    found = repo.find_by_token(PLAINTEXT_TOKEN)
    assert found is not None
    assert found.id == created.id
    assert found.consumed_at is None

    assert repo.find_by_token("token-que-no-existe") is None
