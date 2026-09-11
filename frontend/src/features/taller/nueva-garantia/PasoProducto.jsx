/**
 * Paso 1 del asistente "Agregar nueva garantía": cliente, equipo y el
 * motivo del ingreso. Es la sección más larga a propósito -- es la única
 * que necesita datos que solo el mostrador tiene a mano (búsqueda de
 * cliente/equipo); el resto del asistente ya puede avanzar solo.
 */
import { useState } from "react";
import CampoCliente from "./CampoCliente.jsx";
import CampoProducto from "./CampoProducto.jsx";
import { AYUDA, errorAccesorios, errorNumeroFactura, errorNumeroSerie } from "./validacion.js";

export default function PasoProducto({
  cliente,
  setCliente,
  producto,
  setProducto,
  numeroSerie,
  setNumeroSerie,
  numeroFactura,
  setNumeroFactura,
  accesorios,
  setAccesorios,
  fallaReportada,
  setFallaReportada,
  errores,
}) {
  const [tocado, setTocado] = useState({});
  const marcar = (campo) => setTocado((t) => ({ ...t, [campo]: true }));

  const errSerie = tocado.numeroSerie ? errorNumeroSerie(numeroSerie) : null;
  const errFactura = tocado.numeroFactura ? errorNumeroFactura(numeroFactura) : null;
  const errAccesorios = tocado.accesorios ? errorAccesorios(accesorios) : null;

  return (
    <section className="ng-paso" aria-labelledby="ng-paso-1-titulo">
      <h3 className="ng-paso-titulo" id="ng-paso-1-titulo">
        Cliente y equipo
      </h3>
      <div className="ng-grid-2">
        <CampoCliente valor={cliente} onCambiar={setCliente} errores={errores} />
        <CampoProducto valor={producto} onCambiar={setProducto} errores={errores} />
      </div>
      <div className="ng-grid-2">
        <label className="ng-campo">
          <span className="ng-campo-etiqueta">Nº de serie</span>
          <input
            className="tg-input"
            value={numeroSerie}
            onChange={(e) => setNumeroSerie(e.target.value)}
            onBlur={() => marcar("numeroSerie")}
            placeholder="RT5-8842-AA"
            minLength={3}
            maxLength={60}
            aria-invalid={errSerie ? "true" : undefined}
            aria-describedby="ng-serie-ayuda"
          />
          <span id="ng-serie-ayuda" className="ng-campo-ayuda">
            Opcional. {AYUDA.numeroSerie} (3 a 60 caracteres)
          </span>
          {errSerie ? <p className="ng-campo-error">{errSerie}</p> : null}
        </label>
        <label className="ng-campo">
          <span className="ng-campo-etiqueta">Nº de factura</span>
          <input
            className="tg-input"
            value={numeroFactura}
            onChange={(e) => setNumeroFactura(e.target.value)}
            onBlur={() => marcar("numeroFactura")}
            placeholder="F-A-004821"
            maxLength={40}
            aria-invalid={errFactura ? "true" : undefined}
            aria-describedby="ng-factura-ayuda"
          />
          <span id="ng-factura-ayuda" className="ng-campo-ayuda">
            Opcional. {AYUDA.numeroFactura} (máx. 40)
          </span>
          {errFactura ? <p className="ng-campo-error">{errFactura}</p> : null}
        </label>
      </div>
      <label className="ng-campo">
        <span className="ng-campo-etiqueta">Accesorios entregados</span>
        <input
          className="tg-input"
          value={accesorios}
          onChange={(e) => setAccesorios(e.target.value)}
          onBlur={() => marcar("accesorios")}
          placeholder="Cargador, caja, cable de red…"
          maxLength={300}
          aria-invalid={errAccesorios ? "true" : undefined}
          aria-describedby="ng-accesorios-ayuda"
        />
        <span id="ng-accesorios-ayuda" className="ng-campo-ayuda">
          Opcional. Texto libre, máximo 300 caracteres.
        </span>
        {errAccesorios ? <p className="ng-campo-error">{errAccesorios}</p> : null}
      </label>
      <label className="ng-campo">
        <span className="ng-campo-etiqueta">Falla reportada *</span>
        <textarea
          className="tg-input ng-textarea"
          value={fallaReportada}
          onChange={(e) => setFallaReportada(e.target.value)}
          onBlur={() => marcar("fallaReportada")}
          rows={3}
          maxLength={2000}
          placeholder="Qué reporta el cliente, en sus palabras o las del mostrador…"
          aria-invalid={errores.fallaReportada ? "true" : undefined}
          aria-describedby="ng-falla-ayuda"
        />
        <span id="ng-falla-ayuda" className="ng-campo-contador">
          {fallaReportada.length}/2000 (mínimo 5)
        </span>
        {errores.fallaReportada ? <p className="ng-campo-error">{errores.fallaReportada}</p> : null}
      </label>
    </section>
  );
}
