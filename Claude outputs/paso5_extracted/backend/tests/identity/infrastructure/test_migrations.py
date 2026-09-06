"""RED del Paso 5 — integridad de la migración inicial.

Corre contra SQLite en fichero (dev, §3 del documento de fase). Es RED
hasta que existan `alembic/env.py`, `alembic/versions/0001_...py` y los
modelos de `prime.identity.infrastructure.orm` — cualquiera de las tres
piezas ausente o incorrecta hace fallar `alembic upgrade head`.
"""
from __future__ import annotations

import pytest
from alembic import command
from sqlalchemy import create_engine, inspect, text
from sqlalchemy.exc import IntegrityError

from .conftest import make_alembic_config

EXPECTED_TABLES = {
    "roles",
    "users",
    "auth_sessions",
    "login_attempts",
    "mfa_challenges",
    "password_reset_tokens",
    "security_events",
}


def test_upgrade_desde_bd_vacia_no_falla(sqlite_database_url):
    cfg = make_alembic_config(sqlite_database_url)

    # No debe lanzar — en particular no debe fallar con errno 150 por la FK
    # de users.role_id contra una tabla `roles` inexistente o vacía.
    command.upgrade(cfg, "head")

    engine = create_engine(sqlite_database_url)
    inspector = inspect(engine)
    tables = set(inspector.get_table_names())
    assert EXPECTED_TABLES <= tables

    with engine.connect() as conn:
        admin_role = conn.execute(
            text("SELECT code FROM roles WHERE code = 'ADMIN'")
        ).fetchone()
        assert admin_role is not None, (
            "la migración inicial debe sembrar roles.code='ADMIN' "
            "para que exista un role_id válido antes del primer usuario"
        )


def test_downgrade_revierte_limpiamente(sqlite_database_url):
    cfg = make_alembic_config(sqlite_database_url)
    command.upgrade(cfg, "head")
    command.downgrade(cfg, "base")

    engine = create_engine(sqlite_database_url)
    inspector = inspect(engine)
    remaining = EXPECTED_TABLES & set(inspector.get_table_names())
    assert remaining == set(), f"tablas que sobrevivieron al downgrade: {remaining}"


def test_uq_users_email_rechaza_duplicado_exacto(sqlite_database_url):
    cfg = make_alembic_config(sqlite_database_url)
    command.upgrade(cfg, "head")

    engine = create_engine(sqlite_database_url)
    insert_user = text(
        "INSERT INTO users (role_id, full_name, email, password_hash) "
        "VALUES (1, :name, :email, 'x')"
    )
    with engine.begin() as conn:
        conn.execute(insert_user, {"name": "Ada", "email": "ada@x.com"})

    with engine.begin() as conn:
        with pytest.raises(IntegrityError):
            conn.execute(insert_user, {"name": "Ada 2", "email": "ada@x.com"})
