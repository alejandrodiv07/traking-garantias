// Abrir orden con auditoría de recepción (maqueta 04): equipo → falla → auditoría.
// Los servicios se simulan en el borde; la base vuelve a validar todo.
import { render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, Route, Routes, useLocation } from "react-router-dom";
import { beforeEach, describe, expect, it, vi } from "vitest";

const fakes = vi.hoisted(() => ({
  leerEquipo: vi.fn(),
  abrirOrden: vi.fn(),
  subirAdjuntos: vi.fn(),
  previsualizarCobertura: vi.fn(),
  guardarBorrador: vi.fn(),
  leerBorrador: vi.fn(),
  limpiarBorrador: vi.fn(),
  perfilId: "u7",
}));
vi.mock("./tallerService.js", () => fakes);
vi.mock("../registro/registroService.js", () => fakes);
vi.mock("./borrador.js", () => fakes);
vi.mock("../auth/AuthContext.jsx", () => ({
  useAuth: () => ({ perfil: { id: fakes.perfilId } }),
}));

import AbrirOrden from "./AbrirOrden.jsx";

const EQUIPO = (extras = {}) => ({
  equipo_id: "e1",
  producto: "Huawei HG8245",
  numero_serie: "RT5-8842-AA",
  titular: "Juan Perez",
  vence_el: "2026-11-04",
  dias_restantes: 5,
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
const siguiente = (u) => u.click(screen.getByRole("button", { name: "Siguiente" }));

async function responderTodo(u, valor = "Sí") {
  for (const g of screen.getAllByRole("radiogroup")) await u.click(within(g).getByLabelText(valor));
}

/** Llena los tres pasos: falla, auditoría (todo «Sí») y la foto. */
async function completar(u, { documento = false } = {}) {
  await screen.findByRole("heading", { name: "Equipo" });
  await siguiente(u);
  await u.type(screen.getByLabelText("Falla reportada"), "no enciende");
  await siguiente(u);
  await responderTodo(u);
  await u.upload(screen.getByLabelText(/Fotos/), FOTO);
  if (documento) await u.upload(screen.getByLabelText(/Documentos/), DOC);
}

beforeEach(() => {
  fakes.perfilId = "u7";
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
  fakes.guardarBorrador.mockReset();
  fakes.leerBorrador.mockReset().mockReturnValue(null);
  fakes.limpiarBorrador.mockReset();
});

describe("AbrirOrden: el equipo", () => {
  it("lee el equipo por id y lo muestra en solo lectura", async () => {
    montar();
    expect(await screen.findAllByText("Huawei HG8245")).not.toHaveLength(0);
    expect(fakes.leerEquipo).toHaveBeenCalledWith("e1");
    expect(screen.getAllByText("RT5-8842-AA").length).toBeGreaterThan(0);
    expect(screen.getAllByText(/Juan Perez/).length).toBeGreaterThan(0);
    expect(screen.getByText("Vigente")).toBeTruthy();
  });

  it("sin ?equipo= o con equipo inexistente muestra el error y ofrece buscar", async () => {
    fakes.leerEquipo.mockResolvedValue({ ok: false, codigo: "NO_ENCONTRADO", mensaje: "No existe ese equipo" });
    montar("/taller/nueva?equipo=zz");
    expect((await screen.findByRole("alert")).textContent).toMatch(/No existe ese equipo/);
    expect(screen.getByRole("button", { name: "Buscar el equipo" })).toBeTruthy();
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
  it("tiene los tres pasos y no deja pasar de la falla con menos de 5 caracteres", async () => {
    const u = userEvent.setup();
    montar();
    await screen.findByRole("heading", { name: "Equipo" });
    expect([...screen.getByRole("list", { name: "Pasos" }).querySelectorAll("li")].map((li) => li.textContent)).toEqual(["Equipo", "Falla", "Auditoría"]);
    await siguiente(u);
    await u.type(screen.getByLabelText("Falla reportada"), "abc");
    expect(screen.getByRole("button", { name: "Siguiente" })).toBeDisabled();
    await u.type(screen.getByLabelText("Falla reportada"), "de");
    expect(screen.getByRole("button", { name: "Siguiente" })).toBeEnabled();
  });

  it("no deja abrir sin responder la auditoría ni subir una foto", async () => {
    const u = userEvent.setup();
    montar();
    await screen.findByRole("heading", { name: "Equipo" });
    await siguiente(u);
    await u.type(screen.getByLabelText("Falla reportada"), "no enciende");
    await siguiente(u);
    expect(abrir()).toBeDisabled();
    await u.upload(screen.getByLabelText(/Fotos/), FOTO);
    expect(abrir()).toBeDisabled();
    await responderTodo(u);
    expect(abrir()).toBeEnabled();
  });

  it("un «No» cuenta como respuesta y la auditoría incompleta no calcula la cobertura", async () => {
    const u = userEvent.setup();
    montar();
    await screen.findByRole("heading", { name: "Equipo" });
    await siguiente(u);
    await u.type(screen.getByLabelText("Falla reportada"), "no enciende");
    await siguiente(u);
    await u.click(within(screen.getAllByRole("radiogroup")[0]).getByLabelText("No"));
    expect(screen.getByText(/responde los seis puntos/)).toBeTruthy();
    expect(fakes.previsualizarCobertura).not.toHaveBeenCalled();
  });

  it("completa la auditoría y muestra la cobertura que calcula la base", async () => {
    const u = userEvent.setup();
    montar();
    await completar(u);
    expect(await screen.findAllByText(/Anulada por uso/)).not.toHaveLength(0);
    expect(fakes.previsualizarCobertura).toHaveBeenCalledWith(
      expect.objectContaining({ venceEl: "2026-11-04", checklist: expect.objectContaining({ senales: expect.any(Object) }) }),
    );
  });

  it("un equipo con compra PENDIENTE exige el documento presentado", async () => {
    fakes.leerEquipo.mockResolvedValue({ ok: true, datos: EQUIPO({ estado_compra: "PENDIENTE" }) });
    const u = userEvent.setup();
    montar();
    await completar(u);
    expect(screen.getByText(/exige el documento presentado/)).toBeTruthy();
    expect(abrir()).toBeDisabled();
    await u.upload(screen.getByLabelText(/Documentos/), DOC);
    expect(abrir()).toBeEnabled();
  });
});

describe("AbrirOrden: el envío", () => {
  it("abre la orden con la firma de la 0019, sube los adjuntos y va al detalle", async () => {
    const u = userEvent.setup();
    montar();
    await screen.findByRole("heading", { name: "Equipo" });
    await siguiente(u);
    await u.type(screen.getByLabelText("Falla reportada"), "no enciende");
    await u.type(screen.getByLabelText(/Accesorios/), "cargador");
    await siguiente(u);
    await responderTodo(u);
    await u.upload(screen.getByLabelText(/Fotos/), FOTO);
    await u.click(abrir());

    await waitFor(() => expect(fakes.abrirOrden).toHaveBeenCalledTimes(1));
    expect(fakes.abrirOrden).toHaveBeenCalledWith({
      equipoId: "e1",
      falla: "no enciende",
      accesorios: "cargador",
      checklist: {
        condiciones: { factura_presentada: true, titular_coincide: true },
        equipo: { serial_legible: true, caja_original: true, precintos_intactos: true, contenido_completo: true },
        senales: { descarga_electrica: false, liquidos: false, altas_temperaturas: false, golpes: false, manipulacion_terceros: false },
      },
      observaciones: null,
      claveEnvio: expect.stringMatching(/^[0-9a-f-]{36}$/),
    });
    expect(fakes.subirAdjuntos).toHaveBeenCalledWith("o1", [expect.objectContaining({ archivo: FOTO, tipo: "FOTO" })]);
    expect(await screen.findByText("/taller/o1")).toBeTruthy();
  });

  it("manda las señales de causas externas que marcó el técnico", async () => {
    const u = userEvent.setup();
    montar();
    await completar(u);
    await u.click(screen.getByLabelText("Golpes"));
    await u.click(abrir());
    await waitFor(() => expect(fakes.abrirOrden).toHaveBeenCalled());
    expect(fakes.abrirOrden.mock.calls[0][0].checklist.senales.golpes).toBe(true);
  });

  it("si la base rechaza, muestra el mensaje y no navega", async () => {
    fakes.abrirOrden.mockResolvedValue({ ok: false, codigo: "SIN_PERMISO", mensaje: "sin permiso" });
    const u = userEvent.setup();
    montar();
    await completar(u);
    await u.click(abrir());
    expect((await screen.findByRole("alert")).textContent).toMatch(/sin permiso/);
    expect(fakes.subirAdjuntos).not.toHaveBeenCalled();
  });

  it("si falla una subida no navega y reintenta SOLO los adjuntos, sin crear otra orden", async () => {
    fakes.subirAdjuntos.mockResolvedValueOnce([{ archivo: FOTO, tipo: "FOTO", etiqueta: null }]);
    const u = userEvent.setup();
    montar();
    await completar(u);
    await u.click(abrir());

    await u.click(await screen.findByRole("button", { name: "Reintentar adjuntos" }));
    expect(await screen.findByText("/taller/o1")).toBeTruthy();
    expect(fakes.abrirOrden).toHaveBeenCalledTimes(1);
    expect(fakes.subirAdjuntos).toHaveBeenCalledTimes(2);
  });
});

// Borrador de 24 h (I3 de la revisión; spec §8): la clave de envío y el estado
// viajan en el borrador del módulo 'orden' — cerrar la pestaña NO genera una
// segunda orden al reintentar: la clave se reutiliza y los pendientes apuntan
// a la MISMA orden. Restauración OFRECIDA, no impuesta.
describe("AbrirOrden: borrador de 24 h", () => {
  const BORRADOR = () => ({
    equipoId: "e1",
    serial: "RT5-8842-AA",
    falla: "pantalla rota",
    accesorios: "cargador",
    checklist: {
      condiciones: { factura_presentada: true, titular_coincide: true },
      equipo: { serial_legible: true, caja_original: true, precintos_intactos: true, contenido_completo: true },
      senales: { golpes: true },
    },
    observaciones: null,
    diagnostico: null,
    claveEnvio: "0bfe6b8c-1111-4222-8333-444455556666",
    ordenId: null,
    numero_orden: null,
    pendientes: [],
  });

  it("lo escribe en el borrador del módulo 'orden' (con la clave de envío) en cada cambio", async () => {
    const u = userEvent.setup();
    montar();
    await completar(u);
    expect(fakes.guardarBorrador).toHaveBeenCalledWith(
      "u7",
      expect.objectContaining({ equipoId: "e1", serial: "RT5-8842-AA", falla: "no enciende", claveEnvio: expect.any(String) }),
      "orden",
    );
  });

  it("OFRECE restaurar un borrador del mismo equipo; al restaurar, la clave de envío es LA MISMA", async () => {
    fakes.leerBorrador.mockReturnValue(BORRADOR());
    const u = userEvent.setup();
    montar();
    expect(await screen.findByText(/¿Lo restauras\?/)).toBeTruthy();
    expect(fakes.leerBorrador).toHaveBeenCalledWith("u7", "orden");
    await u.click(screen.getByRole("button", { name: "Restaurar" }));
    await screen.findByRole("heading", { name: "Equipo" });
    await siguiente(u);
    expect(screen.getByLabelText("Falla reportada")).toHaveValue("pantalla rota");
    expect(screen.getByLabelText(/Accesorios/)).toHaveValue("cargador");
    await siguiente(u);

    await u.upload(screen.getByLabelText(/Fotos/), FOTO);
    await u.click(abrir());
    await waitFor(() => expect(fakes.abrirOrden).toHaveBeenCalledTimes(1));
    // LA MISMA clave: la idempotencia de la 0012 devuelve LA orden; no hay segunda.
    expect(fakes.abrirOrden).toHaveBeenCalledWith(expect.objectContaining({ claveEnvio: "0bfe6b8c-1111-4222-8333-444455556666" }));
    expect(await screen.findByText("/taller/o1")).toBeTruthy();
    expect(fakes.limpiarBorrador).toHaveBeenCalledWith("u7", "orden");
  });

  it("un borrador de OTRO equipo no se ofrece y genera su propia clave", async () => {
    fakes.leerBorrador.mockReturnValue({ ...BORRADOR(), equipoId: "otro-equipo" });
    const u = userEvent.setup();
    montar();
    await screen.findByRole("heading", { name: "Equipo" });
    expect(screen.queryByText(/¿Lo restauras\?/)).toBeNull();
    await siguiente(u);
    await u.type(screen.getByLabelText("Falla reportada"), "no enciende");
    const guardado = fakes.guardarBorrador.mock.calls.at(-1)?.[1] ?? {};
    expect(Object.keys(guardado).length).toBeGreaterThan(0);
    expect(guardado.claveEnvio).not.toBe("0bfe6b8c-1111-4222-8333-444455556666");
  });

  it("'Empezar de cero' descarta el borrador", async () => {
    fakes.leerBorrador.mockReturnValue(BORRADOR());
    const u = userEvent.setup();
    montar();
    await screen.findByText(/¿Lo restauras\?/);
    await u.click(screen.getByRole("button", { name: "Empezar de cero" }));
    expect(fakes.limpiarBorrador).toHaveBeenCalledWith("u7", "orden");
    expect(screen.queryByRole("dialog")).toBeNull();
  });

  it("con la orden abierta PENDIENTES en el borrador, se reintentan contra la MISMA orden", async () => {
    fakes.leerBorrador.mockReturnValue({
      ...BORRADOR(),
      ordenId: "o1",
      numero_orden: "OS-2026-0007",
      pendientes: [{ tipo: "FOTO", etiqueta: "frente" }],
    });
    const u = userEvent.setup();
    montar();
    await screen.findByText(/¿Lo restauras\?/);
    await u.click(screen.getByRole("button", { name: "Restaurar" }));
    expect(await screen.findByRole("status")).toHaveTextContent(/La orden OS-2026-0007 ya existe/);
    await u.click(screen.getByRole("button", { name: "Reintentar adjuntos" }));
    expect(fakes.abrirOrden).not.toHaveBeenCalled();
    expect(fakes.subirAdjuntos).toHaveBeenCalledWith("o1", [expect.objectContaining({ tipo: "FOTO", etiqueta: "frente" })]);
    expect(await screen.findByText("/taller/o1")).toBeTruthy();
    expect(fakes.limpiarBorrador).toHaveBeenCalledWith("u7", "orden");
  });
});
