/**
 * El asistente completo "Agregar nueva garantía", en 4 pasos: Producto,
 * Garantía, Documentos, Resumen. Reemplaza al formulario de una sola
 * página de "Nueva orden" -- mismos datos, mismo `onCrear({datosOrden,
 * documentosPendientes})`, misma llamada a `crear_orden()` en el padre --
 * pero divididos en pasos más cortos, cada uno validado antes de avanzar
 * (§multi-step-progress, §progressive-disclosure de ui-ux-pro-max: no
 * abrumar con los tres bloques del formulario original de una sola vez).
 *
 * El estado vive aquí, arriba de los pasos, porque el paso 4 (resumen)
 * necesita ver TODO lo que se escribió en los pasos 1 a 3.
 */
import { useState } from "react";
import {
  errorAccesorios,
  errorFallaReportada,
  errorFechaCompra,
  errorMesesOverride,
  errorNumeroFactura,
  errorNumeroSerie,
  errorSlaDias,
  sinErrores,
} from "./validacion.js";
import PasoProducto from "./PasoProducto.jsx";
import PasoGarantia from "./PasoGarantia.jsx";
import PasoDocumentos from "./PasoDocumentos.jsx";
import PasoResumen from "./PasoResumen.jsx";

const HOY_ISO = new Date().toISOString().slice(0, 10);

const PASOS = [
  { id: "producto", titulo: "Producto" },
  { id: "garantia", titulo: "Garantía" },
  { id: "documentos", titulo: "Documentos" },
  { id: "resumen", titulo: "Resumen" },
];

export default function FormularioGarantia({ onCrear, onCancelar, enviando }) {
  const [pasoActual, setPasoActual] = useState(0);

  const [cliente, setCliente] = useState(null);
  const [producto, setProducto] = useState(null);
  const [numeroSerie, setNumeroSerie] = useState("");
  const [numeroFactura, setNumeroFactura] = useState("");
  const [accesorios, setAccesorios] = useState("");
  const [fallaReportada, setFallaReportada] = useState("");
  const [documentos, setDocumentos] = useState([]);

  const [fechaCompra, setFechaCompra] = useState(HOY_ISO);
  const [tipoGarantia, setTipoGarantia] = useState("ESTANDAR");
  const [mesesOverride, setMesesOverride] = useState(12);

  const [prioridad, setPrioridad] = useState("NORMAL");
  const [tecnicoId, setTecnicoId] = useState("");
  const [slaDias, setSlaDias] = useState(5);

  const [errores, setErrores] = useState({});

  function validarPasoProducto() {
    const e = {};
    if (!cliente?._valido) e.cliente = "Elige un cliente o completa su registro.";
    if (!producto?._valido) e.producto = "Elige un equipo o completa su registro.";
    e.fallaReportada = errorFallaReportada(fallaReportada);
    e.numeroSerie = errorNumeroSerie(numeroSerie);
    e.numeroFactura = errorNumeroFactura(numeroFactura);
    e.accesorios = errorAccesorios(accesorios);
    return e;
  }

  function validarPasoGarantia() {
    const e = {};
    e.fechaCompra = errorFechaCompra(fechaCompra, HOY_ISO);
    if (tipoGarantia === "EXTENDIDA") e.mesesOverride = errorMesesOverride(mesesOverride);
    e.slaDias = errorSlaDias(slaDias);
    return e;
  }

  const VALIDADORES_POR_PASO = [validarPasoProducto, validarPasoGarantia, () => ({}), () => ({})];

  function irASiguiente() {
    const nuevosErrores = VALIDADORES_POR_PASO[pasoActual]();
    setErrores((anteriores) => ({ ...anteriores, ...nuevosErrores }));
    if (!sinErrores(nuevosErrores)) return;
    setPasoActual((p) => Math.min(p + 1, PASOS.length - 1));
  }

  function irAAnterior() {
    setPasoActual((p) => Math.max(p - 1, 0));
  }

  function alEnviar(evento) {
    evento.preventDefault();
    // El último paso es de solo lectura: al llegar aquí, los pasos 1 y 2 ya
    // se validaron para avanzar. Se revalida una vez más por si el usuario
    // volvió atrás y cambió algo sin pasar de nuevo por "Siguiente".
    const errorsProducto = validarPasoProducto();
    const errorsGarantia = validarPasoGarantia();
    const todosLosErrores = { ...errorsProducto, ...errorsGarantia };
    setErrores(todosLosErrores);
    if (!sinErrores(todosLosErrores)) {
      setPasoActual(sinErrores(errorsProducto) ? 1 : 0);
      return;
    }

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

  const esUltimoPaso = pasoActual === PASOS.length - 1;

  return (
    <form className="ng-formulario" onSubmit={alEnviar} noValidate>
      <ol className="ng-pasos" aria-label="Progreso del registro">
        {PASOS.map((paso, i) => (
          <li
            key={paso.id}
            className={
              "ng-pasos-item" +
              (i === pasoActual ? " ng-pasos-item--actual" : "") +
              (i < pasoActual ? " ng-pasos-item--hecho" : "")
            }
            aria-current={i === pasoActual ? "step" : undefined}
          >
            <span className="ng-pasos-numero">{i < pasoActual ? "✓" : i + 1}</span>
            <span className="ng-pasos-titulo">{paso.titulo}</span>
          </li>
        ))}
      </ol>

      {pasoActual === 0 ? (
        <PasoProducto
          cliente={cliente}
          setCliente={setCliente}
          producto={producto}
          setProducto={setProducto}
          numeroSerie={numeroSerie}
          setNumeroSerie={setNumeroSerie}
          numeroFactura={numeroFactura}
          setNumeroFactura={setNumeroFactura}
          accesorios={accesorios}
          setAccesorios={setAccesorios}
          fallaReportada={fallaReportada}
          setFallaReportada={setFallaReportada}
          errores={errores}
        />
      ) : null}

      {pasoActual === 1 ? (
        <PasoGarantia
          producto={producto}
          fechaCompra={fechaCompra}
          setFechaCompra={setFechaCompra}
          tipoGarantia={tipoGarantia}
          setTipoGarantia={setTipoGarantia}
          mesesOverride={mesesOverride}
          setMesesOverride={setMesesOverride}
          prioridad={prioridad}
          setPrioridad={setPrioridad}
          tecnicoId={tecnicoId}
          setTecnicoId={setTecnicoId}
          slaDias={slaDias}
          setSlaDias={setSlaDias}
          errores={errores}
        />
      ) : null}

      {pasoActual === 2 ? <PasoDocumentos documentos={documentos} setDocumentos={setDocumentos} /> : null}

      {pasoActual === 3 ? (
        <PasoResumen
          cliente={cliente}
          producto={producto}
          numeroSerie={numeroSerie}
          numeroFactura={numeroFactura}
          accesorios={accesorios}
          fallaReportada={fallaReportada}
          fechaCompra={fechaCompra}
          tipoGarantia={tipoGarantia}
          mesesOverride={mesesOverride}
          prioridad={prioridad}
          tecnicoId={tecnicoId}
          slaDias={slaDias}
          documentos={documentos}
        />
      ) : null}

      <div className="ng-formulario-acciones">
        <button
          type="button"
          className="tg-btn tg-btn--suave"
          onClick={pasoActual === 0 ? onCancelar : irAAnterior}
          disabled={enviando}
        >
          {pasoActual === 0 ? "Cancelar" : "Atrás"}
        </button>
        {esUltimoPaso ? (
          <button type="submit" className="tg-btn tg-btn--principal" disabled={enviando}>
            {enviando ? "Registrando…" : "Registrar garantía"}
          </button>
        ) : (
          <button type="button" className="tg-btn tg-btn--principal" onClick={irASiguiente}>
            Siguiente
          </button>
        )}
      </div>
    </form>
  );
}
