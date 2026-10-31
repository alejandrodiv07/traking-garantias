// Registrar garantía (maqueta 02): asistente de 5 pasos con resumen en vivo.
// Los servicios se simulan en el borde; la base vuelve a validar todo.
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, Route, Routes, useLocation } from "react-router-dom";
import { beforeEach, describe, expect, it, vi } from "vitest";

const fakes = vi.hoisted(() => ({
  buscarCliente: vi.fn(),
  guardarCliente: vi.fn(),
  listarProductos: vi.fn(),
  registrarGarantia: vi.fn(),
  subirDocumentosEquipo: vi.fn(),
  rol: "TECNICO",
}));

vi.mock("../registro/registroService.js", () => fakes);
vi.mock("./garantiasService.js", () => fakes);
vi.mock("../auth/AuthContext.jsx", () => ({
  useAuth: () => ({ rol: fakes.rol, perfil: { id: "u1" } }),
}));

import NuevaGarantia from "./NuevaGarantia.jsx";

function Destino() {
  const l = useLocation();
  return <p>Consulta {l.search}</p>;
}

function Destino2() {
  return <p>Taller nueva {useLocation().search}</p>;
}

const montar = (ruta = "/garantias/nueva") =>
  render(
    <MemoryRouter initialEntries={[ruta]}>
      <Routes>
        <Route path="/garantias/nueva" element={<NuevaGarantia />} />
        <Route path="/garantias/consulta" element={<Destino />} />
        <Route path="/garantias" element={<p>Tablero</p>} />
        <Route path="/taller/nueva" element={<Destino2 />} />
      </Routes>
    </MemoryRouter>,
  );

const DOC = new File(["x"], "factura.pdf", { type: "application/pdf" });
const FOTO = new File(["x"], "foto.jpg", { type: "image/jpeg" });
const haceDias = (n) => new Date(Date.now() - n * 86400000).toLocaleDateString("sv");
const siguiente = () => userEvent.setup().click(screen.getByRole("button", { name: "Siguiente" }));
const paso = (n) => screen.getByRole("list", { name: "Pasos" }).querySelectorAll("li")[n];

async function titularExistente(usuario) {
  await usuario.type(screen.getByLabelText("Número de documento"), "12345678");
  await screen.findByText(/Titular encontrado/);
  await siguiente();
}

async function elegirProducto(usuario, serial = "RT5-8842-AA") {
  await usuario.type(screen.getByLabelText("Serial"), serial);
  await usuario.selectOptions(await screen.findByLabelText("Marca"), "Huawei");
  await usuario.selectOptions(screen.getByLabelText("Modelo"), "p1");
}

async function llenarCompra(usuario, plazo = /^7 días/, fecha = haceDias(3)) {
  await usuario.type(screen.getByLabelText("N.º de factura"), "F-200");
  fireEvent.change(screen.getByLabelText("Fecha de emisión"), { target: { value: fecha } });
  await usuario.click(screen.getByRole("radio", { name: plazo }));
}

async function hastaResumen(usuario, plazo) {
  montar();
  await titularExistente(usuario);
  await elegirProducto(usuario);
  await siguiente();
  await llenarCompra(usuario, plazo);
  await siguiente();
  await siguiente();
}

beforeEach(() => {
  fakes.rol = "TECNICO";
  fakes.buscarCliente.mockReset().mockResolvedValue({
    ok: true,
    datos: { id: "c1", tipo_documento: "V", documento: "12345678", nombre: "Juan Perez", telefono: null, email: "juan@x.com" },
  });
  fakes.guardarCliente.mockReset().mockResolvedValue({ ok: true, datos: "c-nuevo" });
  fakes.listarProductos.mockReset().mockResolvedValue({
    ok: true,
    datos: [{ id: "p1", marca: { nombre: "Huawei" }, modelo: "HG8245" }],
  });
  fakes.subirDocumentosEquipo.mockReset().mockResolvedValue([]);
  fakes.registrarGarantia.mockReset().mockResolvedValue({
    ok: true,
    datos: { equipo_id: "e1", vence_el: "2026-11-27", equipo_nuevo: true },
  });
});

describe("NuevaGarantia: pasos y titular", () => {
  it("tiene los cinco pasos del diseño y no deja avanzar sin titular", () => {
    montar();
    expect([0, 1, 2, 3, 4].map((i) => paso(i).textContent)).toEqual(["Cliente", "Productos", "Compra", "Documentos", "Resumen"]);
    expect(screen.getByRole("button", { name: "Siguiente" })).toBeDisabled();
    expect(paso(0)).toHaveAttribute("aria-current", "step");
  });

  it("trae los datos de un titular existente y los bloquea", async () => {
    montar();
    await userEvent.setup().type(screen.getByLabelText("Número de documento"), "12345678");
    expect(await screen.findByText(/Titular encontrado/)).toBeInTheDocument();
    expect(screen.getByLabelText("Nombre o razón social")).toHaveValue("Juan Perez");
    expect(screen.getByLabelText("Nombre o razón social")).toBeDisabled();
    expect(screen.getByLabelText("Correo electrónico")).toHaveValue("juan@x.com");
    expect(screen.getByRole("button", { name: "Siguiente" })).toBeEnabled();
  });

  it("a un titular nuevo le exige tipo, nombre y un correo válido", async () => {
    fakes.buscarCliente.mockResolvedValue({ ok: true, datos: null });
    const u = userEvent.setup();
    montar();
    await u.type(screen.getByLabelText("Número de documento"), "V-20111222");
    expect(screen.getByLabelText("Tipo de documento")).toHaveValue("V");
    await u.type(screen.getByLabelText("Nombre o razón social"), "Ana Lopez");
    await u.type(screen.getByLabelText("Correo electrónico"), "ana@");
    expect(screen.getByText("Escribe un correo válido")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Siguiente" })).toBeDisabled();
    await u.type(screen.getByLabelText("Correo electrónico"), "x.com");
    expect(screen.getByRole("button", { name: "Siguiente" })).toBeEnabled();
  });

  it("el documento corto avisa y no busca", async () => {
    montar();
    await userEvent.setup().type(screen.getByLabelText("Número de documento"), "123");
    expect(screen.getByText("El documento necesita al menos 5 dígitos")).toBeInTheDocument();
    expect(fakes.buscarCliente).not.toHaveBeenCalled();
  });
});

describe("NuevaGarantia: productos", () => {
  it("rechaza un serial repetido y permite agregar y quitar productos", async () => {
    const u = userEvent.setup();
    montar();
    await titularExistente(u);
    await elegirProducto(u, "RT5-8842-AA");
    await u.click(screen.getByRole("button", { name: /Agregar otro producto/ }));
    expect(screen.getByText("Producto 2")).toBeInTheDocument();
    const seriales = screen.getAllByLabelText("Serial");
    await u.type(seriales[1], "rt5 8842 aa");
    expect(screen.getByText("Este serial está repetido en la lista")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Siguiente" })).toBeDisabled();
    await u.click(screen.getByRole("button", { name: /Quitar.*producto 2/ }));
    expect(screen.queryByText("Producto 2")).toBeNull();
    expect(screen.getByRole("button", { name: "Siguiente" })).toBeEnabled();
  });
});

describe("NuevaGarantia: compra", () => {
  it("calcula el vencimiento y los días restantes en vivo", async () => {
    const u = userEvent.setup();
    montar();
    await titularExistente(u);
    await elegirProducto(u);
    await siguiente();
    await llenarCompra(u, /^7 días/, haceDias(3));
    expect(screen.getAllByRole("status").some((e) => /días restantes/.test(e.textContent) && e.textContent.startsWith("4"))).toBe(true);
  });

  it("avisa cuando la garantía nace vencida", async () => {
    const u = userEvent.setup();
    montar();
    await titularExistente(u);
    await elegirProducto(u);
    await siguiente();
    await llenarCompra(u, /^7 días/, haceDias(20));
    expect(screen.getByText(/nace vencida/)).toBeInTheDocument();
  });

  it("no acepta una fecha futura", async () => {
    const u = userEvent.setup();
    montar();
    await titularExistente(u);
    await elegirProducto(u);
    await siguiente();
    await llenarCompra(u, /^7 días/, "2999-01-01");
    expect(screen.getByText("La fecha no puede ser futura")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Siguiente" })).toBeDisabled();
  });

  it("«Otro plazo» solo lo fija la jefatura", async () => {
    const u = userEvent.setup();
    montar();
    await titularExistente(u);
    await elegirProducto(u);
    await siguiente();
    expect(screen.getByRole("radio", { name: /Otro plazo/ })).toBeDisabled();
  });

  it("la jefatura fija otro plazo en días", async () => {
    fakes.rol = "JEFE_SERVICIO";
    const u = userEvent.setup();
    montar();
    await titularExistente(u);
    await elegirProducto(u);
    await siguiente();
    await u.type(screen.getByLabelText("N.º de factura"), "F-1");
    fireEvent.change(screen.getByLabelText("Fecha de emisión"), { target: { value: haceDias(1) } });
    await u.click(screen.getByRole("radio", { name: /Otro plazo/ }));
    await u.type(screen.getByLabelText("Días de garantía"), "30");
    expect(screen.getByRole("button", { name: "Siguiente" })).toBeEnabled();
  });

  it("sin factura deja continuar y avisa que queda por determinar", async () => {
    const u = userEvent.setup();
    montar();
    await titularExistente(u);
    await elegirProducto(u);
    await siguiente();
    await u.click(screen.getByLabelText(/No trae la factura/));
    expect(screen.getByText(/queda por determinar/)).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Siguiente" })).toBeEnabled();
  });
});

describe("NuevaGarantia: registrar", () => {
  it("el paso Documentos acepta archivos y los lista", async () => {
    const u = userEvent.setup();
    montar();
    await titularExistente(u);
    await elegirProducto(u);
    await siguiente(u);
    await llenarCompra(u);
    await siguiente(u);
    await u.upload(screen.getByLabelText(/Documentos/), DOC);
    expect(screen.getByText(/factura\.pdf/)).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Siguiente" })).toBeEnabled();
  });

  it("sube los documentos a la garantía recién registrada", async () => {
    const u = userEvent.setup();
    montar();
    await titularExistente(u);
    await elegirProducto(u);
    await siguiente(u);
    await llenarCompra(u);
    await siguiente(u);
    await u.upload(screen.getByLabelText(/Documentos/), DOC);
    await u.upload(screen.getByLabelText(/Fotos/), FOTO);
    await siguiente(u);
    expect(screen.getByText("1 documentos · 1 fotos")).toBeInTheDocument();
    await u.click(screen.getByRole("button", { name: "Registrar garantía" }));
    await waitFor(() =>
      expect(fakes.subirDocumentosEquipo).toHaveBeenCalledWith("e1", [
        expect.objectContaining({ archivo: DOC, tipo: "DOCUMENTO" }),
        expect.objectContaining({ archivo: FOTO, tipo: "FOTO" }),
      ]),
    );
    expect(await screen.findByText("Garantía registrada")).toBeInTheDocument();
    expect(screen.queryByText(/no se subieron/)).toBeNull();
  });

  it("sin documentos no intenta subir nada", async () => {
    const u = userEvent.setup();
    await hastaResumen(u);
    expect(screen.getByText("Sin documentos")).toBeInTheDocument();
    await u.click(screen.getByRole("button", { name: "Registrar garantía" }));
    await screen.findByText("Garantía registrada");
    expect(fakes.subirDocumentosEquipo).not.toHaveBeenCalled();
  });

  it("si una subida falla, la garantía queda registrada y se reintentan solo los archivos", async () => {
    fakes.subirDocumentosEquipo.mockResolvedValueOnce([{ archivo: DOC, tipo: "DOCUMENTO", mensaje: "Sin conexión" }]).mockResolvedValue([]);
    const u = userEvent.setup();
    montar();
    await titularExistente(u);
    await elegirProducto(u);
    await siguiente(u);
    await llenarCompra(u);
    await siguiente(u);
    await u.upload(screen.getByLabelText(/Documentos/), DOC);
    await siguiente(u);
    await u.click(screen.getByRole("button", { name: "Registrar garantía" }));
    expect(await screen.findByText(/1 documento\(s\) no se subieron/)).toBeInTheDocument();
    expect(fakes.registrarGarantia).toHaveBeenCalledTimes(1);
    await u.click(screen.getByRole("button", { name: "Reintentar documentos" }));
    await waitFor(() => expect(screen.queryByText(/no se subieron/)).toBeNull());
    expect(fakes.registrarGarantia).toHaveBeenCalledTimes(1);
    expect(fakes.subirDocumentosEquipo).toHaveBeenCalledTimes(2);
  });

  it("registra la garantía y ofrece verla en la consulta", async () => {
    const u = userEvent.setup();
    await hastaResumen(u);
    expect(screen.getAllByText("Factura F-200").length).toBeGreaterThan(1);
    await u.click(screen.getByRole("button", { name: "Registrar garantía" }));
    await waitFor(() =>
      expect(fakes.registrarGarantia).toHaveBeenCalledWith({
        clienteId: "c1",
        productoId: "p1",
        serial: "RT5-8842-AA",
        tipoSoporte: "FACTURA",
        numeroSoporte: "F-200",
        fechaEmision: haceDias(3),
        plazoDias: 7,
        origen: "VENTA",
      }),
    );
    expect(fakes.guardarCliente).not.toHaveBeenCalled();
    expect(await screen.findByText("Garantía registrada")).toBeInTheDocument();
    await u.click(screen.getByRole("button", { name: "Ver garantía" }));
    expect(await screen.findByText("Consulta ?serial=RT5-8842-AA")).toBeInTheDocument();
  });

  it("la pantalla de éxito resume lo registrado y ofrece los siguientes pasos", async () => {
    const u = userEvent.setup();
    await hastaResumen(u);
    await u.click(screen.getByRole("button", { name: "Registrar garantía" }));
    await screen.findByRole("heading", { name: "Garantía registrada" });
    const datos = document.querySelector(".exito-datos");
    expect(datos).toHaveTextContent("Juan Perez");
    expect(datos).toHaveTextContent("F-200");
    expect(datos).toHaveTextContent("plazo 7 días");
    expect(datos).toHaveTextContent("Registrada tras la venta");
    const items = within(screen.getByRole("list", { name: "Garantías registradas" }));
    expect(items.getByText("Huawei HG8245")).toBeInTheDocument();
    expect(items.getByText("RT5-8842-AA")).toBeInTheDocument();
    expect(items.getByText("Vigente")).toBeInTheDocument();
    expect(items.getByText(/Vence el/)).toBeInTheDocument();
  });

  it("desde el éxito se abre una orden para ese equipo", async () => {
    const u = userEvent.setup();
    await hastaResumen(u);
    await u.click(screen.getByRole("button", { name: "Registrar garantía" }));
    await u.click(await screen.findByRole("button", { name: "Abrir orden de servicio" }));
    expect(await screen.findByText("Taller nueva ?equipo=e1")).toBeInTheDocument();
  });

  it("«Registrar otra garantía» devuelve el asistente vacío", async () => {
    const u = userEvent.setup();
    await hastaResumen(u);
    await u.click(screen.getByRole("button", { name: "Registrar garantía" }));
    await u.click(await screen.findByRole("button", { name: "Registrar otra garantía" }));
    expect(screen.getByLabelText("Número de documento")).toHaveValue("");
    expect(screen.getByRole("button", { name: "Siguiente" })).toBeDisabled();
  });

  it("una garantía sin soporte o desde taller sale «Por confirmar»", async () => {
    const u = userEvent.setup();
    montar();
    await titularExistente(u);
    await elegirProducto(u);
    await siguiente(u);
    await u.click(screen.getByLabelText(/No trae la factura/));
    await siguiente(u);
    await siguiente(u);
    await u.click(screen.getByRole("button", { name: "Registrar garantía" }));
    await screen.findByRole("heading", { name: "Garantía registrada" });
    expect(within(screen.getByRole("list", { name: "Garantías registradas" })).getByText("Por confirmar")).toBeInTheDocument();
    expect(screen.getByText(/Quedó por confirmar/)).toBeInTheDocument();
  });

  it("crea al titular nuevo antes de registrar", async () => {
    fakes.buscarCliente.mockResolvedValue({ ok: true, datos: null });
    const u = userEvent.setup();
    montar();
    await u.type(screen.getByLabelText("Número de documento"), "V-20111222");
    await u.type(screen.getByLabelText("Nombre o razón social"), "Ana Lopez");
    await u.type(screen.getByLabelText("Correo electrónico"), "ana@x.com");
    await siguiente();
    await elegirProducto(u);
    await siguiente();
    await llenarCompra(u);
    await siguiente();
    await siguiente();
    await u.click(screen.getByRole("button", { name: "Registrar garantía" }));
    await waitFor(() =>
      expect(fakes.guardarCliente).toHaveBeenCalledWith({
        tipo: "V",
        documento: "20111222",
        nombre: "Ana Lopez",
        telefono: null,
        email: "ana@x.com",
      }),
    );
    await waitFor(() => expect(fakes.registrarGarantia).toHaveBeenCalledWith(expect.objectContaining({ clienteId: "c-nuevo" })));
  });

  it("varios productos registran una garantía cada uno", async () => {
    const u = userEvent.setup();
    montar();
    await titularExistente(u);
    await elegirProducto(u, "S-111");
    await u.click(screen.getByRole("button", { name: /Agregar otro producto/ }));
    await u.type(screen.getAllByLabelText("Serial")[1], "S-222");
    await u.selectOptions(screen.getAllByLabelText("Marca")[1], "Huawei");
    await u.selectOptions(screen.getAllByLabelText("Modelo")[1], "p1");
    await siguiente();
    await llenarCompra(u);
    await siguiente();
    await siguiente();
    await u.click(screen.getByRole("button", { name: "Registrar 2 garantías" }));
    await waitFor(() => expect(fakes.registrarGarantia).toHaveBeenCalledTimes(2));
    expect(await screen.findByText("2 garantías registradas")).toBeInTheDocument();
  });

  it("muestra el rechazo de la base y se queda en el resumen", async () => {
    fakes.registrarGarantia.mockResolvedValue({ ok: false, codigo: "SIN_PERMISO", mensaje: "los plazos distintos de 7 o 15 días solo los fija el jefe" });
    const u = userEvent.setup();
    await hastaResumen(u);
    await u.click(screen.getByRole("button", { name: "Registrar garantía" }));
    expect((await screen.findByRole("alert")).textContent).toMatch(/solo los fija el jefe/);
    expect(screen.queryByText("Garantía registrada")).toBeNull();
    expect(screen.getByRole("button", { name: "Registrar garantía" })).toBeEnabled();
  });

  it("si un producto falla, los ya registrados no se repiten al reintentar", async () => {
    fakes.registrarGarantia
      .mockResolvedValueOnce({ ok: true, datos: { vence_el: "2026-11-27", equipo_nuevo: true } })
      .mockResolvedValueOnce({ ok: false, codigo: "DESCONOCIDO", mensaje: "serial inválido" });
    const u = userEvent.setup();
    montar();
    await titularExistente(u);
    await elegirProducto(u, "S-111");
    await u.click(screen.getByRole("button", { name: /Agregar otro producto/ }));
    await u.type(screen.getAllByLabelText("Serial")[1], "S-222");
    await u.selectOptions(screen.getAllByLabelText("Marca")[1], "Huawei");
    await u.selectOptions(screen.getAllByLabelText("Modelo")[1], "p1");
    await siguiente();
    await llenarCompra(u);
    await siguiente();
    await siguiente();
    await u.click(screen.getByRole("button", { name: "Registrar 2 garantías" }));
    expect((await screen.findByRole("alert")).textContent).toMatch(/S-222: serial inválido.*ya registradas: S-111/);
    expect(screen.getByRole("button", { name: "Registrar garantía" })).toBeEnabled();
  });

  it("llegando de la Consulta (?serial=&origen=TALLER) precarga el serial y registra con origen TALLER", async () => {
    const u = userEvent.setup();
    montar("/garantias/nueva?serial=ABC-999&origen=TALLER");
    await titularExistente(u);
    expect(screen.getByLabelText("Serial")).toHaveValue("ABC-999");
    await u.selectOptions(await screen.findByLabelText("Marca"), "Huawei");
    await u.selectOptions(screen.getByLabelText("Modelo"), "p1");
    await siguiente();
    await llenarCompra(u);
    await siguiente();
    await siguiente();
    expect(screen.getByText(/queda por confirmar/)).toBeInTheDocument();
    await u.click(screen.getByRole("button", { name: "Registrar garantía" }));
    await waitFor(() =>
      expect(fakes.registrarGarantia).toHaveBeenCalledWith(expect.objectContaining({ serial: "ABC-999", origen: "TALLER" })),
    );
  });
});
