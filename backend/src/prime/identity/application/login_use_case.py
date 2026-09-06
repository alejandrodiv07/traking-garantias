"""`LoginUseCase` — orquestación del primer factor (Paso 7).

Traduce las políticas puras de dominio (`LockoutPolicy`, `MfaPolicy`) y los
repositorios (Paso 6) al flujo de `AUTH_BLUEPRINT.md` §4.1/§4.4: validar
credenciales, aplicar el backoff anti-fuerza-bruta y, según
`user.mfa_enabled`, emitir sesión directamente o abrir un desafío MFA.

Directiva 4 (anti-enumeración): `LoginResult.outcome` en cualquier fallo es
SIEMPRE "INVALID_CREDENTIALS" — el detalle fino (email inexistente, cuenta
bloqueada, contraseña incorrecta...) se registra en `login_attempts.outcome`
vía `login_attempt_repo`, nunca sale de aquí hacia el cliente.
"""
from __future__ import annotations

import secrets
from dataclasses import dataclass
from datetime import datetime

from prime.identity.domain.lockout_policy import LockoutPolicy
from prime.identity.domain.mfa_policy import MfaPolicy
from prime.identity.domain.value_objects import PlainPassword

# Entropía de los tokens de sesión/CSRF/preauth emitidos aquí. 32 bytes
# codificados en URL-safe base64 — el mismo orden de magnitud que
# `auth_sessions.token_hash`/`mfa_challenges.preauth_hash` (SHA-256, 32
# bytes) están dimensionados para hashear.
_TOKEN_BYTES = 32


def _new_token() -> str:
    return secrets.token_urlsafe(_TOKEN_BYTES)


@dataclass(frozen=True)
class LoginResult:
    outcome: str  # "SESSION_ISSUED" | "MFA_REQUIRED" | "INVALID_CREDENTIALS"
    session_token: str | None = None
    csrf_token: str | None = None
    preauth_token: str | None = None
    error: str | None = None


class LoginUseCase:
    def __init__(
        self,
        *,
        user_repo,
        login_attempt_repo,
        session_repo,
        mfa_challenge_repo,
        password_hasher,
        lockout_policy,
        otp_generator,
        pepper: bytes,
    ):
        self._user_repo = user_repo
        self._login_attempt_repo = login_attempt_repo
        self._session_repo = session_repo
        self._mfa_challenge_repo = mfa_challenge_repo
        self._password_hasher = password_hasher
        self._lockout_policy = lockout_policy
        self._otp_generator = otp_generator
        self._pepper = pepper

    def execute(
        self,
        *,
        email: str,
        password: str,
        now: datetime,
        ip_address: bytes | None = None,
        user_agent_hash: bytes | None = None,
    ) -> LoginResult:
        user = self._user_repo.get_by_email(email)

        if user is None:
            self._record_attempt(
                user_id=None, email=email, ip_address=ip_address,
                user_agent_hash=user_agent_hash, outcome="UNKNOWN_EMAIL",
            )
            return LoginResult(outcome="INVALID_CREDENTIALS")

        if self._lockout_policy.esta_bloqueado(user.locked_until, now):
            self._record_attempt(
                user_id=user.id, email=email, ip_address=ip_address,
                user_agent_hash=user_agent_hash, outcome="ACCOUNT_LOCKED",
            )
            return LoginResult(outcome="INVALID_CREDENTIALS")

        if not user.is_active:
            self._record_attempt(
                user_id=user.id, email=email, ip_address=ip_address,
                user_agent_hash=user_agent_hash, outcome="ACCOUNT_INACTIVE",
            )
            return LoginResult(outcome="INVALID_CREDENTIALS")

        if not self._password_hasher.verify(PlainPassword(password), user.password_hash):
            self._registrar_fallo(user, now)
            self._record_attempt(
                user_id=user.id, email=email, ip_address=ip_address,
                user_agent_hash=user_agent_hash, outcome="BAD_PASSWORD",
            )
            return LoginResult(outcome="INVALID_CREDENTIALS")

        # Contraseña correcta: el paso 1 quedó superado. El contador de
        # fallos NO se resetea todavía si hace falta MFA — solo al superar
        # el segundo factor (`VerifyMfaUseCase`); si no, quien tenga la
        # contraseña reintentaría el OTP indefinidamente sin bloquearse
        # jamás.
        self._record_attempt(
            user_id=user.id, email=email, ip_address=ip_address,
            user_agent_hash=user_agent_hash, outcome="SUCCESS",
        )

        if user.mfa_enabled:
            return self._iniciar_desafio_mfa(user, now, ip_address)

        self._resetear_contador_de_fallos(user)
        return self._emitir_sesion(user, ip_address, user_agent_hash)

    # -- pasos internos -----------------------------------------------------

    def _registrar_fallo(self, user, now: datetime) -> None:
        nuevo_contador = self._lockout_policy.contador_efectivo(
            user.failed_login_count + 1, user.last_failed_login_at, now
        )
        decision = self._lockout_policy.evaluate(
            user.failed_login_count + 1, user.lockout_level, user.last_failed_login_at, now
        )
        user.failed_login_count = nuevo_contador
        user.last_failed_login_at = now
        user.locked_until = decision.locked_until
        user.lockout_level = decision.lockout_level
        self._user_repo.save(user)

    def _resetear_contador_de_fallos(self, user) -> None:
        user.failed_login_count = 0
        user.locked_until = None
        self._user_repo.save(user)

    def _iniciar_desafio_mfa(self, user, now: datetime, ip_address: bytes | None) -> LoginResult:
        code = self._otp_generator.generate()
        preauth_token = _new_token()
        self._mfa_challenge_repo.create(
            user_id=user.id,
            code=code,
            preauth_token=preauth_token,
            expires_at=MfaPolicy.nueva_expiracion(now),
            purpose="LOGIN",
            ip_address=ip_address,
        )
        return LoginResult(outcome="MFA_REQUIRED", preauth_token=preauth_token)

    def _emitir_sesion(self, user, ip_address, user_agent_hash) -> LoginResult:
        token = _new_token()
        csrf_token = _new_token()
        # Los tiempos de expiración concretos (idle/absoluto) son
        # responsabilidad de la capa web (Paso 8, cookies `pt_session`);
        # aquí basta con abrir la sesión con un margen amplio y consistente.
        from datetime import timedelta

        now = datetime.utcnow()
        self._session_repo.create(
            user_id=user.id,
            token=token,
            csrf_token=csrf_token,
            idle_expires_at=now + timedelta(minutes=30),
            absolute_expires_at=now + timedelta(hours=8),
            ip_address=ip_address,
            user_agent_hash=user_agent_hash,
        )
        return LoginResult(outcome="SESSION_ISSUED", session_token=token, csrf_token=csrf_token)

    def _record_attempt(self, *, user_id, email, ip_address, user_agent_hash, outcome) -> None:
        self._login_attempt_repo.record(
            user_id=user_id, email=email, ip_address=ip_address,
            user_agent_hash=user_agent_hash, outcome=outcome,
        )
