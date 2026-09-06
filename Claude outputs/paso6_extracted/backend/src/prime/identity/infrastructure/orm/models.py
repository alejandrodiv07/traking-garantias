"""Mapeo SQLAlchemy del DDL de `AUTH_BLUEPRINT.md` §4.

Un único modelo por tabla, sin capa de compatibilidad ni tipos custom.
Portabilidad SQLite (dev) / MySQL 8 (puerta de salida de fase) resuelta con
las herramientas que SQLAlchemy ya trae:

- `Type().with_variant(mysql.Tipo(...), "mysql")`: en MySQL emite el tipo
  exacto del blueprint (BINARY, VARBINARY, INTEGER UNSIGNED, VARCHAR con
  COLLATE); en cualquier otro dialecto (SQLite en dev) cae al tipo genérico.
  No hace falta un TypeDecorator propio ni dos ficheros de modelos.
- `sa.Enum(*valores, name=...)`: portable de fábrica — ENUM real en MySQL,
  VARCHAR + CHECK en SQLite. Por eso no se usa `mysql.ENUM` directamente.
- `__table_args__ = {"mysql_engine": ..., "mysql_charset": ..., "mysql_collate": ...}`:
  SQLAlchemy ignora los argumentos `mysql_*` en cualquier otro dialecto, así
  que no hace falta ramificar por dialecto para fijar InnoDB/utf8mb4.

Los tipos BINARY/VARBINARY de tamaño fijo se representan con
`sa.LargeBinary(n)` como fallback: SQLite los guarda como BLOB de longitud
variable (no valida el tamaño exacto), lo cual es aceptable en dev porque el
código de aplicación siempre escribe exactamente `n` bytes (UUID de 16,
SHA-256/HMAC de 32). La longitud exacta solo se exige de verdad en MySQL,
que es donde corre `test_colacion_email_es_as_cs` y la puerta de salida de
la fase (`alembic upgrade head` contra MySQL 8 real).
"""
from __future__ import annotations

import uuid
from datetime import datetime

import sqlalchemy as sa
from sqlalchemy.dialects import mysql
from sqlalchemy.orm import Mapped, mapped_column

from prime.identity.infrastructure.orm.base import Base

# ---------------------------------------------------------------------------
# Tipos reutilizados (evita repetir el .with_variant en cada columna)
# ---------------------------------------------------------------------------

UnsignedInt = sa.Integer().with_variant(mysql.INTEGER(unsigned=True), "mysql")
# Base sa.Integer (no sa.BigInteger): SQLite solo trata una PK como alias de
# `rowid` (autoincrement real) cuando el tipo declarado es exactamente
# "INTEGER" — "BIGINT" no cuenta, aunque quepan los mismos valores. En
# MySQL el .with_variant sigue emitiendo BIGINT UNSIGNED real.
UnsignedBigInt = sa.Integer().with_variant(mysql.BIGINT(unsigned=True), "mysql")
UnsignedSmallInt = sa.SmallInteger().with_variant(mysql.SMALLINT(unsigned=True), "mysql")
UnsignedTinyInt = sa.SmallInteger().with_variant(mysql.TINYINT(unsigned=True), "mysql")


def _binary(n: int) -> sa.LargeBinary:
    return sa.LargeBinary(n).with_variant(mysql.BINARY(n), "mysql")


def _varbinary(n: int) -> sa.LargeBinary:
    return sa.LargeBinary(n).with_variant(mysql.VARBINARY(n), "mysql")


def _uuid_bytes() -> bytes:
    return uuid.uuid4().bytes


_MYSQL_TABLE_ARGS = {
    "mysql_engine": "InnoDB",
    "mysql_charset": "utf8mb4",
    "mysql_collate": "utf8mb4_0900_ai_ci",
}


# ---------------------------------------------------------------------------
# roles — mínimo, para no romper la FK de users con errno 150 (RBAC llega
# en una fase posterior; esta tabla la amplía, no la crea).
# ---------------------------------------------------------------------------
class Role(Base):
    __tablename__ = "roles"
    __table_args__ = _MYSQL_TABLE_ARGS

    id: Mapped[int] = mapped_column(UnsignedInt, primary_key=True, autoincrement=True)
    code: Mapped[str] = mapped_column(sa.String(30), nullable=False, unique=True)
    name: Mapped[str] = mapped_column(sa.String(100), nullable=False)


# ---------------------------------------------------------------------------
# users — §4.1
# ---------------------------------------------------------------------------
class User(Base):
    __tablename__ = "users"
    __table_args__ = (
        sa.UniqueConstraint("email", name="uq_users_email"),
        sa.Index("idx_users_locked", "locked_until"),
        _MYSQL_TABLE_ARGS,
    )

    id: Mapped[int] = mapped_column(UnsignedInt, primary_key=True, autoincrement=True)
    role_id: Mapped[int] = mapped_column(
        UnsignedInt, sa.ForeignKey("roles.id"), nullable=False
    )
    full_name: Mapped[str] = mapped_column(sa.String(120), nullable=False)

    # Identificación — COLLATE as_cs solo tiene efecto real en MySQL; en
    # SQLite la comparación de bytes ya es case/accent-sensitive por
    # defecto, así que no hay comportamiento que perder.
    email: Mapped[str] = mapped_column(
        sa.String(160).with_variant(
            mysql.VARCHAR(160, collation="utf8mb4_0900_as_cs"), "mysql"
        ),
        nullable=False,
    )
    email_verified_at: Mapped[datetime | None] = mapped_column(sa.DateTime, nullable=True)

    # Credencial
    password_hash: Mapped[str] = mapped_column(sa.String(255), nullable=False)
    password_algo: Mapped[str] = mapped_column(
        sa.String(30), nullable=False, server_default="argon2id"
    )
    password_updated_at: Mapped[datetime] = mapped_column(
        sa.DateTime, nullable=False, server_default=sa.func.current_timestamp()
    )
    must_change_password: Mapped[bool] = mapped_column(
        sa.Boolean, nullable=False, server_default=sa.false()
    )

    # Anti fuerza bruta — directiva 3
    failed_login_count: Mapped[int] = mapped_column(
        UnsignedSmallInt, nullable=False, server_default="0"
    )
    last_failed_login_at: Mapped[datetime | None] = mapped_column(sa.DateTime, nullable=True)
    locked_until: Mapped[datetime | None] = mapped_column(sa.DateTime, nullable=True)
    lockout_level: Mapped[int] = mapped_column(
        UnsignedTinyInt, nullable=False, server_default="0"
    )
    lockout_level_decays_at: Mapped[datetime | None] = mapped_column(sa.DateTime, nullable=True)

    # Segundo factor — directiva 6
    mfa_enabled: Mapped[bool] = mapped_column(sa.Boolean, nullable=False, server_default=sa.true())
    mfa_method: Mapped[str] = mapped_column(
        sa.Enum("EMAIL_OTP", name="mfa_method_enum"),
        nullable=False,
        server_default="EMAIL_OTP",
    )

    # Ciclo de vida
    is_active: Mapped[bool] = mapped_column(sa.Boolean, nullable=False, server_default=sa.true())
    last_login_at: Mapped[datetime | None] = mapped_column(sa.DateTime, nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        sa.DateTime, nullable=False, server_default=sa.func.current_timestamp()
    )
    updated_at: Mapped[datetime] = mapped_column(
        sa.DateTime,
        nullable=False,
        server_default=sa.func.current_timestamp(),
        onupdate=sa.func.current_timestamp(),
    )


# ---------------------------------------------------------------------------
# auth_sessions — §4.2
# ---------------------------------------------------------------------------
class AuthSession(Base):
    __tablename__ = "auth_sessions"
    __table_args__ = (
        sa.UniqueConstraint("token_hash", name="uq_sess_token"),
        sa.Index("idx_sess_user_live", "user_id", "revoked_at"),
        sa.Index("idx_sess_cleanup", "absolute_expires_at"),
        _MYSQL_TABLE_ARGS,
    )

    id: Mapped[bytes] = mapped_column(_binary(16), primary_key=True, default=_uuid_bytes)
    user_id: Mapped[int] = mapped_column(UnsignedInt, sa.ForeignKey("users.id"), nullable=False)
    token_hash: Mapped[bytes] = mapped_column(_binary(32), nullable=False)
    csrf_hash: Mapped[bytes] = mapped_column(_binary(32), nullable=False)

    issued_at: Mapped[datetime] = mapped_column(
        sa.DateTime, nullable=False, server_default=sa.func.current_timestamp()
    )
    idle_expires_at: Mapped[datetime] = mapped_column(sa.DateTime, nullable=False)
    absolute_expires_at: Mapped[datetime] = mapped_column(sa.DateTime, nullable=False)

    ip_address: Mapped[bytes | None] = mapped_column(_varbinary(16), nullable=True)
    user_agent_hash: Mapped[bytes | None] = mapped_column(_binary(32), nullable=True)
    last_seen_at: Mapped[datetime] = mapped_column(
        sa.DateTime, nullable=False, server_default=sa.func.current_timestamp()
    )

    revoked_at: Mapped[datetime | None] = mapped_column(sa.DateTime, nullable=True)
    revoke_reason: Mapped[str | None] = mapped_column(
        sa.Enum(
            "LOGOUT",
            "PASSWORD_CHANGED",
            "ADMIN_REVOKED",
            "IDLE_TIMEOUT",
            "ABSOLUTE_TIMEOUT",
            "SUSPICIOUS",
            name="revoke_reason_enum",
        ),
        nullable=True,
    )


# ---------------------------------------------------------------------------
# login_attempts — §4.3
# ---------------------------------------------------------------------------
class LoginAttempt(Base):
    __tablename__ = "login_attempts"
    __table_args__ = (
        sa.Index("idx_att_email_time", "email_hmac", "attempted_at"),
        sa.Index("idx_att_ip_time", "ip_address", "attempted_at"),
        sa.Index("idx_att_cleanup", "attempted_at"),
        _MYSQL_TABLE_ARGS,
    )

    id: Mapped[int] = mapped_column(UnsignedBigInt, primary_key=True, autoincrement=True)
    user_id: Mapped[int | None] = mapped_column(
        UnsignedInt, sa.ForeignKey("users.id", ondelete="SET NULL"), nullable=True
    )
    email_hmac: Mapped[bytes] = mapped_column(_binary(32), nullable=False)
    ip_address: Mapped[bytes | None] = mapped_column(_varbinary(16), nullable=True)
    user_agent_hash: Mapped[bytes | None] = mapped_column(_binary(32), nullable=True)
    outcome: Mapped[str] = mapped_column(
        sa.Enum(
            "SUCCESS",
            "BAD_PASSWORD",
            "UNKNOWN_EMAIL",
            "ACCOUNT_LOCKED",
            "ACCOUNT_INACTIVE",
            "EMAIL_UNVERIFIED",
            "MFA_FAILED",
            "MFA_SUCCESS",
            "RATE_LIMITED",
            name="login_outcome_enum",
        ),
        nullable=False,
    )
    attempted_at: Mapped[datetime] = mapped_column(
        sa.DateTime, nullable=False, server_default=sa.func.current_timestamp()
    )


# ---------------------------------------------------------------------------
# mfa_challenges — §4.4
# ---------------------------------------------------------------------------
class MfaChallenge(Base):
    __tablename__ = "mfa_challenges"
    __table_args__ = (
        sa.UniqueConstraint("preauth_hash", name="uq_mfa_preauth"),
        sa.Index("idx_mfa_user_live", "user_id", "consumed_at", "expires_at"),
        sa.Index("idx_mfa_cleanup", "expires_at"),
        _MYSQL_TABLE_ARGS,
    )

    id: Mapped[bytes] = mapped_column(_binary(16), primary_key=True, default=_uuid_bytes)
    user_id: Mapped[int] = mapped_column(
        UnsignedInt, sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False
    )
    code_hmac: Mapped[bytes] = mapped_column(_binary(32), nullable=False)
    purpose: Mapped[str] = mapped_column(
        sa.Enum("LOGIN", "PASSWORD_RESET", "EMAIL_VERIFY", name="mfa_purpose_enum"),
        nullable=False,
        server_default="LOGIN",
    )
    preauth_hash: Mapped[bytes] = mapped_column(_binary(32), nullable=False)
    attempts: Mapped[int] = mapped_column(UnsignedTinyInt, nullable=False, server_default="0")
    max_attempts: Mapped[int] = mapped_column(UnsignedTinyInt, nullable=False, server_default="5")
    resend_count: Mapped[int] = mapped_column(UnsignedTinyInt, nullable=False, server_default="0")
    ip_address: Mapped[bytes | None] = mapped_column(_varbinary(16), nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        sa.DateTime, nullable=False, server_default=sa.func.current_timestamp()
    )
    expires_at: Mapped[datetime] = mapped_column(sa.DateTime, nullable=False)
    consumed_at: Mapped[datetime | None] = mapped_column(sa.DateTime, nullable=True)


# ---------------------------------------------------------------------------
# password_reset_tokens — §4.5
# ---------------------------------------------------------------------------
class PasswordResetToken(Base):
    __tablename__ = "password_reset_tokens"
    __table_args__ = (
        sa.UniqueConstraint("token_hash", name="uq_prt_token"),
        sa.Index("idx_prt_user_live", "user_id", "consumed_at"),
        sa.Index("idx_prt_cleanup", "expires_at"),
        _MYSQL_TABLE_ARGS,
    )

    id: Mapped[bytes] = mapped_column(_binary(16), primary_key=True, default=_uuid_bytes)
    user_id: Mapped[int] = mapped_column(
        UnsignedInt, sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False
    )
    token_hash: Mapped[bytes] = mapped_column(_binary(32), nullable=False)
    requested_ip: Mapped[bytes | None] = mapped_column(_varbinary(16), nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        sa.DateTime, nullable=False, server_default=sa.func.current_timestamp()
    )
    expires_at: Mapped[datetime] = mapped_column(sa.DateTime, nullable=False)
    consumed_at: Mapped[datetime | None] = mapped_column(sa.DateTime, nullable=True)


# ---------------------------------------------------------------------------
# security_events — §4.6
# ---------------------------------------------------------------------------
class SecurityEvent(Base):
    __tablename__ = "security_events"
    __table_args__ = (
        sa.Index("idx_sev_user_time", "user_id", "created_at"),
        sa.Index("idx_sev_type_time", "event_type", "created_at"),
        _MYSQL_TABLE_ARGS,
    )

    id: Mapped[int] = mapped_column(UnsignedBigInt, primary_key=True, autoincrement=True)
    user_id: Mapped[int | None] = mapped_column(
        UnsignedInt, sa.ForeignKey("users.id", ondelete="SET NULL"), nullable=True
    )
    event_type: Mapped[str] = mapped_column(
        sa.Enum(
            "ACCOUNT_LOCKED",
            "ACCOUNT_UNLOCKED",
            "PASSWORD_CHANGED",
            "PASSWORD_RESET_REQUESTED",
            "PASSWORD_RESET_COMPLETED",
            "SESSION_REVOKED",
            "MFA_EXHAUSTED",
            "SUSPICIOUS_SESSION_REUSE",
            "USER_DEACTIVATED",
            "USER_ACTIVATED",
            name="security_event_type_enum",
        ),
        nullable=False,
    )
    # none_as_null=True: sin él, asignar `None` a un JSON de SQLAlchemy
    # guarda el literal JSON 'null' en la fila, no SQL NULL — rompe
    # "WHERE detail IS NULL" y el contrato de este campo (None = sin
    # detalle estructurado).
    detail: Mapped[dict | None] = mapped_column(sa.JSON(none_as_null=True), nullable=True)
    ip_address: Mapped[bytes | None] = mapped_column(_varbinary(16), nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        sa.DateTime, nullable=False, server_default=sa.func.current_timestamp()
    )
