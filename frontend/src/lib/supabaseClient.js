/**
 * Cliente de Supabase — instancia única de toda la SPA.
 *
 * Sustituye a `src/api/client.js`, que hablaba con el backend Flask ahora
 * archivado. Ese fichero y `features/auth/authApi.js` quedan sin uso.
 *
 * ---------------------------------------------------------------------------
 * RIESGO RESIDUAL ACEPTADO, DECLARADO AQUÍ PORQUE ES AQUÍ DONDE VIVE
 * ---------------------------------------------------------------------------
 * El AUTH_BLUEPRINT (directiva 5) prohibía `localStorage` para el token de
 * sesión: la cookie era `HttpOnly` y el JS nunca la veía. Con Supabase Auth
 * eso deja de ser cierto. `supabase-js` guarda el JWT en almacenamiento del
 * navegador **legible por JavaScript**; no hay opción de `HttpOnly` sin mover
 * la autenticación a un servidor (`@supabase/ssr`), que es justo lo que se
 * decidió no construir.
 *
 * Consecuencia honesta, para el capítulo de la tesis: un XSS con éxito en esta
 * SPA roba la sesión. Antes no podía. Es el precio real del trade-off de TTM,
 * y conviene escribirlo con esas palabras en lugar de omitirlo.
 *
 * Se acota en dos frentes:
 *
 *   1. `sessionStorage` por defecto (ver `crearAlmacenamiento`). El token
 *      muere al cerrar la pestaña y no se comparte entre pestañas, así que la
 *      ventana de robo es mucho más corta que con `localStorage`. Solo se usa
 *      `localStorage` si el usuario marca "Recordarme", y eso es una decisión
 *      suya, informada y reversible.
 *   2. Content-Security-Policy estricta en el `index.html` y en las cabeceras
 *      del hosting. Sin XSS no hay robo de token; la CSP es ahora la primera
 *      línea de defensa, no un extra.
 *
 * `flowType: 'pkce'` porque el intercambio de código es resistente a
 * interceptación y es el que exigen los enlaces de invitación y de
 * recuperación que emite la Edge Function de alta de usuarios.
 */
import { createClient } from "@supabase/supabase-js";

const URL = import.meta.env.VITE_SUPABASE_URL;
const ANON_KEY = import.meta.env.VITE_SUPABASE_ANON_KEY;

// Fallar aquí, al arrancar, y no en el primer login con un error de red
// indescifrable. Un `.env.local` sin cargar es el fallo nº 1 de integración.
if (!URL || !ANON_KEY) {
  throw new Error(
    "Faltan VITE_SUPABASE_URL o VITE_SUPABASE_ANON_KEY. " +
      "Revisa frontend/.env.local y reinicia `npm run dev` " +
      "(Vite solo lee el .env al arrancar)."
  );
}

// La anon key es pública por diseño: va en el bundle y cualquiera la ve. Lo
// que protege los datos es la RLS del esquema, no el secreto de esta clave.
// La que JAMÁS puede aparecer aquí es `service_role`: bypassea toda la RLS y
// convierte el bundle de JavaScript en una llave maestra de la base de datos.
//
// Confundir las dos al copiar del panel es un error de un solo clic y no da
// ningún síntoma: todo "funciona" —de hecho funciona DE MÁS, porque deja de
// aplicarse la RLS— hasta que alguien abre las DevTools. Por eso se comprueba
// en vez de confiar. Las dos formas que tiene una clave de Supabase:
//   · JWT legacy   -> el rol viaja en el payload base64url del propio token
//   · clave nueva  -> prefijo `sb_publishable_` (pública) / `sb_secret_` (no)
function esClaveSecreta(clave) {
  if (clave.startsWith("sb_secret_")) return true;
  const partes = clave.split(".");
  if (partes.length !== 3) return false;
  try {
    const payload = JSON.parse(
      atob(partes[1].replace(/-/g, "+").replace(/_/g, "/"))
    );
    return payload?.role === "service_role";
  } catch {
    return false; // no es un JWT legible: se deja pasar y fallará al usarse
  }
}

if (esClaveSecreta(ANON_KEY)) {
  throw new Error(
    "VITE_SUPABASE_ANON_KEY contiene una clave SECRETA (service_role). " +
      "Esa clave bypassea toda la seguridad a nivel de fila y nunca debe " +
      "llegar al navegador. Usa la clave `anon` / `publishable` del panel, " +
      "y rota la secreta que acabas de exponer."
  );
}

const CLAVE_PERSISTENCIA = "pt.recordarme";

/**
 * Adaptador de almacenamiento que decide entre `sessionStorage` y
 * `localStorage` en cada operación, según la preferencia que el formulario de
 * login haya dejado apuntada. Se resuelve en caliente y no al construir el
 * cliente, porque el cliente se crea antes de que el usuario marque nada.
 */
function crearAlmacenamiento() {
  const destino = () => {
    try {
      return localStorage.getItem(CLAVE_PERSISTENCIA) === "1"
        ? localStorage
        : sessionStorage;
    } catch {
      // Navegador con almacenamiento bloqueado (modo privado estricto,
      // política corporativa). La sesión vivirá solo en memoria.
      return null;
    }
  };

  return {
    getItem: (k) => {
      try {
        // Se lee de los dos: al recargar no sabemos cuál se usó al firmar.
        return sessionStorage.getItem(k) ?? localStorage.getItem(k);
      } catch {
        return null;
      }
    },
    setItem: (k, v) => {
      try {
        destino()?.setItem(k, v);
      } catch {
        /* sin almacenamiento: sesión solo en memoria */
      }
    },
    removeItem: (k) => {
      // Se borra de AMBOS. Un logout que deja el token en el almacén que no
      // tocó no es un logout.
      try {
        sessionStorage.removeItem(k);
        localStorage.removeItem(k);
      } catch {
        /* nada que limpiar */
      }
    },
  };
}

/** Marca la preferencia de persistencia ANTES de llamar a signInWithPassword. */
export function recordarSesion(recordar) {
  try {
    if (recordar) localStorage.setItem(CLAVE_PERSISTENCIA, "1");
    else localStorage.removeItem(CLAVE_PERSISTENCIA);
  } catch {
    /* sin almacenamiento: se ignora la preferencia */
  }
}

export const supabase = createClient(URL, ANON_KEY, {
  auth: {
    flowType: "pkce",
    persistSession: true,
    autoRefreshToken: true,
    detectSessionInUrl: true,
    storageKey: "pt.auth",
    storage: crearAlmacenamiento(),
  },
  global: {
    headers: { "x-application-name": "prime-telecom-track-garantia" },
  },
});
