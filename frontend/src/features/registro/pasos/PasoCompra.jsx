// Paso 3 del asistente: la compra (spec §7.1). Soporte de FACTURA o
// NOTA_ENTREGA, número, fecha, plazo (7 o 15 ofrecidos; el sistema admite
// de 1 a 365). "No trae la factura" deja todo vacío: cobertura POR_DETERMINAR.
import { useState } from "react";

// El día de vencimiento (día exacto cuenta como vigente): puro cálculo
// de calendario para MOSTRARLO; la cobertura la decide la base.
function sumarDias(fechaTexto, dias) {
  if (!fechaTexto || !dias) return null;
  const d = new Date(`${fechaTexto}T00:00:00`);
  d.setDate(d.getDate() + Number(dias));
  return d.toISOString().slice(0, 10);
}

export default function PasoCompra({ estado, actualizar }) {
  const [sinSoporte, setSinSoporte] = useState(Boolean(estado?.sinSoporte));
  const [numero, setNumero] = useState(estado?.numeroSoporte ?? "");
  const [fecha, setFecha] = useState(estado?.fechaEmision ?? "");
  const [plazo, setPlazo] = useState(estado?.plazoDias ?? "");

  function comprometer(cambios = {}) {
    const sin = "sinSoporte" in cambios ? cambios.sinSoporte : sinSoporte;
    const num = "numero" in cambios ? cambios.numero : numero;
    const fec = "fecha" in cambios ? cambios.fecha : fecha;
    const pla = "plazo" in cambios ? cambios.plazo : plazo;
    actualizar({
      sinSoporte: sin,
      tipoSoporte: sin ? null : "FACTURA",
      numeroSoporte: sin ? null : num.trim() || null,
      fechaEmision: sin ? null : fec || null,
      plazoDias: sin || !pla || pla === "otro" ? null : Number(pla),
      venceEl: sin ? null : sumarDias(fec, pla === "otro" ? null : pla),
    });
  }

  const vence = sumarDias(fecha, plazo);

  return (
    <div>
      <label>
        <input
          type="checkbox"
          checked={sinSoporte}
          onChange={(e) => {
            setSinSoporte(e.target.checked);
            comprometer({ sinSoporte: e.target.checked });
          }}
        />
        No trae la factura ni la nota de entrega
      </label>

      <label htmlFor="numeroSoporte">
        Número
        <input
          id="numeroSoporte"
          value={numero}
          disabled={sinSoporte}
          onChange={(e) => {
            setNumero(e.target.value);
            comprometer({ numero: e.target.value });
          }}
        />
      </label>

      <label htmlFor="fechaEmision">
        Fecha de emisión
        <input
          id="fechaEmision"
          type="date"
          value={fecha}
          disabled={sinSoporte}
          onChange={(e) => {
            setFecha(e.target.value);
            comprometer({ fecha: e.target.value });
          }}
        />
      </label>

      <label htmlFor="plazo">
        Plazo de garantía
        <select
          id="plazo"
          value={plazo}
          disabled={sinSoporte}
          onChange={(e) => {
            setPlazo(e.target.value);
            comprometer({ plazo: e.target.value });
          }}
        >
          <option value="">—</option>
          <option value="7">7 días</option>
          <option value="15">15 días</option>
          <option value="otro">Otro…</option>
          {[1, 3, 30, 60, 90, 120, 180, 365].map((d) => (
            <option key={d} value={d}>
              {d} días
            </option>
          ))}
        </select>
      </label>

      {plazo === "otro" && (
        <label htmlFor="plazoOtro">
          Otro plazo (días)
          <input
            id="plazoOtro"
            type="number"
            min="1"
            max="365"
            value={plazo === "otro" ? "" : plazo}
            disabled={sinSoporte}
            onChange={(e) => {
              setPlazo(e.target.value);
              comprometer({ plazo: e.target.value });
            }}
          />
        </label>
      )}

      {!sinSoporte && vence && <p>Vence el {vence}.</p>}

      {sinSoporte && (
        <p role="status">
          Sin soporte de compra: la cobertura queda por determinar hasta que un
          JEFE o ADMIN la confirme con Ventas.
        </p>
      )}

      {/* El botón queda como reafirmación: el commit real ocurre al cambiar cada campo. */}
      <button type="button" onClick={() => comprometer()}>
        Guardar la compra
      </button>
    </div>
  );
}