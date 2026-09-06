"""RED de la Fase 8 — `RegisterUseCase`.

Contrato exigido (`prime.identity.application.register_use_case`):

    @dataclass(frozen=True)
    class RegisterResult:
        outcome: str          # "USER_CREATED" | "EMAIL_ALREADY_REGISTERED"
        user_id: int | None = None
        error: str | None = None

    class RegisterUseCase:
        def __init__(self, *, user_repo, security_event_repo, password_hasher,
                     default_role_id: int = 1): ...
        def execute(self, *, full_name: str, email: str, password: str,
                    now: datetime, role_id: int | None = None,
                    actor_user_id: int | None = None,
                    ip_address: bytes | None = None) -> RegisterResult: ...

Reglas de `AUTH_BLUEPRINT.md` que este contrato hace cumplir:

- **No es auto-servicio.** El blueprint (§ "no existe endpoint de registro
  publico" y la tabla de deuda consciente) dice que los usuarios los crea
  un ADMIN. Por eso `execute()` recibe `actor_user_id` (quien da el alta)
  y por eso el usuario nace con `must_change_password=True`: la contrasena
  inicial la conoce el administrador, luego no puede seguir siendo valida
  despues del primer login.
- **Directiva 4 (anti-enumeracion) NO aplica aqui.** Devolver
  "EMAIL_ALREADY_REGISTERED" seria una fuga si el endpoint fuera publico;
  como esta detras de un ADMIN autenticado, el fallo debe ser explicito y
  limpio (el administrador necesita saber por que no se creo). Lo que si
  se mantiene es que el fallo NO crea fila ni evento.
- **Directiva 2 (Argon2id).** La contrasena se hashea via el puerto
  `password_hasher`; el caso de uso jamas guarda ni registra el claro.
  Aqui corre el `FakePasswordHasher` del conftest (rapido); el Argon2id
  real ya tiene su prueba en `tests/identity/domain/test_password_hasher.py`.
- **§4.6 (bitacora).** El alta emite un `security_events` de tipo
  "USER_CREATED", con `detail` de contexto y sin credenciales.

  OJO GREEN: `security_event_type_enum` (ORM y migracion 0001) NO tiene
  todavia el valor "USER_CREATED". Estos tests pasan con los fakes, pero
  la fase verde necesita una migracion 0002 que anada el valor al ENUM,
  o el primer alta contra MySQL real reventara con un dato invalido.

El email se normaliza con el VO `Email` (strip + lower, Paso 1) — el caso
de uso no reimplementa la normalizacion, la delega, y por eso el test
comprueba el efecto (fila guardada en minusculas) y no el mecanismo.
"""
from __future__ import annotations

from datetime import datetime, timezone

import pytest

from prime.identity.application.register_use_case import RegisterUseCase
from prime.identity.domain.value_objects import PlainPassword

ADMIN_ROLE_ID = 1
ACTOR_ADMIN_ID = 99
NEW_PASSWORD = "alta-inicial-provisional-2026"
NEW_EMAIL = "grace.hopper@primetelecom.com"


def _now():
    return datetime.now(timezone.utc).replace(tzinfo=None)


def _make_use_case(user_repo, security_event_repo, password_hasher):
    return RegisterUseCase(
        user_repo=user_repo,
        security_event_repo=security_event_repo,
        password_hasher=password_hasher,
        default_role_id=ADMIN_ROLE_ID,
    )


def _register(use_case, *, email=NEW_EMAIL, password=NEW_PASSWORD,
              full_name="Grace Hopper", role_id=ADMIN_ROLE_ID):
    return use_case.execute(
        full_name=full_name,
        email=email,
        password=password,
        role_id=role_id,
        actor_user_id=ACTOR_ADMIN_ID,
        now=_now(),
    )


# ---------------------------------------------------------------------------
# Exito
# ---------------------------------------------------------------------------

def test_alta_exitosa_crea_el_usuario_y_devuelve_su_id(
    user_repo, security_event_repo, password_hasher
):
    use_case = _make_use_case(user_repo, security_event_repo, password_hasher)

    result = _register(use_case)

    assert result.outcome == "USER_CREATED"
    assert result.user_id is not None
    assert result.error is None

    creado = user_repo.get_by_id(result.user_id)
    assert creado is not None
    assert creado.full_name == "Grace Hopper"
    assert creado.role_id == ADMIN_ROLE_ID
    assert creado.is_active is True


def test_alta_normaliza_el_correo_antes_de_guardarlo(
    user_repo, security_event_repo, password_hasher
):
    """`Email` recorta y pasa a minusculas; la fila guarda esa forma.

    Importa mas de lo que parece: `users.email` es UNIQUE con collation
    `..._as_cs` (case-sensitive) en MySQL, asi que si el caso de uso
    guardara el crudo, "Grace@..." y "grace@..." convivirian como dos
    cuentas distintas y el login de una de ellas nunca encontraria fila.
    """
    use_case = _make_use_case(user_repo, security_event_repo, password_hasher)

    result = _register(use_case, email="  GRACE.Hopper@PrimeTelecom.COM  ")

    creado = user_repo.get_by_id(result.user_id)
    assert creado.email == NEW_EMAIL
    # Y queda localizable por la forma normalizada, que es como buscara
    # `LoginUseCase`.
    assert user_repo.get_by_email(NEW_EMAIL) is creado


def test_alta_guarda_el_hash_y_nunca_el_claro(
    user_repo, security_event_repo, password_hasher
):
    use_case = _make_use_case(user_repo, security_event_repo, password_hasher)

    result = _register(use_case)
    creado = user_repo.get_by_id(result.user_id)

    assert creado.password_hash != NEW_PASSWORD
    assert NEW_PASSWORD not in creado.password_hash
    # El hash es verificable por el mismo puerto que usara el login.
    assert password_hasher.verify(PlainPassword(NEW_PASSWORD), creado.password_hash) is True
    assert creado.password_algo == "argon2id"


def test_alta_por_admin_obliga_a_cambiar_la_contrasena(
    user_repo, security_event_repo, password_hasher
):
    """La contrasena inicial la conoce quien da el alta: es de un solo uso."""
    use_case = _make_use_case(user_repo, security_event_repo, password_hasher)

    result = _register(use_case)
    creado = user_repo.get_by_id(result.user_id)

    assert creado.must_change_password is True
    # Alta administrativa != correo verificado: la verificacion es un flujo
    # aparte, y darla por hecha aqui saltaria un control.
    assert creado.email_verified_at is None


# ---------------------------------------------------------------------------
# Rechazo
# ---------------------------------------------------------------------------

def test_correo_duplicado_falla_limpiamente_sin_crear_segunda_fila(
    user_repo, security_event_repo, password_hasher
):
    use_case = _make_use_case(user_repo, security_event_repo, password_hasher)
    primero = _register(use_case)

    segundo = use_case.execute(
        full_name="Grace H. Impostora",
        email=NEW_EMAIL,
        password="otra-contrasena-distinta-2026",
        role_id=ADMIN_ROLE_ID,
        actor_user_id=ACTOR_ADMIN_ID,
        now=_now(),
    )

    assert segundo.outcome == "EMAIL_ALREADY_REGISTERED"
    assert segundo.user_id is None
    # No hay segunda fila: el siguiente id sigue libre.
    assert user_repo.get_by_id(primero.user_id + 1) is None
    # Y la fila original queda intacta — un alta duplicada NO es un
    # camino encubierto para reescribir la contrasena de otro.
    original = user_repo.get_by_id(primero.user_id)
    assert original.full_name == "Grace Hopper"
    assert password_hasher.verify(PlainPassword(NEW_PASSWORD), original.password_hash) is True


def test_correo_duplicado_detecta_la_colision_tras_normalizar(
    user_repo, security_event_repo, password_hasher
):
    """La colision se busca sobre el email normalizado, no sobre el crudo."""
    use_case = _make_use_case(user_repo, security_event_repo, password_hasher)
    _register(use_case)

    segundo = _register(use_case, email="  Grace.HOPPER@primetelecom.com  ")

    assert segundo.outcome == "EMAIL_ALREADY_REGISTERED"


def test_correo_duplicado_no_emite_evento_de_cuenta_creada(
    user_repo, security_event_repo, password_hasher
):
    use_case = _make_use_case(user_repo, security_event_repo, password_hasher)
    _register(use_case)
    security_event_repo._rows.clear()  # aisla el evento del alta valida

    _register(use_case)

    assert security_event_repo.event_types() == []


@pytest.mark.parametrize(
    "email_invalido",
    ["sin-arroba", "espacio en@primetelecom.com", "grace@sin_tld", ""],
)
def test_correo_invalido_lo_rechaza_el_value_object(
    user_repo, security_event_repo, password_hasher, email_invalido
):
    """El caso de uso no revalida: deja que `Email` levante ValueError.

    Traducir esa excepcion a un 400 es trabajo de la Fase 9 (capa web),
    no de la capa de aplicacion.
    """
    use_case = _make_use_case(user_repo, security_event_repo, password_hasher)

    with pytest.raises(ValueError):
        _register(use_case, email=email_invalido)

    assert user_repo.get_by_email(email_invalido.strip().lower()) is None


def test_contrasena_corta_la_rechaza_el_value_object(
    user_repo, security_event_repo, password_hasher
):
    use_case = _make_use_case(user_repo, security_event_repo, password_hasher)

    with pytest.raises(ValueError):
        _register(use_case, password="corta")

    assert user_repo.get_by_email(NEW_EMAIL) is None
    assert security_event_repo.event_types() == []


# ---------------------------------------------------------------------------
# Auditoria (§4.6)
# ---------------------------------------------------------------------------

def test_alta_exitosa_registra_el_evento_de_seguridad(
    user_repo, security_event_repo, password_hasher
):
    use_case = _make_use_case(user_repo, security_event_repo, password_hasher)

    result = _register(use_case)

    assert security_event_repo.event_types() == ["USER_CREATED"]
    evento = security_event_repo._rows[0]
    assert evento.user_id == result.user_id


def test_el_evento_no_filtra_credenciales_y_deja_rastro_del_actor(
    user_repo, security_event_repo, password_hasher
):
    """`detail` es contexto forense, no un vertedero: nunca la contrasena
    ni el hash (§4.6). Si guarda quien dio el alta, que es justo el dato
    que hace auditable un alta administrativa."""
    use_case = _make_use_case(user_repo, security_event_repo, password_hasher)

    result = _register(use_case)
    evento = security_event_repo._rows[0]

    assert evento.detail is not None
    serializado = repr(evento.detail)
    assert NEW_PASSWORD not in serializado
    assert user_repo.get_by_id(result.user_id).password_hash not in serializado

    assert evento.detail.get("created_by") == ACTOR_ADMIN_ID
    assert evento.detail.get("role_id") == ADMIN_ROLE_ID
