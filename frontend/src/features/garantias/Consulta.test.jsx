// Consulta de garantía (maqueta 03): buscador único, ficha con cobertura y
// órdenes, y las acciones (abrir orden; jefatura confirma o desestima).
import { render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, Route, Routes, useLocation } from "react-router-dom";
import { beforeEach, describe, expect, it, vi } from "vitest";

const fakes = vi.hoisted(() => ({
  buscarGarantia: vi.fn(),
  confirmarCompra: vi.fn(),
  desestimarCompra: vi.fn(),
  verificacionPorEquipo: vi.fn(),
  documentosDeEquipo: vi.fn(),
  urlDocumento: vi.fn(),
  subirDocumentosEquipo: vi.fn(),
  rol: "JEFE_SERVICIO",
}));
vi.mock("./garantiasService.js", () => fakes);
vi.mock("../auth/AuthContext.jsx", () => ({ useAuth: () => ({ rol: fakes.rol }) }));

import Consulta from "./Consulta.jsx";

const EQUIPO = (extras = {}) => ({
  equipo_id: "e1",
  producto: "Huawei HG8245",
  numero_serie: "RT5-8842-AA",
  titular: "Juan Perez",
  documento: "12345678",
  email: "juan@x.com",
  telefono: "0414-1234567",
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
const PENDIENTE = (extras = {}) =>
  EQUIPO({ origen: "TALLER", vigencia: "POR_DETERMINAR", estado_compra: "PENDIENTE", dias_restantes: null, vence_el: null, ...extras });

function Destino() {
  const l = useLocation();
  return (
    <p>
      {l.pathname}
      {l.search}
    </p>
  );
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

async function buscar(usuario, texto) {
  await usuario.clear(screen.getByRole("searchbox"));
  await usuario.type(screen.getByRole("searchbox"), texto);
  await usuario.click(screen.getByRole("button", { name: "Buscar" }));
}

beforeEach(() => {
  fakes.rol = "JEFE_SERVICIO";
  fakes.confirmarCompra.mockReset().mockResolvedValue({ ok: true, datos: null });
  fakes.desestimarCompra.mockReset().mockResolvedValue({ ok: true, datos: null });
  fakes.buscarGarantia.mockReset().mockResolvedValue({ ok: true, datos: [EQUIPO()] });
  fakes.documentosDeEquipo.mockReset().mockResolvedValue({ ok: true, datos: [] });
  fakes.urlDocumento.mockReset().mockResolvedValue({ ok: true, datos: "https://x/firmado" });
  fakes.subirDocumentosEquipo.mockReset().mockResolvedValue([]);
  fakes.verificacionPorEquipo.mockReset().mockResolvedValue({ ok: true, datos: { e1: "COINCIDE" } });
});

describe("Consulta: buscador único", () => {
  it("consulta serial, factura y orden con lo escrito y muestra la ficha", async () => {
    const u = userEvent.setup();
    montar();
    await buscar(u, "rt5-8842-aa");
    await waitFor(() =>
      expect(fakes.buscarGarantia).toHaveBeenCalledWith({ serial: "rt5-8842-aa", factura: "rt5-8842-aa", orden: "rt5-8842-aa", documento: null }),
    );
    expect(await screen.findByRole("heading", { name: "Huawei HG8245" })).toBeInTheDocument();
    expect(screen.getByText("Garantía vigente")).toBeInTheDocument();
    expect(screen.getByText("5 días restantes")).toBeInTheDocument();
  });

  it("si parece cédula o RIF, también busca por documento (solo dígitos)", async () => {
    const u = userEvent.setup();
    montar();
    await buscar(u, "V-12345678");
    await waitFor(() => expect(fakes.buscarGarantia).toHaveBeenCalledWith(expect.objectContaining({ documento: "12345678" })));
  });

  it("pide al menos 3 caracteres y no consulta", async () => {
    const u = userEvent.setup();
    montar();
    await buscar(u, "ab");
    expect(screen.getByRole("alert")).toHaveTextContent("Escribe al menos 3 caracteres");
    expect(fakes.buscarGarantia).not.toHaveBeenCalled();
  });

  it("llegando con ?serial= (tras registrar) busca sin pulsar nada", async () => {
    montar("/garantias/consulta?serial=RT5-8842-AA");
    expect(await screen.findByRole("heading", { name: "Huawei HG8245" })).toBeInTheDocument();
    expect(screen.getByRole("searchbox")).toHaveValue("RT5-8842-AA");
  });

  it("con varios equipos ofrece la lista y abre el elegido", async () => {
    fakes.buscarGarantia.mockResolvedValue({ ok: true, datos: [EQUIPO(), EQUIPO({ equipo_id: "e2", numero_serie: "ZTE-0002", producto: "ZTE F670L" })] });
    const u = userEvent.setup();
    montar("/garantias/consulta?q=F-200");
    expect(await screen.findByText(/2 equipos coinciden con «F-200»/)).toBeInTheDocument();
    await u.click(screen.getByRole("button", { name: /ZTE F670L/ }));
    expect(await screen.findByRole("heading", { name: "ZTE F670L" })).toBeInTheDocument();
  });

  it("sin resultados ofrece registrar con origen TALLER", async () => {
    fakes.buscarGarantia.mockResolvedValue({ ok: true, datos: [] });
    const u = userEvent.setup();
    montar();
    await buscar(u, "ZZ-0000");
    expect(await screen.findByText(/No hay garantía registrada para «ZZ-0000»/)).toBeInTheDocument();
    await u.click(screen.getByRole("button", { name: "Registrar ahora" }));
    expect(await screen.findByText("/garantias/nueva?serial=ZZ-0000&origen=TALLER")).toBeInTheDocument();
  });

  it("muestra el error de la base", async () => {
    fakes.buscarGarantia.mockResolvedValue({ ok: false, codigo: "SIN_PERMISO", mensaje: "permission denied" });
    const u = userEvent.setup();
    montar();
    await buscar(u, "RT5-8842-AA");
    expect(await screen.findByRole("alert")).toHaveTextContent("permission denied");
  });
});

describe("Consulta: ficha", () => {
  it("muestra cobertura, titular y respaldo de Ventas", async () => {
    montar("/garantias/consulta?serial=RT5");
    await screen.findByRole("heading", { name: "Huawei HG8245" });
    expect(screen.getByRole("progressbar", { name: /Período de cobertura/ })).toHaveAttribute("value", "10");
    expect(screen.getByText("Inicio · 20 oct 2026")).toBeInTheDocument();
    expect(screen.getByText("Fin · 4 nov 2026")).toBeInTheDocument();
    expect(screen.getByText("juan@x.com")).toBeInTheDocument();
    expect(screen.getByText("Respaldada por Ventas")).toBeInTheDocument();
  });

  it("si la verificación falla, la ficha sale igual sin insignia", async () => {
    fakes.verificacionPorEquipo.mockResolvedValue({ ok: false, codigo: "SIN_CONEXION", mensaje: "" });
    montar("/garantias/consulta?serial=RT5");
    await screen.findByRole("heading", { name: "Huawei HG8245" });
    expect(screen.queryByText("Respaldada por Ventas")).toBeNull();
  });

  it("lista las órdenes del equipo y avisa si hay una abierta", async () => {
    fakes.buscarGarantia.mockResolvedValue({
      ok: true,
      datos: [EQUIPO({ ordenes: [{ numero_orden: "OS-2026-0007", estado: "EN_REPARACION", estado_nombre: "En reparación", cobertura: "EN_GARANTIA", tipo_atencion: "GARANTIA", fecha_ingreso: "2026-10-25T10:00:00+00:00" }] })],
    });
    montar("/garantias/consulta?serial=RT5");
    const lista = await screen.findByRole("list", { name: "Órdenes del equipo" });
    expect(within(lista).getByRole("link", { name: "OS-2026-0007" })).toHaveAttribute("href", "/taller?buscar=OS-2026-0007");
    expect(within(lista).getByText("En reparación")).toBeInTheDocument();
    expect(screen.getByText(/ya tiene la orden/)).toHaveTextContent("OS-2026-0007");
  });

  it("una garantía vencida avisa del servicio pago al abrir la orden", async () => {
    fakes.buscarGarantia.mockResolvedValue({ ok: true, datos: [EQUIPO({ vigencia: "FUERA_DE_GARANTIA", dias_restantes: -4 })] });
    const u = userEvent.setup();
    montar("/garantias/consulta?serial=RT5");
    await screen.findByText("Venció hace 4 días");
    await u.click(screen.getByRole("button", { name: "Abrir orden de servicio" }));
    expect(screen.getByText(/se atenderá como servicio pago/)).toBeInTheDocument();
  });

  it("«Continuar a Taller» lleva a la nueva orden con el equipo", async () => {
    const u = userEvent.setup();
    montar("/garantias/consulta?serial=RT5");
    await screen.findByRole("heading", { name: "Huawei HG8245" });
    await u.click(screen.getByRole("button", { name: "Abrir orden de servicio" }));
    await u.click(screen.getByRole("button", { name: "Continuar a Taller" }));
    expect(await screen.findByText("/taller/nueva?equipo=e1")).toBeInTheDocument();
  });

  it("una compra desestimada muestra el motivo", async () => {
    fakes.buscarGarantia.mockResolvedValue({ ok: true, datos: [EQUIPO({ estado_compra: "DESESTIMADA", motivo_desestimacion: "La factura no existe en Ventas" })] });
    montar("/garantias/consulta?serial=RT5");
    expect(await screen.findByText(/La factura no existe en Ventas/)).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Confirmar compra" })).toBeNull();
  });
});

describe("Consulta: confirmar y desestimar la compra (solo jefatura)", () => {
  beforeEach(() => {
    fakes.buscarGarantia.mockResolvedValue({ ok: true, datos: [PENDIENTE()] });
  });

  it.each(["TECNICO", "RECEPCION"])("a %s se le muestran deshabilitadas con la nota", async (rol) => {
    fakes.rol = rol;
    montar("/garantias/consulta?serial=RT5");
    await screen.findByRole("heading", { name: "Huawei HG8245" });
    expect(screen.getByRole("button", { name: "Confirmar compra" })).toBeDisabled();
    expect(screen.getByRole("button", { name: "Desestimar compra" })).toBeDisabled();
    expect(screen.getByText(/lo hace Jefatura o Administración/)).toBeInTheDocument();
  });

  it("una compra confirmada no ofrece confirmar ni desestimar", async () => {
    fakes.buscarGarantia.mockResolvedValue({ ok: true, datos: [EQUIPO()] });
    montar("/garantias/consulta?serial=RT5");
    await screen.findByRole("heading", { name: "Huawei HG8245" });
    expect(screen.queryByRole("button", { name: "Confirmar compra" })).toBeNull();
  });

  it("el jefe confirma con el soporte y la ficha se recarga", async () => {
    const u = userEvent.setup();
    montar("/garantias/consulta?serial=RT5");
    await screen.findByRole("heading", { name: "Huawei HG8245" });
    await u.click(screen.getByRole("button", { name: "Confirmar compra" }));
    await u.click(screen.getByRole("button", { name: "Confirmar" }));
    await waitFor(() =>
      expect(fakes.confirmarCompra).toHaveBeenCalledWith({
        equipoId: "e1",
        tipoSoporte: "FACTURA",
        numeroSoporte: "F-200",
        fechaEmision: "2026-10-20",
        plazoDias: 15,
      }),
    );
    await waitFor(() => expect(fakes.buscarGarantia).toHaveBeenCalledTimes(2));
  });

  it("desestimar exige un motivo de 10 caracteres", async () => {
    const u = userEvent.setup();
    montar("/garantias/consulta?serial=RT5");
    await screen.findByRole("heading", { name: "Huawei HG8245" });
    await u.click(screen.getByRole("button", { name: "Desestimar compra" }));
    const enviar = screen.getByRole("button", { name: "Desestimar" });
    expect(enviar).toBeDisabled();
    await u.type(screen.getByLabelText(/Motivo/), "corto");
    expect(screen.getByText(/5\/10/)).toBeInTheDocument();
    expect(enviar).toBeDisabled();
    await u.type(screen.getByLabelText(/Motivo/), " y ya está bien");
    await u.click(enviar);
    await waitFor(() => expect(fakes.desestimarCompra).toHaveBeenCalledWith({ equipoId: "e1", motivo: "corto y ya está bien" }));
  });

  it("muestra el rechazo de la base", async () => {
    fakes.confirmarCompra.mockResolvedValue({ ok: false, codigo: "SIN_PERMISO", mensaje: "Solo ADMIN o JEFE_SERVICIO confirman la compra" });
    const u = userEvent.setup();
    montar("/garantias/consulta?serial=RT5");
    await screen.findByRole("heading", { name: "Huawei HG8245" });
    await u.click(screen.getByRole("button", { name: "Confirmar compra" }));
    await u.click(screen.getByRole("button", { name: "Confirmar" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("Solo ADMIN");
  });
});

describe("Consulta: documentos vinculados", () => {
  const DOCS = [
    { id: "d1", tipo: "DOCUMENTO", etiqueta: null, ruta: "equipos/e1/factura.pdf", mime: "application/pdf", bytes: 2048, subido_en: "2026-10-30T10:00:00Z" },
    { id: "d2", tipo: "FOTO", etiqueta: null, ruta: "equipos/e1/serial.jpg", mime: "image/jpeg", bytes: 3 * 1048576, subido_en: "2026-10-29T10:00:00Z" },
  ];

  it("sin documentos lo dice y ofrece agregar", async () => {
    montar("/garantias/consulta?serial=RT5");
    expect(await screen.findByText(/Sin documentos vinculados/)).toBeInTheDocument();
    expect(fakes.documentosDeEquipo).toHaveBeenCalledWith("e1");
    expect(screen.getByLabelText("Agregar documento")).toBeInTheDocument();
  });

  it("lista los archivos con su tipo, tamaño y fecha", async () => {
    fakes.documentosDeEquipo.mockResolvedValue({ ok: true, datos: DOCS });
    montar("/garantias/consulta?serial=RT5");
    const lista = await screen.findByRole("list", { name: "Archivos de la garantía" });
    expect(within(lista).getByText("factura.pdf")).toBeInTheDocument();
    expect(within(lista).getByText(/Documento · 2 KB · 30 oct 2026/)).toBeInTheDocument();
    expect(within(lista).getByText(/Foto · 3.0 MB/)).toBeInTheDocument();
  });

  it("descargar pide un enlace firmado y lo abre en otra pestaña", async () => {
    fakes.documentosDeEquipo.mockResolvedValue({ ok: true, datos: DOCS });
    const abrir = vi.spyOn(window, "open").mockReturnValue(null);
    const u = userEvent.setup();
    montar("/garantias/consulta?serial=RT5");
    await u.click(await screen.findByRole("button", { name: "Descargar factura.pdf" }));
    expect(fakes.urlDocumento).toHaveBeenCalledWith("equipos/e1/factura.pdf");
    expect(abrir).toHaveBeenCalledWith("https://x/firmado", "_blank", "noopener");
    abrir.mockRestore();
  });

  it("si no se puede abrir el archivo, lo avisa", async () => {
    fakes.documentosDeEquipo.mockResolvedValue({ ok: true, datos: DOCS });
    fakes.urlDocumento.mockResolvedValue({ ok: false, mensaje: "Object not found" });
    const u = userEvent.setup();
    montar("/garantias/consulta?serial=RT5");
    await u.click(await screen.findByRole("button", { name: "Descargar factura.pdf" }));
    expect(await screen.findByText("Object not found")).toBeInTheDocument();
  });

  it("agregar un documento lo sube a la garantía y recarga la lista", async () => {
    const u = userEvent.setup();
    montar("/garantias/consulta?serial=RT5");
    await screen.findByText(/Sin documentos vinculados/);
    const pdf = new File(["x"], "venta.pdf", { type: "application/pdf" });
    await u.upload(screen.getByLabelText("Agregar documento"), pdf);
    await waitFor(() => expect(fakes.subirDocumentosEquipo).toHaveBeenCalledWith("e1", [{ archivo: pdf, tipo: "DOCUMENTO" }]));
    await waitFor(() => expect(fakes.documentosDeEquipo).toHaveBeenCalledTimes(2));
  });

  it("si la base rechaza el documento (tope, formato), muestra su mensaje", async () => {
    fakes.subirDocumentosEquipo.mockResolvedValue([{ mensaje: "El registro ya tiene 6 documentos: no se admiten más" }]);
    const u = userEvent.setup();
    montar("/garantias/consulta?serial=RT5");
    await screen.findByText(/Sin documentos vinculados/);
    await u.upload(screen.getByLabelText("Agregar documento"), new File(["x"], "otro.pdf", { type: "application/pdf" }));
    expect(await screen.findByText(/ya tiene 6 documentos/)).toBeInTheDocument();
  });
});
