"""
Paso 2 — RED. `PasswordHasher`: puerto + adaptador Argon2id.

Contrato (`prime.identity.domain.password_hasher`):

    PasswordHasher.hash(password: str) -> str
    PasswordHasher.verify(password: str, hashed: str) -> bool
    PasswordHasher.needs_rehash(hashed: str) -> bool

Dos implementaciones bajo el mismo contrato:
  · FakeHasher (tests/support/fakes.py)  — rápida, para el resto de la suite.
  · Argon2PasswordHasher (producción)    — argon2-cffi real, m=64MiB t=3 p=4.

El contrato se corre contra las dos (`test_contrato_*`, parametrizado). El
comportamiento específico de Argon2 (parámetros reales, needs_rehash sobre
parámetros viejos) se prueba solo contra la real y se marca `slow`: en la
máquina de desarrollo cuesta ~100 ms por hash, a propósito (directiva CISO 2).

Trazabilidad:
  · Directiva CISO 2 — Argon2id (argon2-cffi), m=64 MiB, t=3, p=4, salt por
    biblioteca, hmac.compare_digest para timing-safe compare.
  · Blueprint §6 Paso 2.
"""

import pytest

from prime.identity.domain.password_hasher import Argon2PasswordHasher
from tests.support.fakes import FakeHasher

SECRETO = "SuperSecreta2026!"
OTRA = "OtraClaveDistinta9"


def _hashers():
    return [
        pytest.param(FakeHasher(), id="fake"),
        pytest.param(Argon2PasswordHasher(), id="argon2id", marks=pytest.mark.slow),
    ]


# ===========================================================================
# Contrato común — corre contra las dos implementaciones
# ===========================================================================

@pytest.mark.parametrize("hasher", _hashers())
def test_hash_no_contiene_la_clave(hasher):
    assert SECRETO not in hasher.hash(SECRETO)


@pytest.mark.parametrize("hasher", _hashers())
def test_mismo_password_dos_hashes_distintos(hasher):
    # Salt aleatorio por hash: dos usuarios con la misma clave no comparten fila.
    assert hasher.hash(SECRETO) != hasher.hash(SECRETO)


@pytest.mark.parametrize("hasher", _hashers())
def test_verify_acepta_la_contrasena_correcta(hasher):
    assert hasher.verify(SECRETO, hasher.hash(SECRETO)) is True


@pytest.mark.parametrize("hasher", _hashers())
def test_verify_rechaza_la_contrasena_incorrecta(hasher):
    assert hasher.verify(OTRA, hasher.hash(SECRETO)) is False


@pytest.mark.parametrize("hasher", _hashers())
def test_verify_rechaza_un_hash_corrupto_sin_lanzar(hasher):
    assert hasher.verify(SECRETO, "no-soy-un-hash-valido") is False


@pytest.mark.parametrize("hasher", _hashers())
def test_needs_rehash_es_falso_para_un_hash_recien_generado(hasher):
    assert hasher.needs_rehash(hasher.hash(SECRETO)) is False


# ===========================================================================
# Específico de Argon2id (real, lento, marcado)
# ===========================================================================

def test_needs_rehash_de_un_hash_corrupto_es_true():
    # No hace falta marcar `slow`: parsear un formato invalido es instantaneo,
    # el coste de Argon2 solo entra cuando el hash SI es valido.
    hasher = Argon2PasswordHasher()
    assert hasher.needs_rehash("no-soy-un-hash-valido") is True


@pytest.mark.slow
def test_el_hash_real_tiene_formato_phc_argon2id():
    hasher = Argon2PasswordHasher()
    hashed = hasher.hash(SECRETO)
    assert hashed.startswith("$argon2id$v=19$m=65536,t=3,p=4$")


@pytest.mark.slow
def test_needs_rehash_detecta_parametros_viejos():
    # m=8 MiB / t=1 sería un Argon2id válido pero con parámetros por debajo
    # de los vigentes (m=64 MiB, t=3, p=4) — típico tras subir el costo.
    hasher_viejo = Argon2PasswordHasher(memoria_kib=8 * 1024, iteraciones=1, paralelismo=1)
    hasher_vigente = Argon2PasswordHasher()

    hash_viejo = hasher_viejo.hash(SECRETO)

    assert hasher_vigente.verify(SECRETO, hash_viejo) is True
    assert hasher_vigente.needs_rehash(hash_viejo) is True
    assert hasher_vigente.needs_rehash(hasher_vigente.hash(SECRETO)) is False

