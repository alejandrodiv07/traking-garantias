import { describe, expect, it, vi } from "vitest";
import { crearConsultaFalsa } from "../../../test/supabaseFake.js";

vi.mock("../../../lib/supabaseClient.js");
import { supabase } from "../../../lib/supabaseClient.js";
import { buscarClientes, buscarProductos, listarEstados } from "./catalogos.js";

describe("listarEstados", () => {
  it("devuelve los estados tal como los ordena la base", async () => {
    supabase.from.mockReturnValue(
      crearConsultaFalsa({
        data: [{ codigo: "RECIBIDO", nombre: "Recibido", orden: 10, es_final: false }],
        error: null,
      })
    );

    const estados = await listarEstados();

    expect(estados).toEqual([{ codigo: "RECIBIDO", nombre: "Recibido", orden: 10, es_final: false }]);
  });

  it("un catálogo vacío es una lista vacía, no un error", async () => {
    supabase.from.mockReturnValue(crearConsultaFalsa({ data: null, error: null }));

    expect(await listarEstados()).toEqual([]);
  });
});

describe("buscarClientes", () => {
  it("no consulta la base con menos de 2 caracteres (§7.2)", async () => {
    const resultado = await buscarClientes("a");

    expect(resultado).toEqual([]);
    expect(supabase.from).not.toHaveBeenCalled();
  });

  it("busca por nombre o documento a partir de 2 caracteres", async () => {
    supabase.from.mockReturnValue(
      crearConsultaFalsa({ data: [{ id: "c1", tipo_documento: "V", documento: "123", nombre: "Ana" }], error: null })
    );

    const resultado = await buscarClientes("an");

    expect(resultado).toEqual([{ id: "c1", tipo_documento: "V", documento: "123", nombre: "Ana" }]);
  });
});

describe("buscarProductos", () => {
  it("aplana la marca embebida como dato desambiguador", async () => {
    supabase.from.mockReturnValue(
      crearConsultaFalsa({
        data: [
          {
            id: "p1",
            modelo: "EA2-RT500",
            categoria: "Conectividad industrial",
            meses_garantia: 12,
            marca_id: "m1",
            marcas: { nombre: "Huawei" },
          },
        ],
        error: null,
      })
    );

    const resultado = await buscarProductos("rt5");

    expect(resultado).toEqual([
      { id: "p1", modelo: "EA2-RT500", categoria: "Conectividad industrial", mesesGarantia: 12, marcaId: "m1", marca: "Huawei" },
    ]);
  });

  it("no consulta la base con menos de 2 caracteres", async () => {
    const resultado = await buscarProductos("r");

    expect(resultado).toEqual([]);
    expect(supabase.from).not.toHaveBeenCalled();
  });
});
