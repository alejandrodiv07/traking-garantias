// Asistente de 4 pasos para registrar la garantía de la venta (Tarea 13 del plan).
// Reutiliza PasoCliente y PasoCompra del Hito 1; los servicios se simulan en el borde.
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, Route, Routes, useLocation } from "react-router-dom";
import { beforeEach, describe, expect, it, vi } from "vitest";

const fakes = vi.hoisted(() => ({
  buscarCliente: vi.fn(),
  guardarCliente: vi.fn(),
  listarProductos: vi.fn(),
  registrarGarantia: vi.fn(),
  rol: "TECNICO",
}));

vi.mock("../registro/registroService.js", () => fakes);
vi.mock("./garantiasService.js", () => fakes);
vi.mock("../auth/AuthContext.jsx", () => ({
  useAuth: () => ({ rol: fakes.rol, perfil: { id: "u1" } }),
}));

import NuevaGarantia from "./NuevaGarantia.jsx";

function Destino() {
  const l = useLocation();
  return <p>Consulta {l.search}</p>;
}

const montar = (ruta = "/garantias/nueva") =>
  render(
    <MemoryRouter initialEntries={[ruta]}>
      <Routes>
        <Route path="/garantias/nueva" element={<NuevaGarantia />} />
        <Route path="/garantias/consulta" element={<Destino />} />
      </Routes>
    </MemoryRouter>,
  );

const siguiente = () => userEvent.setup().click(screen.getByRole("button", { name: "Siguiente" }));

async function llegarACompra(usuario) {
  await usuario.type(screen.getByLabelText(/Documento/), "12345678");
  await screen.findByText(/Titular: Juan Perez/);
  await siguiente();
  await usuario.type(screen.getByLabelText("Serial"), "RT5-8842-AA");
  await usuario.selectOptions(await screen.findByLabelText("Marca"), "Huawei");
  await usuario.selectOptions(screen.getByLabelText("Modelo"), "p1");
  await siguiente();
}

async function llenarCompra(usuario, plazo) {
  await usuario.type(screen.getByLabelText("Número"), "F-200");
  fireEvent.change(screen.getByLabelText("Fecha de emisión"), { target: { value: "2026-10-20" } });
  await usuario.selectOptions(screen.getByLabelText("Plazo de garantía"), plazo);
}

beforeEach(() => {
  fakes.rol = "TECNICO";
  fakes.buscarCliente.mockReset().mockResolvedValue({
    ok: true,
    datos: { id: "c1", tipo_documento: "V", documento: "12345678", nombre: "Juan Perez", telefono: null },
  });
  fakes.guardarCliente.mockReset();
  fakes.listarProductos.mockReset().mockResolvedValue({
    ok: true,
    datos: [{ id: "p1", marca: { nombre: "Huawei" }, modelo: "HG8245" }],
  });
  fakes.registrarGarantia.mockReset().mockResolvedValue({
    ok: true,
    datos: { equipo_id: "e1", vence_el: "2026-10-27", equipo_nuevo: true },
  });
});

describe("NuevaGarantia", () => {
  it("no deja avanzar del cliente sin titular", () => {
    montar();
    expect(screen.getByRole("button", { name: "Siguiente" })).toBeDisabled();
  });

  it("no pide falla, checklist ni fotos: solo cliente, equipo, compra y resumen", () => {
    montar();
    expect(screen.queryByLabelText(/Falla/)).toBeNull();
    expect(screen.getAllByRole("listitem").map((li) => li.textContent)).toEqual([
      "Cliente",
      "Equipo",
      "Compra",
      "Resumen",
    ]);
  });

  it("registra la garantía de la venta y lleva a la consulta con el serial", async () => {
    const usuario = userEvent.setup();
    montar();
    await llegarACompra(usuario);
    await llenarCompra(usuario, "7");
    await siguiente();

    expect(screen.getByText(/RT5-8842-AA/)).toBeTruthy();
    await usuario.click(screen.getByRole("button", { name: "Registrar garantía" }));

    await waitFor(() =>
      expect(fakes.registrarGarantia).toHaveBeenCalledWith({
        clienteId: "c1",
        productoId: "p1",
        serial: "RT5-8842-AA",
        tipoSoporte: "FACTURA",
        numeroSoporte: "F-200",
        fechaEmision: "2026-10-20",
        plazoDias: 7,
        origen: "VENTA",
      }),
    );
    expect(await screen.findByText("Consulta ?serial=RT5-8842-AA")).toBeTruthy();
  });

  it("avisa que solo el jefe fija un plazo distinto de 7/15, pero no bloquea (decide la base)", async () => {
    const usuario = userEvent.setup();
    montar();
    await llegarACompra(usuario);
    await llenarCompra(usuario, "30");
    expect(screen.getByText(/solo el jefe puede fijar ese plazo/i)).toBeTruthy();
    await siguiente();
    expect(screen.getByRole("button", { name: "Registrar garantía" })).toBeEnabled();
  });

  it("no avisa del plazo al jefe", async () => {
    fakes.rol = "JEFE_SERVICIO";
    const usuario = userEvent.setup();
    montar();
    await llegarACompra(usuario);
    await llenarCompra(usuario, "30");
    expect(screen.queryByText(/solo el jefe puede fijar ese plazo/i)).toBeNull();
  });

  it("muestra el rechazo de la base y se queda en el resumen", async () => {
    fakes.registrarGarantia.mockResolvedValue({
      ok: false,
      codigo: "SIN_PERMISO",
      mensaje: "los plazos distintos de 7 o 15 días solo los fija el jefe",
    });
    const usuario = userEvent.setup();
    montar();
    await llegarACompra(usuario);
    await llenarCompra(usuario, "30");
    await siguiente();
    await usuario.click(screen.getByRole("button", { name: "Registrar garantía" }));
    expect((await screen.findByRole("alert")).textContent).toMatch(/solo los fija el jefe/);
    expect(screen.queryByText(/^Consulta/)).toBeNull();
  });

  it("llegando de la Consulta (?serial=&origen=TALLER) precarga el serial y registra con origen TALLER", async () => {
    const usuario = userEvent.setup();
    montar("/garantias/nueva?serial=ABC-999&origen=TALLER");
    await usuario.type(screen.getByLabelText(/Documento/), "12345678");
    await screen.findByText(/Titular: Juan Perez/);
    await siguiente();
    expect(screen.getByLabelText("Serial")).toHaveValue("ABC-999");
    await usuario.selectOptions(await screen.findByLabelText("Marca"), "Huawei");
    await usuario.selectOptions(screen.getByLabelText("Modelo"), "p1");
    await siguiente();
    await siguiente();
    await usuario.click(screen.getByRole("button", { name: "Registrar garantía" }));
    await waitFor(() =>
      expect(fakes.registrarGarantia).toHaveBeenCalledWith(
        expect.objectContaining({ serial: "ABC-999", origen: "TALLER" }),
      ),
    );
  });
});
