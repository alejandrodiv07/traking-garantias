/**
 * Filtrado, búsqueda y paginación del tablero — la capa que el operador
 * toca cada vez que pulsa una píldora o escribe en el buscador.
 *
 * Las pruebas de `ordenes.test.js` cubren la FORMA del resultado (una fila
 * de `v_ordenes_tablero` -> la forma que espera `TablaOrdenes`). Estas
 * cubren la PREGUNTA: qué se le pide realmente a PostgREST. Son cosas
 * distintas y sólo la segunda falla cuando alguien rompe un filtro.
 */
import { describe, expect, it, vi } from "vitest";
import { crearConsultaFalsa } from "../../../test/supabaseFake.js";

vi.mock("../../../lib/supabaseClient.js");
// eslint-disable-next-line import/order -- el mock debe registrarse antes de este import
import { supabase } from "../../../lib/supabaseClient.js";
import { consultarOrdenes, contarPorEstado } from "./ordenes.js";

const VACIO = { data: [], error: null, count: 0 };

/** Deja preparada UNA consulta falsa y la devuelve para inspeccionarla. */
function prepararConsulta(resultado = VACIO) {
  const consulta = crearConsultaFalsa(resultado);
  supabase.from.mockReturnValue(consulta);
  return consulta;
}

describe("consultarOrdenes · filtro por estado", () => {
  it('con "TODAS" no manda ningún filtro de estado: la píldora "Todas" tiene que ver el taller entero', async () => {
    const consulta = prepararConsulta();

    await consultarOrdenes({ estado: "TODAS" });

    expect(consulta.seLlamo("eq")).toBe(false);
  });

  it("con un código concreto filtra por esa columna en la consulta, no en el navegador", async () => {
    const consulta = prepararConsulta();

    await consultarOrdenes({ estado: "EN_REPARACION" });

    expect(consulta.argumentosDe("eq")).toEqual(["estado", "EN_REPARACION"]);
  });

  it("lee del tablero y no de `garantias`: la vista es la que respeta la RLS y no expone costos ni notas", async () => {
    prepararConsulta();

    await consultarOrdenes({});

    expect(supabase.from).toHaveBeenCalledWith("v_ordenes_tablero");
  });
});

describe("consultarOrdenes · búsqueda", () => {
  it("busca en las seis columnas del buscador (nº de orden, cliente, documento, equipo, serial y factura)", async () => {
    const consulta = prepararConsulta();

    await consultarOrdenes({ termino: "ana" });

    const [expresion] = consulta.argumentosDe("or");
    expect(expresion).toBe(
      "numero_orden.ilike.%ana%,cliente.ilike.%ana%,documento.ilike.%ana%," +
        "equipo.ilike.%ana%,numero_serie.ilike.%ana%,numero_factura.ilike.%ana%"
    );
  });

  it("un término en blanco no es una búsqueda: no se manda `or` y la tabla sigue completa", async () => {
    const consulta = prepararConsulta();

    await consultarOrdenes({ termino: "   " });

    expect(consulta.seLlamo("or")).toBe(false);
  });

  it("filtro y búsqueda se combinan: buscar dentro de un estado no descarta el estado", async () => {
    const consulta = prepararConsulta();

    await consultarOrdenes({ estado: "RECIBIDO", termino: "SER-1" });

    expect(consulta.argumentosDe("eq")).toEqual(["estado", "RECIBIDO"]);
    expect(consulta.argumentosDe("or")[0]).toContain("numero_serie.ilike.%SER-1%");
  });

  it("una coma o un paréntesis en el término no rompen la gramática de `or()`", async () => {
    const consulta = prepararConsulta();

    await consultarOrdenes({ termino: "Perez, Ana (2)" });

    const [expresion] = consulta.argumentosDe("or");
    expect(expresion).toContain("cliente.ilike.%Perez  Ana  2 %");
  });

  it("un `%` escrito por el usuario se busca literalmente, no como comodín que devuelve el taller entero", async () => {
    const consulta = prepararConsulta();

    await consultarOrdenes({ termino: "100%" });

    const [expresion] = consulta.argumentosDe("or");
    expect(expresion).toContain("numero_orden.ilike.%100\\%%");
  });

  it("un `_` escrito por el usuario tampoco es comodín de un carácter", async () => {
    const consulta = prepararConsulta();

    await consultarOrdenes({ termino: "ORD_2026" });

    const [expresion] = consulta.argumentosDe("or");
    expect(expresion).toContain("numero_orden.ilike.%ORD\\_2026%");
  });
});

describe("consultarOrdenes · paginación", () => {
  it("la primera página pide el rango 0-24", async () => {
    const consulta = prepararConsulta();

    await consultarOrdenes({ pagina: 0, porPagina: 25 });

    expect(consulta.argumentosDe("range")).toEqual([0, 24]);
  });

  it("la tercera página pide el rango 50-74, sin solaparse ni saltarse una fila", async () => {
    const consulta = prepararConsulta();

    await consultarOrdenes({ pagina: 2, porPagina: 25 });

    expect(consulta.argumentosDe("range")).toEqual([50, 74]);
  });

  it("ordena por fecha de ingreso descendente: lo recién llegado, arriba", async () => {
    const consulta = prepararConsulta();

    await consultarOrdenes({});

    expect(consulta.argumentosDe("order")).toEqual([
      "fecha_ingreso",
      { ascending: false },
    ]);
  });
});

describe("contarPorEstado · los números de las píldoras", () => {
  it("cuenta sin traerse las filas (head: true) y pide el total exacto", async () => {
    const consulta = prepararConsulta({ count: 7, error: null });

    await contarPorEstado(["TODAS"]);

    expect(consulta.argumentosDe("select")).toEqual([
      "*",
      { count: "exact", head: true },
    ]);
  });

  it("respeta el término de búsqueda: una píldora no puede decir 40 cuando la tabla de al lado muestra 2", async () => {
    const consulta = prepararConsulta({ count: 2, error: null });

    await contarPorEstado(["RECIBIDO"], { termino: "ana" });

    expect(consulta.argumentosDe("or")[0]).toContain("cliente.ilike.%ana%");
  });

  it("sin término de búsqueda no manda `or`: el recuento es el del taller entero", async () => {
    const consulta = prepararConsulta({ count: 9, error: null });

    await contarPorEstado(["RECIBIDO"]);

    expect(consulta.seLlamo("or")).toBe(false);
  });
});
