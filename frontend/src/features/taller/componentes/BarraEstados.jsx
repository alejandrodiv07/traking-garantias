/**
 * Barra de estados de la orden (maqueta 04): Recibido → En diagnóstico →
 * Diagnosticado → [Presupuestado, solo en servicio pago] → En reparación →
 * Reparado → Entregado. "Diagnosticado" es una etapa visual, no un estado: se
 * marca cuando hay diagnóstico cargado. Los estados que se salen de la línea
 * (espera de repuesto, irreparable, rechazos, anulado) salen como insignia con
 * su tono de `dominio.js`; el estado nunca se comunica solo con color.
 */
import { estado as estadoDe } from "../../tablero/dominio.js";
import "../taller.css";

const NOMBRES = {
  RECIBIDO: "Recibido",
  EN_DIAGNOSTICO: "En diagnóstico",
  DIAGNOSTICADO: "Diagnosticado",
  PRESUPUESTADO: "Presupuestado",
  EN_REPARACION: "En reparación",
  REPARADO: "Reparado",
  ENTREGADO: "Entregado",
};

export default function BarraEstados({ estado, tipoAtencion, tieneDiagnostico = false }) {
  const linea = [
    "RECIBIDO",
    "EN_DIAGNOSTICO",
    "DIAGNOSTICADO",
    ...(tipoAtencion === "PAGO" ? ["PRESUPUESTADO"] : []),
    "EN_REPARACION",
    "REPARADO",
    "ENTREGADO",
  ];
  const indice = linea.indexOf(estado);
  const lateral = indice === -1 ? estadoDe(estado) : null;

  return (
    <div className="be">
      <ol className="be-linea" aria-label="Avance de la orden">
        {linea.map((clave, i) => {
          const hecho = clave === "DIAGNOSTICADO" ? tieneDiagnostico || i < indice : i < indice;
          return (
            <li
              key={clave}
              data-hecho={String(hecho)}
              aria-current={i === indice ? "step" : undefined}
            >
              {NOMBRES[clave]}
            </li>
          );
        })}
      </ol>
      {lateral && (
        <p className="be-lateral" role="status" data-tono={lateral.tono}>
          {lateral.nombre}
        </p>
      )}
    </div>
  );
}
