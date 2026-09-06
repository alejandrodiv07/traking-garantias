"""initial identity schema

Revision ID: 0001_initial_identity_schema
Revises:
Create Date: 2026-09-05

Crea las 7 tablas de `AUTH_BLUEPRINT.md` §4 (`roles` mínimo + las 6 de
seguridad) y siembra la fila `roles.code='ADMIN'` en la MISMA migración,
antes de que exista ningún `users.role_id` que la necesite. Sin esta
semilla, la migración inicial contra una base vacía falla en la primera
sentencia (`errno 150`, ver hallazgo CRÍTICO #1 de la auditoría, §8.2).

Este fichero es lo que produce `alembic revision --autogenerate -m
"initial identity schema"` a partir de
`prime.identity.infrastructure.orm.models`, con un único añadido manual:
el `op.bulk_insert` de la fila ADMIN (autogenerate nunca genera datos,
solo estructura). Regenerar con autogenerate y volver a pegar ese insert
si los modelos cambian.
"""
from __future__ import annotations

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import mysql

# revision identifiers, used by Alembic.
revision: str = "0001_initial_identity_schema"
down_revision: Union[str, None] = None
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

# --- mismos alias de tipo que en models.py --------------------------------
_UNSIGNED_INT = sa.Integer().with_variant(mysql.INTEGER(unsigned=True), "mysql")
_UNSIGNED_BIGINT = sa.BigInteger().with_variant(mysql.BIGINT(unsigned=True), "mysql")
_UNSIGNED_SMALLINT = sa.SmallInteger().with_variant(mysql.SMALLINT(unsigned=True), "mysql")
_UNSIGNED_TINYINT = sa.SmallInteger().with_variant(mysql.TINYINT(unsigned=True), "mysql")

_MYSQL_TABLE_ARGS = dict(
    mysql_engine="InnoDB", mysql_charset="utf8mb4", mysql_collate="utf8mb4_0900_ai_ci"
)


def _binary(n: int) -> sa.LargeBinary:
    return sa.LargeBinary(n).with_variant(mysql.BINARY(n), "mysql")


def _varbinary(n: int) -> sa.LargeBinary:
    return sa.LargeBinary(n).with_variant(mysql.VARBINARY(n), "mysql")


def upgrade() -> None:
    # ---- roles (mínimo, RBAC llega en fase posterior) --------------------
    roles = op.create_table(
        "roles",
        sa.Column("id", _UNSIGNED_INT, primary_key=True, autoincrement=True),
        sa.Column("code", sa.String(30), nullable=False),
        sa.Column("name", sa.String(100), nullable=False),
        sa.UniqueConstraint("code", name="uq_roles_code"),
        **_MYSQL_TABLE_ARGS,
    )
    # Semilla obligatoria: sin ella el primer INSERT en `users` (Paso 5-bis,
    # `flask auth seed-admin`) no tiene un role_id válido que referenciar.
    op.bulk_insert(roles, [{"id": 1, "code": "ADMIN", "name": "Administrador"}])

    # ---- users -------------------------------------------------------------
    op.create_table(
        "users",
        sa.Column("id", _UNSIGNED_INT, primary_key=True, autoincrement=True),
        sa.Column("role_id", _UNSIGNED_INT, sa.ForeignKey("roles.id"), nullable=False),
        sa.Column("full_name", sa.String(120), nullable=False),
        sa.Column(
            "email",
            sa.String(160).with_variant(
                mysql.VARCHAR(160, collation="utf8mb4_0900_as_cs"), "mysql"
            ),
            nullable=False,
        ),
        sa.Column("email_verified_at", sa.DateTime, nullable=True),
        sa.Column("password_hash", sa.String(255), nullable=False),
        sa.Column("password_algo", sa.String(30), nullable=False, server_default="argon2id"),
        sa.Column(
            "password_updated_at",
            sa.DateTime,
            nullable=False,
            server_default=sa.func.current_timestamp(),
        ),
        sa.Column("must_change_password", sa.Boolean, nullable=False, server_default=sa.false()),
        sa.Column("failed_login_count", _UNSIGNED_SMALLINT, nullable=False, server_default="0"),
        sa.Column("last_failed_login_at", sa.DateTime, nullable=True),
        sa.Column("locked_until", sa.DateTime, nullable=True),
        sa.Column("lockout_level", _UNSIGNED_TINYINT, nullable=False, server_default="0"),
        sa.Column("lockout_level_decays_at", sa.DateTime, nullable=True),
        sa.Column("mfa_enabled", sa.Boolean, nullable=False, server_default=sa.true()),
        sa.Column(
            "mfa_method",
            sa.Enum("EMAIL_OTP", name="mfa_method_enum"),
            nullable=False,
            server_default="EMAIL_OTP",
        ),
        sa.Column("is_active", sa.Boolean, nullable=False, server_default=sa.true()),
        sa.Column("last_login_at", sa.DateTime, nullable=True),
        sa.Column(
            "created_at", sa.DateTime, nullable=False, server_default=sa.func.current_timestamp()
        ),
        sa.Column(
            "updated_at",
            sa.DateTime,
            nullable=False,
            server_default=sa.func.current_timestamp(),
            onupdate=sa.func.current_timestamp(),
        ),
        sa.UniqueConstraint("email", name="uq_users_email"),
        **_MYSQL_TABLE_ARGS,
    )
    op.create_index("idx_users_locked", "users", ["locked_until"])

    # ---- auth_sessions -------------------------------------------------------
    op.create_table(
        "auth_sessions",
        sa.Column("id", _binary(16), primary_key=True),
        sa.Column("user_id", _UNSIGNED_INT, sa.ForeignKey("users.id"), nullable=False),
        sa.Column("token_hash", _binary(32), nullable=False),
        sa.Column("csrf_hash", _binary(32), nullable=False),
        sa.Column(
            "issued_at", sa.DateTime, nullable=False, server_default=sa.func.current_timestamp()
        ),
        sa.Column("idle_expires_at", sa.DateTime, nullable=False),
        sa.Column("absolute_expires_at", sa.DateTime, nullable=False),
        sa.Column("ip_address", _varbinary(16), nullable=True),
        sa.Column("user_agent_hash", _binary(32), nullable=True),
        sa.Column(
            "last_seen_at", sa.DateTime, nullable=False, server_default=sa.func.current_timestamp()
        ),
        sa.Column("revoked_at", sa.DateTime, nullable=True),
        sa.Column(
            "revoke_reason",
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
        ),
        sa.UniqueConstraint("token_hash", name="uq_sess_token"),
        **_MYSQL_TABLE_ARGS,
    )
    op.create_index("idx_sess_user_live", "auth_sessions", ["user_id", "revoked_at"])
    op.create_index("idx_sess_cleanup", "auth_sessions", ["absolute_expires_at"])

    # ---- login_attempts --------------------------------------------------
    op.create_table(
        "login_attempts",
        sa.Column("id", _UNSIGNED_BIGINT, primary_key=True, autoincrement=True),
        sa.Column(
            "user_id",
            _UNSIGNED_INT,
            sa.ForeignKey("users.id", ondelete="SET NULL"),
            nullable=True,
        ),
        sa.Column("email_hmac", _binary(32), nullable=False),
        sa.Column("ip_address", _varbinary(16), nullable=True),
        sa.Column("user_agent_hash", _binary(32), nullable=True),
        sa.Column(
            "outcome",
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
        ),
        sa.Column(
            "attempted_at",
            sa.DateTime,
            nullable=False,
            server_default=sa.func.current_timestamp(),
        ),
        **_MYSQL_TABLE_ARGS,
    )
    op.create_index("idx_att_email_time", "login_attempts", ["email_hmac", "attempted_at"])
    op.create_index("idx_att_ip_time", "login_attempts", ["ip_address", "attempted_at"])
    op.create_index("idx_att_cleanup", "login_attempts", ["attempted_at"])

    # ---- mfa_challenges ----------------------------------------------------
    op.create_table(
        "mfa_challenges",
        sa.Column("id", _binary(16), primary_key=True),
        sa.Column(
            "user_id",
            _UNSIGNED_INT,
            sa.ForeignKey("users.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("code_hmac", _binary(32), nullable=False),
        sa.Column(
            "purpose",
            sa.Enum("LOGIN", "PASSWORD_RESET", "EMAIL_VERIFY", name="mfa_purpose_enum"),
            nullable=False,
            server_default="LOGIN",
        ),
        sa.Column("preauth_hash", _binary(32), nullable=False),
        sa.Column("attempts", _UNSIGNED_TINYINT, nullable=False, server_default="0"),
        sa.Column("max_attempts", _UNSIGNED_TINYINT, nullable=False, server_default="5"),
        sa.Column("resend_count", _UNSIGNED_TINYINT, nullable=False, server_default="0"),
        sa.Column("ip_address", _varbinary(16), nullable=True),
        sa.Column(
            "created_at",
            sa.DateTime,
            nullable=False,
            server_default=sa.func.current_timestamp(),
        ),
        sa.Column("expires_at", sa.DateTime, nullable=False),
        sa.Column("consumed_at", sa.DateTime, nullable=True),
        sa.UniqueConstraint("preauth_hash", name="uq_mfa_preauth"),
        **_MYSQL_TABLE_ARGS,
    )
    op.create_index(
        "idx_mfa_user_live", "mfa_challenges", ["user_id", "consumed_at", "expires_at"]
    )
    op.create_index("idx_mfa_cleanup", "mfa_challenges", ["expires_at"])

    # ---- password_reset_tokens ---------------------------------------------
    op.create_table(
        "password_reset_tokens",
        sa.Column("id", _binary(16), primary_key=True),
        sa.Column(
            "user_id",
            _UNSIGNED_INT,
            sa.ForeignKey("users.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("token_hash", _binary(32), nullable=False),
        sa.Column("requested_ip", _varbinary(16), nullable=True),
        sa.Column(
            "created_at",
            sa.DateTime,
            nullable=False,
            server_default=sa.func.current_timestamp(),
        ),
        sa.Column("expires_at", sa.DateTime, nullable=False),
        sa.Column("consumed_at", sa.DateTime, nullable=True),
        sa.UniqueConstraint("token_hash", name="uq_prt_token"),
        **_MYSQL_TABLE_ARGS,
    )
    op.create_index("idx_prt_user_live", "password_reset_tokens", ["user_id", "consumed_at"])
    op.create_index("idx_prt_cleanup", "password_reset_tokens", ["expires_at"])

    # ---- security_events -----------------------------------------------------
    op.create_table(
        "security_events",
        sa.Column("id", _UNSIGNED_BIGINT, primary_key=True, autoincrement=True),
        sa.Column(
            "user_id",
            _UNSIGNED_INT,
            sa.ForeignKey("users.id", ondelete="SET NULL"),
            nullable=True,
        ),
        sa.Column(
            "event_type",
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
        ),
        sa.Column("detail", sa.JSON, nullable=True),
        sa.Column("ip_address", _varbinary(16), nullable=True),
        sa.Column(
            "created_at",
            sa.DateTime,
            nullable=False,
            server_default=sa.func.current_timestamp(),
        ),
        **_MYSQL_TABLE_ARGS,
    )
    op.create_index("idx_sev_user_time", "security_events", ["user_id", "created_at"])
    op.create_index("idx_sev_type_time", "security_events", ["event_type", "created_at"])


def downgrade() -> None:
    # Orden inverso al de creación por las FKs.
    op.drop_table("security_events")
    op.drop_table("password_reset_tokens")
    op.drop_table("mfa_challenges")
    op.drop_table("login_attempts")
    op.drop_table("auth_sessions")
    op.drop_table("users")
    op.drop_table("roles")
