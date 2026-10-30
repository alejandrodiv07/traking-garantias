// Pruebas de la normalización del asistente (Tarea 15 del plan).
import { describe, expect, it } from "vitest";
import { normalizarSerie, normalizarDocumento } from "./normalizar.js";

describe("normalizarSerie", () => {
  it("los formatos distintos llevan al mismo valor", () => {
    expect(normalizarSerie("rt5-8842-aa")).toBe(normalizarSerie("RT5 8842 AA"));
  });

  it("los ceros a la izquierda se conservan ('00123' ≠ '123')", () => {
    expect(normalizarSerie("00123")).not.toBe(normalizarSerie("123"));
  });

  it("quita espacios, guiones y pasa a mayúsculas", () => {
    expect(normalizarSerie("rt5 8842 aa")).toBe("RT58842AA");
  });
});

describe("normalizarDocumento", () => {
  it("'J-30.589.214-7' → tipo J, documento 305892147", () => {
    expect(normalizarDocumento("J-30.589.214-7")).toEqual({
      tipo: "J",
      documento: "305892147",
    });
  });

  it("'v. 12 345 678' → tipo V, documento 12345678", () => {
    expect(normalizarDocumento("v. 12 345 678")).toEqual({
      tipo: "V",
      documento: "12345678",
    });
  });

  it("sin letra de tipo: tipo null y solo dígitos", () => {
    expect(normalizarDocumento("14.250.663")).toEqual({
      tipo: null,
      documento: "14250663",
    });
  });
});