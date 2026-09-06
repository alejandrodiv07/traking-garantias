"""
Paso 3 — RED. `LockoutPolicy`: anti-fuerza-bruta, función pura (sin BD, sin Redis).

Contrato (`prime.identity.domain.lockout_policy`):

    LockoutPolicy.evaluate(failed_count, lockout_level, last_failed_at, now) -> LockoutDecision
        LockoutDecision(locked: bool, locked_until: datetime | None, lockout_level: int)

    LockoutPolicy.esta_bloqueado(locked_until, now) -> bool
    LockoutPolicy.nivel_tras_decaimiento(lockout_level, last_failed_at, now) -> int
    LockoutPolicy.contador_efectivo(failed_count, last_failed_at, now) -> int

`evaluate()` es la función que dicta el Blueprint (§6 Paso 3): recibe el
estado tras un fallo recién ocurrido y devuelve Allow (`locked=False`) o
Lock (`locked=True, locked_until=...`). Las otras tres son las piezas que
`evaluate()` compone por dentro — se prueban también sueltas porque cada
una es una regla de negocio independiente y el Blueprint las pide como
puntos separados.

Trazabilidad:
  · Directiva CISO 3 — anti fuerza bruta. §4.1 (`users.lockout_level`).
  · Blueprint §6 Paso 3.

SUPUESTOS DECLARADOS (esta función no tenía todos los números fijados):

  1. **Ventana de conteo = 15 minutos.** El Blueprint solo dice "los fallos
     antiguos no cuentan"; el valor concreto no está en el documento. Tomo
     prestados los 15 min de la cuota "5/15 min por cuenta" (§3.1) por ser
     el único número de este tipo que el propio Blueprint ya usa para el
     mismo propósito — aunque ese es un contador en Redis y este es un
     campo en `users`, son mecanismos distintos. Es una constante; si
     prefieres otro valor, se cambia en un sitio (`VENTANA_CONTEO`).
  2. **Backoff:** 5 → 15 → 60 min, techo duro en el tercer nivel en
     adelante. Esto es la corrección de §4.1, NO el "5 → 15 → 60 → 24 h"
     que aparece en el texto original de §6 Paso 3 — ese escalón de 24 h
     es exactamente el que el propio documento señala como arma de DoS
     regalada al atacante y descarta. Confirmado también en tu mensaje.
  3. **`locked_until` es un límite exclusivo:** bloqueado mientras
     `now < locked_until`; en el instante exacto en que `now == locked_until`
     ya no lo está. Es la lectura natural de "bloqueo de 5 minutos": a los
     5 minutos exactos, termina.
  4. **La decadencia de `lockout_level` se mide en días completos** desde
     `last_failed_at` (parte entera de `(now - last_failed_at) / 24h`), no
     fracciones: a las 23 h 59 min no ha decaído nada todavía.
"""

from datetime import datetime, timedelta

import pytest

from prime.identity.domain.lockout_policy import (
    DURACION_POR_NIVEL,
    DURACION_TECHO,
    UMBRAL_FALLOS,
    VENTANA_CONTEO,
    LockoutPolicy,
)

AHORA = datetime(2026, 9, 5, 12, 0, 0)


# ===========================================================================
# 1. Umbral exacto — evaluate()
# ===========================================================================

def test_por_debajo_del_umbral_no_bloquea():
    decision = LockoutPolicy.evaluate(
        failed_count=UMBRAL_FALLOS - 1,
        lockout_level=0,
        last_failed_at=AHORA - timedelta(minutes=1),
        now=AHORA,
    )
    assert decision.locked is False
    assert decision.locked_until is None


def test_el_quinto_fallo_exacto_dispara_el_bloqueo():
    decision = LockoutPolicy.evaluate(
        failed_count=UMBRAL_FALLOS,
        lockout_level=0,
        last_failed_at=AHORA - timedelta(minutes=1),
        now=AHORA,
    )
    assert decision.locked is True
    assert decision.locked_until == AHORA + DURACION_POR_NIVEL[1]


def test_failed_count_cero_nunca_bloquea():
    decision = LockoutPolicy.evaluate(
        failed_count=0, lockout_level=0, last_failed_at=None, now=AHORA
    )
    assert decision.locked is False


def test_sin_fallos_previos_last_failed_at_none_no_rompe_evaluate():
    # Primer fallo de la vida de la cuenta: no hay last_failed_at todavia.
    decision = LockoutPolicy.evaluate(
        failed_count=1, lockout_level=0, last_failed_at=None, now=AHORA
    )
    assert decision.locked is False


# ===========================================================================
# 2. Backoff acotado — evaluate()
# ===========================================================================

def _fallo_reciente(nivel_entrante: int):
    """5 fallos seguidos, con el nivel de bloqueo que ya traía la cuenta,
    y el ultimo fallo hace 5 min: dentro de la ventana de conteo (15 min,
    no reinicia contador_efectivo) y dentro de la ventana de decadencia
    (24h, no decae el nivel) — aisla el backoff de las otras dos reglas."""
    return LockoutPolicy.evaluate(
        failed_count=UMBRAL_FALLOS,
        lockout_level=nivel_entrante,
        last_failed_at=AHORA - timedelta(minutes=5),
        now=AHORA,
    )


def test_primer_bloqueo_dura_5_minutos():
    decision = _fallo_reciente(nivel_entrante=0)
    assert decision.lockout_level == 1
    assert decision.locked_until == AHORA + timedelta(minutes=5)


def test_segundo_bloqueo_dura_15_minutos():
    decision = _fallo_reciente(nivel_entrante=1)
    assert decision.lockout_level == 2
    assert decision.locked_until == AHORA + timedelta(minutes=15)


def test_tercer_bloqueo_dura_60_minutos():
    decision = _fallo_reciente(nivel_entrante=2)
    assert decision.lockout_level == 3
    assert decision.locked_until == AHORA + timedelta(minutes=60)


def test_cuarto_bloqueo_tambien_dura_60_minutos_techo_duro():
    decision = _fallo_reciente(nivel_entrante=3)
    assert decision.lockout_level == 4
    assert decision.locked_until == AHORA + DURACION_TECHO


def test_el_techo_nunca_escala_a_24_horas():
    # Anti-regresion explicita: el borrador descartado por el Blueprint (§4.1)
    # proponia un escalon de 24h a partir del tercer bloqueo. Un nivel de
    # entrada absurdamente alto NUNCA debe producir esa duracion.
    decision = _fallo_reciente(nivel_entrante=50)
    assert decision.locked_until == AHORA + timedelta(minutes=60)
    assert decision.locked_until != AHORA + timedelta(hours=24)


# ===========================================================================
# 3. Decaimiento del nivel — nivel_tras_decaimiento()
# ===========================================================================

def test_nivel_decae_1_tras_24_horas_sin_fallos():
    nivel = LockoutPolicy.nivel_tras_decaimiento(
        lockout_level=2, last_failed_at=AHORA - timedelta(hours=25), now=AHORA
    )
    assert nivel == 1


def test_nivel_decae_2_tras_48_horas_sin_fallos():
    nivel = LockoutPolicy.nivel_tras_decaimiento(
        lockout_level=3, last_failed_at=AHORA - timedelta(hours=49), now=AHORA
    )
    assert nivel == 1


def test_nivel_no_baja_de_cero():
    nivel = LockoutPolicy.nivel_tras_decaimiento(
        lockout_level=1, last_failed_at=AHORA - timedelta(days=1000), now=AHORA
    )
    assert nivel == 0


def test_nivel_no_decae_antes_de_cumplirse_24_horas_exactas():
    nivel = LockoutPolicy.nivel_tras_decaimiento(
        lockout_level=2,
        last_failed_at=AHORA - timedelta(hours=23, minutes=59, seconds=59),
        now=AHORA,
    )
    assert nivel == 2


def test_nivel_decae_en_el_segundo_exacto_de_las_24_horas():
    nivel = LockoutPolicy.nivel_tras_decaimiento(
        lockout_level=2, last_failed_at=AHORA - timedelta(hours=24), now=AHORA
    )
    assert nivel == 1


def test_sin_fallos_previos_el_nivel_no_decae_por_no_tener_de_donde():
    nivel = LockoutPolicy.nivel_tras_decaimiento(
        lockout_level=0, last_failed_at=None, now=AHORA
    )
    assert nivel == 0


def test_evaluate_devuelve_el_nivel_ya_decaido_aunque_no_bloquee():
    # El nivel decaido se persiste siempre, no solo cuando hay bloqueo nuevo.
    decision = LockoutPolicy.evaluate(
        failed_count=1,
        lockout_level=2,
        last_failed_at=AHORA - timedelta(hours=25),
        now=AHORA,
    )
    assert decision.locked is False
    assert decision.lockout_level == 1


# ===========================================================================
# 4. Ventana deslizante — contador_efectivo()
# ===========================================================================

def test_contador_efectivo_dentro_de_la_ventana_es_el_recibido():
    contador = LockoutPolicy.contador_efectivo(
        failed_count=4, last_failed_at=AHORA - timedelta(minutes=10), now=AHORA
    )
    assert contador == 4


def test_contador_efectivo_en_el_borde_exacto_de_la_ventana_todavia_cuenta():
    contador = LockoutPolicy.contador_efectivo(
        failed_count=4, last_failed_at=AHORA - VENTANA_CONTEO, now=AHORA
    )
    assert contador == 4


def test_contador_efectivo_se_reinicia_fuera_de_la_ventana():
    contador = LockoutPolicy.contador_efectivo(
        failed_count=4,
        last_failed_at=AHORA - VENTANA_CONTEO - timedelta(seconds=1),
        now=AHORA,
    )
    assert contador == 1


def test_contador_efectivo_sin_fallo_previo_es_el_recibido():
    contador = LockoutPolicy.contador_efectivo(
        failed_count=1, last_failed_at=None, now=AHORA
    )
    assert contador == 1


def test_evaluate_no_bloquea_si_el_fallo_previo_fue_hace_dias():
    # El caso de borde que pide el Blueprint literalmente: un contador que
    # se acerca al umbral (4) pero con el ultimo fallo hace dias — los
    # fallos viejos no cuentan, asi que el quinto "fallo" de hoy es en
    # realidad el primero de una racha nueva.
    decision = LockoutPolicy.evaluate(
        failed_count=4, lockout_level=0, last_failed_at=AHORA - timedelta(days=8), now=AHORA
    )
    assert decision.locked is False


# ===========================================================================
# 5. El segundo exacto en que expira el bloqueo — esta_bloqueado()
# ===========================================================================

def test_esta_bloqueado_mientras_no_llegue_locked_until():
    assert LockoutPolicy.esta_bloqueado(
        locked_until=AHORA + timedelta(seconds=1), now=AHORA
    ) is True


def test_deja_de_estar_bloqueado_en_el_instante_exacto_de_locked_until():
    assert LockoutPolicy.esta_bloqueado(locked_until=AHORA, now=AHORA) is False


def test_no_esta_bloqueado_un_segundo_despues_de_locked_until():
    assert LockoutPolicy.esta_bloqueado(
        locked_until=AHORA - timedelta(seconds=1), now=AHORA
    ) is False


def test_no_esta_bloqueado_sin_locked_until():
    assert LockoutPolicy.esta_bloqueado(locked_until=None, now=AHORA) is False
