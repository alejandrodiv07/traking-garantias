// =====================================================================
//  Edge Function: mfa-enviar-codigo
//  Prime Telecom · Track Garantía
//
//  Conecta el segundo factor (migración ...0003_mfa_email) con Resend.
//  Reemplaza la llamada directa a `generate_mfa_code()` desde el navegador:
//  ANTES esa RPC devolvía la caducidad y el código se leía a mano del SQL
//  Editor (el "modo de pruebas" documentado en la migración); ahora esta
//  función hace el envío real y sigue devolviendo solo la caducidad.
//
//  ---------------------------------------------------------------------
//  DOS CLIENTES, DOS PROPÓSITOS. No es ceremonia, es la frontera de qué
//  puede leer el código y qué no.
//  ---------------------------------------------------------------------
//    · `comoUsuario` (anon key + el JWT de quien llama): invoca
//      `generate_mfa_code()` con la identidad REAL del usuario. Así
//      `auth.uid()` dentro de Postgres es el suyo, y el límite de 5 códigos
//      por 15 minutos que aplica esa función sigue siendo el DEL USUARIO,
//      no un contador compartido por todos los que pasan por esta función.
//    · `admin` (service_role): entra DESPUÉS, solo para leer el `code` que
//      la RPC acaba de insertar y el correo del destinatario. Nunca recibe
//      el JWT del usuario ni decide nada por su cuenta; hace dos SELECT y
//      un POST a Resend.
//
//  El navegador solo ve lo que devuelve el `return` final: la caducidad.
//  El código no cruza la red hacia el cliente en ningún punto.
//
//  ---------------------------------------------------------------------
//  CERO LOGS DEL CÓDIGO
//  ---------------------------------------------------------------------
//  Ni éxito ni error registran `code`. Los logs de una Edge Function son
//  legibles desde el panel de Supabase por cualquiera con acceso al
//  proyecto, y no caducan a los 5 minutos como la fila en la base. Un
//  `console.log` con el código convierte el panel en un segundo sitio
//  desde donde saltarse el segundo factor.
//
//  ---------------------------------------------------------------------
//  SANDBOX DE RESEND (hoy)
//  ---------------------------------------------------------------------
//  `from: onboarding@resend.dev` sin dominio verificado SOLO entrega al
//  correo con el que se creó la cuenta de Resend, sea cual sea el `to` que
//  se le pida. Sirve para validar el flujo de punta a punta; para que
//  llegue a *cualquier* usuario hace falta un dominio propio verificado
//  (SPF/DKIM/DMARC, ya apuntado en la migración) y cambiar el `from`.
//
//  Despliegue:
//      supabase functions deploy mfa-enviar-codigo
//  Secreto ya inyectado por la plataforma: RESEND_API_KEY.
//  (SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY los inyecta
//  Supabase en toda función; ORIGENES_PERMITIDOS es el mismo que usa
//  `admin-crear-usuario`.)
// =====================================================================
import { createClient } from "jsr:@supabase/supabase-js@2";
import { generarCorreoMfa } from "./plantilla-correo.ts";

const REMITENTE = "Prime Telecom <onboarding@resend.dev>";
const MINUTOS_VIGENCIA = 5; // debe coincidir con el default de email_mfa_codes.expires_at

// Lista blanca de orígenes. Nunca "*" con credenciales.
const ORIGENES = (Deno.env.get("ORIGENES_PERMITIDOS") ?? "http://localhost:5173")
  .split(",")
  .map((o) => o.trim());

function cabeceras(origen: string | null) {
  const permitido = origen && ORIGENES.includes(origen) ? origen : ORIGENES[0];
  return {
    "Access-Control-Allow-Origin": permitido,
    "Access-Control-Allow-Headers": "authorization, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Content-Type": "application/json",
  };
}

const json = (cuerpo: unknown, status: number, origen: string | null) =>
  new Response(JSON.stringify(cuerpo), { status, headers: cabeceras(origen) });

/**
 * El `sub` del JWT, sin volver a llamar a la red para pedirlo.
 *
 * No es una decisión de autorización -esa la toma Postgres, vía
 * `auth.uid()`, dentro de `generate_mfa_code()`- es solo CUÁL fila leer
 * después. Confiar en el `sub` aquí es seguro porque el gateway de Supabase
 * ya verificó la firma del JWT antes de invocar esta función (verify_jwt,
 * el mismo mecanismo del que depende toda RLS de este esquema); si esa
 * verificación fallara, la función ni se ejecutaría.
 */
function subDelJwt(auth: string): string | null {
  try {
    const payload = auth.replace(/^Bearer\s+/i, "").split(".")[1];
    const json = JSON.parse(atob(payload.replace(/-/g, "+").replace(/_/g, "/")));
    return typeof json.sub === "string" ? json.sub : null;
  } catch {
    return null;
  }
}

Deno.serve(async (req) => {
  const origen = req.headers.get("origin");

  if (req.method === "OPTIONS") return new Response(null, { headers: cabeceras(origen) });
  if (req.method !== "POST") return json({ error: "Método no permitido" }, 405, origen);

  const auth = req.headers.get("Authorization") ?? "";
  if (!auth.startsWith("Bearer ")) {
    return json({ error: "No autorizado" }, 401, origen);
  }

  const uid = subDelJwt(auth);
  if (!uid) {
    return json({ error: "No autorizado" }, 401, origen);
  }

  const URL_SB = Deno.env.get("SUPABASE_URL")!;

  // ---------------------------------------------------------------
  //  1. EMITIR EL CÓDIGO, con la identidad real del usuario.
  // ---------------------------------------------------------------
  const comoUsuario = createClient(URL_SB, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: auth } },
    auth: { persistSession: false },
  });

  const { data: expiraEn, error: errGenerar } = await comoUsuario.rpc("generate_mfa_code");

  if (errGenerar) {
    // 54000 = program_limit_exceeded: sexto código en 15 minutos (§3.1 de la
    // migración). Se conserva el código de error para que el frontend
    // distinga "espera un poco" de "algo se rompió" sin comparar texto.
    if (errGenerar.code === "54000") {
      return json(
        { error: "Demasiadas solicitudes de código. Espera unos minutos.", code: "54000" },
        429,
        origen,
      );
    }
    return json({ error: "No se pudo generar el código" }, 401, origen);
  }

  // ---------------------------------------------------------------
  //  2. LEER el código y el destinatario. SOLO con service_role.
  // ---------------------------------------------------------------
  const admin = createClient(URL_SB, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  // `generate_mfa_code()` acaba de invalidar cualquier código previo del
  // usuario (un solo código vivo, ver §3.1), así que esta fila es
  // inequívocamente la que se emitió arriba.
  const { data: fila, error: errLeer } = await admin
    .from("email_mfa_codes")
    .select("code")
    .eq("user_id", uid)
    .eq("is_used", false)
    .order("created_at", { ascending: false })
    .limit(1)
    .maybeSingle();

  // El correo se pide a Auth (`getUserById`), no a `profiles.email`: es la
  // fuente de verdad, y sigue siendo válida aunque el espejo de `profiles`
  // no se hubiera sincronizado todavía.
  const { data: usuario, error: errUsuario } = await admin.auth.admin.getUserById(uid);

  if (errLeer || !fila?.code || errUsuario || !usuario?.user?.email) {
    // No se revela CUÁL de las dos lecturas falló: para quien mira desde
    // fuera, es indistinguible de un fallo genérico de envío.
    return json({ error: "No se pudo enviar el código de verificación" }, 500, origen);
  }

  // ---------------------------------------------------------------
  //  3. ENVIAR con Resend.
  // ---------------------------------------------------------------
  const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY");
  if (!RESEND_API_KEY) {
    return json({ error: "El servicio de correo no está configurado" }, 500, origen);
  }

  const correo = generarCorreoMfa({
    code: fila.code,
    minutos: MINUTOS_VIGENCIA,
    nombre: usuario.user.user_metadata?.full_name,
  });

  let respuestaResend: Response;
  try {
    respuestaResend = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${RESEND_API_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        from: REMITENTE,
        to: [usuario.user.email],
        subject: correo.asunto,
        html: correo.html,
        text: correo.texto,
      }),
    });
  } catch {
    // Fallo de red hacia Resend. Igual que un 4xx/5xx de Resend: el
    // contenedor decide, nunca el detalle de la excepción.
    return json({ error: "No se pudo enviar el código de verificación" }, 502, origen);
  }

  if (!respuestaResend.ok) {
    // 5xx EXPLÍCITO y no 200 con un aviso: es la señal que `LoginPage` usa
    // para cerrar la sesión a medio verificar en su `catch` (ver el
    // comentario "Y SI FALLA EL ENVÍO DEL CÓDIGO" en LoginPage.jsx). Un 200
    // aquí dejaría un JWT válido sin ninguna pantalla donde completarlo.
    return json({ error: "No se pudo enviar el código de verificación" }, 502, origen);
  }

  // El navegador recibe ÚNICAMENTE la caducidad. Ni el código ni la
  // respuesta cruda de Resend salen de esta función.
  return json({ expira_en: expiraEn }, 201, origen);
});
