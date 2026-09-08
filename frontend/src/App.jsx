/**
 * Enrutado de la SPA.
 *
 * `<AuthProvider>` envuelve al router porque `RutaProtegida` y `LoginPage`
 * necesitan el contexto, y porque así la sesión se resuelve UNA vez al
 * arrancar y no una vez por ruta.
 */
import { BrowserRouter, Navigate, Route, Routes } from "react-router-dom";
import { AuthProvider, useAuth } from "./features/auth/AuthContext.jsx";
import RutaProtegida, { PantallaCargando } from "./features/auth/RutaProtegida.jsx";
import LoginPage from "./features/auth/LoginPage.jsx";
import Panel from "./features/paneles/Panel.jsx";
import Tablero from "./features/taller/Tablero.jsx";
import { rutaDeInicio } from "./features/auth/authService.js";
import "./App.css";
import "./features/auth/estado.css";

export default function App() {
  return (
    <AuthProvider>
      <BrowserRouter>
        <Rutas />
      </BrowserRouter>
    </AuthProvider>
  );
}

function Rutas() {
  return (
    <Routes>
      <Route path="/login" element={<SoloInvitados />} />

      <Route
        path="/admin"
        element={
          <RutaProtegida rolesPermitidos={["ADMIN"]}>
            <Tablero />
          </RutaProtegida>
        }
      />
      <Route
        path="/jefe"
        element={
          <RutaProtegida rolesPermitidos={["JEFE_SERVICIO", "ADMIN"]}>
            <Panel titulo="Jefatura de servicio" />
          </RutaProtegida>
        }
      />
      <Route
        path="/tecnico"
        element={
          <RutaProtegida rolesPermitidos={["TECNICO"]}>
            <Panel titulo="Taller" />
          </RutaProtegida>
        }
      />
      <Route
        path="/recepcion"
        element={
          <RutaProtegida rolesPermitidos={["RECEPCION", "ADMIN"]}>
            <Panel titulo="Recepción" />
          </RutaProtegida>
        }
      />

      <Route path="/sin-acceso" element={<SinAcceso />} />
      <Route path="*" element={<Raiz />} />
    </Routes>
  );
}

/** `/login` con sesión abierta no debe volver a pedir credenciales. */
function SoloInvitados() {
  const { autenticado, rol, cargando } = useAuth();
  if (cargando) return <PantallaCargando />;
  if (autenticado) return <Navigate to={rutaDeInicio(rol)} replace />;
  return <LoginPage />;
}

/** `/` y cualquier ruta desconocida: al panel que toque, o a login. */
function Raiz() {
  const { autenticado, rol, cargando } = useAuth();
  if (cargando) return <PantallaCargando />;
  return <Navigate to={autenticado ? rutaDeInicio(rol) : "/login"} replace />;
}

function SinAcceso() {
  const { perfil, salir } = useAuth();
  return (
    <div className="est-centrado est-sin-acceso">
      <div className="est-caja">
        <h1 className="est-titulo">Sesión válida, sin alcance</h1>
        <p className="est-texto">
          Tu cuenta ({perfil?.email}) no tiene un rol con acceso a esta
          aplicación. Contacta con el departamento de sistemas.
        </p>
        <button type="button" onClick={salir} className="est-boton">
          Cerrar sesión
        </button>
      </div>
    </div>
  );
}
