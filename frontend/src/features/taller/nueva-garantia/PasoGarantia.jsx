/**
 * Paso 2 del asistente: cobertura de garantía, prioridad y asignación. Se
 * combinan en un solo paso (a diferencia de las dos secciones del
 * formulario original) porque el asistente completo son 4 pasos, no 5, y
 * ninguna de las dos necesita datos del mostrador -- solo elecciones.
 *
 * La barra de vigencia es un ESPEJO, no la fuente: calcula
 * `fecha_compra + meses` en el navegador para dar realimentación
 * inmediata; el valor que queda guardado lo fija el trigger de la base.
 */
import { useMemo, useState } from "react";
import { useTecnicos } from "../datos/hooks.js";
import { errorFechaCompra, errorMesesOverride, errorSlaDias } from "./validacion.js";

const HOY_ISO = new Date().toISOString().slice(0, 10);

function mesesVigencia(fechaCompraIso, meses) {
  if (!fechaCompraIso || !meses) return null;
  const inicio = new Date(fechaCompraIso + "T00:00:00");
  const fin = new Date(inicio);
  fin.setMonth(fin.getMonth() + Number(meses));
  return fin.toISOString().slice(0, 10);
}

export default function PasoGarantia({
  producto,
  fechaCompra,
  setFechaCompra,
  tipoGarantia,
  setTipoGarantia,
  mesesOverride,
  setMesesOverride,
  prioridad,
  setPrioridad,
  tecnicoId,
  setTecnicoId,
  slaDias,
  setSlaDias,
  errores,
}) {
  const { tecnicos } = useTecnicos();
  const [tocado, setTocado] = useState({});
  const marcar = (campo) => setTocado((t) => ({ ...t, [campo]: true }));

  const mesesEfectivos =
    tipoGarantia === "SIN_GARANTIA"
      ? 0
      : tipoGarantia === "EXTENDIDA"
        ? Number(mesesOverride) || 0
        : (producto?.existente?.mesesGarantia ?? 12);

  const venceEstimado = useMemo(
    () => mesesVigencia(fechaCompra, mesesEfectivos),
    [fechaCompra, mesesEfectivos]
  );

  const errFecha = tocado.fechaCompra ? errorFechaCompra(fechaCompra, HOY_ISO) : errores?.fechaCompra;
  const errMeses =
    tipoGarantia === "EXTENDIDA" && tocado.mesesOverride
      ? errorMesesOverride(mesesOverride)
      : errores?.mesesOverride;
  const errSla = tocado.slaDias ? errorSlaDias(slaDias) : errores?.slaDias;

  return (
    <section className="ng-paso" aria-labelledby="ng-paso-2-titulo">
      <h3 className="ng-paso-titulo" id="ng-paso-2-titulo">
        Cobertura de garantía
      </h3>
      <div className="ng-grid-2">
        <label className="ng-campo">
          <span className="ng-campo-etiqueta">Fecha de compra *</span>
          <input
            className="tg-input"
            type="date"
            value={fechaCompra}
            min="2000-01-01"
            max={HOY_ISO}
            onChange={(e) => setFechaCompra(e.target.value)}
            onBlur={() => marcar("fechaCompra")}
            aria-invalid={errFecha ? "true" : undefined}
            aria-describedby="ng-fecha-ayuda"
          />
          <span id="ng-fecha-ayuda" className="ng-campo-ayuda">
            Desde el año 2000, sin fechas futuras.
          </span>
          {errFecha ? <p className="ng-campo-error">{errFecha}</p> : null}
        </label>
        <label className="ng-campo">
          <span className="ng-campo-etiqueta">Duración de garantía</span>
          <input
            className="tg-input"
            type="number"
            min={1}
            max={120}
            step={1}
            disabled={tipoGarantia !== "EXTENDIDA"}
            value={tipoGarantia === "EXTENDIDA" ? mesesOverride : mesesEfectivos}
            onChange={(e) => setMesesOverride(e.target.value)}
            onBlur={() => marcar("mesesOverride")}
            aria-invalid={errMeses ? "true" : undefined}
            aria-describedby="ng-meses-ayuda"
          />
          <span id="ng-meses-ayuda" className="ng-campo-ayuda">
            {tipoGarantia === "EXTENDIDA" ? "Meses pactados (1 a 120)." : "Según el producto."}
          </span>
          {errMeses ? <p className="ng-campo-error">{errMeses}</p> : null}
        </label>
      </div>

      <div className="ng-segmentado" role="radiogroup" aria-label="Tipo de garantía">
        {[
          { valor: "ESTANDAR", etiqueta: "Estándar de fábrica" },
          { valor: "EXTENDIDA", etiqueta: "Extendida" },
          { valor: "SIN_GARANTIA", etiqueta: "Sin garantía" },
        ].map((op) => (
          <button
            key={op.valor}
            type="button"
            role="radio"
            aria-checked={tipoGarantia === op.valor}
            className="ng-segmentado-opcion"
            onClick={() => setTipoGarantia(op.valor)}
          >
            {op.etiqueta}
          </button>
        ))}
      </div>

      {tipoGarantia !== "SIN_GARANTIA" && venceEstimado ? (
        <p className="ng-vigencia-nota">
          Estimado: vence el {new Date(venceEstimado + "T00:00:00").toLocaleDateString("es-VE")} (cálculo en
          pantalla; el valor real lo fija la base al registrar la garantía).
        </p>
      ) : null}

      <h3 className="ng-paso-titulo ng-paso-titulo--separado">Prioridad y asignación</h3>
      <div className="ng-grid-2">
        <label className="ng-campo">
          <span className="ng-campo-etiqueta">Prioridad</span>
          <select className="tg-input" value={prioridad} onChange={(e) => setPrioridad(e.target.value)}>
            <option value="BAJA">Baja</option>
            <option value="NORMAL">Normal</option>
            <option value="ALTA">Alta</option>
            <option value="URGENTE">Urgente</option>
          </select>
        </label>
        <label className="ng-campo">
          <span className="ng-campo-etiqueta">Técnico</span>
          <select className="tg-input" value={tecnicoId} onChange={(e) => setTecnicoId(e.target.value)}>
            <option value="">Sin asignar</option>
            {tecnicos.map((t) => (
              <option key={t.id} value={t.id}>
                {t.full_name}
              </option>
            ))}
          </select>
        </label>
      </div>
      <label className="ng-campo">
        <span className="ng-campo-etiqueta">Plazo de entrega (días) *</span>
        <input
          className="tg-input"
          type="number"
          min={1}
          max={90}
          step={1}
          value={slaDias}
          onChange={(e) => setSlaDias(e.target.value)}
          onBlur={() => marcar("slaDias")}
          aria-invalid={errSla ? "true" : undefined}
          aria-describedby="ng-sla-ayuda"
        />
        <span id="ng-sla-ayuda" className="ng-campo-ayuda">
          Un número entero de 1 a 90 días. Diagnóstico: 7 a 15 días hábiles según operativa del taller.
        </span>
        {errSla ? <p className="ng-campo-error">{errSla}</p> : null}
      </label>
    </section>
  );
}
