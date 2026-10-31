import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import InsigniaVerificacion from "./InsigniaVerificacion.jsx";

describe("InsigniaVerificacion", () => {
  it.each([
    ["COINCIDE", "Respaldada por Ventas", "ok"],
    ["DIFIERE", "No coincide: revisar", "mal"],
    ["SIN_VENTA", "Sin venta", "neutro"],
  ])("%s dice «%s»", (valor, texto, tono) => {
    render(<InsigniaVerificacion valor={valor} />);
    expect(screen.getByText(texto)).toHaveAttribute("data-t", tono);
  });

  it("sin dato no pinta nada", () => {
    const { container } = render(<InsigniaVerificacion valor={null} />);
    expect(container).toBeEmptyDOMElement();
  });
});
