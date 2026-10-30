// tallerService: contrato de abrir_orden por equipo (0019) y lectura del equipo
// (Tarea 15 del plan). Supabase y subirAdjunto se simulan en el borde.
import { beforeEach, describe, expect, it, vi } from "vitest";

const fakes = vi.hoisted(() => ({
  rpc: vi.fn(),
  subirAdjunto: vi.fn(),
  single: vi.fn(),
  eq: vi.fn(),
  select: vi.fn(),
  from: vi.fn(),
  getUser: vi.fn(),
}));

vi.mock("../../lib/supabaseClient.js", () => ({
  supabase: { rpc: fakes.rpc, from: fakes.from, auth: { getUser: fakes.getUser } },
}));
vi.mock("../registro/registroService.js", async () => {
  const real = await vi.importActual("../registro/registroService.js");
  return { ...real, subirAdjunto: fakes.subirAdjunto };
});

import {
  abrirOrden,
  actualizarDiagnostico,
  adjuntosOrden,
  agregarNota,
  asignarTecnico,
  cambiarEstado,
  historialOrden,
  leerEquipo,
  listarTecnicos,
  notasOrden,
  obtenerOrden,
  registrarPresupuesto,
  subirAdjuntos,
} from "./tallerService.js";

beforeEach(() => {
  for (const f of Object.values(fakes)) f.mockReset();
  fakes.from.mockReturnValue({ select: fakes.select });
  fakes.select.mockReturnValue({ eq: fakes.eq });
  fakes.eq.mockReturnValue({ maybeSingle: fakes.single });
});

describe("abrirOrden", () => {
  it("manda la firma exacta de la 0019 (sin fecha de ingreso) y devuelve la fila", async () => {
    fakes.rpc.mockResolvedValue({
      data: [{ orden_id: "o1", numero_orden: "OS-2026-0001", consulta_token: "t", cobertura: "EN_GARANTIA", tipo_atencion: "GARANTIA" }],
      error: null,
    });
    const r = await abrirOrden({
      equipoId: "e1",
      falla: "no enciende",
      accesorios: "cargador",
      checklist: { equipo: { golpes: true } },
      observaciones: "rayado",
      claveEnvio: "k1",
    });
    expect(fakes.rpc).toHaveBeenCalledWith("abrir_orden", {
      p_equipo_id: "e1",
      p_falla: "no enciende",
      p_accesorios: "cargador",
      p_checklist: { equipo: { golpes: true } },
      p_observaciones: "rayado",
      p_clave_envio: "k1",
    });
    expect(r).toEqual({ ok: true, datos: expect.objectContaining({ orden_id: "o1" }) });
  });

  it("manda null en lo opcional", async () => {
    fakes.rpc.mockResolvedValue({ data: [{ orden_id: "o1" }], error: null });
    await abrirOrden({ equipoId: "e1", falla: "no enciende", claveEnvio: "k1" });
    expect(fakes.rpc.mock.calls[0][1]).toMatchObject({
      p_accesorios: null,
      p_checklist: null,
      p_observaciones: null,
    });
  });

  it("42501 es SIN_PERMISO y un fallo de red SIN_CONEXION", async () => {
    fakes.rpc.mockResolvedValueOnce({ data: null, error: { code: "42501", message: "no" } });
    expect((await abrirOrden({ equipoId: "e1", falla: "xxxxx", claveEnvio: "k" })).codigo).toBe("SIN_PERMISO");
    fakes.rpc.mockRejectedValueOnce(new TypeError("Failed to fetch"));
    expect((await abrirOrden({ equipoId: "e1", falla: "xxxxx", claveEnvio: "k" })).codigo).toBe("SIN_CONEXION");
  });
});

describe("leerEquipo", () => {
  it("lee el equipo por id desde v_garantias", async () => {
    fakes.single.mockResolvedValue({ data: { equipo_id: "e1", numero_serie: "RT5" }, error: null });
    const r = await leerEquipo("e1");
    expect(fakes.from).toHaveBeenCalledWith("v_garantias");
    expect(fakes.eq).toHaveBeenCalledWith("equipo_id", "e1");
    expect(r).toEqual({ ok: true, datos: { equipo_id: "e1", numero_serie: "RT5" } });
  });

  it("equipo inexistente es NO_ENCONTRADO", async () => {
    fakes.single.mockResolvedValue({ data: null, error: null });
    expect((await leerEquipo("zz")).codigo).toBe("NO_ENCONTRADO");
  });
});

describe("subirAdjuntos", () => {
  it("sube todos y devuelve como pendientes solo los que fallaron", async () => {
    const a = { archivo: { name: "a.jpg" }, tipo: "FOTO", etiqueta: null };
    const b = { archivo: { name: "b.pdf" }, tipo: "DOCUMENTO", etiqueta: null };
    fakes.subirAdjunto.mockResolvedValueOnce({ ok: true }).mockResolvedValueOnce({ ok: false });
    expect(await subirAdjuntos("o1", [a, b])).toEqual([b]);
    expect(fakes.subirAdjunto).toHaveBeenCalledWith("o1", a.archivo, { tipo: "FOTO", etiqueta: null });
  });
});

// Constructor falso de supabase-js: cada tabla responde lo que se le diga y
// registra el encadenado (select / insert / update / eq / order) para
// comprobar la consulta.
function tablasFalsas(respuestas) {
  const llamadas = {};
  fakes.from.mockImplementation((tabla) => {
    const registro = (llamadas[tabla] = []);
    const b = {
      select: (...a) => (registro.push(["select", ...a]), b),
      insert: (...a) => (registro.push(["insert", ...a]), b),
      update: (...a) => (registro.push(["update", ...a]), b),
      eq: (...a) => (registro.push(["eq", ...a]), b),
      order: (...a) => (registro.push(["order", ...a]), b),
      maybeSingle: () => Promise.resolve(respuestas[tabla]),
      then: (res, rej) => Promise.resolve(respuestas[tabla]).then(res, rej),
    };
    return b;
  });
  return llamadas;
}

describe("lecturas del detalle de la orden", () => {
  it("obtenerOrden junta la fila del tablero, las columnas de la orden y el nombre del técnico", async () => {
    const llamadas = tablasFalsas({
      v_tablero: { data: { orden_id: "o1", numero_orden: "OS-1", serial: "RT5", estado: "RECIBIDO" }, error: null },
      ordenes_servicio: {
        data: { id: "o1", tipo_atencion: "GARANTIA", falla_reportada: "no enciende", tecnico_asignado_id: "t1" },
        error: null,
      },
      profiles: { data: { full_name: "Tomás Técnico" }, error: null },
    });
    const r = await obtenerOrden("o1");
    expect(llamadas.v_tablero).toContainEqual(["eq", "orden_id", "o1"]);
    expect(llamadas.ordenes_servicio).toContainEqual(["eq", "id", "o1"]);
    expect(llamadas.profiles).toContainEqual(["eq", "id", "t1"]);
    expect(r.ok).toBe(true);
    expect(r.datos).toMatchObject({
      numero_orden: "OS-1",
      serial: "RT5",
      tipo_atencion: "GARANTIA",
      falla_reportada: "no enciende",
      tecnico: "Tomás Técnico",
    });
  });

  it("sin técnico asignado no consulta profiles", async () => {
    const llamadas = tablasFalsas({
      v_tablero: { data: { orden_id: "o1" }, error: null },
      ordenes_servicio: { data: { id: "o1", tecnico_asignado_id: null }, error: null },
    });
    const r = await obtenerOrden("o1");
    expect(llamadas.profiles).toBeUndefined();
    expect(r.datos.tecnico).toBeNull();
  });

  it("una orden que no se ve es NO_ENCONTRADO", async () => {
    tablasFalsas({
      v_tablero: { data: null, error: null },
      ordenes_servicio: { data: null, error: null },
    });
    expect((await obtenerOrden("zz")).codigo).toBe("NO_ENCONTRADO");
  });

  it("historialOrden pide la bitácora de la orden, la más reciente primero", async () => {
    const llamadas = tablasFalsas({ historial_ordenes: { data: [{ id: 1 }], error: null } });
    const r = await historialOrden("o1");
    expect(llamadas.historial_ordenes).toContainEqual(["eq", "orden_id", "o1"]);
    expect(llamadas.historial_ordenes).toContainEqual(["order", "creado_en", { ascending: false }]);
    expect(r).toEqual({ ok: true, datos: [{ id: 1 }] });
  });

  it("notasOrden trae el autor por su nombre", async () => {
    const llamadas = tablasFalsas({ notas_internas: { data: [{ id: "n1" }], error: null } });
    await notasOrden("o1");
    expect(llamadas.notas_internas[0][1]).toMatch(/autor:autor_id\(full_name\)/);
    expect(llamadas.notas_internas).toContainEqual(["eq", "orden_id", "o1"]);
  });

  it("adjuntosOrden lee los adjuntos de la orden y mapea 42501", async () => {
    const llamadas = tablasFalsas({ adjuntos: { data: null, error: { code: "42501", message: "no" } } });
    const r = await adjuntosOrden("o1");
    expect(llamadas.adjuntos).toContainEqual(["eq", "orden_id", "o1"]);
    expect(r).toMatchObject({ ok: false, codigo: "SIN_PERMISO" });
  });
});

// Escrituras (Tarea 16, segunda mitad): la 0021 es la ÚNICA puerta para el
// estado, el técnico y el presupuesto. El servicio manda la firma exacta.
describe("cambiarEstado", () => {
  it("manda la firma exacta de la 0021 y devuelve la fila del estado", async () => {
    fakes.rpc.mockResolvedValue({
      data: [{ orden_id: "o1", estado: "EN_REPARACION", tipo_atencion: "GARANTIA" }],
      error: null,
    });
    const r = await cambiarEstado("o1", { estado: "EN_REPARACION", comentario: "Repuesto puesto" });
    expect(fakes.rpc).toHaveBeenCalledWith("cambiar_estado", {
      p_orden_id: "o1",
      p_estado: "EN_REPARACION",
      p_comentario: "Repuesto puesto",
      p_motivo: null,
    });
    expect(r).toEqual({ ok: true, datos: { orden_id: "o1", estado: "EN_REPARACION", tipo_atencion: "GARANTIA" } });
  });

  it("el motivo del rechazo viaja en p_motivo", async () => {
    fakes.rpc.mockResolvedValue({ data: [{ orden_id: "o1", estado: "RECHAZADO" }], error: null });
    await cambiarEstado("o1", { estado: "RECHAZADO", motivo: "Equipo con humedad evidente" });
    expect(fakes.rpc.mock.calls[0][1]).toMatchObject({
      p_estado: "RECHAZADO",
      p_motivo: "Equipo con humedad evidente",
      p_comentario: null,
    });
  });

  it("un rechazo de la base por permiso llega como SIN_PERMISO y una caída de red como SIN_CONEXION", async () => {
    fakes.rpc.mockResolvedValueOnce({ data: null, error: { code: "42501", message: "no permitido" } });
    expect((await cambiarEstado("o1", { estado: "ANULADO" })).codigo).toBe("SIN_PERMISO");
    fakes.rpc.mockRejectedValueOnce(new TypeError("Failed to fetch"));
    expect((await cambiarEstado("o1", { estado: "ANULADO" })).codigo).toBe("SIN_CONEXION");
  });
});

describe("asignarTecnico", () => {
  it("manda p_orden_id y p_tecnico_id (y null para desasignar)", async () => {
    fakes.rpc.mockResolvedValue({ data: null, error: null });
    const r = await asignarTecnico("o1", "t1");
    expect(fakes.rpc).toHaveBeenCalledWith("asignar_tecnico", { p_orden_id: "o1", p_tecnico_id: "t1" });
    expect(r.ok).toBe(true);
    await asignarTecnico("o1", null);
    expect(fakes.rpc.mock.calls[1][1]).toMatchObject({ p_tecnico_id: null });
  });
});

describe("registrarPresupuesto", () => {
  it("manda p_orden_id y p_monto", async () => {
    fakes.rpc.mockResolvedValue({ data: [{ tipo_atencion: "PAGO" }], error: null });
    const r = await registrarPresupuesto("o1", 45);
    expect(fakes.rpc).toHaveBeenCalledWith("registrar_presupuesto", { p_orden_id: "o1", p_monto: 45 });
    expect(r.ok).toBe(true);
  });
});

describe("listarTecnicos", () => {
  it("lee de profiles los técnicos activos con su nombre", async () => {
    const llamadas = tablasFalsas({
      profiles: { data: [{ id: "t1", full_name: "Tomás Técnico" }], error: null },
    });
    const r = await listarTecnicos();
    expect(llamadas.profiles).toContainEqual(["eq", "role", "TECNICO"]);
    expect(llamadas.profiles).toContainEqual(["eq", "is_active", true]);
    expect(llamadas.profiles).toContainEqual(["select", "id, full_name"]);
    expect(r).toEqual({ ok: true, datos: [{ id: "t1", full_name: "Tomás Técnico" }] });
  });
});

// Piezas de las pestañas de la Tarea 16 (segunda ronda): el diagnóstico va por
// UPDATE directo de la columna que sigue abierta (la 0021 no lo cierra) y las
// notas internas por INSERT con el autor de la sesión (RLS: autor_id = auth.uid()).
describe("agregarNota", () => {
  it("inserta la nota con el autor de la sesión", async () => {
    const llamadas = tablasFalsas({ notas_internas: { data: null, error: null } });
    fakes.getUser.mockResolvedValue({ data: { user: { id: "u7" } }, error: null });
    const r = await agregarNota("o1", "Llamar al cliente");
    expect(llamadas.notas_internas).toContainEqual([
      "insert",
      { orden_id: "o1", autor_id: "u7", nota: "Llamar al cliente" },
    ]);
    expect(r).toEqual({ ok: true, datos: null });
  });

  it("sin sesión no toca la tabla", async () => {
    const llamadas = tablasFalsas({});
    fakes.getUser.mockResolvedValue({ data: { user: null }, error: null });
    const r = await agregarNota("o1", "Llamar al cliente");
    expect(r.ok).toBe(false);
    expect(llamadas.notas_internas).toBeUndefined();
  });

  it("una nota sin texto no se envía", async () => {
    const llamadas = tablasFalsas({});
    const r = await agregarNota("o1", "   ");
    expect(r.ok).toBe(false);
    expect(llamadas.notas_internas).toBeUndefined();
  });

  it("el rechazo de la base (42501) llega como SIN_PERMISO", async () => {
    tablasFalsas({ notas_internas: { data: null, error: { code: "42501", message: "no" } } });
    fakes.getUser.mockResolvedValue({ data: { user: { id: "u7" } }, error: null });
    const r = await agregarNota("o1", "Llamar al cliente");
    expect(r).toMatchObject({ ok: false, codigo: "SIN_PERMISO" });
  });
});

describe("actualizarDiagnostico", () => {
  it("actualiza la columna abierta `diagnostico` por id (fuera de la 0021)", async () => {
    const llamadas = tablasFalsas({ ordenes_servicio: { data: null, error: null } });
    const r = await actualizarDiagnostico("o1", "Fuente quemada");
    expect(llamadas.ordenes_servicio).toContainEqual(["update", { diagnostico: "Fuente quemada" }]);
    expect(llamadas.ordenes_servicio).toContainEqual(["eq", "id", "o1"]);
    expect(r).toEqual({ ok: true, datos: null });
  });

  it("un texto vacío borra el diagnóstico (columna nullable)", async () => {
    const llamadas = tablasFalsas({ ordenes_servicio: { data: null, error: null } });
    await actualizarDiagnostico("o1", "");
    expect(llamadas.ordenes_servicio).toContainEqual(["update", { diagnostico: null }]);
  });

  it("un rechazo de la base por RLS se mapea SIN_PERMISO", async () => {
    tablasFalsas({ ordenes_servicio: { data: null, error: { code: "42501", message: "no permitido" } } });
    const r = await actualizarDiagnostico("o1", "Fuente quemada");
    expect(r).toMatchObject({ ok: false, codigo: "SIN_PERMISO" });
  });
});
