/**
 * Equipo/modelo: busca uno existente, o compone el JSONB de un producto
 * nuevo. Misma forma de valor que `CampoCliente.jsx`, espejo de lo que
 * `crear_orden()` espera en `p_producto_id` / `p_producto_nuevo`.
 *
 * La categoría es de solo lectura al elegir un producto existente (§7.1):
 * es una propiedad del producto, no de la orden. Solo se escribe al
 * registrar un producto nuevo.
 */
import { useState } from "react";
import { useBusquedaProductos, useMarcas } from "../datos/hooks.js";
import SelectorAsincrono from "./SelectorAsincrono.jsx";

function etiquetaProducto(p) {
  return p.modelo;
}
function detalleProducto(p) {
  return p.marca;
}

export default function CampoProducto({ valor, onCambiar, errores }) {
  const { termino, setTermino, productos, buscando } = useBusquedaProductos();
  const { marcas } = useMarcas();
  const [registrandoNuevo, setRegistrandoNuevo] = useState(false);
  const [nuevo, setNuevo] = useState({
    marca_id: "",
    modelo: "",
    categoria: "",
    meses_garantia: 12,
  });

  const seleccionado = valor?.existente ?? null;

  function seleccionarExistente(producto) {
    onCambiar({ id: producto.id, existente: producto });
  }

  function limpiarSeleccion() {
    onCambiar(null);
    setRegistrandoNuevo(false);
    setTermino("");
  }

  function empezarRegistroNuevo() {
    setRegistrandoNuevo(true);
    setNuevo((n) => ({ ...n, modelo: termino }));
  }

  function actualizarNuevo(campo, valorCampo) {
    const siguiente = { ...nuevo, [campo]: valorCampo };
    setNuevo(siguiente);
    onCambiar({
      nuevo: {
        marca_id: siguiente.marca_id || undefined,
        modelo: siguiente.modelo,
        categoria: siguiente.categoria,
        meses_garantia: Number(siguiente.meses_garantia) || 12,
      },
      existente: {
        modelo: siguiente.modelo,
        categoria: siguiente.categoria,
        marca: marcas.find((m) => m.id === siguiente.marca_id)?.nombre ?? "",
      },
    });
  }

  if (registrandoNuevo && !seleccionado) {
    return (
      <div className="no-cliente-nuevo">
        <div className="no-grid-2">
          <label className="no-campo">
            <span className="no-campo-etiqueta">Marca *</span>
            <select
              className="tg-input"
              value={nuevo.marca_id}
              onChange={(e) => actualizarNuevo("marca_id", e.target.value)}
              required
            >
              <option value="" disabled>
                Elige una marca…
              </option>
              {marcas.map((m) => (
                <option key={m.id} value={m.id}>
                  {m.nombre}
                </option>
              ))}
            </select>
          </label>
          <label className="no-campo">
            <span className="no-campo-etiqueta">Equipo / modelo *</span>
            <input
              className="tg-input"
              value={nuevo.modelo}
              onChange={(e) => actualizarNuevo("modelo", e.target.value)}
              placeholder="Ej. Router Industrial EA2-RT500"
              required
            />
          </label>
        </div>
        <div className="no-grid-2">
          <label className="no-campo">
            <span className="no-campo-etiqueta">Categoría *</span>
            <input
              className="tg-input"
              value={nuevo.categoria}
              onChange={(e) => actualizarNuevo("categoria", e.target.value)}
              placeholder="Ej. Conectividad industrial"
              required
            />
          </label>
          <label className="no-campo">
            <span className="no-campo-etiqueta">Garantía de fábrica (meses)</span>
            <input
              className="tg-input"
              type="number"
              min={0}
              max={120}
              value={nuevo.meses_garantia}
              onChange={(e) => actualizarNuevo("meses_garantia", e.target.value)}
            />
          </label>
        </div>
        {errores?.producto ? <p className="no-campo-error">{errores.producto}</p> : null}
        <button type="button" className="tg-enlace" onClick={limpiarSeleccion}>
          Buscar un equipo existente en su lugar
        </button>
      </div>
    );
  }

  return (
    <>
      <label className="no-campo">
        <span className="no-campo-etiqueta">Equipo / modelo *</span>
        <SelectorAsincrono
          placeholder="Ej. Router Industrial EA2-RT500…"
          termino={termino}
          onTerminoCambia={setTermino}
          resultados={productos}
          buscando={buscando}
          etiquetaDe={etiquetaProducto}
          detalleDe={detalleProducto}
          seleccionado={seleccionado}
          onSeleccionar={seleccionarExistente}
          onLimpiarSeleccion={limpiarSeleccion}
          onRegistrarNuevo={empezarRegistroNuevo}
          etiquetaRegistrarNuevo={`Registrar «${termino}» como equipo nuevo`}
          requerido
          error={errores?.producto}
        />
      </label>
      <label className="no-campo">
        <span className="no-campo-etiqueta">Categoría</span>
        <input className="tg-input" value={seleccionado?.categoria ?? ""} readOnly disabled />
      </label>
    </>
  );
}
