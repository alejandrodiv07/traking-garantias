"""
`LockoutPolicy` — anti-fuerza-bruta, función pura (Paso 3).

Sin BD, sin Redis: recibe el estado que ya vive en la fila `users` (§4.1) y
`now`, y devuelve una decisión. El repositorio (Paso 6) es quien persiste
lo que esta política calcula; aquí no se toca nada fuera de la memoria.

Trazabilidad: directiva CISO 3, Blueprint §6 Paso 3 y §4.1 (backoff
acotado — corrige el escalón de 24h del borrador original).

Supuestos declarados y aprobados (ver docstring de
tests/identity/domain/test_lockout_policy.py):
  · Ventana de conteo = 15 min (mismo valor que la cuota "5/15 min por
    cuenta" de rate limiting, §3.1 — mecanismo distinto, mismo número).
  · `locked_until` es límite exclusivo: bloqueado mientras `now < locked_until`,
    coincide con `locked_until < NOW()` del propio Blueprint.
  · La decadencia de `lockout_level` se mide en días completos transcurridos.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta

UMBRAL_FALLOS = 5
VENTANA_CONTEO = timedelta(minutes=15)
VENTANA_DECAY = timedelta(hours=24)

# Backoff acotado (§4.1): 1er bloqueo 5 min, 2º 15 min, 3º en adelante 60 min
# fijo. Nunca 24h — ese escalón es el arma de DoS que el Blueprint descarta.
DURACION_POR_NIVEL = {1: timedelta(minutes=5), 2: timedelta(minutes=15)}
DURACION_TECHO = timedelta(minutes=60)


def _duracion_para_nivel(nivel: int) -> timedelta:
    return DURACION_POR_NIVEL.get(nivel, DURACION_TECHO)


@dataclass(frozen=True, slots=True)
class LockoutDecision:
    locked: bool
    locked_until: datetime | None
    lockout_level: int


class LockoutPolicy:
    """Namespace de funciones puras; sin estado, sin instancias."""

    @staticmethod
    def esta_bloqueado(locked_until: datetime | None, now: datetime) -> bool:
        if locked_until is None:
            return False
        return now < locked_until

    @staticmethod
    def nivel_tras_decaimiento(
        lockout_level: int, last_failed_at: datetime | None, now: datetime
    ) -> int:
        if last_failed_at is None or lockout_level <= 0:
            return max(lockout_level, 0)

        dias_transcurridos = (now - last_failed_at) // VENTANA_DECAY
        return max(lockout_level - dias_transcurridos, 0)

    @staticmethod
    def contador_efectivo(
        failed_count: int, last_failed_at: datetime | None, now: datetime
    ) -> int:
        if last_failed_at is None:
            return failed_count

        # Fuera de la ventana: los fallos viejos no cuentan. El fallo que
        # acaba de ocurrir (el que motiva esta llamada) es el primero de
        # una racha nueva.
        if now - last_failed_at > VENTANA_CONTEO:
            return 1

        return failed_count

    @staticmethod
    def evaluate(
        failed_count: int,
        lockout_level: int,
        last_failed_at: datetime | None,
        now: datetime,
    ) -> LockoutDecision:
        nivel_decaido = LockoutPolicy.nivel_tras_decaimiento(
            lockout_level, last_failed_at, now
        )
        contador = LockoutPolicy.contador_efectivo(failed_count, last_failed_at, now)

        if contador < UMBRAL_FALLOS:
            return LockoutDecision(locked=False, locked_until=None, lockout_level=nivel_decaido)

        nuevo_nivel = nivel_decaido + 1
        return LockoutDecision(
            locked=True,
            locked_until=now + _duracion_para_nivel(nuevo_nivel),
            lockout_level=nuevo_nivel,
        )
