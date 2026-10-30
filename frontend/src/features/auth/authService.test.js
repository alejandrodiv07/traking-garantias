// Prueba del gancho de borradores en cerrarSesion (Tarea 16 del plan).
// El borrador contiene datos personales del CLIENTE y las laptops del
// taller son compartidas: al cerrar sesión, TODOS los borradores se van.
import { beforeEach, describe, expect, it, vi } from "vitest";

const fakes = vi.hoisted(() => ({
  signOut: vi.fn(),
  limpiarBorradores: vi.fn(),
}));

vi.mock("../../lib/supabaseClient.js", () => ({
  supabase: {
    auth: { signOut: fakes.signOut },
  },
  recordarSesion: () => {},   // cerrarSesion la llama en el finally
}));
vi.mock("../registro/borrador.js", () => ({
  limpiarBorradores: fakes.limpiarBorradores,
}));

import { cerrarSesion } from "./authService.js";

beforeEach(() => {
  fakes.signOut.mockReset();
  fakes.signOut.mockResolvedValue({});
  fakes.limpiarBorradores.mockClear();
});

describe("cerrarSesion", () => {
  it("limpia TODOS los borradores del PC", async () => {
    await cerrarSesion();
    expect(fakes.limpiarBorradores).toHaveBeenCalledTimes(1);
  });

  it("limpia los borradores AUNQUE falle el servidor (cutoff de internet)", async () => {
    fakes.signOut.mockRejectedValue(new Error("red caída"));
    await expect(cerrarSesion()).resolves.toBeUndefined();
    expect(fakes.limpiarBorradores).toHaveBeenCalledTimes(1);
  });
});