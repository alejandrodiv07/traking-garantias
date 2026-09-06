"""RED del Paso 5 — colación de `users.email` (hallazgo HIGH #7 de la
auditoría, §8.2). Solo tiene sentido contra MySQL real: SQLite no
implementa `COLLATE utf8mb4_0900_as_cs` ni distingue mayúsculas/acentos
por colación, así que ejecutarlo contra SQLite no probaría nada — de ahí
el marker `mysql`, saltado automáticamente sin `TEST_MYSQL_URL`
(ver conftest.py).

Ejecutar de verdad en la puerta de salida de la Fase 1-A:
    TEST_MYSQL_URL=mysql+pymysql://user:pass@localhost/prime_test pytest -m mysql
"""
from __future__ import annotations

import os

import pytest
from alembic import command
from sqlalchemy import create_engine, text
from sqlalchemy.exc import IntegrityError

from .conftest import make_alembic_config


@pytest.mark.mysql
def test_colacion_email_es_as_cs():
    database_url = os.environ["TEST_MYSQL_URL"]
    cfg = make_alembic_config(database_url)
    command.upgrade(cfg, "head")
    try:
        engine = create_engine(database_url)

        # Confirma la colación declarada en la columna, no solo el
        # comportamiento observado — si alguien la cambia sin querer en
        # una migración futura, este assert falla aunque el insert de
        # abajo por casualidad siga pasando.
        with engine.connect() as conn:
            collation = conn.execute(
                text(
                    "SELECT COLLATION_NAME FROM information_schema.COLUMNS "
                    "WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'users' "
                    "AND COLUMN_NAME = 'email'"
                )
            ).scalar_one()
            assert collation == "utf8mb4_0900_as_cs"

        insert_user = text(
            "INSERT INTO users (role_id, full_name, email, password_hash) "
            "VALUES (1, :name, :email, 'x')"
        )
        with engine.begin() as conn:
            conn.execute(insert_user, {"name": "Jose", "email": "jose@x.com"})
            # Con la colación por defecto de MySQL 8 (utf8mb4_0900_ai_ci,
            # accent-insensitive) este INSERT chocaría con uq_users_email
            # porque 'josé' == 'jose' para esa colación. Con as_cs debe
            # tratarse como una fila distinta.
            conn.execute(insert_user, {"name": "José", "email": "josé@x.com"})

        with engine.connect() as conn:
            count = conn.execute(
                text("SELECT COUNT(*) FROM users WHERE full_name IN ('Jose', 'José')")
            ).scalar_one()
        assert count == 2, (
            "josé@x.com y jose@x.com deben ser identidades distintas para la BD "
            "(directiva anti-enumeración — ver hallazgo HIGH #7, §8.2)"
        )
    except IntegrityError:  # pragma: no cover - solo si la colación regresa a ai_ci
        pytest.fail(
            "el UNIQUE de email colisionó entre 'jose@x.com' y 'josé@x.com': "
            "la columna no está usando utf8mb4_0900_as_cs"
        )
    finally:
        command.downgrade(cfg, "base")
