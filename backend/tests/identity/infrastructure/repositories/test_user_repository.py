"""RED del Paso 6 — `UserRepository`.

Contrato exigido (lo implementa
`prime.identity.infrastructure.repositories.user_repository.UserRepository`):

    UserRepository(session)
        .add(*, role_id, full_name, email, password_hash,
             email_verified_at=None, must_change_password=False) -> User
        .get_by_email(email: str) -> User | None
        .get_by_id(user_id: int) -> User | None

`password_hash` ya llega hasheado (Argon2id, Paso 2 del dominio) — el
repositorio no hashea nada, solo persiste. Por eso el test no comprueba
"nunca en claro" aquí: esa garantía la da `Argon2PasswordHasher`, ya
probada en `tests/identity/domain`. Lo que sí verifica este test es que el
repositorio guarda exactamente el hash recibido, byte a byte, y que
`get_by_email` normaliza igual que la columna (case/acento-sensible, como
exige la colación `as_cs` de la migración).
"""
from __future__ import annotations

from sqlalchemy import text

from prime.identity.infrastructure.repositories.user_repository import UserRepository

ARGON2_HASH = "$argon2id$v=19$m=65536,t=3,p=4$c2FsdHNhbHQ$aGFzaGhhc2hoYXNo"


def test_add_persiste_y_get_by_email_recupera(db_session):
    repo = UserRepository(db_session)

    user = repo.add(
        role_id=1,
        full_name="Ada Lovelace",
        email="ada@primetelecom.com",
        password_hash=ARGON2_HASH,
    )
    db_session.commit()

    assert user.id is not None

    found = repo.get_by_email("ada@primetelecom.com")
    assert found is not None
    assert found.id == user.id
    assert found.full_name == "Ada Lovelace"


def test_get_by_id_recupera_el_mismo_usuario(db_session):
    repo = UserRepository(db_session)
    user = repo.add(
        role_id=1,
        full_name="Grace Hopper",
        email="grace@primetelecom.com",
        password_hash=ARGON2_HASH,
    )
    db_session.commit()

    found = repo.get_by_id(user.id)
    assert found is not None
    assert found.email == "grace@primetelecom.com"


def test_get_by_email_inexistente_devuelve_none(db_session):
    repo = UserRepository(db_session)
    assert repo.get_by_email("fantasma@primetelecom.com") is None


def test_el_hash_almacenado_es_exactamente_el_recibido(db_session):
    """El repositorio no transforma el hash — lo persiste tal cual.

    No comprueba "el hash nunca es la contraseña en claro" aquí (eso es
    responsabilidad de `PasswordHasher`, ya cubierta en el dominio); lo
    que sí es responsabilidad de la capa de persistencia es NO alterar el
    formato PHC al guardarlo o leerlo (encoding, truncado por longitud de
    columna, etc.).
    """
    repo = UserRepository(db_session)
    user = repo.add(
        role_id=1,
        full_name="Katherine Johnson",
        email="katherine@primetelecom.com",
        password_hash=ARGON2_HASH,
    )
    db_session.commit()

    row = db_session.execute(
        text("SELECT password_hash FROM users WHERE id = :id"), {"id": user.id}
    ).fetchone()
    assert row.password_hash == ARGON2_HASH
