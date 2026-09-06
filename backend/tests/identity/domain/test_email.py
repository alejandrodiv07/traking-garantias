"""
Value Object `Email` (Paso 1, dominio puro).

Contrato: Email(raw).value -> str normalizado (strip + lower, acentos intactos).

Trazabilidad:
  · Directiva CISO 1 — formato estricto (corta SQLi/CRLF en el borde), <= 160.
  · Blueprint §6 Paso 1.
"""

import pytest

from prime.identity.domain.value_objects import Email

MAX_EMAIL = 160
DOMINIO = "@primetelecom.com"  # 17 caracteres


# ===========================================================================
# Normalización
# ===========================================================================

def test_email_se_normaliza_a_minusculas_y_sin_espacios():
    assert Email("  Admin@PrimeTelecom.COM ").value == "admin@primetelecom.com"


def test_email_conserva_los_acentos_al_normalizar():
    # La BD compara byte a byte (COLLATE as_cs): jose@ y josé@ son cuentas
    # distintas. La normalización baja la caja, no quita tildes.
    assert Email("José@X.com").value == "josé@x.com"
    assert Email("José@X.com") != Email("jose@x.com")


def test_dos_grafias_de_la_misma_cuenta_son_el_mismo_value_object():
    assert Email("Admin@X.com") == Email("  admin@x.com ")
    assert len({Email("Admin@X.com"), Email("admin@x.com")}) == 1


def test_email_no_es_igual_a_su_string():
    assert Email("admin@x.com") != "admin@x.com"


# ===========================================================================
# Formato
# ===========================================================================

@pytest.mark.parametrize(
    "crudo",
    [
        "no-soy-un-correo",
        "@x.com",
        "admin@",
        "admin@@x.com",
        "admin@x",          # sin TLD
        "admin@.com",
        "admin@x.",
        "admin@x..com",
        ".admin@x.com",
        "admin.@x.com",
        "admin@-x.com",
        "",
        "   ",
    ],
)
def test_email_con_formato_invalido_es_rechazado(crudo):
    with pytest.raises(ValueError):
        Email(crudo)


@pytest.mark.parametrize(
    "payload",
    [
        "admin@x.com' OR '1'='1",
        "admin'--@x.com",
        "admin@x.com; DROP TABLE users",
        "admin@x.com OR 1=1",
        "ad min@x.com",
        "<script>alert(1)</script>@x.com",
        "admin@x.com\nBcc: atacante@evil.com",
        "admin@x.com\r\nX-Inyectado: 1",
        'admin"@x.com',
        "admin@x.com,otro@y.com",
    ],
)
def test_payload_de_inyeccion_no_pasa_la_validacion_de_formato(payload):
    # El VO es la primera barrera: lo que llega al repositorio ya es un email.
    with pytest.raises(ValueError):
        Email(payload)


@pytest.mark.parametrize("crudo", [None, 123, b"admin@x.com", ["admin@x.com"]])
def test_email_no_string_es_rechazado(crudo):
    with pytest.raises(TypeError):
        Email(crudo)


# ===========================================================================
# Longitud (bordes)
# ===========================================================================

def test_email_de_exactamente_160_es_aceptado():
    crudo = "a" * (MAX_EMAIL - len(DOMINIO)) + DOMINIO
    assert len(Email(crudo).value) == MAX_EMAIL


def test_email_de_161_es_rechazado():
    crudo = "a" * (MAX_EMAIL - len(DOMINIO) + 1) + DOMINIO
    with pytest.raises(ValueError):
        Email(crudo)


def test_email_demasiado_largo_es_rechazado():
    with pytest.raises(ValueError):
        Email("a" * 200 + "@x.com")


def test_la_longitud_se_mide_despues_de_recortar_los_espacios():
    crudo = "a" * (MAX_EMAIL - len(DOMINIO)) + DOMINIO
    assert Email("   " + crudo + "   ").value == crudo


# ===========================================================================
# Inmutabilidad
# ===========================================================================

def test_email_es_inmutable():
    correo = Email("admin@x.com")
    with pytest.raises((AttributeError, TypeError)):
        correo.value = "otro@x.com"
