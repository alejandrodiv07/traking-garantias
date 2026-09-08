/**
 * Autocompletado base (§7.2 del spec): un componente, dos usos (cliente y
 * producto). Comportamiento:
 *
 *   1. Busca desde 2 caracteres, con 300 ms de retardo (lo hace el hook que
 *      llama a este componente, no este componente).
 *   2. Muestra hasta 8 coincidencias con su dato desambiguador visible.
 *   3. Al elegir, el valor que se guarda es el objeto completo (con su
 *      UUID); el texto en pantalla es solo la etiqueta.
 *   4. Sin coincidencias, ofrece "Registrar nuevo".
 *   5. Teclado completo: flechas, Enter, Esc; `role="combobox"` con
 *      `aria-activedescendant`.
 *
 * Una vez elegido un valor (o al registrar uno nuevo), el campo se congela
 * en modo "lectura con opción de cambiar": no tiene sentido seguir
 * mostrando un cuadro de búsqueda sobre un valor que ya se decidió.
 */
import { useEffect, useId, useRef, useState } from "react";
import { Check, ChevronDown, Loader2 } from "lucide-react";

export default function SelectorAsincrono({
  etiqueta,
  placeholder,
  termino,
  onTerminoCambia,
  resultados,
  buscando,
  etiquetaDe,
  detalleDe,
  seleccionado,
  onSeleccionar,
  onLimpiarSeleccion,
  onRegistrarNuevo,
  etiquetaRegistrarNuevo = "Registrar nuevo",
  requerido = false,
  error,
}) {
  const idBase = useId();
  const [abierto, setAbierto] = useState(false);
  const [activo, setActivo] = useState(-1);
  const cajaRef = useRef(null);

  // Las opciones visibles son las coincidencias + (si el término alcanza
  // para buscar y no hay ninguna) la fila de "Registrar nuevo".
  const hayTermino = termino.trim().length >= 2;
  const sinCoincidencias = hayTermino && !buscando && resultados.length === 0;
  const opciones = sinCoincidencias
    ? [{ __nuevo: true }]
    : resultados;

  useEffect(() => {
    setActivo(opciones.length > 0 ? 0 : -1);
  }, [termino, resultados.length, sinCoincidencias]); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    function alHacerClicFuera(evento) {
      if (cajaRef.current && !cajaRef.current.contains(evento.target)) setAbierto(false);
    }
    document.addEventListener("mousedown", alHacerClicFuera);
    return () => document.removeEventListener("mousedown", alHacerClicFuera);
  }, []);

  function elegir(opcion) {
    if (opcion.__nuevo) {
      onRegistrarNuevo();
    } else {
      onSeleccionar(opcion);
    }
    setAbierto(false);
  }

  function alTeclado(evento) {
    if (evento.key === "ArrowDown") {
      evento.preventDefault();
      setAbierto(true);
      setActivo((i) => Math.min(i + 1, opciones.length - 1));
    } else if (evento.key === "ArrowUp") {
      evento.preventDefault();
      setActivo((i) => Math.max(i - 1, 0));
    } else if (evento.key === "Enter") {
      if (abierto && activo >= 0 && opciones[activo]) {
        evento.preventDefault();
        elegir(opciones[activo]);
      }
    } else if (evento.key === "Escape") {
      if (abierto) {
        evento.preventDefault();
        evento.stopPropagation();
        setAbierto(false);
      }
    }
  }

  if (seleccionado) {
    return (
      <div className="no-selector no-selector--fijado">
        <span className="no-selector-chip">
          <Check size={14} strokeWidth={2.5} aria-hidden="true" />
          <span>
            <span className="no-selector-principal">{etiquetaDe(seleccionado)}</span>
            {detalleDe(seleccionado) ? (
              <span className="no-selector-detalle"> · {detalleDe(seleccionado)}</span>
            ) : null}
          </span>
        </span>
        <button type="button" className="tg-enlace" onClick={onLimpiarSeleccion}>
          Cambiar
        </button>
      </div>
    );
  }

  const idListbox = `${idBase}-listbox`;
  const idActivo = activo >= 0 ? `${idBase}-opt-${activo}` : undefined;

  return (
    <div className="no-selector" ref={cajaRef}>
      <div className="no-selector-caja">
        <input
          type="text"
          className="tg-input"
          role="combobox"
          aria-expanded={abierto}
          aria-controls={idListbox}
          aria-activedescendant={idActivo}
          aria-autocomplete="list"
          aria-required={requerido}
          aria-invalid={error ? "true" : undefined}
          placeholder={placeholder}
          value={termino}
          onChange={(e) => {
            onTerminoCambia(e.target.value);
            setAbierto(true);
          }}
          onFocus={() => setAbierto(true)}
          onKeyDown={alTeclado}
        />
        {buscando ? (
          <Loader2 className="no-selector-icono no-selector-icono--girando" size={16} aria-hidden="true" />
        ) : (
          <ChevronDown className="no-selector-icono" size={16} aria-hidden="true" />
        )}
      </div>

      {abierto && hayTermino ? (
        <ul className="no-selector-lista" role="listbox" id={idListbox}>
          {buscando ? (
            <li className="no-selector-mensaje" role="presentation">
              Buscando…
            </li>
          ) : opciones.length === 0 ? (
            <li className="no-selector-mensaje" role="presentation">
              Sin coincidencias
            </li>
          ) : (
            opciones.map((opcion, i) => (
              <li
                key={opcion.__nuevo ? "__nuevo" : opcion.id}
                id={`${idBase}-opt-${i}`}
                role="option"
                aria-selected={i === activo}
                className={
                  "no-selector-opcion" +
                  (i === activo ? " no-selector-opcion--activa" : "") +
                  (opcion.__nuevo ? " no-selector-opcion--nueva" : "")
                }
                onMouseEnter={() => setActivo(i)}
                onMouseDown={(e) => {
                  // mousedown, no click: evita que el blur del input cierre
                  // la lista antes de registrar la elección.
                  e.preventDefault();
                  elegir(opcion);
                }}
              >
                {opcion.__nuevo ? (
                  etiquetaRegistrarNuevo
                ) : (
                  <>
                    <span className="no-selector-principal">{etiquetaDe(opcion)}</span>
                    {detalleDe(opcion) ? (
                      <span className="no-selector-detalle"> · {detalleDe(opcion)}</span>
                    ) : null}
                  </>
                )}
              </li>
            ))
          )}
        </ul>
      ) : null}

      {error ? <p className="no-campo-error">{error}</p> : null}
    </div>
  );
}
