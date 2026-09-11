import React from "react";
import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";

vi.mock("../datos/hooks.js", () => ({
  // Stateful de verdad: el real hace lo mismo (guarda `termino` y dispara la
  // búsqueda), así que el mock estático rompía la interacción de escribir.
  useBusquedaClientes: () => {
    const [termino, setTermino] = React.useState("");
    return { termino, setTermino, clientes: [], buscando: false };
  },
}));

import CampoCliente from "./CampoCliente.jsx";

// Envoltorio que sostiene el estado tal como lo hace FormularioOrden: el
// valor vive arriba y baja como prop controlada.
function Envoltorio() {
  const [cliente, setCliente] = React.useState(null);
  return <CampoCliente valor={cliente} onCambiar={setCliente} errores={{}} />;
}

describe("CampoCliente — registro de cliente nuevo", () => {
  it("no oculta los campos de nombre/cédula al escribir (regresión: se congelaba tras la 1ª tecla)", async () => {
    const usuario = userEvent.setup();
    render(<Envoltorio />);

    await usuario.type(screen.getByPlaceholderText("Nombre o cédula/RIF…"), "Juan Pérez");
    await usuario.click(screen.getByRole("option", { name: /registrar/i }));

    const campoCedula = screen.getByPlaceholderText("12345678");
    await usuario.type(campoCedula, "12345678");

    // Si el bug reaparece, este input desaparece del árbol (reemplazado por
    // el chip "seleccionado" de SelectorAsincrono) y esto falla.
    expect(screen.getByPlaceholderText("12345678")).toHaveValue("12345678");
    expect(screen.getByPlaceholderText("Nombre o razón social")).toBeInTheDocument();
  });

  it("permite capturar el teléfono del cliente nuevo", async () => {
    const usuario = userEvent.setup();
    render(<Envoltorio />);

    await usuario.type(screen.getByPlaceholderText("Nombre o cédula/RIF…"), "Juan Pérez");
    await usuario.click(screen.getByRole("option", { name: /registrar/i }));

    const campoTelefono = screen.getByLabelText(/Teléfono/);
    await usuario.type(campoTelefono, "04141234567");

    expect(campoTelefono).toHaveValue("04141234567");
  });
});
