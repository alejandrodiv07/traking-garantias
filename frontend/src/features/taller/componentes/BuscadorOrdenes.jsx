/**
 * Búsqueda multicriterio (§5.1). Antes vivía incrustada en `Tablero.jsx`
 * filtrando `ORDENES` en memoria; ahora es un campo controlado que
 * Tablero.jsx debounce-a hacia `useOrdenes({ termino })` -- el propio hook
 * de datos decide cuándo consultar, este componente solo es el input.
 */
import { Search, X } from "lucide-react";

export default function BuscadorOrdenes({ valor, onCambiar }) {
  return (
    <div className="tg-buscador">
      <label className="tg-sr" htmlFor="tg-busqueda">
        Buscar órdenes por número, cliente, cédula o RIF, equipo, serial o factura
      </label>
      <Search className="tg-buscador-icono" size={18} strokeWidth={1.8} aria-hidden="true" />
      <input
        id="tg-busqueda"
        className="tg-input"
        type="search"
        autoComplete="off"
        value={valor}
        onChange={(e) => onCambiar(e.target.value)}
        placeholder="Buscar por serial, cédula/RIF, cliente, nº de orden o factura…"
      />
      {valor ? (
        <button
          type="button"
          className="tg-buscador-limpiar"
          aria-label="Borrar la búsqueda"
          onClick={() => onCambiar("")}
        >
          <X size={16} strokeWidth={2} aria-hidden="true" />
        </button>
      ) : null}
    </div>
  );
}
