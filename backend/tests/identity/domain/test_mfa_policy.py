"""
Paso 4 — RED. `OtpGenerator` y `MfaPolicy`: segundo factor por correo,
función pura (sin BD, sin envío real de correo).

Contrato (`prime.identity.domain.mfa_policy`):

    OtpGenerator.generate() -> str                              # 6 dígitos, ceros a la izquierda
    OtpGenerator.hash(code: str, pepper: bytes) -> bytes         # HMAC-SHA256(code, pepper)
    OtpGenerator.verify(code: str, code_hmac: bytes, pepper: bytes) -> bool

    MfaChallenge(code_hmac, attempts, resend_count, expires_at, consumed_at)
    MfaVerificationResult(accepted, motivo, challenge)           # challenge = estado a persistir
    Motivo.OK | .CODIGO_INCORRECTO | .AGOTADO | .EXPIRADO | .CONSUMIDO

    MfaPolicy.evaluar(challenge, code_ingresado, pepper, now) -> MfaVerificationResult
    MfaPolicy.puede_reenviar(challenge) -> bool
    MfaPolicy.reenviar(challenge, nuevo_code_hmac) -> MfaChallenge
    MfaPolicy.nueva_expiracion(ahora) -> datetime                # ahora + 10 min

No incluyo `max_attempts` / `max_reenvios` como campos del challenge: son
política global (`MAX_INTENTOS=5`, `MAX_REENVIOS=3`), no configuración por
fila. La columna `max_attempts` de la tabla siempre vale 5 en la práctica;
si algún día deja de ser una constante, se añade entonces.

Trazabilidad: directiva CISO 6, Blueprint §4.4 y §6 Paso 4.

DECISIONES DE DISEÑO (fijadas para que el GREEN sea determinista):

  · **Orden de las comprobaciones en `evaluar()`:** CONSUMIDO > AGOTADO >
    EXPIRADO > (código correcto/incorrecto). Un desafío ya usado o ya
    agotado no vuelve a evaluarse aunque además esté vencido — el motivo
    reportado es siempre el primero que aplica, no el más reciente.
  · **`expires_at` es límite exclusivo**, igual que `locked_until` en
    `LockoutPolicy` (mismo criterio en todo el dominio): vigente mientras
    `now < expires_at`.
  · **Agotar por intentos NO marca `consumed_at`.** Son dos mecanismos de
    muerte distintos y así lo dice el propio DDL (§4.4): `consumed_at` es
    anti-replay de un código que SÍ acertó; `attempts` es el límite de
    fuerza bruta. Confundirlos dejaría "reintentar tras agotar" y
    "reintentar tras acertar" indistinguibles en la bitácora.
  · **Un intento contra un desafío ya expirado o agotado no incrementa
    `attempts`.** Ya está muerto; seguir contando no cambia nada y
    ensuciaría la fila.
"""

import hmac
from datetime import datetime, timedelta

import pytest

from prime.identity.domain.mfa_policy import (
    MAX_INTENTOS,
    MAX_REENVIOS,
    TTL,
    MfaChallenge,
    MfaPolicy,
    Motivo,
    OtpGenerator,
)

AHORA = datetime(2026, 9, 5, 12, 0, 0)
PEPPER = b"pepper-de-prueba-no-usar-en-produccion"
CODIGO = "042931"  # el ejemplo del propio Blueprint: los ceros a la izquierda importan


def _challenge(**overrides):
    base = dict(
        code_hmac=OtpGenerator.hash(CODIGO, PEPPER),
        attempts=0,
        resend_count=0,
        expires_at=AHORA + timedelta(minutes=10),
        consumed_at=None,
    )
    base.update(overrides)
    return MfaChallenge(**base)


# ===========================================================================
# 1. Generación — OtpGenerator.generate()
# ===========================================================================

def test_generate_produce_siempre_exactamente_6_caracteres():
    for _ in range(200):
        codigo = OtpGenerator.generate()
        assert len(codigo) == 6
        assert codigo.isdigit()


def test_generate_rellena_con_ceros_a_la_izquierda(monkeypatch):
    monkeypatch.setattr("secrets.randbelow", lambda _: 42)
    assert OtpGenerator.generate() == "000042"


def test_generate_no_trunca_el_valor_maximo(monkeypatch):
    monkeypatch.setattr("secrets.randbelow", lambda _: 999_999)
    assert OtpGenerator.generate() == "999999"


def test_generate_el_valor_minimo_es_seis_ceros(monkeypatch):
    monkeypatch.setattr("secrets.randbelow", lambda _: 0)
    assert OtpGenerator.generate() == "000000"


def test_generate_usa_secrets_randbelow_con_el_rango_de_un_millon(monkeypatch):
    llamadas = []
    monkeypatch.setattr(
        "secrets.randbelow", lambda n: (llamadas.append(n), 0)[1]
    )
    OtpGenerator.generate()
    assert llamadas == [1_000_000]


# ===========================================================================
# 2. Verificación segura — OtpGenerator.hash() / .verify()
# ===========================================================================

def test_hash_es_un_digest_binario_de_32_bytes():
    digest = OtpGenerator.hash(CODIGO, PEPPER)
    assert isinstance(digest, bytes)
    assert len(digest) == 32


def test_verify_acepta_el_codigo_correcto():
    assert OtpGenerator.verify(CODIGO, OtpGenerator.hash(CODIGO, PEPPER), PEPPER) is True


def test_verify_rechaza_el_codigo_incorrecto():
    assert OtpGenerator.verify("999999", OtpGenerator.hash(CODIGO, PEPPER), PEPPER) is False


def test_verify_distingue_el_pepper():
    digest = OtpGenerator.hash(CODIGO, PEPPER)
    assert OtpGenerator.verify(CODIGO, digest, b"otro-pepper") is False


def test_verify_usa_hmac_compare_digest(monkeypatch):
    llamadas = []
    original = hmac.compare_digest

    def espia(a, b):
        llamadas.append((a, b))
        return original(a, b)

    monkeypatch.setattr(hmac, "compare_digest", espia)
    OtpGenerator.verify(CODIGO, OtpGenerator.hash(CODIGO, PEPPER), PEPPER)
    assert llamadas, "verify() debe pasar por hmac.compare_digest, no por '=='"


# ===========================================================================
# 3. Límite de intentos — MfaPolicy.evaluar()
# ===========================================================================

def test_codigo_incorrecto_incrementa_attempts_y_no_consume():
    challenge = _challenge(attempts=2)
    resultado = MfaPolicy.evaluar(challenge, "000000", PEPPER, AHORA)
    assert resultado.accepted is False
    assert resultado.motivo is Motivo.CODIGO_INCORRECTO
    assert resultado.challenge.attempts == 3
    assert resultado.challenge.consumed_at is None


def test_el_intento_numero_5_agota_el_desafio():
    challenge = _challenge(attempts=MAX_INTENTOS - 1)
    resultado = MfaPolicy.evaluar(challenge, "000000", PEPPER, AHORA)
    assert resultado.accepted is False
    assert resultado.motivo is Motivo.AGOTADO
    assert resultado.challenge.attempts == MAX_INTENTOS


def test_un_desafio_ya_agotado_rechaza_incluso_el_codigo_correcto():
    # El desafio murio: ni siquiera se llega a comparar el codigo.
    challenge = _challenge(attempts=MAX_INTENTOS)
    resultado = MfaPolicy.evaluar(challenge, CODIGO, PEPPER, AHORA)
    assert resultado.accepted is False
    assert resultado.motivo is Motivo.AGOTADO
    assert resultado.challenge.attempts == MAX_INTENTOS  # no sigue subiendo


def test_por_debajo_del_limite_el_codigo_correcto_si_se_acepta():
    challenge = _challenge(attempts=MAX_INTENTOS - 1)
    resultado = MfaPolicy.evaluar(challenge, CODIGO, PEPPER, AHORA)
    assert resultado.accepted is True
    assert resultado.motivo is Motivo.OK


# ===========================================================================
# 4. Semántica de reenvío — MfaPolicy.puede_reenviar() / .reenviar()
# ===========================================================================

def test_reenviar_incrementa_resend_count():
    challenge = _challenge(resend_count=0)
    nuevo = MfaPolicy.reenviar(challenge, nuevo_code_hmac=b"x" * 32)
    assert nuevo.resend_count == 1


def test_reenviar_reemplaza_el_code_hmac():
    challenge = _challenge()
    nuevo_hmac = OtpGenerator.hash("777777", PEPPER)
    nuevo = MfaPolicy.reenviar(challenge, nuevo_code_hmac=nuevo_hmac)
    assert nuevo.code_hmac == nuevo_hmac
    assert nuevo.code_hmac != challenge.code_hmac


def test_reenviar_no_extiende_expires_at():
    challenge = _challenge(expires_at=AHORA + timedelta(minutes=3))
    nuevo = MfaPolicy.reenviar(challenge, nuevo_code_hmac=b"x" * 32)
    assert nuevo.expires_at == challenge.expires_at


def test_reenviar_no_resetea_los_intentos_ya_consumidos():
    challenge = _challenge(attempts=3)
    nuevo = MfaPolicy.reenviar(challenge, nuevo_code_hmac=b"x" * 32)
    assert nuevo.attempts == 3


def test_puede_reenviar_es_verdadero_por_debajo_del_tope():
    assert MfaPolicy.puede_reenviar(_challenge(resend_count=MAX_REENVIOS - 1)) is True


def test_puede_reenviar_es_falso_al_llegar_al_tope():
    assert MfaPolicy.puede_reenviar(_challenge(resend_count=MAX_REENVIOS)) is False


def test_reenviar_por_encima_del_tope_es_rechazado():
    challenge = _challenge(resend_count=MAX_REENVIOS)
    with pytest.raises(ValueError):
        MfaPolicy.reenviar(challenge, nuevo_code_hmac=b"x" * 32)


def test_tres_reenvios_seguidos_de_cinco_intentos_serian_20_oportunidades_si_resetearan():
    # Ancla directamente el calculo de riesgo del Blueprint (§4.4 regla 5):
    # si reenviar reseteara `attempts`, 3 reenvios x 5 intentos = 20
    # adivinanzas por contrasena validada, no 5. Lo probamos agotando
    # intentos, reenviando, y confirmando que el desafio sigue agotado.
    challenge = _challenge(attempts=MAX_INTENTOS, resend_count=0)
    challenge = MfaPolicy.reenviar(challenge, nuevo_code_hmac=OtpGenerator.hash("111111", PEPPER))
    resultado = MfaPolicy.evaluar(challenge, "111111", PEPPER, AHORA)
    assert resultado.accepted is False
    assert resultado.motivo is Motivo.AGOTADO


# ===========================================================================
# 5. Anti-replay — consumed_at
# ===========================================================================

def test_verificar_con_exito_marca_consumed_at():
    challenge = _challenge()
    resultado = MfaPolicy.evaluar(challenge, CODIGO, PEPPER, AHORA)
    assert resultado.challenge.consumed_at == AHORA


def test_un_codigo_ya_consumido_nunca_vuelve_a_ser_valido():
    challenge = _challenge(consumed_at=AHORA - timedelta(minutes=1))
    resultado = MfaPolicy.evaluar(challenge, CODIGO, PEPPER, AHORA)
    assert resultado.accepted is False
    assert resultado.motivo is Motivo.CONSUMIDO


def test_consumido_tiene_prioridad_sobre_agotado():
    challenge = _challenge(consumed_at=AHORA - timedelta(minutes=1), attempts=MAX_INTENTOS)
    resultado = MfaPolicy.evaluar(challenge, CODIGO, PEPPER, AHORA)
    assert resultado.motivo is Motivo.CONSUMIDO


def test_agotado_tiene_prioridad_sobre_expirado():
    challenge = _challenge(attempts=MAX_INTENTOS, expires_at=AHORA - timedelta(seconds=1))
    resultado = MfaPolicy.evaluar(challenge, CODIGO, PEPPER, AHORA)
    assert resultado.motivo is Motivo.AGOTADO


# ===========================================================================
# TTL — MfaPolicy.nueva_expiracion() y bordes de expiración en evaluar()
# ===========================================================================

def test_la_nueva_expiracion_es_diez_minutos_despues():
    assert MfaPolicy.nueva_expiracion(AHORA) == AHORA + TTL
    assert TTL == timedelta(minutes=10)


def test_un_desafio_vigente_al_borde_exacto_de_expirar_todavia_es_valido():
    challenge = _challenge(expires_at=AHORA)
    resultado = MfaPolicy.evaluar(challenge, CODIGO, PEPPER, AHORA - timedelta(microseconds=1))
    assert resultado.accepted is True


def test_un_desafio_se_rechaza_en_el_instante_exacto_en_que_expira():
    challenge = _challenge(expires_at=AHORA)
    resultado = MfaPolicy.evaluar(challenge, CODIGO, PEPPER, AHORA)
    assert resultado.accepted is False
    assert resultado.motivo is Motivo.EXPIRADO


def test_un_intento_contra_un_desafio_expirado_no_incrementa_attempts():
    challenge = _challenge(attempts=1, expires_at=AHORA - timedelta(seconds=1))
    resultado = MfaPolicy.evaluar(challenge, "000000", PEPPER, AHORA)
    assert resultado.challenge.attempts == 1
