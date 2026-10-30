// Pruebas de PasoAdjuntos y PasoResumen (Tarea 19 del plan).
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";

import PasoAdjuntos from "./PasoAdjuntos.jsx";
import PasoResumen from "./PasoResumen.jsx";

const actualizar = vi.fn();
beforeEach(() => {
  actualizar.mockReset();
});

const HEIC = () => new File([new Uint8Array(4)], "a.heic", { type: "image/heic" });
const GRANDE = () => {
  const f = new File([new Uint8Array(4)], "g.jpg", { type: "image/jpeg" });
  Object.defineProperty(f, "size", { value: 9 * 1024 * 1024 });
  return f;
};
const FOTO = () => new File([new Uint8Array(4)], "n.jpg", { type: "image/jpeg" });
const PDF = () => new File([new Uint8Array(4)], "d.pdf", { type: "application/pdf" });

const ESTADO_ADJ = { archivosAdjuntos: [] };
// fireEvent.change: el accept del input filtra en userEvent.upload y no
// deja llegar los archivos inválidos que aquí se quieren rechazar.
const subir = (etiquetaArchivo, archivo) =>
  fireEvent.change(screen.getByLabelText(etiquetaArchivo).closest("label")?.querySelector("input") ?? screen.getByLabelText(etiquetaArchivo), { target: { files: [archivo] } });

describe("PasoAdjuntos", () => {
  it("un HEIC se rechaza con el mensaje claro, sin quitar los demás adjuntos", async () => {
    render(<PasoAdjuntos estado={ESTADO_ADJ} actualizar={actualizar} />);
    fireEvent.change(screen.getElementById ? screen.getElementById("inputFoto") : screen.getByLabelText(/foto/i), { target: { files: [FOTO()] } });
    fireEvent.change(screen.getByLabelText(/foto/i), { target: { files: [HEIC()] } });
    expect(await screen.findByText(/Formato no admitido/i)).toBeTruthy();
    expect(screen.getByText(/n\.jpg/)).toBeTruthy();   // el buen adjunto sigue
    expect(screen.queryByText(/a\.heic/)).toBeNull(); // el rechazado, no
  });

  it("un archivo de 9 MB muestra el mensaje de límite", async () => {
    render(<PasoAdjuntos estado={ESTADO_ADJ} actualizar={actualizar} />);
    fireEvent.change(screen.getByLabelText(/foto/i), { target: { files: [GRANDE()] } });
    expect(await screen.findByText(/más de 8 MB/i)).toBeTruthy();
    expect(actualizar).not.toHaveBeenCalled();
  });

  it("la novena foto muestra el límite de 8", async () => {
    const ocho = Array.from({ length: 8 }, (_, i) => ({
      id: String(i),
      archivo: FOTO(), tipo: "FOTO", etiqueta: `f${i}`, error: null,
    }));
    render(<PasoAdjuntos estado={{ archivosAdjuntos: ocho }} actualizar={actualizar} />);
    fireEvent.change(screen.getByLabelText(/foto/i), { target: { files: [FOTO()] } });
    expect(await screen.findByText(/máximo 8/i)).toBeTruthy();
    expect(actualizar).not.toHaveBeenCalled();
  });
});

describe("PasoResumen", () => {
  const ESTADO_RESUMEN = {
    serial: "RT5-8842-AA",
    productoTexto: "Huawei HG8245",
    titular: "Juan Perez",
    falla: "No enciende",
    numeroSoporte: "F-1",
    fechaEmision: "2026-09-01",
    plazoDias: 7,
    cobertura: "EN_GARANTIA",
    archivosAdjuntos: [{ id: "1", archivo: FOTO(), tipo: "FOTO", etiqueta: "frontal" }],
  };

  function editar() {
    return vi.fn();
  }

  it("lista cliente, equipo, falla, compra, verificación y adjuntos", () => {
    render(<PasoResumen estado={ESTADO_RESUMEN} irPara={editar()} onConfirmar={vi.fn()} />);
    expect(screen.getByText(/Juan Perez/)).toBeTruthy();
    expect(screen.getByText(/RT5-8842-AA/)).toBeTruthy();
    expect(screen.getByText(/No enciende/)).toBeTruthy();
    expect(screen.getByText(/F-1/)).toBeTruthy();
    expect(screen.getByText(/EN_GARANTIA/)).toBeTruthy();
    expect(screen.getAllByText(/n\.jpg|foto/).length >= 1).toBe(true);
  });

  it('el botón "Editar" de cada sección vuelve a ese paso', async () => {
    const irPara = vi.fn();
    render(<PasoResumen estado={ESTADO_RESUMEN} irPara={irPara} onConfirmar={vi.fn()} />);
    const user = userEvent.setup();
    await user.click(screen.getByRole("button", { name: /editar cliente/i }));
    expect(irPara).toHaveBeenCalledWith("cliente");
    await user.click(screen.getByRole("button", { name: /editar equipo/i }));
    expect(irPara).toHaveBeenCalledWith("equipo");
  });
});