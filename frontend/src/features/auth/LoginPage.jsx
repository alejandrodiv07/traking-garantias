/**
 * Contenedor de la pantalla de acceso. Orquesta los DOS pasos.
 *
 * `Login.jsx` es puramente presentacional y expone
 *
 *     onSubmit({ email, password, remember }) -> Promise
 *        resuelve { mfa: true, expiraEn } -> pinta el paso 2
 *        resuelve { scope: false }        -> "Sesión válida, sin alcance"
 *        rechaza                          -> "Credenciales incorrectas"
 *     onVerify(codigo) -> Promise
 *     onResend()       -> Promise<{ expiraEn }>
 *     onCancel()       -> abandona el paso 2
 *
 * Sustituye al flujo de un solo paso. Recupera la idea del viejo `AuthFlow.jsx`
 * del backend Flask —contraseña y luego código— pero con una diferencia que
 * importa: allí el segundo paso lo imponía el servidor porque sin él no había
 * token. Aquí `signInWithPassword` YA devolvió un JWT válido antes de pintar el
 * paso 2, así que este componente no está protegiendo nada por sí solo. La
 * puerta está en Postgres: `mi_rol()` exige `mfa_ok()`, y sin código verificado
 * ninguna consulta devuelve una garantía. Esta pantalla solo hace visible esa
 * puerta; nunca la sustituye.
 *
 * ---------------------------------------------------------------------------
 * Y SI FALLA EL ENVÍO DEL CÓDIGO, SE CIERRA LA SESIÓN
 * ---------------------------------------------------------------------------
 * Ese es el caso que se olvida siempre. Contraseña correcta + Resend caído
 * dejaría al usuario con un JWT válido, sin pantalla donde verificar y sin
 * forma de avanzar: una sesión zombi que se queda en el almacenamiento del
 * navegador hasta que caduque. Se cierra en el `catch`.
 */
import { useCallback, useRef } from "react";
import { useLocation, useNavigate } from "react-router-dom";
import Login from "./Login.jsx";
import { useAuth } from "./AuthContext.jsx";
import {
  cerrarSesion,
  iniciarSesion,
  rutaDeInicio,
  solicitarCodigoMfa,
  verificarCodigoMfa,
  Resultado,
} from "./authService.js";

export default function LoginPage() {
  const navigate = useNavigate();
  const location = useLocation();
  const { refrescarPerfil } = useAuth();

  // El perfil se resuelve en el paso 1 y se usa en el paso 2 para decidir el
  // destino. En una ref y no en estado: nada de lo que se pinta depende de
  // él, así que guardarlo en `useState` solo añadiría un render.
  const perfilRef = useRef(null);

  /** Destino final, común a los dos pasos. */
  const entrar = useCallback(
    async (perfil) => {
      const destino = rutaDeInicio(perfil.role);

      if (destino === "/sin-acceso") {
        // Autenticado, pero con un rol que esta versión de la SPA no sabe
        // enrutar. `Login.jsx` tiene un estado propio para exactamente esto.
        return { scope: false };
      }

      // El contexto se entera solo por `onAuthStateChange`, pero se fuerza el
      // refresco para que el panel ya tenga el perfil —y el `mfaOk` recién
      // concedido— en el primer render y no parpadee.
      await refrescarPerfil();

      // Si el usuario llegó aquí desde una URL protegida, vuelve allí.
      const previa = location.state?.from?.pathname;
      navigate(previa && previa !== "/login" ? previa : destino, { replace: true });

      return { scope: true };
    },
    [navigate, location, refrescarPerfil]
  );

  // ---------------------------------------------------------------- paso 1
  const handleSubmit = useCallback(async ({ email, password, remember }) => {
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

    perfilRef.current = perfil;

    try {
      const { expiraEn } = await solicitarCodigoMfa();
      return { mfa: true, expiraEn };
    } catch (err) {
      // Sesión abierta que no puede completarse: no se deja viva.
      await cerrarSesion();
      throw err;
    }
  }, []);

  // ---------------------------------------------------------------- paso 2
  const handleVerify = useCallback(
    async (codigo) => {
      await verificarCodigoMfa(codigo);   // lanza si no vale

      // El rol para decidir la ruta viene del paso 1. Si la cuenta se
      // desactivó entre los dos pasos, el `refrescarPerfil()` de `entrar`
      // devuelve perfil nulo y `AuthContext` expulsa la sesión: la copia de
      // aquí solo elige a qué panel apuntar, no concede nada.
      return entrar(perfilRef.current);
    },
    [entrar]
  );

  const handleResend = useCallback(() => solicitarCodigoMfa(), []);

  // "Usar otra cuenta": la sesión a medio verificar se cierra. Dejarla viva
  // sería dejar en el navegador un token al que solo le falta un código.
  const handleCancel = useCallback(() => {
    perfilRef.current = null;
    cerrarSesion();
  }, []);

  return (
    <Login
      onSubmit={handleSubmit}
      onVerify={handleVerify}
      onResend={handleResend}
      onCancel={handleCancel}
      onForgotPassword={() => navigate("/recuperar")}
      onContactAdmin={() => {
        window.location.href = "mailto:sistemas@primetelecom.com";
      }}
    />
  );
}
