// Barra de estados de la orden (Tarea 16 del plan; maqueta 04).
import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";

import BarraEstados from "./BarraEstados.jsx";

const pasos = () => screen.getAllByRole("listitem").map((li) => li.textContent);
const actual = () =>
  screen.getAllByRole("listitem").filter((li) => li.getAttribute("aria-current") === "step");

describe("BarraEstados", () => {
  it("en garantía no pasa por Presupuestado", () => {
    render(<BarraEstados estado="RECIBIDO" tipoAtencion="GARANTIA" />);
    expect(pasos()).toEqual(["Recibido", "En diagnóstico", "Diagnosticado", "En reparación", "Reparado", "Entregado"]);
  });

  it("en servicio pago muestra Presupuestado entre el diagnóstico y la reparación", () => {
    render(<BarraEstados estado="RECIBIDO" tipoAtencion="PAGO" />);
    expect(pasos()).toEqual([
      "Recibido",
      "En diagnóstico",
      "Diagnosticado",
      "Presupuestado",
      "En reparación",
      "Reparado",
      "Entregado",
    ]);
  });

  it("marca el paso actual y como hechos los anteriores", () => {
    render(<BarraEstados estado="EN_REPARACION" tipoAtencion="GARANTIA" />);
    expect(actual().map((li) => li.textContent)).toEqual(["En reparación"]);
    const hechos = screen.getAllByRole("listitem").filter((li) => li.dataset.hecho === "true");
    expect(hechos.map((li) => li.textContent)).toEqual(["Recibido", "En diagnóstico", "Diagnosticado"]);
  });

  it("Diagnosticado se marca solo cuando hay diagnóstico, aunque el estado siga en diagnóstico", () => {
    const { rerender } = render(<BarraEstados estado="EN_DIAGNOSTICO" tipoAtencion="GARANTIA" />);
    expect(screen.getByText("Diagnosticado").dataset.hecho).toBe("false");
    rerender(<BarraEstados estado="EN_DIAGNOSTICO" tipoAtencion="GARANTIA" tieneDiagnostico />);
    expect(screen.getByText("Diagnosticado").dataset.hecho).toBe("true");
  });

  it.each([
    ["RECHAZADO", "Rechazado", "adverso"],
    ["IRREPARABLE", "Irreparable", "adverso"],
    ["EN_ESPERA_REPUESTO", "En espera de repuesto", "progreso"],
  ])("el estado lateral %s sale como insignia", (estado, nombre, tono) => {
    render(<BarraEstados estado={estado} tipoAtencion="GARANTIA" />);
    expect(screen.getByRole("status")).toHaveTextContent(nombre);
    expect(screen.getByRole("status")).toHaveAttribute("data-tono", tono);
    expect(actual()).toHaveLength(0);
  });

  it("un estado de la línea principal no lleva insignia lateral", () => {
    render(<BarraEstados estado="REPARADO" tipoAtencion="GARANTIA" />);
    expect(screen.queryByRole("status")).toBeNull();
  });
});
