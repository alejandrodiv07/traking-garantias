"""`RegisterUseCase` — alta administrativa de usuarios (Fase 8).

`AUTH_BLUEPRINT.md` es explicito: **no hay endpoint de registro publico**.
Los usuarios los crea un ADMIN. Este caso de uso modela ese alta, no un
auto-servicio, y de ahi sus dos rasgos menos obvios:

1. `actor_user_id` — quien da el alta viaja hasta la bitacora. Un alta sin
   autor no es auditable, y un alta administrativa que no se puede auditar
   es una puerta trasera con papeleo.
2. `must_change_password=True` — la contrasena inicial la eligio y conoce
   el administrador. Sobrevivir al primer login la convertiria en una
   credencial compartida.

**Sobre la anti-enumeracion (directiva 4):** aqui NO aplica. Esa directiva
protege un endpoint anonimo de que un atacante descubra que correos
existen. Este flujo esta detras de un ADMIN ya autenticado, y ocultarle
por que fallo el alta solo produciria administradores dandole a "crear"
tres veces. El fallo es explicito; lo que se mantiene es que no crea fila,
no toca la existente y no ensucia la bitacora.

**Sobre la carrera check-then-insert:** `get_by_email()` seguido de `add()`
no es atomico. La barrera real es `uq_users_email` en la base de datos; la
comprobacion previa existe para devolver un resultado limpio en el 99.9%
de los casos, no para garantizar unicidad. La capa web (Fase 9) debe
capturar el `IntegrityError` del commit y traducirlo al MISMO
`EMAIL_ALREADY_REGISTERED` — este modulo no importa SQLAlchemy y no puede
hacerlo por ella.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime

from prime.identity.domain.value_objects import Email, PlainPassword

# Tipo de evento de §4.6. Anadido al ENUM por la migracion 0002 — antes de
# ella, este INSERT falla contra MySQL con un valor invalido.
EVENT_USER_CREATED = "USER_CREATED"

OUTCOME_CREATED = "USER_CREATED"
OUTCOME_DUPLICATE = "EMAIL_ALREADY_REGISTERED"


@dataclass(frozen=True)
class RegisterResult:
    outcome: str  # "USER_CREATED" | "EMAIL_ALREADY_REGISTERED"
    user_id: int | None = None
    error: str | None = None


class RegisterUseCase:
    def __init__(
        self,
        *,
        user_repo,
        security_event_repo,
        password_hasher,
        default_role_id: int = 1,
    ):
        self._user_repo = user_repo
        self._security_event_repo = security_event_repo
        self._password_hasher = password_hasher
        self._default_role_id = default_role_id

    def execute(
        self,
        *,
        full_name: str,
        email: str,
        password: str,
        now: datetime,
        role_id: int | None = None,
        actor_user_id: int | None = None,
        ip_address: bytes | None = None,
    ) -> RegisterResult:
        # Los VO validan y normalizan. Si algo esta mal, levantan ValueError
        # y esta capa lo deja pasar: traducirlo a un 400 con el mensaje
        # adecuado es trabajo de la capa web, que es la unica que sabe que
        # forma tiene una respuesta de error.
        email_vo = Email(email)
        plain = PlainPassword(password)

        nombre = full_name.strip()
        if not nombre:
            raise ValueError("full_name no puede estar vacio")

        rol = role_id if role_id is not None else self._default_role_id

        if self._user_repo.get_by_email(email_vo.value) is not None:
            # Ni fila, ni evento, ni hash: si no hay alta, no hay nada que
            # auditar y no se gastan 100 ms de Argon2 en un camino muerto.
            return RegisterResult(
                outcome=OUTCOME_DUPLICATE,
                error="Ya existe un usuario con ese correo.",
            )

        user = self._user_repo.add(
            role_id=rol,
            full_name=nombre,
            email=email_vo.value,
            password_hash=self._password_hasher.hash(plain),
            # El correo NO se da por verificado: el alta administrativa
            # prueba que un ADMIN lo escribio, no que su dueno lo lea.
            email_verified_at=None,
            must_change_password=True,
        )

        self._security_event_repo.record(
            user_id=user.id,
            event_type=EVENT_USER_CREATED,
            # §4.6: `detail` es contexto forense. Nunca la contrasena, nunca
            # el hash — el correo si, porque ya vive en `users` y sin el la
            # entrada de bitacora es ilegible tras un borrado de cuenta.
            detail={
                "created_by": actor_user_id,
                "role_id": rol,
                "email": email_vo.value,
                "must_change_password": True,
            },
            ip_address=ip_address,
        )

        return RegisterResult(outcome=OUTCOME_CREATED, user_id=user.id)
