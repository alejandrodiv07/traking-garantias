"""
`PasswordHasher` — puerto + adaptador Argon2id (Paso 2, contrato unificado
en Fase 8).

Puerto informal (duck typing, sin `Protocol` de por medio: un solo
adaptador de produccion no necesita el ceremonial de una interfaz formal;
el contrato lo fijan los tests parametrizados de test_password_hasher.py):

    hash(password: PlainPassword | str) -> str
    verify(password: PlainPassword | str, hashed: str) -> bool
    needs_rehash(hashed: str) -> bool

**Por que la union y no solo `PlainPassword`:** los casos de uso (Paso 7 en
adelante) pasan SIEMPRE `PlainPassword` — es lo que hace que leer un
secreto se vea en el diff, via `.expose()`, y ahora ese `.expose()` ocurre
en un unico sitio: aqui dentro. Pero los tests de dominio del Paso 2
ejercitan el adaptador con cadenas crudas, varias mas cortas que el minimo
de 12 que impone `PlainPassword`; exigir el VO obligaria a reescribir esos
casos limite o, peor, a relajar el VO para complacer a un test. Aceptar
ambos une el contrato donde importa (arriba) sin propagar el cambio hacia
abajo.

Ganador del Password Hashing Competition, resistente a GPU/ASIC. La
comparacion en tiempo constante y el salt aleatorio por hash los hace la
biblioteca (`argon2-cffi`, sobre el Argon2 de referencia en C) — no se
reimplementan aqui. Directiva CISO 2.
"""

from __future__ import annotations

from argon2 import PasswordHasher as _Argon2
from argon2.exceptions import InvalidHash, VerificationError, VerifyMismatchError

from prime.identity.domain.value_objects import PlainPassword

# Parametros vigentes: m=64 MiB, t=3, p=4 (Blueprint §5, directiva 2).
_MEMORIA_KIB = 64 * 1024
_ITERACIONES = 3
_PARALELISMO = 4


def _crudo(password: PlainPassword | str) -> str:
    """Unico punto del sistema donde un `PlainPassword` se destapa."""
    if isinstance(password, PlainPassword):
        return password.expose()
    if isinstance(password, str):
        return password
    raise TypeError(
        f"PasswordHasher espera PlainPassword o str, no {type(password).__name__}"
    )


class Argon2PasswordHasher:
    def __init__(
        self,
        *,
        memoria_kib: int = _MEMORIA_KIB,
        iteraciones: int = _ITERACIONES,
        paralelismo: int = _PARALELISMO,
    ) -> None:
        self._ph = _Argon2(
            time_cost=iteraciones,
            memory_cost=memoria_kib,
            parallelism=paralelismo,
        )

    def hash(self, password: PlainPassword | str) -> str:
        return self._ph.hash(_crudo(password))

    def verify(self, password: PlainPassword | str, hashed: str) -> bool:
        try:
            # orden argon2-cffi: verify(hash, password) — invertido respecto
            # a nuestro puerto, que pone primero el dato del usuario.
            return self._ph.verify(hashed, _crudo(password))
        except (VerifyMismatchError, VerificationError, InvalidHash):
            return False

    def needs_rehash(self, hashed: str) -> bool:
        try:
            return self._ph.check_needs_rehash(hashed)
        except InvalidHash:
            # Un hash que ni siquiera se puede parsear no esta "al dia": no
            # cae por esta rama en la suite (siempre hasheamos primero), pero
            # tratarlo como "necesita rehash" es el lado seguro por defecto.
            return True
