// Detalle del registro en ventana sobre el Tablero (corrección D3; spec §7.4).
// Monta los componentes de `revisiones/` sin duplicarlos: el historial carga
// solo, el formulario lo cálculo de cobertura lo hace la base. Al guardar una
// revisión la cobertura pudo cambiar, así que el Tablero se recarga
// (onRegistrada -> cargar()).
import { X } from "lucide-react";
import HistorialRevisiones from "../../revisiones/HistorialRevisiones.jsx";
import RevisionForm from "../../revisiones/RevisionForm.jsx";

export default function DetalleRegistro({ fila, rol, onCerrar, onRegistrada }) {
  return (
    <div
      role="dialog"
      aria-label={`Detalle de ${fila.numero_orden}`}
      className="tg-detalle"
    >
      <header className="tg-detalle-cab">
        <div>
          <h2 className="tg-detalle-codigo tg-mono">{fila.numero_orden}</h2>
          <p className="tg-detalle-sub">
            {fila.producto}
            <span className="tg-mono">{fila.serial}</span>
          </p>
        </div>
        <button
          type="button"
          className="tg-btn tg-btn--suave"
          onClick={onCerrar}
          aria-label="Cerrar detalle"
        >
          <X size={16} strokeWidth={1.8} aria-hidden="true" />
          Cerrar
        </button>
      </header>

      <dl className="tg-detalle-datos">
        <div>
          <dt>Titular</dt>
          <dd>
            {fila.cliente}
            <span className="tg-mono">{fila.documento}</span>
          </dd>
        </div>
        <div>
          <dt>Estado</dt>
          <dd>{fila.estado_nombre}</dd>
        </div>
        <div>
          <dt>Cobertura</dt>
          <dd>{fila.cobertura}</dd>
        </div>
      </dl>

      <section aria-label="Revisiones del registro">
        <h3>Revisiones</h3>
        <HistorialRevisiones ordenId={fila.orden_id} />
        <RevisionForm ordenId={fila.orden_id} rol={rol} onRegistrada={onRegistrada} />
      </section>
    </div>
  );
}