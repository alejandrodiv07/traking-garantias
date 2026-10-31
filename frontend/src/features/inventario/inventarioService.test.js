// inventarioService: lectura del catálogo y administración (crear, corregir, desactivar).
import { beforeEach, describe, expect, it, vi } from "vitest";

const fakes = vi.hoisted(() => ({ from: vi.fn() }));
vi.mock("../../lib/supabaseClient.js", () => ({ supabase: { from: fakes.from } }));

import { actualizarProducto, cambiarActivo, crearProducto, listarCatalogo } from "./inventarioService.js";

/** Cadena de supabase-js: cada método devuelve la misma cadena y `await` entrega el resultado. */
const cadena = (resultado, registro = {}) =>
  new Proxy(
    {},
    {
      get: (_, metodo) => {
        if (metodo === "then") return (ok, ko) => Promise.resolve(resultado).then(ok, ko);
        return (...args) => {
          (registro[metodo] ??= []).push(args);
          return cadena(resultado, registro);
        };
      },
    },
  );

beforeEach(() => {
  fakes.from.mockReset();
});

describe("listarCatalogo", () => {
  it("lee productos con su marca y los ordena por marca y modelo", async () => {
    const reg = {};
    fakes.from.mockReturnValue(
      cadena(
        {
          data: [
            { id: "p2", marcas: { nombre: "TP-Link" }, modelo: "TL-SG108", categoria: "SWITCH", meses_garantia: 12, activo: true },
            { id: "p1", marcas: { nombre: "APC" }, modelo: "BX600L-LM", categoria: "UPS Y REGULADORES", meses_garantia: 12, activo: false },
          ],
          error: null,
        },
        reg,
      ),
    );
    const r = await listarCatalogo();
    expect(fakes.from).toHaveBeenCalledWith("productos");
    expect(reg.select[0][0]).toBe("id, marcas(nombre), modelo, categoria, meses_garantia, activo");
    expect(r.datos.map((p) => `${p.marca} ${p.modelo}`)).toEqual(["APC BX600L-LM", "TP-Link TL-SG108"]);
    expect(r.datos[0]).not.toHaveProperty("marcas");
  });

  it("devuelve el error de la base", async () => {
    fakes.from.mockReturnValue(cadena({ data: null, error: { code: "42501", message: "x" } }));
    expect(await listarCatalogo()).toMatchObject({ ok: false, codigo: "SIN_PERMISO" });
  });

  it("sin red devuelve SIN_CONEXION", async () => {
    fakes.from.mockImplementation(() => {
      throw new TypeError("Failed to fetch");
    });
    expect(await listarCatalogo()).toMatchObject({ ok: false, codigo: "SIN_CONEXION" });
  });
});

describe("crearProducto", () => {
  it("usa la marca existente y guarda el tipo en mayúsculas", async () => {
    const insProd = {};
    fakes.from.mockImplementation((tabla) =>
      tabla === "marcas" ? cadena({ data: { id: "m1" }, error: null }) : cadena({ error: null }, insProd),
    );
    const r = await crearProducto({ marca: " tp-link ", modelo: " TL-SG1000 ", categoria: "switch", meses: "24" });
    expect(r).toEqual({ ok: true, datos: null });
    expect(insProd.insert[0][0]).toEqual({ marca_id: "m1", modelo: "TL-SG1000", categoria: "SWITCH", meses_garantia: 24 });
  });

  it("si la marca no existe, la crea primero", async () => {
    const marcas = [];
    fakes.from.mockImplementation((tabla) => {
      if (tabla === "marcas") {
        const reg = {};
        marcas.push(reg);
        // 1.ª llamada: búsqueda sin resultado; 2.ª: alta con id
        return cadena({ data: marcas.length === 1 ? null : { id: "m9" }, error: null }, reg);
      }
      return cadena({ error: null });
    });
    const r = await crearProducto({ marca: "Nueva Marca", modelo: "X-1", categoria: "otros", meses: 12 });
    expect(r.ok).toBe(true);
    expect(marcas).toHaveLength(2);
    expect(marcas[1].insert[0][0]).toEqual({ nombre: "Nueva Marca" });
  });

  it("escapa % y _ al buscar la marca", async () => {
    const reg = {};
    fakes.from.mockImplementation((tabla) => (tabla === "marcas" ? cadena({ data: { id: "m1" }, error: null }, reg) : cadena({ error: null })));
    await crearProducto({ marca: "A_B%", modelo: "M", categoria: "x", meses: 1 });
    expect(reg.ilike[0]).toEqual(["nombre", "A\\_B\\%"]);
  });

  it("mapea el modelo repetido y los datos inválidos", async () => {
    const con = (code) =>
      fakes.from.mockImplementation((tabla) => (tabla === "marcas" ? cadena({ data: { id: "m1" }, error: null }) : cadena({ error: { code, message: "x" } })));
    con("23505");
    expect(await crearProducto({ marca: "A", modelo: "M", categoria: "x", meses: 1 })).toMatchObject({ codigo: "DUPLICADO", mensaje: /Ya existe ese modelo/ });
    con("23514");
    expect(await crearProducto({ marca: "A", modelo: "M", categoria: "x", meses: 999 })).toMatchObject({ codigo: "INVALIDO" });
  });
});

describe("actualizarProducto y cambiarActivo", () => {
  it("corrige tipo (mayúsculas) y garantía del modelo", async () => {
    const reg = {};
    fakes.from.mockReturnValue(cadena({ error: null }, reg));
    expect(await actualizarProducto("p1", { categoria: "router", meses: "24" })).toEqual({ ok: true, datos: null });
    expect(reg.update[0][0]).toEqual({ categoria: "ROUTER", meses_garantia: 24 });
    expect(reg.eq[0]).toEqual(["id", "p1"]);
  });

  it("desactiva y reactiva un modelo", async () => {
    const reg = {};
    fakes.from.mockReturnValue(cadena({ error: null }, reg));
    await cambiarActivo("p1", false);
    expect(reg.update[0][0]).toEqual({ activo: false });
    expect(reg.eq[0]).toEqual(["id", "p1"]);
  });

  it("sin permiso, lo dice claro", async () => {
    fakes.from.mockReturnValue(cadena({ error: { code: "42501", message: "x" } }));
    expect(await cambiarActivo("p1", false)).toMatchObject({ ok: false, codigo: "SIN_PERMISO" });
  });
});
