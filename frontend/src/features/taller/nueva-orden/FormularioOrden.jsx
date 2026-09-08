/**
 * Las cuatro secciones del mockup (§7.1): cliente y equipo, cobertura,
 * prioridad y asignación, y el envío. `falla_reportada` no está en el
 * mockup pero es obligatoria en la base (`CHECK`, 5-2000 caracteres): se
 * agrega al final de la primera sección, con contador de caracteres.
 *
 * La barra de vigencia es un ESPEJO, no la fuente: calcula
 * `fecha_compra + meses` en el navegador para dar realimentación
 * inmediata; el valor que queda guardado lo fija el trigger de la base. Si
 * alguna vez divergen, manda el trigger (§7.1).
 */
import { useMemo, useState } from "react";
import { useTecnicos } from "../datos/hooks.js";
import CampoCliente from "./CampoCliente.jsx";
import CampoProducto from "./CampoProducto.jsx";
import CampoDocumentos from "./CampoDocumentos.jsx";

const HOY_ISO = new Date().toISOString().slice(0, 10);

function mesesVigencia(fechaCompraIso, meses) {
  if (!fechaCompraIso || !meses) return null;
  const inicio = new Date(fechaCompraIso + "T00:00:00");
  const fin = new Date(inicio);
  fin.setMonth(fin.getMonth() + Number(meses));
  return fin.toISOString().slice(0, 10);
}

export default function FormularioOrden({ onCrear, onCancelar, enviando }) {
  const { tecnicos } = useTecnicos();

  const [cliente, setCliente] = useState(null);
  const [producto, setProducto] = useState(null);
  const [numeroSerie, setNumeroSerie] = useState("");
  const [numeroFactura, setNumeroFactura] = useState("");
  const [fallaReportada, setFallaReportada] = useState("");
  const [documentos, setDocumentos] = useState([]);

  const [fechaCompra, setFechaCompra] = useState(HOY_ISO);
  const [tipoGarantia, setTipoGarantia] = useState("ESTANDAR");
  const [mesesOverride, setMesesOverride] = useState(12);

  const [prioridad, setPrioridad] = useState("NORMAL");
  const [tecnicoId, setTecnicoId] = useState("");
  const [slaDias, setSlaDias] = useState(5);

  const [errores, setErrores] = useState({});

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

  function validar() {
    const nuevosErrores = {};
    if (!cliente) nuevosErrores.cliente = "Elige un cliente o registra uno nuevo.";
    if (!producto) nuevosErrores.producto = "Elige un equipo o registra uno nuevo.";
    const largoFalla = fallaReportada.trim().length;
    if (largoFalla < 5 || largoFalla > 2000) {
      nuevosErrores.fallaReportada = "Describe la falla con 5 a 2000 caracteres.";
    }
    if (!fechaCompra || fechaCompra < "2000-01-01") {
      nuevosErrores.fechaCompra = "Ingresa una fecha de compra válida.";
    }
    if (tipoGarantia === "EXTENDIDA" && !mesesOverride) {
      nuevosErrores.mesesOverride = "Una garantía extendida necesita su duración.";
    }
    const sla = Number(slaDias);
    if (!Number.isInteger(sla) || sla < 1 || sla > 90) {
      nuevosErrores.slaDias = "El plazo de entrega debe estar entre 1 y 90 días.";
    }
    setErrores(nuevosErrores);
    return Object.keys(nuevosErrores).length === 0;
  }

  function alEnviar(evento) {
    evento.preventDefault();
    if (!validar()) return;

    onCrear({
      datosOrden: {
        fechaCompra,
        fallaReportada: fallaReportada.trim(),
        cliente: cliente?.id ? { id: cliente.id } : { nuevo: cliente.nuevo },
        producto: producto?.id ? { id: producto.id } : { nuevo: producto.nuevo },
        numeroSerie: numeroSerie.trim() || null,
        numeroFactura: numeroFactura.trim() || null,
        prioridad,
        tipoGarantia,
        mesesOverride: tipoGarantia === "EXTENDIDA" ? Number(mesesOverride) : null,
        slaDias: Number(slaDias),
        tecnicoId: tecnicoId || null,
      },
      documentosPendientes: documentos,
    });
  }

  return (
    <form className="no-formulario" onSubmit={alEnviar} noValidate>
      <section className="no-seccion">
        <h4 className="no-seccion-titulo">Cliente y equipo</h4>
        <div className="no-grid-2">
          <CampoCliente valor={cliente} onCambiar={setCliente} errores={errores} />
          <CampoProducto valor={producto} onCambiar={setProducto} errores={errores} />
        </div>
        <div className="no-grid-2">
          <label className="no-campo">
            <span className="no-campo-etiqueta">Serial</span>
            <input
              className="tg-input"
              value={numeroSerie}
              onChange={(e) => setNumeroSerie(e.target.value)}
              placeholder="XXX-0000-XX"
              minLength={3}
              maxLength={60}
            />
          </label>
          <label className="no-campo">
            <span className="no-campo-etiqueta">Nº de factura</span>
            <input
              className="tg-input"
              value={numeroFactura}
              onChange={(e) => setNumeroFactura(e.target.value)}
              placeholder="V-0000"
            />
          </label>
        </div>
        <label className="no-campo">
          <span className="no-campo-etiqueta">Falla reportada *</span>
          <textarea
            className="tg-input no-textarea"
            value={fallaReportada}
            onChange={(e) => setFallaReportada(e.target.value)}
            rows={3}
            maxLength={2000}
            placeholder="Qué reporta el cliente, en sus palabras o las del mostrador…"
            aria-invalid={errores.fallaReportada ? "true" : undefined}
          />
          <span className="no-campo-contador">{fallaReportada.length}/2000</span>
          {errores.fallaReportada ? <p className="no-campo-error">{errores.fallaReportada}</p> : null}
        </label>
        <label className="no-campo">
          <span className="no-campo-etiqueta">Documentos</span>
          <CampoDocumentos pendientes={documentos} onCambiar={setDocumentos} />
        </label>
      </section>

      <section className="no-seccion">
        <h4 className="no-seccion-titulo">Cobertura de garantía</h4>
        <div className="no-grid-2">
          <label className="no-campo">
            <span className="no-campo-etiqueta">Fecha de compra *</span>
            <input
              className="tg-input"
              type="date"
              value={fechaCompra}
              min="2000-01-01"
              max={HOY_ISO}
              onChange={(e) => setFechaCompra(e.target.value)}
            />
            {errores.fechaCompra ? <p className="no-campo-error">{errores.fechaCompra}</p> : null}
          </label>
          <label className="no-campo">
            <span className="no-campo-etiqueta">Duración de garantía</span>
            <input
              className="tg-input"
              type="number"
              min={0}
              max={120}
              disabled={tipoGarantia !== "EXTENDIDA"}
              value={tipoGarantia === "EXTENDIDA" ? mesesOverride : mesesEfectivos}
              onChange={(e) => setMesesOverride(e.target.value)}
              aria-describedby="no-meses-ayuda"
            />
            <span id="no-meses-ayuda" className="no-campo-ayuda">
              {tipoGarantia === "EXTENDIDA" ? "meses pactados" : "según el producto"}
            </span>
            {errores.mesesOverride ? <p className="no-campo-error">{errores.mesesOverride}</p> : null}
          </label>
        </div>

        <div className="no-segmentado" role="radiogroup" aria-label="Tipo de garantía">
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
              className="no-segmentado-opcion"
              onClick={() => setTipoGarantia(op.valor)}
            >
              {op.etiqueta}
            </button>
          ))}
        </div>

        {tipoGarantia !== "SIN_GARANTIA" && venceEstimado ? (
          <p className="no-vigencia-nota">
            Estimado: vence el {new Date(venceEstimado + "T00:00:00").toLocaleDateString("es-VE")} (cálculo
            en pantalla; el valor real lo fija la base al crear la orden).
          </p>
        ) : null}
      </section>

      <section className="no-seccion">
        <h4 className="no-seccion-titulo">Prioridad y asignación</h4>
        <div className="no-grid-2">
          <label className="no-campo">
            <span className="no-campo-etiqueta">Prioridad</span>
            <select className="tg-input" value={prioridad} onChange={(e) => setPrioridad(e.target.value)}>
              <option value="BAJA">Baja</option>
              <option value="NORMAL">Normal</option>
              <option value="ALTA">Alta</option>
              <option value="URGENTE">Urgente</option>
            </select>
          </label>
          <label className="no-campo">
            <span className="no-campo-etiqueta">Técnico</span>
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
        <label className="no-campo">
          <span className="no-campo-etiqueta">Plazo de entrega (días) *</span>
          <input
            className="tg-input"
            type="number"
            min={1}
            max={90}
            value={slaDias}
            onChange={(e) => setSlaDias(e.target.value)}
          />
          <span className="no-campo-ayuda">Diagnóstico: 7 a 15 días hábiles según operativa del taller.</span>
          {errores.slaDias ? <p className="no-campo-error">{errores.slaDias}</p> : null}
        </label>
      </section>

      <div className="no-formulario-acciones">
        <button type="button" className="tg-btn tg-btn--suave" onClick={onCancelar} disabled={enviando}>
          Cancelar
        </button>
        <button type="submit" className="tg-btn tg-btn--principal" disabled={enviando}>
          {enviando ? "Creando…" : "Crear orden"}
        </button>
      </div>
    </form>
  );
}
