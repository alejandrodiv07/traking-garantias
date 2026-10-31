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
import NuevaGarantia from "./features/garantias/NuevaGarantia.jsx";
import Consulta from "./features/garantias/Consulta.jsx";
import AbrirOrden from "./features/taller/AbrirOrden.jsx";
import Taller from "./features/taller/Taller.jsx";
import Garantias from "./features/garantias/Garantias.jsx";
import OrdenDetalle from "./features/taller/OrdenDetalle.jsx";
import Tablero from "./features/tablero/Tablero.jsx";
import ImportarVentas from "./features/ventas/ImportarVentas.jsx";
import Proximamente from "./features/layout/Proximamente.jsx";
import Inventario from "./features/inventario/Inventario.jsx";
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
        <Route path="/garantias" element={<Garantias />} />
        <Route path="/garantias/nueva" element={<NuevaGarantia />} />
        <Route path="/garantias/consulta" element={<Consulta />} />
        <Route path="/taller" element={<Taller />} />
        <Route path="/taller/nueva" element={<AbrirOrden />} />
        <Route path="/taller/:id" element={<OrdenDetalle />} />
        <Route path="/entregas" element={<Proximamente titulo="Entregas" motivo="Falta el backend: plazo previsto y datos de la entrega (quién retira, cobro, accesorios)." />} />
        <Route path="/inventario" element={<Inventario />} />
        <Route path="/reportes" element={<Proximamente titulo="Reportes" motivo="Falta el backend: expedientes, generación de PDF y exportaciones." />} />
        <Route path="/clientes" element={<Proximamente titulo="Clientes" motivo="Falta el backend: registro de avisos y envío de correos (depende de Resend)." />} />
        <Route path="/notificaciones" element={<Proximamente titulo="Notificaciones" motivo="Fase 2c: alertas automáticas de vencimiento y su bandeja." />} />
        {/* Fase 2b: la base ya lo impone (importar_ventas); esto solo evita la tropezada. */}
        <Route
          path="/ventas/importar"
          element={
            <RutaProtegida rolesPermitidos={["ADMIN", "JEFE_SERVICIO"]}>
              <ImportarVentas />
            </RutaProtegida>
          }
        />
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
