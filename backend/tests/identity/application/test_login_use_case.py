"""RED del Paso 7 — `LoginUseCase`.

Contrato exigido (`prime.identity.application.login_use_case`):

    @dataclass(frozen=True)
    class LoginResult:
        outcome: str   # "SESSION_ISSUED" | "MFA_REQUIRED" | "INVALID_CREDENTIALS"
        session_token: str | None = None
        csrf_token: str | None = None
        preauth_token: str | None = None
        error: str | None = None

    class LoginUseCase:
        def __init__(self, *, user_repo, login_attempt_repo, session_repo,
                     mfa_challenge_repo, password_hasher, lockout_policy,
                     otp_generator, pepper: bytes): ...
        def execute(self, *, email: str, password: str, now: datetime,
                    ip_address: bytes | None = None,
                    user_agent_hash: bytes | None = None) -> LoginResult: ...

Reglas de `AUTH_BLUEPRINT.md` que este contrato hace cumplir:
- Directiva 4 (anti-enumeración): `LoginResult.outcome` en fallo es
  SIEMPRE "INVALID_CREDENTIALS" — el detalle fino (BAD_PASSWORD,
  ACCOUNT_LOCKED, etc.) vive solo en `login_attempts.outcome`, nunca sale
  del caso de uso hacia el cliente.
- §4.1 / Paso 7: la sesión se emite tras 2FA, o de inmediato si
  `user.mfa_enabled` es False (el esquema lo permite: `mfa_enabled`
  default True, pero no es una constante del sistema).
- §4.4 regla 7 / Paso 3: el contador de fallos se maneja con
  `LockoutPolicy.evaluate`, reutilizada tal cual del dominio — este test
  NO reimplementa el backoff, solo verifica que el caso de uso la invoca y
  persiste su decisión.
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone

from prime.identity.application.login_use_case import LoginUseCase

CORRECT_PASSWORD = "correct-horse-battery-staple"
WRONG_PASSWORD = "wrong-password-not-the-one"
PEPPER = b"test-pepper-not-for-production-0123456789"


def _now():
    return datetime.now(timezone.utc).replace(tzinfo=None)


def _make_use_case(user_repo, login_attempt_repo, session_repo, mfa_challenge_repo,
                    password_hasher, lockout_policy, otp_generator):
    return LoginUseCase(
        user_repo=user_repo,
        login_attempt_repo=login_attempt_repo,
        session_repo=session_repo,
        mfa_challenge_repo=mfa_challenge_repo,
        password_hasher=password_hasher,
        lockout_policy=lockout_policy,
        otp_generator=otp_generator,
        pepper=PEPPER,
    )


def _seed_user(user_repo, password_hasher, *, mfa_enabled=True, failed_login_count=0,
               lockout_level=0, last_failed_login_at=None, email="ada@primetelecom.com"):
    from prime.identity.domain.value_objects import PlainPassword

    return user_repo.add(
        role_id=1,
        full_name="Ada Lovelace",
        email=email,
        password_hash=password_hasher.hash(PlainPassword(CORRECT_PASSWORD)),
        email_verified_at=_now(),
        mfa_enabled=mfa_enabled,
        is_active=True,
        failed_login_count=failed_login_count,
        lockout_level=lockout_level,
        last_failed_login_at=last_failed_login_at,
    )


def test_password_correcta_sin_mfa_emite_sesion_directamente(
    user_repo, login_attempt_repo, session_repo, mfa_challenge_repo, password_hasher,
    lockout_policy, otp_generator,
):
    user = _seed_user(user_repo, password_hasher, mfa_enabled=False)
    use_case = _make_use_case(
        user_repo, login_attempt_repo, session_repo, mfa_challenge_repo, password_hasher,
        lockout_policy, otp_generator,
    )

    result = use_case.execute(email=user.email, password=CORRECT_PASSWORD, now=_now())

    assert result.outcome == "SESSION_ISSUED"
    assert result.session_token is not None
    assert result.csrf_token is not None
    assert result.preauth_token is None
    assert session_repo.count() == 1
    assert session_repo.all()[0].user_id == user.id
    assert mfa_challenge_repo.count() == 0
    assert login_attempt_repo.outcomes() == ["SUCCESS"]


def test_password_incorrecta_incrementa_el_contador_y_registra_el_intento(
    user_repo, login_attempt_repo, session_repo, mfa_challenge_repo, password_hasher,
    lockout_policy, otp_generator,
):
    user = _seed_user(user_repo, password_hasher, failed_login_count=0, lockout_level=0)
    use_case = _make_use_case(
        user_repo, login_attempt_repo, session_repo, mfa_challenge_repo, password_hasher,
        lockout_policy, otp_generator,
    )

    result = use_case.execute(email=user.email, password=WRONG_PASSWORD, now=_now())

    # Directiva 4: el error nunca distingue la causa hacia afuera.
    assert result.outcome == "INVALID_CREDENTIALS"
    assert result.session_token is None
    assert result.preauth_token is None

    updated = user_repo.get_by_id(user.id)
    assert updated.failed_login_count == 1
    assert updated.locked_until is None  # todavía lejos del umbral de 5

    assert login_attempt_repo.count() == 1
    assert login_attempt_repo.outcomes() == ["BAD_PASSWORD"]
    assert session_repo.count() == 0


def test_password_correcta_con_mfa_dispara_desafio_y_preauth_token(
    user_repo, login_attempt_repo, session_repo, mfa_challenge_repo, password_hasher,
    lockout_policy, otp_generator,
):
    user = _seed_user(user_repo, password_hasher, mfa_enabled=True, failed_login_count=3)
    use_case = _make_use_case(
        user_repo, login_attempt_repo, session_repo, mfa_challenge_repo, password_hasher,
        lockout_policy, otp_generator,
    )

    result = use_case.execute(email=user.email, password=CORRECT_PASSWORD, now=_now())

    assert result.outcome == "MFA_REQUIRED"
    assert result.preauth_token is not None
    assert result.session_token is None  # la sesión NO nace hasta superar el 2FA

    assert session_repo.count() == 0

    challenge = mfa_challenge_repo.find_by_preauth_token(result.preauth_token)
    assert challenge is not None
    assert challenge.user_id == user.id
    assert challenge.consumed_at is None
    assert challenge.expires_at > _now()

    # El contador de fallos NO se resetea en el paso 1 — solo al superar
    # el segundo factor (si no, quien tenga la contraseña reintenta el
    # OTP indefinidamente sin que la cuenta se bloquee jamás).
    updated = user_repo.get_by_id(user.id)
    assert updated.failed_login_count == 3


def test_quinto_fallo_bloquea_la_cuenta_inmediatamente(
    user_repo, login_attempt_repo, session_repo, mfa_challenge_repo, password_hasher,
    lockout_policy, otp_generator,
):
    user = _seed_user(
        user_repo, password_hasher, failed_login_count=4, lockout_level=0,
        last_failed_login_at=_now() - timedelta(minutes=1),
    )
    use_case = _make_use_case(
        user_repo, login_attempt_repo, session_repo, mfa_challenge_repo, password_hasher,
        lockout_policy, otp_generator,
    )

    result = use_case.execute(email=user.email, password=WRONG_PASSWORD, now=_now())

    # Mismo error genérico que cualquier otro fallo — el bloqueo no se anuncia.
    assert result.outcome == "INVALID_CREDENTIALS"

    updated = user_repo.get_by_id(user.id)
    assert updated.failed_login_count == 5
    assert updated.locked_until is not None
    assert updated.locked_until > _now()
    assert updated.lockout_level == 1

    assert session_repo.count() == 0
