/**
 * Documentos adjuntos, opcionales (Q2/Q8-Q14 de la ronda de grilling;
 * ADR-012). Aquí solo se ACUMULAN en memoria, igual que los datos de un
 * cliente/producto nuevo: la subida real a Storage ocurre recién con el
 * `orden_id` que devuelve `crear_orden()`, en `TokenDeConsulta.jsx`.
 */
import { useId, useRef } from "react";
import { FileText, Image, Paperclip, X } from "lucide-react";
import {
  MAX_ARCHIVOS_POR_ORDEN,
  TAMANO_MAXIMO_BYTES,
  TIPOS_DOCUMENTO,
  TIPOS_MIME_PERMITIDOS,
} from "../datos/documentos.js";

function formatoTamano(bytes) {
  if (bytes < 1024 * 1024) return `${Math.round(bytes / 1024)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

const ICONO_POR_TIPO = {
  FACTURA: FileText,
  FOTO_EQUIPO: Image,
  OTRO: Paperclip,
};

export default function CampoDocumentos({ pendientes, onCambiar }) {
  const idInput = useId();
  const inputRef = useRef(null);

  function agregarArchivos(lista) {
    const archivos = Array.from(lista ?? []);
    if (archivos.length === 0) return;

    const cupo = MAX_ARCHIVOS_POR_ORDEN - pendientes.length;
    const aceptados = [];
    const rechazados = [];

    for (const archivo of archivos.slice(0, Math.max(cupo, 0))) {
      if (archivo.size > TAMANO_MAXIMO_BYTES) {
        rechazados.push(`"${archivo.name}" pesa más de 10 MB.`);
      } else if (!TIPOS_MIME_PERMITIDOS.includes(archivo.type)) {
        rechazados.push(`"${archivo.name}" no es PDF, JPG ni PNG.`);
      } else {
        aceptados.push({ tipo: "OTRO", archivo });
      }
    }

    if (archivos.length > cupo) {
      rechazados.push(`Solo se aceptan hasta ${MAX_ARCHIVOS_POR_ORDEN} archivos por orden.`);
    }

    if (aceptados.length > 0) onCambiar([...pendientes, ...aceptados]);
    if (rechazados.length > 0) {
      // Aviso simple: este campo no tiene su propio canal de errores en el
      // formulario porque los documentos son opcionales (§7.1); un
      // `alert` sería peor, así que se resuelve con el propio DOM.
      // eslint-disable-next-line no-alert
      window.alert(rechazados.join("\n"));
    }
  }

  function cambiarTipo(indice, tipo) {
    onCambiar(pendientes.map((p, i) => (i === indice ? { ...p, tipo } : p)));
  }

  function quitar(indice) {
    onCambiar(pendientes.filter((_, i) => i !== indice));
  }

  const lleno = pendientes.length >= MAX_ARCHIVOS_POR_ORDEN;

  return (
    <div className="no-documentos">
      <input
        ref={inputRef}
        id={idInput}
        type="file"
        className="tg-sr"
        multiple
        accept={TIPOS_MIME_PERMITIDOS.join(",")}
        onChange={(e) => {
          agregarArchivos(e.target.files);
          e.target.value = "";
        }}
      />
      <label
        htmlFor={idInput}
        className={"no-documentos-zona" + (lleno ? " no-documentos-zona--llena" : "")}
      >
        <Paperclip size={16} strokeWidth={1.8} aria-hidden="true" />
        {lleno
          ? `Máximo ${MAX_ARCHIVOS_POR_ORDEN} archivos`
          : "Adjuntar factura o fotos del equipo (opcional, PDF/JPG/PNG, máx. 10 MB c/u)"}
      </label>

      {pendientes.length > 0 ? (
        <ul className="no-documentos-lista">
          {pendientes.map((p, i) => {
            const Icono = ICONO_POR_TIPO[p.tipo] ?? Paperclip;
            return (
              <li className="no-documentos-fila" key={`${p.archivo.name}-${i}`}>
                <Icono size={16} strokeWidth={1.8} aria-hidden="true" />
                <span className="no-documentos-nombre" title={p.archivo.name}>
                  {p.archivo.name}
                </span>
                <span className="no-documentos-tamano">{formatoTamano(p.archivo.size)}</span>
                <select
                  className="no-documentos-tipo"
                  value={p.tipo}
                  onChange={(e) => cambiarTipo(i, e.target.value)}
                  aria-label={`Tipo de documento: ${p.archivo.name}`}
                >
                  {TIPOS_DOCUMENTO.map((t) => (
                    <option key={t.codigo} value={t.codigo}>
                      {t.etiqueta}
                    </option>
                  ))}
                </select>
                <button
                  type="button"
                  className="no-documentos-quitar"
                  aria-label={`Quitar ${p.archivo.name}`}
                  onClick={() => quitar(i)}
                >
                  <X size={14} strokeWidth={2} aria-hidden="true" />
                </button>
              </li>
            );
          })}
        </ul>
      ) : null}
    </div>
  );
}
