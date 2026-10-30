// Pruebas de los pasos Cliente, Compra y Verificación (Tarea 18 del plan).
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";

const fakes = vi.hoisted(() => ({
  guardarCliente: vi.fn(),
  buscarCliente: vi.fn(),
  previsualizarCobertura: vi.fn(),
}));

vi.mock("../registroService.js", () => fakes);

import PasoCliente from "./PasoCliente.jsx";
import PasoCompra from "./PasoCompra.jsx";
import PasoVerificacion from "./PasoVerificacion.jsx";

beforeEach(() => {
  fakes.guardarCliente.mockReset().mockResolvedValue({ ok: true, datos: "c1" });
  fakes.buscarCliente.mockReset().mockResolvedValue({ ok: true, datos: null });
  fakes.previsualizarCobertura.mockReset().mockResolvedValue({
    ok: true,
    datos: { cobertura: "EN_GARANTIA", motivo: null },
  });
});

const actualizar = vi.fn();
const estadoVacio = {};
const renderPasoCliente = (estado = estadoVacio) =>
  render(<PasoCliente estado={estado} actualizar={actualizar} />);

describe("PasoCliente", () => {
  it("escribe 'J-30.589.214-7' y rellena tipo J y documento 305892147", async () => {
    renderPasoCliente();
    await userEvent.setup().type(screen.getByLabelText(/documento/i), "J-30.589.214-7");
    expect(screen.getByLabelText(/tipo/i)).toHaveValue("J");
    expect(screen.getByRole("textbox", { name: /documento/i })).toHaveValue("305892147");
  });

  it("un documento de 4 dígitos muestra el error junto al campo", async () => {
    renderPasoCliente();
    await userEvent.setup().type(screen.getByLabelText(/documento/i), "1234");
    expect(await screen.findByText(/5 dígitos|al menos 5/)).toBeTruthy();
  });

  it('"cliente existente" y "nuevo" alternan los campos', async () => {
    renderPasoCliente();
    await userEvent.setup().click(screen.getByRole("button", { name: /existente/i }));
    expect(screen.queryByLabelText(/nombre/i)).toBeNull();
    await userEvent.setup().click(screen.getByRole("button", { name: /nuevo/i }));
    expect(screen.getByLabelText(/nombre/i)).toBeTruthy();
  });
});

describe("PasoCompra", () => {
  it("elige 7 días y una fecha y muestra el vencimiento calculado", async () => {
    render(<PasoCompra estado={{}} actualizar={actualizar} />);
    const user = userEvent.setup();
    await user.type(screen.getByLabelText(/número/i), "F-50");
    await user.type(screen.getByLabelText(/fecha/i), "2026-09-01");
    await user.selectOptions(screen.getByLabelText(/plazo/i), "7");
    expect(screen.getByText(/vence el 2026-09-08/i)).toBeTruthy();
  });

  it('"no trae la factura" desactiva soporte, fecha y plazo con el aviso', async () => {
    render(<PasoCompra estado={{}} actualizar={actualizar} />);
    const user = userEvent.setup();
    await user.click(screen.getByRole("checkbox", { name: /no trae/i }));
    expect(actualizar).toHaveBeenCalledWith(expect.objectContaining({ sinSoporte: true }));
    expect(screen.getByText(/por determinar/i)).toBeTruthy();
  });

  it("con sinSoporte los controles están desactivados", () => {
    render(<PasoCompra estado={{ sinSoporte: true }} actualizar={vi.fn()} />);
    expect(screen.getByLabelText(/número/i)).toBeDisabled();
    expect(screen.getByLabelText(/fecha/i)).toBeDisabled();
    expect(screen.getByLabelText(/plazo/i)).toBeDisabled();
  });
});

describe("PasoVerificacion", () => {
  it("cada casilla pide la cobertura a la base (no se calcula en el navegador)", async () => {
    fakes.previsualizarCobertura.mockResolvedValue({
      ok: true, datos: { cobertura: "EN_GARANTIA", motivo: null },
    });
    const estado = { serial: "S", venceEl: "2026-09-08", fechaIngreso: "2026-09-02" };
    render(<PasoVerificacion estado={estado} actualizar={() => {}} />);
    const user = userEvent.setup();
    const casillas = screen.getAllByRole("checkbox");
    await user.click(casillas[0]);
    await waitFor(() =>
      expect(fakes.previsualizarCobertura).toHaveBeenCalled(),
    );
    expect(screen.getByText(/EN_GARANTIA/)).toBeTruthy();
  });

  it("marcar golpes muestra ANULADA_POR_USO y su motivo", async () => {
    fakes.previsualizarCobertura.mockResolvedValue({
      ok: true,
      datos: { cobertura: "ANULADA_POR_USO", motivo: "golpes (señal de causa externa)" },
    });
    const estado = { venceEl: "2026-09-08", fechaIngreso: "2026-09-02" };
    render(<PasoVerificacion estado={estado} actualizar={() => {}} />);
    await userEvent.setup().click(screen.getByRole("checkbox", { name: /golpes/i }));
    await waitFor(() => expect(screen.getByText(/ANULADA_POR_USO/)).toBeTruthy());
    expect(screen.getByText(/golpes/)).toBeTruthy();
  });

  it("si la base falla, muestra 'Se calculará al guardar' sin bloquear", async () => {
    fakes.previsualizarCobertura.mockResolvedValue({ ok: false, codigo: "SIN_CONEXION", mensaje: "x" });
    const estado = { venceEl: "2026-09-08", fechaIngreso: "2026-09-02" };
    render(<PasoVerificacion estado={estado} actualizar={() => {}} />);
    await userEvent.setup().click(screen.getAllByRole("checkbox")[0]);
    await waitFor(() => expect(screen.getByText(/se calculará al guardar/i)).toBeTruthy());
  });
});