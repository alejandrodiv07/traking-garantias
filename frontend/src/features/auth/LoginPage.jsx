/**
 * Contenedor de la pantalla de acceso.
 *
 * `Login.jsx` es puramente presentacional y expone
 * `onSubmit({ email, password, remember }) -> Promise`, y su contrato es
 *
 *     resuelve                  -> acceso concedido
 *     resuelve { scope: false } -> "Sesión válida, sin alcance"
 *     rechaza                   -> "Credenciales incorrectas"
 *
 * Ese contrato encaja tal cual con el nuevo backend, así que el componente de
 * UI se reutiliza sin tocar una línea.
 *
 * Sustituye a `AuthFlow.jsx`, que orquestaba el paso de 2FA por correo del
 * backend Flask. Ese componente y `MfaCodeScreen.jsx` quedan sin uso: Supabase
 * Auth resuelve el login en un solo paso, y el segundo factor (TOTP) se activa
 * desde el panel de Supabase, no desde esta pantalla.
 */
import { useCallback } from "react";
import { useLocation, useNavigate } from "react-router-dom";
import Login from "./Login.jsx";
import { useAuth } from "./AuthContext.jsx";
import { iniciarSesion, rutaDeInicio, Resultado } from "./authService.js";

export default function LoginPage() {
  const navigate = useNavigate();
  const location = useLocation();
  const { refrescarPerfil } = useAuth();

  const handleSubmit = useCallback(
    async ({ email, password, remember }) => {
      const { resultado, mensaje, perfil } = await iniciarSesion({
        email,
        password,
        recordar: remember,
      });

      if (resultado !== Resultado.OK) {
        // `Login.jsx` muestra "Credenciales incorrectas" ante CUALQUIER
        // rechazo. Se le pasa el mensaje ya colapsado por `authService`:
        // ni el componente ni la consola ven la causa real.
        throw new Error(mensaje ?? "Credenciales incorrectas");
      }

      const destino = rutaDeInicio(perfil.role);

      if (destino === "/sin-acceso") {
        // Autenticado, pero con un rol que esta versión de la SPA no sabe
        // enrutar. `Login.jsx` tiene un estado propio para exactamente esto.
        return { scope: false };
      }

      // El contexto se entera solo por `onAuthStateChange`, pero se fuerza el
      // refresco para que el panel ya tenga el perfil en el primer render y
      // no parpadee.
      await refrescarPerfil();

      // Si el usuario llegó aquí desde una URL protegida, vuelve allí.
      const previa = location.state?.from?.pathname;
      navigate(previa && previa !== "/login" ? previa : destino, { replace: true });

      return { scope: true };
    },
    [navigate, location, refrescarPerfil]
  );

  return (
    <Login
      onSubmit={handleSubmit}
      onForgotPassword={() => navigate("/recuperar")}
      onContactAdmin={() => {
        window.location.href = "mailto:sistemas@primetelecom.com";
      }}
    />
  );
}
