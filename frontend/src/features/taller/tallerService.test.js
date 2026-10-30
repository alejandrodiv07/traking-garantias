// tallerService: contrato de abrir_orden por equipo (0019) y lectura del equipo
// (Tarea 15 del plan). Supabase y subirAdjunto se simulan en el borde.
import { beforeEach, describe, expect, it, vi } from "vitest";

const fakes = vi.hoisted(() => ({
  rpc: vi.fn(),
  subirAdjunto: vi.fn(),
  single: vi.fn(),
  eq: vi.fn(),
  select: vi.fn(),
  from: vi.fn(),
}));

vi.mock("../../lib/supabaseClient.js", () => ({
  supabase: { rpc: fakes.rpc, from: fakes.from },
}));
vi.mock("../registro/registroService.js", async () => {
  const real = await vi.importActual("../registro/registroService.js");
  return { ...real, subirAdjunto: fakes.subirAdjunto };
});

import { abrirOrden, leerEquipo, subirAdjuntos } from "./tallerService.js";

beforeEach(() => {
  for (const f of Object.values(fakes)) f.mockReset();
  fakes.from.mockReturnValue({ select: fakes.select });
  fakes.select.mockReturnValue({ eq: fakes.eq });
  fakes.eq.mockReturnValue({ maybeSingle: fakes.single });
});

describe("abrirOrden", () => {
  it("manda la firma exacta de la 0019 (sin fecha de ingreso) y devuelve la fila", async () => {
    fakes.rpc.mockResolvedValue({
      data: [{ orden_id: "o1", numero_orden: "OS-2026-0001", consulta_token: "t", cobertura: "EN_GARANTIA", tipo_atencion: "GARANTIA" }],
      error: null,
    });
    const r = await abrirOrden({
      equipoId: "e1",
      falla: "no enciende",
      accesorios: "cargador",
      checklist: { equipo: { golpes: true } },
      observaciones: "rayado",
      claveEnvio: "k1",
    });
    expect(fakes.rpc).toHaveBeenCalledWith("abrir_orden", {
      p_equipo_id: "e1",
      p_falla: "no enciende",
      p_accesorios: "cargador",
      p_checklist: { equipo: { golpes: true } },
      p_observaciones: "rayado",
      p_clave_envio: "k1",
    });
    expect(r).toEqual({ ok: true, datos: expect.objectContaining({ orden_id: "o1" }) });
  });

  it("manda null en lo opcional", async () => {
    fakes.rpc.mockResolvedValue({ data: [{ orden_id: "o1" }], error: null });
    await abrirOrden({ equipoId: "e1", falla: "no enciende", claveEnvio: "k1" });
    expect(fakes.rpc.mock.calls[0][1]).toMatchObject({
      p_accesorios: null,
      p_checklist: null,
      p_observaciones: null,
    });
  });

  it("42501 es SIN_PERMISO y un fallo de red SIN_CONEXION", async () => {
    fakes.rpc.mockResolvedValueOnce({ data: null, error: { code: "42501", message: "no" } });
    expect((await abrirOrden({ equipoId: "e1", falla: "xxxxx", claveEnvio: "k" })).codigo).toBe("SIN_PERMISO");
    fakes.rpc.mockRejectedValueOnce(new TypeError("Failed to fetch"));
    expect((await abrirOrden({ equipoId: "e1", falla: "xxxxx", claveEnvio: "k" })).codigo).toBe("SIN_CONEXION");
  });
});

describe("leerEquipo", () => {
  it("lee el equipo por id desde v_garantias", async () => {
    fakes.single.mockResolvedValue({ data: { equipo_id: "e1", numero_serie: "RT5" }, error: null });
    const r = await leerEquipo("e1");
    expect(fakes.from).toHaveBeenCalledWith("v_garantias");
    expect(fakes.eq).toHaveBeenCalledWith("equipo_id", "e1");
    expect(r).toEqual({ ok: true, datos: { equipo_id: "e1", numero_serie: "RT5" } });
  });

  it("equipo inexistente es NO_ENCONTRADO", async () => {
    fakes.single.mockResolvedValue({ data: null, error: null });
    expect((await leerEquipo("zz")).codigo).toBe("NO_ENCONTRADO");
  });
});

describe("subirAdjuntos", () => {
  it("sube todos y devuelve como pendientes solo los que fallaron", async () => {
    const a = { archivo: { name: "a.jpg" }, tipo: "FOTO", etiqueta: null };
    const b = { archivo: { name: "b.pdf" }, tipo: "DOCUMENTO", etiqueta: null };
    fakes.subirAdjunto.mockResolvedValueOnce({ ok: true }).mockResolvedValueOnce({ ok: false });
    expect(await subirAdjuntos("o1", [a, b])).toEqual([b]);
    expect(fakes.subirAdjunto).toHaveBeenCalledWith("o1", a.archivo, { tipo: "FOTO", etiqueta: null });
  });
});
