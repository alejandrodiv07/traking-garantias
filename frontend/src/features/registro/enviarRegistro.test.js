// Pruebas de enviarRegistro (Tarea 19 del plan): primero abrirOrden (el
// orden existe antes de subir un solo archivo), luego subir cada adjunto.
import { beforeEach, describe, expect, it, vi } from "vitest";

const fakes = vi.hoisted(() => ({
  abrirOrden: vi.fn(),
  subirAdjunto: vi.fn(),
  limpiarBorrador: vi.fn(),
}));

vi.mock("./registroService.js", async (importOriginal) => ({
  ...(await importOriginal()),
  abrirOrden: fakes.abrirOrden,
  subirAdjunto: fakes.subirAdjunto,
  limpiarBorrador: fakes.limpiarBorrador,
}));
vi.mock("./borrador.js", async (importOriginal) => ({
  ...(await importOriginal()),
  limpiarBorrador: fakes.limpiarBorrador,
}));

import { enviarRegistro } from "./enviarRegistro.js";

const ARCHIVO = (nombre) => new File([new Uint8Array(5)], nombre, { type: "image/jpeg" });
const ESTADO = {
  serial: "RT5-8842-AA",
  productoId: "p1",
  clienteId: "c1",
  falla: "No enciende",
  tipoSoporte: "FACTURA",
  numeroSoporte: "F-1",
  fechaEmision: "2026-09-01",
  plazoDias: 7,
};

const REGISTRO = {
  orden_id: "r9",
  numero_orden: "OS-2026-00009",
  cobertura: "EN_GARANTIA",
  consulta_token: "abc",
};

beforeEach(() => {
  fakes.abrirOrden.mockReset().mockResolvedValue({ ok: true, datos: REGISTRO });
  fakes.subirAdjunto.mockReset().mockResolvedValue({ ok: true, datos: {} });
  fakes.limpiarBorrador.mockReset();
});

describe("enviarRegistro", () => {
  it("manda la clave de envío del estado a abrirOrden", async () => {
    await enviarRegistro({ ...ESTADO, claveEnvio: "clave-9" }, [], { userId: "u1" });
    expect(fakes.abrirOrden).toHaveBeenCalledWith(expect.objectContaining({ claveEnvio: "clave-9" }));
  });

  it("abrirOrden primero; sube cada archivo; limpia el borrador si todo sale", async () => {
    const archivos = [
      { archivo: ARCHIVO("a.jpg"), tipo: "FOTO", etiqueta: "a" },
      { archivo: ARCHIVO("b.jpg"), tipo: "FOTO", etiqueta: "b" },
    ];
    const r = await enviarRegistro(ESTADO, archivos, { userId: "u1" });

    expect(fakes.abrirOrden).toHaveBeenCalledWith(
      expect.objectContaining({ serial: "RT5-8842-AA", falla: "No enciende" }),
    );
    expect(fakes.subirAdjunto).toHaveBeenCalledTimes(2);
    expect(fakes.subirAdjunto).toHaveBeenCalledWith("r9", archivos[0].archivo, { tipo: "FOTO", etiqueta: "a" });
    expect(fakes.limpiarBorrador).toHaveBeenCalledWith("u1");
    expect(r).toEqual(expect.objectContaining({ ok: true, registro: REGISTRO, pendientes: [] }));
  });

  it("si una subida falla, el registro EXISTE y el archivo queda en pendientes", async () => {
    fakes.subirAdjunto
      .mockResolvedValueOnce({ ok: true, datos: {} })
      .mockResolvedValueOnce({ ok: false, codigo: "SIN_CONEXION", mensaje: "x" })
      .mockResolvedValueOnce({ ok: true, datos: {} });
    const archivos = [
      { archivo: ARCHIVO("a.jpg"), tipo: "FOTO", etiqueta: "a" },
      { archivo: ARCHIVO("b.jpg"), tipo: "FOTO", etiqueta: "b" },
      { archivo: ARCHIVO("c.jpg"), tipo: "FOTO", etiqueta: "c" },
    ];
    const r = await enviarRegistro(ESTADO, archivos, { userId: "u1" });

    expect(r.ok).toBe(true);
    expect(r.registro).toEqual(REGISTRO);
    expect(r.pendientes).toEqual([archivos[1]]);
    // el registro ya existe: NO limpiarBorrador (el técnico reintenta adjuntos después)
    expect(fakes.limpiarBorrador).not.toHaveBeenCalled();
  });

  it("reintentar sube SOLO los pendientes", async () => {
    const pendientes = [{ archivo: ARCHIVO("b.jpg"), tipo: "FOTO", etiqueta: "b" }];
    fakes.subirAdjunto.mockResolvedValueOnce({ ok: true, datos: {} });
    const r = await enviarRegistro(ESTADO, [], {
      userId: "u1",
      ordenIdExistente: "r9",
      pendientesIniciales: pendientes,
    });
    expect(fakes.subirAdjunto).toHaveBeenCalledTimes(1);
    expect(fakes.subirAdjunto).toHaveBeenCalledWith("r9", pendientes[0].archivo, { tipo: "FOTO", etiqueta: "b" });
    expect(fakes.limpiarBorrador).toHaveBeenCalledWith("u1");  // al completar sí se limpia
    expect(r.pendientes).toEqual([]);
  });

  it("abrirOrden falla por SESION_VENCIDA: NO limpia el borrador y vuelve con el mensaje", async () => {
    fakes.abrirOrden.mockResolvedValue({
      ok: false,
      codigo: "SESION_VENCIDA",
      mensaje: "Tu sesión venció: vuelve a entrar para continuar",
    });
    const r = await enviarRegistro(ESTADO, [ { archivo: ARCHIVO("a.jpg"), tipo: "FOTO", etiqueta: "a" }], { userId: "u1" });
    expect(r.ok).toBe(false);
    expect(r.codigo).toBe("SESION_VENCIDA");
    expect(r.mensaje).toMatch(/Tu sesión venció/);
    expect(fakes.limpiarBorrador).not.toHaveBeenCalled();
  });
});