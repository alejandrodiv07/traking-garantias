// Lista de órdenes del Taller (Tarea 17 del plan; spec §8): chips por estado,
// filas que abren el detalle y estado vacío. Los datos salen de v_tablero.
import { render, screen, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, Route, Routes, useLocation } from "react-router-dom";
import { beforeEach, describe, expect, it, vi } from "vitest";

const fakes = vi.hoisted(() => ({ listarTablero: vi.fn() }));
vi.mock("../tablero/tableroService.js", () => fakes);

import Taller from "./Taller.jsx";

const FILA = (extras = {}) => ({
  orden_id: "o1",
  numero_orden: "OS-2026-0001",
  estado: "RECIBIDO",
  estado_nombre: "Recibido",
  cobertura: "EN_GARANTIA",
  cliente: "Juan Perez",
  producto: "Huawei HG8245",
  serial: "RT5-8842-AA",
  fecha_ingreso: "2026-10-25T14:00:00+00:00",
  nivel_vigencia: "PRONTO",
  dias_restantes: 5,
  abierto: true,
  ...extras,
});

const FILAS = [
  FILA(),
  FILA({ orden_id: "o2", numero_orden: "OS-2026-0002", cliente: "Ana Gomez", estado: "EN_REPARACION", estado_nombre: "En reparación" }),
  FILA({ orden_id: "o3", numero_orden: "OS-2026-0003", cliente: "Luis Diaz", estado: "RECHAZADO", estado_nombre: "Rechazado" }),
];

function Destino() {
  return <p>{useLocation().pathname}</p>;
}

const montar = () =>
  render(
    <MemoryRouter initialEntries={["/taller"]}>
      <Routes>
        <Route path="/taller" element={<Taller />} />
        <Route path="*" element={<Destino />} />
      </Routes>
    </MemoryRouter>,
  );

beforeEach(() => {
  fakes.listarTablero.mockReset().mockResolvedValue({ ok: true, filas: FILAS });
});

describe("Taller", () => {
  it("lista las órdenes con número, cliente, equipo y estado", async () => {
    montar();
    expect(await screen.findByText("OS-2026-0001")).toBeTruthy();
    const fila = screen.getByText("OS-2026-0001").closest("tr");
    expect(within(fila).getByText("Juan Perez")).toBeTruthy();
    expect(within(fila).getByText("Huawei HG8245")).toBeTruthy();
    expect(within(fila).getByText("Recibido")).toBeTruthy();
  });

  it("el clic en una fila abre el detalle de la orden", async () => {
    montar();
    await userEvent.setup().click(await screen.findByText("Ana Gomez"));
    expect(await screen.findByText("/taller/o2")).toBeTruthy();
  });

  it("los chips filtran por estado; En reparación incluye En espera de repuesto", async () => {
    fakes.listarTablero.mockResolvedValue({
      ok: true,
      filas: [...FILAS, FILA({ orden_id: "o4", numero_orden: "OS-2026-0004", estado: "EN_ESPERA_REPUESTO", estado_nombre: "En espera de repuesto" })],
    });
    const usuario = userEvent.setup();
    montar();
    await screen.findByText("OS-2026-0001");
    await usuario.click(screen.getByRole("button", { name: "En reparación" }));
    expect(screen.getByText("OS-2026-0002")).toBeTruthy();
    expect(screen.getByText("OS-2026-0004")).toBeTruthy();
    expect(screen.queryByText("OS-2026-0001")).toBeNull();
  });

  it("hay un chip Rechazado", async () => {
    const usuario = userEvent.setup();
    montar();
    await screen.findByText("OS-2026-0001");
    await usuario.click(screen.getByRole("button", { name: "Rechazado" }));
    expect(screen.getByText("OS-2026-0003")).toBeTruthy();
    expect(screen.queryByText("OS-2026-0002")).toBeNull();
  });

  it("sin órdenes muestra el estado vacío", async () => {
    fakes.listarTablero.mockResolvedValue({ ok: true, filas: [] });
    montar();
    expect(await screen.findByText(/No hay órdenes/)).toBeTruthy();
  });

  it("muestra el error del servicio", async () => {
    fakes.listarTablero.mockResolvedValue({ ok: false, codigo: "SIN_CONEXION", mensaje: "Sin conexión" });
    montar();
    expect((await screen.findByRole("alert")).textContent).toMatch(/Sin conexión/);
  });

  it("Nueva orden lleva a la consulta, donde se elige el equipo", async () => {
    montar();
    await userEvent.setup().click(await screen.findByRole("button", { name: "Nueva orden" }));
    expect(await screen.findByText("/garantias/consulta")).toBeTruthy();
  });
});
