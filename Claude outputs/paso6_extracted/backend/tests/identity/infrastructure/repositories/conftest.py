"""Fixtures compartidas de los tests de repositorios (Paso 6).

Reutiliza `sqlite_database_url` y `make_alembic_config` del conftest padre
(`tests/identity/infrastructure/conftest.py`) — pytest los hereda solo por
estar en un directorio superior, no hace falta reimportarlos.

`db_session` sube el esquema completo (Paso 5) contra SQLite en fichero y
entrega una `Session` de SQLAlchemy ya conectada. `seeded_user_id` inserta
un usuario mínimo por SQL directo (no vía `UserRepository`, que es
precisamente lo que estos tests están verificando) para tener un
`user_id` válido al que colgar sesiones, intentos, desafíos MFA, etc.
"""
from __future__ import annotations

import pytest
from alembic import command
from sqlalchemy import create_engine, text
from sqlalchemy.orm import sessionmaker

from ..conftest import make_alembic_config


@pytest.fixture
def db_session(sqlite_database_url):
    cfg = make_alembic_config(sqlite_database_url)
    command.upgrade(cfg, "head")

    engine = create_engine(sqlite_database_url)
    Session = sessionmaker(bind=engine, future=True, expire_on_commit=False)
    session = Session()
    try:
        yield session
    finally:
        session.close()
        engine.dispose()


@pytest.fixture
def seeded_user_id(db_session) -> int:
    result = db_session.execute(
        text(
            "INSERT INTO users (role_id, full_name, email, password_hash) "
            "VALUES (1, 'Test User', 'test.repo@primetelecom.com', 'placeholder-hash')"
        )
    )
    db_session.commit()
    return result.lastrowid


# Pepper de prueba para HMAC (email_hmac, code_hmac). En producción sale de
# la variable de entorno PEPPER (Paso 0); aquí se fija para que el test sea
# determinista y pueda recalcular el HMAC esperado de forma independiente.
TEST_PEPPER = b"test-pepper-not-for-production-0123456789"
