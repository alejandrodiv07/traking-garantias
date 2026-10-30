// @vitest-environment node
/**
 * Contrato CORS de `mfa-enviar-codigo`, probado contra el handler REAL.
 *
 * Por qué a nivel de handler y no de una función suelta: el bug que el
 * navegador ve como "CORS error" con 0 kB NO es una cabecera mal escrita sino
 * una respuesta que nunca llega con cabeceras (el handler lanza antes de
 * construirla y el gateway contesta un 500 pelado, sin Access-Control-*). Un
 * test que solo mirase la lista estática de cabeceras lo dejaría pasar.
 *
 * Qué se simula y por qué:
 *   · `Deno`            -> no existe en Node; se captura el handler de `Deno.serve`.
 *   · supabase-js       -> la red no es lo que se prueba; el fake distingue la
 *                          anon key (RPC con la identidad del usuario) de la
 *                          service_role (lectura del código y del correo).
 *   · `fetch` (Resend)  -> para forzar éxito y fallo del envío.
 * Lo que NO se simula: el handler, la lógica de CORS y la plantilla del correo.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const ORIGEN = "http://localhost:5173";
const CABECERAS_SUPABASE_JS = [
  "authorization",
  "content-type",
  "apikey",
  "x-client-info",
  "x-application-name",
];

/** JWT con firma falsa: el handler solo lee el `sub` (la firma la verifica el gateway). */
function jwt(sub = "user-1") {
  const b64 = (o: unknown) =>
    Buffer.from(JSON.stringify(o)).toString("base64url");
  return `${b64({ alg: "HS256" })}.${b64({ sub })}.firma`;
}

type Escenario = {
  rpc?: { data: unknown; error: { code?: string } | null };
  fila?: { data: { code: string } | null; error: unknown };
  usuario?: { data: { user: { email: string } | null }; error: unknown };
};

const CODIGO_SECRETO = "482913";

function instalarFakes(esc: Escenario = {}, env: Record<string, string> = {}) {
  const entorno: Record<string, string> = {
    SUPABASE_URL: "http://sb.test",
    SUPABASE_ANON_KEY: "anon",
    SUPABASE_SERVICE_ROLE_KEY: "service",
    RESEND_API_KEY: "re_test",
    ...env,
  };

  let handler: ((req: Request) => Promise<Response> | Response) | undefined;
  vi.stubGlobal("Deno", {
    serve: (h: typeof handler) => {
      handler = h;
    },
    env: { get: (k: string) => entorno[k] },
  });

  const rpc = esc.rpc ?? { data: "2026-10-29T18:05:00Z", error: null };
  const fila = esc.fila ?? { data: { code: CODIGO_SECRETO }, error: null };
  const usuario = esc.usuario ?? {
    data: { user: { email: "samuel.admin2@primetelecom.com" } },
    error: null,
  };

  vi.doMock("jsr:@supabase/supabase-js@2", () => ({
    createClient: (_url: string, key: string) => {
      if (key === "anon") return { rpc: async () => rpc };
      const cadena: Record<string, unknown> = {};
      for (const m of ["select", "eq", "order", "limit"]) cadena[m] = () => cadena;
      cadena.maybeSingle = async () => fila;
      return {
        from: () => cadena,
        auth: { admin: { getUserById: async () => usuario } },
      };
    },
  }));

  return {
    handler: () => {
      if (!handler) throw new Error("index.ts no registró un handler en Deno.serve");
      return handler;
    },
  };
}

async function cargar(esc?: Escenario, env?: Record<string, string>) {
  vi.resetModules();
  const fakes = instalarFakes(esc, env);
  await import("./index.ts");
  return fakes.handler();
}

const post = (headers: Record<string, string> = {}) =>
  new Request("http://fn.test/mfa-enviar-codigo", {
    method: "POST",
    headers: {
      origin: ORIGEN,
      authorization: `Bearer ${jwt()}`,
      "content-type": "application/json",
      ...headers,
    },
    body: "{}",
  });

beforeEach(() => {
  vi.stubGlobal(
    "fetch",
    vi.fn(async () => new Response('{"id":"abc"}', { status: 200 })),
  );
});

afterEach(() => {
  vi.unstubAllGlobals();
  vi.doUnmock("jsr:@supabase/supabase-js@2");
});

/** Toda respuesta que el navegador pueda recibir tiene que traer permiso CORS. */
function exigirCors(res: Response, origen = ORIGEN) {
  expect(res.headers.get("access-control-allow-origin")).toBe(origen);
}

describe("preflight (OPTIONS)", () => {
  it("permite TODAS las cabeceras que manda supabase-js", async () => {
    const handler = await cargar();
    const res = await handler(
      new Request("http://fn.test/mfa-enviar-codigo", {
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
    const handler = await cargar();
    const res = await handler(
      new Request("http://fn.test/mfa-enviar-codigo", {
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
    const handler = await cargar();
    const res = await handler(
      new Request("http://fn.test/mfa-enviar-codigo", {
        method: "OPTIONS",
        headers: { origin: ORIGEN },
      }),
    );

    const permitidas = (res.headers.get("access-control-allow-headers") ?? "").toLowerCase();
    for (const c of CABECERAS_SUPABASE_JS) expect(permitidas).toContain(c);
  });
});

describe("el POST real: TODA respuesta lleva CORS (si no, el navegador ve 'CORS error')", () => {
  it("éxito: 201, solo la caducidad en el cuerpo y CORS", async () => {
    const handler = await cargar();
    const res = await handler(post());

    expect(res.status).toBe(201);
    exigirCors(res);
    const texto = await res.text();
    expect(JSON.parse(texto)).toEqual({ expira_en: "2026-10-29T18:05:00Z" });
    expect(texto).not.toContain(CODIGO_SECRETO);
  });

  it("el correo va al usuario que inicia sesión (sin destinatario fijo)", async () => {
    const handler = await cargar({
      usuario: { data: { user: { email: "otra.persona@primetelecom.com" } }, error: null },
    });
    const res = await handler(post());

    expect(res.status).toBe(201);
    const llamada = vi.mocked(fetch).mock.calls[0];
    expect(llamada[0]).toBe("https://api.resend.com/emails");
    const cuerpo = JSON.parse(String((llamada[1] as RequestInit).body));
    expect(cuerpo.to).toEqual(["otra.persona@primetelecom.com"]);
  });

  it("sin cabecera Authorization: 401 con CORS", async () => {
    const handler = await cargar();
    const res = await handler(post({ authorization: "" }));

    expect(res.status).toBe(401);
    exigirCors(res);
  });

  it("JWT ilegible: 401 con CORS", async () => {
    const handler = await cargar();
    const res = await handler(post({ authorization: "Bearer basura" }));

    expect(res.status).toBe(401);
    exigirCors(res);
  });

  it("método distinto de POST: 405 con CORS", async () => {
    const handler = await cargar();
    const res = await handler(
      new Request("http://fn.test/mfa-enviar-codigo", {
        method: "GET",
        headers: { origin: ORIGEN },
      }),
    );

    expect(res.status).toBe(405);
    exigirCors(res);
  });

  it("sexto código en 15 minutos (54000): 429 con CORS y el código de error", async () => {
    const handler = await cargar({ rpc: { data: null, error: { code: "54000" } } });
    const res = await handler(post());

    expect(res.status).toBe(429);
    exigirCors(res);
    expect((await res.json()).code).toBe("54000");
  });

  it("la RPC falla por otra causa: 401 con CORS", async () => {
    const handler = await cargar({ rpc: { data: null, error: { code: "42501" } } });
    const res = await handler(post());

    expect(res.status).toBe(401);
    exigirCors(res);
  });

  it("no se encuentra el código emitido: 500 con CORS", async () => {
    const handler = await cargar({ fila: { data: null, error: null } });
    const res = await handler(post());

    expect(res.status).toBe(500);
    exigirCors(res);
  });

  it("Resend responde 403: 502 con CORS y sin filtrar el código", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => new Response('{"message":"domain"}', { status: 403 })),
    );
    const handler = await cargar();
    const res = await handler(post());

    expect(res.status).toBe(502);
    exigirCors(res);
    expect(await res.text()).not.toContain(CODIGO_SECRETO);
  });

  it("Resend inalcanzable (fallo de red): 502 con CORS", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => {
        throw new TypeError("fetch failed");
      }),
    );
    const handler = await cargar();
    const res = await handler(post());

    expect(res.status).toBe(502);
    exigirCors(res);
  });

  it("sin RESEND_API_KEY: 500 con CORS", async () => {
    const handler = await cargar(undefined, { RESEND_API_KEY: "" });
    const res = await handler(post());

    expect(res.status).toBe(500);
    exigirCors(res);
  });
});

describe("lista blanca de orígenes", () => {
  it("un origen permitido por ORIGENES_PERMITIDOS se refleja tal cual", async () => {
    const handler = await cargar(undefined, {
      ORIGENES_PERMITIDOS: "https://app.primetelecom.com, http://localhost:5173",
    });
    const res = await handler(post({ origin: "https://app.primetelecom.com" }));

    exigirCors(res, "https://app.primetelecom.com");
  });

  it("un origen NO permitido jamás se refleja (ni con *)", async () => {
    const handler = await cargar();
    const res = await handler(post({ origin: "https://evil.example" }));

    const permitido = res.headers.get("access-control-allow-origin");
    expect(permitido).not.toBe("https://evil.example");
    expect(permitido).not.toBe("*");
  });
});

describe("el correo", () => {
  it("el código viaja SOLO a Resend, nunca en la respuesta al navegador", async () => {
    const fetchSimulado = vi.fn(async () => new Response("{}", { status: 200 }));
    vi.stubGlobal("fetch", fetchSimulado);
    const handler = await cargar();
    const res = await handler(post());

    expect(await res.text()).not.toContain(CODIGO_SECRETO);
    expect(fetchSimulado).toHaveBeenCalledTimes(1);
    const [url, init] = fetchSimulado.mock.calls[0] as unknown as [string, RequestInit];
    expect(url).toBe("https://api.resend.com/emails");
    // La plantilla agrupa el código en bloques de 3 ("482 913") para leerlo mejor.
    expect(String(init.body)).toContain("482 913");
  });
});
