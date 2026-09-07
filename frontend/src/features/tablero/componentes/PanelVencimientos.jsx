/**
 * Garantías que vencen pronto.
 *
 * El "faltan N días" se calcula aquí y no viene precocinado en los datos: un
 * texto guardado ("3 días") es correcto el día que se escribe y mentira al
 * siguiente. La fecha real va además en el `datetime` del `<time>` y en el
 * título accesible, porque "3 días" sin fecha obliga a hacer cuentas.
 *
 * El color del plazo (rojo / ámbar / neutro) NUNCA es la única señal: el
 * número de días está escrito al lado. Un daltónico ve lo mismo.
 */
import { TriangleAlert } from "lucide-react";
import { diasHasta } from "../dominio.js";

/** <=7 días aprieta, <=21 avisa, el resto informa. */
function tonoPorPlazo(dias) {
  if (dias <= 7) return "adverso";
  if (dias <= 21) return "progreso";
  return "neutro";
}

function textoPlazo(dias) {
  if (dias < 0) return `Venció hace ${Math.abs(dias)} d`;
  if (dias === 0) return "Vence hoy";
  if (dias === 1) return "1 día";
  return `${dias} días`;
}

export default function PanelVencimientos({ items, hoy, onRecordatorios }) {
  return (
    <aside className="tg-card tg-aside" aria-labelledby="tg-aside-tit">
      <h2 className="tg-aside-titulo" id="tg-aside-tit">
        <TriangleAlert size={17} strokeWidth={2} aria-hidden="true" />
        Garantías por vencer
      </h2>
      <p className="tg-aside-sub">Próximos 30 días, ordenadas por vencimiento</p>

      <ul className="tg-vencimientos">
        {items.map((g) => {
          const dias = diasHasta(g.venceEl, hoy);
          const fechaLarga = new Date(g.venceEl + "T00:00:00").toLocaleDateString("es-VE", {
            day: "numeric",
            month: "long",
            year: "numeric",
          });
          return (
            <li className="tg-vencimiento" key={g.id}>
              <div className="tg-vencimiento-fila">
                <div>
                  <p className="tg-vencimiento-cliente">{g.cliente}</p>
                  <p className="tg-vencimiento-serie tg-mono">
                    {g.serie ?? "Sin número de serie"}
                  </p>
                </div>
                <span
                  className="tg-insignia tg-insignia--cuadrada"
                  data-tono={tonoPorPlazo(dias)}
                >
                  <time dateTime={g.venceEl} title={`Vence el ${fechaLarga}`}>
                    {textoPlazo(dias)}
                  </time>
                </span>
              </div>
              <p className="tg-vencimiento-equipo">{g.equipo}</p>
            </li>
          );
        })}
      </ul>

      <button
        type="button"
        className="tg-btn tg-btn--suave tg-btn--ancho"
        onClick={onRecordatorios}
      >
        Enviar recordatorios
      </button>
    </aside>
  );
}
