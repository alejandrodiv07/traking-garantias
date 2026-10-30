// @vitest-environment node
/**
 * Contrato de la Edge Function `limpiar-huerfanos` (Tarea 14 del plan).
 *
 * Qué se prueba: la autorización por secreto de cron y el comportamiento
 * borrar/simular. Cómo: el handler real, con `Deno` y supabase-js
 * simulados (mismo patrón que mfa-enviar-codigo): no hay runtime Deno
 * aquí ni en CI.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const SECRETO = "cron-secreto";
const HUERFANOS = ["hu25.jpg", "hu48.jpg"];

type Escenario = {
  /** lo que devuelve la RPC listar_huerfanos */
  huerfanos?: { data: string[] | null; error: unknown };
  /** lo que devuelve storage.remove */
  remove?: { error: unknown };
};

function instalarFakes(esc: Escenario = {}) {
  const entorno: Record<string, string> = {
    SUPABASE_URL: "http://sb.test",
    SUPABASE_SERVICE_ROLE_KEY: "service",
    LIMPIEZA_SECRET: SECRETO,
  };

  let handler: ((req: Request) => Promise<Response> | Response) | undefined;
  vi.stubGlobal("Deno", {
    serve: (h: typeof handler) => {
      handler = h;
    },
    env: { get: (k: string) => entorno[k] },
  });

  const llamadasRemove: string[][] = [];
  // la RPC devuelve TABLE(nombre text): filas {"nombre": …}
  const rpc = esc.huerfanos ?? {
    data: HUERFANOS.map((n) => ({ nombre: n })),
    error: null,
  };
  const remove = esc.remove ?? { error: null };

  vi.doMock("jsr:@supabase/supabase-js@2", () => ({
    createClient: () => ({
      rpc: async (fn: string) => {
        if (fn !== "listar_huerfanos") {
          return { data: null, error: { message: "función inesperada" } };
        }
        return rpc;
      },
      storage: {
        from: (bucket: string) => ({
          bucket: () => bucket,
          remove: async (nombres: string[]) => {
            llamadasRemove.push(nombres);
            return remove;
          },
        }),
      },
    }),
  }));

  return {
    handler: () => {
      if (!handler) throw new Error("index.ts no registró un handler en Deno.serve");
      return handler;
    },
    llamadasRemove: () => llamadasRemove,
  };
}

async function cargar(esc?: Escenario) {
  vi.resetModules();
  const fakes = instalarFakes(esc);
  await import("./index.ts");
  return fakes;
}

const post = (url: string, headers: Record<string, string> = {}) =>
  new Request(url, {
    method: "POST",
    headers: { "content-type": "application/json", ...headers },
    body: "{}",
  });

afterEach(() => {
  vi.unstubAllGlobals();
  vi.doUnmock("jsr:@supabase/supabase-js@2");
});

const URL_BASE = "http://fn.test/limpiar-huerfanos";

describe("autorización", () => {
  it("sin x-cron-secret responde 401", async () => {
    const fakes = await cargar();
    const res = await fakes.handler()(post(URL_BASE));
    expect(res.status).toBe(401);
  });

  it("con un secreto equivocado responde 401", async () => {
    const fakes = await cargar();
    const res = await fakes.handler()(post(URL_BASE, { "x-cron-secret": "mal" }));
    expect(res.status).toBe(401);
  });
});

describe("simulación", () => {
  it("con ?simular=1 informa los nombres y NO llama a remove", async () => {
    const fakes = await cargar();
    const res = await handlerSimular(fakes);
    const cuerpo = await res.json();
    expect(cuerpo).toEqual({
      huerfanos: 2,
      borrados: 0,
      simulacion: true,
      nombres: HUERFANOS,
    });
    expect(fakes.llamadasRemove()).toEqual([]);
  });
});

async function handlerSimular(fakes: { handler: () => (req: Request) => Promise<Response> }) {
  return fakes.handler()(post(`${URL_BASE}?simular=1`, { "x-cron-secret": SECRETO }));
}

describe("borrado real", () => {
  it("con secreto y sin simular llama a remove con EXACTAMENTE los nombres", async () => {
    const fakes = await cargar();
    const res = await fakes.handler()(
      post(URL_BASE, { "x-cron-secret": SECRETO }),
    );
    const cuerpo = await res.json();
    expect(cuerpo).toMatchObject({ borrados: 2, simulacion: false });
    expect(fakes.llamadasRemove()).toEqual([HUERFANOS]);
  });

  it("si listar_huerfanos devuelve vacío no llama a remove", async () => {
    const fakes = await cargar({ huerfanos: { data: [], error: null } });
    await fakes.handler()(post(URL_BASE, { "x-cron-secret": SECRETO }));
    expect(fakes.llamadasRemove()).toEqual([]);
  });

  it("un fallo de Storage responde 500 sin borrar nada más", async () => {
    const fakes = await cargar({ remove: { error: { message: "storage caído" } } });
    const res = await fakes.handler()(post(URL_BASE, { "x-cron-secret": SECRETO }));
    expect(res.status).toBe(500);
  });

  it("un fallo de la RPC responde 500 sin llamar a remove", async () => {
    const fakes = await cargar({ huerfanos: { data: null, error: { message: "bd caída" } } });
    const res = await fakes.handler()(post(URL_BASE, { "x-cron-secret": SECRETO }));
    expect(res.status).toBe(500);
    expect(fakes.llamadasRemove()).toEqual([]);
  });
});