// Pruebas del paso 1 del asistente: el serial (Tarea 17 del plan; spec §7.1).
// Requisitos probados: foco inicial, búsqueda por Enter o pausa de 400 ms con
// 3+ caracteres, reutilización de equipo, advertencia por producto distinto.
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";

const fakes = vi.hoisted(() => ({
  buscarEquipo: vi.fn(),
  listarProductos: vi.fn(),
}));

vi.mock("../registroService.js", () => fakes);

import PasoEquipo from "./PasoEquipo.jsx";

const EQUIPO_EXISTENTE = [{
  equipo_id: "e1",
  producto_id: "p1",
  producto: "Huawei HG8245",
  numero_serie: "RT5-8842-AA",
  titular: "Juan Perez",
  vence_el: "2026-09-08",
  dias_restantes: 5,
  registros: [{ numero: "REG-2026-000001", estado: "ENTREGADO" }],
}];
const PRODUCTOS = [
  { id: "p1", modelo: "HG8245", marca: "Huawei" },
  { id: "p2", modelo: "Archer C6", marca: "TP-Link" },
];

beforeEach(() => {
  fakes.buscarEquipo.mockReset().mockResolvedValue({ ok: true, datos: [] });
  fakes.listarProductos.mockReset().mockResolvedValue({ ok: true, datos: PRODUCTOS });
});

const base = { actualizar: vi.fn(), estado: {} };
const renderPaso = (props = {}) => render(<PasoEquipo {...base} {...props} />);

describe("el campo del serial", () => {
  it("recibe el foco al abrir el asistente (lector de código listo)", () => {
    renderPaso();
    expect(screen.getByLabelText(/serial/i)).toBe(document.activeElement);
  });
});

it("escribe RT5-8842-AA rápido y Enter dispara UNA búsqueda", async () => {
  const user = userEvent.setup();
  renderPaso();
  const campo = screen.getByLabelText(/serial/i);
  await user.type(campo, "RT5-8842-AA{Enter}");
  expect(fakes.buscarEquipo).toHaveBeenCalledTimes(1);
  expect(fakes.buscarEquipo).toHaveBeenCalledWith("RT5-8842-AA");
});

it("escribe y espera 400 ms: la búsqueda se dispara sola", async () => {
  const user = userEvent.setup();
  renderPaso();
  await user.type(screen.getByLabelText(/serial/i), "RT5-8842-AA");
  await waitFor(() => expect(fakes.buscarEquipo).toHaveBeenCalled(),
    { timeout: 1500 });
  expect(fakes.buscarEquipo).toHaveBeenCalledWith("RT5-8842-AA");
});

it("con 2 caracteres (o menos) no se dispara la búsqueda, ni tras la pausa", async () => {
  const user = userEvent.setup({ delay: 1 });
  renderPaso();
  await user.type(screen.getByLabelText(/serial/i), "RT");
  await new Promise((r) => setTimeout(r, 700));   // más que la pausa de 400 ms
  expect(fakes.buscarEquipo).not.toHaveBeenCalled();
});

it("Enter no envía ni cierra el formulario (no dispara submit)", async () => {
  const user = userEvent.setup();
  const onEnviar = vi.fn();
  render(
    <form onSubmit={onEnviar}>
      <PasoEquipo {...base} />
    </form>,
  );
  await user.type(screen.getByLabelText(/serial/i), "ABC{Enter}");
  expect(onEnviar).not.toHaveBeenCalled();
});

describe("resultado de la búsqueda", () => {
  it("equipo existente: muestra titular, vigencia e historial y marca reutilizado", async () => {
    fakes.buscarEquipo.mockResolvedValue({ ok: true, datos: EQUIPO_EXISTENTE });
    const actualizar = vi.fn();
    renderPaso({ actualizar });
    await userEvent.setup({ delay: 1 }).type(screen.getByLabelText(/serial/i), "RT5-8842-AA");
    await waitFor(() => expect(screen.getByText(/Juan Perez/)).toBeTruthy());
    expect(screen.getByText(/vence/i) || screen.getByText(/vigencia/i)).toBeTruthy();
    expect(actualizar).toHaveBeenCalledWith(
      expect.objectContaining({
        equipoReutilizado: true,
        equipoId: "e1",
        serial: "RT5-8842-AA",
        productoId: "p1",
      }),
    );
  });

  it("serial repetido con OTRO producto: advierte y no crea sin confirmar", async () => {
    fakes.buscarEquipo.mockResolvedValue({
      ok: true,
      datos: [
        ...EQUIPO_EXISTENTE,
        { ...EQUIPO_EXISTENTE[0], producto: "TP-Link Archer C6", producto_id: "p2", equipo_id: "e2" },
      ],
    });
    const actualizar = vi.fn();
    renderPaso({ actualizar });
    await userEvent.setup({ delay: 1 }).type(screen.getByLabelText(/serial/i), "RT5-8842-AA");
    await waitFor(() => expect(screen.getByText(/este serial está registrado/i)).toBeTruthy());
    // sin confirmar no marca reutilizado automáticamente
    expect(actualizar).not.toHaveBeenCalledWith(expect.objectContaining({ equipoReutilizado: true }));
  });

  it("serial nuevo pide marca y modelo con el catálogo", async () => {
    renderPaso();
    await userEvent.setup({ delay: 1 }).type(screen.getByLabelText(/serial/i), "ABCDEF");
    await waitFor(() => expect(screen.getByLabelText(/marca/i)).toBeTruthy());
    expect(screen.getByLabelText(/modelo/i)).toBeTruthy();
  });
});