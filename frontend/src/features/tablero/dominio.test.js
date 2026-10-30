// Pruebas del espejo del dominio — Tarea 6 de la fase 2a (migración 0016):
// el estado RECHAZADO (decisión del taller) entra al catálogo con tono
// ADVERSO y NO es terminal (tiene la salida ÚNICA a ENTREGADO), por lo que
// sigue contando como orden abierta.
import { describe, expect, it } from "vitest";
import { ESTADOS, ESTADOS_TERMINALES, estaAbierta } from "./dominio.js";

describe("estado RECHAZADO (0016)", () => {
  it("RECHAZADO existe en ESTADOS con tono adverso y final=false", () => {
    const e = ESTADOS.find((x) => x.codigo === "RECHAZADO");
    expect(e).toBeDefined();
    expect(e.nombre).toBe("Rechazado");
    expect(e.tono).toBe("adverso");
    expect(e.final).toBe(false);
  });

  it("RECHAZADO va en el orden 85: tras RECHAZADO_POR_CLIENTE y antes de ENTREGADO", () => {
    const codigos = ESTADOS.map((x) => x.codigo);
    expect(codigos.indexOf("RECHAZADO")).toBeGreaterThan(
      codigos.indexOf("RECHAZADO_POR_CLIENTE"),
    );
    expect(codigos.indexOf("RECHAZADO")).toBeLessThan(codigos.indexOf("ENTREGADO"));
  });

  it("estaAbierta('RECHAZADO') es true: solo ENTREGADO y ANULADO cierran", () => {
    expect(estaAbierta("RECHAZADO")).toBe(true);
  });

  it("ESTADOS tiene ahora 11 entradas", () => {
    expect(ESTADOS).toHaveLength(11);
  });

  it("ESTADOS_TERMINALES no cambia: RECHAZADO no es terminal", () => {
    expect(ESTADOS_TERMINALES).toEqual(["ENTREGADO", "ANULADO"]);
  });
});