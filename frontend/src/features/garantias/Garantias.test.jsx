// Tablero de garantías (maqueta 01, /garantias): una fila por equipo, chips por
// estado de la garantía y salto a la Consulta.
import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, Route, Routes, useLocation } from "react-router-dom";
import { beforeEach, describe, expect, it, vi } from "vitest";

const fakes = vi.hoisted(() => ({ listarGarantias: vi.fn() }));
vi.mock("./garantiasService.js", () => fakes);

import Garantias from "./Garantias.jsx";

const G = (extras = {}) => ({
  equipo_id: "e1",
  numero_serie: "RT5-8842-AA",
  producto: "Huawei HG8245",
  titular: "Juan Perez",
  documento: "12345678",
  numero_soporte: "F-200",
  fecha_emision: "2026-10-20",
  vence_el: "2026-11-30",
  dias_restantes: 31,
  vigencia: "EN_GARANTIA",
  estado_compra: "CONFIRMADA",
  ...extras,
});

const FILAS = [
  G(),
  G({ equipo_id: "e2", numero_serie: "ZTE-0002", dias_restantes: 2 }),
  G({ equipo_id: "e3", numero_serie: "ZTE-0003", vigencia: "FUERA_DE_GARANTIA", dias_restantes: -4 }),
  G({ equipo_id: "e4", numero_serie: "ZTE-0004", vigencia: "POR_DETERMINAR", estado_compra: "PENDIENTE", dias_restantes: null, vence_el: null }),
];

function Destino() {
  const l = useLocation();
  return <p>{l.pathname + l.search}</p>;
}

const montar = () =>
  render(
    <MemoryRouter initialEntries={["/garantias"]}>
      <Routes>
        <Route path="/garantias" element={<Garantias />} />
        <Route path="*" element={<Destino />} />
      </Routes>
    </MemoryRouter>,
  );

beforeEach(() => {
  fakes.listarGarantias.mockReset().mockResolvedValue({ ok: true, datos: FILAS });
});

const chip = (n) => screen.getByRole("button", { name: n });

describe("Garantias", () => {
  it("lista serial, titular, equipo, factura y vencimiento", async () => {
    montar();
    expect(await screen.findByText("RT5-8842-AA")).toBeTruthy();
    const fila = screen.getByText("RT5-8842-AA").closest("tr");
    expect(fila.textContent).toMatch(/Juan Perez/);
    expect(fila.textContent).toMatch(/Huawei HG8245/);
    expect(fila.textContent).toMatch(/F-200/);
    expect(fila.textContent).toMatch(/2026-11-30/);
  });

  it.each([
    ["Vigente", ["RT5-8842-AA", "ZTE-0002"], ["ZTE-0003", "ZTE-0004"]],
    ["Por vencer", ["ZTE-0002"], ["RT5-8842-AA", "ZTE-0003"]],
    ["Vencida", ["ZTE-0003"], ["RT5-8842-AA", "ZTE-0004"]],
    ["Por confirmar", ["ZTE-0004"], ["RT5-8842-AA", "ZTE-0003"]],
  ])("el chip %s filtra", async (nombre, visibles, ocultas) => {
    montar();
    await screen.findByText("RT5-8842-AA");
    await userEvent.setup().click(chip(nombre));
    for (const s of visibles) expect(screen.getByText(s)).toBeTruthy();
    for (const s of ocultas) expect(screen.queryByText(s)).toBeNull();
  });

  it("la búsqueda va a la base", async () => {
    montar();
    await screen.findByText("RT5-8842-AA");
    await userEvent.setup().type(screen.getByLabelText("Buscar"), "ZTE");
    await vi.waitFor(() =>
      expect(fakes.listarGarantias).toHaveBeenLastCalledWith({ busqueda: "ZTE" }),
    );
  });

  it("una fila abre la Consulta con su serial", async () => {
    montar();
    await userEvent.setup().click(await screen.findByText("ZTE-0003"));
    expect(await screen.findByText("/garantias/consulta?serial=ZTE-0003")).toBeTruthy();
  });

  it("Nueva garantía lleva al asistente", async () => {
    montar();
    await userEvent.setup().click(await screen.findByRole("button", { name: "Nueva garantía" }));
    expect(await screen.findByText("/garantias/nueva")).toBeTruthy();
  });

  it("estado vacío y error", async () => {
    fakes.listarGarantias.mockResolvedValueOnce({ ok: true, datos: [] });
    montar();
    expect(await screen.findByText(/No hay garantías/)).toBeTruthy();
  });

  it("muestra el error del servicio", async () => {
    fakes.listarGarantias.mockResolvedValue({ ok: false, mensaje: "Sin conexión" });
    montar();
    expect((await screen.findByRole("alert")).textContent).toMatch(/Sin conexión/);
  });
});
