"""`VerifyMfaUseCase` — orquestación del segundo factor (Paso 7).

Traduce `MfaPolicy.evaluar` (dominio, Paso 4 — prioridad CONSUMIDO >
AGOTADO > EXPIRADO > código incorrecto) a efectos de persistencia:

- `Motivo.OK`      -> consume el desafío, RESETEA el contador de fallos del
                      usuario (el reseteo ocurre AQUÍ, no en el paso 1 de
                      `LoginUseCase`) y emite la sesión completa.
- `Motivo.AGOTADO` -> además de `login_attempts.outcome=MFA_FAILED`, emite
                      `security_events.event_type=MFA_EXHAUSTED` (regla 7
                      de §4.4: un agotamiento de MFA es un evento de
                      seguridad de grano grueso) y cuenta como un fallo de
                      login más (mismo backoff que una contraseña
                      incorrecta, vía `LockoutPolicy`).
- Todo motivo distinto de OK deja `session_token is None` — la sesión NUNCA
  nace de un intento fallido, agotado, expirado o repetido.

`LockoutPolicy` se importa directamente (no se inyecta): es un namespace de
funciones puras sin estado, igual que en `login_use_case.py` se importa
`MfaPolicy` directamente para `nueva_expiracion`.
"""
from __future__ import annotations

import secrets
from dataclasses import dataclass
from datetime import datetime, timedelta

from prime.identity.domain.lockout_policy import LockoutPolicy
from prime.identity.domain.mfa_policy import MfaChallenge, Motivo

_TOKEN_BYTES = 32


def _new_token() -> str:
    return secrets.token_urlsafe(_TOKEN_BYTES)


@dataclass(frozen=True)
class VerifyMfaResult:
    outcome: str  # "SESSION_ISSUED" | "MFA_FAILED" | "MFA_EXHAUSTED"
                  # | "MFA_EXPIRED" | "MFA_ALREADY_CONSUMED"
    session_token: str | None = None
    csrf_token: str | None = None
    error: str | None = None


class VerifyMfaUseCase:
    def __init__(
        self,
        *,
        mfa_challenge_repo,
        session_repo,
        user_repo,
        login_attempt_repo,
        security_event_repo,
        mfa_policy,
        otp_generator,
        pepper: bytes,
    ):
        self._mfa_challenge_repo = mfa_challenge_repo
        self._session_repo = session_repo
        self._user_repo = user_repo
        self._login_attempt_repo = login_attempt_repo
        self._security_event_repo = security_event_repo
        self._mfa_policy = mfa_policy
        self._otp_generator = otp_generator
        self._pepper = pepper

    def execute(
        self,
        *,
        preauth_token: str,
        code: str,
        now: datetime,
        ip_address: bytes | None = None,
        user_agent_hash: bytes | None = None,
    ) -> VerifyMfaResult:
        row = self._mfa_challenge_repo.find_by_preauth_token(preauth_token)
        if row is None:
            return VerifyMfaResult(outcome="MFA_FAILED", error="challenge_not_found")

        domain_challenge = MfaChallenge(
            code_hmac=row.code_hmac,
            attempts=row.attempts,
            resend_count=row.resend_count,
            expires_at=row.expires_at,
            consumed_at=row.consumed_at,
        )
        verification = self._mfa_policy.evaluar(domain_challenge, code, self._pepper, now)

        # El desafío se persiste tal cual lo deja la política, sin importar
        # el motivo — `evaluar` ya decide si toca `attempts` o `consumed_at`.
        row.attempts = verification.challenge.attempts
        row.consumed_at = verification.challenge.consumed_at
        self._mfa_challenge_repo.save(row)

        user = self._user_repo.get_by_id(row.user_id)

        if verification.motivo == Motivo.OK:
            self._record_attempt(user.id, ip_address, user_agent_hash, "MFA_SUCCESS")
            self._resetear_contador_de_fallos(user)
            return self._emitir_sesion(user, ip_address, user_agent_hash)

        if verification.motivo == Motivo.AGOTADO:
            self._record_attempt(user.id, ip_address, user_agent_hash, "MFA_FAILED")
            self._security_event_repo.record(
                user_id=user.id, event_type="MFA_EXHAUSTED", detail=None, ip_address=ip_address,
            )
            self._registrar_fallo(user, now)
            return VerifyMfaResult(outcome="MFA_EXHAUSTED")

        if verification.motivo == Motivo.EXPIRADO:
            self._record_attempt(user.id, ip_address, user_agent_hash, "MFA_FAILED")
            return VerifyMfaResult(outcome="MFA_EXPIRED")

        if verification.motivo == Motivo.CONSUMIDO:
            # Replay: el desafío ya se usó en un intento anterior. No es un
            # fallo nuevo de credenciales (esa cuenta ya la abonó el intento
            # original) — no se duplica en login_attempts ni en el backoff.
            return VerifyMfaResult(outcome="MFA_ALREADY_CONSUMED")

        # Motivo.CODIGO_INCORRECTO: intento fallido, pero el desafío sigue
        # vigente (attempts < max) — el usuario puede reintentar.
        self._record_attempt(user.id, ip_address, user_agent_hash, "MFA_FAILED")
        return VerifyMfaResult(outcome="MFA_FAILED")

    # -- pasos internos -----------------------------------------------------

    def _registrar_fallo(self, user, now: datetime) -> None:
        nuevo_contador = LockoutPolicy.contador_efectivo(
            user.failed_login_count + 1, user.last_failed_login_at, now
        )
        decision = LockoutPolicy.evaluate(
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

    def _emitir_sesion(self, user, ip_address, user_agent_hash) -> VerifyMfaResult:
        token = _new_token()
        csrf_token = _new_token()
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
        return VerifyMfaResult(outcome="SESSION_ISSUED", session_token=token, csrf_token=csrf_token)

    def _record_attempt(self, user_id, ip_address, user_agent_hash, outcome: str) -> None:
        user = self._user_repo.get_by_id(user_id)
        self._login_attempt_repo.record(
            user_id=user_id, email=user.email, ip_address=ip_address,
            user_agent_hash=user_agent_hash, outcome=outcome,
        )
