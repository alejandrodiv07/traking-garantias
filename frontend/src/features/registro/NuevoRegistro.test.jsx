// Prueba de integración del asistente completo (corrección D1, hallazgo 1):
// "Siguiente" debe avanzar por pasos REALMENTE montados — cliente, compra,
// verificación, adjuntos y resumen — y el resumen puede crear el registro.
import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";

const fakes = vi.hoisted(() => ({
  buscarEquipo: vi.fn(),
  buscarCliente: vi.fn(),
  guardarCliente: vi.fn(),
  previsualizarCobertura: vi.fn(),
  listarProductos: vi.fn(),
  enviarRegistro: vi.fn(),
}));

vi.mock("./registroService.js", () => fakes);
vi.mock("./enviarRegistro.js", () => ({ enviarRegistro: fakes.enviarRegistro }));

import NuevoRegistro from "./NuevoRegistro.jsx";

beforeEach(() => {
  localStorage.clear();
  fakes.buscarEquipo.mockReset().mockResolvedValue({ ok: true, datos: [] });
  fakes.buscarCliente.mockReset().mockResolvedValue({ ok: true, datos: null });
  fakes.guardarCliente.mockReset().mockResolvedValue({ ok: true, datos: "c1" });
  fakes.previsualizarCobertura.mockReset().mockResolvedValue({
    ok: true, datos: { cobertura: "EN_GARANTIA", motivo: null },
  });
  fakes.listarProductos.mockReset().mockResolvedValue({ ok: true, datos: [] });
  fakes.enviarRegistro.mockReset().mockResolvedValue({
    ok: true,
    registro: { registro_id: "r1", numero_registro: "REG-2026-000001" },
    pendientes: [],
  });
});

const botones = (nombre) => screen.getByRole("button", { name: nombre });

describe("NuevoRegistro: el asistente recorre los 6 pasos montados", () => {
  it("Siguiente llega a Cliente y Compra montados (no a pantallas vacías)", async () => {
    render(<NuevoRegistro userId="u1" onCerrar={vi.fn()} onCreado={vi.fn()} />);
    const user = userEvent.setup({ delay: 1 });

    // Paso equipo: el serial (ya se probó a fondo en PasoEquipo.test.jsx).
    await user.type(screen.getByLabelText(/serial/i), "RT58842AA{Enter}");
    await user.click(botones(/siguiente/i));

    // Paso cliente MONTADO: el campo del documento existe.
    expect(await screen.findByLabelText(/documento/i)).toBeTruthy();
    await user.click(botones(/siguiente/i));

    // Paso compra MONTADO: el campo del número existe.
    expect(await screen.findByLabelText(/número/i)).toBeTruthy();
    await user.click(botones(/siguiente/i));
  });

  it("Siguiente llega a Verificación, Adjuntos y Resumen; Confirmar crea el registro", async () => {
    const onCreado = vi.fn();
    render(<NuevoRegistro userId="u1" onCerrar={vi.fn()} onCreado={onCreado} />);
    const user = userEvent.setup({ delay: 1 });

    await user.type(screen.getByLabelText(/serial/i), "RT58842AA{Enter}");
    await user.click(botones(/siguiente/i));
    await screen.findByLabelText(/documento/i);            // cliente
    await user.click(botones(/siguiente/i));
    await screen.findByLabelText(/número/i);               // compra
    await user.click(botones(/siguiente/i));

    // Paso verificación MONTADO: las casillas del checklist existen.
    expect((await screen.findAllByRole("checkbox")).length).toBe(11);
    await user.click(botones(/siguiente/i));

    // Paso adjuntos MONTADO.
    expect(await screen.findByLabelText(/fotos/i)).toBeTruthy();
    await user.click(botones(/siguiente/i));

    // Paso resumen MONTADO: Confirmar llama a enviarRegistro y avisa onCreado.
    await user.click(await screen.findByRole("button", { name: /confirmar y registrar/i }));
    expect(await screen.findByText(/registro creado/i)).toBeTruthy();
    expect(fakes.enviarRegistro).toHaveBeenCalledTimes(1);
    expect(onCreado).toHaveBeenCalledWith(expect.objectContaining({ registro_id: "r1" }));
  });

  it("el botón Editar del resumen vuelve al paso correspondiente", async () => {
    render(<NuevoRegistro userId="u1" onCerrar={vi.fn()} onCreado={vi.fn()} />);
    const user = userEvent.setup({ delay: 1 });

    await user.type(screen.getByLabelText(/serial/i), "RT58842AA{Enter}");
    await user.click(botones(/siguiente/i));
    await screen.findByLabelText(/documento/i);
    await user.click(botones(/siguiente/i));
    await screen.findByLabelText(/número/i);
    await user.click(botones(/siguiente/i));
    await screen.findAllByRole("checkbox");               // verificación
    await user.click(botones(/siguiente/i));
    await screen.findByLabelText(/fotos/i);               // adjuntos
    await user.click(botones(/siguiente/i));
    await screen.findByRole("button", { name: /confirmar y registrar/i });

    // Editar cliente regresa al paso del titular, montado de nuevo.
    await user.click(screen.getByRole("button", { name: /editar cliente/i }));
    expect(screen.getByLabelText(/documento/i)).toBeTruthy();
  });
});