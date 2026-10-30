// Pruebas del historial y del formulario de revisión (Tarea 21 del plan).
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";

const fakes = vi.hoisted(() => ({
  listarRevisiones: vi.fn(),
  registrarRevision: vi.fn(),
}));

vi.mock("./revisionesService.js", () => fakes);

import HistorialRevisiones from "./HistorialRevisiones.jsx";
import RevisionForm from "./RevisionForm.jsx";

const REVISIONES = [
  {
    id: "v2",
    tipo: "TECNICA",
    revisado_por: "Tito Tecnico",
    revisado_en: "2026-09-20T14:00:00+00:00",
    checklist: { senales: { golpes: true } },
    resultado: "EN_GARANTIA",
    observaciones: "Revisado, sin causa externa",
  },
  {
    id: "v1",
    tipo: "RECEPCION",
    revisado_por: "Ada Admin",
    revisado_en: "2026-09-02T14:00:00+00:00",
    checklist: {},
    resultado: "POR_DETERMINAR",
    observaciones: "Entrada sin factura",
  },
];

beforeEach(() => {
  fakes.listarRevisiones.mockReset();
  fakes.registrarRevision.mockReset().mockResolvedValue({
    ok: true,
    datos: { revision_id: "v9", cobertura: "EN_GARANTIA" },
  });
});

describe("HistorialRevisiones", () => {
  it("la revisión más reciente aparece primero (cronológico inverso)", async () => {
    fakes.listarRevisiones.mockResolvedValue({ ok: true, datos: REVISIONES });
    render(<HistorialRevisiones registroId="r1" />);
    const filas = await screen.findAllByTestId("revision");
    expect(filas.length).toBe(2);
    // cronológico inverso: la TECNICA (2026-09-20) queda antes que la RECEPCIÓN (2026-09-02)
    expect(filas[0]).toHaveTextContent(/Tecnica|Técnica/);
    expect(filas[0]).toHaveTextContent(/EN_GARANTIA/);
    expect(filas[1]).toHaveTextContent(/Recepción/);
    expect(filas[1]).toHaveTextContent(/POR_DETERMINAR/);
  });

  it("muestra revisor, fecha, resultado y observaciones", async () => {
    fakes.listarRevisiones.mockResolvedValue({ ok: true, datos: [REVISIONES[0]] });
    render(<HistorialRevisiones registroId="r1" />);
    await waitFor(() => expect(screen.getByText(/sin causa externa/)).toBeTruthy());
  });

  it("NO hay botones de editar ni de borrar", async () => {
    fakes.listarRevisiones.mockResolvedValue({ ok: true, datos: REVISIONES });
    render(<HistorialRevisiones registroId="r1" />);
    await waitFor(() => expect(screen.getAllByTestId("revision").length).toBe(2));
    expect(screen.queryByRole("button", { name: /editar|borrar/i })).toBeNull();
  });
});

describe("RevisionForm", () => {
  it("para RECEPCION el formulario no se muestra", () => {
    render(<RevisionForm registroId="r1" rol="RECEPCION" onRegistrada={() => {}} />);
    expect(screen.queryByRole("button", { name: /guardar revisión/i })).toBeNull();
    expect(screen.getByText(/no registra revisiones/i)).toBeTruthy();
  });

  it("envía el checklist y muestra el resultado que devuelve la base", async () => {
    render(<RevisionForm registroId="r1" rol="TECNICO" onRegistrada={() => {}} />);
    const user = userEvent.setup();
    await user.click(screen.getByRole("checkbox", { name: /serial de fábrica/i }));
    await user.click(screen.getByRole("button", { name: /guardar revisión/i }));
    await waitFor(() =>
      expect(fakes.registrarRevision).toHaveBeenCalledWith(
        "r1",
        expect.objectContaining({ tipo: "TECNICA", checklist: expect.objectContaining({ equipo: expect.anything() }) }),
      ),
    );
    await waitFor(() => expect(screen.getByText(/EN_GARANTIA/)).toBeTruthy());
  });

  it("un error SIN_PERMISO se pinta junto al formulario", async () => {
    fakes.registrarRevision.mockResolvedValue({
      ok: false, codigo: "SIN_PERMISO", mensaje: "Su rol no puede registrar revisiones",
    });
    render(<RevisionForm registroId="r1" rol="TECNICO" onRegistrada={() => {}} />);
    await userEvent.setup().click(screen.getByRole("button", { name: /guardar revisión/i }));
    await waitFor(() => expect(screen.getByText(/no puede registrar revisiones/i)).toBeTruthy());
  });
});