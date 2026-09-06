"""RED del Paso 7 — `VerifyMfaUseCase`.

Contrato exigido (`prime.identity.application.verify_mfa_use_case`):

    @dataclass(frozen=True)
    class VerifyMfaResult:
        outcome: str  # "SESSION_ISSUED" | "MFA_FAILED" | "MFA_EXHAUSTED"
                      # | "MFA_EXPIRED" | "MFA_ALREADY_CONSUMED"
        session_token: str | None = None
        csrf_token: str | None = None
        error: str | None = None

    class VerifyMfaUseCase:
        def __init__(self, *, mfa_challenge_repo, session_repo, user_repo,
                     login_attempt_repo, security_event_repo, mfa_policy,
                     otp_generator, pepper: bytes): ...
        def execute(self, *, preauth_token: str, code: str, now: datetime,
                    ip_address: bytes | None = None,
                    user_agent_hash: bytes | None = None) -> VerifyMfaResult: ...

La orquestación es una traducción directa de `MfaPolicy.evaluar` (dominio,
Paso 4 — prioridad CONSUMIDO > AGOTADO > EXPIRADO > código incorrecto) a
efectos de persistencia:

- `Motivo.OK`      -> consume el desafío, RESETEA el contador de fallos del
                      usuario (regla del Paso 7: el reseteo ocurre aquí,
                      no en el paso 1 de `LoginUseCase`) y emite la sesión.
- `Motivo.AGOTADO` -> además de `login_attempts.outcome=MFA_FAILED`, emite
                      `security_events.event_type=MFA_EXHAUSTED` (regla 7
                      de §4.4: un agotamiento de MFA es un evento de
                      seguridad de grano grueso, no solo una fila de
                      bitácora).
- Todo motivo distinto de OK deja `session_token is None` — la sesión NUNCA
  nace de un intento fallido, agotado, expirado o repetido.
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone

from prime.identity.application.verify_mfa_use_case import VerifyMfaUseCase

PEPPER = b"test-pepper-not-for-production-0123456789"
PLAINTEXT_CODE = "042931"
PREAUTH_TOKEN = "preauth-cookie-pt_mfa-32-bytes-entropia"


def _now():
    return datetime.now(timezone.utc).replace(tzinfo=None)


def _make_use_case(mfa_challenge_repo, session_repo, user_repo, login_attempt_repo,
                    security_event_repo, mfa_policy, otp_generator):
    return VerifyMfaUseCase(
        mfa_challenge_repo=mfa_challenge_repo,
        session_repo=session_repo,
        user_repo=user_repo,
        login_attempt_repo=login_attempt_repo,
        security_event_repo=security_event_repo,
        mfa_policy=mfa_policy,
        otp_generator=otp_generator,
        pepper=PEPPER,
    )


def _seed_user(user_repo, *, failed_login_count=3, lockout_level=1):
    return user_repo.add(
        role_id=1,
        full_name="Ada Lovelace",
        email="ada@primetelecom.com",
        password_hash="$fake$irrelevante-para-este-caso-de-uso",
        email_verified_at=_now(),
        is_active=True,
        failed_login_count=failed_login_count,
        lockout_level=lockout_level,
    )


def _seed_challenge(mfa_challenge_repo, user_id, *, expires_at=None, attempts=0,
                    consumed=False, code=PLAINTEXT_CODE):
    created = mfa_challenge_repo.create(
        user_id=user_id,
        code=code,
        preauth_token=PREAUTH_TOKEN,
        expires_at=expires_at or (_now() + timedelta(minutes=10)),
    )
    if attempts or consumed:
        created.attempts = attempts
        created.consumed_at = _now() if consumed else None
        mfa_challenge_repo.save(created)
    return created


def test_codigo_correcto_consume_el_desafio_y_promueve_a_sesion_completa(
    mfa_challenge_repo, session_repo, user_repo, login_attempt_repo, security_event_repo,
    mfa_policy, otp_generator,
):
    user = _seed_user(user_repo, failed_login_count=3, lockout_level=1)
    _seed_challenge(mfa_challenge_repo, user.id)
    use_case = _make_use_case(
        mfa_challenge_repo, session_repo, user_repo, login_attempt_repo, security_event_repo,
        mfa_policy, otp_generator,
    )

    result = use_case.execute(preauth_token=PREAUTH_TOKEN, code=PLAINTEXT_CODE, now=_now())

    assert result.outcome == "SESSION_ISSUED"
    assert result.session_token is not None
    assert result.csrf_token is not None

    challenge = mfa_challenge_repo.find_by_preauth_token(PREAUTH_TOKEN)
    assert challenge.consumed_at is not None  # anti-replay: un solo uso

    updated_user = user_repo.get_by_id(user.id)
    assert updated_user.failed_login_count == 0  # el reseteo ocurre AQUÍ

    assert session_repo.count() == 1
    assert session_repo.all()[0].user_id == user.id
    assert login_attempt_repo.outcomes() == ["MFA_SUCCESS"]


def test_reintentos_agotados_no_emite_sesion_y_registra_evento_de_seguridad(
    mfa_challenge_repo, session_repo, user_repo, login_attempt_repo, security_event_repo,
    mfa_policy, otp_generator,
):
    user = _seed_user(user_repo)
    _seed_challenge(mfa_challenge_repo, user.id, attempts=5)  # max_attempts por defecto = 5

    use_case = _make_use_case(
        mfa_challenge_repo, session_repo, user_repo, login_attempt_repo, security_event_repo,
        mfa_policy, otp_generator,
    )

    result = use_case.execute(preauth_token=PREAUTH_TOKEN, code=PLAINTEXT_CODE, now=_now())

    assert result.outcome == "MFA_EXHAUSTED"
    assert result.session_token is None
    assert session_repo.count() == 0

    # Regla 7 del blueprint: un fallo de MFA cuenta como fallo de login.
    updated_user = user_repo.get_by_id(user.id)
    assert updated_user.failed_login_count > 3

    assert "MFA_EXHAUSTED" in security_event_repo.event_types()
    assert login_attempt_repo.outcomes() == ["MFA_FAILED"]


def test_codigo_expirado_es_rechazado_sin_emitir_sesion(
    mfa_challenge_repo, session_repo, user_repo, login_attempt_repo, security_event_repo,
    mfa_policy, otp_generator,
):
    user = _seed_user(user_repo)
    _seed_challenge(
        mfa_challenge_repo, user.id, expires_at=_now() - timedelta(seconds=1)
    )

    use_case = _make_use_case(
        mfa_challenge_repo, session_repo, user_repo, login_attempt_repo, security_event_repo,
        mfa_policy, otp_generator,
    )

    result = use_case.execute(preauth_token=PREAUTH_TOKEN, code=PLAINTEXT_CODE, now=_now())

    assert result.outcome == "MFA_EXPIRED"
    assert result.session_token is None
    assert session_repo.count() == 0
    assert login_attempt_repo.outcomes() == ["MFA_FAILED"]


def test_codigo_ya_consumido_no_se_puede_reutilizar_replay(
    mfa_challenge_repo, session_repo, user_repo, login_attempt_repo, security_event_repo,
    mfa_policy, otp_generator,
):
    user = _seed_user(user_repo)
    _seed_challenge(mfa_challenge_repo, user.id, consumed=True)

    use_case = _make_use_case(
        mfa_challenge_repo, session_repo, user_repo, login_attempt_repo, security_event_repo,
        mfa_policy, otp_generator,
    )

    # Alguien reintenta el mismo código correcto tras ya haberlo usado.
    result = use_case.execute(preauth_token=PREAUTH_TOKEN, code=PLAINTEXT_CODE, now=_now())

    assert result.outcome == "MFA_ALREADY_CONSUMED"
    assert result.session_token is None
    assert session_repo.count() == 0
