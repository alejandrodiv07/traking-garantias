// Paso 5 del asistente: fotos y documentos (opcional). Cámara o archivo;
// validación temprana de formato/tamaño/límite — con mensaje CLARO y SIN
// perder los adjuntos que sí entraron (spec §5.4 y §7.1).
import { useRef, useState } from "react";

const MAX_FOTOS = 8;
const MAX_DOCS = 6;
const MAX_BYTES = 8 * 1024 * 1024;
const MIME_FOTO = ["image/jpeg", "image/png", "image/webp"];
const MIME_DOC = ["application/pdf", "image/jpeg", "image/png"];

// La MISMA regla que aplica la base; aquí solo para avisar temprano.
function validar(archivo, tipo, cuentaFotos, cuentaDocs) {
  const mime = archivo?.type ?? "";
  if (tipo === "FOTO" && !MIME_FOTO.includes(mime)) {
    return "Formato no admitido: para las fotos usa JPG, PNG o WEBP";
  }
  if (tipo === "DOCUMENTO" && !MIME_DOC.includes(mime)) {
    return "Formato no admitido: para los documentos usa PDF, JPG o PNG";
  }
  if ((archivo?.size ?? 0) > MAX_BYTES) {
    return "El archivo no puede pesar más de 8 MB";
  }
  if (tipo === "FOTO" && cuentaFotos >= MAX_FOTOS) {
    return "El registro lleva 8 fotos: máximo 8 por registro";
  }
  if (tipo === "DOCUMENTO" && cuentaDocs >= MAX_DOCS) {
    return "El registro lleva 6 documentos: máximo 6 por registro";
  }
  return null;
}

let contadorAdjuntos = 0;

export default function PasoAdjuntos({ estado, actualizar }) {
  const [aviso, setAviso] = useState("");
  // Lista local: si la conexión o el padre se van, lo ya agregado sigue en pantalla.
  const [lista, setLista] = useState(estado?.archivosAdjuntos ?? []);
  // Espejo SIEMPRE fresco de la lista: en un lote de N archivos elegidos
  // juntos, cada agregar ya ve lo agregado por el anterior (con la lista del
  // render, todos leerían la misma y solo sobreviviría el último).
  const listaFresca = useRef(null);
  if (listaFresca.current === null) listaFresca.current = estado?.archivosAdjuntos ?? [];

  function agregar(archivo, tipo) {
    const anterior = listaFresca.current;
    const fotos = anterior.filter((a) => a.tipo === "FOTO").length;
    const docs = anterior.filter((a) => a.tipo === "DOCUMENTO").length;
    const error = validar(archivo, tipo, fotos, docs);
    if (error) {
      // Se rechaza con el mensaje CLARO; los ya agregados no se tocan.
      setAviso(error);
      return;
    }
    setAviso("");
    const id = `adj-${contadorAdjuntos++}`;
    const nueva = [...anterior, { id, archivo, tipo, etiqueta: null, error: null }];
    listaFresca.current = nueva;
    setLista(nueva);
    actualizar({ archivosAdjuntos: nueva });
  }

  function quitar(id) {
    const nueva = listaFresca.current.filter((a) => a.id !== id);
    listaFresca.current = nueva;
    setLista(nueva);
    actualizar({ archivosAdjuntos: nueva });
  }

  return (
    <div>
      <label htmlFor="inputFoto">
        Fotos (con la cámara o del archivo)
        <input
          id="inputFoto"
          type="file"
          accept="image/jpeg,image/png,image/webp"
          multiple
          onChange={(e) => {
            for (const f of e.target.files) agregar(f, "FOTO");
            e.target.value = "";
          }}
        />
      </label>

      <label htmlFor="inputDoc">
        Documentos (PDF, JPG o PNG)
        <input
          id="inputDoc"
          type="file"
          accept="application/pdf,image/jpeg,image/png"
          multiple
          onChange={(e) => {
            for (const f of e.target.files) agregar(f, "DOCUMENTO");
            e.target.value = "";
          }}
        />
      </label>

      <ul>
        {lista.map((a) => (
          <li key={a.id}>
            {a.archivo.name} ({a.tipo})
            <button type="button" onClick={() => quitar(a.id)}>
              Quitar
            </button>
          </li>
        ))}
      </ul>

      {aviso && (
        <p role="alert">{aviso}</p>
      )}
    </div>
  );
}