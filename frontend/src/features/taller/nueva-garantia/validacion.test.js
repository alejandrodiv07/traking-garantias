import { describe, expect, it } from "vitest";
import {
  errorAccesorios,
  errorCategoria,
  errorDocumento,
  errorEmail,
  errorFallaReportada,
  errorFechaCompra,
  errorMesesGarantia,
  errorMesesOverride,
  errorModelo,
  errorNombre,
  errorNumeroFactura,
  errorNumeroSerie,
  errorSlaDias,
  errorTelefono,
  sinErrores,
} from "./validacion.js";

describe("errorNombre", () => {
  it("rechaza vacío", () => {
    expect(errorNombre("")).toBe("Este campo es obligatorio.");
  });
  it("rechaza menos de 3 caracteres", () => {
    expect(errorNombre("Al")).toMatch(/de 3 a 160/);
  });
  it("rechaza símbolos fuera de . , ' & -", () => {
    expect(errorNombre("Juan#Pérez")).toMatch(/Solo se permite/);
    expect(errorNombre("Juan@Pérez")).toMatch(/Solo se permite/);
  });
  it("acepta letras Unicode, dígitos, espacios y . , ' & -", () => {
    expect(errorNombre("José Muñoz")).toBeNull();
    expect(errorNombre("O'Brien & Asociados, C.A.")).toBeNull();
    expect(errorNombre("Distribuidora 2000")).toBeNull();
  });
});

describe("errorDocumento", () => {
  it("rechaza vacío", () => {
    expect(errorDocumento("")).toBe("Este campo es obligatorio.");
  });
  it("descarta letras mezcladas y valida solo los dígitos restantes (uso previsto: el campo ya filtra al escribir)", () => {
    // "12A4567" -> dígitos "124567": 6 dígitos, dentro de 5-15, así que pasa.
    expect(errorDocumento("12A4567")).toBeNull();
    // Si tras descartar las letras quedan menos de 5 dígitos, sigue fallando.
    expect(errorDocumento("1A2")).toMatch(/Solo se permite/);
  });
  it("rechaza menos de 5 o más de 15 dígitos", () => {
    expect(errorDocumento("1234")).toMatch(/Solo se permite/);
    expect(errorDocumento("1234567890123456")).toMatch(/Solo se permite/);
  });
  it("acepta de 5 a 15 dígitos", () => {
    expect(errorDocumento("12345")).toBeNull();
    expect(errorDocumento("123456789012345")).toBeNull();
  });
});

describe("errorTelefono", () => {
  it("es opcional", () => {
    expect(errorTelefono("")).toBeNull();
  });
  it("acepta un + inicial y dígitos", () => {
    expect(errorTelefono("+584141234567")).toBeNull();
    expect(errorTelefono("04141234567")).toBeNull();
  });
  it("rechaza letras o menos de 7 caracteres", () => {
    expect(errorTelefono("abc1234567")).toMatch(/Solo se permite/);
    expect(errorTelefono("123")).toMatch(/Solo se permite/);
  });
});

describe("errorEmail", () => {
  it("es opcional", () => {
    expect(errorEmail("")).toBeNull();
  });
  it("exige minúsculas", () => {
    expect(errorEmail("Cliente@Correo.com")).toBe("Escribe el correo en minúsculas.");
  });
  it("rechaza formato inválido", () => {
    expect(errorEmail("cliente-arroba-correo.com")).toMatch(/correo válido/);
    expect(errorEmail("cliente@correo")).toMatch(/correo válido/);
  });
  it("acepta un correo válido en minúsculas", () => {
    expect(errorEmail("cliente@correo.com")).toBeNull();
  });
});

describe("errorModelo", () => {
  it("rechaza vacío y símbolos no permitidos", () => {
    expect(errorModelo("")).toBe("Este campo es obligatorio.");
    expect(errorModelo("Router#500")).toMatch(/Solo se permite/);
  });
  it("acepta letras, dígitos, espacios y . , - /", () => {
    expect(errorModelo("Router Industrial EA2-RT500/A, v1.2")).toBeNull();
  });
});

describe("errorCategoria", () => {
  it("rechaza dígitos", () => {
    expect(errorCategoria("Categoria 2")).toMatch(/Solo se permite/);
  });
  it("acepta letras, espacios y guiones", () => {
    expect(errorCategoria("Conectividad industrial")).toBeNull();
  });
});

describe("errorMesesGarantia / errorMesesOverride / errorSlaDias", () => {
  it("exige enteros dentro de rango", () => {
    expect(errorMesesGarantia(-1)).toMatch(/0 a 120/);
    expect(errorMesesGarantia(12.5)).toMatch(/0 a 120/);
    expect(errorMesesGarantia(12)).toBeNull();

    expect(errorMesesOverride(0)).toMatch(/1 a 120/);
    expect(errorMesesOverride(24)).toBeNull();

    expect(errorSlaDias(0)).toMatch(/1 y 90/);
    expect(errorSlaDias(91)).toMatch(/1 y 90/);
    expect(errorSlaDias(5)).toBeNull();
  });
});

describe("errorNumeroSerie / errorNumeroFactura / errorAccesorios", () => {
  it("son opcionales", () => {
    expect(errorNumeroSerie("")).toBeNull();
    expect(errorNumeroFactura("")).toBeNull();
    expect(errorAccesorios("")).toBeNull();
  });
  it("numeroSerie solo acepta letras, dígitos y guiones", () => {
    expect(errorNumeroSerie("RT5-8842-AA")).toBeNull();
    expect(errorNumeroSerie("RT5_8842")).toMatch(/Solo se permite/);
  });
  it("numeroFactura acepta letras, dígitos, puntos y guiones", () => {
    expect(errorNumeroFactura("F-A-004821")).toBeNull();
    expect(errorNumeroFactura("F/004821")).toMatch(/Solo se permite/);
  });
});

describe("errorFallaReportada", () => {
  it("exige de 5 a 2000 caracteres", () => {
    expect(errorFallaReportada("abcd")).toMatch(/5 a 2000/);
    expect(errorFallaReportada("abcde")).toBeNull();
  });
});

describe("errorFechaCompra", () => {
  it("rechaza vacío, anteriores al 2000 y futuras", () => {
    expect(errorFechaCompra("", "2026-09-11")).toMatch(/fecha de compra válida/);
    expect(errorFechaCompra("1999-12-31", "2026-09-11")).toMatch(/fecha de compra válida/);
    expect(errorFechaCompra("2026-09-12", "2026-09-11")).toMatch(/no puede ser futura/);
    expect(errorFechaCompra("2026-09-11", "2026-09-11")).toBeNull();
  });
});

describe("sinErrores", () => {
  it("es true solo cuando ningún campo tiene mensaje", () => {
    expect(sinErrores({ a: null, b: null })).toBe(true);
    expect(sinErrores({ a: null, b: "algo" })).toBe(false);
  });
});
