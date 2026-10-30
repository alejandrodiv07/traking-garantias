// Pruebas del hook del asistente (Tarea 17 del plan; spec §7.1 y §7.2).
import { act, renderHook, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const fakes = vi.hoisted(() => ({
  guardarBorrador: vi.fn(),
  leerBorrador: vi.fn(),
  limpiarBorrador: vi.fn(),
}));

vi.mock("./borrador.js", async (importOriginal) => ({
  ...(await importOriginal()),
  guardarBorrador: fakes.guardarBorrador,
  leerBorrador: fakes.leerBorrador,
  limpiarBorrador: fakes.limpiarBorrador,
}));

import { useAsistente } from "./useAsistente.js";

beforeEach(() => {
  fakes.guardarBorrador.mockReset();
  fakes.leerBorrador.mockReset();
  fakes.leerBorrador.mockReturnValue(null);
  fakes.limpiarBorrador.mockReset();
});

describe("useAsistente", () => {
  it("los pasos en orden son equipo→cliente→compra→verificacion→adjuntos→resumen", () => {
    const { result } = renderHook(() => useAsistente("u1"));
    expect(result.current.pasos).toEqual([
      "equipo", "cliente", "compra", "verificacion", "adjuntos", "resumen",
    ]);
    expect(result.current.paso).toBe(0);
  });

  it("siguiente() avanza, atras() retrocede y no pasa del final", () => {
    const { result } = renderHook(() => useAsistente("u1"));
    act(() => result.current.siguiente());
    expect(result.current.paso).toBe(1);
    act(() => result.current.atras());
    expect(result.current.paso).toBe(0);
    act(() => result.current.atras());
    expect(result.current.paso).toBe(0);
  });

  it("actualizar() fusiona parcial y el borrador se guarda con cada cambio", () => {
    const { result } = renderHook(() => useAsistente("u1"));
    act(() => result.current.actualizar({ serial: "RT5-8842-AA" }));
    act(() => result.current.actualizar({ falla: "No enciende" }));
    expect(result.current.estado).toEqual({ serial: "RT5-8842-AA", falla: "No enciende" });
    expect(fakes.guardarBorrador).toHaveBeenCalledWith("u1", result.current.estado);
  });

  it("ofrece restaurar el borrador que existía al abrir", async () => {
    fakes.leerBorrador.mockReturnValue({ serial: "BORRADOR-A", falla: "x" });
    const { result } = renderHook(() => useAsistente("u1"));
    await waitFor(() => expect(result.current.borradorOfrecido).toEqual({
      serial: "BORRADOR-A", falla: "x",
    }));
    // aún NO reemplaza el estado: el asistente ofrece, no obliga
    expect(result.current.estado).toEqual({});
  });

  it("restaurar() toma el borrador; descartar() no lo hace y lo limpia", async () => {
    fakes.leerBorrador.mockReturnValue({ serial: "BORRADOR-A" });
    const { result } = renderHook(() => useAsistente("u1"));
    await waitFor(() => expect(result.current.borradorOfrecido).not.toBeNull());
    act(() => result.current.restaurar());
    expect(result.current.estado).toEqual({ serial: "BORRADOR-A" });
    expect(result.current.borradorOfrecido).toBeNull();
  });

  it("si se reutiliza un equipo, el paso compra se OMITE", () => {
    const { result } = renderHook(() => useAsistente("u1"));
    act(() => result.current.actualizar({ equipoReutilizado: true }));
    act(() => result.current.siguiente());
    expect(result.current.pasos).not.toContain("compra");
    // del paso 'equipo', siguiente() va directo a 'cliente'
    expect(result.current.pasos[result.current.paso]).toBe("cliente");
  });

  it("reiniciar() vacía el estado y limpia el borrador", () => {
    const { result } = renderHook(() => useAsistente("u1"));
    act(() => result.current.actualizar({ serial: "x" }));
    act(() => result.current.reiniciar());
    expect(result.current.estado).toEqual({});
    expect(result.current.paso).toBe(0);
    expect(fakes.limpiarBorrador).toHaveBeenCalledWith("u1");
  });
});