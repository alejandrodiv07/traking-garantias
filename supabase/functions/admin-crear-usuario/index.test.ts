// @vitest-environment node
/**
 * Contrato CORS de `admin-crear-usuario`, probado contra el handler REAL.
 *
 * Es el mismo fallo que tuvo `mfa-enviar-codigo` (29/10/2026): `supabase-js`
 * manda `apikey`, `x-client-info` y `x-application-name` además de
 * `authorization` y `content-type`; si el preflight no las permite TODAS el
 * navegador bloquea el POST real y la UI ve un "CORS error" con 0 kB aunque
 * el preflight devuelva 200. Aquí se fija antes de que la pantalla de alta de
 * usuarios exista y lo descubra en producción.
 *
 * Se simulan `Deno` y supabase-js (no hay red ni runtime Deno); el handler y
 * su lógica de CORS y de validación son los reales.
 */
import { afterEach, describe, expect, it, vi } from "vitest";

const ORIGEN = "http://localhost:5173";
const CABECERAS_SUPABASE_JS = [
  "authorization",
  "content-type",
  "apikey",
  "x-client-info",
  "x-application-name",
];

type Escenario = {
  rol?: { data: unknown; error: unknown };
  crear?: { data: { user: { id: string } } | null; error: { message: string } | null };
  fijarRol?: { error: unknown };
};

async function cargar(esc: Escenario = {}, env: Record<string, string> = {}) {
  const entorno: Record<string, string> = {
    SUPABASE_URL: "http://sb.test",
    SUPABASE_ANON_KEY: "anon",
    SUPABASE_SERVICE_ROLE_KEY: "service",
    ...env,
  };

  let handler: ((req: Request) => Promise<Response> | Response) | undefined;
  vi.stubGlobal("Deno", {
    serve: (h: typeof handler) => {
      handler = h;
    },
    env: { get: (k: string) => entorno[k] },
  });

  const rol = esc.rol ?? { data: "ADMIN", error: null };
  const crear = esc.crear ?? { data: { user: { id: "nuevo-1" } }, error: null };
  const fijarRol = esc.fijarRol ?? { error: null };
  const borrados: string[] = [];

  vi.resetModules();
  vi.doMock("jsr:@supabase/supabase-js@2", () => ({
    createClient: (_url: string, key: string) => {
      if (key === "anon") return { rpc: async () => rol };
      return {
        auth: {
          admin: {
            createUser: async () => crear,
            deleteUser: async (id: string) => {
              borrados.push(id);
              return { error: null };
            },
          },
        },
        from: () => ({ update: () => ({ eq: async () => fijarRol }) }),
      };
    },
  }));

  await import("./index.ts");
  if (!handler) throw new Error("index.ts no registró un handler en Deno.serve");
  return { handler, borrados };
}

const post = (cuerpo: unknown = valido, headers: Record<string, string> = {}) =>
  new Request("http://fn.test/admin-crear-usuario", {
    method: "POST",
    headers: {
      origin: ORIGEN,
      authorization: "Bearer jwt-de-admin",
      "content-type": "application/json",
      ...headers,
    },
    body: typeof cuerpo === "string" ? cuerpo : JSON.stringify(cuerpo),
  });

const valido = {
  email: "nuevo.tecnico@primetelecom.com",
  full_name: "Nuevo Técnico",
  role: "TECNICO",
};

afterEach(() => {
  vi.unstubAllGlobals();
  vi.doUnmock("jsr:@supabase/supabase-js@2");
});

function exigirCors(res: Response, origen = ORIGEN) {
  expect(res.headers.get("access-control-allow-origin")).toBe(origen);
}

describe("preflight (OPTIONS)", () => {
  it("permite TODAS las cabeceras que manda supabase-js", async () => {
    const { handler } = await cargar();
    const res = await handler(
      new Request("http://fn.test/admin-crear-usuario", {
        method: "OPTIONS",
        headers: {
          origin: ORIGEN,
          "access-control-request-method": "POST",
          "access-control-request-headers": CABECERAS_SUPABASE_JS.join(", "),
        },
      }),
    );

    expect(res.status).toBeLessThan(300);
    exigirCors(res);
    const permitidas = (res.headers.get("access-control-allow-headers") ?? "").toLowerCase();
    for (const c of CABECERAS_SUPABASE_JS) expect(permitidas).toContain(c);
  });

  it("permite una cabecera futura que supabase-js agregue (eco del pedido)", async () => {
    const { handler } = await cargar();
    const res = await handler(
      new Request("http://fn.test/admin-crear-usuario", {
        method: "OPTIONS",
        headers: {
          origin: ORIGEN,
          "access-control-request-method": "POST",
          "access-control-request-headers": "authorization, x-cabecera-nueva-del-futuro",
        },
      }),
    );

    expect(res.headers.get("access-control-allow-headers")!.toLowerCase()).toContain(
      "x-cabecera-nueva-del-futuro",
    );
  });

  it("sin Access-Control-Request-Headers cae a la lista completa de respaldo", async () => {
    const { handler } = await cargar();
    const res = await handler(
      new Request("http://fn.test/admin-crear-usuario", {
        method: "OPTIONS",
        headers: { origin: ORIGEN },
      }),
    );

    const permitidas = (res.headers.get("access-control-allow-headers") ?? "").toLowerCase();
    for (const c of CABECERAS_SUPABASE_JS) expect(permitidas).toContain(c);
  });
});

describe("el POST real: TODA respuesta lleva CORS", () => {
  it("alta correcta: 201 con CORS y la contraseña temporal una sola vez", async () => {
    const { handler } = await cargar();
    const res = await handler(post());

    expect(res.status).toBe(201);
    exigirCors(res);
    const cuerpo = await res.json();
    expect(cuerpo.usuario).toEqual({
      id: "nuevo-1",
      email: valido.email,
      full_name: valido.full_name,
      role: "TECNICO",
    });
    expect(cuerpo.password_temporal).toMatch(/^[A-Za-z0-9_-]{24}$/);
  });

  it("método distinto de POST: 405 con CORS", async () => {
    const { handler } = await cargar();
    const res = await handler(
      new Request("http://fn.test/admin-crear-usuario", {
        method: "GET",
        headers: { origin: ORIGEN },
      }),
    );

    expect(res.status).toBe(405);
    exigirCors(res);
  });

  it("sin Authorization: 401 con CORS", async () => {
    const { handler } = await cargar();
    const res = await handler(post(valido, { authorization: "" }));

    expect(res.status).toBe(401);
    exigirCors(res);
  });

  it("quien llama no es ADMIN: 403 con CORS y no se crea nada", async () => {
    const { handler, borrados } = await cargar({ rol: { data: "TECNICO", error: null } });
    const res = await handler(post());

    expect(res.status).toBe(403);
    exigirCors(res);
    expect(borrados).toEqual([]);
  });

  it("mi_rol() falla: 403 con CORS", async () => {
    const { handler } = await cargar({ rol: { data: null, error: { code: "42501" } } });
    const res = await handler(post());

    expect(res.status).toBe(403);
    exigirCors(res);
  });

  it("cuerpo que no es JSON: 400 con CORS", async () => {
    const { handler } = await cargar();
    const res = await handler(post("esto no es json"));

    expect(res.status).toBe(400);
    exigirCors(res);
  });

  it.each([
    ["correo inválido", { ...valido, email: "no-es-correo" }],
    ["nombre demasiado corto", { ...valido, full_name: "ab" }],
    ["rol desconocido (lista blanca)", { ...valido, role: "SUPERUSUARIO" }],
  ])("%s: 422 con CORS", async (_nombre, cuerpo) => {
    const { handler } = await cargar();
    const res = await handler(post(cuerpo));

    expect(res.status).toBe(422);
    exigirCors(res);
  });

  it("correo ya registrado: 409 con CORS", async () => {
    const { handler } = await cargar({
      crear: { data: null, error: { message: "User already registered" } },
    });
    const res = await handler(post());

    expect(res.status).toBe(409);
    exigirCors(res);
  });

  it("falla genérica al crear: 500 con CORS", async () => {
    const { handler } = await cargar({
      crear: { data: null, error: { message: "boom" } },
    });
    const res = await handler(post());

    expect(res.status).toBe(500);
    exigirCors(res);
  });

  it("no se pudo fijar el rol: se revierte el alta (deleteUser) y 500 con CORS", async () => {
    const { handler, borrados } = await cargar({ fijarRol: { error: { code: "XX000" } } });
    const res = await handler(post({ ...valido, role: "JEFE_SERVICIO" }));

    expect(res.status).toBe(500);
    exigirCors(res);
    expect(borrados).toEqual(["nuevo-1"]);
  });
});

describe("lista blanca de orígenes", () => {
  it("un origen permitido por ORIGENES_PERMITIDOS se refleja tal cual", async () => {
    const { handler } = await cargar(undefined, {
      ORIGENES_PERMITIDOS: "https://app.primetelecom.com, http://localhost:5173",
    });
    const res = await handler(post(valido, { origin: "https://app.primetelecom.com" }));

    exigirCors(res, "https://app.primetelecom.com");
  });

  it("un origen NO permitido jamás se refleja (ni con *)", async () => {
    const { handler } = await cargar();
    const res = await handler(post(valido, { origin: "https://evil.example" }));

    const permitido = res.headers.get("access-control-allow-origin");
    expect(permitido).not.toBe("https://evil.example");
    expect(permitido).not.toBe("*");
  });
});
