// Detalle de la orden (Tarea 16 del plan): lectura (primera mitad) y acciones
// por rol (segunda mitad, RPC 0021). El rol lo decide la base; aquí la UI lo
// anticipa con el espejo de transiciones.
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
  registrarRevision: vi.fn(),
  listarTecnicos: vi.fn(),
  cambiarEstado: vi.fn(),
  asignarTecnico: vi.fn(),
  registrarPresupuesto: vi.fn(),
  actualizarDiagnostico: vi.fn(),
  agregarNota: vi.fn(),
  rol: "JEFE_SERVICIO",
}));
vi.mock("./tallerService.js", () => fakes);
vi.mock("../revisiones/revisionesService.js", () => fakes);
vi.mock("../auth/AuthContext.jsx", () => ({ useAuth: () => ({ rol: fakes.rol }) }));

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
  fakes.rol = "JEFE_SERVICIO";
  fakes.obtenerOrden.mockReset().mockResolvedValue({ ok: true, datos: ORDEN() });
  fakes.historialOrden.mockReset().mockResolvedValue({ ok: true, datos: [] });
  fakes.notasOrden.mockReset().mockResolvedValue({ ok: true, datos: [] });
  fakes.adjuntosOrden.mockReset().mockResolvedValue({ ok: true, datos: [] });
  fakes.listarRevisiones.mockReset().mockResolvedValue({ ok: true, datos: [] });
  fakes.registrarRevision.mockReset().mockResolvedValue({ ok: true, datos: { cobertura: "EN_GARANTIA" } });
  fakes.actualizarDiagnostico.mockReset().mockResolvedValue({ ok: true, datos: null });
  fakes.agregarNota.mockReset().mockResolvedValue({ ok: true, datos: null });
  fakes.listarTecnicos.mockReset().mockResolvedValue({
    ok: true,
    datos: [
      { id: "t1", full_name: "Tomás Técnico" },
      { id: "t2", full_name: "Luis López" },
    ],
  });
  fakes.cambiarEstado.mockReset().mockResolvedValue({
    ok: true,
    datos: { orden_id: "o1", estado: "EN_REPARACION", tipo_atencion: "GARANTIA" },
  });
  fakes.asignarTecnico.mockReset().mockResolvedValue({ ok: true, datos: null });
  fakes.registrarPresupuesto.mockReset().mockResolvedValue({ ok: true, datos: { tipo_atencion: "PAGO" } });
});

describe("OrdenDetalle: encabezado", () => {
  it("lee la orden de la ruta y muestra número, estado, cobertura y atención", async () => {
    montar();
    expect(await cargada()).toBeTruthy();
    expect(fakes.obtenerOrden).toHaveBeenCalledWith("o1");
    expect(screen.getAllByText("En diagnóstico").length).toBeGreaterThan(0);
    expect(screen.getAllByText("En garantía").length).toBeGreaterThan(0);
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
    // "Presupuestado" aparece en la barra Y como opción del avance (jefatura).
    expect((await screen.findAllByText("Presupuestado")).length).toBeGreaterThan(0);
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
      expect(screen.getAllByText(t).length).toBeGreaterThan(0);
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

  it("Diagnóstico: en pago muestra el diagnóstico y el presupuesto cargados", async () => {
    fakes.obtenerOrden.mockResolvedValue({
      ok: true,
      datos: ORDEN({ tipo_atencion: "PAGO", cobertura: "FUERA_DE_GARANTIA", diagnostico: "Fuente quemada", costo_reparacion: "45.00" }),
    });
    montar();
    await cargada();
    await pestana("Diagnóstico y presupuesto");
    expect(screen.getByLabelText("Diagnóstico")).toHaveValue("Fuente quemada");
    expect(screen.getByLabelText("Presupuesto (monto)")).toHaveValue(45);
  });

  it("Diagnóstico: en garantía no hay formulario de presupuesto y sin texto avisa que falta", async () => {
    montar();
    await cargada();
    await pestana("Diagnóstico y presupuesto");
    expect(screen.getByPlaceholderText(/Aún no hay diagnóstico/)).toBeTruthy();
    expect(screen.queryByRole("button", { name: "Registrar presupuesto" })).toBeNull();
    expect(screen.getByText(/Solo se presupuesta un servicio pago/)).toBeTruthy();
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

// Acciones por rol (segunda mitad): la UI anticipa la matriz de
// transiciones_estado (espejo en dominio.js); la 0021 decide de verdad.
const opcionesDe = async () => {
  const cb = await screen.findByRole("combobox", { name: "Avanzar a:" });
  return Array.from(cb.options).map((o) => o.textContent);
};

describe("OrdenDetalle: acciones por rol — Avanzar", () => {
  it("un técnico desde En diagnóstico solo ve sus tres saltos, sin Rechazar ni Asignar", async () => {
    fakes.rol = "TECNICO";
    montar();
    await cargada();
    expect(await opcionesDe()).toEqual(["Elegir estado", "Presupuestado", "En reparación", "Irreparable"]);
    expect(screen.queryByRole("button", { name: "Rechazar" })).toBeNull();
    expect(screen.queryByRole("button", { name: "Asignar técnico" })).toBeNull();
  });

  it("jefatura ve, además, Rechazar y Anular (y rechaza directo en la pestaña de acciones)", async () => {
    montar();
    await cargada();
    expect(await opcionesDe()).toEqual([
      "Elegir estado",
      "Presupuestado",
      "En reparación",
      "Irreparable",
      "Anulado",
      "Rechazado",
    ]);
    expect(screen.getByRole("button", { name: "Rechazar" })).toBeTruthy();
    expect(screen.getByRole("button", { name: "Asignar técnico" })).toBeTruthy();
  });

  it("avanzar llama cambiar_estado con el estado elegido y refresca la orden", async () => {
    const user = userEvent.setup();
    fakes.obtenerOrden.mockResolvedValueOnce({ ok: true, datos: ORDEN() }).mockResolvedValueOnce({
      ok: true,
      datos: ORDEN({ estado: "EN_REPARACION", estado_nombre: "En reparación" }),
    });
    montar();
    await cargada();
    await user.selectOptions(screen.getByRole("combobox", { name: "Avanzar a:" }), "En reparación");
    await user.click(screen.getByRole("button", { name: "Avanzar" }));
    expect(fakes.cambiarEstado).toHaveBeenCalledWith("o1", { estado: "EN_REPARACION", comentario: null });
    expect(fakes.obtenerOrden).toHaveBeenCalledTimes(2);
    expect((await screen.findAllByText("En reparación")).length).toBeGreaterThan(0);
  });

  it("el comentario opcional del avance viaja con el cambio", async () => {
    const user = userEvent.setup();
    montar();
    await cargada();
    await user.selectOptions(screen.getByRole("combobox", { name: "Avanzar a:" }), "En reparación");
    await user.type(screen.getByLabelText("Comentario"), "Repuesto puesto");
    await user.click(screen.getByRole("button", { name: "Avanzar" }));
    expect(fakes.cambiarEstado).toHaveBeenCalledWith("o1", { estado: "EN_REPARACION", comentario: "Repuesto puesto" });
  });

  it("si la base niega el avance, el problema se muestra y no se refresca", async () => {
    const user = userEvent.setup();
    fakes.rol = "TECNICO";
    fakes.obtenerOrden.mockResolvedValue({
      ok: true,
      datos: ORDEN({ tecnico: "Otro Técnico" }),
    });
    fakes.cambiarEstado.mockResolvedValue({ ok: false, mensaje: "Solo el técnico asignado puede cambiar el estado" });
    montar();
    await cargada();
    await user.selectOptions(screen.getByRole("combobox", { name: "Avanzar a:" }), "En reparación");
    await user.click(screen.getByRole("button", { name: "Avanzar" }));
    expect((await screen.findByRole("alert")).textContent).toMatch(/Solo el técnico asignado/);
    expect(fakes.obtenerOrden).toHaveBeenCalledTimes(1);
  });

  it("una orden entregada ya no ofrece avanzar, rechazar ni asignar", async () => {
    fakes.obtenerOrden.mockResolvedValue({
      ok: true,
      datos: ORDEN({ estado: "ENTREGADO", estado_nombre: "Entregado" }),
    });
    montar();
    expect(await cargada()).toBeTruthy();
    expect(screen.queryByRole("combobox", { name: "Avanzar a:" })).toBeNull();
    expect(screen.queryByRole("button", { name: "Rechazar" })).toBeNull();
    expect(screen.queryByRole("button", { name: "Asignar técnico" })).toBeNull();
  });
});

describe("OrdenDetalle: acciones por rol — Rechazar", () => {
  it("se ofrece solo a jefatura desde RECIBIDO/EN_DIAGNOSTICO/PRESUPUESTADO", async () => {
    fakes.obtenerOrden.mockResolvedValue({
      ok: true,
      datos: ORDEN({ estado: "EN_REPARACION", estado_nombre: "En reparación" }),
    });
    montar();
    await cargada();
    expect(screen.queryByRole("button", { name: "Rechazar" })).toBeNull();
  });

  it("abre un modal que pide el motivo y no envía menos de 10 caracteres", async () => {
    const user = userEvent.setup();
    montar();
    await cargada();
    await user.click(screen.getByRole("button", { name: "Rechazar" }));
    const dialogo = screen.getByRole("dialog", { name: "Rechazar orden" });
    await user.type(screen.getByPlaceholderText(/motivo/i), "equipo");
    expect(screen.getByRole("button", { name: "Rechazar orden" })).toBeDisabled();
    await user.click(screen.getByRole("button", { name: "Rechazar orden" }));
    expect(fakes.cambiarEstado).not.toHaveBeenCalled();
    expect(dialogo).toBeVisible();
  });

  it("con un motivo de sustancia envía RECHAZADO + motivo y recarga la orden", async () => {
    const user = userEvent.setup();
    fakes.obtenerOrden
      .mockResolvedValueOnce({ ok: true, datos: ORDEN() })
      .mockResolvedValueOnce({
        ok: true,
        datos: ORDEN({ estado: "RECHAZADO", estado_nombre: "Rechazado", motivo_rechazo: "Equipo con humedad evidente" }),
      });
    montar();
    await cargada();
    await user.click(screen.getByRole("button", { name: "Rechazar" }));
    await user.type(screen.getByPlaceholderText(/motivo/i), "Equipo con humedad evidente");
    await user.click(screen.getByRole("button", { name: "Rechazar orden" }));
    expect(fakes.cambiarEstado).toHaveBeenCalledWith("o1", {
      estado: "RECHAZADO",
      motivo: "Equipo con humedad evidente",
    });
    expect(fakes.obtenerOrden).toHaveBeenCalledTimes(2);
    expect(await screen.findByRole("heading", { name: "OS-2026-0007" })).toBeTruthy();
  });

  it("si la base rechaza el cambio, el mensaje del servicio sale en el modal", async () => {
    const user = userEvent.setup();
    fakes.cambiarEstado.mockResolvedValue({
      ok: false,
      codigo: "SIN_PERMISO",
      mensaje: "Su rol no puede cambiar el estado de la orden",
    });
    montar();
    await cargada();
    await user.click(screen.getByRole("button", { name: "Rechazar" }));
    await user.type(screen.getByPlaceholderText(/motivo/i), "Equipo con humedad evidente");
    await user.click(screen.getByRole("button", { name: "Rechazar orden" }));
    expect((await screen.findByRole("alert")).textContent).toMatch(/Su rol no puede cambiar el estado/);
  });
});

describe("OrdenDetalle: acciones por rol — Asignar técnico", () => {
  it("un técnico ni lo ve; para jefatura los técnicos llegan listarTecnicos", async () => {
    fakes.rol = "TECNICO";
    montar();
    await cargada();
    expect(screen.queryByRole("button", { name: "Asignar técnico" })).toBeNull();
    expect(fakes.listarTecnicos).not.toHaveBeenCalled();
  });

  it("el modal ofrece los técnicos activos (listarTecnicos)", async () => {
    const user = userEvent.setup();
    montar();
    await cargada();
    await user.click(screen.getByRole("button", { name: "Asignar técnico" }));
    expect(fakes.listarTecnicos).toHaveBeenCalledTimes(1);
    const cb = screen.getByRole("combobox", { name: "Técnico" });
    expect(Array.from(cb.options).map((o) => o.textContent)).toEqual(["Elegir técnico", "Tomás Técnico", "Luis López"]);
  });

  it("asignar llama asignarTecnico y refresca; el error de la base se muestra", async () => {
    const user = userEvent.setup();
    fakes.obtenerOrden
      .mockResolvedValueOnce({ ok: true, datos: ORDEN({ tecnico: null }) })
      .mockResolvedValueOnce({ ok: true, datos: ORDEN({ tecnico: "Tomás Técnico" }) });
    montar();
    await cargada();
    await user.click(screen.getByRole("button", { name: "Asignar técnico" }));
    expect(screen.getByRole("button", { name: "Asignar" })).toBeDisabled();
    await user.selectOptions(screen.getByRole("combobox", { name: "Técnico" }), "Tomás Técnico");
    await user.click(screen.getByRole("button", { name: "Asignar" }));
    expect(fakes.asignarTecnico).toHaveBeenCalledWith("o1", "t1");
    expect(fakes.obtenerOrden).toHaveBeenCalledTimes(2);
    expect(await screen.findByText(/Tomás Técnico/)).toBeTruthy();
  });
});

describe("OrdenDetalle: acciones por rol — RECEPCION", () => {
  it("con la orden Reparada, recepción solo marca Entregado y hace el cambio", async () => {
    const user = userEvent.setup();
    fakes.rol = "RECEPCION";
    fakes.obtenerOrden.mockResolvedValue({
      ok: true,
      datos: ORDEN({ estado: "REPARADO", estado_nombre: "Reparado" }),
    });
    montar();
    await cargada();
    expect(await opcionesDe()).toEqual(["Elegir estado", "Entregado"]);
    expect(screen.queryByRole("button", { name: "Rechazar" })).toBeNull();
    expect(screen.queryByRole("button", { name: "Asignar técnico" })).toBeNull();
    await user.selectOptions(screen.getByRole("combobox", { name: "Avanzar a:" }), "Entregado");
    await user.click(screen.getByRole("button", { name: "Avanzar" }));
    expect(fakes.cambiarEstado).toHaveBeenCalledWith("o1", { estado: "ENTREGADO", comentario: null });
  });
});

// Pestaña Auditoría: la lista de revisiones SIEMPRE se muestra; el formulario
// de revisión técnica lo deja el propio RevisionForm fuera del alcance de
// RECEPCION (la base decide con registrar_revision).
describe("OrdenDetalle: pestaña Auditoría", () => {
  it("muestra la lista y el formulario de revisión técnica", async () => {
    const user = userEvent.setup();
    fakes.listarRevisiones.mockResolvedValue({
      ok: true,
      datos: [
        {
          id: "r1",
          tipo: "TECNICA",
          revisado_en: "2026-10-26T09:00:00+00:00",
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
    await user.click(screen.getByRole("button", { name: "Guardar revisión" }));
    expect(fakes.registrarRevision).toHaveBeenCalledWith(
      "o1",
      expect.objectContaining({ tipo: "TECNICA" }),
    );
    expect(await screen.findByText(/Revisión guardada/)).toBeTruthy();
    expect(fakes.listarRevisiones).toHaveBeenCalledTimes(2); // la lista se recarga
    expect(fakes.obtenerOrden).toHaveBeenCalledTimes(2); // la orden también (cambió el equipo)
  });

  it("a RECEPCION la auditoría se muestra sin formulario", async () => {
    fakes.rol = "RECEPCION";
    montar();
    await cargada();
    await pestana("Auditoría");
    expect(await screen.findByRole("note")).toHaveTextContent("Tu rol no registra revisiones");
    expect(screen.queryByRole("button", { name: "Guardar revisión" })).toBeNull();
    expect(fakes.registrarRevision).not.toHaveBeenCalled();
  });
});

describe("OrdenDetalle: pestaña Diagnóstico y presupuesto", () => {
  it("guarda el diagnóstico por el UPDATE directo y refresca la orden", async () => {
    const user = userEvent.setup();
    montar();
    await cargada();
    await pestana("Diagnóstico y presupuesto");
    await user.type(screen.getByLabelText("Diagnóstico"), "Fuente quemada");
    await user.click(screen.getByRole("button", { name: "Guardar diagnóstico" }));
    expect(fakes.actualizarDiagnostico).toHaveBeenCalledWith("o1", "Fuente quemada");
    expect(fakes.obtenerOrden).toHaveBeenCalledTimes(2);
    expect(await screen.findByRole("status")).toHaveTextContent("Diagnóstico guardado");
  });

  it("un error del servicio al guardar el diagnóstico se muestra", async () => {
    const user = userEvent.setup();
    fakes.actualizarDiagnostico.mockResolvedValue({ ok: false, codigo: "SIN_PERMISO", mensaje: "No permitido" });
    montar();
    await cargada();
    await pestana("Diagnóstico y presupuesto");
    await user.type(screen.getByLabelText("Diagnóstico"), "Fuente quemada");
    await user.click(screen.getByRole("button", { name: "Guardar diagnóstico" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("No permitido");
    expect(fakes.obtenerOrden).toHaveBeenCalledTimes(1);
  });

  it("en PAGO registra el presupuesto y refresca", async () => {
    const user = userEvent.setup();
    fakes.obtenerOrden.mockResolvedValue({
      ok: true,
      datos: ORDEN({ tipo_atencion: "PAGO", cobertura: "FUERA_DE_GARANTIA" }),
    });
    montar();
    await cargada();
    await pestana("Diagnóstico y presupuesto");
    await user.type(screen.getByLabelText("Presupuesto (monto)"), "60");
    await user.click(screen.getByRole("button", { name: "Registrar presupuesto" }));
    expect(fakes.registrarPresupuesto).toHaveBeenCalledWith("o1", 60);
    expect(fakes.obtenerOrden).toHaveBeenCalledTimes(2);
  });

  it("un rechazo de la base al presupuestar se muestra", async () => {
    const user = userEvent.setup();
    fakes.obtenerOrden.mockResolvedValue({
      ok: true,
      datos: ORDEN({ tipo_atencion: "PAGO", cobertura: "FUERA_DE_GARANTIA" }),
    });
    fakes.registrarPresupuesto.mockResolvedValue({ ok: false, mensaje: "La orden está cerrada" });
    montar();
    await cargada();
    await pestana("Diagnóstico y presupuesto");
    await user.type(screen.getByLabelText("Presupuesto (monto)"), "60");
    await user.click(screen.getByRole("button", { name: "Registrar presupuesto" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("La orden está cerrada");
    expect(fakes.obtenerOrden).toHaveBeenCalledTimes(1);
  });

  it("en PRESUPUESTADO los botones recepcionan la decisión del cliente", async () => {
    const user = userEvent.setup();
    fakes.obtenerOrden.mockResolvedValue({
      ok: true,
      datos: ORDEN({ tipo_atencion: "PAGO", cobertura: "FUERA_DE_GARANTIA", estado: "PRESUPUESTADO", estado_nombre: "Presupuestado" }),
    });
    montar();
    await cargada();
    await pestana("Diagnóstico y presupuesto");
    await user.click(screen.getByRole("button", { name: "Aceptó el presupuesto" }));
    expect(fakes.cambiarEstado).toHaveBeenCalledWith("o1", { estado: "EN_REPARACION" });
    expect(fakes.obtenerOrden).toHaveBeenCalledTimes(2);
    await user.click(screen.getByRole("button", { name: "No aceptó el presupuesto" }));
    expect(fakes.cambiarEstado).toHaveBeenCalledWith("o1", { estado: "RECHAZADO_POR_CLIENTE" });
    expect(fakes.obtenerOrden).toHaveBeenCalledTimes(3);
  });
});

describe("OrdenDetalle: pestaña Bitácora — notas internas", () => {
  it("agrega una nota con agregarNota y recarga la bitácora", async () => {
    const user = userEvent.setup();
    fakes.notasOrden
      .mockResolvedValueOnce({ ok: true, datos: [] })
      .mockResolvedValue({
        ok: true,
        datos: [{ id: "n9", nota: "Llamar el lunes", created_at: "2026-10-30T12:00:00+00:00", autor: { full_name: "Jefe Jorge" } }],
      });
    montar();
    await cargada();
    await pestana("Bitácora");
    await user.type(screen.getByLabelText("Nota interna"), "Llamar el lunes");
    await user.click(screen.getByRole("button", { name: "Agregar nota" }));
    expect(fakes.agregarNota).toHaveBeenCalledWith("o1", "Llamar el lunes");
    expect(await screen.findByText(/Llamar el lunes/)).toBeTruthy();
    expect(fakes.notasOrden).toHaveBeenCalledTimes(2);
  });

  it("una nota vacía no se envía", async () => {
    const user = userEvent.setup();
    montar();
    await cargada();
    await pestana("Bitácora");
    expect(screen.getByRole("button", { name: "Agregar nota" })).toBeDisabled();
    await user.click(screen.getByRole("button", { name: "Agregar nota" }));
    expect(fakes.agregarNota).not.toHaveBeenCalled();
  });
});
