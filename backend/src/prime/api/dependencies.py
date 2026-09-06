from __future__ import annotations

from prime.identity.application.login_use_case import LoginUseCase
from prime.identity.application.verify_mfa_use_case import VerifyMfaUseCase

# Estos son los conectores ("ports") de nuestra arquitectura hexagonal.
# En la Fase 10 (Wiring), los implementaremos para que inyecten la sesión de BD y los repositorios.
# En la Fase 9 (actual), los tests web los sobrescribirán con Fakes.

def get_login_use_case() -> LoginUseCase:
    raise NotImplementedError("Dependencia no cableada. Fase 10 pendiente.")

def get_verify_mfa_use_case() -> VerifyMfaUseCase:
    raise NotImplementedError("Dependencia no cableada. Fase 10 pendiente.")
