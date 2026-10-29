// =====================================================================
//  Edge Function: admin-crear-usuario
//  Prime Telecom · Track Garantía
//
//  Alta de usuarios internos. Reemplaza a `supabase.auth.signUp()` desde el
//  navegador, que NO sirve aquí por dos razones independientes:
//
//    1. El trigger `handle_new_user` ignora `options.data.role` a propósito
//       (era la vía de escalada de privilegios). Un signUp con
//       role:'JEFE_SERVICIO' crea un TECNICO en silencio.
//    2. `signUp` reemplaza la sesión activa del navegador: el administrador
//       queda logueado como el usuario que acaba de crear.
//
//  Fijar el rol exige `service_role`, que jamás puede estar en el bundle del
//  frontend. Vive aquí, en el servidor, junto con la comprobación de que
//  quien llama es realmente un ADMIN.
//
//  Despliegue:
//      supabase functions deploy admin-crear-usuario
//  (SUPABASE_URL y SUPABASE_SERVICE_ROLE_KEY los inyecta la plataforma.)
// =====================================================================
import { createClient } from "jsr:@supabase/supabase-js@2";

const ROLES_VALIDOS = ["ADMIN", "JEFE_SERVICIO", "TECNICO", "RECEPCION"] as const;
type Rol = (typeof ROLES_VALIDOS)[number];

// Lista blanca de orígenes. Nunca "*" con credenciales.
const ORIGENES = (Deno.env.get("ORIGENES_PERMITIDOS") ?? "http://localhost:5173")
  .split(",")
  .map((o) => o.trim());

// Debe citar TODAS las que manda supabase-js: con una sola ausente el
// navegador bloquea el POST real aunque el preflight devuelva 200 y la UI ve
// un "CORS error" con 0 kB. Mismo bug que tuvo `mfa-enviar-codigo` (29/10/2026).
const CABECERAS_PERMITIDAS =
  "authorization, content-type, apikey, x-client-info, x-application-name";

/**
 * El preflight hace ECO de lo que el navegador pidió
 * (`Access-Control-Request-Headers`): solo dice qué headers puede adjuntar el
 * navegador, la autorización real sigue siendo `mi_rol()` en Postgres. Así
 * ningún header futuro de supabase-js vuelve a romper el alta de usuarios. La
 * lista estática queda de respaldo para respuestas sin preflight.
 */
function cabeceras(origen: string | null, pedidas: string | null = null) {
  const permitido = origen && ORIGENES.includes(origen) ? origen : ORIGENES[0];
  return {
    "Access-Control-Allow-Origin": permitido,
    "Access-Control-Allow-Headers": pedidas?.trim() || CABECERAS_PERMITIDAS,
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Content-Type": "application/json",
  };
}

const json = (cuerpo: unknown, status: number, origen: string | null) =>
  new Response(JSON.stringify(cuerpo), { status, headers: cabeceras(origen) });

Deno.serve(async (req) => {
  const origen = req.headers.get("origin");

  if (req.method === "OPTIONS") {
    return new Response(null, {
      headers: cabeceras(origen, req.headers.get("Access-Control-Request-Headers")),
    });
  }
  if (req.method !== "POST") return json({ error: "Método no permitido" }, 405, origen);

  const auth = req.headers.get("Authorization") ?? "";
  if (!auth.startsWith("Bearer ")) {
    return json({ error: "No autorizado" }, 401, origen);
  }

  const URL_SB = Deno.env.get("SUPABASE_URL")!;

  // ---------------------------------------------------------------
  //  1. ¿QUIÉN LLAMA?  Se pregunta a la BASE, no al JWT.
  // ---------------------------------------------------------------
  //  Con la anon key y el JWT del que llama: `mi_rol()` se evalúa bajo la
  //  identidad real del usuario. Un JWT manipulado no pasa la verificación de
  //  firma de PostgREST, y un rol inventado en los claims da igual porque la
  //  función lee `profiles`, no el token.
  const comoUsuario = createClient(URL_SB, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: auth } },
    auth: { persistSession: false },
  });

  const { data: rolLlamante, error: errRol } = await comoUsuario.rpc("mi_rol");

  if (errRol || rolLlamante !== "ADMIN") {
    // Mismo cuerpo para "sin sesión" y para "sesión sin permiso": no se
    // confirma la existencia de la función a quien no debe usarla.
    return json({ error: "No autorizado" }, 403, origen);
  }

  // ---------------------------------------------------------------
  //  2. VALIDACIÓN DE ENTRADA
  // ---------------------------------------------------------------
  let cuerpo: { email?: string; full_name?: string; role?: string };
  try {
    cuerpo = await req.json();
  } catch {
    return json({ error: "Cuerpo inválido" }, 400, origen);
  }

  const email = String(cuerpo.email ?? "").trim().toLowerCase();
  const fullName = String(cuerpo.full_name ?? "").trim();
  const role = String(cuerpo.role ?? "TECNICO").trim().toUpperCase();

  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email) || email.length > 160) {
    return json({ error: "Correo inválido" }, 422, origen);
  }
  if (fullName.length < 3 || fullName.length > 120) {
    return json({ error: "El nombre debe tener entre 3 y 120 caracteres" }, 422, origen);
  }
  // Lista blanca, no lista negra: un rol desconocido se rechaza, no se acepta.
  if (!ROLES_VALIDOS.includes(role as Rol)) {
    return json({ error: "Rol no válido" }, 422, origen);
  }

  // ---------------------------------------------------------------
  //  3. ALTA CON service_role
  // ---------------------------------------------------------------
  const admin = createClient(URL_SB, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  // Contraseña temporal del CSPRNG del sistema. Se devuelve UNA vez, igual
  // que el token de consulta de las garantías: quien la reciba la entrega en
  // mano y el usuario la cambia al entrar.
  const tmp = generarPassword();

  const { data: creado, error: errCrear } = await admin.auth.admin.createUser({
    email,
    password: tmp,
    // El correo corporativo ya está validado fuera de banda (lo crea el
    // propio departamento de sistemas), igual que asumía el blueprint.
    email_confirm: true,
    user_metadata: { full_name: fullName },
  });

  if (errCrear || !creado?.user) {
    const duplicado = /already|registered|exists/i.test(errCrear?.message ?? "");
    return json(
      { error: duplicado ? "Ya existe una cuenta con ese correo" : "No se pudo crear el usuario" },
      duplicado ? 409 : 500,
      origen,
    );
  }

  // El trigger ya creó el perfil como TECNICO. El rol pedido se fija AHORA,
  // del lado del servidor, después de haber comprobado que quien llama es
  // ADMIN. Este es el único punto del sistema donde un rol distinto de
  // TECNICO se asigna en un alta.
  if (role !== "TECNICO") {
    const { error: errRolFijar } = await admin
      .from("profiles")
      .update({ role })
      .eq("id", creado.user.id);

    if (errRolFijar) {
      // Compensación: el alta y el rol deben ser atómicos desde fuera. Dejar
      // un usuario con el rol equivocado es peor que no crearlo.
      await admin.auth.admin.deleteUser(creado.user.id);
      return json({ error: "No se pudo asignar el rol; alta revertida" }, 500, origen);
    }
  }

  return json(
    {
      usuario: { id: creado.user.id, email, full_name: fullName, role },
      password_temporal: tmp,
      aviso: "Entrégala en persona. No se puede volver a consultar.",
    },
    201,
    origen,
  );
});

/** 18 bytes del CSPRNG en base64url ≈ 144 bits. */
function generarPassword(): string {
  const b = new Uint8Array(18);
  crypto.getRandomValues(b);
  return btoa(String.fromCharCode(...b))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=/g, "");
}
