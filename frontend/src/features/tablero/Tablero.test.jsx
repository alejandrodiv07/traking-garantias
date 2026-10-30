// Pruebas del Tablero con datos reales (Tarea 20 del plan; spec §7.3).
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";

const fakes = vi.hoisted(() => ({
  listarTablero: vi.fn(),
  listarRevisiones: vi.fn(),
  registrarRevision: vi.fn(),
}));

vi.mock("./tableroService.js", () => fakes);
// El borde del feature vecino (revisiones): Tablero lo consume montando
// HistorialRevisiones/RevisionForm; el servicio es el que se falsifica.
vi.mock("../revisiones/revisionesService.js", () => fakes);
vi.mock("../auth/AuthContext.jsx", () => ({
  useAuth: () => ({ perfil: { full_name: "Ada Admin" }, rol: "ADMIN", salir: vi.fn() }),
}));

import Tablero from "./Tablero.jsx";

const FILA = (extras = {}) => ({
  orden_id: "r1",
  numero_orden: "OS-2026-00001",
  estado: "RECIBIDO",
  estado_nombre: "Recibido",
  cobertura: "EN_GARANTIA",
  serial: "RT5-8842-AA",
  producto: "Huawei HG8245",
  cliente: "Juan Perez",
  documento: "305892147",
  fecha_ingreso: "2026-09-02T14:00:00+00:00",
  vence_el: "2026-09-08",
  dias_restantes: 5,
  nivel_vigencia: "PRONTO",
  dias_en_taller: 0,
  nivel_sla: "NORMAL",
  urgencia_rank: 1,
  abierto: true,
  numero_soporte: "F-200",
  ...extras,
});

beforeEach(() => {
  fakes.listarTablero.mockReset().mockResolvedValue({ ok: true, filas: [] });
  fakes.listarRevisiones.mockReset().mockResolvedValue({ ok: true, datos: [] });
  fakes.registrarRevision.mockReset().mockResolvedValue({
    ok: true,
    datos: { revision_id: "v9", cobertura: "EN_GARANTIA" },
  });
});

describe("TablaRegistros", () => {
  it("muestra POR SEPARADO los días restantes y los días en taller", async () => {
    fakes.listarTablero.mockResolvedValue({ ok: true, filas: [FILA()] });
    render(<Tablero />);
    await waitFor(() => expect(screen.getAllByText(/RT5-8842-AA/).length >= 1).toBe(true));
    expect(screen.getByText(/5 d\b/)).toBeTruthy();   // días restantes de la garantía
    expect(screen.getByText(/0 días en taller/)).toBeTruthy();
  });

  it("una fila PENDIENTE muestra 'Sin factura'", async () => {
    fakes.listarTablero.mockResolvedValue({
      ok: true,
      filas: [FILA({ nivel_vigencia: "PENDIENTE", vence_el: null, dias_restantes: null, cobertura: "POR_DETERMINAR" })],
    });
    render(<Tablero />);
    await waitFor(() => expect(screen.getByText(/Sin factura/)).toBeTruthy());
  });
});

describe("el detalle del registro (Revisiones desde el Tablero)", () => {
  it("al pulsar Revisar se abre el detalle con el código y las revisiones cargadas", async () => {
    fakes.listarTablero.mockResolvedValue({ ok: true, filas: [FILA()] });
    fakes.listarRevisiones.mockResolvedValue({
      ok: true,
      datos: [
        {
          id: "v1",
          tipo: "RECEPCION",
          revisor: { full_name: "Ada Admin" },
          revisado_en: "2026-09-02T14:00:00+00:00",
          checklist: {},
          resultado: "POR_DETERMINAR",
          observaciones: "Entrada sin factura",
        },
      ],
    });
    render(<Tablero />);
    await userEvent.setup().click(await screen.findByRole("button", { name: "Revisar OS-2026-00001" }));
    const dialogo = screen.getByRole("dialog", { name: /Detalle de OS-2026-00001/ });
    expect(dialogo).toBeTruthy();
    // el encabezado identifica al equipo (el serial también aparece en la tabla
    // y en el panel de vencimientos, por eso se comprueba que exista)
    expect(screen.getAllByText(/Huawei HG8245/).length >= 1).toBe(true);
    expect(screen.getAllByText(/RT5-8842-AA/).length >= 1).toBe(true);
    // las revisiones del registro se piden y se pintan
    await waitFor(() => expect(screen.getAllByTestId("revision").length >= 1).toBe(true));
    expect(fakes.listarRevisiones).toHaveBeenCalledWith("r1");
    // y el formulario de revisión queda montado
    expect(screen.getByRole("button", { name: /Guardar revisión/ })).toBeTruthy();
  });

  it("guardar una revisión recarga el listado del tablero", async () => {
    fakes.listarTablero.mockResolvedValue({ ok: true, filas: [FILA()] });
    render(<Tablero />);
    const user = userEvent.setup();
    await waitFor(() => expect(screen.getByRole("button", { name: "Revisar OS-2026-00001" })).toBeTruthy());
    expect(fakes.listarTablero).toHaveBeenCalledTimes(1);
    await user.click(screen.getByRole("button", { name: "Revisar OS-2026-00001" }));
    await user.click(screen.getByRole("button", { name: /Guardar revisión/ }));
    await waitFor(() => expect(fakes.listarTablero).toHaveBeenCalledTimes(2));
  });
});

describe("la barra del Tablero", () => {
  it('el botón dice "Nuevo registro" y abre el asistente', async () => {
    render(<Tablero />);
    const boton = await screen.findByRole("button", { name: /Nuevo registro/ });
    await userEvent.setup().click(boton);
    expect(screen.getByRole("dialog", { name: /Nuevo registro/ })).toBeTruthy();
  });

  it("estado vacío", async () => {
    render(<Tablero />);
    await waitFor(() => expect(screen.getByText(/no hay registros|Sin registros/i)).toBeTruthy());
  });

  it("estado de error con Reintentar", async () => {
    fakes.listarTablero.mockResolvedValue({ ok: false, codigo: "SIN_CONEXION", mensaje: "Sin conexión" });
    render(<Tablero />);
    const reintentar = await screen.findByRole("button", { name: /Reintentar/ });
    expect(reintentar).toBeTruthy();
  });
});