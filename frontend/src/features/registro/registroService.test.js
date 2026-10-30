// Pruebas de registroService (Tarea 15 del plan).
// El cliente de Supabase se simula EN EL BORDE (../../lib/supabaseClient.js):
// lo que se prueba es que cada función llame a la RPC con los nombres de
// parámetro EXACTOS de las Tareas 11 y 12 del plan, y el mapeo de errores.
import { beforeEach, describe, expect, it, vi } from "vitest";

const fakes = vi.hoisted(() => {
  const rpc = vi.fn();
  const upload = vi.fn();
  const storageFrom = vi.fn(() => ({ upload }));
  const insert = vi.fn();
  const from = vi.fn(() => ({ insert }));
  return {
    rpc,
    upload,
    storageFrom,
    insert,
    from,
    // el builder de supabase-js es thenable: `await .insert(x)` dispara el resultado
    setResultado(v) {
      insert.mockImplementation(() => ({
        then: (res) => Promise.resolve(v).then(res),
        catch: (rj) => Promise.resolve(v).catch(rj),
      }));
    },
    limpiar() {
      rpc.mockReset();
      upload.mockReset();
      insert.mockReset();
      storageFrom.mockClear();
      from.mockClear();
    },
  };
});

vi.mock("../../lib/supabaseClient.js", () => ({
  supabase: {
    rpc: fakes.rpc,
    storage: { from: fakes.storageFrom },
    from: fakes.from,
  },
}));

import {
  buscarEquipo,
  guardarCliente,
  previsualizarCobertura,
  registrarIngreso,
  registrarRevision,
  subirAdjunto,
} from "./registroService.js";

const ARCHIVO_JPG = (bytes = 100) =>
  new File([new Uint8Array(bytes)], "foto.jpg", { type: "image/jpeg" });

beforeEach(() => {
  fakes.limpiar();
  fakes.rpc.mockResolvedValue({ data: [], error: null });
  fakes.upload.mockResolvedValue({ data: { path: "x" }, error: null });
  fakes.setResultado({ data: [], error: null });
});

describe("llamadas a la base (nombres exactos de la RPC)", () => {
  it("buscarEquipo llama a buscar_equipo con p_serial", async () => {
    const r = await buscarEquipo("RT5-8842-AA");
    expect(fakes.rpc).toHaveBeenCalledWith("buscar_equipo", { p_serial: "RT5-8842-AA" });
    expect(r).toEqual({ ok: true, datos: [] });
  });

  it("guardarCliente pasa las claves exactas", async () => {
    await guardarCliente({
      tipo: "V",
      documento: "305892147",
      nombre: "Juan Perez",
      telefono: "04241234567",
      email: "juan@correo.com",
      direccion: "Los Teques",
    });
    expect(fakes.rpc).toHaveBeenCalledWith("guardar_cliente", {
      p_tipo: "V",
      p_documento: "305892147",
      p_nombre: "Juan Perez",
      p_telefono: "04241234567",
      p_email: "juan@correo.com",
      p_direccion: "Los Teques",
    });
  });

  it("registrarIngreso pasa las claves exactas", async () => {
    const carga = {
      serial: "RT5-8842-AA",
      productoId: "p1",
      clienteId: "c1",
      falla: "No enciende",
      accesorios: "cargador",
      tipoSoporte: "FACTURA",
      numeroSoporte: "F-1",
      fechaEmision: "2026-09-01",
      plazoDias: 7,
      vendedor: "Tienda",
      checklist: { a: true },
      observaciones: "obs",
    };
    await registrarIngreso(carga);
    expect(fakes.rpc).toHaveBeenCalledWith("registrar_ingreso", {
      p_serial: "RT5-8842-AA",
      p_producto_id: "p1",
      p_cliente_id: "c1",
      p_falla: "No enciende",
      p_accesorios: "cargador",
      p_tipo_soporte: "FACTURA",
      p_numero_soporte: "F-1",
      p_fecha_emision: "2026-09-01",
      p_plazo_dias: 7,
      p_vendedor: "Tienda",
      p_checklist: { a: true },
      p_observaciones: "obs",
    });
  });

  it("registrarRevision llama a registrar_revision", async () => {
    const r = await registrarRevision("reg-1", {
      tipo: "TECNICA",
      checklist: { golpes: true },
      observaciones: "golpes",
    });
    expect(fakes.rpc).toHaveBeenCalledWith("registrar_revision", {
      p_registro_id: "reg-1",
      p_tipo: "TECNICA",
      p_checklist: { golpes: true },
      p_observaciones: "golpes",
    });
    expect(r.ok).toBe(true);
  });

  it("previsualizarCobertura llama a calcular_cobertura", async () => {
    const chk = { condiciones: { factura_presentada: true, titular_coincide: true } };
    await previsualizarCobertura({
      venceEl: "2026-09-08",
      fechaIngreso: "2026-09-02",
      checklist: chk,
    });
    expect(fakes.rpc).toHaveBeenCalledWith("calcular_cobertura", {
      p_vence_el: "2026-09-08",
      p_fecha_ingreso: "2026-09-02",
      p_checklist: chk,
    });
  });
});

describe("mapeo de errores", () => {
  it("un 42501 da SIN_PERMISO", async () => {
    fakes.rpc.mockResolvedValue({ data: null, error: { code: "42501", message: "Su rol no puede registrar ingresos" } });
    const r = await buscarEquipo("x");
    expect(r).toMatchObject({ ok: false, codigo: "SIN_PERMISO", mensaje: "Su rol no puede registrar ingresos" });
  });

  it("un 401 da SESION_VENCIDA", async () => {
    fakes.rpc.mockResolvedValue({ data: null, error: { code: "401", status: 401, message: "JWT invalid" } });
    const r = await registrarRevision("r", { tipo: "TECNICA", checklist: {}, observaciones: null });
    expect(r).toMatchObject({ ok: false, codigo: "SESION_VENCIDA" });
  });

  it("un fetch que lanza da SIN_CONEXION", async () => {
    fakes.rpc.mockRejectedValue(new TypeError("Failed to fetch"));
    const r = await buscarEquipo("x");
    expect(r).toMatchObject({ ok: false, codigo: "SIN_CONEXION" });
  });

  it("un error sin código reconocible da DESCONOCIDO", async () => {
    fakes.rpc.mockResolvedValue({ data: null, error: { code: "99999", message: "algo raro" } });
    const r = await buscarEquipo("x");
    expect(r).toMatchObject({ ok: false, codigo: "DESCONOCIDO", mensaje: "algo raro" });
  });
});

describe("subirAdjunto: validación ANTES de subir", () => {
  it("un HEIC no se sube y da FORMATO_NO_ADMITIDO", async () => {
    const heic = new File([new Uint8Array(10)], "x.heic", { type: "image/heic" });
    const r = await subirAdjunto("reg-1", heic, { tipo: "FOTO", etiqueta: "x" });
    expect(fakes.upload).not.toHaveBeenCalled();
    expect(r).toMatchObject({ ok: false, codigo: "FORMATO_NO_ADMITIDO" });
    expect(r.mensaje).toMatch(/JPG, PNG o WEBP/);
  });

  it("un archivo de 9 MB da LIMITE y no se sube", async () => {
    const grande = new File([new Uint8Array(10)], "g.jpg", { type: "image/jpeg" });
    Object.defineProperty(grande, "size", { value: 9 * 1024 * 1024 });
    const r = await subirAdjunto("reg-1", grande, { tipo: "FOTO", etiqueta: "g" });
    expect(fakes.upload).not.toHaveBeenCalled();
    expect(r).toMatchObject({ ok: false, codigo: "LIMITE" });
  });

  it("un PDF no es una foto", async () => {
    const pdf = new File([new Uint8Array(10)], "x.pdf", { type: "application/pdf" });
    const r = await subirAdjunto("reg-1", pdf, { tipo: "FOTO", etiqueta: "x" });
    expect(fakes.upload).not.toHaveBeenCalled();
    expect(r).toMatchObject({ ok: false, codigo: "FORMATO_NO_ADMITIDO" });
  });
});

describe("subirAdjunto: camino feliz", () => {
  it("sube a la ruta del registro y luego registra la fila", async () => {
    fakes.upload.mockResolvedValue({ data: { path: "registros/reg-1/foto.jpg" }, error: null });
    fakes.setResultado({ data: [{ id: "a1" }], error: null });

    const r = await subirAdjunto("reg-1", ARCHIVO_JPG(), { tipo: "FOTO", etiqueta: "frontal" });
    expect(fakes.storageFrom).toHaveBeenCalledWith("registros");
    expect(fakes.upload).toHaveBeenCalledWith("registros/reg-1/foto.jpg", expect.anything());
    expect(fakes.insert).toHaveBeenCalledWith(
      expect.objectContaining({
        registro_id: "reg-1",
        tipo: "FOTO",
        ruta: "registros/reg-1/foto.jpg",
        mime: "image/jpeg",
        bytes: expect.any(Number),
        etiqueta: "frontal",
      }),
    );
    expect(r).toEqual({ ok: true, datos: { id: "a1" } });
  });
});