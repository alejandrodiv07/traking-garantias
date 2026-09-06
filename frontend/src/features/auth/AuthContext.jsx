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
import { cerrarSesion, obtenerPerfil } from "./authService.js";

const AuthContext = createContext(null);

export function AuthProvider({ children }) {
  const [sesion, setSesion] = useState(null);
  const [perfil, setPerfil] = useState(null);
  // `cargando` arranca en true: hasta que Supabase resuelva si hay sesión
  // guardada no se puede decidir nada. Sin esta bandera, un refresco de página
  // en /admin parpadea a /login y vuelve — y en una conexión lenta el usuario
  // ve la pantalla de acceso durante un segundo entero.
  const [cargando, setCargando] = useState(true);

  const montado = useRef(true);

  const sincronizarPerfil = useCallback(async (nuevaSesion) => {
    if (!nuevaSesion) {
      if (montado.current) {
        setSesion(null);
        setPerfil(null);
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
      setCargando(false);
      return;
    }

    setSesion(nuevaSesion);
    setPerfil(p);
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
  }, []);

  const valor = useMemo(
    () => ({
      sesion,
      perfil,
      rol: perfil?.role ?? null,
      autenticado: Boolean(sesion && perfil),
      cargando,
      salir,
      // Para cuando un ADMIN se cambia el nombre y la cabecera debe reflejarlo
      // sin recargar la página.
      refrescarPerfil: () => sincronizarPerfil(sesion),
    }),
    [sesion, perfil, cargando, salir, sincronizarPerfil]
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
