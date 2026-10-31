// garantiasService: contrato de registrar_garantia y buscar_equipo (Tareas 8, 13
// y 14 del plan). Supabase se simula en el borde, como en registroService.
import { beforeEach, describe, expect, it, vi } from "vitest";

const rpcFalso = vi.hoisted(() => vi.fn());
const subirFalso = vi.hoisted(() => vi.fn());
const supabaseFalso = vi.hoisted(() => ({ rpc: undefined }));
vi.mock("../../lib/supabaseClient.js", () => ({ supabase: supabaseFalso }));
vi.mock("../registro/registroService.js", async (orig) => ({ ...(await orig()), subirAdjuntoEquipo: subirFalso }));

import {
  buscarGarantia,
  confirmarCompra,
  desestimarCompra,
  documentosDeEquipo,
  listarGarantias,
  registrarGarantia,
  subirDocumentosEquipo,
  urlDocumento,
} from "./garantiasService.js";

beforeEach(() => {
  rpcFalso.mockReset();
  supabaseFalso.rpc = rpcFalso;
});

const DATOS = {
  clienteId: "c1",
  productoId: "p1",
  serial: "RT5-8842-AA",
  tipoSoporte: "FACTURA",
  numeroSoporte: "F-200",
  fechaEmision: "2026-10-20",
  plazoDias: 7,
};

describe("registrarGarantia", () => {
  it("llama a registrar_garantia con origen VENTA y devuelve la fila", async () => {
    rpcFalso.mockResolvedValue({
      data: [{ equipo_id: "e1", vence_el: "2026-10-27", equipo_nuevo: true }],
      error: null,
    });
    const r = await registrarGarantia(DATOS);
    expect(rpcFalso).toHaveBeenCalledWith("registrar_garantia", {
      p_cliente_id: "c1",
      p_producto_id: "p1",
      p_serial: "RT5-8842-AA",
      p_tipo_soporte: "FACTURA",
      p_numero_soporte: "F-200",
      p_fecha_emision: "2026-10-20",
      p_plazo_dias: 7,
      p_origen: "VENTA",
    });
    expect(r).toEqual({
      ok: true,
      datos: { equipo_id: "e1", vence_el: "2026-10-27", equipo_nuevo: true },
    });
  });

  it("manda null en lo que falta y respeta el origen TALLER", async () => {
    rpcFalso.mockResolvedValue({ data: [{ equipo_id: "e1" }], error: null });
    await registrarGarantia({ clienteId: "c1", productoId: "p1", serial: "X1Y", origen: "TALLER" });
    expect(rpcFalso.mock.calls[0][1]).toMatchObject({
      p_tipo_soporte: null,
      p_numero_soporte: null,
      p_fecha_emision: null,
      p_plazo_dias: null,
      p_origen: "TALLER",
    });
  });

  it("42501 es SIN_PERMISO con el mensaje de la base", async () => {
    rpcFalso.mockResolvedValue({
      data: null,
      error: { code: "42501", message: "los plazos distintos de 7 o 15 días solo los fija el jefe" },
    });
    expect(await registrarGarantia({ ...DATOS, plazoDias: 30 })).toEqual({
      ok: false,
      codigo: "SIN_PERMISO",
      mensaje: "los plazos distintos de 7 o 15 días solo los fija el jefe",
    });
  });

  it("un fallo de red es SIN_CONEXION", async () => {
    rpcFalso.mockRejectedValue(new TypeError("Failed to fetch"));
    expect((await registrarGarantia(DATOS)).codigo).toBe("SIN_CONEXION");
  });
});

describe("buscarGarantia", () => {
  it("manda los 4 criterios, con null los que faltan, y devuelve las filas", async () => {
    rpcFalso.mockResolvedValue({ data: [{ equipo_id: "e1" }], error: null });
    const r = await buscarGarantia({ serial: "RT5" });
    expect(rpcFalso).toHaveBeenCalledWith("buscar_equipo", {
      p_serial: "RT5",
      p_documento: null,
      p_factura: null,
      p_orden: null,
    });
    expect(r).toEqual({ ok: true, datos: [{ equipo_id: "e1" }] });
  });
});

describe("listarGarantias", () => {
  it("lee v_garantias ordenada por vencimiento y busca en serial, titular, cédula y factura", async () => {
    const consulta = { order: vi.fn(), limit: vi.fn(), or: vi.fn() };
    consulta.order.mockReturnValue(consulta);
    consulta.limit.mockReturnValue(consulta);
    consulta.or.mockResolvedValue({ data: [{ equipo_id: "e1" }], error: null });
    const desdeFalso = vi.fn(() => ({ select: vi.fn(() => consulta) }));
    supabaseFalso.from = desdeFalso;

    const r = await listarGarantias({ busqueda: " RT5 " });
    expect(desdeFalso).toHaveBeenCalledWith("v_garantias");
    expect(consulta.order).toHaveBeenCalledWith("vence_el", { ascending: true });
    expect(consulta.or).toHaveBeenCalledWith(
      "numero_serie.ilike.*RT5*,titular.ilike.*RT5*,documento.ilike.*RT5*,numero_soporte.ilike.*RT5*",
    );
    expect(r).toEqual({ ok: true, datos: [{ equipo_id: "e1" }] });
  });
});

describe("confirmar y desestimar compra", () => {
  it("confirmarCompra manda el soporte completo", async () => {
    rpcFalso.mockResolvedValue({ data: null, error: null });
    const r = await confirmarCompra({
      equipoId: "e1",
      tipoSoporte: "FACTURA",
      numeroSoporte: "F-9",
      fechaEmision: "2026-10-20",
      plazoDias: 15,
    });
    expect(rpcFalso).toHaveBeenCalledWith("confirmar_compra", {
      p_equipo_id: "e1",
      p_tipo_soporte: "FACTURA",
      p_numero_soporte: "F-9",
      p_fecha_emision: "2026-10-20",
      p_plazo_dias: 15,
    });
    expect(r.ok).toBe(true);
  });

  it("desestimarCompra manda el motivo y mapea 42501 a SIN_PERMISO", async () => {
    rpcFalso.mockResolvedValue({ data: null, error: { code: "42501", message: "solo jefatura" } });
    const r = await desestimarCompra({ equipoId: "e1", motivo: "la factura no corresponde" });
    expect(rpcFalso).toHaveBeenCalledWith("desestimar_compra", {
      p_equipo_id: "e1",
      p_motivo: "la factura no corresponde",
    });
    expect(r).toMatchObject({ ok: false, codigo: "SIN_PERMISO" });
  });
});

describe("documentos de la garantía", () => {
  it("subirDocumentosEquipo sube cada archivo al equipo y devuelve solo los que fallaron", async () => {
    const a = { archivo: { name: "a.pdf" }, tipo: "DOCUMENTO", etiqueta: "Factura" };
    const b = { archivo: { name: "b.jpg" }, tipo: "FOTO" };
    subirFalso.mockReset().mockResolvedValueOnce({ ok: true }).mockResolvedValueOnce({ ok: false, mensaje: "Sin conexión" });
    const pendientes = await subirDocumentosEquipo("e1", [a, b]);
    expect(subirFalso).toHaveBeenCalledWith("e1", a.archivo, { tipo: "DOCUMENTO", etiqueta: "Factura" });
    expect(pendientes).toEqual([{ ...b, mensaje: "Sin conexión" }]);
  });

  it("documentosDeEquipo lee los adjuntos del equipo, el más reciente primero", async () => {
    const order = vi.fn().mockResolvedValue({ data: [{ id: "d1" }], error: null });
    const eq = vi.fn(() => ({ order }));
    const select = vi.fn(() => ({ eq }));
    supabaseFalso.from = vi.fn(() => ({ select }));
    const r = await documentosDeEquipo("e1");
    expect(supabaseFalso.from).toHaveBeenCalledWith("adjuntos");
    expect(eq).toHaveBeenCalledWith("equipo_id", "e1");
    expect(order).toHaveBeenCalledWith("subido_en", { ascending: false });
    expect(r).toEqual({ ok: true, datos: [{ id: "d1" }] });
  });

  it("urlDocumento pide un enlace firmado de 60 s", async () => {
    const createSignedUrl = vi.fn().mockResolvedValue({ data: { signedUrl: "https://x/firmado" }, error: null });
    supabaseFalso.storage = { from: vi.fn(() => ({ createSignedUrl })) };
    const r = await urlDocumento("equipos/e1/factura.pdf");
    expect(supabaseFalso.storage.from).toHaveBeenCalledWith("ordenes");
    expect(createSignedUrl).toHaveBeenCalledWith("equipos/e1/factura.pdf", 60);
    expect(r).toEqual({ ok: true, datos: "https://x/firmado" });
  });

  it("urlDocumento devuelve el error si la base lo niega", async () => {
    supabaseFalso.storage = { from: () => ({ createSignedUrl: vi.fn().mockResolvedValue({ data: null, error: { message: "Object not found" } }) }) };
    expect(await urlDocumento("equipos/e1/x.pdf")).toMatchObject({ ok: false, mensaje: "Object not found" });
  });
});
