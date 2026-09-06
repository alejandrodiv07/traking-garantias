/**
 * Guardia de ruta.
 *
 * Repetido de `AuthContext.jsx` porque conviene tenerlo a la vista aquí: esto
 * NO es una medida de seguridad. Es enrutamiento. Un usuario que edite el
 * estado de React llegará a `/admin` y verá una pantalla vacía, porque los
 * datos los sirve Postgres bajo RLS y no este componente. La seguridad está
 * en la base; esto solo evita que un TECNICO tropiece con una pantalla que no
 * le sirve.
 */
import { Navigate, useLocation } from "react-router-dom";
import { useAuth } from "./AuthContext.jsx";
import { rutaDeInicio } from "./authService.js";

export default function RutaProtegida({ rolesPermitidos, children }) {
  const { autenticado, rol, cargando } = useAuth();
  const location = useLocation();

  // Sin esta guarda, el primer render tras un refresco (sesión aún no
  // resuelta) redirige a /login y expulsa a un usuario que sí tenía sesión.
  if (cargando) return <PantallaCargando />;

  if (!autenticado) {
    // `state.from` permite volver a donde iba después de entrar.
    return <Navigate to="/login" replace state={{ from: location }} />;
  }

  if (rolesPermitidos && !rolesPermitidos.includes(rol)) {
    // A su propio panel, no a una página de error: el usuario no hizo nada
    // malo, simplemente escribió una URL que no le corresponde.
    return <Navigate to={rutaDeInicio(rol)} replace />;
  }

  return children;
}

export function PantallaCargando() {
  return (
    <div
      style={{
        minHeight: "100dvh",
        display: "grid",
        placeItems: "center",
        color: "#64748b",
        font: "500 14px/1.5 system-ui, -apple-system, Segoe UI, sans-serif",
      }}
    >
      <span role="status" aria-live="polite">
        Verificando sesión…
      </span>
    </div>
  );
}
