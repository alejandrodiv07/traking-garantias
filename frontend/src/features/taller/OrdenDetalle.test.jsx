// Detalle de la orden, SOLO LECTURA (Tarea 16 del plan, primera mitad):
// encabezado, barra de estados y las cinco pestañas. Las acciones llegan con la 0021.
import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { beforeEach, describe, expect, it, vi } from "vitest";

const fakes = vi.hoisted(() => ({
  obtenerOrden: vi.fn(),
  historialOrden: vi.fn(),
  notasOrden: vi.fn(),
  adjuntosOrden: vi.fn(),
  listarRevisiones: vi.fn(),
}));
vi.mock("./tallerService.js", () => fakes);
vi.mock("../revisiones/revisionesService.js", () => fakes);

import OrdenDetalle from "./OrdenDetalle.jsx";

const ORDEN = (extras = {}) => ({
  orden_id: "o1",
  numero_orden: "OS-2026-0007",
  estado: "EN_DIAGNOSTICO",
  estado_nombre: "En diagnóstico",
  cobertura: "EN_GARANTIA",
  tipo_atencion: "GARANTIA",
  serial: "RT5-8842-AA",
  producto: "Huawei HG8245",
  cliente: "Juan Perez",
  documento: "12345678",
  fecha_ingreso: "2026-10-25T10:00:00+00:00",
  falla_reportada: "No enciende",
  accesorios: "cargador y caja",
  diagnostico: null,
  costo_reparacion: null,
  motivo_rechazo: null,
  tecnico: "Tomás Técnico",
  ...extras,
});

const montar = () =>
  render(
    <MemoryRouter initialEntries={["/taller/o1"]}>
      <Routes>
        <Route path="/taller/:id" element={<OrdenDetalle />} />
      </Routes>
    </MemoryRouter>,
  );

const pestana = (n) => userEvent.setup().click(screen.getByRole("tab", { name: n }));
const cargada = () => screen.findByRole("heading", { name: "OS-2026-0007" });

beforeEach(() => {
  fakes.obtenerOrden.mockReset().mockResolvedValue({ ok: true, datos: ORDEN() });
  fakes.historialOrden.mockReset().mockResolvedValue({ ok: true, datos: [] });
  fakes.notasOrden.mockReset().mockResolvedValue({ ok: true, datos: [] });
  fakes.adjuntosOrden.mockReset().mockResolvedValue({ ok: true, datos: [] });
  fakes.listarRevisiones.mockReset().mockResolvedValue({ ok: true, datos: [] });
});

describe("OrdenDetalle: encabezado", () => {
  it("lee la orden de la ruta y muestra número, estado, cobertura y atención", async () => {
    montar();
    expect(await cargada()).toBeTruthy();
    expect(fakes.obtenerOrden).toHaveBeenCalledWith("o1");
    expect(screen.getAllByText("En diagnóstico").length).toBeGreaterThan(0);
    expect(screen.getByText("En garantía")).toBeTruthy();
    expect(screen.getByText("Atención: garantía")).toBeTruthy();
  });

  it.each([
    ["PAGO", "Atención: pago"],
    ["PENDIENTE", "Atención: pendiente"],
  ])("la insignia refleja tipo_atencion %s", async (tipo, texto) => {
    fakes.obtenerOrden.mockResolvedValue({ ok: true, datos: ORDEN({ tipo_atencion: tipo }) });
    montar();
    expect(await screen.findByText(texto)).toBeTruthy();
  });

  it("dibuja la barra de estados con el tipo de atención", async () => {
    fakes.obtenerOrden.mockResolvedValue({ ok: true, datos: ORDEN({ tipo_atencion: "PAGO" }) });
    montar();
    expect(await screen.findByText("Presupuestado")).toBeTruthy();
  });

  it("si no existe o no se ve, muestra el error", async () => {
    fakes.obtenerOrden.mockResolvedValue({ ok: false, codigo: "NO_ENCONTRADO", mensaje: "No existe esa orden" });
    montar();
    expect((await screen.findByRole("alert")).textContent).toMatch(/No existe esa orden/);
  });

  it("una orden RECHAZADA enseña su motivo", async () => {
    fakes.obtenerOrden.mockResolvedValue({
      ok: true,
      datos: ORDEN({ estado: "RECHAZADO", estado_nombre: "Rechazado", motivo_rechazo: "Equipo con humedad evidente" }),
    });
    montar();
    expect(await screen.findByText(/Equipo con humedad evidente/)).toBeTruthy();
  });
});

describe("OrdenDetalle: pestañas", () => {
  it("tiene las cinco pestañas y abre en Resumen", async () => {
    montar();
    await cargada();
    expect(screen.getAllByRole("tab").map((t) => t.textContent)).toEqual([
      "Resumen",
      "Auditoría",
      "Diagnóstico y presupuesto",
      "Documentos",
      "Bitácora",
    ]);
    expect(screen.getByRole("tab", { name: "Resumen" })).toHaveAttribute("aria-selected", "true");
  });

  it("Resumen: equipo, titular, falla, accesorios y técnico", async () => {
    montar();
    await cargada();
    for (const t of ["RT5-8842-AA", "Huawei HG8245", /Juan Perez/, "No enciende", "cargador y caja", /Tomás Técnico/]) {
      expect(screen.getByText(t)).toBeTruthy();
    }
  });

  it("Resumen sin técnico dice que no hay uno asignado", async () => {
    fakes.obtenerOrden.mockResolvedValue({ ok: true, datos: ORDEN({ tecnico: null }) });
    montar();
    expect(await screen.findByText(/Sin técnico asignado/)).toBeTruthy();
  });

  it("Auditoría lista las revisiones de la orden", async () => {
    fakes.listarRevisiones.mockResolvedValue({
      ok: true,
      datos: [
        {
          id: "r1",
          tipo: "RECEPCION",
          revisado_en: "2026-10-25T10:05:00+00:00",
          resultado: "EN_GARANTIA",
          observaciones: "rayones leves",
          checklist: {},
          revisor: { full_name: "Rita Recepción" },
        },
      ],
    });
    montar();
    await cargada();
    await pestana("Auditoría");
    expect(await screen.findByText(/rayones leves/)).toBeTruthy();
    expect(fakes.listarRevisiones).toHaveBeenCalledWith("o1");
  });

  it("Diagnóstico: en pago muestra el diagnóstico y el presupuesto", async () => {
    fakes.obtenerOrden.mockResolvedValue({
      ok: true,
      datos: ORDEN({ tipo_atencion: "PAGO", cobertura: "FUERA_DE_GARANTIA", diagnostico: "Fuente quemada", costo_reparacion: "45.00" }),
    });
    montar();
    await cargada();
    await pestana("Diagnóstico y presupuesto");
    expect(screen.getByText("Fuente quemada")).toBeTruthy();
    expect(screen.getByText(/Presupuesto: 45/)).toBeTruthy();
  });

  it("Diagnóstico: en garantía no hay presupuesto y sin texto avisa que falta", async () => {
    montar();
    await cargada();
    await pestana("Diagnóstico y presupuesto");
    expect(screen.getByText(/Aún no hay diagnóstico/)).toBeTruthy();
    expect(screen.queryByText(/Presupuesto:/)).toBeNull();
  });

  it("Documentos lista fotos y documentos por nombre de archivo", async () => {
    fakes.adjuntosOrden.mockResolvedValue({
      ok: true,
      datos: [
        { id: "a1", tipo: "FOTO", etiqueta: null, ruta: "ordenes/o1/frente.jpg", mime: "image/jpeg", bytes: 10, subido_en: "2026-10-25T10:00:00+00:00" },
        { id: "a2", tipo: "DOCUMENTO", etiqueta: null, ruta: "ordenes/o1/factura.pdf", mime: "application/pdf", bytes: 10, subido_en: "2026-10-25T10:00:00+00:00" },
      ],
    });
    montar();
    await cargada();
    await pestana("Documentos");
    expect(await screen.findByText(/frente\.jpg/)).toBeTruthy();
    expect(screen.getByText(/factura\.pdf/)).toBeTruthy();
  });

  it("Documentos vacío lo dice", async () => {
    montar();
    await cargada();
    await pestana("Documentos");
    expect(await screen.findByText(/Sin documentos/)).toBeTruthy();
  });

  it("Bitácora junta cambios de estado, eventos y notas internas", async () => {
    fakes.historialOrden.mockResolvedValue({
      ok: true,
      datos: [
        { id: 2, evento: "BITACORA", estado_anterior: null, estado_nuevo: "EN_DIAGNOSTICO", comentario: "La cobertura cambió a EN_GARANTIA", creado_en: "2026-10-26T09:00:00+00:00", autor: null },
        { id: 1, evento: "ESTADO", estado_anterior: "RECIBIDO", estado_nuevo: "EN_DIAGNOSTICO", comentario: null, creado_en: "2026-10-25T11:00:00+00:00", autor: { full_name: "Tomás Técnico" } },
      ],
    });
    fakes.notasOrden.mockResolvedValue({
      ok: true,
      datos: [{ id: "n1", nota: "Llamar al cliente mañana", created_at: "2026-10-26T10:00:00+00:00", autor: { full_name: "Jefe Jorge" } }],
    });
    montar();
    await cargada();
    await pestana("Bitácora");
    expect(await screen.findByText(/La cobertura cambió a EN_GARANTIA/)).toBeTruthy();
    expect(screen.getByText(/Recibido → En diagnóstico/)).toBeTruthy();
    expect(screen.getByText(/Llamar al cliente mañana/)).toBeTruthy();
  });

  it("un fallo al leer una pestaña se muestra sin tumbar el detalle", async () => {
    fakes.adjuntosOrden.mockResolvedValue({ ok: false, mensaje: "Sin conexión" });
    montar();
    await cargada();
    await pestana("Documentos");
    expect((await screen.findByRole("alert")).textContent).toMatch(/Sin conexión/);
  });
});
