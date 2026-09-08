/**
 * `diasHasta` es lo que decide si el panel de vencimientos dice "Vence hoy"
 * o "Venció hace 1 d". El taller está en America/Caracas (UTC-4): a partir
 * de las 20:00 hora local, la fecha UTC ya es la de mañana. Cualquier
 * cálculo que pase por `toISOString()` cambia de día esa tarde, y el
 * operador del turno de noche ve un plazo distinto que el de la mañana
 * sobre la misma orden.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { diasHasta, fechaLocalISO } from "./dominio.js";

/** 8 de septiembre de 2026, 20:30 en Caracas = 9 de septiembre 00:30 UTC. */
const NOCHE_EN_CARACAS = new Date("2026-09-09T00:30:00Z");

describe("diasHasta", () => {
  it("una garantía que vence hoy son 0 días, a las 9 de la mañana", () => {
    const manana = new Date("2026-09-08T13:00:00Z"); // 09:00 en Caracas
    expect(diasHasta("2026-09-08", manana)).toBe(0);
  });

  it("sigue siendo hoy a las 20:30 de Caracas, aunque en UTC ya sea mañana", () => {
    expect(diasHasta("2026-09-08", NOCHE_EN_CARACAS)).toBe(0);
  });

  it("mañana es 1 día también en el turno de noche", () => {
    expect(diasHasta("2026-09-09", NOCHE_EN_CARACAS)).toBe(1);
  });

  it("una garantía vencida da días negativos", () => {
    expect(diasHasta("2026-09-05", NOCHE_EN_CARACAS)).toBe(-3);
  });

  it("acepta un timestamp completo, no sólo una fecha suelta", () => {
    expect(diasHasta("2026-09-10T18:45:00.000Z", NOCHE_EN_CARACAS)).toBe(2);
  });
});

describe("fechaLocalISO", () => {
  it("da la fecha del calendario del taller, no la de UTC", () => {
    expect(fechaLocalISO(NOCHE_EN_CARACAS)).toBe("2026-09-08");
  });

  it("rellena mes y día a dos cifras", () => {
    expect(fechaLocalISO(new Date("2026-01-05T15:00:00Z"))).toBe("2026-01-05");
  });
});

describe("la ventana de `consultarPorVencer`", () => {
  beforeEach(() => {
    vi.useFakeTimers();
    vi.setSystemTime(NOCHE_EN_CARACAS);
  });
  afterEach(() => vi.useRealTimers());

  it("arranca hoy y no mañana: una garantía que vence hoy tiene que salir en el panel", async () => {
    const { crearConsultaFalsa } = await import("../../test/supabaseFake.js");
    const { supabase } = await import("../../lib/supabaseClient.js");
    const { consultarPorVencer } = await import("./datos/ordenes.js");

    const consulta = crearConsultaFalsa({ data: [], error: null });
    supabase.from.mockReturnValue(consulta);

    await consultarPorVencer({ dias: 30 });

    expect(consulta.argumentosDe("gte")).toEqual(["garantia_vence_el", "2026-09-08"]);
    expect(consulta.argumentosDe("lte")).toEqual(["garantia_vence_el", "2026-10-08"]);
  });
});

vi.mock("../../lib/supabaseClient.js");
