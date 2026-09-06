"""
Value Object `PlainPassword` (Paso 1, dominio puro).

Contrato: PlainPassword(raw).expose() -> str crudo, byte a byte, sin tocar.
`.expose()` en vez de `.value` es deliberado: leer el secreto tiene que
verse en el diff. Nadie escribe `pwd.expose()` por accidente.

Trazabilidad:
  · Directiva CISO 1 — <= 128 (techo del DoS por Argon2 con entrada gigante).
  · Directiva CISO 2 — no se recorta ni se filtra: cualquier byte se acepta
    y se hashea. Nunca aparece en repr/str.
  · Blueprint §6 Paso 1 — >= 12, sin reglas de composición.
"""

import pytest

from prime.identity.domain.value_objects import PlainPassword

MIN_PASSWORD = 12
MAX_PASSWORD = 128


# ===========================================================================
# Longitud (bordes)
# ===========================================================================

def test_password_de_exactamente_12_es_aceptada():
    assert PlainPassword("a" * MIN_PASSWORD).expose() == "a" * MIN_PASSWORD


def test_password_de_11_es_rechazada():
    with pytest.raises(ValueError):
        PlainPassword("a" * (MIN_PASSWORD - 1))


def test_password_de_exactamente_128_es_aceptada():
    assert len(PlainPassword("a" * MAX_PASSWORD).expose()) == MAX_PASSWORD


def test_password_de_129_es_rechazada_para_cortar_el_dos_por_argon2():
    with pytest.raises(ValueError):
        PlainPassword("a" * (MAX_PASSWORD + 1))


def test_password_gigante_es_rechazada_sin_llegar_a_hashear():
    with pytest.raises(ValueError):
        PlainPassword("a" * 100_000)


def test_password_vacia_es_rechazada():
    with pytest.raises(ValueError):
        PlainPassword("")


@pytest.mark.parametrize("crudo", [None, 123, b"a" * 12, ["a" * 12]])
def test_password_no_string_es_rechazada(crudo):
    with pytest.raises(TypeError):
        PlainPassword(crudo)


# ===========================================================================
# No se toca el contenido
# ===========================================================================

def test_password_no_se_recorta_ni_se_normaliza():
    crudo = "   contrasena con espacios   "
    assert PlainPassword(crudo).expose() == crudo


@pytest.mark.parametrize(
    "crudo",
    [
        "' OR '1'='1' --",          # filtrar comillas debilitaria la clave
        "correct horse battery",
        "contrasena-con-tildes-ñ-á",
        "\t\n\\ raro pero valido",
        "🔐" * MIN_PASSWORD,
        "12345678901234567890",
    ],
)
def test_password_acepta_cualquier_byte_sin_reglas_de_composicion(crudo):
    assert PlainPassword(crudo).expose() == crudo


def test_password_de_solo_minusculas_es_valida():
    # Nada de "una mayuscula y un simbolo": la longitud es lo que importa.
    assert PlainPassword("aaaaaaaaaaaa").expose() == "aaaaaaaaaaaa"


def test_la_longitud_se_mide_sobre_el_crudo_no_sobre_una_version_recortada():
    with pytest.raises(ValueError):
        PlainPassword("  " + "a" * 127)  # 129 caracteres


# ===========================================================================
# No filtra
# ===========================================================================

SECRETO = "SuperSecreta2026!"


def test_el_repr_no_revela_la_contrasena():
    assert SECRETO not in repr(PlainPassword(SECRETO))


def test_el_str_no_revela_la_contrasena():
    assert SECRETO not in str(PlainPassword(SECRETO))


def test_la_interpolacion_en_un_log_no_revela_la_contrasena():
    pwd = PlainPassword(SECRETO)
    assert SECRETO not in f"login fallido: {pwd}"
    assert SECRETO not in f"login fallido: {pwd!r}"
    assert SECRETO not in repr({"password": pwd})


def test_password_es_inmutable():
    pwd = PlainPassword(SECRETO)
    with pytest.raises((AttributeError, TypeError)):
        pwd._value = "otra"
