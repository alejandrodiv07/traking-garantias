import React from "react";
import { fireEvent, render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("../../auth/AuthContext.jsx", () => ({
  useAuth: () => ({ perfil: { id: "u1", full_name: "Ana Rondón" } }),
}));

vi.mock("../datos/ordenes.js", () => ({
  crearOrden: vi.fn(),
}));

vi.mock("../datos/documentos.js", () => ({
  subirDocumentos: vi.fn().mockResolvedValue([]),
  MAX_ARCHIVOS_POR_ORDEN: 5,
  TAMANO_MAXIMO_BYTES: 10 * 1024 * 1024,
  TIPOS_MIME_PERMITIDOS: ["application/pdf", "image/jpeg", "image/png"],
  TIPOS_DOCUMENTO: [
    { codigo: "FACTURA", etiqueta: "Factura" },
    { codigo: "FOTO_EQUIPO", etiqueta: "Foto del equipo" },
    { codigo: "OTRO", etiqueta: "Otro" },
  ],
}));

vi.mock("../datos/hooks.js", () => ({
  useTecnicos: () => ({ tecnicos: [] }),
  useMarcas: () => ({ marcas: [{ id: "m1", nombre: "EA2" }] }),
  useBusquedaClientes: () => {
    const [termino, setTermino] = React.useState("");
    return { termino, setTermino, clientes: [], buscando: false };
  },
  useBusquedaProductos: () => {
    const [termino, setTermino] = React.useState("");
    return { termino, setTermino, productos: [], buscando: false };
  },
}));

import { crearOrden } from "../datos/ordenes.js";
import ModalNuevaGarantia from "./ModalNuevaGarantia.jsx";

function elementosFocoables() {
  return Array.from(
    document.querySelectorAll(
      'a[href], button:not([disabled]), textarea, input, select, [tabindex]:not([tabindex="-1"])'
    )
  );
}

async function completarPasoProducto(usuario) {
  await usuario.type(screen.getByPlaceholderText("Nombre o cédula/RIF…"), "Juan Pérez");
  await usuario.click(screen.getByRole("option", { name: /registrar/i }));
  await usuario.type(screen.getByPlaceholderText("12345678"), "12345678");

  await usuario.type(screen.getByPlaceholderText("Ej. Router Industrial EA2-RT500…"), "Router X");
  await usuario.click(screen.getByRole("option", { name: /registrar/i }));
  // El modelo ya viene precargado con el término buscado (Router X); no se
  // vuelve a teclear, solo se completan marca y categoría.
  await usuario.selectOptions(screen.getByLabelText("Marca *"), "m1");
  await usuario.type(screen.getByPlaceholderText("Ej. Conectividad industrial"), "Redes");

  await usuario.type(screen.getByLabelText(/Falla reportada/), "No enciende el equipo");
}

describe("ModalNuevaGarantia", () => {
  beforeEach(() => {
    crearOrden.mockReset();
  });

  it("atrapa el foco: Tab en el último control vuelve al primero", async () => {
    render(<ModalNuevaGarantia onCerrar={vi.fn()} onOrdenCreada={vi.fn()} />);

    const foco = elementosFocoables();
    const primero = foco[0];
    const ultimo = foco[foco.length - 1];

    expect(document.activeElement).toBe(primero);

    ultimo.focus();
    expect(document.activeElement).toBe(ultimo);

    fireEvent.keyDown(document, { key: "Tab" });

    expect(document.activeElement).toBe(primero);
  });

  it("Esc cierra el modal mientras se está llenando el formulario", async () => {
    const onCerrar = vi.fn();
    render(<ModalNuevaGarantia onCerrar={onCerrar} onOrdenCreada={vi.fn()} />);

    fireEvent.keyDown(document, { key: "Escape" });

    expect(onCerrar).toHaveBeenCalledTimes(1);
  });

  it("muestra el título y el botón renombrados", () => {
    render(<ModalNuevaGarantia onCerrar={vi.fn()} onOrdenCreada={vi.fn()} />);
    expect(screen.getByRole("heading", { name: "Agregar nueva garantía" })).toBeInTheDocument();
  });

  it("el paso 1 vacío bloquea avanzar y muestra un error por campo", async () => {
    const usuario = userEvent.setup();
    render(<ModalNuevaGarantia onCerrar={vi.fn()} onOrdenCreada={vi.fn()} />);

    await usuario.click(screen.getByRole("button", { name: "Siguiente" }));

    expect(await screen.findByText("Elige un cliente o completa su registro.")).toBeInTheDocument();
    expect(screen.getByText("Elige un equipo o completa su registro.")).toBeInTheDocument();
    expect(screen.getByText("Describe la falla con 5 a 2000 caracteres.")).toBeInTheDocument();
    // Sigue en el paso 1: el paso 2 no se muestra.
    expect(screen.queryByText("Cobertura de garantía")).not.toBeInTheDocument();
    expect(crearOrden).not.toHaveBeenCalled();
  });

  it("una falla reportada de 4 caracteres bloquea el avance con el mensaje esperado", async () => {
    const usuario = userEvent.setup();
    render(<ModalNuevaGarantia onCerrar={vi.fn()} onOrdenCreada={vi.fn()} />);

    await usuario.type(screen.getByLabelText(/Falla reportada/), "abcd");
    await usuario.click(screen.getByRole("button", { name: "Siguiente" }));

    expect(await screen.findByText("Describe la falla con 5 a 2000 caracteres.")).toBeInTheDocument();
    expect(crearOrden).not.toHaveBeenCalled();
  });

  it("completa el asistente de 4 pasos y llama a crear_orden() con el payload esperado", async () => {
    const onOrdenCreada = vi.fn();
    crearOrden.mockResolvedValue({
      ok: true,
      datos: { ordenId: "g1", numeroOrden: "G-0001", consultaToken: "TOKEN-ABC" },
    });
    const usuario = userEvent.setup();
    render(<ModalNuevaGarantia onCerrar={vi.fn()} onOrdenCreada={onOrdenCreada} />);

    // Paso 1: Producto
    await completarPasoProducto(usuario);
    await usuario.click(screen.getByRole("button", { name: "Siguiente" }));

    // Paso 2: Garantía
    await screen.findByText("Cobertura de garantía");
    await usuario.click(screen.getByRole("button", { name: "Siguiente" }));

    // Paso 3: Documentos (opcional, se avanza sin adjuntar nada)
    await screen.findByRole("heading", { name: "Documentos" });
    await usuario.click(screen.getByRole("button", { name: "Siguiente" }));

    // Paso 4: Resumen
    await screen.findByRole("heading", { name: "Revisa antes de registrar" });
    await usuario.click(screen.getByRole("button", { name: "Registrar garantía" }));

    expect(await screen.findByText("Garantía G-0001 registrada")).toBeInTheDocument();
    expect(crearOrden).toHaveBeenCalledTimes(1);

    const payload = crearOrden.mock.calls[0][0];
    expect(payload.fallaReportada).toBe("No enciende el equipo");
    expect(payload.cliente.nuevo.documento).toBe("12345678");
    expect(payload.producto.nuevo.modelo).toBe("Router X");
    expect(payload.tipoGarantia).toBe("ESTANDAR");
    expect(payload.slaDias).toBe(5);
    expect(onOrdenCreada).toHaveBeenCalledTimes(1);
  });
});
