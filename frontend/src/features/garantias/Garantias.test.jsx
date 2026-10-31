// Tablero de garantías (maqueta 01, /garantias): KPIs, filtros por texto y
// fechas, chips con conteo, orden por vencimiento y salto a la Consulta.
import { render, screen, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, Route, Routes, useLocation } from "react-router-dom";
import { beforeEach, describe, expect, it, vi } from "vitest";

const fakes = vi.hoisted(() => ({ listarGarantias: vi.fn(), rol: "JEFE_SERVICIO" }));
vi.mock("./garantiasService.js", () => fakes);
vi.mock("../auth/AuthContext.jsx", () => ({ useAuth: () => ({ rol: fakes.rol }) }));

import Garantias from "./Garantias.jsx";

const G = (extras = {}) => ({
  equipo_id: "e1",
  numero_serie: "RT5-8842-AA",
  producto: "Huawei HG8245",
  titular: "Juan Perez",
  documento: "V-12345678",
  numero_soporte: "F-200",
  fecha_emision: "2026-10-20",
  plazo_dias: 15,
  vence_el: "2026-11-04",
  dias_restantes: 31,
  origen: "VENTA",
  vigencia: "EN_GARANTIA",
  estado_compra: "CONFIRMADA",
  ...extras,
});

const FILAS = [
  G(),
  G({ equipo_id: "e2", numero_serie: "ZTE-0002", titular: "Ana Lopez", documento: "V-87654321", numero_soporte: "F-201", fecha_emision: "2026-10-28", vence_el: "2026-11-02", dias_restantes: 2 }),
  G({ equipo_id: "e3", numero_serie: "ZTE-0003", titular: "Pedro Gil", fecha_emision: "2026-09-01", vence_el: "2026-09-08", vigencia: "FUERA_DE_GARANTIA", dias_restantes: -4 }),
  G({ equipo_id: "e4", numero_serie: "ZTE-0004", titular: "Marta Salas", origen: "TALLER", vigencia: "POR_DETERMINAR", estado_compra: "PENDIENTE", dias_restantes: null, vence_el: null }),
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
  fakes.rol = "JEFE_SERVICIO";
  fakes.listarGarantias.mockReset().mockResolvedValue({ ok: true, datos: FILAS });
});

const chip = (n) => screen.getByRole("button", { name: new RegExp(`^${n}`) });
const seriales = () => screen.getAllByRole("row").slice(1).map((r) => within(r).getAllByRole("cell")[0].textContent);

describe("Garantias: tablero", () => {
  it("lista serial, titular, equipo, factura y vencimiento de cada garantía", async () => {
    montar();
    expect(await screen.findByText("RT5-8842-AA")).toBeInTheDocument();
    const fila = screen.getByText("RT5-8842-AA").closest("tr");
    expect(fila).toHaveTextContent("Juan Perez");
    expect(fila).toHaveTextContent("Huawei HG8245");
    expect(fila).toHaveTextContent("F-200");
    expect(fila).toHaveTextContent("4 nov");
    expect(fila).toHaveTextContent("31 días");
    expect(fila).toHaveTextContent("Vigente");
  });

  it("los indicadores cuentan todas las garantías, no solo las filtradas", async () => {
    montar();
    await screen.findByText("RT5-8842-AA");
    const kpi = (n) => screen.getByRole("heading", { name: n }).closest("li");
    expect(kpi("Registradas")).toHaveTextContent("4");
    expect(kpi("Registradas")).toHaveTextContent("1 por confirmar");
    expect(kpi("Vigentes")).toHaveTextContent("1");
    expect(kpi("Vencen en 3 días")).toHaveTextContent("1");
    expect(kpi("Vencidas")).toHaveTextContent("1");
  });

  it("los chips clasifican y muestran su conteo", async () => {
    montar();
    await screen.findByText("RT5-8842-AA");
    expect(chip("Todas")).toHaveTextContent("4");
    await userEvent.setup().click(chip("Por vencer"));
    expect(seriales()).toEqual(["ZTE-0002"]);
    await userEvent.setup().click(chip("Vencidas"));
    expect(seriales()).toEqual(["ZTE-0003"]);
    await userEvent.setup().click(chip("Por confirmar"));
    expect(seriales()).toEqual(["ZTE-0004"]);
    expect(screen.getByText("Pendiente de confirmar")).toBeInTheDocument();
    expect(screen.getByText("Registrada en taller")).toBeInTheDocument();
  });

  it("busca por serial, cédula, factura o titular sin importar guiones ni mayúsculas", async () => {
    montar();
    await screen.findByText("RT5-8842-AA");
    const caja = screen.getByRole("searchbox");
    await userEvent.setup().type(caja, "zte 0002");
    expect(seriales()).toEqual(["ZTE-0002"]);
    await userEvent.setup().clear(caja);
    await userEvent.setup().type(caja, "v87654321");
    expect(seriales()).toEqual(["ZTE-0002"]);
    await userEvent.setup().click(screen.getByRole("button", { name: "Borrar la búsqueda" }));
    expect(seriales()).toHaveLength(4);
  });

  it("filtra por fecha de emisión y permite quitar las fechas", async () => {
    montar();
    await screen.findByText("RT5-8842-AA");
    await userEvent.setup().type(screen.getByLabelText("Emitida desde"), "2026-10-25");
    expect(seriales()).toEqual(["ZTE-0002"]);
    await userEvent.setup().click(screen.getByRole("button", { name: "Quitar fechas" }));
    expect(seriales()).toHaveLength(4);
  });

  it("ordena por vencimiento y se invierte con el encabezado", async () => {
    montar();
    await screen.findByText("RT5-8842-AA");
    expect(seriales()).toEqual(["ZTE-0003", "ZTE-0002", "RT5-8842-AA", "ZTE-0004"]);
    await userEvent.setup().click(screen.getByRole("button", { name: /Vence/ }));
    expect(seriales()).toEqual(["ZTE-0004", "RT5-8842-AA", "ZTE-0002", "ZTE-0003"]);
  });

  it("sin coincidencias ofrece registrar la garantía", async () => {
    montar();
    await screen.findByText("RT5-8842-AA");
    await userEvent.setup().type(screen.getByRole("searchbox"), "inexistente");
    expect(screen.getByText("No hay garantías con esos criterios")).toBeInTheDocument();
    await userEvent.setup().click(screen.getByRole("button", { name: "Registrar garantía" }));
    expect(await screen.findByText("/garantias/nueva")).toBeInTheDocument();
  });

  it("«Ver» abre la Consulta con el serial", async () => {
    montar();
    await screen.findByText("RT5-8842-AA");
    await userEvent.setup().click(screen.getByRole("button", { name: /Ver garantía RT5-8842-AA/ }));
    expect(await screen.findByText("/garantias/consulta?serial=RT5-8842-AA")).toBeInTheDocument();
  });

  it("«Nueva garantía» lleva al asistente", async () => {
    montar();
    await userEvent.setup().click(screen.getByRole("button", { name: "Nueva garantía" }));
    expect(await screen.findByText("/garantias/nueva")).toBeInTheDocument();
  });

  it("muestra el error de la base", async () => {
    fakes.listarGarantias.mockResolvedValue({ ok: false, codigo: "SIN_PERMISO", mensaje: "permission denied" });
    montar();
    expect(await screen.findByRole("alert")).toHaveTextContent("permission denied");
  });
});

describe("Garantias: Ventas", () => {
  it("muestra el respaldo de Ventas de cada equipo", async () => {
    fakes.listarGarantias.mockResolvedValue({
      ok: true,
      datos: [G({ verificacion: "COINCIDE" }), G({ equipo_id: "e2", numero_serie: "ZTE-0002", verificacion: "DIFIERE" })],
    });
    montar();
    expect(await screen.findByText("Respaldada por Ventas")).toBeInTheDocument();
    expect(screen.getByText("No coincide: revisar")).toBeInTheDocument();
  });

  it.each(["ADMIN", "JEFE_SERVICIO"])("%s ve el enlace para importar ventas", async (rol) => {
    fakes.rol = rol;
    montar();
    await screen.findByText("RT5-8842-AA");
    expect(screen.getByRole("link", { name: "Importar ventas" })).toHaveAttribute("href", "/ventas/importar");
  });

  it.each(["TECNICO", "RECEPCION"])("%s no lo ve", async (rol) => {
    fakes.rol = rol;
    montar();
    await screen.findByText("RT5-8842-AA");
    expect(screen.queryByRole("link", { name: "Importar ventas" })).toBeNull();
  });
});
