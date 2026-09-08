/**
 * Los números de las píldoras y la tabla responden a la MISMA pregunta.
 *
 * Antes no: `useOrdenes` recibía el término del buscador y
 * `useRecuentosPorEstado` no, así que al buscar "ana" la tabla mostraba 2
 * filas y la píldora de al lado seguía diciendo 40. El operador no tiene
 * forma de saber cuál de los dos números es el bueno.
 */
import { renderHook, waitFor } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { crearConsultaFalsa } from "../../../test/supabaseFake.js";

vi.mock("../../../lib/supabaseClient.js");
// eslint-disable-next-line import/order -- el mock debe registrarse antes de este import
import { supabase } from "../../../lib/supabaseClient.js";
import { useRecuentosPorEstado } from "./hooks.js";

describe("useRecuentosPorEstado", () => {
  it("cuenta por código y arma el mapa que pintan las píldoras", async () => {
    supabase.from.mockReturnValue(crearConsultaFalsa({ count: 4, error: null }));

    const { result } = renderHook(() => useRecuentosPorEstado(["TODAS", "RECIBIDO"]));

    await waitFor(() => expect(result.current.cargando).toBe(false));

    expect(result.current.recuentos).toEqual({ TODAS: 4, RECIBIDO: 4 });
  });

  it("pasa el término del buscador al recuento: píldora y tabla cuentan lo mismo", async () => {
    const consulta = crearConsultaFalsa({ count: 2, error: null });
    supabase.from.mockReturnValue(consulta);

    const { result } = renderHook(() =>
      useRecuentosPorEstado(["RECIBIDO"], { termino: "ana" })
    );

    await waitFor(() => expect(result.current.cargando).toBe(false));

    expect(consulta.argumentosDe("or")[0]).toContain("cliente.ilike.%ana%");
  });

  it("cambiar el término vuelve a contar: los números no se quedan pegados a la búsqueda anterior", async () => {
    supabase.from.mockReturnValue(crearConsultaFalsa({ count: 1, error: null }));

    const { result, rerender } = renderHook(
      ({ termino }) => useRecuentosPorEstado(["RECIBIDO"], { termino }),
      { initialProps: { termino: "ana" } }
    );

    await waitFor(() => expect(result.current.cargando).toBe(false));
    const llamadasIniciales = supabase.from.mock.calls.length;

    rerender({ termino: "luis" });

    await waitFor(() =>
      expect(supabase.from.mock.calls.length).toBeGreaterThan(llamadasIniciales)
    );
  });
});
