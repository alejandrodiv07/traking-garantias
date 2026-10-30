/**
 * Servicio de autenticación — Supabase Auth.
 *
 * Sustituye a `authApi.js` (backend Flask, archivado). Sigue siendo la única
 * puerta: ningún componente llama a `supabase.auth.*` directamente.
 *
 * ---------------------------------------------------------------------------
 * Lo que este módulo conserva del blueprint original
 * ---------------------------------------------------------------------------
 * - **Mensaje único ante cualquier fallo** (directiva 4). Supabase distingue
 *   internamente "Invalid login credentials" de "Email not confirmed", y esa
 *   distinción es un oráculo de enumeración servido en bandeja. Aquí las
 *   causas se colapsan a un solo texto antes de salir de la función. El
 *   detalle real no se registra ni en consola: `console.error(error.message)`
 *   reconstruye el oráculo para cualquiera que abra las DevTools.
 * - **El rol no se cree, se consulta.** El JWT de Supabase no lleva el rol, y
 *   aunque lo llevara sería un dato que el cliente puede decodificar y —en un
 *   navegador manipulado— fingir. El rol se lee de `profiles` con la anon key,
 *   sujeto a RLS, y sirve SOLO para decidir qué pinta la interfaz. La
 *   autorización real la aplica Postgres en cada consulta.
 * - **Perfil ausente = sesión revocada.** Ver `obtenerPerfil`.
 */
import { supabase, recordarSesion } from "../../lib/supabaseClient.js";
import { limpiarBorradores } from "../registro/borrador.js";

export const Resultado = Object.freeze({
  OK: "OK",
  INVALIDO: "INVALIDO",
  LIMITADO: "LIMITADO",
  ERROR: "ERROR",
});

const MENSAJE_GENERICO = "Credenciales incorrectas";

export const RUTA_POR_ROL = Object.freeze({
  ADMIN: "/garantias",
  JEFE_SERVICIO: "/garantias",
  TECNICO: "/garantias",
  RECEPCION: "/garantias",
});

/** Ruta de aterrizaje del rol. `/sin-acceso` si el rol es desconocido. */
export function rutaDeInicio(rol) {
  return RUTA_POR_ROL[rol] ?? "/sin-acceso";
}

/**
 * Lee el perfil del usuario autenticado.
 *
 * Devuelve `null` en tres casos que la RLS vuelve indistinguibles a propósito:
 * el perfil no existe, la cuenta está desactivada (`is_active = false`, y la
 * policy `prof_select_activos` deja de devolver la fila), o el JWT ya no vale.
 *
 * Los tres significan lo mismo para el frontend: esta sesión no debe seguir
 * abierta. Es, de hecho, el mecanismo de baja: un ADMIN pone `is_active=false`
 * y el usuario queda fuera en su siguiente arranque, sin tocar Supabase Auth.
 */
export async function obtenerPerfil() {
  const { data: auth } = await supabase.auth.getUser();
  const uid = auth?.user?.id;
  if (!uid) return null;

  // EL `.eq("id", uid)` NO ES OPCIONAL, aunque parezca redundante con la RLS.
  // La policy `prof_select` deja ver también los perfiles de los compañeros
  // (la interfaz necesita los nombres de los técnicos), así que sin el filtro
  // esta consulta devuelve N filas y `.maybeSingle()` LANZA
  // ("multiple rows returned"). El error se traduce en perfil nulo, y el
  // perfil nulo dispara el signOut: todos los inicios de sesión fallarían.
  // La RLS acota lo que PUEDE verse; la consulta dice lo que QUIERE verse.
  const { data, error } = await supabase
    .from("profiles")
    .select("id, full_name, email, role, is_active")
    .eq("id", uid)
    .maybeSingle();

  if (error || !data || !data.is_active) return null;
  return data;
}

/**
 * Inicio de sesión.
 *
 * Dos fases, y la segunda no es opcional: autenticar dice *quién* eres,
 * `obtenerPerfil` dice *si sigues siendo alguien aquí dentro*. Si la segunda
 * falla se revoca la sesión recién creada; dejar viva una sesión sin perfil
 * es dejar entrar a una cuenta dada de baja.
 */
export async function iniciarSesion({ email, password, recordar = false }) {
  recordarSesion(recordar);

  const identificador = String(email ?? "").trim().toLowerCase();

  try {
    const { data, error } = await supabase.auth.signInWithPassword({
      email: identificador,
      password,
    });

    if (error) {
      // 429: cuota agotada. Merece mensaje propio, porque si no el usuario
      // legítimo reintenta y agrava su propio bloqueo. No revela nada: el
      // límite de Supabase es por IP, no por existencia de la cuenta.
      if (error.status === 429) {
        return {
          resultado: Resultado.LIMITADO,
          mensaje: "Demasiados intentos. Espera unos minutos antes de reintentar.",
        };
      }
      // Todo lo demás —contraseña mala, correo inexistente, correo sin
      // confirmar, usuario baneado— comparte texto. A propósito.
      return { resultado: Resultado.INVALIDO, mensaje: MENSAJE_GENERICO };
    }

    const perfil = await obtenerPerfil();

    if (!perfil) {
      await supabase.auth.signOut();
      return {
        resultado: Resultado.INVALIDO,
        // Mismo texto que un fallo de contraseña: quien sondea correos no
        // aprende que "esa cuenta existe pero está desactivada".
        mensaje: MENSAJE_GENERICO,
      };
    }

    return { resultado: Resultado.OK, sesion: data.session, perfil };
  } catch {
    // Fallo de red o de CORS. `fetch` no deja distinguirlos desde el cliente.
    return {
      resultado: Resultado.ERROR,
      mensaje: "No se pudo contactar con el servidor. Revisa tu conexión.",
    };
  }
}

/**
 * ===========================================================================
 * SEGUNDO FACTOR POR CORREO
 * ===========================================================================
 * Tres RPC, y ninguna devuelve el código. Eso no es un detalle de estilo: si
 * `generate_mfa_code` devolviera el número, quien tiene la contraseña robada
 * —el único atacante contra el que existe este paso— lo leería en la pestaña
 * Network y verificaría sin abrir el correo. El código se queda en Postgres y
 * lo lee solo el emisor del correo, con `service_role`, del lado del servidor.
 *
 * Y la pantalla del código no es la que protege nada: cuando llegas aquí el
 * JWT ya existe y ya es válido. Lo que hace real al segundo factor es que
 * `mi_rol()` exige `mfa_ok()` en la base (migración ...0003_mfa_email §6):
 * sin verificar, toda consulta a garantías devuelve cero filas.
 */

/**
 * Emite un código y lo manda por correo. Devuelve CUÁNDO caduca (no el
 * código): el navegador nunca lo ve, ni en este `data` ni en la pestaña
 * Network.
 *
 * Pasa por la Edge Function `mfa-enviar-codigo` y no por la RPC directa.
 * Dentro, la función llama a esta misma RPC con el JWT de quien llama (así
 * `auth.uid()` y el límite de 5 por 15 minutos siguen siendo los del
 * usuario, no un contador compartido) y manda el código a Resend con
 * service_role. Un 5xx de la función (Resend caído, sin API key) se trata
 * IGUAL que el 429 de cuota: como fallo del envío, nunca como éxito.
 */
export async function solicitarCodigoMfa() {
  const { data, error } = await supabase.functions.invoke("mfa-enviar-codigo");

  if (error) {
    // supabase-js no parsea el cuerpo de un error HTTP de la función: hay
    // que leerlo del Response crudo que cuelga de `error.context`. Si esa
    // lectura falla (la función no respondió con JSON, o no hay `context`),
    // se cae al mensaje genérico y no se revienta mostrando un error crudo.
    const cuerpo = await error.context?.json?.().catch(() => null);
    // 54000 = program_limit_exceeded: sexto código en 15 minutos. Merece
    // mensaje propio, igual que el 429 del login: el usuario legítimo que
    // reintenta a ciegas solo agrava su propio bloqueo.
    const e = new Error(
      cuerpo?.code === "54000"
        ? "Demasiadas solicitudes de código. Espera unos minutos."
        : "No se pudo enviar el código de verificación."
    );
    e.code = cuerpo?.code;
    throw e;
  }

  return { expiraEn: data?.expira_en };
}

/**
 * Verifica el código. Lanza ante CUALQUIER fallo, con un solo mensaje.
 *
 * `verify_mfa_code` devuelve false tanto si el código está mal como si venció
 * o si ya se usó. Esa indistinción es deliberada en la base y se conserva
 * aquí: decirle al atacante "vencido" en vez de "incorrecto" le confirma que
 * acertó el número pero llegó tarde.
 */
export async function verificarCodigoMfa(codigo) {
  const { data, error } = await supabase.rpc("verify_mfa_code", {
    p_code: String(codigo ?? "").trim(),
  });

  if (error || data !== true) {
    throw new Error("Código incorrecto o vencido");
  }
  return true;
}

/**
 * ¿Esta sesión superó el segundo factor?
 *
 * Se consulta a la BASE y no a un flag de React porque el permiso vive en la
 * base: está anclado al `session_id` del JWT. Un `mfaOk = true` en el estado
 * del navegador no abre ninguna fila, y un usuario que lo ponga a mano en las
 * DevTools verá los paneles vacíos.
 */
export async function mfaVerificada() {
  const { data, error } = await supabase.rpc("mfa_ok");
  return !error && data === true;
}

/**
 * Cierra la sesión. No lanza nunca.
 *
 * `scope: "local"` NO basta: dejaría vivo el refresh token en el servidor.
 * El scope global revoca la sesión en Supabase, que es lo que hace que un
 * logout signifique algo. Si la llamada de red falla igual se limpia el
 * almacenamiento: dejar al usuario dentro porque el servidor no contestó es
 * peor que cerrar de más.
 */
export async function cerrarSesion() {
  try {
    await supabase.auth.signOut({ scope: "global" });
  } catch {
    /* silencio deliberado */
  } finally {
    recordarSesion(false);
    // El borrador del asistente guarda datos personales del CLIENTE y las
    // laptops del taller son compartidas: al cerrar sesión se va TODO.
    limpiarBorradores();
  }
}

/** Sesión vigente al arrancar la SPA, o `null`. */
export async function sesionActual() {
  const { data } = await supabase.auth.getSession();
  return data?.session ?? null;
}

/**
 * Alta de usuario — SOLO para la vista de administrador.
 *
 * ===========================================================================
 * POR QUÉ ESTO NO ES `supabase.auth.signUp()`
 * ===========================================================================
 * Dos razones independientes, y cada una basta:
 *
 * 1. EL ROL DEL METADATA SE IGNORA. El trigger `handle_new_user` fuerza
 *    'TECNICO' como CONSTANTE, precisamente porque `options.data` lo controla
 *    quien llama y era la vía de escalada de privilegios que se cerró en la
 *    migración. Un `signUp({ options: { data: { role: 'JEFE_SERVICIO' } } })`
 *    no falla: crea un TECNICO en silencio. Un permiso que se concede en
 *    silencio y no se aplica es peor que un error.
 *
 * 2. `signUp` DESLOGUEA AL ADMINISTRADOR. `supabase-js` sustituye la sesión
 *    activa por la del usuario recién creado. El admin termina operando como
 *    el técnico que acaba de dar de alta, sin aviso.
 *
 * La vía correcta necesita `service_role`, que no puede vivir en el navegador.
 * De ahí la Edge Function `admin-crear-usuario`: valida contra la base que
 * quien llama es ADMIN, crea el usuario con la API de administración y fija
 * el rol del lado del servidor. El navegador solo manda su propio JWT.
 * ===========================================================================
 */
export async function invitarUsuario({ email, fullName, role }) {
  const { data, error } = await supabase.functions.invoke("admin-crear-usuario", {
    body: {
      email: String(email ?? "").trim().toLowerCase(),
      full_name: String(fullName ?? "").trim(),
      role,
    },
  });

  if (error) {
    return {
      resultado: Resultado.ERROR,
      mensaje: data?.error ?? "No se pudo crear el usuario",
    };
  }
  return { resultado: Resultado.OK, usuario: data?.usuario };
}

/**
 * Cambia el rol de un usuario existente.
 *
 * Aquí sí basta con PostgREST: la policy `prof_update_admin` y el trigger
 * `proteger_columnas_de_profile` ya restringen esto a un ADMIN, y el trigger
 * además le impide cambiarse el rol a sí mismo (para que no quede un sistema
 * sin ningún administrador). El cliente no comprueba nada: si el que llama no
 * es ADMIN, la operación afecta a cero filas o lanza. Esa es la prueba de que
 * la autorización está en la base y no en la interfaz.
 */
export async function cambiarRol({ userId, role }) {
  const { error } = await supabase
    .from("profiles")
    .update({ role })
    .eq("id", userId);

  if (error) {
    return { resultado: Resultado.ERROR, mensaje: "No se pudo cambiar el rol" };
  }
  return { resultado: Resultado.OK };
}

/** Baja lógica. Corta el acceso en el siguiente arranque (ver `obtenerPerfil`). */
export async function desactivarUsuario(userId) {
  const { error } = await supabase
    .from("profiles")
    .update({ is_active: false })
    .eq("id", userId);

  return error
    ? { resultado: Resultado.ERROR, mensaje: "No se pudo desactivar la cuenta" }
    : { resultado: Resultado.OK };
}
