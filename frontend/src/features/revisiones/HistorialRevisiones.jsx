// Historial de revisiones de la orden (Tarea 21 del plan; spec §7.4).
// Cronológico inverso, con revisor, fecha, resultado y observaciones.
// SIN botones de editar ni borrar: una corrección es una revisión nueva.
import { useEffect, useState } from "react";
import { listarRevisiones } from "./revisionesService.js";
import "./revisiones.css";

export default function HistorialRevisiones({ ordenId }) {
  const [revisiones, setRevisiones] = useState(null);
  const [error, setError] = useState(null);

  useEffect(() => {
    let vivo = true;
    listarRevisiones(ordenId).then((r) => {
      if (!vivo) return;
      if (r.ok) setRevisiones(r.datos);
      else setError(r);
    });
    return () => {
      vivo = false;
    };
  }, [ordenId]);

  if (error) {
    return (
      <p role="alert">{error.mensaje ?? "No se pudo cargar el historial."}</p>
    );
  }
  if (!revisiones) return <p role="status">Cargando revisiones…</p>;
  if (revisiones.length === 0) {
    return <p role="status">Sin revisiones todavía.</p>;
  }

  return (
    <ul className="rv-lista" aria-label="Historial de revisiones">
      {revisiones.map((v) => (
        <li key={v.id} data-testid="revision">
          <p>
            <strong>{v.tipo === "RECEPCION" ? "Recepción" : "Técnica"}</strong>{" "}
            — {v.revisor?.full_name ?? "—"}{" "}
            <time dateTime={v.revisado_en}>
              {new Date(v.revisado_en).toLocaleDateString("es-VE", {
                day: "numeric", month: "short", year: "numeric",
              })}
            </time>
          </p>
          <p>Resultado: {v.resultado}</p>
          {v.observaciones && <p>{v.observaciones}</p>}
        </li>
      ))}
    </ul>
  );
}