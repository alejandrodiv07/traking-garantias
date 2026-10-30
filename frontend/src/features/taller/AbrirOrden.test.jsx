// Abrir orden con auditoría de recepción (Tarea 15 del plan; spec §8).
// Reutiliza PasoVerificacion y PasoAdjuntos; los servicios se simulan en el borde.
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, Route, Routes, useLocation } from "react-router-dom";
import { beforeEach, describe, expect, it, vi } from "vitest";

const fakes = vi.hoisted(() => ({
  leerEquipo: vi.fn(),
  abrirOrden: vi.fn(),
  subirAdjuntos: vi.fn(),
  previsualizarCobertura: vi.fn(),
}));
vi.mock("./tallerService.js", () => fakes);
vi.mock("../registro/registroService.js", () => fakes);

import AbrirOrden from "./AbrirOrden.jsx";

const EQUIPO = (extras = {}) => ({
  equipo_id: "e1",
  producto: "Huawei HG8245",
  numero_serie: "RT5-8842-AA",
  titular: "Juan Perez",
  vence_el: "2026-11-04",
  vigencia: "EN_GARANTIA",
  estado_compra: "CONFIRMADA",
  ...extras,
});

const FOTO = new File(["x"], "foto.jpg", { type: "image/jpeg" });
const DOC = new File(["x"], "factura.pdf", { type: "application/pdf" });

function Destino() {
  return <p>{useLocation().pathname}</p>;
}

const montar = (ruta = "/taller/nueva?equipo=e1") =>
  render(
    <MemoryRouter initialEntries={[ruta]}>
      <Routes>
        <Route path="/taller/nueva" element={<AbrirOrden />} />
        <Route path="*" element={<Destino />} />
      </Routes>
    </MemoryRouter>,
  );

const abrir = () => screen.getByRole("button", { name: "Abrir orden" });

async function completar(usuario, { documento = false } = {}) {
  await screen.findByText("Huawei HG8245");
  await usuario.type(screen.getByLabelText("Falla reportada"), "no enciende");
  await usuario.upload(screen.getByLabelText(/Fotos/), FOTO);
  if (documento) await usuario.upload(screen.getByLabelText(/Documentos/), DOC);
}

beforeEach(() => {
  fakes.leerEquipo.mockReset().mockResolvedValue({ ok: true, datos: EQUIPO() });
  fakes.abrirOrden.mockReset().mockResolvedValue({
    ok: true,
    datos: { orden_id: "o1", numero_orden: "OS-2026-0001", cobertura: "EN_GARANTIA", tipo_atencion: "GARANTIA" },
  });
  fakes.subirAdjuntos.mockReset().mockResolvedValue([]);
  fakes.previsualizarCobertura.mockReset().mockResolvedValue({
    ok: true,
    datos: { cobertura: "ANULADA_POR_USO", motivo: "golpes" },
  });
});

describe("AbrirOrden: el equipo", () => {
  it("lee el equipo por id y lo muestra en solo lectura", async () => {
    montar();
    expect(await screen.findByText("Huawei HG8245")).toBeTruthy();
    expect(fakes.leerEquipo).toHaveBeenCalledWith("e1");
    expect(screen.getByText("RT5-8842-AA")).toBeTruthy();
    expect(screen.getByText(/Juan Perez/)).toBeTruthy();
  });

  it("sin ?equipo= o con equipo inexistente muestra el error", async () => {
    fakes.leerEquipo.mockResolvedValue({ ok: false, codigo: "NO_ENCONTRADO", mensaje: "No existe ese equipo" });
    montar("/taller/nueva?equipo=zz");
    expect((await screen.findByRole("alert")).textContent).toMatch(/No existe ese equipo/);
  });

  it.each([
    ["FUERA_DE_GARANTIA", /se atenderá como servicio pago/],
    ["POR_DETERMINAR", /cobertura pendiente de confirmar/],
  ])("con vigencia %s avisa de la cobertura", async (vigencia, aviso) => {
    fakes.leerEquipo.mockResolvedValue({ ok: true, datos: EQUIPO({ vigencia }) });
    montar();
    expect(await screen.findByText(aviso)).toBeTruthy();
  });
});

describe("AbrirOrden: lo que exige el formulario", () => {
  it("no deja abrir sin falla ni foto", async () => {
    montar();
    await screen.findByText("Huawei HG8245");
    expect(abrir()).toBeDisabled();
  });

  it("falla de menos de 5 caracteres no cuenta", async () => {
    const usuario = userEvent.setup();
    montar();
    await screen.findByText("Huawei HG8245");
    await usuario.type(screen.getByLabelText("Falla reportada"), "abc");
    await usuario.upload(screen.getByLabelText(/Fotos/), FOTO);
    expect(abrir()).toBeDisabled();
  });

  it("un equipo con compra PENDIENTE exige el documento presentado", async () => {
    fakes.leerEquipo.mockResolvedValue({ ok: true, datos: EQUIPO({ estado_compra: "PENDIENTE" }) });
    const usuario = userEvent.setup();
    montar();
    await completar(usuario);
    expect(screen.getByText(/exige el documento presentado/)).toBeTruthy();
    expect(abrir()).toBeDisabled();
    await usuario.upload(screen.getByLabelText(/Documentos/), DOC);
    expect(abrir()).toBeEnabled();
  });
});

describe("AbrirOrden: el envío", () => {
  it("abre la orden con la firma de la 0019, sube los adjuntos y va al detalle", async () => {
    const usuario = userEvent.setup();
    montar();
    await completar(usuario);
    await usuario.type(screen.getByLabelText("Accesorios"), "cargador");
    await usuario.click(abrir());

    await waitFor(() => expect(fakes.abrirOrden).toHaveBeenCalledTimes(1));
    expect(fakes.abrirOrden).toHaveBeenCalledWith({
      equipoId: "e1",
      falla: "no enciende",
      accesorios: "cargador",
      checklist: null,
      observaciones: null,
      claveEnvio: expect.stringMatching(/^[0-9a-f-]{36}$/),
    });
    expect(fakes.subirAdjuntos).toHaveBeenCalledWith("o1", [
      expect.objectContaining({ archivo: FOTO, tipo: "FOTO" }),
    ]);
    expect(await screen.findByText("/taller/o1")).toBeTruthy();
  });

  it("manda el checklist que marcó el técnico", async () => {
    const usuario = userEvent.setup();
    montar();
    await completar(usuario);
    await usuario.click(screen.getByLabelText("Golpes"));
    await screen.findByText(/ANULADA_POR_USO/);
    await usuario.click(abrir());
    await waitFor(() => expect(fakes.abrirOrden).toHaveBeenCalled());
    expect(fakes.abrirOrden.mock.calls[0][0].checklist.senales.golpes).toBe(true);
  });

  it("si la base rechaza, muestra el mensaje y no navega", async () => {
    fakes.abrirOrden.mockResolvedValue({ ok: false, codigo: "SIN_PERMISO", mensaje: "sin permiso" });
    const usuario = userEvent.setup();
    montar();
    await completar(usuario);
    await usuario.click(abrir());
    expect((await screen.findByRole("alert")).textContent).toMatch(/sin permiso/);
    expect(fakes.subirAdjuntos).not.toHaveBeenCalled();
  });

  it("si falla una subida no navega y reintenta SOLO los adjuntos, sin crear otra orden", async () => {
    fakes.subirAdjuntos.mockResolvedValueOnce([{ archivo: FOTO, tipo: "FOTO", etiqueta: null }]);
    const usuario = userEvent.setup();
    montar();
    await completar(usuario);
    await usuario.click(abrir());

    await usuario.click(await screen.findByRole("button", { name: "Reintentar adjuntos" }));
    expect(await screen.findByText("/taller/o1")).toBeTruthy();
    expect(fakes.abrirOrden).toHaveBeenCalledTimes(1);
    expect(fakes.subirAdjuntos).toHaveBeenCalledTimes(2);
  });
});
