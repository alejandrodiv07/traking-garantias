"""Base declarativa única + engine/session factory.

Un solo `Base.metadata` para todo el paquete `identity`. Alembic (`env.py`)
importa este módulo para descubrir el esquema objetivo — no hay un segundo
mapeo paralelo que mantener sincronizado.

La URL sale de `DATABASE_URL` (definida en `.env`, Paso 0). En desarrollo
apunta a un fichero SQLite; contra MySQL real (puerta de salida de la
Fase 1-A, ver `20260905-auth-fase1a-design.md` §3) apunta a
`mysql+pymysql://...`. El código de dominio y de aplicación no cambia entre
ambos: solo cambia esta variable de entorno.
"""
from __future__ import annotations

import os

from sqlalchemy import create_engine
from sqlalchemy.orm import DeclarativeBase, sessionmaker


class Base(DeclarativeBase):
    pass


def get_engine(database_url: str | None = None):
    url = database_url or os.environ["DATABASE_URL"]
    # ponytail: engine por llamada, sin pool custom — SQLAlchemy ya trae
    # pooling razonable por defecto (QueuePool en MySQL, NullPool-like en
    # SQLite de fichero). Ajustar pool_size solo si el perfil de carga real
    # lo exige.
    connect_args = {"check_same_thread": False} if url.startswith("sqlite") else {}
    return create_engine(url, connect_args=connect_args, future=True)


def get_session_factory(database_url: str | None = None):
    return sessionmaker(bind=get_engine(database_url), future=True, expire_on_commit=False)
