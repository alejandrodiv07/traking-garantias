"""
Value Objects del dominio Identity (Paso 1).

Dominio puro: solo stdlib. Ni pydantic ni email-validator — la validación de
la capa web (Paso 8) es otra capa y otro contrato; aquí un `re` y un `str`
cubren el 100% de lo que el dominio necesita garantizar.

Regla que sostiene ambos objetos: no pueden existir en estado inválido. Si
tienes una instancia, ya está validada; ninguna capa superior vuelve a mirar.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

MAX_EMAIL = 160
MIN_PASSWORD = 12
MAX_PASSWORD = 128

# Parte local: cualquier carácter salvo espacios (incluye \n y \r) y los
# metacaracteres que abren SQLi, inyección de cabeceras, HTML y listas de
# destinatarios. Unicode permitido a propósito: josé@ es una cuenta legítima
# y distinta de jose@ (la BD la compara byte a byte, COLLATE ..._as_cs).
_ATOMO = r"[^\s@.,;:\"'<>()\[\]\\]+"
_LOCAL = rf"{_ATOMO}(?:\.{_ATOMO})*"
# Dominio: etiquetas ASCII sin guion al principio ni al final, y un TLD
# alfabético de 2+. IDN se rechaza; no hay caso de uso corporativo.
_ETIQUETA = r"[a-z0-9](?:[a-z0-9-]*[a-z0-9])?"
_DOMINIO = rf"{_ETIQUETA}(?:\.{_ETIQUETA})*\.[a-z]{{2,}}"
_EMAIL = re.compile(rf"{_LOCAL}@{_DOMINIO}")


@dataclass(frozen=True, slots=True)
class Email:
    """Correo corporativo ya normalizado. `frozen` da inmutabilidad; el
    `__eq__`/`__hash__` que regala el decorador opera sobre la forma
    normalizada, que es justo la identidad que usa la tabla `users`."""

    value: str

    def __post_init__(self) -> None:
        if not isinstance(self.value, str):
            raise TypeError(f"Email espera str, no {type(self.value).__name__}")

        normalizado = self.value.strip().lower()

        # La longitud se comprueba antes del regex: una entrada de 100 KB no
        # llega nunca al motor de expresiones regulares.
        if not 0 < len(normalizado) <= MAX_EMAIL:
            raise ValueError(f"el email debe tener entre 1 y {MAX_EMAIL} caracteres")

        if not _EMAIL.fullmatch(normalizado):
            raise ValueError("formato de email inválido")

        object.__setattr__(self, "value", normalizado)


class PlainPassword:
    """Contraseña en claro, de camino al hasher y a ningún otro sitio.

    No es un dataclass a propósito: el `__repr__` generado escupiría el
    secreto en el primer traceback, y taparlo cuesta más que escribir la
    clase a mano. Tampoco define `__eq__` — comparar contraseñas es trabajo
    del `PasswordHasher` (Paso 2), en tiempo constante.
    """

    __slots__ = ("_value",)

    def __init__(self, raw: str) -> None:
        if not isinstance(raw, str):
            raise TypeError(f"PlainPassword espera str, no {type(raw).__name__}")

        # El crudo no se recorta ni se filtra: se acepta cualquier byte y se
        # hashea. Quitar comillas produciría claves peores, no mejores. El
        # techo de 128 es lo que corta el DoS por Argon2 con entrada gigante.
        if not MIN_PASSWORD <= len(raw) <= MAX_PASSWORD:
            raise ValueError(
                f"la contraseña debe tener entre {MIN_PASSWORD} y "
                f"{MAX_PASSWORD} caracteres"
            )

        object.__setattr__(self, "_value", raw)

    def expose(self) -> str:
        """Único camino al valor. Llamarlo tiene que verse en el diff."""
        return self._value

    def __setattr__(self, name: str, value: object) -> None:
        raise AttributeError("PlainPassword es inmutable")

    def __repr__(self) -> str:
        return "PlainPassword(***)"

    __str__ = __repr__
