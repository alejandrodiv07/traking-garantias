// Consulta de garantía (Tarea 14 del plan; spec §8): buscador único sobre
// buscar_equipo, ficha con cobertura e historial, y los saltos a registrar / abrir orden.
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, Route, Routes, useLocation } from "react-router-dom";
import { beforeEach, describe, expect, it, vi } from "vitest";

const fakes = vi.hoisted(() => ({ buscarGarantia: vi.fn() }));
vi.mock("./garantiasService.js", () => fakes);

import Consulta from "./Consulta.jsx";

const EQUIPO = (extras = {}) => ({
  equipo_id: "e1",
  producto: "Huawei HG8245",
  numero_serie: "RT5-8842-AA",
  titular: "Juan Perez",
  documento: "12345678",
  numero_soporte: "F-200",
  fecha_emision: "2026-10-20",
  plazo_dias: 15,
  vence_el: "2026-11-04",
  dias_restantes: 5,
  origen: "VENTA",
  vigencia: "EN_GARANTIA",
  estado_compra: "CONFIRMADA",
  motivo_desestimacion: null,
  ordenes: [],
  ...extras,
});

function Destino() {
  const l = useLocation();
  return <p>{l.pathname}{l.search}</p>;
}

const montar = (ruta = "/garantias/consulta") =>
  render(
    <MemoryRouter initialEntries={[ruta]}>
      <Routes>
        <Route path="/garantias/consulta" element={<Consulta />} />
        <Route path="*" element={<Destino />} />
      </Routes>
    </MemoryRouter>,
  );

async function buscar(usuario, criterio, texto) {
  await usuario.selectOptions(screen.getByLabelText("Buscar por"), criterio);
  await usuario.type(screen.getByLabelText("Valor"), texto);
  await usuario.click(screen.getByRole("button", { name: "Buscar" }));
}

beforeEach(() => {
  fakes.buscarGarantia.mockReset().mockResolvedValue({ ok: true, datos: [EQUIPO()] });
});

describe("Consulta: buscador", () => {
  it.each([
    ["serial", "RT5-8842-AA", { serial: "RT5-8842-AA" }],
    ["documento", "12345678", { documento: "12345678" }],
    ["factura", "F-200", { factura: "F-200" }],
    ["orden", "OS-2026-0001", { orden: "OS-2026-0001" }],
  ])("busca por %s con un solo criterio", async (criterio, texto, esperado) => {
    montar();
    await buscar(userEvent.setup(), criterio, texto);
    await waitFor(() => expect(fakes.buscarGarantia).toHaveBeenCalledWith(esperado));
  });

  it("busca sola cuando llega ?serial= (venir de registrar la garantía)", async () => {
    montar("/garantias/consulta?serial=RT5-8842-AA");
    await waitFor(() =>
      expect(fakes.buscarGarantia).toHaveBeenCalledWith({ serial: "RT5-8842-AA" }),
    );
    expect(await screen.findByText("Huawei HG8245")).toBeTruthy();
  });

  it("muestra el error de la base", async () => {
    fakes.buscarGarantia.mockResolvedValue({ ok: false, codigo: "SIN_CONEXION", mensaje: "Sin conexión" });
    montar();
    await buscar(userEvent.setup(), "serial", "RT5");
    expect((await screen.findByRole("alert")).textContent).toMatch(/Sin conexión/);
  });
});

describe("Consulta: resultado", () => {
  it("muestra producto, serial, titular, periodo, cobertura y días restantes", async () => {
    montar("/garantias/consulta?serial=RT5-8842-AA");
    expect(await screen.findByText("Huawei HG8245")).toBeTruthy();
    expect(screen.getByText("RT5-8842-AA")).toBeTruthy();
    expect(screen.getByText(/Juan Perez/)).toBeTruthy();
    expect(screen.getByText(/2026-10-20/)).toBeTruthy();
    expect(screen.getByText(/2026-11-04/)).toBeTruthy();
    expect(screen.getByText("En garantía")).toHaveAttribute("data-tono", "resuelto");
    expect(screen.getByText(/5 días restantes/)).toBeTruthy();
  });

  it("una garantía vencida lo dice", async () => {
    fakes.buscarGarantia.mockResolvedValue({
      ok: true,
      datos: [EQUIPO({ vigencia: "FUERA_DE_GARANTIA", dias_restantes: -3 })],
    });
    montar("/garantias/consulta?serial=RT5");
    expect(await screen.findByText("Fuera de garantía")).toBeTruthy();
    expect(screen.getByText(/Vencida/)).toBeTruthy();
  });

  it("una compra desestimada muestra el motivo", async () => {
    fakes.buscarGarantia.mockResolvedValue({
      ok: true,
      datos: [EQUIPO({
        vigencia: "FUERA_DE_GARANTIA",
        estado_compra: "DESESTIMADA",
        motivo_desestimacion: "La factura no corresponde al equipo",
      })],
    });
    montar("/garantias/consulta?serial=RT5");
    expect(await screen.findByText(/La factura no corresponde al equipo/)).toBeTruthy();
  });

  it("lista el historial de órdenes del equipo", async () => {
    fakes.buscarGarantia.mockResolvedValue({
      ok: true,
      datos: [EQUIPO({
        ordenes: [{
          numero_orden: "OS-2026-0007",
          estado: "EN_DIAGNOSTICO",
          estado_nombre: "En diagnóstico",
          cobertura: "EN_GARANTIA",
          tipo_atencion: "GARANTIA",
          fecha_ingreso: "2026-10-25T10:00:00+00:00",
        }],
      })],
    });
    montar("/garantias/consulta?serial=RT5");
    expect(await screen.findByText("OS-2026-0007")).toBeTruthy();
    expect(screen.getByText("En diagnóstico")).toBeTruthy();
  });

  it("varios equipos con el mismo serial salen todos", async () => {
    fakes.buscarGarantia.mockResolvedValue({
      ok: true,
      datos: [EQUIPO(), EQUIPO({ equipo_id: "e2", producto: "ZTE F670L" })],
    });
    montar("/garantias/consulta?serial=RT5");
    expect(await screen.findByText("Huawei HG8245")).toBeTruthy();
    expect(screen.getByText("ZTE F670L")).toBeTruthy();
  });
});

describe("Consulta: acciones", () => {
  it("sin resultados ofrece registrar ahora con origen TALLER", async () => {
    fakes.buscarGarantia.mockResolvedValue({ ok: true, datos: [] });
    montar("/garantias/consulta?serial=ABC-999");
    expect(await screen.findByText("No hay garantía registrada")).toBeTruthy();
    await userEvent.setup().click(screen.getByRole("button", { name: "Registrar ahora" }));
    expect(
      await screen.findByText("/garantias/nueva?serial=ABC-999&origen=TALLER"),
    ).toBeTruthy();
  });

  it("abrir orden lleva al taller con el equipo", async () => {
    montar("/garantias/consulta?serial=RT5");
    await userEvent.setup().click(await screen.findByRole("button", { name: "Abrir orden de servicio" }));
    expect(await screen.findByText("/taller/nueva?equipo=e1")).toBeTruthy();
  });

  it("en garantía no avisa nada antes de abrir la orden", async () => {
    montar("/garantias/consulta?serial=RT5");
    await screen.findByText("Huawei HG8245");
    expect(screen.queryByText(/servicio pago/)).toBeNull();
    expect(screen.queryByText(/pendiente de confirmar/)).toBeNull();
  });

  it.each([
    ["FUERA_DE_GARANTIA", /se atenderá como servicio pago/],
    ["POR_DETERMINAR", /cobertura pendiente de confirmar/],
  ])("con vigencia %s avisa antes de abrir la orden", async (vigencia, aviso) => {
    fakes.buscarGarantia.mockResolvedValue({ ok: true, datos: [EQUIPO({ vigencia })] });
    montar("/garantias/consulta?serial=RT5");
    expect(await screen.findByText(aviso)).toBeTruthy();
  });

  it("avisa si el equipo ya tiene una orden abierta", async () => {
    fakes.buscarGarantia.mockResolvedValue({
      ok: true,
      datos: [EQUIPO({
        ordenes: [{ numero_orden: "OS-2026-0007", estado: "EN_REPARACION", estado_nombre: "En reparación", cobertura: "EN_GARANTIA", tipo_atencion: "GARANTIA", fecha_ingreso: "2026-10-25T10:00:00+00:00" }],
      })],
    });
    montar("/garantias/consulta?serial=RT5");
    expect(await screen.findByText(/ya tiene una orden abierta/)).toBeTruthy();
  });
});
