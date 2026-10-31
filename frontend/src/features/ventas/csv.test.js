// Parser del CSV de Ventas: corre en el navegador, sin dependencias. El
// servidor vuelve a validar todo; esto solo da la vista previa.
import { describe, expect, it } from "vitest";
import { aCsv, filasDeVentas, parseCsv } from "./csv.js";

describe("parseCsv", () => {
  it("separa por coma o por punto y coma según la cabecera", () => {
    expect(parseCsv("a,b\n1,2")).toEqual([["a", "b"], ["1", "2"]]);
    expect(parseCsv("a;b\n1;2")).toEqual([["a", "b"], ["1", "2"]]);
  });

  it("quita el BOM de UTF-8, acepta CRLF y salta líneas vacías", () => {
    expect(parseCsv("﻿a,b\r\n\r\n1,2\r\n\r\n")).toEqual([["a", "b"], ["1", "2"]]);
  });

  it("respeta comillas: el delimitador, las comillas dobles y los saltos de línea van dentro de la celda", () => {
    expect(parseCsv('a,b\n"x, y","di ""hola"""\n"l1\nl2",z')).toEqual([
      ["a", "b"],
      ["x, y", 'di "hola"'],
      ["l1\nl2", "z"],
    ]);
  });

  it("un archivo vacío no da filas", () => {
    expect(parseCsv("")).toEqual([]);
    expect(parseCsv("\n\n")).toEqual([]);
  });
});

const CAB = "numero_factura;fecha_emision;tipo_documento;numero_documento;nombre_cliente;serial;modelo";

describe("filasDeVentas", () => {
  it("convierte cada línea en el objeto que espera importar_ventas", () => {
    const r = filasDeVentas(`${CAB}\nF-1;2026-10-20;V;12345678;Juan Perez;RT5-1;HG8245`);
    expect(r.faltantes).toEqual([]);
    expect(r.filas).toHaveLength(1);
    expect(r.filas[0]).toMatchObject({
      linea: 2,
      error: null,
      datos: {
        numero_factura: "F-1",
        fecha_emision: "2026-10-20",
        tipo_documento: "V",
        numero_documento: "12345678",
        nombre_cliente: "Juan Perez",
        serial: "RT5-1",
        modelo: "HG8245",
      },
    });
  });

  it("acepta la fecha DD/MM/AAAA y la entrega en ISO", () => {
    const r = filasDeVentas(`${CAB}\nF-1;05/10/2026;V;1;x;RT5-1;m`);
    expect(r.filas[0].datos.fecha_emision).toBe("2026-10-05");
  });

  it("reconoce cabeceras con mayúsculas, tildes y espacios", () => {
    const r = filasDeVentas("Número Factura;Fecha Emisión;Número Documento;Serial\nF-1;2026-10-20;1;RT5-1");
    expect(r.faltantes).toEqual([]);
    expect(r.filas[0].error).toBeNull();
  });

  it("avisa de las columnas obligatorias que faltan en la cabecera", () => {
    const r = filasDeVentas("numero_factura;serial\nF-1;RT5-1");
    expect(r.faltantes).toEqual(["fecha_emision", "numero_documento"]);
  });

  it("marca la fila inválida con su campo y no la manda", () => {
    const r = filasDeVentas(
      [
        CAB,
        ";2026-10-20;V;1;x;RT5-1;m", // sin factura
        "F-2;ayer;V;1;x;RT5-2;m", // fecha ilegible
        "F-3;2999-01-01;V;1;x;RT5-3;m", // futura
        "F-4;2026-02-31;V;1;x;RT5-4;m", // fecha que no existe
        "F-5;2026-10-20;V;1;x;AB;m", // serial corto
      ].join("\n"),
    );
    expect(r.filas.map((f) => f.error?.campo)).toEqual([
      "numero_factura",
      "fecha_emision",
      "fecha_emision",
      "fecha_emision",
      "serial",
    ]);
    expect(r.filas.every((f) => f.datos === null || f.error)).toBe(true);
  });
});

describe("aCsv", () => {
  it("escribe cabecera y filas con comillas donde hace falta", () => {
    expect(aCsv(["a", "b"], [["x,y", 'di "hola"'], ["1", "2"]])).toBe('a,b\r\n"x,y","di ""hola"""\r\n1,2');
  });

  it("neutraliza las celdas que Excel leería como fórmula", () => {
    expect(aCsv(["a"], [["=1+1"], ["+cmd"], ["@x"], ["-5"]])).toBe("a\r\n'=1+1\r\n'+cmd\r\n'@x\r\n'-5");
  });
});
