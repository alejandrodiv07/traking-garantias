// Pruebas del borrador local con caducidad de 24 h (Tarea 16 del plan).
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { guardarBorrador, leerBorrador, limpiarBorrador, limpiarBorradores } from "./borrador.js";

const USUARIO = "user-1";
const OTRO = "user-2";

beforeEach(() => {
  localStorage.clear();
  vi.useFakeTimers();
  vi.setSystemTime(new Date("2026-10-29T12:00:00"));
});

afterEach(() => {
  vi.useRealTimers();
});

describe("guardar y leer", () => {
  it("lo guardado se lee tal cual con la clave del usuario", () => {
    guardarBorrador(USUARIO, { serial: "RT5-8842-AA", paso: 1 });
    expect(leerBorrador(USUARIO)).toEqual({ serial: "RT5-8842-AA", paso: 1 });
  });

  it("el borrador de un usuario no es visible para otro (PC compartido)", () => {
    guardarBorrador(USUARIO, { serial: "RT5-8842-AA" });
    expect(leerBorrador(OTRO)).toBeNull();
  });

  it("un File incluido por error en el estado se descarta al guardar", () => {
    const archivo = new File([new Uint8Array(3)], "foto.jpg", { type: "image/jpeg" });
    guardarBorrador(USUARIO, { serial: "x", archivo });
    const borrador = leerBorrador(USUARIO);
    expect(JSON.parse(localStorage.getItem("pt.borrador." + USUARIO))).not.toContain("Foto");
    expect(borrador).toEqual({ serial: "x" });
  });
});

describe("caducidad a las 24 horas", () => {
  it("a 23 h 59 min todavía se lee", () => {
    guardarBorrador(USUARIO, { serial: "x" });
    vi.advanceTimersByTime(23 * 60 * 60 * 1000 + 59 * 60 * 1000);
    expect(leerBorrador(USUARIO)).toEqual({ serial: "x" });
  });

  it("a 24 h 1 min devuelve null y la clave desaparece", () => {
    guardarBorrador(USUARIO, { serial: "x" });
    vi.advanceTimersByTime(24 * 60 * 60 * 1000 + 60 * 1000);
    expect(leerBorrador(USUARIO)).toBeNull();
    expect(localStorage.getItem("pt.borrador." + USUARIO)).toBeNull();
  });
});

describe("limpieza", () => {
  it("limpiarBorrador borra la del usuario", () => {
    guardarBorrador(USUARIO, { serial: "x" });
    guardarBorrador(OTRO, { serial: "y" });
    limpiarBorrador(USUARIO);
    expect(leerBorrador(USUARIO)).toBeNull();
    expect(leerBorrador(OTRO)).toEqual({ serial: "y" });
  });

  it("limpiarBorradores borra las de todos (cierre de sesión en PC compartido)", () => {
    guardarBorrador(USUARIO, { serial: "x" });
    guardarBorrador(OTRO, { serial: "y" });
    limpiarBorradores();
    expect(leerBorrador(USUARIO)).toBeNull();
    expect(leerBorrador(OTRO)).toBeNull();
  });
});

describe("almacenamiento roto", () => {
  it("guardar con localStorage lleno/caído no rompe al asistente", () => {
    vi.spyOn(Storage.prototype, "setItem").mockImplementation(() => {
      throw new Error("QuotaExceededError");
    });
    let rompio = false;
    try {
      guardarBorrador(USUARIO, { serial: "x" });
    } finally {
      vi.restoreAllMocks();
    }
    expect(rompio).toBe(false);
  });

  it("leer con datos no JSON no rompe (devuelve null)", () => {
    localStorage.setItem("pt.borrador." + USUARIO, "{corrupto");
    expect(leerBorrador(USUARIO)).toBeNull();
  });
});