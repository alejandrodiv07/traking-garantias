// Idempotencia del envío (revisión de ingeniería H1/H2): el resumen genera UNA
// clave por registro y la manda siempre igual, también tras restaurar el borrador.
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";

const fakes = vi.hoisted(() => ({ enviarRegistro: vi.fn() }));
vi.mock("../enviarRegistro.js", () => ({ enviarRegistro: fakes.enviarRegistro }));

import PasoResumen from "./PasoResumen.jsx";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const ESTADO = { serial: "RT5-8842-AA", titular: "Juan Perez", falla: "No enciende", archivosAdjuntos: [] };
const actualizar = vi.fn();

beforeEach(() => {
  actualizar.mockReset();
  fakes.enviarRegistro.mockReset().mockResolvedValue({
    ok: false, codigo: "SIN_CONEXION", mensaje: "Sin conexión", pendientes: [],
  });
});

describe("PasoResumen: clave de envío", () => {
  it("la primera vez genera una clave uuid, la guarda en el borrador y la envía", async () => {
    render(<PasoResumen estado={ESTADO} irPara={vi.fn()} actualizar={actualizar} userId="u1" />);
    await userEvent.setup().click(screen.getByRole("button", { name: /confirmar y registrar/i }));
    await waitFor(() => expect(fakes.enviarRegistro).toHaveBeenCalledTimes(1));
    const clave = actualizar.mock.calls.find(([p]) => p.claveEnvio)?.[0].claveEnvio;
    expect(clave).toMatch(UUID);
    expect(fakes.enviarRegistro.mock.calls[0][0].claveEnvio).toBe(clave);
  });

  it("si el estado ya trae clave (borrador restaurado) la reutiliza y no la regenera", async () => {
    render(<PasoResumen estado={{ ...ESTADO, claveEnvio: "clave-previa" }} irPara={vi.fn()} actualizar={actualizar} userId="u1" />);
    await userEvent.setup().click(screen.getByRole("button", { name: /confirmar y registrar/i }));
    await waitFor(() => expect(fakes.enviarRegistro).toHaveBeenCalledTimes(1));
    expect(fakes.enviarRegistro.mock.calls[0][0].claveEnvio).toBe("clave-previa");
    expect(actualizar).not.toHaveBeenCalled();
  });
});
