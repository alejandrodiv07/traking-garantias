from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from prime.api.routers import auth

app = FastAPI(title="Prime Telecom Auth API")

# Configuración CORS estricta para el frontend local (Vite)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://localhost:5173"],
    allow_credentials=True, # Obligatorio para aceptar cookies cross-origin
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(auth.router)
