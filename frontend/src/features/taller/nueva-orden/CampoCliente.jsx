/**
 * Cliente: busca uno existente, o compone el JSONB de un cliente nuevo.
 *
 * Emite hacia `FormularioOrden` un valor con esta forma:
 *   { id }                                  -- cliente existente
 *   { nuevo: { tipo_documento, documento, nombre, telefono?, email? } }
 *
 * Es exactamente lo que `crear_orden()` espera en `p_cliente_id` /
 * `p_cliente_nuevo` (ADR-009): nada se inserta aquí, los datos solo se
 * acumulan hasta que la orden se crea de verdad.
 */
import { useState } from "react";
import { useBusquedaClientes } from "../datos/hooks.js";
import SelectorAsincrono from "./SelectorAsincrono.jsx";

const TIPOS_DOCUMENTO = ["V", "E", "J", "G", "P"];

function etiquetaCliente(c) {
  return c.nombre;
}
function detalleCliente(c) {
  return `${c.tipo_documento}-${c.documento}`;
}

export default function CampoCliente({ valor, onCambiar, errores }) {
  const { termino, setTermino, clientes, buscando } = useBusquedaClientes();
  const [registrandoNuevo, setRegistrandoNuevo] = useState(false);
  const [nuevo, setNuevo] = useState({
    tipo_documento: "V",
    documento: "",
    nombre: "",
    telefono: "",
    email: "",
  });

  const seleccionado = valor?.existente ?? null;

  function seleccionarExistente(cliente) {
    onCambiar({ id: cliente.id, existente: cliente });
  }

  function limpiarSeleccion() {
    onCambiar(null);
    setRegistrandoNuevo(false);
    setTermino("");
  }

  function empezarRegistroNuevo() {
    setRegistrandoNuevo(true);
    // El nombre tecleado en la búsqueda es casi siempre el nombre real:
    // se precarga para no hacer escribirlo dos veces.
    setNuevo((n) => ({ ...n, nombre: termino }));
  }

  function actualizarNuevo(campo, valorCampo) {
    const siguiente = { ...nuevo, [campo]: valorCampo };
    setNuevo(siguiente);
    onCambiar({
      nuevo: {
        tipo_documento: siguiente.tipo_documento,
        documento: siguiente.documento.replace(/\D/g, ""),
        nombre: siguiente.nombre,
        telefono: siguiente.telefono || undefined,
        email: siguiente.email || undefined,
      },
      existente: {
        nombre: siguiente.nombre,
        tipo_documento: siguiente.tipo_documento,
        documento: siguiente.documento.replace(/\D/g, ""),
      },
    });
  }

  if (registrandoNuevo && !seleccionado) {
    return (
      <div className="no-cliente-nuevo">
        <div className="no-grid-2">
          <label className="no-campo">
            <span className="no-campo-etiqueta">Cliente *</span>
            <input
              className="tg-input"
              value={nuevo.nombre}
              onChange={(e) => actualizarNuevo("nombre", e.target.value)}
              placeholder="Nombre o razón social"
              required
            />
          </label>
          <label className="no-campo">
            <span className="no-campo-etiqueta">Cédula / RIF *</span>
            <div className="no-documento">
              <select
                className="tg-input no-documento-tipo"
                value={nuevo.tipo_documento}
                onChange={(e) => actualizarNuevo("tipo_documento", e.target.value)}
              >
                {TIPOS_DOCUMENTO.map((t) => (
                  <option key={t} value={t}>
                    {t}
                  </option>
                ))}
              </select>
              <input
                className="tg-input"
                inputMode="numeric"
                value={nuevo.documento}
                onChange={(e) => actualizarNuevo("documento", e.target.value)}
                placeholder="12345678"
                required
              />
            </div>
          </label>
        </div>
        {errores?.cliente ? <p className="no-campo-error">{errores.cliente}</p> : null}
        <button type="button" className="tg-enlace" onClick={limpiarSeleccion}>
          Buscar un cliente existente en su lugar
        </button>
      </div>
    );
  }

  return (
    <label className="no-campo">
      <span className="no-campo-etiqueta">Cliente *</span>
      <SelectorAsincrono
        placeholder="Nombre o cédula/RIF…"
        termino={termino}
        onTerminoCambia={setTermino}
        resultados={clientes}
        buscando={buscando}
        etiquetaDe={etiquetaCliente}
        detalleDe={detalleCliente}
        seleccionado={seleccionado}
        onSeleccionar={seleccionarExistente}
        onLimpiarSeleccion={limpiarSeleccion}
        onRegistrarNuevo={empezarRegistroNuevo}
        etiquetaRegistrarNuevo={`Registrar «${termino}» como cliente nuevo`}
        requerido
        error={errores?.cliente}
      />
    </label>
  );
}
