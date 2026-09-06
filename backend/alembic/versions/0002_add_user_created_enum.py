"""Anade 'USER_CREATED' a security_event_type_enum (Fase 8).

`RegisterUseCase` emite un evento de §4.6 al dar de alta un usuario, y el
ENUM de 0001 no contempla ese valor: sin esta migracion, el primer alta
contra MySQL 8 falla con "Data truncated for column 'event_type'".

Dos dialectos, dos mecanismos, y conviene entender por que:

- **MySQL** tiene ENUM nativo: un `MODIFY COLUMN` con la lista ampliada
  basta, y anadir el valor al FINAL evita reasignar los ordinales de los
  existentes (que es lo que convierte un ALTER barato en una reescritura
  de tabla con riesgo de remapeo).
- **SQLite** no tiene ENUM: SQLAlchemy lo emite como VARCHAR + CHECK, y
  SQLite no sabe alterar un CHECK. Hay que recrear la tabla, que es lo que
  hace `batch_alter_table`. Se le pasa `copy_from` con la definicion
  EXPLICITA en vez de dejarle reflejar la tabla: la reflexion de CHECK en
  SQLite es textual y arrastraria el constraint viejo a la tabla nueva —
  exactamente el que venimos a sustituir.
"""
from __future__ import annotations

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import mysql

revision = "0002_add_user_created_enum"
down_revision = "0001_initial_identity_schema"
branch_labels = None
depends_on = None

_VALORES_ANTIGUOS = (
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
)
_VALORES_NUEVOS = _VALORES_ANTIGUOS + ("USER_CREATED",)

_ENUM_NAME = "security_event_type_enum"

_UNSIGNED_INT = sa.Integer().with_variant(mysql.INTEGER(unsigned=True), "mysql")
_UNSIGNED_BIGINT = sa.Integer().with_variant(mysql.BIGINT(unsigned=True), "mysql")
_VARBINARY_16 = sa.LargeBinary(16).with_variant(mysql.VARBINARY(16), "mysql")

_MYSQL_TABLE_ARGS = {
    "mysql_engine": "InnoDB",
    "mysql_charset": "utf8mb4",
    "mysql_collate": "utf8mb4_0900_ai_ci",
}


def _enum(valores: tuple[str, ...]) -> sa.Enum:
    return sa.Enum(*valores, name=_ENUM_NAME)


def _security_events(valores: tuple[str, ...]) -> sa.Table:
    """Definicion explicita de la tabla para `copy_from` (ver docstring)."""
    return sa.Table(
        "security_events",
        sa.MetaData(),
        sa.Column("id", _UNSIGNED_BIGINT, primary_key=True, autoincrement=True),
        sa.Column(
            "user_id",
            _UNSIGNED_INT,
            sa.ForeignKey("users.id", ondelete="SET NULL"),
            nullable=True,
        ),
        sa.Column("event_type", _enum(valores), nullable=False),
        sa.Column("detail", sa.JSON(none_as_null=True), nullable=True),
        sa.Column("ip_address", _VARBINARY_16, nullable=True),
        sa.Column(
            "created_at",
            sa.DateTime,
            nullable=False,
            server_default=sa.func.current_timestamp(),
        ),
        sa.Index("idx_sev_user_time", "user_id", "created_at"),
        sa.Index("idx_sev_type_time", "event_type", "created_at"),
        **_MYSQL_TABLE_ARGS,
    )


def _cambiar_enum(desde: tuple[str, ...], hacia: tuple[str, ...]) -> None:
    if op.get_bind().dialect.name == "mysql":
        op.alter_column(
            "security_events",
            "event_type",
            existing_type=mysql.ENUM(*desde),
            type_=mysql.ENUM(*hacia),
            existing_nullable=False,
        )
        return

    with op.batch_alter_table(
        "security_events",
        copy_from=_security_events(desde),
        recreate="always",
    ) as batch_op:
        batch_op.alter_column(
            "event_type",
            existing_type=_enum(desde),
            type_=_enum(hacia),
            existing_nullable=False,
        )


def upgrade() -> None:
    _cambiar_enum(_VALORES_ANTIGUOS, _VALORES_NUEVOS)


def downgrade() -> None:
    # Un ENUM mas estrecho no puede convivir con filas que usan el valor
    # que se retira. Se borran ANTES de estrechar: revertir esta migracion
    # es, por definicion, renunciar a esos eventos de auditoria.
    op.execute(
        sa.text("DELETE FROM security_events WHERE event_type = 'USER_CREATED'")
    )
    _cambiar_enum(_VALORES_NUEVOS, _VALORES_ANTIGUOS)
