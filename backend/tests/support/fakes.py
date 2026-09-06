"""
Test doubles reutilizables entre pasos (Paso 2 en adelante).

`FakeHasher` implementa el mismo contrato que `PasswordHasher` con una
operación trivial y determinista (SHA-256 + "salt" en claro concatenada).
Es criptográficamente inútil a propósito: solo sirve para que los tests de
casos de uso (Paso 7) no paguen el coste real de Argon2 (~100 ms) en cada
assert. El adaptador real se prueba una sola vez, en test_password_hasher.py,
marcado @pytest.mark.slow.
"""

from __future__ import annotations

import hashlib
import secrets


class FakeHasher:
    """Cumple el protocolo `PasswordHasher`. Rápido, no seguro, no usar
    fuera de tests."""

    def __init__(self, *, parametros_vigentes: str = "fake:v1") -> None:
        self._parametros_vigentes = parametros_vigentes

    def hash(self, password: str) -> str:
        sal = secrets.token_hex(8)
        digest = hashlib.sha256(f"{sal}{password}".encode()).hexdigest()
        return f"{self._parametros_vigentes}${sal}${digest}"

    def verify(self, password: str, hashed: str) -> bool:
        try:
            parametros, sal, digest = hashed.split("$", 2)
        except ValueError:
            return False
        esperado = hashlib.sha256(f"{sal}{password}".encode()).hexdigest()
        return secrets.compare_digest(esperado, digest)

    def needs_rehash(self, hashed: str) -> bool:
        return not hashed.startswith(f"{self._parametros_vigentes}$")
