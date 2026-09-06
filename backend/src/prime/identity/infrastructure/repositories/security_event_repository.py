"""`SecurityEventRepository` — persistencia de `security_events` (Paso 6).

Contrato: ver
`tests/identity/infrastructure/repositories/test_security_event_repository.py`.
`AUTH_BLUEPRINT.md` §4.6: `detail` es JSON de contexto — nunca credenciales
ni tokens (responsabilidad de quien llama, en Paso 7; este repositorio solo
persiste y recupera tal cual lo que se le entrega).
"""
from __future__ import annotations

from sqlalchemy.orm import Session

from prime.identity.infrastructure.orm.models import SecurityEvent


class SecurityEventRepository:
    def __init__(self, session: Session):
        self._session = session

    def record(
        self,
        *,
        user_id: int | None,
        event_type: str,
        detail: dict | None = None,
        ip_address: bytes | None = None,
    ) -> SecurityEvent:
        event = SecurityEvent(
            user_id=user_id,
            event_type=event_type,
            detail=detail,
            ip_address=ip_address,
        )
        self._session.add(event)
        self._session.flush()
        return event
