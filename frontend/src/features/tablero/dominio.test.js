// Pruebas del espejo del dominio — Tarea 6 de la fase 2a (migración 0016):
// el estado RECHAZADO (decisión del taller) entra al catálogo con tono
// ADVERSO y NO es terminal (tiene la salida ÚNICA a ENTREGADO), por lo que
// sigue contando como orden abierta.
import { describe, expect, it } from "vitest";
import { ESTADOS, ESTADOS_TERMINALES, TRANSICIONES, estaAbierta, transicionesDesde } from "./dominio.js";

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

// Espejo de `transiciones_estado` (20260906000002 + 0016): la misma matriz
// que impone el trigger, en el formato que la UI filtra por rol.
describe("TRANSICIONES (espejo de transiciones_estado)", () => {
  it("la matriz tiene las 23 transiciones, ninguna auto-referida", () => {
    expect(TRANSICIONES).toHaveLength(23);
    expect(TRANSICIONES.every((t) => t.desde !== t.hasta)).toBe(true);
  });

  const salida = (desde) => transicionesDesde(desde, "ADMIN").map((e) => e.codigo);
  const salidaRol = (desde, rol) => transicionesDesde(desde, rol).map((e) => e.codigo);

  it("desde EN_DIAGNOSTICO, un técnico solo llega a Presupuestado/En reparación/Irreparable", () => {
    expect(salidaRol("EN_DIAGNOSTICO", "TECNICO")).toEqual(["PRESUPUESTADO", "EN_REPARACION", "IRREPARABLE"]);
  });

  it("desde EN_DIAGNOSTICO, jefatura también puede Rechazar o Anular", () => {
    expect(salida("EN_DIAGNOSTICO")).toEqual([
      "PRESUPUESTADO",
      "EN_REPARACION",
      "IRREPARABLE",
      "ANULADO",
      "RECHAZADO",
    ]);
  });

  it("desde PRESUPUESTADO, RECEPCION solo recepciona la decisión del cliente", () => {
    expect(salidaRol("PRESUPUESTADO", "RECEPCION")).toEqual(["EN_REPARACION", "RECHAZADO_POR_CLIENTE"]);
  });

  it("desde REPARADO, recepción solo marca Entregado", () => {
    expect(salidaRol("REPARADO", "RECEPCION")).toEqual(["ENTREGADO"]);
  });

  it("desde RECIBIDO, la única avanzable sin jefatura es En diagnóstico", () => {
    expect(salidaRol("RECIBIDO", "TECNICO")).toEqual(["EN_DIAGNOSTICO"]);
  });

  it("el rechazo del taller (RECHAZADO) solo tiene la salida a Entregado", () => {
    expect(salida("RECHAZADO")).toEqual(["ENTREGADO"]);
  });

  it("de los estados terminales no salen transiciones", () => {
    expect(TRANSICIONES.filter((t) => t.hasta === "ENTREGADO").map((t) => t.desde).sort()).toEqual([
      "IRREPARABLE",
      "RECHAZADO",
      "RECHAZADO_POR_CLIENTE",
      "REPARADO",
    ]);
    expect(TRANSICIONES.filter((t) => t.desde === "ENTREGADO" || t.desde === "ANULADO")).toHaveLength(0);
  });

  it("cada destino del espejo es un estado del catálogo (nada inventado)", () => {
    const codigos = new Set(ESTADOS.map((e) => e.codigo));
    for (const t of TRANSICIONES) {
      expect(codigos.has(t.desde)).toBe(true);
      expect(codigos.has(t.hasta)).toBe(true);
    }
  });
});