// Inventario (maqueta 06): catálogo de productos con filtros; Jefatura agrega, corrige y desactiva.
import { render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter } from "react-router-dom";
import { beforeEach, describe, expect, it, vi } from "vitest";

const fakes = vi.hoisted(() => ({
  listarCatalogo: vi.fn(),
  crearProducto: vi.fn(),
  actualizarProducto: vi.fn(),
  cambiarActivo: vi.fn(),
  rol: "JEFE_SERVICIO",
}));
vi.mock("./inventarioService.js", () => fakes);
vi.mock("../auth/AuthContext.jsx", () => ({ useAuth: () => ({ rol: fakes.rol }) }));

import Inventario from "./Inventario.jsx";

const P = (id, marca, modelo, categoria, extras = {}) => ({ id, marca, modelo, categoria, meses_garantia: 12, activo: true, ...extras });
const CATALOGO = [
  // En el orden que entrega el servicio: por marca y modelo.
  P("1", "APC", "BX600L-LM", "UPS Y REGULADORES"),
  P("4", "Epson", "T544120", "TINTA Y TONER", { activo: false }),
  P("3", "TP-Link", "Archer C6", "ROUTER", { meses_garantia: 24 }),
  P("2", "TP-Link", "TL-SG108", "SWITCH"),
];

const montar = () =>
  render(
    <MemoryRouter>
      <Inventario />
    </MemoryRouter>,
  );
const modelos = () => screen.getAllByRole("row").slice(1).map((r) => within(r).getAllByRole("cell")[1].textContent);
const campo = (etiqueta, id) => screen.getByLabelText(etiqueta, { selector: `#${id}` });

beforeEach(() => {
  fakes.rol = "JEFE_SERVICIO";
  fakes.listarCatalogo.mockReset().mockResolvedValue({ ok: true, datos: CATALOGO });
  fakes.crearProducto.mockReset().mockResolvedValue({ ok: true, datos: null });
  fakes.actualizarProducto.mockReset().mockResolvedValue({ ok: true, datos: null });
  fakes.cambiarActivo.mockReset().mockResolvedValue({ ok: true, datos: null });
});

describe("Inventario: catálogo", () => {
  it("muestra por defecto los modelos activos con su marca, tipo y garantía", async () => {
    montar();
    expect(await screen.findByText("BX600L-LM")).toBeInTheDocument();
    expect(modelos()).toEqual(["BX600L-LM", "Archer C6", "TL-SG108"]);
    const fila = screen.getByText("Archer C6").closest("tr");
    expect(fila).toHaveTextContent("TP-Link");
    expect(fila).toHaveTextContent("ROUTER");
    expect(fila).toHaveTextContent("24 meses");
    expect(screen.queryByText("T544120")).toBeNull();
  });

  it("los indicadores cuentan modelos, marcas, tipos y desactivados", async () => {
    montar();
    await screen.findByText("BX600L-LM");
    const kpi = (n) => screen.getByRole("heading", { name: n }).closest("li");
    expect(kpi("Modelos activos")).toHaveTextContent("3");
    expect(kpi("Marcas")).toHaveTextContent("3");
    expect(kpi("Tipos de equipo")).toHaveTextContent("4");
    expect(kpi("Desactivados")).toHaveTextContent("1");
  });

  it("filtra por marca, por tipo y por texto", async () => {
    const u = userEvent.setup();
    montar();
    await screen.findByText("BX600L-LM");
    await u.selectOptions(screen.getByLabelText("Marca", { selector: "#inv-f-marca" }), "TP-Link");
    expect(modelos()).toEqual(["Archer C6", "TL-SG108"]);
    await u.selectOptions(screen.getByLabelText("Tipo de equipo", { selector: "#inv-f-tipo" }), "SWITCH");
    expect(modelos()).toEqual(["TL-SG108"]);
    await u.selectOptions(screen.getByLabelText("Marca", { selector: "#inv-f-marca" }), "");
    await u.selectOptions(screen.getByLabelText("Tipo de equipo", { selector: "#inv-f-tipo" }), "");
    await u.type(screen.getByRole("searchbox"), "tl sg");
    expect(modelos()).toEqual(["TL-SG108"]);
    await u.click(screen.getByRole("button", { name: "Borrar la búsqueda" }));
    expect(modelos()).toHaveLength(3);
  });

  it("el chip Desactivados muestra solo los que no se ofrecen", async () => {
    const u = userEvent.setup();
    montar();
    await screen.findByText("BX600L-LM");
    await u.click(screen.getByRole("button", { name: /^Desactivados/ }));
    expect(modelos()).toEqual(["T544120"]);
    expect(screen.getByText("Desactivado")).toBeInTheDocument();
    await u.click(screen.getByRole("button", { name: /^Todos/ }));
    expect(modelos()).toHaveLength(4);
  });

  it("con un catálogo grande muestra de 100 en 100", async () => {
    fakes.listarCatalogo.mockResolvedValue({
      ok: true,
      datos: Array.from({ length: 250 }, (_, i) => P(String(i), "APC", `M-${String(i).padStart(3, "0")}`, "UPS Y REGULADORES")),
    });
    const u = userEvent.setup();
    montar();
    await screen.findByText("M-000");
    expect(modelos()).toHaveLength(100);
    expect(screen.getByText("Mostrando 100 de 250 modelos")).toBeInTheDocument();
    await u.click(screen.getByRole("button", { name: "Mostrar 100 más" }));
    expect(modelos()).toHaveLength(200);
  });

  it("sin coincidencias lo dice", async () => {
    const u = userEvent.setup();
    montar();
    await screen.findByText("BX600L-LM");
    await u.type(screen.getByRole("searchbox"), "inexistente");
    expect(screen.getByText("No hay modelos con esos criterios")).toBeInTheDocument();
  });

  it("muestra el error de la base", async () => {
    fakes.listarCatalogo.mockResolvedValue({ ok: false, codigo: "SIN_PERMISO", mensaje: "permission denied" });
    montar();
    expect(await screen.findByRole("alert")).toHaveTextContent("permission denied");
  });
});

describe("Inventario: administración (solo jefatura)", () => {
  it.each(["TECNICO", "RECEPCION"])("%s solo consulta: sin alta ni acciones", async (rol) => {
    fakes.rol = rol;
    montar();
    await screen.findByText("BX600L-LM");
    expect(screen.queryByRole("button", { name: /Nuevo producto/ })).toBeNull();
    expect(screen.queryByRole("button", { name: /Editar/ })).toBeNull();
    expect(screen.queryByRole("button", { name: /Desactivar/ })).toBeNull();
    expect(screen.getByText(/lo hace Jefatura o Administración/)).toBeInTheDocument();
  });

  it("agrega un producto con marca, modelo, tipo y garantía, y recarga", async () => {
    const u = userEvent.setup();
    montar();
    await screen.findByText("BX600L-LM");
    await u.click(screen.getByRole("button", { name: /Nuevo producto/ }));
    const enviar = screen.getByRole("button", { name: "Agregar producto" });
    expect(enviar).toBeDisabled();
    await u.type(campo("Marca", "inv-marca"), "Hikvision");
    await u.type(campo("Modelo", "inv-modelo"), "DS-7108");
    await u.type(campo("Tipo de equipo", "inv-tipo"), "camara de seguridad");
    await u.clear(campo(/Garantía del fabricante/, "inv-meses"));
    await u.type(campo(/Garantía del fabricante/, "inv-meses"), "24");
    await u.click(enviar);
    await waitFor(() =>
      expect(fakes.crearProducto).toHaveBeenCalledWith({ marca: "Hikvision", modelo: "DS-7108", categoria: "camara de seguridad", meses: "24" }),
    );
    expect(await screen.findByText(/Hikvision DS-7108 agregado al catálogo/)).toBeInTheDocument();
    expect(fakes.listarCatalogo).toHaveBeenCalledTimes(2);
    expect(screen.queryByRole("form", { name: "Nuevo producto" })).toBeNull();
  });

  it("no deja guardar una garantía fuera de 0 a 120 meses", async () => {
    const u = userEvent.setup();
    montar();
    await screen.findByText("BX600L-LM");
    await u.click(screen.getByRole("button", { name: /Nuevo producto/ }));
    await u.type(campo("Marca", "inv-marca"), "APC");
    await u.type(campo("Modelo", "inv-modelo"), "X1");
    await u.type(campo("Tipo de equipo", "inv-tipo"), "UPS");
    await u.clear(campo(/Garantía del fabricante/, "inv-meses"));
    await u.type(campo(/Garantía del fabricante/, "inv-meses"), "121");
    expect(screen.getByRole("button", { name: "Agregar producto" })).toBeDisabled();
  });

  it("muestra el modelo repetido que rechaza la base y deja el formulario abierto", async () => {
    fakes.crearProducto.mockResolvedValue({ ok: false, codigo: "DUPLICADO", mensaje: "Ya existe ese modelo para esa marca" });
    const u = userEvent.setup();
    montar();
    await screen.findByText("BX600L-LM");
    await u.click(screen.getByRole("button", { name: /Nuevo producto/ }));
    await u.type(campo("Marca", "inv-marca"), "APC");
    await u.type(campo("Modelo", "inv-modelo"), "BX600L-LM");
    await u.type(campo("Tipo de equipo", "inv-tipo"), "UPS");
    await u.click(screen.getByRole("button", { name: "Agregar producto" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("Ya existe ese modelo");
    expect(screen.getByRole("button", { name: "Agregar producto" })).toBeInTheDocument();
  });

  it("corrige el tipo y la garantía de un modelo (marca y modelo quedan fijos)", async () => {
    const u = userEvent.setup();
    montar();
    await screen.findByText("BX600L-LM");
    await u.click(screen.getByRole("button", { name: /Editar APC BX600L-LM/ }));
    expect(campo("Marca", "inv-marca")).toBeDisabled();
    expect(campo("Modelo", "inv-modelo")).toBeDisabled();
    await u.clear(campo("Tipo de equipo", "inv-tipo"));
    await u.type(campo("Tipo de equipo", "inv-tipo"), "REGULADOR");
    await u.click(screen.getByRole("button", { name: "Guardar cambios" }));
    await waitFor(() => expect(fakes.actualizarProducto).toHaveBeenCalledWith("1", { categoria: "REGULADOR", meses: "12" }));
    expect(await screen.findByText("Cambios guardados")).toBeInTheDocument();
  });

  it("desactivar y activar un modelo cambia su estado y recarga", async () => {
    const u = userEvent.setup();
    montar();
    await screen.findByText("BX600L-LM");
    await u.click(screen.getByRole("button", { name: /Desactivar APC BX600L-LM/ }));
    await waitFor(() => expect(fakes.cambiarActivo).toHaveBeenCalledWith("1", false));
    expect(await screen.findByText(/desactivado: ya no se ofrece/)).toBeInTheDocument();
    await u.click(screen.getByRole("button", { name: /^Desactivados/ }));
    await u.click(screen.getByRole("button", { name: /Activar Epson T544120/ }));
    await waitFor(() => expect(fakes.cambiarActivo).toHaveBeenCalledWith("4", true));
  });
});
