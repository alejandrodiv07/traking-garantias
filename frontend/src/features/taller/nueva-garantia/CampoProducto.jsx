/**
 * Equipo/modelo: busca uno existente, o compone el JSONB de un producto
 * nuevo. Misma forma de valor que `CampoCliente.jsx` (incluido `_valido`),
 * espejo de lo que `crear_orden()` espera en `p_producto_id` /
 * `p_producto_nuevo`.
 *
 * La categoría es de solo lectura al elegir un producto existente: es una
 * propiedad del producto, no de la garantía. Solo se escribe al registrar
 * un producto nuevo.
 */
import { useState } from "react";
import { errorCategoria, errorMesesGarantia, errorModelo, AYUDA } from "./validacion.js";
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
  const [tocado, setTocado] = useState({});

  // Mismo cuidado que en `CampoCliente.jsx`: `valor.existente` también viaja
  // en el borrador de un producto NUEVO (para que el resumen tenga con qué
  // pintar un nombre) y ese objeto es truthy desde la primera tecla. Si
  // `seleccionado` se leyera de ahí, elegir una marca en el alta de un
  // equipo nuevo lo disparaba a verdadero y el formulario de dos-tres
  // campos desaparecía debajo del cursor. Solo un `id` real (una fila ya
  // elegida por búsqueda) cuenta como "seleccionado".
  const seleccionado = valor?.id ? valor.existente : null;

  function seleccionarExistente(producto) {
    onCambiar({ id: producto.id, existente: producto, _valido: true });
  }

  function limpiarSeleccion() {
    onCambiar(null);
    setRegistrandoNuevo(false);
    setTermino("");
    setTocado({});
  }

  function empezarRegistroNuevo() {
    setRegistrandoNuevo(true);
    setNuevo((n) => ({ ...n, modelo: termino }));
  }

  function actualizarNuevo(campo, valorCampo) {
    const siguiente = { ...nuevo, [campo]: valorCampo };
    setNuevo(siguiente);

    const valido =
      Boolean(siguiente.marca_id) &&
      !errorModelo(siguiente.modelo) &&
      !errorCategoria(siguiente.categoria) &&
      !errorMesesGarantia(siguiente.meses_garantia);

    onCambiar({
      nuevo: {
        marca_id: siguiente.marca_id || undefined,
        modelo: siguiente.modelo.trim(),
        categoria: siguiente.categoria.trim(),
        meses_garantia: Number(siguiente.meses_garantia) || 12,
      },
      existente: {
        modelo: siguiente.modelo,
        categoria: siguiente.categoria,
        marca: marcas.find((m) => m.id === siguiente.marca_id)?.nombre ?? "",
      },
      _valido: valido,
    });
  }

  function marcarTocado(campo) {
    setTocado((t) => ({ ...t, [campo]: true }));
  }

  if (registrandoNuevo && !seleccionado) {
    const errModelo = tocado.modelo ? errorModelo(nuevo.modelo) : null;
    const errCategoria = tocado.categoria ? errorCategoria(nuevo.categoria) : null;
    const errMeses = tocado.meses_garantia ? errorMesesGarantia(nuevo.meses_garantia) : null;
    const faltaMarca = tocado.marca_id && !nuevo.marca_id;

    return (
      <div className="ng-cliente-nuevo">
        <div className="ng-grid-2">
          <label className="ng-campo">
            <span className="ng-campo-etiqueta">Marca *</span>
            <select
              className="tg-input"
              value={nuevo.marca_id}
              onChange={(e) => actualizarNuevo("marca_id", e.target.value)}
              onBlur={() => marcarTocado("marca_id")}
              required
              aria-invalid={faltaMarca ? "true" : undefined}
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
            {faltaMarca ? <p className="ng-campo-error">Elige una marca.</p> : null}
          </label>
          <label className="ng-campo">
            <span className="ng-campo-etiqueta">Equipo / modelo *</span>
            <input
              className="tg-input"
              value={nuevo.modelo}
              onChange={(e) => actualizarNuevo("modelo", e.target.value)}
              onBlur={() => marcarTocado("modelo")}
              placeholder="Ej. Router Industrial EA2-RT500"
              maxLength={80}
              required
              aria-invalid={errModelo ? "true" : undefined}
              aria-describedby="ng-producto-modelo-ayuda"
            />
            <span id="ng-producto-modelo-ayuda" className="ng-campo-ayuda">
              {AYUDA.modelo}
            </span>
            {errModelo ? <p className="ng-campo-error">{errModelo}</p> : null}
          </label>
        </div>
        <div className="ng-grid-2">
          <label className="ng-campo">
            <span className="ng-campo-etiqueta">Categoría *</span>
            <input
              className="tg-input"
              value={nuevo.categoria}
              onChange={(e) => actualizarNuevo("categoria", e.target.value)}
              onBlur={() => marcarTocado("categoria")}
              placeholder="Ej. Conectividad industrial"
              maxLength={60}
              required
              aria-invalid={errCategoria ? "true" : undefined}
              aria-describedby="ng-producto-categoria-ayuda"
            />
            <span id="ng-producto-categoria-ayuda" className="ng-campo-ayuda">
              {AYUDA.categoria}
            </span>
            {errCategoria ? <p className="ng-campo-error">{errCategoria}</p> : null}
          </label>
          <label className="ng-campo">
            <span className="ng-campo-etiqueta">Garantía de fábrica (meses)</span>
            <input
              className="tg-input"
              type="number"
              min={0}
              max={120}
              step={1}
              value={nuevo.meses_garantia}
              onChange={(e) => actualizarNuevo("meses_garantia", e.target.value)}
              onBlur={() => marcarTocado("meses_garantia")}
              aria-invalid={errMeses ? "true" : undefined}
              aria-describedby="ng-producto-meses-ayuda"
            />
            <span id="ng-producto-meses-ayuda" className="ng-campo-ayuda">
              Un número entero de 0 a 120.
            </span>
            {errMeses ? <p className="ng-campo-error">{errMeses}</p> : null}
          </label>
        </div>
        {errores?.producto ? <p className="ng-campo-error">{errores.producto}</p> : null}
        <button type="button" className="tg-enlace" onClick={limpiarSeleccion}>
          Buscar un equipo existente en su lugar
        </button>
      </div>
    );
  }

  return (
    <>
      <label className="ng-campo">
        <span className="ng-campo-etiqueta">Equipo / modelo *</span>
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
      <label className="ng-campo">
        <span className="ng-campo-etiqueta">Categoría</span>
        <input className="tg-input" value={seleccionado?.categoria ?? ""} readOnly disabled />
      </label>
    </>
  );
}
