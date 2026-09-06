from datetime import datetime, timezone
from fastapi import APIRouter, Depends, HTTPException, Response, status, Cookie
from pydantic import BaseModel

from prime.api.dependencies import get_login_use_case, get_verify_mfa_use_case
from prime.identity.application.login_use_case import LoginUseCase
from prime.identity.application.verify_mfa_use_case import VerifyMfaUseCase

router = APIRouter(prefix="/auth", tags=["auth"])

class LoginRequest(BaseModel):
    email: str
    password: str

class VerifyMfaRequest(BaseModel):
    code: str

def _now() -> datetime:
    return datetime.now(timezone.utc).replace(tzinfo=None)

@router.post("/login")
def login(
    request: LoginRequest,
    response: Response,
    use_case: LoginUseCase = Depends(get_login_use_case)
):
    result = use_case.execute(email=request.email, password=request.password, now=_now())

    if result.outcome == "INVALID_CREDENTIALS":
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Credenciales inválidas")

    if result.outcome == "MFA_REQUIRED":
        response.status_code = status.HTTP_202_ACCEPTED
        response.set_cookie(
            key="pt_mfa",
            value=result.preauth_token,
            httponly=True,
            secure=True,
            samesite="lax"
        )
        return {"detail": "MFA requerido"}

    if result.outcome == "SESSION_ISSUED":
        response.set_cookie(
            key="pt_session", value=result.session_token, httponly=True, secure=True, samesite="lax"
        )
        response.set_cookie(
            key="pt_csrf", value=result.csrf_token, httponly=True, secure=True, samesite="lax"
        )
        return {"detail": "Login exitoso"}

@router.post("/mfa/verify")
def verify_mfa(
    request: VerifyMfaRequest,
    response: Response,
    pt_mfa: str | None = Cookie(default=None),
    use_case: VerifyMfaUseCase = Depends(get_verify_mfa_use_case)
):
    if not pt_mfa:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Token MFA faltante")

    result = use_case.execute(preauth_token=pt_mfa, code=request.code, now=_now())

    if result.outcome == "SESSION_ISSUED":
        response.set_cookie(
            key="pt_session", value=result.session_token, httponly=True, secure=True, samesite="lax"
        )
        response.set_cookie(
            key="pt_csrf", value=result.csrf_token, httponly=True, secure=True, samesite="lax"
        )
        response.delete_cookie("pt_mfa")
        return {"detail": "MFA verificado y sesión iniciada"}

    raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="MFA fallido")

@router.post("/logout")
def logout(response: Response):
    response.delete_cookie("pt_session")
    response.delete_cookie("pt_csrf")
    return {"detail": "Logout exitoso"}
