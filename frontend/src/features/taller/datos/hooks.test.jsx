import { renderHook, waitFor } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { crearConsultaFalsa } from "../../../test/supabaseFake.js";

vi.mock("../../../lib/supabaseClient.js");
import { supabase } from "../../../lib/supabaseClient.js";
import { useKpis, useOrdenes } from "./hooks.js";

describe("useOrdenes", () => {
  it("empieza cargando y termina con las órdenes normalizadas (estado: carga)", async () => {
    supabase.from.mockReturnValue(
      crearConsultaFalsa({
        data: [{ id: "1", numero_orden: "ORD-2026-000001", cliente: "Ana", estado: "RECIBIDO" }],
        error: null,
        count: 1,
      })
    );

    const { result } = renderHook(() => useOrdenes({}));

    expect(result.current.cargando).toBe(true);

    await waitFor(() => expect(result.current.cargando).toBe(false));

    expect(result.current.total).toBe(1);
    expect(result.current.ordenes[0].numero).toBe("ORD-2026-000001");
    expect(result.current.error).toBeNull();
  });

  it("un taller vacío termina con la lista vacía, no en estado de error (estado: vacío)", async () => {
    supabase.from.mockReturnValue(crearConsultaFalsa({ data: [], error: null, count: 0 }));

    const { result } = renderHook(() => useOrdenes({}));

    await waitFor(() => expect(result.current.cargando).toBe(false));

    expect(result.current.ordenes).toEqual([]);
    expect(result.current.total).toBe(0);
    expect(result.current.error).toBeNull();
  });

  it("un fallo de la consulta deja `error` poblado y no revienta el hook (estado: error)", async () => {
    supabase.from.mockReturnValue(crearConsultaFalsa({ data: null, error: { message: "caído" }, count: null }));

    const { result } = renderHook(() => useOrdenes({}));

    await waitFor(() => expect(result.current.cargando).toBe(false));

    expect(result.current.error).toEqual({ message: "caído" });
    expect(result.current.ordenes).toEqual([]);
  });
});

describe("useKpis", () => {
  it("carga y expone el resultado crudo de kpis_tablero()", async () => {
    supabase.rpc.mockResolvedValue({ data: [{ ordenes_abiertas: 7 }], error: null });

    const { result } = renderHook(() => useKpis());

    expect(result.current.cargando).toBe(true);
    await waitFor(() => expect(result.current.cargando).toBe(false));

    expect(result.current.kpis).toEqual({ ordenes_abiertas: 7 });
  });
});
