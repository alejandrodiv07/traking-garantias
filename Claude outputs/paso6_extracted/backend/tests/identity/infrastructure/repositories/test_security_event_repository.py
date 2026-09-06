"""RED del Paso 6 — `SecurityEventRepository`.

Contrato exigido:

    SecurityEventRepository(session)
        .record(*, user_id, event_type: str, detail: dict | None = None,
                ip_address=None) -> SecurityEvent

Sin secretos que hashear — `security_events.detail` es JSON de contexto y
`AUTH_BLUEPRINT.md` §4.6 es explícito: "NUNCA credenciales ni tokens". El
repositorio no puede impedir por sí solo que una capa superior meta un
secreto ahí (eso es responsabilidad de quien la llama, en Paso 7), así que
este test cubre lo que sí es responsabilidad de la persistencia: guardar y
recuperar el evento tal cual, incluido el `detail` estructurado.
"""
from __future__ import annotations

from sqlalchemy import text

from prime.identity.infrastructure.repositories.security_event_repository import (
    SecurityEventRepository,
)


def test_record_persiste_el_evento_con_su_detalle(db_session, seeded_user_id):
    repo = SecurityEventRepository(db_session)

    event = repo.record(
        user_id=seeded_user_id,
        event_type="ACCOUNT_LOCKED",
        detail={"failed_attempts": 5, "lockout_level": 1},
    )
    db_session.commit()

    row = db_session.execute(
        text("SELECT event_type, detail FROM security_events WHERE id = :id"),
        {"id": event.id},
    ).fetchone()
    assert row.event_type == "ACCOUNT_LOCKED"

    import json

    stored_detail = row.detail if isinstance(row.detail, dict) else json.loads(row.detail)
    assert stored_detail == {"failed_attempts": 5, "lockout_level": 1}


def test_record_admite_user_id_nulo_para_eventos_sin_usuario_conocido(db_session):
    repo = SecurityEventRepository(db_session)

    event = repo.record(user_id=None, event_type="SUSPICIOUS_SESSION_REUSE", detail=None)
    db_session.commit()

    row = db_session.execute(
        text("SELECT user_id, detail FROM security_events WHERE id = :id"),
        {"id": event.id},
    ).fetchone()
    assert row.user_id is None
    assert row.detail is None
