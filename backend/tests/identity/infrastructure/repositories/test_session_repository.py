"""RED del Paso 6 — `SessionRepository`.

Contrato exigido:

    SessionRepository(session)
        .create(*, user_id, token: str, csrf_token: str,
                idle_expires_at, absolute_expires_at,
                ip_address: bytes|None=None, user_agent_hash: bytes|None=None) -> AuthSession
        .find_by_token(token: str) -> AuthSession | None
        .revoke(session_id: bytes, reason: str) -> None

Regla de `AUTH_BLUEPRINT.md` §2.1 / §4.2: "en la base de datos nunca se
guarda el token, sino su SHA-256". El repositorio recibe el token en claro
(el que se pondrá en la cookie) y persiste únicamente `sha256(token)` en
`token_hash` — nunca el valor original. Lo mismo para `csrf_token` /
`csrf_hash`.
"""
from __future__ import annotations

import hashlib
from datetime import datetime, timedelta, timezone

from sqlalchemy import text

from prime.identity.infrastructure.repositories.session_repository import SessionRepository

PLAINTEXT_TOKEN = "T0k3n-en-claro-32-bytes-de-entropia-ABCDEF"
PLAINTEXT_CSRF = "csrf-secreto-atado-a-la-sesion-XYZ123"


def _now():
    return datetime.now(timezone.utc).replace(tzinfo=None)


def test_create_persiste_solo_el_hash_del_token(db_session, seeded_user_id):
    repo = SessionRepository(db_session)

    session_row = repo.create(
        user_id=seeded_user_id,
        token=PLAINTEXT_TOKEN,
        csrf_token=PLAINTEXT_CSRF,
        idle_expires_at=_now() + timedelta(minutes=30),
        absolute_expires_at=_now() + timedelta(hours=8),
    )
    db_session.commit()

    expected_token_hash = hashlib.sha256(PLAINTEXT_TOKEN.encode("utf-8")).digest()
    expected_csrf_hash = hashlib.sha256(PLAINTEXT_CSRF.encode("utf-8")).digest()

    row = db_session.execute(
        text("SELECT token_hash, csrf_hash FROM auth_sessions WHERE id = :id"),
        {"id": session_row.id},
    ).fetchone()
    assert bytes(row.token_hash) == expected_token_hash
    assert bytes(row.csrf_hash) == expected_csrf_hash


def test_el_token_en_claro_nunca_aparece_en_la_tabla(db_session, seeded_user_id):
    repo = SessionRepository(db_session)
    repo.create(
        user_id=seeded_user_id,
        token=PLAINTEXT_TOKEN,
        csrf_token=PLAINTEXT_CSRF,
        idle_expires_at=_now() + timedelta(minutes=30),
        absolute_expires_at=_now() + timedelta(hours=8),
    )
    db_session.commit()

    # Consulta literal: si el token en claro apareciera en CUALQUIER columna
    # de texto/binario de la fila, esta búsqueda por LIKE lo encontraría.
    leaked = db_session.execute(
        text(
            "SELECT COUNT(*) FROM auth_sessions WHERE "
            "CAST(token_hash AS TEXT) LIKE :needle OR "
            "CAST(csrf_hash AS TEXT) LIKE :needle"
        ),
        {"needle": f"%{PLAINTEXT_TOKEN}%"},
    ).scalar_one()
    assert leaked == 0


def test_find_by_token_recupera_por_el_token_en_claro(db_session, seeded_user_id):
    repo = SessionRepository(db_session)
    created = repo.create(
        user_id=seeded_user_id,
        token=PLAINTEXT_TOKEN,
        csrf_token=PLAINTEXT_CSRF,
        idle_expires_at=_now() + timedelta(minutes=30),
        absolute_expires_at=_now() + timedelta(hours=8),
    )
    db_session.commit()

    found = repo.find_by_token(PLAINTEXT_TOKEN)
    assert found is not None
    assert found.id == created.id

    assert repo.find_by_token("token-que-no-existe") is None


def test_revoke_marca_revoked_at_y_revoke_reason(db_session, seeded_user_id):
    repo = SessionRepository(db_session)
    created = repo.create(
        user_id=seeded_user_id,
        token=PLAINTEXT_TOKEN,
        csrf_token=PLAINTEXT_CSRF,
        idle_expires_at=_now() + timedelta(minutes=30),
        absolute_expires_at=_now() + timedelta(hours=8),
    )
    db_session.commit()

    repo.revoke(created.id, "LOGOUT")
    db_session.commit()

    row = db_session.execute(
        text("SELECT revoked_at, revoke_reason FROM auth_sessions WHERE id = :id"),
        {"id": created.id},
    ).fetchone()
    assert row.revoked_at is not None
    assert row.revoke_reason == "LOGOUT"
