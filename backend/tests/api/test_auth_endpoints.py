# backend/tests/api/test_auth_endpoints.py
"""RED -> GREEN de la Fase 9 — Adaptador HTTP de Autenticación (FastAPI)."""
from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from prime.api.main import app
from prime.api.dependencies import get_login_use_case, get_verify_mfa_use_case
from prime.identity.application.login_use_case import LoginResult
from prime.identity.application.verify_mfa_use_case import VerifyMfaResult

# --- Fakes para inyección de dependencias ---
class FakeLoginUseCase:
    def execute(self, email, password, now, **kwargs):
        if password == "wrong-password":
            return LoginResult(outcome="INVALID_CREDENTIALS")
        if email == "mfa-user@primetelecom.com":
            return LoginResult(outcome="MFA_REQUIRED", preauth_token="token-preauth-mfa")
        return LoginResult(outcome="SESSION_ISSUED", session_token="sesion-activa", csrf_token="csrf-activo")

class FakeVerifyMfaUseCase:
    def execute(self, preauth_token, code, now, **kwargs):
        if code == "000000":
            return VerifyMfaResult(outcome="MFA_FAILED")
        return VerifyMfaResult(outcome="SESSION_ISSUED", session_token="sesion-activa", csrf_token="csrf-activo")

app.dependency_overrides[get_login_use_case] = FakeLoginUseCase
app.dependency_overrides[get_verify_mfa_use_case] = FakeVerifyMfaUseCase

client = TestClient(app)

# ---------------------------------------------------------------------------
# POST /auth/login
# ---------------------------------------------------------------------------

def test_login_payload_incompleto_devuelve_422():
    # Falta el campo 'password'
    response = client.post("/auth/login", json={"email": "ada@primetelecom.com"})
    assert response.status_code == 422


def test_login_credenciales_invalidas_devuelve_401():
    response = client.post(
        "/auth/login",
        json={"email": "ada@primetelecom.com", "password": "wrong-password"}
    )
    assert response.status_code == 401
    assert "set-cookie" not in response.headers.get("set-cookie", "").lower()


def test_login_exitoso_sin_mfa_emite_cookies_seguras_200(monkeypatch):
    # Nota para el GREEN: Inyectaremos un mock del LoginUseCase para forzar SESSION_ISSUED
    # sin tocar la BD, ya que aquí solo probamos el adaptador HTTP.

    response = client.post(
        "/auth/login",
        json={"email": "admin@primetelecom.com", "password": "Prime-Admin-2026!"}
    )
    assert response.status_code == 200

    cookies = response.headers.get_list("set-cookie")
    assert cookies, "No se emitieron cookies en la respuesta"

    cookies_str = "".join(cookies).lower()
    assert "pt_session=" in cookies_str
    assert "pt_csrf=" in cookies_str

    # Verificación de mitigación XSS
    for cookie in cookies:
        cookie_lower = cookie.lower()
        assert "httponly" in cookie_lower, f"Falta HttpOnly en: {cookie}"
        assert "secure" in cookie_lower, f"Falta Secure en: {cookie}"
        assert "samesite=lax" in cookie_lower, f"Falta SameSite=Lax en: {cookie}"


def test_login_requiere_mfa_devuelve_202_con_cookie_preauth():
    response = client.post(
        "/auth/login",
        json={"email": "mfa-user@primetelecom.com", "password": "CorrectPassword123!"}
    )
    # 202 Accepted: Petición aceptada pero el proceso de auth no ha concluido.
    assert response.status_code == 202

    cookies_str = "".join(response.headers.get_list("set-cookie")).lower()
    assert "pt_mfa=" in cookies_str
    assert "pt_session=" not in cookies_str  # Aún no hay sesión válida
    assert "httponly" in cookies_str
    assert "secure" in cookies_str


# ---------------------------------------------------------------------------
# POST /auth/mfa/verify
# ---------------------------------------------------------------------------

def test_verify_mfa_sin_cookie_preauth_devuelve_401():
    # Intento de verificar MFA sin la cookie temporal pt_mfa
    response = client.post("/auth/mfa/verify", json={"code": "123456"})
    assert response.status_code == 401


def test_verify_mfa_codigo_incorrecto_devuelve_401():
    client.cookies.set("pt_mfa", "token-preauth-falso")
    response = client.post("/auth/mfa/verify", json={"code": "000000"})
    assert response.status_code == 401
    # La cookie pt_mfa no debe borrarse hasta que expire o se agoten intentos


def test_verify_mfa_exitoso_emite_sesion_y_limpia_preauth():
    client.cookies.set("pt_mfa", "token-preauth-valido")
    response = client.post("/auth/mfa/verify", json={"code": "123456"})

    assert response.status_code == 200

    cookies_str = "".join(response.headers.get_list("set-cookie")).lower()
    assert "pt_session=" in cookies_str
    assert "pt_mfa=;" in cookies_str or "max-age=0" in cookies_str # Borrado de cookie MFA


# ---------------------------------------------------------------------------
# POST /auth/logout
# ---------------------------------------------------------------------------

def test_logout_limpia_cookies_de_sesion():
    client.cookies.set("pt_session", "sesion-activa")
    client.cookies.set("pt_csrf", "csrf-activo")

    response = client.post("/auth/logout")
    assert response.status_code == 200

    cookies_str = "".join(response.headers.get_list("set-cookie")).lower()
    # Verifica que las cookies se marcan para borrado
    assert "pt_session=;" in cookies_str or "max-age=0" in cookies_str
    assert "pt_csrf=;" in cookies_str or "max-age=0" in cookies_str
