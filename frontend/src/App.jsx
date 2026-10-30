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
import Layout from "./features/layout/Layout.jsx";
import Tablero from "./features/tablero/Tablero.jsx";
import { rutaDeInicio } from "./features/auth/authService.js";
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

const TODOS_LOS_ROLES = ["ADMIN", "JEFE_SERVICIO", "TECNICO", "RECEPCION"];

function Rutas() {
  return (
    <Routes>
      <Route path="/login" element={<SoloInvitados />} />

      {/* Hito 1: TODOS los roles aterrizan en el mismo Tablero (spec §7.3);
          lo que difiere por rol lo decide la base (RLS) y los componentes. */}
      <Route
        path="/tablero"
        element={
          <RutaProtegida rolesPermitidos={["ADMIN", "JEFE_SERVICIO", "TECNICO", "RECEPCION"]}>
            <Tablero />
          </RutaProtegida>
        }
      />
      {/* Rutas antiguas, por si hay algún enlace guardado: van al Tablero. */}
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
            <Tablero />
          </RutaProtegida>
        }
      />
      <Route
        path="/tecnico"
        element={
          <RutaProtegida rolesPermitidos={["TECNICO"]}>
            <Tablero />
          </RutaProtegida>
        }
      />
      <Route
        path="/recepcion"
        element={
          <RutaProtegida rolesPermitidos={["RECEPCION", "ADMIN"]}>
            <Tablero />
          </RutaProtegida>
        }
      />

      {/* Fase 2a: cada pantalla reemplaza su stub en las tareas 13–17. */}
      <Route
        element={
          <RutaProtegida rolesPermitidos={TODOS_LOS_ROLES}>
            <Layout />
          </RutaProtegida>
        }
      >
        <Route path="/garantias" element={<div>Tablero de garantías</div>} />
        <Route path="/garantias/nueva" element={<div>Nueva garantía</div>} />
        <Route path="/garantias/consulta" element={<div>Consulta de garantía</div>} />
        <Route path="/taller" element={<div>Taller</div>} />
        <Route path="/taller/nueva" element={<div>Abrir orden</div>} />
        <Route path="/taller/:id" element={<div>Detalle de la orden</div>} />
      </Route>

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
