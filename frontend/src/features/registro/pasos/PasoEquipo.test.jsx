// Pruebas del paso 1 del asistente: el serial (Tarea 17 del plan; spec §7.1)
// y la falla reportada (corrección D5; obligatoria, de 5 a 2000 caracteres).
// Requisitos probados: foco inicial, búsqueda por Enter o pausa de 400 ms con
// 3+ caracteres, reutilización de equipo, advertencia por producto distinto.
import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
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

// Los pasos que solo renderizan y asercan terminan antes de que la carga del
// catálogo resuelva; su setState cae fuera de act y React amaga. Esta espera
// lo consume DENTRO de act. Debe llamarse en pruebas de render directo.
async function cargarCatalogoEnAct() {
  await act(async () => {
    await Promise.resolve();
    await Promise.resolve();
  });
}

describe("el campo del serial", () => {
  it("recibe el foco al abrir el asistente (lector de código listo)", async () => {
    renderPaso();
    expect(screen.getByLabelText(/serial/i)).toBe(document.activeElement);
    await cargarCatalogoEnAct();
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

describe("la falla reportada (en el paso equipo, corregida en D5)", () => {
  it("al abrir el asistente el campo de la falla está vacío y es de entrada multilinea", async () => {
    renderPaso();
    const campo = screen.getByLabelText(/falla reportada/i);
    expect(campo.tagName).toBe("TEXTAREA");
    expect(campo).toHaveValue("");
    await cargarCatalogoEnAct();
  });

  it("escribe una falla corta (de menos de 5) y aparece el error de 5 a 2000", async () => {
    const user = userEvent.setup();
    renderPaso();
    await user.type(screen.getByLabelText(/falla reportada/i), "casa");
    expect(screen.getByText("La falla va de 5 a 2000 caracteres")).toBeTruthy();
  });

  it("' hola ' (espacios de más) no engaña el mínimo: pide el rango de 5 a 2000", async () => {
    // La base mide length(btrim(...)): 5 caracteres de relleno NO deben pasar.
    const user = userEvent.setup();
    renderPaso();
    await user.type(screen.getByLabelText(/falla reportada/i), " hola ");
    expect(screen.getByText("La falla va de 5 a 2000 caracteres")).toBeTruthy();
  });

  it("borra la falla y avisa que es obligatoria", async () => {
    const user = userEvent.setup();
    renderPaso();
    const campo = screen.getByLabelText(/falla reportada/i);
    await user.type(campo, "No enciende");
    await user.clear(campo);
    expect(screen.getByText("La falla reportada es obligatoria")).toBeTruthy();
  });

  it("escribe una falla de 5+ caracteres y compromete actualizar({ falla })", async () => {
    const user = userEvent.setup();
    const actualizar = vi.fn();
    renderPaso({ actualizar });
    await user.type(screen.getByLabelText(/falla reportada/i), "No enciende");
    expect(actualizar).toHaveBeenCalledWith(
      expect.objectContaining({ falla: "No enciende" }),
    );
  });

  it("con más de 2000 caracteres trunca a 2000 y avisa el máximo", async () => {
    renderPaso();
    const campo = screen.getByLabelText(/falla reportada/i);
    expect(campo).toHaveAttribute("maxLength", "2000");
    fireEvent.change(campo, { target: { value: "x".repeat(2100) } });
    expect(campo).toHaveValue("x".repeat(2000));
    expect(screen.getByText(/llegaste al máximo/i)).toBeTruthy();
    await cargarCatalogoEnAct();
  });

  it("sin tocar el campo no asusta de entrada: el aviso de obligatoria sale al interactuar", async () => {
    renderPaso();
    expect(screen.queryByText("La falla reportada es obligatoria")).toBeNull();
    await cargarCatalogoEnAct();
  });
});