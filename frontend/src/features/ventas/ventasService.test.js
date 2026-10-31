// ventasService: importar_ventas en bloques de 5000 (límite de la RPC).
import { beforeEach, describe, expect, it, vi } from "vitest";

const rpcFalso = vi.hoisted(() => vi.fn());
vi.mock("../../lib/supabaseClient.js", () => ({ supabase: { rpc: rpcFalso } }));

import { importarVentas, TAMANO_BLOQUE } from "./ventasService.js";

const resumen = (extras = {}) => ({
  data: [{ lote_id: "l1", nuevas: 0, actualizadas: 0, con_error: 0, confirmadas: 0, errores: [], ...extras }],
  error: null,
});
const filas = (n) => Array.from({ length: n }, (_, i) => ({ serial: `S-${i}` }));

beforeEach(() => rpcFalso.mockReset());

describe("importarVentas", () => {
  it("manda el archivo y las filas, y devuelve el resumen", async () => {
    rpcFalso.mockResolvedValue(resumen({ nuevas: 2, confirmadas: 1 }));
    const r = await importarVentas("ventas.csv", filas(2));
    expect(rpcFalso).toHaveBeenCalledWith("importar_ventas", { p_archivo: "ventas.csv", p_filas: filas(2) });
    expect(r).toMatchObject({ ok: true, datos: { nuevas: 2, actualizadas: 0, con_error: 0, confirmadas: 1, errores: [] } });
  });

  it("parte en bloques de 5000, suma los resúmenes y numera los errores sobre el total", async () => {
    expect(TAMANO_BLOQUE).toBe(5000);
    rpcFalso
      .mockResolvedValueOnce(resumen({ nuevas: 4999, con_error: 1, errores: [{ fila: 3, campo: "serial", mensaje: "x" }] }))
      .mockResolvedValueOnce(resumen({ nuevas: 4, actualizadas: 1, confirmadas: 2, errores: [{ fila: 2, campo: "serial", mensaje: "y" }] }));
    const r = await importarVentas("g.csv", filas(5005));
    expect(rpcFalso).toHaveBeenCalledTimes(2);
    expect(rpcFalso.mock.calls[1][1].p_filas).toHaveLength(5);
    expect(r.datos).toMatchObject({ nuevas: 5003, actualizadas: 1, con_error: 1, confirmadas: 2 });
    expect(r.datos.errores.map((e) => e.fila)).toEqual([3, 5002]);
  });

  it("si un bloque falla, devuelve el error y lo ya guardado", async () => {
    rpcFalso
      .mockResolvedValueOnce(resumen({ nuevas: 5000 }))
      .mockResolvedValueOnce({ data: null, error: { code: "42501", message: "Solo ADMIN" } });
    const r = await importarVentas("g.csv", filas(5001));
    expect(r).toMatchObject({ ok: false, codigo: "SIN_PERMISO", guardadas: 5000 });
  });
});
