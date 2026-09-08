/**
 * Píldoras de filtro por estado (CU-03).
 *
 * A diferencia de `TablaOrdenes`/`PanelVencimientos`, este componente SÍ
 * conoce sus propios hooks de datos: los diez estados y su recuento vienen
 * de la base, no de props que alguien más tendría que armar. Es justo lo
 * que hace que "agregar un estado con un INSERT lo hace aparecer sin tocar
 * React" sea cierto -- si los estados llegaran por props, Tablero.jsx
 * tendría que saber pedirlos, y volveríamos a tener el catálogo declarado
 * en un sitio que no es la base.
 */
import { useEstados, useRecuentosPorEstado } from "../datos/hooks.js";

export default function FiltrosEstado({ filtro, termino = "", onCambiar }) {
  const { estados, cargando: cargandoEstados } = useEstados();
  const codigos = ["TODAS", ...estados.map((e) => e.codigo)];
  // El mismo término que la tabla: una píldora que dice 40 junto a una
  // tabla que muestra 2 obliga al operador a adivinar cuál miente.
  const { recuentos, cargando: cargandoRecuentos } = useRecuentosPorEstado(codigos, { termino });

  if (cargandoEstados) {
    return (
      <div className="tg-chips" role="group" aria-label="Filtrar por estado, cargando">
        {[0, 1, 2, 3, 4].map((i) => (
          <span className="tg-chip tg-chip--esqueleto" key={i} aria-hidden="true" />
        ))}
      </div>
    );
  }

  return (
    <div className="tg-chips" role="group" aria-label="Filtrar por estado">
      <button
        type="button"
        className="tg-chip"
        aria-pressed={filtro === "TODAS"}
        onClick={() => onCambiar("TODAS")}
      >
        Todas
        <span className="tg-chip-cuenta">
          {cargandoRecuentos ? "…" : recuentos.TODAS ?? 0}
        </span>
      </button>
      {estados.map((e) => (
        <button
          key={e.codigo}
          type="button"
          className="tg-chip"
          aria-pressed={filtro === e.codigo}
          onClick={() => onCambiar(e.codigo)}
        >
          {e.nombre}
          <span className="tg-chip-cuenta">
            {cargandoRecuentos ? "…" : recuentos[e.codigo] ?? 0}
          </span>
        </button>
      ))}
    </div>
  );
}
