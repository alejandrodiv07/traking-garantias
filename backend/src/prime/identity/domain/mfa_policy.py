"""
`OtpGenerator` y `MfaPolicy` — segundo factor por correo (Paso 4).

Función pura: sin BD, sin envío de correo. El repositorio (Paso 6) traduce
`MfaChallenge` desde/hacia la fila de `mfa_challenges`; `LoginUseCase` y
`VerifyMfaUseCase` (Paso 7) son quienes generan el código, lo envían por
correo y persisten el `MfaChallenge` que esta política devuelve.

Trazabilidad: directiva CISO 6, Blueprint §4.4 y §6 Paso 4.
"""

from __future__ import annotations

import hmac
import secrets
from dataclasses import dataclass, replace
from datetime import datetime, timedelta
from enum import Enum

MAX_INTENTOS = 5
MAX_REENVIOS = 3
TTL = timedelta(minutes=10)


class Motivo(str, Enum):
    OK = "OK"
    CODIGO_INCORRECTO = "CODIGO_INCORRECTO"
    AGOTADO = "AGOTADO"
    EXPIRADO = "EXPIRADO"
    CONSUMIDO = "CONSUMIDO"


class OtpGenerator:
    @staticmethod
    def generate() -> str:
        # secrets.randbelow(1_000_000) da un entero en [0, 999999]. Sin el
        # formateo a ancho fijo, "042931" se convertiría en "42931" y se
        # perdería un dígito de entropía real (10^6 -> ~9*10^5 aparentes).
        return f"{secrets.randbelow(1_000_000):06d}"

    @staticmethod
    def hash(code: str, pepper: bytes) -> bytes:
        return hmac.new(pepper, code.encode(), "sha256").digest()

    @staticmethod
    def verify(code: str, code_hmac: bytes, pepper: bytes) -> bool:
        return hmac.compare_digest(OtpGenerator.hash(code, pepper), code_hmac)


@dataclass(frozen=True, slots=True)
class MfaChallenge:
    code_hmac: bytes
    attempts: int
    resend_count: int
    expires_at: datetime
    consumed_at: datetime | None


@dataclass(frozen=True, slots=True)
class MfaVerificationResult:
    accepted: bool
    motivo: Motivo
    challenge: MfaChallenge  # estado ya actualizado, listo para que el repo lo persista


class MfaPolicy:
    """Namespace de funciones puras; sin estado, sin instancias."""

    @staticmethod
    def evaluar(
        challenge: MfaChallenge, code_ingresado: str, pepper: bytes, now: datetime
    ) -> MfaVerificationResult:
        # Orden fijo: CONSUMIDO > AGOTADO > EXPIRADO > código. Un desafío
        # muerto no se reevalúa por otra causa distinta a la que lo mató.
        if challenge.consumed_at is not None:
            return MfaVerificationResult(False, Motivo.CONSUMIDO, challenge)

        if challenge.attempts >= MAX_INTENTOS:
            return MfaVerificationResult(False, Motivo.AGOTADO, challenge)

        if now >= challenge.expires_at:
            return MfaVerificationResult(False, Motivo.EXPIRADO, challenge)

        if OtpGenerator.verify(code_ingresado, challenge.code_hmac, pepper):
            consumido = replace(challenge, consumed_at=now)
            return MfaVerificationResult(True, Motivo.OK, consumido)

        nuevos_intentos = challenge.attempts + 1
        motivo = Motivo.AGOTADO if nuevos_intentos >= MAX_INTENTOS else Motivo.CODIGO_INCORRECTO
        agotado = replace(challenge, attempts=nuevos_intentos)
        return MfaVerificationResult(False, motivo, agotado)

    @staticmethod
    def puede_reenviar(challenge: MfaChallenge) -> bool:
        return challenge.resend_count < MAX_REENVIOS

    @staticmethod
    def reenviar(challenge: MfaChallenge, nuevo_code_hmac: bytes) -> MfaChallenge:
        if not MfaPolicy.puede_reenviar(challenge):
            raise ValueError(f"máximo {MAX_REENVIOS} reenvíos por desafío")

        # Solo cambian code_hmac y resend_count. expires_at y attempts se
        # dejan intactos a propósito (Blueprint §4.4 regla 5): si el reenvío
        # extendiera el TTL o reseteara los intentos, 3 reenvíos x 5 intentos
        # darían 20 adivinanzas por contraseña validada, no 5.
        return replace(
            challenge,
            code_hmac=nuevo_code_hmac,
            resend_count=challenge.resend_count + 1,
        )

    @staticmethod
    def nueva_expiracion(ahora: datetime) -> datetime:
        return ahora + TTL
