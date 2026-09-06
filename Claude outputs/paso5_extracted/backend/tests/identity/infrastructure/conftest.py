"""Config compartida de los tests de infraestructura.

- `alembic_config`: apunta siempre al `alembic.ini` real del proyecto,
  pero con la URL sustituida por la del test (SQLite en fichero temporal
  para los tests normales; MySQL real solo para los marcados `mysql`).
- El marker `mysql` se salta automáticamente si no hay
  `TEST_MYSQL_URL` en el entorno — así `pytest` sigue en verde en la
  máquina de desarrollo (sin MySQL instalado, §3 del documento de fase) y
  solo se ejecuta de verdad en la puerta de salida de la fase, contra
  MySQL 8 real.
"""
from __future__ import annotations

import os
from pathlib import Path

import pytest
from alembic.config import Config

BACKEND_DIR = Path(__file__).resolve().parents[3]


def pytest_configure(config: pytest.Config) -> None:
    config.addinivalue_line(
        "markers", "mysql: requiere una MySQL 8 real (TEST_MYSQL_URL); no corre en SQLite"
    )


def pytest_collection_modifyitems(config: pytest.Config, items: list[pytest.Item]) -> None:
    if os.environ.get("TEST_MYSQL_URL"):
        return
    skip_mysql = pytest.mark.skip(
        reason="TEST_MYSQL_URL no configurada — este test solo corre contra MySQL 8 real"
    )
    for item in items:
        if "mysql" in item.keywords:
            item.add_marker(skip_mysql)


def make_alembic_config(database_url: str) -> Config:
    cfg = Config(str(BACKEND_DIR / "alembic.ini"))
    cfg.set_main_option("script_location", str(BACKEND_DIR / "alembic"))
    cfg.set_main_option("sqlalchemy.url", database_url)
    os.environ["DATABASE_URL"] = database_url  # env.py también lo lee de aquí
    return cfg


@pytest.fixture
def sqlite_database_url(tmp_path) -> str:
    db_file = tmp_path / "test_identity.db"
    return f"sqlite:///{db_file}"
