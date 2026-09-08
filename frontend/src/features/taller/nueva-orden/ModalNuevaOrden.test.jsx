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
  useMarcas: () => ({ marcas: [] }),
  useBusquedaClientes: () => ({ termino: "", setTermino: vi.fn(), clientes: [], buscando: false }),
  useBusquedaProductos: () => ({ termino: "", setTermino: vi.fn(), productos: [], buscando: false }),
}));

import { crearOrden } from "../datos/ordenes.js";
import ModalNuevaOrden from "./ModalNuevaOrden.jsx";

function elementosFocoables() {
  return Array.from(
    document.querySelectorAll(
      'a[href], button:not([disabled]), textarea, input, select, [tabindex]:not([tabindex="-1"])'
    )
  );
}

describe("ModalNuevaOrden", () => {
  beforeEach(() => {
    crearOrden.mockReset();
  });

  it("atrapa el foco: Tab en el último control vuelve al primero", async () => {
    render(<ModalNuevaOrden onCerrar={vi.fn()} onOrdenCreada={vi.fn()} />);

    const foco = elementosFocoables();
    const primero = foco[0];
    const ultimo = foco[foco.length - 1];

    // El primer elemento focoable recibe el foco al abrir el modal.
    expect(document.activeElement).toBe(primero);

    ultimo.focus();
    expect(document.activeElement).toBe(ultimo);

    fireEvent.keyDown(document, { key: "Tab" });

    expect(document.activeElement).toBe(primero);
  });

  it("Esc cierra el modal mientras se está llenando el formulario", async () => {
    const onCerrar = vi.fn();
    render(<ModalNuevaOrden onCerrar={onCerrar} onOrdenCreada={vi.fn()} />);

    fireEvent.keyDown(document, { key: "Escape" });

    expect(onCerrar).toHaveBeenCalledTimes(1);
  });

  it("enviar el formulario vacío muestra un error por campo y no llama a crear_orden()", async () => {
    const usuario = userEvent.setup();
    render(<ModalNuevaOrden onCerrar={vi.fn()} onOrdenCreada={vi.fn()} />);

    await usuario.click(screen.getByRole("button", { name: "Crear orden" }));

    expect(await screen.findByText("Elige un cliente o registra uno nuevo.")).toBeInTheDocument();
    expect(screen.getByText("Elige un equipo o registra uno nuevo.")).toBeInTheDocument();
    expect(screen.getByText("Describe la falla con 5 a 2000 caracteres.")).toBeInTheDocument();
    expect(crearOrden).not.toHaveBeenCalled();
  });

  it("una falla reportada de 4 caracteres bloquea el envío", async () => {
    const usuario = userEvent.setup();
    render(<ModalNuevaOrden onCerrar={vi.fn()} onOrdenCreada={vi.fn()} />);

    await usuario.type(screen.getByLabelText(/Falla reportada/), "abcd");
    await usuario.click(screen.getByRole("button", { name: "Crear orden" }));

    expect(await screen.findByText("Describe la falla con 5 a 2000 caracteres.")).toBeInTheDocument();
    expect(crearOrden).not.toHaveBeenCalled();
  });

  it("una falla reportada de 5 caracteres SÍ pasa esa validación puntual", async () => {
    const usuario = userEvent.setup();
    render(<ModalNuevaOrden onCerrar={vi.fn()} onOrdenCreada={vi.fn()} />);

    await usuario.type(screen.getByLabelText(/Falla reportada/), "abcde");
    await usuario.click(screen.getByRole("button", { name: "Crear orden" }));

    // Sigue bloqueado por cliente/equipo (no se llenaron), pero YA NO por la
    // falla reportada: es la prueba de que el umbral está en 5, no en 4 ni en 6.
    await screen.findByText("Elige un cliente o registra uno nuevo.");
    expect(screen.queryByText("Describe la falla con 5 a 2000 caracteres.")).not.toBeInTheDocument();
    expect(crearOrden).not.toHaveBeenCalled();
  });
});
