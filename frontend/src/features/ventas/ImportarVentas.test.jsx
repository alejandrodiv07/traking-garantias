// Pantalla /ventas/importar: vista previa del CSV, importación de las filas
// válidas, resumen y descarga de las filas con error.
import { render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter } from "react-router-dom";
import { beforeEach, describe, expect, it, vi } from "vitest";

const fakes = vi.hoisted(() => ({ importarVentas: vi.fn() }));
vi.mock("./ventasService.js", () => fakes);

import ImportarVentas from "./ImportarVentas.jsx";

const CAB = "numero_factura;fecha_emision;tipo_documento;numero_documento;nombre_cliente;serial;modelo";
const CSV = [
  CAB,
  "F-1;2026-10-20;V;12345678;Juan Perez;RT5-1;HG8245",
  "F-2;2026-10-20;V;87654321;Ana Lopez;RT5-2;HG8245",
  "F-3;ayer;V;1;Mal Fecha;RT5-3;HG8245",
].join("\n");

// jsdom no implementa File.text() / Blob.text() (los navegadores sí).
const archivo = (texto, nombre = "ventas.csv") =>
  Object.assign(new File([texto], nombre, { type: "text/csv" }), { text: async () => texto });
const leer = (blob) =>
  new Promise((ok) => {
    const r = new FileReader();
    r.onload = () => ok(r.result);
    r.readAsText(blob);
  });

async function subir(texto, nombre) {
  const usuario = userEvent.setup();
  render(
    <MemoryRouter>
      <ImportarVentas />
    </MemoryRouter>,
  );
  await usuario.upload(screen.getByLabelText(/archivo csv/i), archivo(texto, nombre));
  return usuario;
}

beforeEach(() => {
  fakes.importarVentas.mockReset().mockResolvedValue({
    ok: true,
    datos: { nuevas: 1, actualizadas: 1, con_error: 0, confirmadas: 1, errores: [] },
  });
  URL.createObjectURL = vi.fn(() => "blob:x");
  URL.revokeObjectURL = vi.fn();
  vi.spyOn(HTMLAnchorElement.prototype, "click").mockImplementation(() => {}); // jsdom no navega
});

describe("ImportarVentas: vista previa", () => {
  it("cuenta las filas y marca la inválida con su motivo", async () => {
    await subir(CSV);
    expect(await screen.findByText(/3 filas · 2 válidas · 1 con error/)).toBeInTheDocument();
    const fila = screen.getByText("Mal Fecha").closest("tr");
    expect(within(fila).getByText(/fecha_emision/)).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Importar 2 filas válidas" })).toBeEnabled();
  });

  it("avisa de las columnas que faltan y no deja importar", async () => {
    await subir("numero_factura;serial\nF-1;RT5-1");
    expect(await screen.findByRole("alert")).toHaveTextContent("fecha_emision, numero_documento");
    expect(screen.queryByRole("button", { name: /Importar/ })).toBeNull();
  });

  it("sin filas válidas el botón de importar no se ofrece", async () => {
    await subir(`${CAB}\nF-3;ayer;V;1;x;RT5-3;m`);
    await screen.findByText(/1 filas · 0 válidas/);
    expect(screen.queryByRole("button", { name: /Importar/ })).toBeNull();
  });
});

describe("ImportarVentas: importar", () => {
  it("manda solo las filas válidas, con el nombre del archivo, y muestra el resumen", async () => {
    const usuario = await subir(CSV, "ventas-oct.csv");
    await usuario.click(await screen.findByRole("button", { name: "Importar 2 filas válidas" }));
    await waitFor(() => expect(fakes.importarVentas).toHaveBeenCalledTimes(1));
    const [nombre, filas] = fakes.importarVentas.mock.calls[0];
    expect(nombre).toBe("ventas-oct.csv");
    expect(filas.map((f) => f.serial)).toEqual(["RT5-1", "RT5-2"]);
    const r = await screen.findByRole("status");
    expect(r).toHaveTextContent("1 nuevas");
    expect(r).toHaveTextContent("1 actualizadas");
    expect(r).toHaveTextContent("1 garantías confirmadas");
  });

  it("devuelve a la jefatura las filas con error (vista previa y servidor) para descargar", async () => {
    fakes.importarVentas.mockResolvedValue({
      ok: true,
      datos: { nuevas: 1, actualizadas: 0, con_error: 1, confirmadas: 0, errores: [{ fila: 2, campo: "serial", mensaje: "serial repetido" }] },
    });
    const usuario = await subir(CSV);
    await usuario.click(await screen.findByRole("button", { name: "Importar 2 filas válidas" }));
    const boton = await screen.findByRole("button", { name: "Descargar filas con error (2)" });
    await usuario.click(boton);
    const blob = URL.createObjectURL.mock.calls[0][0];
    const texto = await leer(blob);
    expect(texto).toContain("serial repetido");
    expect(texto).toContain("RT5-2");
    expect(texto).toContain("Mal Fecha");
  });

  it("muestra el rechazo de la base y deja reintentar", async () => {
    fakes.importarVentas.mockResolvedValue({ ok: false, codigo: "SIN_PERMISO", mensaje: "Solo ADMIN o JEFE_SERVICIO importan ventas", guardadas: 0 });
    const usuario = await subir(CSV);
    await usuario.click(await screen.findByRole("button", { name: "Importar 2 filas válidas" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("Solo ADMIN");
    expect(screen.getByRole("button", { name: "Importar 2 filas válidas" })).toBeEnabled();
  });

  it("no permite enviar dos veces mientras importa", async () => {
    let fin;
    fakes.importarVentas.mockReturnValue(new Promise((r) => (fin = r)));
    const usuario = await subir(CSV);
    await usuario.click(await screen.findByRole("button", { name: "Importar 2 filas válidas" }));
    expect(screen.getByRole("button", { name: /Importando/ })).toBeDisabled();
    fin({ ok: true, datos: { nuevas: 2, actualizadas: 0, con_error: 0, confirmadas: 0, errores: [] } });
    await screen.findByRole("status");
    expect(fakes.importarVentas).toHaveBeenCalledTimes(1);
  });
});
