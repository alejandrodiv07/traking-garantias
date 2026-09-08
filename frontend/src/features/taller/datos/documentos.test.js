import { beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("../../../lib/supabaseClient.js");
import { supabase } from "../../../lib/supabaseClient.js";
import { subirDocumento, subirDocumentos } from "./documentos.js";

function archivoFalso({ nombre = "factura.pdf", tipo = "application/pdf", tamano = 1024 } = {}) {
  const archivo = new File([new Uint8Array(tamano)], nombre, { type: tipo });
  return archivo;
}

describe("subirDocumento", () => {
  let upload;
  let remove;
  let insertUnico;

  beforeEach(() => {
    upload = vi.fn().mockResolvedValue({ data: { path: "x" }, error: null });
    remove = vi.fn().mockResolvedValue({ data: null, error: null });
    insertUnico = vi.fn().mockResolvedValue({
      data: { id: "d1", tipo: "FACTURA", nombre_original: "factura.pdf", tamano_bytes: 1024 },
      error: null,
    });

    supabase.storage.from.mockReturnValue({ upload, remove, createSignedUrl: vi.fn() });
    supabase.from.mockReturnValue({
      insert: () => ({ select: () => ({ single: insertUnico }) }),
    });
  });

  it("rechaza un archivo de más de 10 MB SIN llegar a subirlo", async () => {
    const archivo = archivoFalso({ tamano: 11 * 1024 * 1024 });

    const resultado = await subirDocumento({ ordenId: "o1", tipo: "FACTURA", archivo, usuarioId: "u1" });

    expect(resultado.ok).toBe(false);
    expect(resultado.error.mensaje).toContain("más de 10 MB");
    expect(upload).not.toHaveBeenCalled();
  });

  it("rechaza un tipo MIME que no es PDF/JPG/PNG SIN llegar a subirlo", async () => {
    const archivo = archivoFalso({ tipo: "application/zip", nombre: "cosa.zip" });

    const resultado = await subirDocumento({ ordenId: "o1", tipo: "OTRO", archivo, usuarioId: "u1" });

    expect(resultado.ok).toBe(false);
    expect(resultado.error.mensaje).toContain("no es PDF, JPG ni PNG");
    expect(upload).not.toHaveBeenCalled();
  });

  it("sube el binario y registra el metadato cuando el archivo es válido", async () => {
    const archivo = archivoFalso();

    const resultado = await subirDocumento({ ordenId: "o1", tipo: "FACTURA", archivo, usuarioId: "u1" });

    expect(resultado.ok).toBe(true);
    expect(upload).toHaveBeenCalledTimes(1);
    expect(insertUnico).toHaveBeenCalledTimes(1);
  });

  it("si el metadato falla tras subir el binario, limpia el objeto huérfano del bucket", async () => {
    insertUnico.mockResolvedValue({ data: null, error: { message: "fila rechazada" } });
    const archivo = archivoFalso();

    const resultado = await subirDocumento({ ordenId: "o1", tipo: "FACTURA", archivo, usuarioId: "u1" });

    expect(resultado.ok).toBe(false);
    expect(remove).toHaveBeenCalledTimes(1);
  });
});

describe("subirDocumentos", () => {
  it("sigue subiendo el resto de la lista aunque uno falle (ADR-012: nunca se revierte la orden)", async () => {
    let llamada = 0;
    supabase.storage.from.mockReturnValue({
      upload: vi.fn(async () => {
        llamada += 1;
        return llamada === 1 ? { data: null, error: { message: "red caída" } } : { data: { path: "x" }, error: null };
      }),
      remove: vi.fn().mockResolvedValue({ data: null, error: null }),
      createSignedUrl: vi.fn(),
    });
    supabase.from.mockReturnValue({
      insert: () => ({
        select: () => ({ single: vi.fn().mockResolvedValue({ data: { id: "d2" }, error: null }) }),
      }),
    });

    const resultados = await subirDocumentos({
      ordenId: "o1",
      pendientes: [
        { tipo: "FACTURA", archivo: archivoFalso({ nombre: "a.pdf" }) },
        { tipo: "FOTO_EQUIPO", archivo: archivoFalso({ nombre: "b.jpg", tipo: "image/jpeg" }) },
      ],
      usuarioId: "u1",
    });

    expect(resultados).toHaveLength(2);
    expect(resultados[0].ok).toBe(false);
    expect(resultados[1].ok).toBe(true);
  });
});
