/**
 * Estado de sesión de la aplicación.
 *
 * Context nativo, sin Zustand: el estado es un objeto de cuatro campos que
 * cambia dos veces por sesión (entrar y salir). Una librería de estado aquí
 * sería una dependencia sin trabajo que hacer.
 *
 * ---------------------------------------------------------------------------
 * Lo que este contexto NO es
 * ---------------------------------------------------------------------------
 * No es una credencial. `perfil.role` sirve para decidir qué pinta la interfaz
 * y a qué ruta se redirige, nada más. Quien manipule este estado desde las
 * DevTools verá el panel de ADMIN vacío: cada consulta seguirá pasando por la
 * RLS de Postgres, que no lee este objeto sino el JWT. Toda pantalla que se
 * "protege" solo con este valor es cosmética, y así hay que tratarla.
 */
import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import { supabase } from "../../lib/supabaseClient.js";
import { cerrarSesion, mfaVerificada, obtenerPerfil } from "./authService.js";

const AuthContext = createContext(null);

export function AuthProvider({ children }) {
  const [sesion, setSesion] = useState(null);
  const [perfil, setPerfil] = useState(null);
  // `cargando` arranca en true: hasta que Supabase resuelva si hay sesión
  // guardada no se puede decidir nada. Sin esta bandera, un refresco de página
  // en /admin parpadea a /login y vuelve — y en una conexión lenta el usuario
  // ve la pantalla de acceso durante un segundo entero.
  const [cargando, setCargando] = useState(true);
  // ¿Esta sesión superó el segundo factor? Arranca en false y solo lo pone a
  // true una consulta a `mfa_ok()` en la base. No es cosmética: entra en
  // `autenticado`, así que una sesión a medio verificar NO es una sesión
  // autenticada para el router (ver el comentario de `autenticado` abajo).
  const [mfaOk, setMfaOk] = useState(false);

  const montado = useRef(true);

  const sincronizarPerfil = useCallback(async (nuevaSesion) => {
    if (!nuevaSesion) {
      if (montado.current) {
        setSesion(null);
        setPerfil(null);
        setMfaOk(false);
        setCargando(false);
      }
      return;
    }

    const p = await obtenerPerfil();

    if (!montado.current) return;

    if (!p) {
      // Sesión válida en Supabase Auth pero sin perfil activo en la base:
      // cuenta dada de baja mientras la pestaña estaba abierta. Se expulsa.
      await cerrarSesion();
      setSesion(null);
      setPerfil(null);
      setMfaOk(false);
      setCargando(false);
      return;
    }

    // Una RPC más por arranque de sesión. Se paga aquí y no en cada ruta:
    // `RutaProtegida` se renderiza en cada navegación, `mfa_ok()` no.
    const verificada = await mfaVerificada();

    if (!montado.current) return;

    setSesion(nuevaSesion);
    setPerfil(p);
    setMfaOk(verificada);
    setCargando(false);
  }, []);

  useEffect(() => {
    montado.current = true;

    supabase.auth.getSession().then(({ data }) => {
      sincronizarPerfil(data?.session ?? null);
    });

    const { data: sub } = supabase.auth.onAuthStateChange((evento, nuevaSesion) => {
      // IMPORTANTE: nada de `await` de supabase-js DENTRO de este callback.
      // El cliente mantiene un lock mientras lo ejecuta, y una llamada
      // anidada a la propia librería se queda esperando ese lock para
      // siempre: la aplicación se congela sin error. Se difiere a la
      // siguiente vuelta del event loop, que libera el lock primero.
      // (Es el bug clásico de integración de supabase-js con React.)
      if (evento === "SIGNED_OUT") {
        setSesion(null);
        setPerfil(null);
        setMfaOk(false);
        setCargando(false);
        return;
      }
      if (evento === "TOKEN_REFRESHED") {
        // Solo se renovó el JWT; el perfil no cambia. Evita una consulta a
        // `profiles` cada hora, por pestaña abierta.
        setSesion(nuevaSesion);
        return;
      }
      setTimeout(() => sincronizarPerfil(nuevaSesion), 0);
    });

    return () => {
      montado.current = false;
      sub?.subscription?.unsubscribe();
    };
  }, [sincronizarPerfil]);

  const salir = useCallback(async () => {
    await cerrarSesion();
    setSesion(null);
    setPerfil(null);
    setMfaOk(false);
  }, []);

  const valor = useMemo(
    () => ({
      sesion,
      perfil,
      rol: perfil?.role ?? null,
      // `autenticado` INCLUYE el segundo factor, y ahí está toda la gracia:
      // sin tocar ni `RutaProtegida` ni `SoloInvitados`, una sesión a medio
      // verificar deja de ser "autenticada" para el router. Si `autenticado`
      // fuera solo sesión + perfil, `SoloInvitados` sacaría al usuario de
      // /login en el instante en que la contraseña se acepta —justo cuando
      // hay que pintarle el paso 2— y el código no se pediría nunca.
      autenticado: Boolean(sesion && perfil && mfaOk),
      // Para el contenedor del login: hay sesión, pero le falta el código.
      sesionSinVerificar: Boolean(sesion && perfil && !mfaOk),
      mfaOk,
      cargando,
      salir,
      // Para cuando un ADMIN se cambia el nombre y la cabecera debe reflejarlo
      // sin recargar la página.
      refrescarPerfil: () => sincronizarPerfil(sesion),
    }),
    [sesion, perfil, mfaOk, cargando, salir, sincronizarPerfil]
  );

  return <AuthContext.Provider value={valor}>{children}</AuthContext.Provider>;
}

export function useAuth() {
  const ctx = useContext(AuthContext);
  if (!ctx) {
    throw new Error("useAuth debe usarse dentro de <AuthProvider>");
  }
  return ctx;
}
