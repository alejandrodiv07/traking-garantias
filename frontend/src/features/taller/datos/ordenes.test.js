import { describe, expect, it, vi } from "vitest";
import { crearConsultaFalsa } from "../../../test/supabaseFake.js";

vi.mock("../../../lib/supabaseClient.js");
// eslint-disable-next-line import/order -- el mock debe registrarse antes de este import
import { supabase } from "../../../lib/supabaseClient.js";
import { consultarOrdenes, consultarKpis, consultarPorVencer, contarPorEstado, crearOrden } from "./ordenes.js";

const FILA_BASE = {
  id: "1",
  numero_orden: "ORD-2026-000001",
  cliente: "Ana Pérez",
  documento: "V-12345678",
  equipo: "Huawei Router X",
  numero_serie: "SER-0001",
  estado: "RECIBIDO",
  estado_nombre: "Recibido",
  cobertura: "EN_GARANTIA",
  prioridad: "NORMAL",
  fecha_ingreso: "2026-09-01",
  garantia_vence_el: "2027-09-01",
  sla_vence_el: "2026-09-06",
};

describe("consultarOrdenes", () => {
  it("normaliza una fila de v_ordenes_tablero a la forma que ya esperan TablaOrdenes/PanelVencimientos", async () => {
    supabase.from.mockReturnValue(crearConsultaFalsa({ data: [FILA_BASE], error: null, count: 1 }));

    const resultado = await consultarOrdenes({});

    expect(resultado.total).toBe(1);
    expect(resultado.ordenes[0]).toEqual({
      id: "1",
      numero: "ORD-2026-000001",
      cliente: "Ana Pérez",
      documento: "V-12345678",
      equipo: "Huawei Router X",
      serie: "SER-0001",
      estado: "RECIBIDO",
      estadoNombre: "Recibido",
      cobertura: "EN_GARANTIA",
      prioridad: "NORMAL",
      ingreso: "2026-09-01",
      venceEl: "2027-09-01",
      slaVenceEl: "2026-09-06",
    });
  });

  it("un taller sin órdenes es una lista vacía, no un error", async () => {
    supabase.from.mockReturnValue(crearConsultaFalsa({ data: [], error: null, count: 0 }));

    const resultado = await consultarOrdenes({});

    expect(resultado).toEqual({ ordenes: [], total: 0 });
  });

  it("relanza el error de PostgREST para que quien llame decida cómo mostrarlo", async () => {
    const errorPostgrest = { code: "42501", message: "no autorizado" };
    supabase.from.mockReturnValue(crearConsultaFalsa({ data: null, error: errorPostgrest, count: null }));

    await expect(consultarOrdenes({})).rejects.toEqual(errorPostgrest);
  });
});

describe("contarPorEstado", () => {
  it("consulta una vez por código, en orden, y arma el mapa de recuentos", async () => {
    supabase.from
      .mockReturnValueOnce(crearConsultaFalsa({ count: 10, error: null }))
      .mockReturnValueOnce(crearConsultaFalsa({ count: 3, error: null }))
      .mockReturnValueOnce(crearConsultaFalsa({ count: 0, error: null }));

    const recuentos = await contarPorEstado(["TODAS", "RECIBIDO", "ENTREGADO"]);

    expect(recuentos).toEqual({ TODAS: 10, RECIBIDO: 3, ENTREGADO: 0 });
    expect(supabase.from).toHaveBeenCalledTimes(3);
  });
});

describe("consultarKpis", () => {
  it("desenvuelve el array de una fila que devuelve la función SQL", async () => {
    supabase.rpc.mockResolvedValue({ data: [{ ordenes_abiertas: 5, tasa_a_tiempo: 94 }], error: null });

    const kpis = await consultarKpis();

    expect(kpis).toEqual({ ordenes_abiertas: 5, tasa_a_tiempo: 94 });
  });

  it("propaga el error si kpis_tablero() lo rechaza (p.ej. anon sin permiso)", async () => {
    supabase.rpc.mockResolvedValue({ data: null, error: { message: "permiso denegado" } });

    await expect(consultarKpis()).rejects.toEqual({ message: "permiso denegado" });
  });
});

describe("consultarPorVencer", () => {
  it("normaliza las filas de garantías próximas a vencer", async () => {
    supabase.from.mockReturnValue(
      crearConsultaFalsa({
        data: [{ id: "1", cliente: "Ana", numero_serie: "S1", equipo: "Router", garantia_vence_el: "2026-09-20" }],
        error: null,
      })
    );

    const resultado = await consultarPorVencer({ dias: 30 });

    expect(resultado).toEqual([{ id: "1", cliente: "Ana", serie: "S1", equipo: "Router", venceEl: "2026-09-20" }]);
  });

  it("ninguna garantía por vencer es una lista vacía", async () => {
    supabase.from.mockReturnValue(crearConsultaFalsa({ data: [], error: null }));

    const resultado = await consultarPorVencer({ dias: 30 });

    expect(resultado).toEqual([]);
  });
});

describe("crearOrden", () => {
  const datosOrden = {
    fechaCompra: "2026-01-01",
    fallaReportada: "no enciende",
    cliente: { id: "c1" },
    producto: { id: "p1" },
  };

  it("traduce 42501 al mensaje de 'tu rol no puede registrar órdenes'", async () => {
    supabase.rpc.mockResolvedValue({ data: null, error: { code: "42501" } });

    const resultado = await crearOrden(datosOrden);

    expect(resultado).toEqual({
      ok: false,
      error: { codigo: "42501", mensaje: "Tu rol no puede registrar órdenes." },
    });
  });

  it("traduce 22023 al mensaje de datos faltantes", async () => {
    supabase.rpc.mockResolvedValue({ data: null, error: { code: "22023" } });

    const resultado = await crearOrden(datosOrden);

    expect(resultado.error.mensaje).toBe("Faltan datos del cliente o del equipo.");
  });

  it("un código sin traducción conocida cae en el mensaje genérico", async () => {
    supabase.rpc.mockResolvedValue({ data: null, error: { code: "99999" } });

    const resultado = await crearOrden(datosOrden);

    expect(resultado.error.mensaje).toBe("No se pudo completar la operación. Intenta de nuevo.");
  });

  it("mapea la fila de éxito, incluido el token de un solo uso", async () => {
    supabase.rpc.mockResolvedValue({
      data: [
        {
          orden_id: "o1",
          numero_orden: "ORD-2026-000002",
          consulta_token: "tok-plano-123",
          cobertura: "EN_GARANTIA",
          vence_el: "2027-01-01",
          cliente_id: "c1",
          producto_id: "p1",
        },
      ],
      error: null,
    });

    const resultado = await crearOrden(datosOrden);

    expect(resultado).toEqual({
      ok: true,
      datos: {
        ordenId: "o1",
        numeroOrden: "ORD-2026-000002",
        consultaToken: "tok-plano-123",
        cobertura: "EN_GARANTIA",
        venceEl: "2027-01-01",
        clienteId: "c1",
        productoId: "p1",
      },
    });
  });

  it("envía cliente_nuevo y producto_nuevo (no los ids) cuando se registra un cliente/producto nuevo", async () => {
    supabase.rpc.mockResolvedValue({ data: [{ orden_id: "o1", numero_orden: "X", consulta_token: "t" }], error: null });

    await crearOrden({
      ...datosOrden,
      cliente: { nuevo: { tipo_documento: "V", documento: "1", nombre: "Nueva" } },
      producto: { nuevo: { marca_id: "m1", modelo: "X", categoria: "Y" } },
    });

    expect(supabase.rpc).toHaveBeenCalledWith(
      "crear_orden",
      expect.objectContaining({
        p_cliente_id: null,
        p_cliente_nuevo: { tipo_documento: "V", documento: "1", nombre: "Nueva" },
        p_producto_id: null,
        p_producto_nuevo: { marca_id: "m1", modelo: "X", categoria: "Y" },
      })
    );
  });
});
